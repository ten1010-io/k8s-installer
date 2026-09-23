#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--node name] [id...]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--node          Name to report this node under
EOF
  exit
}

parse_params() {
  node=""

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --node)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      node="${2-}"
      shift
      ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ -z "${node-}" ]] && die "[ERROR] Missing required option: --node"

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

# The paths and the sysfs lookups, which have to be the same in every script of
# this directory. See vfio-pci-common.sh
source "$SCRIPT_DIR_PATH"/vfio-pci-common.sh

# Says whether this node has actually taken the vfio-pci configuration written
# for it, rather than whether that configuration was written.
#
# Nothing the setup writes is true until the node has been rebooted, and the
# installer reboots nothing, so a node carrying the configuration and a node
# where it worked look the same from the outside. This is what tells them apart,
# by asking the only question that settles it: is every device the inventory
# named bound to vfio-pci right now, on a node whose iommu is up.
#
# It reports and does not fail. A node still waiting for a reboot is not a broken
# node, and whoever can reboot it may not be whoever is running this. What
# matters is that it goes on saying so until it is done, which is why the report
# goes to stdout for a playbook to collect and repeat at the end of every run.
#
# The ids are arguments rather than something read out of the vars file of the
# node, so that this can be run at any time, including after reset-vars-file.yml
# has taken that file away and by an operator who has just rebooted a node and
# come back to confirm it. check-cert-expiry.sh is the same shape for the same
# reason
main() {
  # A node that names no device has nothing to take, which is most of them
  [[ ${#args[@]} -gt 0 ]] || exit 0

  report_unapplied_devices

  exit 0
}

# Silence is the report when everything is where it should be. The playbook only
# prints what comes back, so a node doing its job costs the operator no line.
#
# The iommu has to be up as well as every device bound. A device can be bound to
# vfio-pci on a node whose iommu never came up, and no guest can be given it
# there, so bound is not on its own what is being asked about
report_unapplied_devices() {
  local lines
  lines=$(device_lines)

  if [[ $(iommu_state) = "on" ]] && ! grep -qv 'driver\["vfio-pci"\]$' <<< "$lines"; then
    return 0
  fi

  echo "[WARN] node[\"$node\"] names vfio-pci devices that are not bound to vfio-pci"
  echo "  iommu: $(iommu_state)"
  echo "$lines" | sed 's/^/  /'
  explain_state
  echo "  Then: ansible-playbook -i inventory.yml playbooks/tasks/check-vfio-pci.yml"

  return 0
}

# One line per device the inventory named, whether or not it is where it should
# be. An id that is on no device of this node is its own answer: the setup
# refuses an id it can not find, so one that has gone missing since means the
# card was moved or pulled
device_lines() {
  local id
  local path
  local found

  for id in "${args[@]}"; do
    found="false"
    for path in $(sysfs_paths_of_device_id "$id"); do
      found="true"
      echo "$id at $(basename "$path") group[\"$(iommu_group_of_sysfs_path "$path")\"] driver[\"$(driver_of_sysfs_path "$path")\"]"
    done

    [[ $found = "true" ]] || echo "$id is not on this node"
  done

  return 0
}

# Which of the four failures this is. They need different things done and the
# list above does not distinguish them on its own.
#
# Nothing written at all is the first, and it is not a node waiting for a reboot:
# the inventory names devices for it and setup-vfio-pci.sh has never run there.
# update-cluster.yml is the way into it - it applies variables but does not
# provision, so a node given ids after it was built sits here until add-node.yml
# or an install reaches it. Saying "reboot the node" to that would be wrong.
#
# After that, the question is whether the node is running with what was written
# for it, and the ids on the kernel command line are what answer it rather than
# the state of the iommu. An iommu is on for whatever reason the site has of its
# own: a host worth passing cards out of is very likely to have had intel_iommu=on
# in /etc/default/grub before this ever ran, and reading that as "rebooted since"
# sends whoever is holding the report off to read initramfs files when all the
# node wants is a reboot. Asking after the ids instead is exact, and it also
# catches the node whose ids were changed after its last boot, which looks
# entirely healthy to the iommu.
#
# A node that did boot with them and has no iommu even so is the third, and it is
# the one thing here that nothing written to the node can fix. The argument asking
# for an iommu was on the command line and the machine came up without one, so it
# is not offering one: vt-d or amd-vi is off in its firmware, or it is a guest
# nobody gave an iommu to. Telling that node to reboot, which the state of the
# iommu on its own would, is telling it to do the thing that just failed.
#
# The fourth is a node that booted with the ids, has its iommu up, and still has a
# device on the driver of its vendor: both reached it and the initramfs or the
# modprobe options did not reach the device
explain_state() {
  if [[ ! -f $MODPROBE_PATH ]]; then
    echo "  Nothing has been written to this node. The inventory names devices for it and"
    echo "  the setup has not run here, which update-cluster.yml does not do. Build the node"
    echo "  with add-node.yml, or run the install if the cluster is being created"
    return 0
  fi

  if ! booted_with_vfio_pci_config; then
    echo "  This node is not running with the kernel command line this wrote. It carries"
    echo "  ids[\"$(configured_vfio_pci_device_ids)\"] and booted with ids[\"$(booted_vfio_pci_device_ids)\"]"
    echo "  Reboot the node. Cordon and drain it first if it is already carrying pods"
    return 0
  fi

  if [[ $(iommu_state) = "off" ]]; then
    echo "  This node booted with intel_iommu or amd_iommu on the command line and came up"
    echo "  with no iommu anyway, which vfio-pci can not work without - the devices above"
    echo "  are in no iommu group at all. Another reboot will not change it and there is"
    echo "  nothing to fix in what was written here. The machine is not offering one:"
    echo "  turn on VT-d or AMD-Vi in its firmware, and on a virtual machine give the guest"
    echo "  an iommu of its own"
    return 0
  fi

  echo "  The node booted with the command line this wrote and its iommu is up, so both"
  echo "  reached it. A device still on the driver of its vendor means the initramfs or the"
  echo "  modprobe options did not, which wants looking at on this node rather than another"
  echo "  reboot"

  return 0
}

main
