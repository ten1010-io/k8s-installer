#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--out-path path]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--out-path      Directory to fill, laid out as bundle/python-packages is, defaults to that directory
                of this tree. It is emptied first
EOF
  exit
}

parse_params() {
  out_path=""

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --out-path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      out_path="${2-}"
      shift
      ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  return 0
}

setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  [[ -n ${work_path-} ]] && rm -rf "$work_path"

  return 0
}

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT
setup_colors
parse_params "$@"

# --- End of CLI template ---

# Fills bundle/python-packages with the wheels setup-venv.sh installs the venv
# of the control node from: one directory per python and per pip call of that
# script, holding the projects the call names, at the versions release.yml
# pins, and whatever they pull in.
#
# What goes where is read off setup-venv.sh rather than written here again,
# so that a project added to a pip call of that script is fetched into the
# directory that call reads without a second list to keep. The versions are
# read off python_packages of release.yml, which is where a release states
# what it chose, and every version there is passed to every download of that
# python as a constraint, so that a project pinned for one directory is the
# same build wherever another directory pulls it in.
#
# The wheels are fetched inside a manylinux container rather than by the pip
# of this machine. A wheel is built for one python and one floor of glibc,
# and this needs two pythons the nodes run and the oldest glibc among their
# operating systems, which no one operating system provides: the container
# holds every python with its headers and compiler on glibc 2.28, which is
# the glibc of rhel 8, the oldest the installer supports. pip run under the
# python of the container therefore picks, by itself, the wheels every node
# of that python can load, and a project that publishes no wheel for that
# python - netifaces, last released before 3.10 - is built from its sdist
# there and repaired by auditwheel into a wheel every node can load. The
# image is pinned by digest, the way everything this repository installs is
# pinned
KI_ROOT_PATH=$(cd "$SCRIPT_DIR_PATH/.." &>/dev/null && pwd -P)
RELEASE_META_PATH="$KI_ROOT_PATH"/release.yml
SETUP_VENV_PATH="$KI_ROOT_PATH"/scripts/setup-venv.sh

MANYLINUX_IMAGE="quay.io/pypa/manylinux_2_28_x86_64:2026.10.26-1@sha256:e0adf18521ad35192df733a6c62d35df7801957d24e0470238aacecfab2188a3"

work_path=""
container_cmd=""

main() {
  [[ -f $RELEASE_META_PATH ]] || die "[ERROR] No such file or directory of which path is \"$RELEASE_META_PATH\""
  [[ -f $SETUP_VENV_PATH ]] || die "[ERROR] No such file or directory of which path is \"$SETUP_VENV_PATH\""
  [[ -z $out_path ]] && out_path="$KI_ROOT_PATH/bundle/python-packages"

  find_container_command

  local pythons
  pythons=$(pip_calls | cut -d' ' -f1 | sort -u)
  [[ -z $pythons ]] && die "[ERROR] File[\"$SETUP_VENV_PATH\"] installs nothing from python-packages that this can read. pip calls are expected as \"pip install --no-index -f .../python-packages/<python>/<directory> <names>\""

  work_path=$(mktemp -d)
  rm -rf "$out_path"
  mkdir -p "$out_path"

  local python
  for python in $pythons; do
    fetch_python "$python"
  done

  report

  return 0
}

find_container_command() {
  local command
  for command in docker podman; do
    type "$command" &>/dev/null || continue
    container_cmd=$command
    return 0
  done

  die "[ERROR] docker or podman is needed to run the manylinux container the wheels are fetched in, and neither is installed"
}

# The pip calls of setup-venv.sh that read python-packages, as
# "<python> <directory> <name>..." lines, one per call
pip_calls() {
  grep -oP 'python-packages/\Kpython3\.[0-9]+/[A-Za-z0-9._-]+ [A-Za-z0-9._ -]+$' "$SETUP_VENV_PATH" | tr '/' ' ' | sort -u

  return 0
}

# The entries of python_packages.<python> of release.yml, as "<name> <version>"
# lines. yq is a binary of the bundle this is filling the directory next to,
# so the file is read without it
declared_versions() {
  local python=$1

  awk -v python="$python" '
    $0 == "python_packages:" { in_block = 1; next }
    in_block && $0 == "  " python ":" { in_python = 1; next }
    in_python && /^    [A-Za-z0-9._-]+: "[^"]+"$/ { name = $1; sub(/:$/, "", name); version = $2; gsub(/"/, "", version); print name, version; next }
    in_block && /^  [A-Za-z0-9._-]+:$/ { in_python = 0; next }
    in_block && /^[^ #]/ { exit }
  ' < "$RELEASE_META_PATH"

  return 0
}

