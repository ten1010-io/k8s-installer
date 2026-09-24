#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--vars-path path]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--vars-path     File path
EOF
  exit
}

parse_params() {
  vars_path=""

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --vars-path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      vars_path="${2-}"
      shift
      ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ -z "${vars_path-}" ]] && die "[ERROR] Missing required option: --vars-path"

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

# The paths, the markers and the sysfs lookups, which have to be the same in
# every script of this directory. See vfio-pci-common.sh
source "$SCRIPT_DIR_PATH"/vfio-pci-common.sh

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""
jinja2_cmd=""

os_info=""
os_distribution=""
os_major_version=""
os_minor_version=""

ki_etc_root_path=""
# The names of the kernel arguments setup-vfio-pci.sh put on the boot entries of
# this node. Read rather than worked out again, so that an argument the site had
# on the line before the installer ever ran is left where it is
kernel_args_path=""

# Takes the vfio-pci configuration of this node away, so that a node the cluster
# no longer holds is not left booting with its cards bound to nothing.
#
# The devices keep their binding until the node is rebooted, the same way they
# only got it at a boot
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory
  get_os_version

  ki_etc_root_path=$($yq_cmd '.ki_etc_root_path' < "$vars_path")
  kernel_args_path="$ki_etc_root_path/$KERNEL_ARGS_FILE_NAME"

  # Nothing to do on a node this never ran on, which is every node without a
  # card. Keyed on the files rather than on the variable, so that a node whose
  # ids were taken out of the inventory before this ran is still cleaned up
  has_vfio_pci_config "$kernel_args_path" || exit 0

  if [[ $os_distribution = "ubuntu" && $os_major_version = "22.04" && $os_minor_version -le "$UBUNTU2204_SUPPORTED_MINOR_VERSION" ]]; then
    ubuntu_reset
    exit 0
  fi

  if [[ $os_distribution = "ubuntu" && $os_major_version = "24.04" && $os_minor_version -le "$UBUNTU2404_SUPPORTED_MINOR_VERSION" ]]; then
    ubuntu_reset
    exit 0
  fi

  if [[ $os_distribution = "rhel" && $os_major_version = "8" && $os_minor_version -le "$RHEL8_SUPPORTED_MINOR_VERSION" ]]; then
    rhel8_reset
    exit 0
  fi

  die "[ERROR] OS not supported\n$os_info"
}

ubuntu_reset() {
  rm -f "$MODULES_LOAD_PATH"
  rm -f "$MODPROBE_PATH"
  rm -f "$GRUB_DROP_IN_PATH"
  remove_cdi_refresh_drop_in
  delete_initramfs_modules_block

  update-initramfs -u -k all
  update-grub

  return 0
}

rhel8_reset() {
  rm -f "$MODULES_LOAD_PATH"
  rm -f "$MODPROBE_PATH"
  rm -f "$DRACUT_PATH"
  remove_cdi_refresh_drop_in
  remove_grubby_kernel_args

  dracut -f --regenerate-all

  return 0
}

# The names of the arguments setup-vfio-pci.sh wrote down as its own. One that
# was already on the line when the setup first ran is not among them: the node
# was given it by whoever built the image, and this is not the thing that takes
# it away. Names rather than whole arguments, so that an id changed since is
# still taken off
remove_grubby_kernel_args() {
  [[ -f $kernel_args_path ]] || return 0

  local name
  while read -r name; do
    [[ -n $name ]] || continue
    grubby --update-kernel=ALL --remove-args="$name"
  done < "$kernel_args_path"

  rm -f "$kernel_args_path"

  return 0
}

import_ki_opt_vars() {
  ki_opt_root_path=$(grep -oP  "^ki_opt_root_path: \K(.+)" < "$vars_path")
  ki_opt_scripts_path=$(grep -oP  "^ki_opt_scripts_path: \K(.+)" < "$vars_path")
  ki_opt_bundle_path=$(grep -oP  "^ki_opt_bundle_path: \K(.+)" < "$vars_path")
  ki_opt_venv_path=$(grep -oP  "^ki_opt_venv_path: \K(.+)" < "$vars_path")
}

get_os_version() {
  os_info=$("$ki_opt_scripts_path"/preflight/get-os-info.sh)

  os_distribution=$($yq_cmd .distribution <<< "$os_info")
  os_major_version=$($yq_cmd .major_version <<< "$os_info")
  os_minor_version=$($yq_cmd .minor_version <<< "$os_info")
}

setup_cmd_vars() {
  yq_cmd="$ki_opt_bundle_path/bin/yq"
  jinja2_cmd="$ki_opt_venv_path/bin/jinja2"
}

validate_ki_opt_directory() {
  require_directory_exists "$ki_opt_scripts_path"
  require_directory_exists "$ki_opt_bundle_path"
  require_directory_exists "$ki_opt_venv_path"

  return 0
}

require_file_exists() {
  local path=$1

  [[ ! -e $path ]] && die "[ERROR] No such file or directory of which path is \"$path\""
  [[ ! -f $path ]] && die "[ERROR] File[\"$path\"] is not a regular file"

  return 0
}

require_directory_exists() {
  local path=$1

  [[ ! -e $path ]] && die "[ERROR] No such file or directory of which path is \"$path\""
  [[ ! -d $path ]] && die "[ERROR] File[\"$path\"] is not a directory"

  return 0
}

main
