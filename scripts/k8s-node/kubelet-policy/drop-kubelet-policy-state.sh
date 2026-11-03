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

# Where kubelet keeps what the cpu manager and the memory manager last decided:
# the policy each ran under, and for the memory manager the size of every numa
# node and what was reserved on it. Fixed by kubelet
CPU_MANAGER_STATE_PATH=/var/lib/kubelet/cpu_manager_state
MEMORY_MANAGER_STATE_PATH=/var/lib/kubelet/memory_manager_state

# Says this boot has already been given a fresh start. /run is a tmpfs the
# kernel mounts empty at every boot, so a file here lives exactly as long as the
# boot does and nothing has to be written to say it ended. Written here the
# first time through, and also by setup-kubelet-policy-state.sh when it writes
# the drop in, so that the restart which follows on a running node does not
# count as the first start of its boot
MARKER_PATH=/run/k8s-installer/kubelet-policy-state-dropped

# Takes the checkpoints of kubelet's cpu manager and memory manager away once per
# boot, before kubelet starts. Run by kubelet.service itself, as an ExecStartPre
# that setup-kubelet-policy-state.sh puts in a drop in of the unit.
#
# What the checkpoints are for is a kubelet restart: the containers keep running
# under containerd, and the file is how the kubelet that comes back knows which
# of them holds which cpus and which memory. Across a boot there is nothing for
# it to remember - every container is gone, and the pods that come back are
# admitted again and allocated again - and the file does harm instead. The memory
# manager compares the total memory of every numa node against what it wrote,
# to the byte, and refuses to start when the two differ: measured on 1.36 on
# ec2, a plain reboot moved numa node 1 of an m5.16xlarge from 133836640256 to
# 133836615680 bytes, 24KiB, and kubelet looped on
#   "[memorymanager] the expected machine state is different from the real one"
# until the file was removed by hand. The count of hugepages the kernel managed
# to allocate at that boot is in the same comparison, so a node short of 1G
# pages after a reboot would refuse for a second reason.
#
# Once per boot rather than on every start, because within a boot the
# checkpoint is doing its job: kubelet restarted for a configuration change has
# containers to pick back up, and update-k8s-node-kubelet.sh is the one that
# decides when a restart may take the state away. Both files go, not only the
# memory manager's, for the same reason --reset-cpu-manager-state takes both:
# the cpu manager compares the cpus of the machine the same way, and a boot is
# when a virtual machine finds out it was resized.
#
# Quiet on the way through. systemd runs this before every kubelet start and
# the journal of kubelet is where somebody looks when kubelet does not come up,
# so the one line this writes is the one that says it did something
main() {
  [[ -f $MARKER_PATH ]] && exit 0

  mkdir -p "$(dirname "$MARKER_PATH")"
  touch "$MARKER_PATH"

  local path
  local dropped=""
  for path in "$CPU_MANAGER_STATE_PATH" "$MEMORY_MANAGER_STATE_PATH"; do
    [[ -f $path ]] || continue
    rm -f "$path"
    dropped="$dropped $path"
  done

  [[ -n $dropped ]] && msg "[INFO] First kubelet start of this boot: took away the checkpoints of the previous one -$dropped"

  exit 0
}

main
