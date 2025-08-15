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

playbook=""
inventory_hostname=""
target_node=""
target_node_op=""
ki_cp_ha_mode=""

knn_to_ih_dict=""

main() {
  require_file_exists "$vars_path"
  import_ki_env_vars
  setup_cmd_vars
  require_directory_exists "$ki_env_path"
  validate_ki_env_directory

  playbook=$($yq_cmd '.playbook' < "$vars_path")
  inventory_hostname=$($yq_cmd '.inventory_hostname' < "$vars_path")
  target_node=$($yq_cmd '.target_node' < "$vars_path")
  target_node_op=$($yq_cmd '.target_node_op' < "$vars_path")
  ki_cp_ha_mode=$($yq_cmd '.ki_cp_ha_mode' < "$vars_path")

  knn_to_ih_dict=$(get_knn_to_ih_dict)

  if [[ $playbook = "setup-cluster" ]]; then
    require_linux_packages_not_installed
    return 0
  fi

  if [[ $playbook = "add-node" || $playbook = "remove-node" ]]; then
    if [[ $inventory_hostname = "$target_node" ]]; then
      [[ $target_node_op = "add" ]] && require_linux_packages_not_installed
      return 0
    fi

    require_linux_packages_installed
    if [[ $(is_ki_cp_node "$inventory_hostname") = "true" ]]; then
      require_ki_cp_node
    else
      require_not_ki_cp_node
    fi
    [[ $(is_k8s_cp_node "$inventory_hostname") = "true" ]] && check_k8s_cluster_matches_inventory

    return 0
  fi

  return 0
}

require_linux_packages_installed() {
  [[ $("$ki_env_scripts_path/systemctl.sh" exists containerd) = "false" ]] && die "[ERROR] Linux package[\"containerd\"] not installed"
  [[ $("$ki_env_scripts_path/systemctl.sh" exists docker) = "false" ]] && die "[ERROR] Linux package[\"containerd\"] not installed"
  [[ $("$ki_env_scripts_path/systemctl.sh" exists kubelet) = "false" ]] && die "[ERROR] Linux package[\"containerd\"] not installed"

  return 0
}

require_linux_packages_not_installed() {
  [[ $("$ki_env_scripts_path/systemctl.sh" exists containerd) = "true" ]] && die "[ERROR] Linux package[\"containerd\"] already installed"
  [[ $("$ki_env_scripts_path/systemctl.sh" exists docker) = "true" ]] && die "[ERROR] Linux package[\"docker\"] already installed"
  [[ $("$ki_env_scripts_path/systemctl.sh" exists kubelet) = "true" ]] && die "[ERROR] Linux package[\"kubelet\"] already installed"

  return 0
}

require_ki_cp_node() {
  [[ $ki_cp_ha_mode = "true" && $(docker_service_exists ki-cp-keepalived) = "false" ]] &&
    die "[ERROR] Node is expected to be ki cp node but, docker service[\"ki-cp-keepalived\"] not exists"
  [[ $(docker_service_exists ki-cp-dns-server) = "false" ]] &&
    die "[ERROR] Node is expected to be ki cp node but, docker service[\"ki-cp-dns-server\"] not exists"
  [[ $(docker_service_exists ki-cp-ntp-server) = "false" ]] &&
    die "[ERROR] Node is expected to be ki cp node but, docker service[\"ki-cp-ntp-server\"] not exists"
  [[ $(docker_service_exists ki-cp-k8s-cp-lb) = "false" ]] &&
    die "[ERROR] Node is expected to be ki cp node but, docker service[\"ki-cp-k8s-cp-lb\"] not exists"
  [[ $(docker_service_exists ki-cp-k8s-registry) = "false" ]] &&
    die "[ERROR] Node is expected to be ki cp node but, docker service[\"ki-cp-k8s-registry\"] not exists"

  return 0
}

