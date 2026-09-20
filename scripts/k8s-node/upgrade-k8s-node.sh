#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--vars-path path] [--first-cp-node]
Available options:
-h, --help        Print this help and exit
-v, --verbose     Print script debug info
--vars-path       File path
--first-cp-node   Raise the version of the cluster from this node
EOF
  exit
}

parse_params() {
  vars_path=""
  first_cp_node="false"

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
    --first-cp-node) first_cp_node="true" ;;
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

yq_cmd=""

k8s_version=""

# Takes this node to the kubernetes version of the release the installer now
# holds. The packages under it have already been replaced by the caller, so
# kubeadm here is the new one and what is left is to tell the cluster.
#
# One node does it for the cluster and the rest follow. kubeadm calls the first
# one "upgrade apply", which raises the version the cluster records and upgrades
# the control plane of that node, and every node after it "upgrade node", which
# reads that version and brings itself into line. Running apply twice is not how
# a second node is upgraded
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  k8s_version=$($yq_cmd '.k8s_version' < "$vars_path")

  if [[ $first_cp_node = "true" ]]; then
    upgrade_cluster
  else
    upgrade_node
  fi

  return 0
}

# The version the cluster records, which is the only one that says whether this
# has been done. Nothing on the node answers that: the packages were replaced
# before this ran, so kubelet and kubeadm on disk report the new version whether
# or not the cluster has ever heard of it. Reading that as "already upgraded" is
# how an entire upgrade gets skipped and reported as a success
get_cluster_k8s_version() {
  kubectl -n kube-system get configmap kubeadm-config \
      -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null |
    grep -oP '^kubernetesVersion: \K.+' || true

  return 0
}

# Raising the version the cluster records is done once, by the first node. Asked
# again for a version it already holds, kubeadm rewrites and restarts the
# control plane of this node for nothing, so a run repeated after a failure part
# way through skips straight to the nodes that still need it
upgrade_cluster() {
  if [[ $(get_cluster_k8s_version) = "$k8s_version" ]]; then
    msg "[INFO] The cluster already records kubernetes[\"$k8s_version\"]"
    upgrade_node
    return 0
  fi

  msg "[INFO] Raising the cluster to kubernetes[\"$k8s_version\"]"
  kubeadm upgrade apply "$k8s_version" --yes ||
    die "[ERROR] Failed to raise the cluster to kubernetes[\"$k8s_version\"]. the cluster is left at the version it reports, and the nodes after this one were not touched"

  return 0
}

# No check of its own. kubeadm upgrade node reads the version the cluster
# records and brings this node to it, and doing that to a node already there
# changes nothing, so there is nothing to decide
upgrade_node() {
  msg "[INFO] Bringing this node to kubernetes[\"$k8s_version\"]"
  kubeadm upgrade node ||
    die "[ERROR] Failed to bring this node to kubernetes[\"$k8s_version\"]"

  return 0
}

import_ki_opt_vars() {
  ki_opt_root_path=$(grep -oP  "^ki_opt_root_path: \K(.+)" < "$vars_path")
  ki_opt_scripts_path=$(grep -oP  "^ki_opt_scripts_path: \K(.+)" < "$vars_path")
  ki_opt_bundle_path=$(grep -oP  "^ki_opt_bundle_path: \K(.+)" < "$vars_path")
  ki_opt_venv_path=$(grep -oP  "^ki_opt_venv_path: \K(.+)" < "$vars_path")
}

setup_cmd_vars() {
  yq_cmd="$ki_opt_bundle_path/bin/yq"
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