# One container run per python: every directory of that python is downloaded
# with the pins of that python as constraints, every sdist that came instead
# of a wheel is built and repaired, and what was written is handed back to
# the user this runs as, since the container writes as root
fetch_python() {
  local python=$1

  local declared
  declared=$(declared_versions "$python")
  [[ -z $declared ]] && die "[ERROR] File[\"$RELEASE_META_PATH\"] declares no python_packages for $python, which setup-venv.sh installs from python-packages/$python"

  local constraints="$work_path/$python.constraints.txt"
  awk '{ print $1 "==" $2 }' <<< "$declared" > "$constraints"

  # python3.10 -> cp310-cp310, which is where the image keeps that python
  [[ $python =~ ^python3\.([0-9]+)$ ]] || die "[ERROR] Directory[\"$python\"] of python-packages is not named after a python 3 minor"
  local python_dir="cp3${BASH_REMATCH[1]}-cp3${BASH_REMATCH[1]}"

  local script="$work_path/$python.sh"
  {
    echo 'set -euo pipefail'
    echo "pip=\"/opt/python/$python_dir/bin/python -m pip\""
    echo '[[ -x "/opt/python/'"$python_dir"'/bin/python" ]] || { echo "[ERROR] The image holds no '"$python_dir"'"; exit 1; }'
    echo 'fetch() {'
    echo '  local dir=$1; shift'
    echo '  mkdir -p "/out/$dir"'
    echo '  $pip -q download --disable-pip-version-check -c /work/constraints.txt -d "/out/$dir" "$@"'
    echo '  local sdist'
    echo '  for sdist in "/out/$dir"/*.tar.gz "/out/$dir"/*.zip; do'
    echo '    [[ -e $sdist ]] || continue'
    echo '    echo "[INFO]   building $(basename "$sdist"), which is published as a source only"'
    echo '    rm -rf /tmp/wheel && $pip -q wheel --disable-pip-version-check --no-deps -w /tmp/wheel "$sdist"'
    echo '    auditwheel repair -w "/out/$dir" /tmp/wheel/*.whl >/tmp/auditwheel.log 2>&1 || { cat /tmp/auditwheel.log; exit 1; }'
    echo '    rm -f "$sdist"'
    echo '  done'
    echo '}'
    local line dir name names=() version
    while read -r line; do
      [[ $line = "$python "* ]] || continue
      read -r _ dir names <<< "$line"
      local specs=()
      for name in $names; do
        version=$(awk -v n="$name" '$1 == n { print $2; exit }' <<< "$declared")
        [[ -z $version ]] && die "[ERROR] File[\"$RELEASE_META_PATH\"] pins no version of $name for $python, which setup-venv.sh installs into python-packages/$python/$dir"
        specs+=("$name==$version")
      done
      echo "echo '[INFO] $python/$dir: ${specs[*]}'"
      echo "fetch $dir ${specs[*]}"
    done < <(pip_calls)
    echo "chown -R $(id -u):$(id -g) /out"
  } > "$script"
  cp "$constraints" "$work_path/constraints.txt"

  mkdir -p "$out_path/$python"
  "$container_cmd" run --rm -e HOME=/tmp -v "$out_path/$python:/out" -v "$work_path:/work:ro" "$MANYLINUX_IMAGE" bash /work/"$python".sh ||
    die "[ERROR] Fail to fetch the python packages of $python"

  require_declared "$python" "$declared"

  return 0
}

# Every name release.yml pins for the python is there as a wheel of that
# version, in some directory of that python, and nothing is left as a source.
# A wheel is named after the project with dashes turned to underscores, in
# whichever case the project spells itself
require_declared() {
  local python=$1 declared=$2

  local name version errors=""
  while read -r name version; do
    [[ -z $name ]] && continue
    [[ -n $(find "$out_path/$python" -iname "${name//-/_}-$version-*.whl" -print -quit) ]] ||
      errors+="\n  $name $version is pinned and no directory of $python holds a wheel of it"
  done <<< "$declared"
  [[ -n $(find "$out_path/$python" -name "*.tar.gz" -print -quit) ]] &&
    errors+="\n  a source archive is left under $python, which a node without a compiler can not install"
  [[ -n $errors ]] && die "[ERROR] Directory[\"$out_path/$python\"] is not what release.yml declares:$errors"

  return 0
}

report() {
  local dir
  while read -r dir; do
    msg "[INFO] ${dir#"$out_path"/} ($(find "$dir" -name "*.whl" | wc -l)): $(find "$dir" -name "*.whl" -printf '%f ' | sed -E 's/-(py[0-9]+(\.py[0-9]+)*|cp[0-9]+)-[^ ]*//g')"
  done < <(find "$out_path" -mindepth 2 -type d | sort)

  msg "[INFO] $(du -sh "$out_path" | cut -f1) under \"$out_path\", laid out as bundle/python-packages"

  return 0
}

main
