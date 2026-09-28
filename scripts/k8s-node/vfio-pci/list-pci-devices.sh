#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--node name] [--all]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--node          Name to report this node under
--all           Include pci bridges, which are left out by default
EOF
  exit
}

parse_params() {
  node=""
  all="false"

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --all) all="true" ;;
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

# Where the kernel publishes which cpus belong to which numa node. Not a pci
# path, and read here because the two answers are read together: the numa node a
# device sits on is only useful beside the cpus of that node. Overridable for the
# same reason PCI_DEVICES_PATH is, so that this can be pointed at a directory of
# fixtures and checked without a machine that has two sockets
NUMA_NODES_PATH=${NUMA_NODES_PATH:-/sys/devices/system/node}

# The pci class codes worth naming. Unlike the drivers of a card, which are a
# fact about the machine and are asked of it, these are a fixed enumeration of
# the pci specification, so writing them down is reading a constant rather than
# guessing. Anything not here prints its code
declare -A CLASS_NAMES=(
  [0106]="SATA controller"
  [0108]="NVMe controller"
  [0200]="Ethernet controller"
  [0207]="Infiniband controller"
  [0300]="VGA controller"
  [0302]="3D controller"
  [0403]="Audio device"
  [0c03]="USB controller"
  [0c04]="Fibre Channel"
  [1200]="Processing accelerator"
)

# Lists the pci devices of this node, so that whoever is deciding what to pass
# through can read the ids off a playbook instead of logging into every machine.
#
# Grouped by iommu group, which is the decision actually being made and the one
# thing lspci does not put in front of you. A group goes to a guest whole or not
# at all, so the gpu and the audio function sharing group 61 are a pair that has
# to be named together, while the onboard audio in its own group is the same
# driver and must be left alone.
#
# Each device also carries the numa node it sits on, and the cpus of every numa
# node are printed above the list. Those two decide kubelet_reserved_system_cpus
# and whether kubelet_topology_manager_policy single-numa-node can be satisfied at
# all: a guest given cpus on the other side of the machine reaches its own card
# across the interconnect, and nothing reports that as anything but slow.
#
# Read from sysfs rather than from lspci: lspci comes from pciutils and the
# bundle does not carry it. The cost is that the vendor and device names are not
# available, since those live in the pci.ids file that same package ships. The
# driver a device is on says more here anyway. The cpu lists come from sysfs for
# the same reason lscpu is not called
main() {
  local state
  state=$(iommu_state)

  echo "[INFO] node[\"$node\"] iommu: $state"

  if [[ $state = "off" ]]; then
    echo "  Groups are not shown. A device is only put in an iommu group once the node has"
    echo "  booted with its iommu on, so the ids below are complete and the grouping is not"
  fi

  numa_lines

  device_lines | sort | cut -f2-

  exit 0
}

# The cpus of each numa node, which is the half of the answer the device list can
# not carry. Sorted by number and not by name: the glob puts node10 before node2,
# and a machine with that many nodes is exactly the machine this is for.
#
# A machine with no numa sysfs at all is one the kernel sees as uniform, and
# saying so is the answer rather than the absence of one. It says it under the
# same key as the rest, so that one grep finds the numa lines of any machine
numa_lines() {
  local path
  local id

  if ! compgen -G "$NUMA_NODES_PATH/node*/cpulist" > /dev/null; then
    echo '[INFO] numa["-"] cpus["-"] no numa sysfs on this kernel, so every cpu is one pool'
    return 0
  fi

  for path in "$NUMA_NODES_PATH"/node*; do
    [[ -f $path/cpulist ]] || continue

    id=${path##*/node}
    printf '%s\t[INFO] numa["%s"] cpus["%s"]\n' "$id" "$id" "$(cpu_list_of_numa_path "$path")"
  done | sort -n | cut -f2-

  return 0
}

# The cpus of one numa node, or - for a node that has none. An empty cpulist is a
# memory only node - hbm in flat mode, a cxl expander, or a node whose cpus are
# all offline - and an empty string there reads like a read that failed rather
# than like a node with nothing to pin to
cpu_list_of_numa_path() {
  local path=$1
  local value

  value=$(< "$path"/cpulist)
  [[ -n $value ]] || { echo "-"; return 0; }

  echo "$value"

  return 0
}

# One line per device, each prefixed with a sort key so that the devices of a
# group come out together and an ungrouped node still comes out in slot order
device_lines() {
  local path
  local slot
  local id
  local group

  for path in "$PCI_DEVICES_PATH"/*; do
    [[ -f $path/vendor && -f $path/device && -f $path/class ]] || continue

    if [[ $all = "false" ]] && is_bridge "$path"; then
      continue
    fi

    slot=$(basename "$path")
    id="$(hex4 "$path"/vendor):$(hex4 "$path"/device)"
    group=$(iommu_group_of_sysfs_path "$path")

    printf '%s\t%-12s %-14s %-12s %-12s %-24s %s\n' \
      "${group:-zzz}$slot" \
      "group[\"${group:--}\"]" \
      "$slot" \
      "$id" \
      "numa[\"$(numa_node_of_sysfs_path "$path")\"]" \
      "$(class_name "$path")" \
      "driver[\"$(driver_of_sysfs_path "$path")\"]"
  done

  return 0
}

# The numa node a device is attached to. The kernel writes -1 when it has no
# answer - a machine with one node, or firmware that did not say - and that is
# reported as unknown rather than as node -1, which would read like a place
numa_node_of_sysfs_path() {
  local path=$1
  local value

  [[ -f $path/numa_node ]] || { echo "-"; return 0; }

  value=$(< "$path"/numa_node)
  [[ $value = "-1" ]] && { echo "-"; return 0; }

  echo "$value"

  return 0
}

# A bridge is structure rather than a device anyone passes through, and a node
# has enough of them to bury everything else
is_bridge() {
  local path=$1

  [[ $(class_code "$path") = 06* ]]
}

class_name() {
  local path=$1
  local code

  code=$(class_code "$path")
  echo "${CLASS_NAMES[$code]-class[\"$code\"]}"
}

# sysfs writes these as 0x10de and the inventory writes them as 10de
hex4() {
  local value

  value=$(< "$1")
  echo "${value#0x}"
}

main
