#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
EOF
  exit
}

parse_params() {
  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
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
}

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT
setup_colors
parse_params "$@"

# --- End of CLI template ---

# release.yml is where the version of a component is decided, and README.adoc
# carries a table of the same numbers so that a reader does not have to open the
# release file to find out what a release holds.
#
# That makes one fact live in two places, which is the thing this repository
# spends effort avoiding everywhere else. The copy is therefore checked rather
# than trusted. README.adoc says release.yml wins; this says so out loud on the
# day that stops being true, which is the day someone bumps a version and reads
# no further.
#
# The tables are found by the markers README.adoc carries above them rather than
# by their headings, so that rewording the prose around them can not quietly turn
# this into a check of nothing. A marker with no table under it, or a block of
# release.yml this can not read, is a failure for the same reason: agreement
# reported from an empty comparison is worse than no comparison
KI_ROOT_PATH=$(cd "$SCRIPT_DIR_PATH/.." &>/dev/null && pwd -P)
RELEASE_META_PATH="$KI_ROOT_PATH"/release.yml
README_PATH="$KI_ROOT_PATH"/README.adoc
CI_ANSIBLE_REQUIREMENTS_PATH="$KI_ROOT_PATH"/tools/ci-requirements-ansible.txt

MARKER_PREFIX="// check-release-docs: "

main() {
  require_files

  local failed="false"
  check_block packages || failed="true"
  check_block binaries || failed="true"
  local python
  for python in $(read_pythons); do
    check_block "python_packages $python" || failed="true"
  done
  check_ansible_core_pins || failed="true"

  if [[ $failed = "true" ]]; then
    die "[ERROR] File[\"$README_PATH\"] and file[\"$RELEASE_META_PATH\"] disagree. release.yml is where a version is decided, so correct the table unless what is wrong is the release file itself"
  fi

  msg "[INFO] README.adoc and $(basename "$CI_ANSIBLE_REQUIREMENTS_PATH") agree with release.yml on every declared component"

  return 0
}

