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

ki_etc_root_path=""
# Where the kernel arguments this put on the boot entries of a rhel8 node are
# written down, so that the reset takes off what this put on and nothing else
kernel_args_path=""

yq_cmd=""
jinja2_cmd=""

os_info=""
os_distribution=""
os_major_version=""
os_minor_version=""

vfio_pci_device_ids=""
iommu_kernel_args=""
# The iommu arguments and the ids, which is the whole of what goes on the kernel
# line. The ids are there because modprobe options do not reach a vfio-pci that
# is built into the kernel rather than loaded as a module
kernel_args=""

# Binds the pci devices of this node that the inventory named to vfio-pci, so
# that a virtual machine can be given one.
#
# Doing nothing is the normal case: a node with no vfio_pci_device_ids is left
# exactly as it was, and neither the bootloader nor the initramfs is touched.
#
# What a device needs before a guest can have it is three things that all have to
# be true at boot: the iommu on, the vfio modules in the initramfs, and the ids
# claimed before the driver of the vendor loads. So this writes configuration and
# the node takes it at its next boot. Nothing here reboots anything
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory
  get_os_version

  ki_etc_root_path=$($yq_cmd '.ki_etc_root_path' < "$vars_path")
  kernel_args_path="$ki_etc_root_path/$KERNEL_ARGS_FILE_NAME"

  vfio_pci_device_ids=$($yq_cmd '.vfio_pci_device_ids // [] | join(",")' < "$vars_path")

  # Not simply nothing to do. A node whose ids were taken out of the inventory
  # still carries what an earlier run wrote and would go on binding its cards at
  # every boot, so the reset is what answers an empty list. It decides from the
  # files it finds, which is how a node that never had a card is still left
  # exactly as it was: neither the bootloader nor the initramfs is opened
  if [[ -z $vfio_pci_device_ids ]]; then
    msg "[INFO] No vfio pci device id given for this node"
    exec "$ki_opt_scripts_path"/k8s-node/vfio-pci/reset-vfio-pci.sh --vars-path "$vars_path"
  fi

  require_vfio_pci_devices_exist
  set_iommu_kernel_args
  set_kernel_args

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
    rhel8_setup
    report_state
    exit 0
  fi

  die "[ERROR] OS not supported\n$os_info"
}

ubuntu_setup() {
  create_modules_load_file
  create_modprobe_file
  create_initramfs_modules_block
  create_grub_drop_in_file

  update-initramfs -u -k all
  update-grub

  return 0
}

rhel8_setup() {
  create_modules_load_file
  create_modprobe_file
  create_dracut_file
  add_grubby_kernel_args

  dracut -f --regenerate-all

  return 0
}

