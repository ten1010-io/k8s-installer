#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--vars-path path] <node>
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--vars-path     File path
Arguments:
node            The name the node has in the cluster
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
  [[ ${#args[@]} -lt 1 ]] && die "[ERROR] Missing required argument: node"

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

# Long enough for a kubelet that is coming back to register, short enough that
# one which is not coming back is reported rather than waited on
NODE_READY_TIMEOUT=300
POLL_INTERVAL=5

# Waits until a node is Ready again.
#
# What this sits between is a node whose kubelet was replaced and the next node
# having the same done to it. Moving on while this one is still down would take
# the cluster to one fewer node than the run looks like it is touching, and the
# node being uncordoned says nothing about whether kubelet is back.
#
# Runs where kubectl does, which is a control plane node, so the node it is
# asked about is named rather than assumed to be this one
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  local knn=${args[0]}
  [[ -z $knn ]] && die "[ERROR] Missing required argument: node name"

  wait_node_ready "$knn"

  return 0
}

wait_node_ready() {
  local knn=$1

  msg "[INFO] Waiting for k8s node[\"$knn\"] to be Ready"

  local elapsed=0
  while [[ $(get_node_ready_status "$knn") != "True" ]]; do
    [[ $elapsed -ge $NODE_READY_TIMEOUT ]] &&
      die "[ERROR] Failed to wait for k8s node[\"$knn\"] being Ready. timeout occurred"

    sleep ${POLL_INTERVAL}s
    elapsed=$((elapsed + POLL_INTERVAL))
  done

  return 0
}

# Empty while the apiserver can not be asked at all, which reads the same as a
# node that is not Ready yet and is retried the same way
get_node_ready_status() {
  local knn=$1

  kubectl get node "$knn" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true

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
