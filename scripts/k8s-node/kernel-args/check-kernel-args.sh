#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--node name] [--metrics-path path]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--node          Name to report this node under
--metrics-path  Also write what was measured to this file, in the prometheus text
                format a node exporter textfile collector reads
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

# The record of what was put on the command line, which is what this compares
# against. Absent on a node that was never given any
RECORD_PATH=/etc/k8s-installer/kernel-args

# Says whether this node is booted with the kernel command line arguments it was
# configured with, and prints nothing when it is.
#
# Written rather than in force is the whole of what can go wrong here, and the
# two look the same from the outside: the arguments take effect at a boot, so a
# node that was configured and never rebooted reads exactly like one where the
# bootloader did not take them. Reported rather than failed, and to stdout for a
# playbook to collect, the way check-vfio-pci.sh is.
#
# Nothing is read out of the vars file of the node, and the node is named on the
# command line, so that this can be run at any time - including after
# reset-vars-file.yml has taken that file away, which is where every playbook
# imports the report from, and by an operator who has just rebooted a node and
# come back to confirm it. check-vfio-pci.sh is the same shape for the same
# reason
main() {
  # Measured before the record is looked at, so that a node whose arguments were
  # taken away writes a metric saying it is missing none. Left to the early exit
  # below, the last number it wrote would stand for good
  local missing
  missing=$(missing_args)

  [[ -n $metrics_path ]] && write_metrics_file "$missing"

  # A node that was given no argument has nothing to take, which is most of them
  [[ -f $RECORD_PATH ]] || exit 0

  report_missing_args "$missing"

  exit 0
}

# The arguments this node was given and is not booted with, one per line
missing_args() {
  [[ -f $RECORD_PATH ]] || return 0

  local cmdline
  cmdline=$(cat /proc/cmdline)

  local arg
  while IFS= read -r arg; do
    [[ -z $arg ]] && continue
    grep -qwF -- "$arg" <<< "$cmdline" || echo "$arg"
  done < "$RECORD_PATH"

  return 0
}

# Compared as fixed strings rather than as patterns. A kernel argument carries
# dots more often than not, and a dot in a pattern matches anything, so a node
# booted with a differently spelled argument would read as one that took it
report_missing_args() {
  local missing=$1

  [[ -z $missing ]] && return 0

  local joined
  joined=$(tr '\n' ' ' <<< "$missing")

  echo "[WARN] node[\"$node\"] is not booted with kernelCmdlineExtraArgs[\"${joined% }\"]. the configuration is written and takes effect when the node is rebooted"

  return 0
}

# Writes what was measured where a node exporter textfile collector reads it, so
# that the answer is there between playbook runs as well as at the end of one.
#
# Replaced rather than appended to, and moved into place, because a collector
# reads whatever is there when it is scraped. Whether the file is still being
# refreshed is not carried in it: node_exporter already exports
# node_textfile_mtime_seconds for every file it reads
write_metrics_file() {
  local missing=$1

  local count=0
  [[ -n $missing ]] && count=$(grep -c . <<< "$missing")

  mkdir -p "$(dirname "$metrics_path")"

  cat > "$metrics_path".tmp <<EOF
# HELP ki_node_kernel_args_missing Kernel command line arguments this node was given and is not booted with
# TYPE ki_node_kernel_args_missing gauge
ki_node_kernel_args_missing $count
EOF

  chmod 0644 "$metrics_path".tmp
  mv -f "$metrics_path".tmp "$metrics_path"

  return 0
}

main
