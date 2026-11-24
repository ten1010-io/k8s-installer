#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--node name] [--reserved-cpus set] [--cpu-manager-policy policy] [--full-pcpus-only bool]
Available options:
-h, --help            Print this help and exit
-v, --verbose         Print script debug info
--node                Name to report this node under
--reserved-cpus       The cpus this node is to keep for the system, as the
                      inventory names them. Nothing is checked without it
--cpu-manager-policy  The cpu manager policy this node is to run, none or static
--full-pcpus-only     Whether the static policy of this node hands out whole
                      cores only, true or false
EOF
  exit
}

parse_params() {
  node=""
  reserved_cpu_set=""
  cpu_manager_policy="none"
  full_pcpus_only="false"

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
    --reserved-cpus)
      # Empty is a node that names no set, which is most of them, and the
      # caller is spared from leaving the option out for those
      reserved_cpu_set="${2-}"
      shift
      ;;
    --cpu-manager-policy)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      cpu_manager_policy="${2-}"
      shift
      ;;
    --full-pcpus-only)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      full_pcpus_only="${2-}"
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

# How a set of cpus is laid over the cores and the numa nodes of this machine.
# See reserved-cpus-common.sh
source "$SCRIPT_DIR_PATH"/reserved-cpus-common.sh

# Says what is wrong with the cpus this node is to keep for the system, one line
# each, and nothing when the set fits the machine.
#
# The inventory is checked on the control node for whether the set is written as
# one. Whether its numbers are cpus of this machine, which numa node each is on
# and whether the two threads of a core are in it together are facts about the
# machine, so they are asked here, of the node, before the set is applied to it.
# Applying it is a node drained and its kubelet brought back, and a kubelet
# handed a set it can not use is one that does not come back.
#
# Two kinds of line, and which is which is the first word. [ERROR] is a set the
# caller is to refuse:
#
#  - a number that is not a cpu this node has online. kubelet refuses to start
#    with it, under any cpu manager policy
#  - under the static policy with full-pcpus-only, a core whose threads are not
#    reserved together. That option is the promise that no two workloads share a
#    core, and the thread left over is one no pod can be given as its own, so
#    the node gives up a cpu and the core is shared all the same
#
# [WARN] is a set that works and is probably not what was meant, under the
# static policy, which is where a cpu is somebody's alone:
#
#  - a core whose threads are not reserved together, without full-pcpus-only.
#    kubelet hands the other thread to a pod as an exclusive cpu, and that pod
#    shares its core with whatever the system runs on the reserved one
#  - numa nodes that are not reserved alike, or one with no reserved cpu or less
#    than a core of them. What is left to hand out then differs from one numa
#    node to the next, and a workload sized to fill a numa node fits on one side
#    of the machine and not on the other
#
# Printed to stdout for a playbook to collect and decide on, with rc 0 either
# way, the way check-kubelet-restart.sh and check-kernel-args.sh are. The values
# are given on the command line rather than read from the vars file of the node,
# so that this can be asked at any time, including at the end of a run when that
# file is gone
main() {
  [[ -n $reserved_cpu_set ]] || exit 0

  [[ -n $(online_cpu_list) ]] ||
    die "[ERROR] node[\"$node\"] does not say which cpus it has online in file[\"$CPU_SYSFS_PATH/online\"]"

  load_reserved_cpus "$reserved_cpu_set"

  report_absent_cpus

  if [[ $cpu_manager_policy = "static" ]]; then
    report_half_reserved_cores
    report_numa_spread
  fi

  exit 0
}

report_absent_cpus() {
  local absent
  absent=$(absent_reserved_cpus | paste -sd, -)

  [[ -n $absent ]] || return 0

  echo "[ERROR] node[\"$node\"] kubelet_reserved_system_cpus[\"$reserved_cpu_set\"] names cpus[\"$absent\"], which this node does not have online. it has cpus[\"$(online_cpu_list)\"]. kubelet does not start with a reserved cpu it does not have"

  return 0
}

report_half_reserved_cores() {
  local siblings
  local held
  local free

  while IFS=$'\t' read -r siblings held free; do
    if [[ $full_pcpus_only = "true" ]]; then
      echo "[ERROR] node[\"$node\"] kubelet_reserved_system_cpus[\"$reserved_cpu_set\"] reserves cpus[\"$held\"] of the core whose threads are cpus[\"$siblings\"] and not cpus[\"$free\"]. with full-pcpus-only kubelet hands out whole cores, so cpus[\"$free\"] is a cpu no pod can be given as its own, and what runs on the shared cpus still shares that core with the system. reserve the threads of a core together"
    else
      echo "[WARN] node[\"$node\"] kubelet_reserved_system_cpus[\"$reserved_cpu_set\"] reserves cpus[\"$held\"] of the core whose threads are cpus[\"$siblings\"] and not cpus[\"$free\"]. kubelet hands cpus[\"$free\"] to a pod as an exclusive cpu, and that pod shares its core with whatever the system runs on cpus[\"$held\"]. reserve the threads of a core together"
    fi
  done < <(half_reserved_core_lines)

  return 0
}

# What is said about the numa nodes is said once for the node rather than once
# for each of them: they are only uneven in relation to each other
report_numa_spread() {
  local id
  local count
  local whole
  local spread=""
  local empty=""
  local partial=""
  local -A counts=()

  while IFS=$'\t' read -r id count whole; do
    spread+="${spread:+, }numa[\"$id\"] $count"
    counts[$count]=1

    if [[ $count -eq 0 ]]; then
      empty+="${empty:+,}$id"
    elif [[ $whole -eq 0 ]]; then
      partial+="${partial:+,}$id"
    fi
  done < <(numa_reserved_lines)

  if [[ -n $empty ]]; then
    echo "[WARN] node[\"$node\"] kubelet_reserved_system_cpus[\"$reserved_cpu_set\"] reserves no cpu on numa[\"$empty\"]. every cpu of that numa node is handed out, and what the system runs there has none of its own"
  fi

  if [[ -n $partial ]]; then
    echo "[WARN] node[\"$node\"] kubelet_reserved_system_cpus[\"$reserved_cpu_set\"] reserves less than one whole core on numa[\"$partial\"]"
  fi

  if [[ ${#counts[@]} -gt 1 ]]; then
    echo "[WARN] node[\"$node\"] kubelet_reserved_system_cpus[\"$reserved_cpu_set\"] does not reserve the same number of cpus on every numa node: $spread. the cpus left to hand out differ from one numa node to the next"
  fi

  return 0
}

main