# The pythons python_packages of release.yml declares a block for
read_pythons() {
  awk '
    $0 == "python_packages:" { in_block = 1; next }
    in_block && /^  [A-Za-z0-9._-]+:$/ { name = $1; sub(/:$/, "", name); print name; next }
    in_block && /^[^ #]/ { exit }
  ' < "$RELEASE_META_PATH"

  return 0
}

# tools/ci-requirements-ansible.txt pins the ansible-core the parse check runs
# under each python, and release.yml pins the ansible-core the bundle carries
# for that python. The check exists to read the playbooks with the parser a
# node has, so the two are the same fact in two files and the copy is checked
check_ansible_core_pins() {
  local ok="true"
  local pinned minor declared
  while read -r pinned minor; do
    [[ -z $pinned ]] && continue
    declared=$(lookup ansible-core "$(read_declared "python_packages python3.$minor")")
    if [[ -z $declared ]]; then
      msg "[ERROR] $(basename "$CI_ANSIBLE_REQUIREMENTS_PATH") pins ansible-core[\"$pinned\"] for python 3.$minor and release.yml declares no ansible-core for python3.$minor"
      ok="false"
      continue
    fi
    if [[ $pinned != "$declared" ]]; then
      msg "[ERROR] ansible-core for python 3.$minor is version[\"$declared\"] in release.yml and version[\"$pinned\"] in $(basename "$CI_ANSIBLE_REQUIREMENTS_PATH")"
      ok="false"
    fi
  done < <(grep -oP '^ansible-core==\K[0-9.]+; python_version == "3\.[0-9]+"' "$CI_ANSIBLE_REQUIREMENTS_PATH" | sed -E 's/; python_version == "3\.([0-9]+)"/ \1/')

  [[ $ok = "true" ]] && return 0

  return 1
}

require_files() {
  [[ ! -f $RELEASE_META_PATH ]] && die "[ERROR] No such file or directory of which path is \"$RELEASE_META_PATH\""
  [[ ! -f $README_PATH ]] && die "[ERROR] No such file or directory of which path is \"$README_PATH\""
  [[ ! -f $CI_ANSIBLE_REQUIREMENTS_PATH ]] && die "[ERROR] No such file or directory of which path is \"$CI_ANSIBLE_REQUIREMENTS_PATH\""

  return 0
}

check_block() {
  local block=$1

  local declared
  declared=$(read_declared "$block")
  [[ -z $declared ]] &&
    die "[ERROR] Block[\"$block\"] of file[\"$RELEASE_META_PATH\"] holds no entry this can read. Entries are expected as \"  <name>: \\\"<version>\\\"\""

  local tabled
  tabled=$(read_table "$block")
  [[ -z $tabled ]] &&
    die "[ERROR] File[\"$README_PATH\"] carries no table with a row under marker[\"$MARKER_PREFIX$block\"]. Rows are expected as \"|<name> |<version>\""

  local ok="true"
  local name
  local version
  local found

  while read -r name version; do
    found=$(lookup "$name" "$tabled")
    if [[ -z $found ]]; then
      msg "[ERROR] ${block}[\"$name\"] is declared as version[\"$version\"] and the table of README.adoc does not list it"
      ok="false"
      continue
    fi

    if [[ $found != "$version" ]]; then
      msg "[ERROR] ${block}[\"$name\"] is version[\"$version\"] in release.yml and version[\"$found\"] in README.adoc"
      ok="false"
    fi
  done <<< "$declared"

  while read -r name version; do
    found=$(lookup "$name" "$declared")
    if [[ -z $found ]]; then
      msg "[ERROR] ${block}[\"$name\"] is listed as version[\"$version\"] in the table of README.adoc and release.yml declares no such component"
      ok="false"
    fi
  done <<< "$tabled"

  [[ $ok = "true" ]] && return 0

  return 1
}

lookup() {
  local name=$1
  local pairs=$2

  awk -v n="$name" '$1 == n { print $2; exit }' <<< "$pairs"

  return 0
}

# The entries of a top level block of release.yml, as "<name> <version>" lines.
# Reading stops at the first line of the block that is not an entry, which is how
# the next key of the file ends it. A block named as "<block> <key>" is the
# block one level down, which is how python_packages declares one per python
read_declared() {
  local block=$1

  local key=""
  [[ $block = *" "* ]] && key=${block#* } && block=${block%% *}

  awk -v block="$block" -v key="$key" '
    $0 == block ":" { in_block = 1; in_key = (key == ""); next }
    in_block && key != "" && $0 == "  " key ":" { in_key = 1; next }
    in_block && key != "" && /^  [A-Za-z0-9._-]+:$/ { in_key = 0; next }
    in_block && in_key && $0 ~ "^" (key == "" ? "  " : "    ") "[A-Za-z0-9._-]+: \"[^\"]+\"$" {
      name = $1
      sub(/:$/, "", name)
      version = $2
      gsub(/"/, "", version)
      print name, version
      next
    }
    in_block && key == "" { exit }
    in_block && /^[^ #]/ { exit }
  ' < "$RELEASE_META_PATH"

  return 0
}

# The rows of the table that follows a marker in README.adoc, as "<name>
# <version>" lines. The header row is not one of them, since a cell of it does
# not begin with a digit
read_table() {
  local block=$1

  awk -v marker="$MARKER_PREFIX$block" '
    $0 == marker { found = 1; next }
    found && $0 == "|===" {
      in_table = !in_table
      if (!in_table) { exit }
      next
    }
    in_table && $0 ~ /^\|[A-Za-z0-9._-]+ \|[0-9]/ {
      name = substr($1, 2)
      version = substr($2, 2)
      print name, version
    }
  ' < "$README_PATH"

  return 0
}

main
