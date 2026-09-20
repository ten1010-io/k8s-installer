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

yq_cmd=""
jinja2_cmd=""

k8s_cp=""
ki_etc_kubeadm_path=""
ki_tmp_join_credentials_path=""
hostname=""

node_name=""

main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  k8s_cp=$($yq_cmd '.k8s_cp' < "$vars_path")
  ki_etc_kubeadm_path=$($yq_cmd '.ki_etc_kubeadm_path' < "$vars_path")
  ki_tmp_join_credentials_path=$($yq_cmd '.ki_tmp_join_credentials_path' < "$vars_path")
  hostname=$($yq_cmd '.hostname' < "$vars_path")

  require_kubelet_not_enabled

  node_name=$(convert_into_knn "$hostname")
  token=$($yq_cmd '.token' < "$ki_tmp_join_credentials_path")
  discovery_token_ca_cert_hash=$($yq_cmd '.discovery_token_ca_cert_hash' < "$ki_tmp_join_credentials_path")
  certificate_key=$($yq_cmd '.certificate_key' < "$ki_tmp_join_credentials_path")

  mkdir -p "$ki_etc_kubeadm_path"

  systemctl enable kubelet
  $jinja2_cmd -D node_name="$node_name" \
              -D token="$token" \
              -D discovery_token_ca_cert_hash="$discovery_token_ca_cert_hash" \
              -D certificate_key="$certificate_key" \
              --format yaml \
              -o "$ki_etc_kubeadm_path""/kubeadm-join-config.yml" \
              "$SCRIPT_DIR_PATH"/templates/kubeadm-join-config.yml.j2 \
              "$vars_path"
  create_kubelet_config_patch_file
  kubeadm join --config "$ki_etc_kubeadm_path""/kubeadm-join-config.yml"

  if [[ $k8s_cp == "true" ]]; then
    mkdir -p $HOME/.kube
    cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config
  fi

  return 0
}

# This node downloads the cluster wide KubeletConfiguration from the
# kubelet-config ConfigMap. The reservations are calculated per node, so the
# baseline is patched with the values calculated for the capacity of this node
create_kubelet_config_patch_file() {
  mkdir -p "$ki_etc_kubeadm_path""/patches"
  $jinja2_cmd --format yaml \
              -o "$ki_etc_kubeadm_path""/patches/kubeletconfiguration+merge.yaml" \
              "$SCRIPT_DIR_PATH"/templates/kubeadm-kubelet-config.yml.j2 \
              "$vars_path"

  return 0
}

convert_into_knn() {
  local hostname=$1

  sed "s/_/-/g" <<< "${hostname,,}"

  return 0
}

require_kubelet_not_enabled() {
  local result
  result=$("$ki_opt_scripts_path"/systemctl.sh is-enabled kubelet)

  [[ $result = true ]] && die "[ERROR] Kubelet already enabled"

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
  jinja2_cmd="$ki_opt_venv_path/bin/jinja2"
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