require_not_ki_cp_node() {
  [[ $(docker_service_exists ki-cp-keepalived) = "true" ]] &&
    die "[ERROR] Node is expected not to be ki cp node but, docker service[\"ki-cp-keepalived\"] exists"
  [[ $(docker_service_exists ki-cp-dns-server) = "true" ]] &&
    die "[ERROR] Node is expected not to be ki cp node but, docker service[\"ki-cp-dns-server\"] exists"
  [[ $(docker_service_exists ki-cp-ntp-server) = "true" ]] &&
    die "[ERROR] Node is expected not to be ki cp node but, docker service[\"ki-cp-ntp-server\"] exists"
  [[ $(docker_service_exists ki-cp-k8s-cp-lb) = "true" ]] &&
    die "[ERROR] Node is expected not to be ki cp node but, docker service[\"ki-cp-k8s-cp-lb\"] exists"
  [[ $(docker_service_exists ki-cp-k8s-registry) = "true" ]] &&
    die "[ERROR] Node is expected not to be ki cp node but, docker service[\"ki-cp-k8s-registry\"] exists"

  return 0
}

check_k8s_cluster_matches_inventory() {
  check_k8s_cluster_all_nodes
  check_k8s_cluster_cp_nodes

  return 0
}

check_k8s_cluster_all_nodes() {
  local diff_ih_list
  local diff_len
  local ih_list1
  local ih_list2

  ih_list1=$(get_k8s_cluster_all_ih_list)
  if [[ $target_node_op = "add" ]]; then
    ih_list2=$($yq_cmd -o json --null-input "$(get_inventory_k8s_node_ih_list) - [\"$target_node\"]")
  else
    ih_list2=$(get_inventory_k8s_node_ih_list)
  fi
  diff_ih_list=$($yq_cmd -o json --null-input "$ih_list1 - $ih_list2")
  diff_len=$($yq_cmd --null-input "$diff_ih_list | length")
  if [[ $diff_len -gt 0 ]]; then
    [[ $diff_len = 1 && $target_node_op = "add" && $($yq_cmd --null-input "$diff_ih_list | .[0]") = "$target_node" ]] &&
      die "[ERROR] K8s cluster already has node[\"$target_node\"]"

    die "[ERROR] K8s cluster has nodes that are not in inventory\n$diff_ih_list"
  fi

  ih_list1=$(get_k8s_cluster_all_ih_list)
  ih_list2=$($yq_cmd -o json --null-input "$(get_inventory_k8s_node_ih_list) - [\"$target_node\"]")
  diff_ih_list=$($yq_cmd -o json --null-input "$ih_list2 - $ih_list1")
  diff_len=$($yq_cmd --null-input "$diff_ih_list | length")
  [[ $diff_len -gt 0 ]] && die "[ERROR] Inventory has k8s nodes that are not in k8s cluster\n$diff_ih_list"

  return 0
}

check_k8s_cluster_cp_nodes() {
  local diff_ih_list
  local diff_len
  local ih_list1
  local ih_list2

  ih_list1=$(get_k8s_cluster_cp_ih_list)
  if [[ $target_node_op = "add" ]]; then
    ih_list2=$($yq_cmd -o json --null-input "$(get_inventory_k8s_cp_node_ih_list) - [\"$target_node\"]")
  else
    ih_list2=$(get_inventory_k8s_cp_node_ih_list)
  fi
  diff_ih_list=$($yq_cmd -o json --null-input "$ih_list1 - $ih_list2")
  diff_len=$($yq_cmd --null-input "$diff_ih_list | length")
  if [[ $diff_len -gt 0 ]]; then
    [[ $diff_len = 1 && $target_node_op = "add" && $($yq_cmd --null-input "$diff_ih_list | .[0]") = "$target_node" ]] &&
      die "[ERROR] K8s cluster already has control plane node[\"$target_node\"]"

    die "[ERROR] K8s cluster has control plane nodes that are not in inventory\n$diff_ih_list"
  fi

  ih_list1=$(get_k8s_cluster_cp_ih_list)
  ih_list2=$($yq_cmd -o json --null-input "$(get_inventory_k8s_cp_node_ih_list) - [\"$target_node\"]")
  diff_ih_list=$($yq_cmd -o json --null-input "$ih_list2 - $ih_list1")
  diff_len=$($yq_cmd --null-input "$diff_ih_list | length")
  [[ $diff_len -gt 0 ]] && die "[ERROR] Inventory has k8s control plane nodes that are not in k8s cluster\n$diff_ih_list"

  return 0
}

