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

UBUNTU2204_SUPPORTED_MINOR_VERSION=5
UBUNTU2404_SUPPORTED_MINOR_VERSION=4
RHEL8_SUPPORTED_MINOR_VERSION=10

KI_OPT_SCRIPTS_PATH="$ki_opt_root_path"/scripts
KI_OPT_BIN_PATH="$ki_opt_root_path"/bin
KI_OPT_VENV_PATH="$ki_opt_root_path"/venv

YQ_CMD="$KI_OPT_BIN_PATH"/bin/yq

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
    export DEBIAN_FRONTEND=noninteractive
    dpkg -R -i "$KI_OPT_BIN_PATH"/linux-packages/ubuntu22.04/python3.10
    dpkg -i "$KI_OPT_BIN_PATH"/linux-packages/ubuntu22.04/python3/python3-minimal*
    dpkg -R -i "$KI_OPT_BIN_PATH"/linux-packages/ubuntu22.04/python3
    dpkg -R -i "$KI_OPT_BIN_PATH"/linux-packages/ubuntu22.04/python3-distutils
    dpkg -R -i "$KI_OPT_BIN_PATH"/linux-packages/ubuntu22.04/python3.10-venv
    export DEBIAN_FRONTEND=""
  fi

  if [[ -e $KI_OPT_VENV_PATH ]]; then
    msg "[INFO] K8s installer will use existing venv"
  else
    msg "[INFO] K8s installer will create virtual environment[\"venv\"]"

    python3.10 -m venv "$KI_OPT_VENV_PATH"
    "$KI_OPT_VENV_PATH"/bin/pip3.10 install --no-index -f "$KI_OPT_BIN_PATH"/python-packages/python3.10/netifaces netifaces
    "$KI_OPT_VENV_PATH"/bin/pip3.10 install --no-index -f "$KI_OPT_BIN_PATH"/python-packages/python3.10/jinja2-cli jinja2-cli PyYAML
    "$KI_OPT_VENV_PATH"/bin/pip3.10 install --no-index -f "$KI_OPT_BIN_PATH"/python-packages/python3.10/ansible ansible jmespath
    "$KI_OPT_VENV_PATH"/bin/pip3.10 install --no-index -f "$KI_OPT_BIN_PATH"/python-packages/python3.10/pydantic pydantic
  fi

  validate_venv_directory

  msg ""
  msg "[INFO] To activate venv, run the following"
  msg "source $KI_OPT_VENV_PATH/bin/activate"

  return 0
}

ubuntu2404_setup() {
  if [[ $(ubuntu2404_is_installed python3\.12-venv) = "false" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    dpkg -R -i "$KI_OPT_BIN_PATH"/linux-packages/ubuntu24.04/python3.12
    dpkg -R -i "$KI_OPT_BIN_PATH"/linux-packages/ubuntu24.04/python3.12-venv
    export DEBIAN_FRONTEND=""
  fi

  if [[ -e $KI_OPT_VENV_PATH ]]; then
    msg "[INFO] K8s installer will use existing venv"
  else
    msg "[INFO] K8s installer will create virtual environment[\"venv\"]"

    python3.12 -m venv "$KI_OPT_VENV_PATH"
    "$KI_OPT_VENV_PATH"/bin/pip3.12 install --no-index -f "$KI_OPT_BIN_PATH"/python-packages/python3.12/netifaces netifaces
    "$KI_OPT_VENV_PATH"/bin/pip3.12 install --no-index -f "$KI_OPT_BIN_PATH"/python-packages/python3.12/jinja2-cli jinja2-cli PyYAML
    "$KI_OPT_VENV_PATH"/bin/pip3.12 install --no-index -f "$KI_OPT_BIN_PATH"/python-packages/python3.12/ansible ansible jmespath
    "$KI_OPT_VENV_PATH"/bin/pip3.12 install --no-index -f "$KI_OPT_BIN_PATH"/python-packages/python3.12/pydantic pydantic
  fi

  validate_venv_directory

  msg ""
  msg "[INFO] To activate venv, run the following"
  msg "source $KI_OPT_VENV_PATH/bin/activate"

  return 0
}

rhel8_setup() {
  if [[ $(rhel8_is_installed python3\.12) = "false" ]]; then
    rpm --force -Uvh --oldpackage --replacepkgs "$KI_OPT_BIN_PATH/linux-packages/rhel8/chkconfig/*.rpm"
    rpm --force -Uvh --oldpackage --replacepkgs "$KI_OPT_BIN_PATH/linux-packages/rhel8/python3.12/*.rpm"
  fi

  if [[ -e $KI_OPT_VENV_PATH ]]; then
    msg "[INFO] K8s installer will use existing venv"
  else
    msg "[INFO] K8s installer will create virtual environment[\"venv\"]"

    python3.12 -m venv "$KI_OPT_VENV_PATH"
    "$KI_OPT_VENV_PATH"/bin/pip3.12 install --no-index -f "$KI_OPT_BIN_PATH"/python-packages/python3.12/netifaces netifaces
    "$KI_OPT_VENV_PATH"/bin/pip3.12 install --no-index -f "$KI_OPT_BIN_PATH"/python-packages/python3.12/jinja2-cli jinja2-cli PyYAML
    "$KI_OPT_VENV_PATH"/bin/pip3.12 install --no-index -f "$KI_OPT_BIN_PATH"/python-packages/python3.12/ansible ansible jmespath
    "$KI_OPT_VENV_PATH"/bin/pip3.12 install --no-index -f "$KI_OPT_BIN_PATH"/python-packages/python3.12/pydantic pydantic
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

rhel8_is_installed() {
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
  require_directory_exists "$KI_OPT_BIN_PATH"

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
