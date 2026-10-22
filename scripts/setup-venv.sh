#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--root-path path] [--force]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--root-path     Directory path
--force         Recreate the virtual environment even if one already exists
EOF
  exit
}

parse_params() {
  ki_opt_root_path=""
  force="false"

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --force) force="true" ;;
    --root-path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      ki_opt_root_path="${2-}"
      shift
      ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ -z "${ki_opt_root_path-}" ]] && die "[ERROR] Missing required option: --root-path"

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

# shellcheck source=all-node/linux-package/rpm-common.sh
source "$SCRIPT_DIR_PATH/all-node/linux-package/rpm-common.sh"
# shellcheck source=all-node/linux-package/deb-common.sh
source "$SCRIPT_DIR_PATH/all-node/linux-package/deb-common.sh"

UBUNTU2204_SUPPORTED_MINOR_VERSION=5
UBUNTU2404_SUPPORTED_MINOR_VERSION=5
RHEL8_SUPPORTED_MINOR_VERSION=10
RHEL9_SUPPORTED_MINOR_VERSION=8
RHEL10_SUPPORTED_MINOR_VERSION=2

KI_OPT_SCRIPTS_PATH="$ki_opt_root_path"/scripts
KI_OPT_BUNDLE_PATH="$ki_opt_root_path"/bundle
KI_OPT_VENV_PATH="$ki_opt_root_path"/venv

YQ_CMD="$KI_OPT_BUNDLE_PATH"/bin/yq

os_info=""
os_distribution=""
os_major_version=""
os_minor_version=""

main() {
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory
  get_os_version
  remove_venv_if_forced

  if [[ $os_distribution = "ubuntu" && $os_major_version = "22.04" && $os_minor_version -le "$UBUNTU2204_SUPPORTED_MINOR_VERSION" ]]; then
    ubuntu2204_setup
    exit 0
  fi

  if [[ $os_distribution = "ubuntu" && $os_major_version = "24.04" && $os_minor_version -le "$UBUNTU2404_SUPPORTED_MINOR_VERSION" ]]; then
    ubuntu2404_setup
    exit 0
  fi

  if [[ $os_distribution = "rhel" && $os_major_version = "8" && $os_minor_version -le "$RHEL8_SUPPORTED_MINOR_VERSION" ]]; then
    rhel8_setup
    exit 0
  fi

  if [[ $os_distribution = "rhel" && $os_major_version = "9" && $os_minor_version -le "$RHEL9_SUPPORTED_MINOR_VERSION" ]]; then
    rhel9_setup
    exit 0
  fi

  if [[ $os_distribution = "rhel" && $os_major_version = "10" && $os_minor_version -le "$RHEL10_SUPPORTED_MINOR_VERSION" ]]; then
    rhel10_setup
    exit 0
  fi

  die "[ERROR] OS not supported\n$os_info"
}

# An upgrade ships new versions of the python packages, and pip can not be relied
# on to reconcile an existing environment offline, so the environment is thrown
# away and built again from the packages of the new release
remove_venv_if_forced() {
  [[ $force = "false" ]] && return 0
  [[ ! -e $KI_OPT_VENV_PATH ]] && return 0

  msg "[INFO] K8s installer will recreate virtual environment[\"venv\"]"
  rm -rf "$KI_OPT_VENV_PATH"

  return 0
}

