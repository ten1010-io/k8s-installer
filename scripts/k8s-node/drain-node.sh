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

# Long enough for the replacements to be scheduled and to start, which is what a
# PodDisruptionBudget is waiting for before it lets the next pod go, and short
# enough that a drain nothing is going to let through is reported rather than
# waited on
DRAIN_TIMEOUT=5m

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

# Moves the workload off a node before the node is worked on or taken away.
#
# Through the eviction api, which is the only thing a PodDisruptionBudget is
# enforced against. The call this replaces passed --disable-eviction, which
# deletes the pods outright and honours no budget at all: a deployment of three
# replicas declaring that two must stay up lost all three at once, and whatever
# it served was down until the replacements had started somewhere else. That is
# the opposite of what draining a node is for.
#
# The grace period is not overridden either. It was pinned at ten seconds, so a
# pod that asked for longer to finish what it was doing did not get it
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  local knn=${args[0]}

  drain_k8s_node "$knn"

  return 0
}

# --force is not passed. It covers the pods that no controller owns, which are
# exactly the ones nothing will start again elsewhere, so refusing is the honest
# answer: there is something on this node that this cannot move, and somebody
# has to decide what happens to it
drain_k8s_node() {
  local knn=$1

  msg "[INFO] Draining k8s node[\"$knn\"]"
  kubectl drain "$knn" \
      --timeout "$DRAIN_TIMEOUT" \
      --delete-emptydir-data \
      --ignore-daemonsets ||
    die "[ERROR] Failed to drain the k8s node[\"$knn\"]. a pod of it could not be moved within $DRAIN_TIMEOUT, which a PodDisruptionBudget that can not be met or a pod no controller owns both look like. the node is left cordoned, so run uncordon-node.sh against it to put it back into service"

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