# A typo in an id is a node configured for a device it does not have, and nothing
# about the run says so: every file is written, the report says "Configured", and
# it shows up only after a reboot as "passthrough does not work", which is the
# one state this is unable to tell apart from a node that was never rebooted.
# Refused here instead, the way a node told it has a gpu it does not have is
# refused. See require_nvidia_gpu_exists of setup-containerd.sh
require_vfio_pci_devices_exist() {
  local id
  local missing=()

  for id in ${vfio_pci_device_ids//,/ }; do
    if [[ -z $(sysfs_paths_of_device_id "$id") ]]; then
      missing+=("$id")
    fi
  done

  [[ ${#missing[@]} -gt 0 ]] &&
    die "[ERROR] No pci device of vfioPciDeviceIds[\"${missing[*]}\"] on this node"

  return 0
}

# Which of the two the processor of this node needs. Read from the processor
# rather than taken as a variable, because it is a fact about the machine and
# getting it wrong is a node that boots with an iommu that never comes up
set_iommu_kernel_args() {
  local vendor_id
  vendor_id=$(grep -m1 -oP '^vendor_id\s*:\s*\K.+' /proc/cpuinfo || true)

  case "$vendor_id" in
    GenuineIntel) iommu_kernel_args="intel_iommu=on iommu=pt" ;;
    AuthenticAMD) iommu_kernel_args="amd_iommu=on iommu=pt" ;;
    *) die "[ERROR] Can not tell which iommu this node needs from vendorId[\"$vendor_id\"]" ;;
  esac

  return 0
}

# The ids go on the kernel line as well as into the modprobe options, because a
# kernel can carry vfio-pci built in rather than as a module. modprobe.d is only
# read for a module that modprobe loads, so on such a kernel "options vfio-pci
# ids=..." reaches nothing and the cards come up on the driver of their vendor -
# with every file this writes looking exactly as it does on a working node. The
# softdep lines are a no op there for the same reason: there is no module load to
# order. A built in driver takes its parameters from the kernel line only.
#
# Harmless where vfio-pci is a module: the kernel holds the value and hands it
# over when the module loads, which is the same value modprobe.d gives it
set_kernel_args() {
  kernel_args="$iommu_kernel_args vfio-pci.ids=$vfio_pci_device_ids"

  return 0
}

create_modules_load_file() {
  mkdir -p "$(dirname "$MODULES_LOAD_PATH")"
  printf '%s\n' "${VFIO_MODULES[@]}" > "$MODULES_LOAD_PATH"

  return 0
}

# The ids are claimed by vfio-pci, and the drivers that would otherwise claim the
# same card are told to let it load first. softdep rather than a blacklist: a
# blacklist is about a driver and this is about a device, and a node holding two
# cards of which only one is passed through still needs the other one driven
create_modprobe_file() {
  local driver

  mkdir -p "$(dirname "$MODPROBE_PATH")"
  {
    echo "options vfio-pci ids=$vfio_pci_device_ids"
    for driver in $(vendor_drivers_of_device_ids); do
      echo "softdep $driver pre: vfio-pci"
    done
  } > "$MODPROBE_PATH"

  return 0
}

# The modules that would claim the cards named for this node, asked of the node
# rather than written down here. A list written down covers the cards whoever
# wrote it thought of, and handing a guest an amd card or a nic is the same
# operation as handing it an nvidia one.
#
# Resolved from the modalias of each device, which is what the device says it is
# and does not change with what is bound to it. Reading the driver currently
# bound would answer vfio-pci itself on every run after the first reboot, and
# write a softdep of vfio-pci on itself
vendor_drivers_of_device_ids() {
  local path
  local driver

  for path in $(sysfs_paths_of_device_ids "$vfio_pci_device_ids"); do
    [[ -f $path/modalias ]] || continue
    for driver in $(modprobe -R "$(< "$path"/modalias)" 2>/dev/null || true); do
      if [[ $driver != "vfio-pci" && $driver != "vfio_pci" ]]; then
        echo "$driver"
      fi
    done
  done | sort -u

  return 0
}

# The file belongs to the distribution and holds whatever else the site put in
# it, so the block between the markers is what this owns. Rewritten rather than
# appended to, or a second run leaves the modules named twice
create_initramfs_modules_block() {
  mkdir -p "$(dirname "$INITRAMFS_MODULES_PATH")"
  touch "$INITRAMFS_MODULES_PATH"
  delete_initramfs_modules_block

  {
    echo "$INITRAMFS_BEGIN"
    printf '%s\n' "${VFIO_MODULES[@]}"
    echo "$INITRAMFS_END"
  } >> "$INITRAMFS_MODULES_PATH"

  return 0
}

create_dracut_file() {
  mkdir -p "$(dirname "$DRACUT_PATH")"
  echo "add_drivers+=\" ${VFIO_MODULES[*]} \"" > "$DRACUT_PATH"

  return 0
}

# A drop in rather than an edit of /etc/default/grub, so that the line of the
# site is left alone and removing this file is the whole of the undo. ubuntu
# sources every file of that directory after the main one, which is what lets
# this append to what is already there
create_grub_drop_in_file() {
  mkdir -p "$(dirname "$GRUB_DROP_IN_PATH")"
  cat > "$GRUB_DROP_IN_PATH" <<EOF
GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT $kernel_args"
EOF

  return 0
}

# rhel8 has no drop in directory for this, so grubby edits the entries. Every
# argument is simply asked for: grubby replaces one of the same name rather than
# leaving a second copy of it on the line.
#
# What decides ownership is read from the boot entries, which are what is being
# edited, and not from /proc/cmdline, which is the kernel that happens to be
# running. A node whose entries were reset but which has not been rebooted still
# carries the arguments in /proc/cmdline, and that node is exactly the one that
# needs them put back.
#
# The ones that were not already there are written down, so that the reset takes
# off what this put on. A node whose image already carried intel_iommu=on is a
# node this added nothing to, and taking it away later would be taking away a
# setting the site owns
add_grubby_kernel_args() {
  local entries
  entries=$(grubby --info=ALL)

  local arg
  for arg in $kernel_args; do
    if ! every_boot_entry_has "$entries" "$arg"; then
      record_owned_kernel_arg "${arg%%=*}"
    fi

    grubby --update-kernel=ALL --args="$arg"
  done

  return 0
}

# Added to rather than rewritten, and by name rather than as a whole argument.
#
# Rewritten, a second run empties it: it finds the arguments already on the line,
# has nothing to record, and the node loses what the first run owned.
# upgrade-k8s-nodes.yml runs the setup again on every upgrade, so that is every
# node of every cluster, and the reset would then leave the arguments on the boot
# entries for ever.
#
# By name, because the ids can change. grubby removes an argument by its name, so
# a record of vfio-pci.ids takes off whatever value the line carries rather than
# only the value that was there when it was written. Removing by name is also
# exact: taking off "iommu" leaves an "intel_iommu" the site owns alone
record_owned_kernel_arg() {
  local name=$1

  mkdir -p "$(dirname "$kernel_args_path")"
  touch "$kernel_args_path"
  grep -qxF "$name" "$kernel_args_path" || echo "$name" >> "$kernel_args_path"

  return 0
}

# An argument only some of the entries carry is one this puts on the rest, and
# owns from then on
every_boot_entry_has() {
  local entries=$1
  local arg=$2

  local total
  local holding
  total=$(grep -c '^args=' <<< "$entries" || true)
  holding=$(grep '^args=' <<< "$entries" | grep -cw -- "$arg" || true)

  [[ $total -gt 0 && $total -eq $holding ]]
}

# What is true now, said plainly, because none of it is true until the node has
# been rebooted and a node that was never rebooted looks exactly like one where
# this did not work
report_state() {
  msg "[INFO] Configured vfioPciDeviceIds[\"$vfio_pci_device_ids\"] with kernelArgs[\"$kernel_args\"]"
  msg "[INFO] The iommu of this node is currently $(iommu_state)"
  booted_with_vfio_pci_config ||
    msg "[WARN] This node has to be rebooted before any of it applies"

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
