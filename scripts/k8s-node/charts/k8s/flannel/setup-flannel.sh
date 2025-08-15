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

CHART_NAME=flannel

ki_env_path=""
ki_env_scripts_path=""
ki_env_bin_path=""
ki_env_ki_venv_path=""

yq_cmd=""
jinja2_cmd=""
python3_cmd=""

ki_etc_charts_path=""
ki_tmp_root_path=""
internal_network_subnets=""

chart_root_path=""

main() {
  require_file_exists "$vars_path"
  import_ki_env_vars
  setup_cmd_vars
  require_directory_exists "$ki_env_path"
  validate_ki_env_directory

  ki_etc_charts_path=$($yq_cmd '.ki_etc_charts_path' < "$vars_path")
  ki_tmp_root_path=$($yq_cmd '.ki_tmp_root_path' < "$vars_path")
  internal_network_subnets=$($yq_cmd -o json '.internal_network_subnets' < "$vars_path")

  chart_root_path=$ki_etc_charts_path/k8s/$CHART_NAME

  mkdir -p "$chart_root_path"
  cp -f "$ki_env_bin_path/charts/k8s/flannel.tgz" "$chart_root_path/chart.tgz"
  create_values_yml_file

  kubectl create ns kube-flannel
  kubectl label --overwrite ns kube-flannel pod-security.kubernetes.io/enforce=privileged
  helm install -n kube-flannel flannel "$chart_root_path/chart.tgz" -f "$chart_root_path/values.yml"

  return 0
}

create_values_yml_file() {
  local iface_can_reach
  internal_network_subnet=$($yq_cmd --null-input "$internal_network_subnets | .[0]")
  iface_can_reach=$($python3_cmd "$SCRIPT_DIR_PATH/get-network-address.py" "$internal_network_subnet")

  local tmp_file_path
  tmp_file_path="$ki_tmp_root_path/tmp-templates-vars.yml"
  touch "$tmp_file_path"
  $yq_cmd -i ".internal_network_ki_cp_dns_name = load(\"$vars_path\").internal_network_ki_cp_dns_name" "$tmp_file_path"
  $yq_cmd -i ".ki_cp_k8s_registry_port = load(\"$vars_path\").ki_cp_k8s_registry_port" "$tmp_file_path"
  $yq_cmd -i ".iface_can_reach = \"$iface_can_reach\"" "$tmp_file_path"
  $jinja2_cmd --format yaml -o "$chart_root_path/values.yml" "$SCRIPT_DIR_PATH"/templates/values.yml.j2 "$tmp_file_path"
  rm "$tmp_file_path"
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
  python3_cmd="$ki_env_ki_venv_path/bin/python3"
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
