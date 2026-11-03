#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--node name] [--metrics-path path]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--node          Name to report this node under
--metrics-path  Write what was measured to this file, in the prometheus text
                format a node exporter textfile collector reads, instead of
                printing it
EOF
  exit
}

parse_params() {
  node=""
  metrics_path=""

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
    --metrics-path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      metrics_path="${2-}"
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

# The configuration kubelet is running with. kubeadm writes it from the cluster
# baseline and the patch of this node, and it is the file kubelet is started
# with, so it is what the node runs rather than what the inventory meant
KUBELET_CONFIG_PATH=/var/lib/kubelet/config.yaml

# Says which cpu, memory and topology policies kubelet runs under on this node,
# for a monitoring system to read.
#
# What this is for is a node whose pods are virtual machines pinned to a numa
# node: a scheduler sends them to the node for its label, and whether the node
# actually pins is decided by three keys in a file on the node that nothing
# outside it can see. A label and a policy drift apart the moment somebody edits
# one of them, and the pod that lands on the wrong kind of node runs - slower, or
# across the interconnect from its gpu - rather than failing. Exporting the
# policies beside the label is what lets the two be compared.
#
# Read off the file rather than asked of kubelet. kubelet does answer, over
# /configz with a client certificate, and the file is what that answer is made
# from. A kubelet that is not running has no /configz and still has the file,
# and the file is what it will come up with
main() {
  local cpu_static=0
  local memory_static=0
  local topology_policy

  [[ $(policy_of cpuManagerPolicy none) = "static" ]] && cpu_static=1
  # kubelet spells this one with a capital, Static and None
  [[ $(policy_of memoryManagerPolicy None) = "Static" ]] && memory_static=1
  topology_policy=$(policy_of topologyManagerPolicy none)

  if [[ -n $metrics_path ]]; then
    write_metrics_file "$cpu_static" "$memory_static" "$topology_policy"
  else
    print_metrics "$cpu_static" "$memory_static" "$topology_policy"
  fi

  exit 0
}

# The value of a top level key of the kubelet configuration, or the default
# kubelet applies when the key is not written. The file is one document with its
# policies at the top level, which is how kubeadm writes it, so a key is the line
# that starts with its name. A node with no file at all - kubelet not installed,
# or taken away - runs no policy, and the defaults are the answer for it too
policy_of() {
  local key=$1
  local default=$2
  local value=""

  [[ -f $KUBELET_CONFIG_PATH ]] &&
    value=$(grep -oP "^$key:\s*\K\S+" "$KUBELET_CONFIG_PATH" | tr -d '"' || true)

  echo "${value:-$default}"

  return 0
}

print_metrics() {
  metrics_text "$1" "$2" "$3"

  return 0
}

metrics_text() {
  cat <<EOF
# HELP ki_node_kubelet_cpu_manager_static Whether kubelet of this node gives whole cpus to Guaranteed pods that ask for them
# TYPE ki_node_kubelet_cpu_manager_static gauge
ki_node_kubelet_cpu_manager_static $1
# HELP ki_node_kubelet_memory_manager_static Whether kubelet of this node pins the memory of Guaranteed pods to a numa node
# TYPE ki_node_kubelet_memory_manager_static gauge
ki_node_kubelet_memory_manager_static $2
# HELP ki_node_kubelet_topology_manager_policy The topology manager policy kubelet of this node runs under, in the label
# TYPE ki_node_kubelet_topology_manager_policy gauge
ki_node_kubelet_topology_manager_policy{policy="$3"} 1
EOF
}

# Replaced rather than appended to, and moved into place, because a collector
# reads whatever is there when it is scraped. check-kernel-args.sh is the same
# shape for the same reason
write_metrics_file() {
  mkdir -p "$(dirname "$metrics_path")"

  metrics_text "$1" "$2" "$3" > "$metrics_path".tmp

  chmod 0644 "$metrics_path".tmp
  mv -f "$metrics_path".tmp "$metrics_path"

  return 0
}

main
