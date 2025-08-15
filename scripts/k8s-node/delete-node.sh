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

ki_env_path=""
ki_env_scripts_path=""
ki_env_bin_path=""
ki_env_ki_venv_path=""

yq_cmd=""
jinja2_cmd=""
etcdctl_cmd=""

target_node=""
target_node_op=""
k8s_cp_nodes=""
ih_to_hostname_dict=""

main() {
  require_file_exists "$vars_path"
  import_ki_env_vars
  setup_cmd_vars
  require_directory_exists "$ki_env_path"
  validate_ki_env_directory

  target_node=$($yq_cmd '.target_node' < "$vars_path")
  target_node_op=$($yq_cmd '.target_node_op' < "$vars_path")
  k8s_cp_nodes=$($yq_cmd -o json '.k8s_cp_nodes' < "$vars_path")
  ih_to_hostname_dict=$($yq_cmd -o json '.ih_to_hostname_dict' < "$vars_path")

  [[ -z $target_node ]] && exit 0
  [[ $target_node_op != "remove" ]] && exit 0

  local target_node_knn
  target_node_knn=$(get_knn "$target_node")

  if [[ $(k8s_node_exists "$target_node_knn") = "true" ]]; then
    msg "[INFO] Deleting k8s node[\"$target_node_knn\"]"
    delete_k8s_node "$target_node_knn"
  fi

  if [[ $(is_k8s_cp "$target_node") = "true" && $(etcd_member_exists "$target_node_knn") = "true" ]]; then
    msg "[INFO] Deleting etcd member with name[\"$target_node_knn\"]"
    delete_etcd_member "$target_node_knn"
  fi

  return 0
}

get_knn() {
  local ih=$1

  local hostname
  hostname=$(get_hostname "$ih")

  echo "${hostname,,}"
}

get_hostname() {
  local ih=$1

  local hostname
  hostname=$($yq_cmd <<< "$ih_to_hostname_dict" ".$ih")
  [[ -z $hostname || $hostname = "null" ]] && die "[ERROR] Fail to get hostname for ih[\"$ih\"]"

  echo "$hostname"
}

k8s_node_exists() {
  local knn=$1

  local exit_code=0
  kubectl get node "$knn" > /dev/null 2>&1 || exit_code=$?
  if [[ $exit_code = 0 ]]; then echo "true"; else echo "false"; fi

  return 0
}

is_k8s_cp() {
  local ih=$1

  found=$($yq_cmd --null-input "$k8s_cp_nodes | .[] | select(. == \"$ih\")")
  if [[ -n $found ]]; then echo "true"; else echo "false"; fi

  return 0
}

etcd_member_exists() {
  local knn=$1

  local list_result
  local member

  list_result=$($etcdctl_cmd -w json --hex --command-timeout=3s member list)

  member=$($yq_cmd <<< "$list_result" ".members | .[] | select(.name == \"$knn\")")
  if [[ -n $member ]]; then echo "true"; else echo "false"; fi

  return 0
}

get_etcd_member_id() {
  local knn=$1

  local list_result
  local member
  local member_id

  list_result=$($etcdctl_cmd -w json --hex --command-timeout=3s member list)

  member=$($yq_cmd <<< "$list_result" ".members | .[] | select(.name == \"$knn\")")
  [[ -z $member ]] && die "[ERROR] Etcd member with name[\"$knn\"] not exists"

  member_id=$($yq_cmd <<< "$member" '.ID')
  [[ -z $member_id ]] && die "[ERROR] Etcd member with name[\"$knn\"] exists, but doesn't have a ID"

  echo "$member_id"
  return 0
}

delete_etcd_member() {
  local knn=$1

  local id
  id=$(get_etcd_member_id "$knn")
  $etcdctl_cmd member remove "$id"
}

delete_k8s_node() {
  knn=$1

  kubectl drain "$knn" \
      --grace-period 10 \
      --timeout 30s \
      --disable-eviction \
      --force \
      --delete-emptydir-data \
      --ignore-daemonsets
  kubectl delete node "$knn"
}

import_ki_env_vars() {
  ki_env_path=$(grep -oP  "^ki_env_path: \K(.+)" < "$vars_path")
  ki_env_scripts_path=$(grep -oP  "^ki_env_scripts_path: \K(.+)" < "$vars_path")
  ki_env_bin_path=$(grep -oP  "^ki_env_bin_path: \K(.+)" < "$vars_path")
  ki_env_ki_venv_path=$(grep -oP  "^ki_env_ki_venv_path: \K(.+)" < "$vars_path")
}

setup_cmd_vars() {
  yq_cmd="$ki_env_bin_path/bin/yq"
  jinja2_cmd="$ki_env_ki_venv_path/bin/jinja2"
  etcdctl_cmd="etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/peer.crt --key=/etc/kubernetes/pki/etcd/peer.key"
}

validate_ki_env_directory() {
  require_directory_exists "$ki_env_scripts_path"
  require_directory_exists "$ki_env_bin_path"
  require_directory_exists "$ki_env_ki_venv_path"

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