ubuntu2204_setup() {
  if [[ $(ubuntu2204_is_installed python3\.10-venv) = "false" ]]; then
    local base="$KI_OPT_BUNDLE_PATH/linux-packages/ubuntu22.04"
    export DEBIAN_FRONTEND=noninteractive
    ubuntu_plan_dirs "$base/python3.10" "$base/python3" "$base/python3-distutils" "$base/python3.10-venv"
    ubuntu_install_dir "$base/python3.10"
    # python3-minimal before the rest of python3, which the others pre-depend on
    local minimal=()
    mapfile -t minimal < <(deb_files_of "$base/python3" | grep -E '/python3-minimal_[^/]*\.deb$' || true)
    [[ ${#minimal[@]} = 0 ]] &&
      die "[ERROR] Directory[\"python3\"] of the bundle holds no python3-minimal, which the rest of it pre-depends on"
    deb_install_planned python3-minimal -- "${minimal[@]}"
    ubuntu_install_dir "$base/python3"
    ubuntu_install_dir "$base/python3-distutils"
    ubuntu_install_dir "$base/python3.10-venv"
    export DEBIAN_FRONTEND=""
  fi

  if [[ -e $KI_OPT_VENV_PATH ]]; then
    msg "[INFO] K8s installer will use existing venv"
  else
    msg "[INFO] K8s installer will create virtual environment[\"venv\"]"

    python3.10 -m venv "$KI_OPT_VENV_PATH"
    "$KI_OPT_VENV_PATH"/bin/pip3.10 install --no-index -f "$KI_OPT_BUNDLE_PATH"/python-packages/python3.10/netifaces netifaces
    "$KI_OPT_VENV_PATH"/bin/pip3.10 install --no-index -f "$KI_OPT_BUNDLE_PATH"/python-packages/python3.10/jinja2-cli jinja2-cli PyYAML
    "$KI_OPT_VENV_PATH"/bin/pip3.10 install --no-index -f "$KI_OPT_BUNDLE_PATH"/python-packages/python3.10/ansible ansible jmespath
    "$KI_OPT_VENV_PATH"/bin/pip3.10 install --no-index -f "$KI_OPT_BUNDLE_PATH"/python-packages/python3.10/pydantic pydantic
  fi

  validate_venv_directory

  msg ""
  msg "[INFO] To activate venv, run the following"
  msg "source $KI_OPT_VENV_PATH/bin/activate"

  return 0
}

ubuntu2404_setup() {
  if [[ $(ubuntu2404_is_installed python3\.12-venv) = "false" ]]; then
    local base="$KI_OPT_BUNDLE_PATH/linux-packages/ubuntu24.04"
    export DEBIAN_FRONTEND=noninteractive
    ubuntu_plan_dirs "$base/python3.12" "$base/python3.12-venv"
    ubuntu_install_dir "$base/python3.12"
    ubuntu_install_dir "$base/python3.12-venv"
    export DEBIAN_FRONTEND=""
  fi

  if [[ -e $KI_OPT_VENV_PATH ]]; then
    msg "[INFO] K8s installer will use existing venv"
  else
    msg "[INFO] K8s installer will create virtual environment[\"venv\"]"

    python3.12 -m venv "$KI_OPT_VENV_PATH"
    "$KI_OPT_VENV_PATH"/bin/pip3.12 install --no-index -f "$KI_OPT_BUNDLE_PATH"/python-packages/python3.12/netifaces netifaces
    "$KI_OPT_VENV_PATH"/bin/pip3.12 install --no-index -f "$KI_OPT_BUNDLE_PATH"/python-packages/python3.12/jinja2-cli jinja2-cli PyYAML
    "$KI_OPT_VENV_PATH"/bin/pip3.12 install --no-index -f "$KI_OPT_BUNDLE_PATH"/python-packages/python3.12/ansible ansible jmespath
    "$KI_OPT_VENV_PATH"/bin/pip3.12 install --no-index -f "$KI_OPT_BUNDLE_PATH"/python-packages/python3.12/pydantic pydantic
  fi

  validate_venv_directory

  msg ""
  msg "[INFO] To activate venv, run the following"
  msg "source $KI_OPT_VENV_PATH/bin/activate"

  return 0
}

rhel8_setup() {
  if [[ $(rhel_is_installed python3\.12) = "false" ]]; then
    rhel_install_dir "$KI_OPT_BUNDLE_PATH/linux-packages/rhel8/python3.12"
  fi

  if [[ -e $KI_OPT_VENV_PATH ]]; then
    msg "[INFO] K8s installer will use existing venv"
  else
    msg "[INFO] K8s installer will create virtual environment[\"venv\"]"

    python3.12 -m venv "$KI_OPT_VENV_PATH"
    "$KI_OPT_VENV_PATH"/bin/pip3.12 install --no-index -f "$KI_OPT_BUNDLE_PATH"/python-packages/python3.12/netifaces netifaces
    "$KI_OPT_VENV_PATH"/bin/pip3.12 install --no-index -f "$KI_OPT_BUNDLE_PATH"/python-packages/python3.12/jinja2-cli jinja2-cli PyYAML
    "$KI_OPT_VENV_PATH"/bin/pip3.12 install --no-index -f "$KI_OPT_BUNDLE_PATH"/python-packages/python3.12/ansible ansible jmespath
    "$KI_OPT_VENV_PATH"/bin/pip3.12 install --no-index -f "$KI_OPT_BUNDLE_PATH"/python-packages/python3.12/pydantic pydantic
  fi

  validate_venv_directory

  msg ""
  msg "[INFO] To activate venv, run the following"
  msg "source $KI_OPT_VENV_PATH/bin/activate"

  return 0
}

# rhel 9 boots with python 3.9 and carries 3.12 as a package of its own, the way
# rhel 8 does. Both directories come from tools/build-bundle-packages.sh, so the
# alternatives the rhel 8 one goes through arrives inside it when the oldest
# minor lacks it.
#
# The directory is laid down whether or not python3.12 is there, unlike on rhel
# 8. It carries what the python of the newest minor needs at run time and rpm
# does not know to ask for - the expat its pyexpat calls into, the openssh that
# can load the openssl it brings - and a node that got python3.12 some other
# way, from AppStream by hand or from an earlier run of this, has none of that
# and dies at ensurepip or loses its sshd. rpm leaves what is already at the
# version the directory holds alone.
#
# What the node holds at a newer version it keeps, by the source rpm it was
# built from (plan-rpm-install.py). A newer minor already carries an expat and
# an openssl at least as new as the ones the directory brings, and downgrading
# them breaks the packages of the node pinned to them, openssl-devel among them
rhel9_setup() {
  rhel_install_dir "$KI_OPT_BUNDLE_PATH/linux-packages/rhel9/python3.12"

  rhel_create_venv

  return 0
}

# Everything here goes in at the version the bundle carries, whatever the node
# holds, the way it did before there was a plan: every directory is a
# principal one.
#
# These are the closure of python rather than anything the release declares,
# and a node of a later point release often holds the interpreter newer. But
# the venv package wants the python at exactly its own version, and it is not
# on an ubuntu image: a node whose python is newer than the bundle's and that
# has no venv package of its own would have nothing to make the environment
# with, and no repository to get one from. So the interpreter follows the
# bundle, downgrade and all, which is the python of the newest point release
# the bundle was built against. dpkg refuses it only where the node pins that
# python from outside the directories (a libpython3.X-dev, say), and then it
# refuses before anything of the node has moved.
#
# Planned as one all the same: what the node already holds at the bundled
# version is not handed over, and python3-minimal is named by two directories
ubuntu_plan_dirs() {
  deb_principal_dirs=("$@")

  local files=()
  local dir
  local file
  for dir in "$@"; do
    while read -r file; do
      [[ -n $file ]] && files+=("$file")
    done < <(deb_files_of "$dir")
  done

  deb_plan_install "${files[@]}"

  return 0
}

ubuntu_install_dir() {
  local dir=$1

  local files=()
  mapfile -t files < <(deb_files_of "$dir")
  [[ ${#files[@]} = 0 ]] && return 0

  deb_install_planned "$(basename "$dir")" -- "${files[@]}"

  return 0
}

# Everything here is the dependency closure of python3.12, so nothing is
# declared by the release and every package is planned as a dependency
rhel_install_dir() {
  local dir=$1

  local files=()
  local rpm_file
  for rpm_file in "$dir"/*.rpm; do
    [[ -e $rpm_file ]] && files+=("$rpm_file")
  done
  [[ ${#files[@]} = 0 ]] && return 0

  rpm_install_files "$(basename "$dir")" -- "${files[@]}"

  return 0
}

# rhel 10 boots with python 3.12 as its system python, so there is nothing to
# install before the environment is made
rhel10_setup() {
  rhel_create_venv

  return 0
}

rhel_create_venv() {
  if [[ -e $KI_OPT_VENV_PATH ]]; then
    msg "[INFO] K8s installer will use existing venv"
  else
    msg "[INFO] K8s installer will create virtual environment[\"venv\"]"

    python3.12 -m venv "$KI_OPT_VENV_PATH"
    "$KI_OPT_VENV_PATH"/bin/pip3.12 install --no-index -f "$KI_OPT_BUNDLE_PATH"/python-packages/python3.12/netifaces netifaces
    "$KI_OPT_VENV_PATH"/bin/pip3.12 install --no-index -f "$KI_OPT_BUNDLE_PATH"/python-packages/python3.12/jinja2-cli jinja2-cli PyYAML
    "$KI_OPT_VENV_PATH"/bin/pip3.12 install --no-index -f "$KI_OPT_BUNDLE_PATH"/python-packages/python3.12/ansible ansible jmespath
    "$KI_OPT_VENV_PATH"/bin/pip3.12 install --no-index -f "$KI_OPT_BUNDLE_PATH"/python-packages/python3.12/pydantic pydantic
  fi

  validate_venv_directory

  msg ""
  msg "[INFO] To activate venv, run the following"
  msg "source $KI_OPT_VENV_PATH/bin/activate"

  return 0
}

ubuntu2204_is_installed() {
  local pkg_regex=$1

  local exit_code=0
  apt list --installed 2> /dev/null | grep "$pkg_regex" > /dev/null 2>/dev/null || exit_code=$?

  if [[ $exit_code = "0" ]]; then echo "true"; else echo "false"; fi

  return 0
}

ubuntu2404_is_installed() {
  local pkg_regex=$1

  local exit_code=0
  apt list --installed 2> /dev/null | grep "$pkg_regex" > /dev/null 2>/dev/null || exit_code=$?

  if [[ $exit_code = "0" ]]; then echo "true"; else echo "false"; fi

  return 0
}

rhel_is_installed() {
  local pkg_regex=$1

  local exit_code=0
  yum list installed --disableplugin subscription-manager 2> /dev/null | grep "$pkg_regex" > /dev/null 2>/dev/null || exit_code=$?

  if [[ $exit_code = "0" ]]; then echo "true"; else echo "false"; fi

  return 0
}

get_os_version() {
  os_info=$("$KI_OPT_SCRIPTS_PATH"/preflight/get-os-info.sh)

  os_distribution=$($YQ_CMD .distribution <<< "$os_info")
  os_major_version=$($YQ_CMD .major_version <<< "$os_info")
  os_minor_version=$($YQ_CMD .minor_version <<< "$os_info")
}

validate_ki_opt_directory() {
  require_directory_exists "$KI_OPT_SCRIPTS_PATH"
  require_directory_exists "$KI_OPT_BUNDLE_PATH"

  return 0
}

validate_venv_directory() {
  [[ ! -e $KI_OPT_VENV_PATH/bin/activate ]] && die "[ERROR] Invalid venv directory. activate script not exists"

  return 0
}

require_directory_exists() {
  local path=$1

  [[ ! -e $path ]] && die "[ERROR] No such file or directory of which path is \"$path\""
  [[ ! -d $path ]] && die "[ERROR] File[\"$path\"] is not a directory"

  return 0
}

main
