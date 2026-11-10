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

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

# How long kubelet is given to come up after a boot, and how long it has to stay
# up to count.
#
# The first is for what kubelet waits on at a boot. systemd starts it before
# containerd is answering and before the network is up, and a kubelet that can
# not reach its runtime exits and is started again, so the unit is seen
# activating, failed and active in turn for a while on a healthy node. Five
# minutes is the same allowance wait-k8s-node-ready.sh makes for the node.
#
# The second is for a kubelet that reads a configuration it refuses. Measured on
# 1.36, it gives up about a quarter of a second in and the unit waits ten
# seconds before starting it again, so one question can land on the quarter
# second and three questions five seconds apart can not. The same figure
# update-k8s-node-kubelet.sh uses after a restart, for the same reason
KUBELET_UP_TIMEOUT=300
KUBELET_SETTLE_SECONDS=15
POLL_INTERVAL=5

# Waits until the kubelet of this node is running, and stays running.
#
# What this sits between is a node that was rebooted and the cluster being
# asked whether it is back. The node object keeps the Ready it had before the
# reboot for as long as the lease grace period allows, so a machine that comes
# back in under a minute is reported Ready by a kubelet that is gone, and a
# wait on that condition passes while the kubelet that came up is refusing its
# configuration and being started over and over. A node running the static
# memory manager after a boot that changed its hugepages is exactly that node.
# So the unit is asked on the node, which is the only place the answer is
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  wait_kubelet_up
  require_kubelet_stays_up

  return 0
}

wait_kubelet_up() {
  msg "[INFO] Waiting for kubelet of this node to be running"

  local elapsed=0
  while [[ $(kubelet_running) != "true" ]]; do
    [[ $elapsed -ge $KUBELET_UP_TIMEOUT ]] &&
      die "[ERROR] Failed to wait for kubelet being running. timeout occurred$(journal_excerpt)"

    sleep ${POLL_INTERVAL}s
    elapsed=$((elapsed + POLL_INTERVAL))
  done

  return 0
}

# Asked again rather than once, because a looping unit is briefly running each
# time it is started and a single question can land there
require_kubelet_stays_up() {
  local waited=0
  while [[ $waited -lt $KUBELET_SETTLE_SECONDS ]]; do
    sleep ${POLL_INTERVAL}s
    waited=$((waited + POLL_INTERVAL))

    [[ $(kubelet_running) = "true" ]] ||
      die "[ERROR] kubelet of this node started and stopped again, so it is refusing to run with what it was given$(journal_excerpt)"
  done

  msg "[INFO] kubelet of this node is running"

  return 0
}

kubelet_running() {
  "$ki_opt_scripts_path"/systemctl.sh is-running kubelet

  return 0
}

# The lines of the journal that say why, where there are any. kubelet names
# the checkpoint it refuses and the file to remove, and that line is the one
# somebody looking at a node that will not come back wants first
journal_excerpt() {
  local lines
  lines=$(journalctl -u kubelet -n 200 --no-pager 2>/dev/null |
    grep -E "Invalid state|machine state|failed to run Kubelet|command failed" |
    tail -n 5 || true)

  [[ -z $lines ]] && return 0

  printf '\n%s' "$lines"

  return 0
}

import_ki_opt_vars() {
  ki_opt_root_path=$(grep -oP  "^ki_opt_root_path: \K(.+)" < "$vars_path")
  ki_opt_scripts_path=$(grep -oP  "^ki_opt_scripts_path: \K(.+)" < "$vars_path")
  ki_opt_bundle_path=$(grep -oP  "^ki_opt_bundle_path: \K(.+)" < "$vars_path")
  ki_opt_venv_path=$(grep -oP  "^ki_opt_venv_path: \K(.+)" < "$vars_path")
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