get_k8s_cluster_all_ih_list() {
  local k8s_cluster_all_node_list
  k8s_cluster_all_node_list=$(get_k8s_cluster_all_node_list)

  local ih_list="[]"
  for knn in $($yq_cmd '. | join(" ")' <<< "$k8s_cluster_all_node_list"); do
    ih=$($yq_cmd ".[\"$knn\"]" <<< "$knn_to_ih_dict")
    [[ -z $ih || $ih = "null" ]] && die "[ERROR] K8s cluster has the node[\"$ih\"] that is not in inventory"
    ih_list=$($yq_cmd -o json ". + [\"$ih\"]" <<< "$ih_list")
  done

  echo "$ih_list"
}

get_k8s_cluster_cp_ih_list() {
  local k8s_cluster_cp_node_list
  k8s_cluster_cp_node_list=$(get_k8s_cluster_cp_node_list)

  local ih_list="[]"
  for knn in $($yq_cmd '. | join(" ")' <<< "$k8s_cluster_cp_node_list"); do
    ih=$($yq_cmd ".[\"$knn\"]" <<< "$knn_to_ih_dict")
    [[ -z $ih || $ih = "null" ]] && die "[ERROR] K8s cluster has the node[\"$ih\"] that is not in inventory"
    ih_list=$($yq_cmd -o json ". + [\"$ih\"]" <<< "$ih_list")
  done

  echo "$ih_list"
}

get_inventory_k8s_node_ih_list() {
  $yq_cmd -o json ".groups.k8s_node" < "$vars_path"
}

get_inventory_k8s_cp_node_ih_list() {
  $yq_cmd -o json ".k8s_cp_nodes" < "$vars_path"
}

get_k8s_cluster_all_node_list() {
  local name_lines
  local name
  name_lines=$(kubectl get nodes -o name)

  local knn_list="[]"
  local knn
  while read -r name; do
    [[ ! $name =~ ^node/ ]] && continue
    knn=${name:5}
    knn_list=$($yq_cmd -o json ". + [\"$knn\"]" <<< "$knn_list")
  done <<< "$name_lines"

  echo "$knn_list"
}

get_k8s_cluster_cp_node_list() {
  local name_lines
  local name
  name_lines=$(kubectl get nodes -o name -l node-role.kubernetes.io/control-plane=)

  local knn_list="[]"
  local knn
  while read -r name; do
    [[ ! $name =~ ^node/ ]] && continue
    knn=${name:5}
    knn_list=$($yq_cmd -o json ". + [\"$knn\"]" <<< "$knn_list")
  done <<< "$name_lines"

  echo "$knn_list"
}

get_knn_to_ih_dict() {
  local hostname_to_ih_dict
  local knn_to_ih_dict="{}"
  local ih
  hostname_to_ih_dict=$($yq_cmd -o json '.hostname_to_ih_dict' < "$vars_path")
  for hostname in $($yq_cmd '. | keys | join(" ")' <<< "$hostname_to_ih_dict"); do
    ih=$($yq_cmd ".[\"$hostname\"]" <<< "$hostname_to_ih_dict")
    knn_to_ih_dict=$($yq_cmd -o json ".[\"${hostname,,}\"] = \"$ih\"" <<< "$knn_to_ih_dict")
  done

  echo "$knn_to_ih_dict"
}

docker_service_exists() {
  local svc_name=$1

  local ls_lines_len
  ls_lines_len=$(docker compose ls -a --filter name='^'"$svc_name"'$' | wc -l)
  if [[ $ls_lines_len = 2 ]]; then echo "true"; else echo "false"; fi

  return 0
}

is_ki_cp_node() {
  ih=$1

  $yq_cmd ".groups.ki_cp_node | contains([\"$ih\"])" < "$vars_path"
}

is_k8s_cp_node() {
  ih=$1

  $yq_cmd ".k8s_cp_nodes | contains([\"$ih\"])" < "$vars_path"
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
