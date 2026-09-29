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
RHEL9_SUPPORTED_MINOR_VERSION=8
RHEL10_SUPPORTED_MINOR_VERSION=2

# The drop in ubuntu reads after its own file, and the record of what this put on
# the command line. Both carry the name of the installer, so a file here is never
# confused with one the site wrote and the reset knows what is its to remove
GRUB_DROP_IN_PATH=/etc/default/grub.d/99-ki-kernel-args.cfg
RECORD_PATH=/etc/k8s-installer/kernel-args

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

# The arguments this node was given the last time, one per line. Empty on a node
# this never ran on, which reads the same as a node that was given none
recorded_args() {
  [[ -f $RECORD_PATH ]] || return 0
  cat "$RECORD_PATH"

  return 0
}

kernel_cmdline_extra_args=""

# Puts the kernel command line arguments of this node where the bootloader reads
# them, and takes away the ones it put there before.
#
# What this is for is everything a node has to boot with that is not the iommu:
# hugepages reserved at boot, cpus isolated from the scheduler, a driver
# parameter. The vfio-pci component writes its own arguments and owns its own
# file - those are derived from the devices named in the inventory, while these
# are declared by whoever runs the cluster, and two owners writing one file is
# how a reset takes away more than it put there.
#
# Nothing here reboots. The arguments take effect at the next boot, and
# setup-boot-config.yml is where the reboot for both components sits
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory
  get_os_version

  kernel_cmdline_extra_args=$($yq_cmd '.kernel_cmdline_extra_args // [] | join(" ")' < "$vars_path")

  # Not "nothing to do". A node whose list was emptied is a node that has
  # arguments to take off, and the record is what says so
  if [[ -z $kernel_cmdline_extra_args && -z $(recorded_args) ]]; then
    msg "[INFO] No kernel command line argument given for this node"
    exit 0
  fi

  if [[ $os_distribution = "ubuntu" && $os_major_version = "22.04" && $os_minor_version -le "$UBUNTU2204_SUPPORTED_MINOR_VERSION" ]]; then
    ubuntu_setup
    report_state
    exit 0
  fi

  if [[ $os_distribution = "ubuntu" && $os_major_version = "24.04" && $os_minor_version -le "$UBUNTU2404_SUPPORTED_MINOR_VERSION" ]]; then
    ubuntu_setup
    report_state
    exit 0
  fi

  if [[ $os_distribution = "rhel" && $os_major_version = "8" && $os_minor_version -le "$RHEL8_SUPPORTED_MINOR_VERSION" ]]; then
    rhel_setup
    report_state
    exit 0
  fi

  if [[ $os_distribution = "rhel" && $os_major_version = "9" && $os_minor_version -le "$RHEL9_SUPPORTED_MINOR_VERSION" ]]; then
    rhel_setup
    report_state
    exit 0
  fi

  if [[ $os_distribution = "rhel" && $os_major_version = "10" && $os_minor_version -le "$RHEL10_SUPPORTED_MINOR_VERSION" ]]; then
    rhel_setup
    report_state
    exit 0
  fi

  die "[ERROR] OS not supported\n$os_info"
}

ubuntu_setup() {
  create_grub_drop_in_file
  write_record

  update-grub

  return 0
}

rhel_setup() {
  remove_recorded_grubby_args
  add_grubby_args
  write_record

  return 0
}

# A drop in rather than an edit of /etc/default/grub, so that the line of the
# site is left alone and removing this one file is the whole of the undo. ubuntu
# sources every file of that directory after the main one, which is what lets
# this append to whatever is already there.
#
# An empty list removes the file. The arguments of a node are what the inventory
# says they are, and a list that was emptied says none
create_grub_drop_in_file() {
  if [[ -z $kernel_cmdline_extra_args ]]; then
    rm -f "$GRUB_DROP_IN_PATH"
    return 0
  fi

  mkdir -p "$(dirname "$GRUB_DROP_IN_PATH")"
  cat > "$GRUB_DROP_IN_PATH" <<EOF
GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT $kernel_cmdline_extra_args"
EOF

  return 0
}

# rhel has no drop in directory for this, so grubby edits the entries and the
# record is what makes that reversible. grubby replaces an argument of the same
# name rather than repeating it, so adding is idempotent; what it can not know is
# which arguments used to be asked for and are not any more, and taking those off
# by hand is the difference between a node that boots with what the inventory
# says and one that boots with everything it has ever been told
remove_recorded_grubby_args() {
  local arg
  local name
  while IFS= read -r arg; do
    [[ -z $arg ]] && continue
    name=${arg%%=*}
    grep -qwF -- "$name" <<< "${kernel_cmdline_extra_args// /$'\n'}" && continue
    grubby --update-kernel=ALL --remove-args="$name"
  done < <(recorded_args)

  return 0
}

# Every argument in one call. grubby replaces an argument of the same name
# rather than repeating it, so asking for them one at a time collapses a
# repeated name to whichever came last: measured on rhel8.10, asking for
# "hugepagesz=1G hugepages=2 hugepagesz=2M hugepages=8" one at a time leaves
# only the 2M pair, and asking for all of them together leaves all four. The
# kernel reads a hugepages= as belonging to the hugepagesz= before it, so that
# repetition is the whole of how a node is given two page sizes
add_grubby_args() {
  grubby --update-kernel=ALL --args="$kernel_cmdline_extra_args"

  return 0
}

write_record() {
  if [[ -z $kernel_cmdline_extra_args ]]; then
    rm -f "$RECORD_PATH"
    return 0
  fi

  mkdir -p "$(dirname "$RECORD_PATH")"
  printf '%s\n' $kernel_cmdline_extra_args > "$RECORD_PATH"

  return 0
}

# What is true now, said plainly, because none of it is true until the node has
# been rebooted and a node that was never rebooted looks exactly like one where
# this did not work
report_state() {
  if [[ -z $kernel_cmdline_extra_args ]]; then
    msg "[INFO] Took the kernel command line arguments of this node away"
  else
    msg "[INFO] Configured kernelCmdlineExtraArgs[\"$kernel_cmdline_extra_args\"]"
  fi
  msg "[WARN] This node has to be rebooted before the command line changes"

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
