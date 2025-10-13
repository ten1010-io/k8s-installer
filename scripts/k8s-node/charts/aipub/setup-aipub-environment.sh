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

AIPUB_CP_NODE_LABEL_KEY="node-role.aipub.ten1010.io/control-plane"

ki_env_path=""
ki_env_scripts_path=""
ki_env_bin_path=""
ki_env_ki_venv_path=""

yq_cmd=""
jinja2_cmd=""
python3_cmd=""

ki_tmp_root_path=""
ki_etc_charts_path=""
ki_var_aipub_local_pv_path=""
ih_to_hostname_dict=""
aipub_ha_mode=""
aipub_cp_nodes=""
aipub_keycloak_postgresql_storage_size=""

main() {
  require_file_exists "$vars_path"
  import_ki_env_vars
  setup_cmd_vars
  require_directory_exists "$ki_env_path"
  validate_ki_env_directory

  ki_tmp_root_path=$($yq_cmd '.ki_tmp_root_path' < "$vars_path")
  ki_etc_charts_path=$($yq_cmd '.ki_etc_charts_path' < "$vars_path")
  ki_var_aipub_local_pv_path=$($yq_cmd '.ki_var_aipub_local_pv_path' < "$vars_path")
  ih_to_hostname_dict=$($yq_cmd -o json '.ih_to_hostname_dict' < "$vars_path")
  aipub_ha_mode=$($yq_cmd '.aipub_ha_mode' < "$vars_path")
  aipub_cp_nodes=$($yq_cmd -o json '.aipub_cp_nodes' < "$vars_path")
  aipub_keycloak_postgresql_storage_size=$($yq_cmd '.aipub_keycloak_postgresql_storage_size' < "$vars_path")
  aipub_harbor_registry_storage_size=$($yq_cmd '.aipub_harbor_registry_storage_size' < "$vars_path")
  aipub_harbor_postgresql_storage_size=$($yq_cmd '.aipub_harbor_postgresql_storage_size' < "$vars_path")
  aipub_harbor_redis_storage_size=$($yq_cmd '.aipub_harbor_redis_storage_size' < "$vars_path")

  resources_path=$ki_etc_charts_path/aipub/resources

  keycloak_postgresql_local_pv_name="local-aipub-keycloak-postgresql"
  keycloak_postgresql_local_pv_ih=$($yq_cmd --null-input "$aipub_cp_nodes | .[0]")
  keycloak_postgresql_local_pv_path="$ki_var_aipub_local_pv_path/keycloak/postgresql"
  harbor_registry_local_pv_name="local-aipub-harbor-registry"
  harbor_registry_local_pv_ih=$($yq_cmd --null-input "$aipub_cp_nodes | .[0]")
  harbor_registry_local_pv_path="$ki_var_aipub_local_pv_path/harbor/registry"
  harbor_postgresql_local_pv_name="local-aipub-harbor-postgresql"
  harbor_postgresql_local_pv_ih=$($yq_cmd --null-input "$aipub_cp_nodes | .[0]")
  harbor_postgresql_local_pv_path="$ki_var_aipub_local_pv_path/harbor/postgresql"
  harbor_redis_local_pv_name="local-aipub-harbor-redis"
  harbor_redis_local_pv_ih=$($yq_cmd --null-input "$aipub_cp_nodes | .[0]")
  harbor_redis_local_pv_path="$ki_var_aipub_local_pv_path/harbor/redis"


  mkdir -p "$resources_path"
  if [[ $aipub_ha_mode != "true" ]]; then
    create_local_pv_yml_file "$keycloak_postgresql_local_pv_name" \
      "$aipub_keycloak_postgresql_storage_size" \
      "$keycloak_postgresql_local_pv_name" \
      "$(get_knn "$keycloak_postgresql_local_pv_ih")" \
      "$keycloak_postgresql_local_pv_path"
    create_local_pv_yml_file "$harbor_registry_local_pv_name" \
      "$aipub_harbor_registry_storage_size" \
      "$harbor_registry_local_pv_name" \
      "$(get_knn "$harbor_registry_local_pv_ih")" \
      "$harbor_registry_local_pv_path"
    create_local_pv_yml_file "$harbor_postgresql_local_pv_name" \
      "$aipub_harbor_postgresql_storage_size" \
      "$harbor_postgresql_local_pv_name" \
      "$(get_knn "$harbor_postgresql_local_pv_ih")" \
      "$harbor_postgresql_local_pv_path"
    create_local_pv_yml_file "$harbor_redis_local_pv_name" \
      "$aipub_harbor_redis_storage_size" \
      "$harbor_redis_local_pv_name" \
      "$(get_knn "$harbor_redis_local_pv_ih")" \
      "$harbor_redis_local_pv_path"
  fi
  [[ $(has_files "$resources_path") = "true" ]] && kubectl apply -f "$resources_path"
  attach_aipub_cp_node_label
  kubectl create namespace aipub

  return 0
}

create_local_pv_yml_file() {
  local name=$1
  local storage=$2
  local storage_class=$3
  local knn=$4
  local path=$5

  local tmp_file_path
  tmp_file_path="$ki_tmp_root_path/tmp-templates-vars.yml"
  touch "$tmp_file_path"
  $yq_cmd -i ".name = \"$name\"" "$tmp_file_path"
  $yq_cmd -i ".storage = \"$storage\"" "$tmp_file_path"
  $yq_cmd -i ".storage_class = \"$storage_class\"" "$tmp_file_path"
  $yq_cmd -i ".knn = \"$knn\"" "$tmp_file_path"
  $yq_cmd -i ".path = \"$path\"" "$tmp_file_path"
  $jinja2_cmd --format yaml -o "$resources_path/$name-pv.yml" "$SCRIPT_DIR_PATH"/templates/local-pv.yml.j2 "$tmp_file_path"
  rm "$tmp_file_path"

  return 0
}

attach_aipub_cp_node_label() {
  local len
  local ih
  local knn

  len=$($yq_cmd --null-input "$aipub_cp_nodes | length")
  for (( i=0; i<"$len"; i++ )); do
    ih=$($yq_cmd --null-input "$aipub_cp_nodes | .[$i]")
    knn=$(get_knn "$ih")

    kubectl label node "$knn" "$AIPUB_CP_NODE_LABEL_KEY="
  done

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

has_files() {
  local dir_path=$1

  if [[ -n "$(ls -A "$dir_path" 2>/dev/null)" ]]; then echo "true"; else echo "false"; fi

  return 0
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
