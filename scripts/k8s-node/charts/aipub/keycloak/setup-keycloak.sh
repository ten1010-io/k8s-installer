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

CHART_NAME=keycloak

ki_env_path=""
ki_env_scripts_path=""
ki_env_bin_path=""
ki_env_ki_venv_path=""

yq_cmd=""
jinja2_cmd=""
python3_cmd=""

ki_etc_charts_path=""
ki_tmp_root_path=""
internal_network_ki_cp_dns_name=""
ki_cp_aipub_registry_port=""
aipub_ingress_zone=""
aipub_ha_mode=""
aipub_ha_mode_storage_class=""
aipub_keycloak_ingress_class=""
aipub_keycloak_ingress_subdomain=""
aipub_keycloak_replica_count=""
aipub_keycloak_postgresql_storage_size=""

chart_root_path=""
resources_path=""

main() {
  require_file_exists "$vars_path"
  import_ki_env_vars
  setup_cmd_vars
  require_directory_exists "$ki_env_path"
  validate_ki_env_directory

  ki_etc_charts_path=$($yq_cmd '.ki_etc_charts_path' < "$vars_path")
  ki_tmp_root_path=$($yq_cmd '.ki_tmp_root_path' < "$vars_path")
  internal_network_ki_cp_dns_name=$($yq_cmd '.internal_network_ki_cp_dns_name' < "$vars_path")
  ki_cp_aipub_registry_port=$($yq_cmd '.ki_cp_aipub_registry_port' < "$vars_path")
  aipub_ingress_zone=$($yq_cmd '.aipub_ingress_zone' < "$vars_path")
  aipub_ha_mode=$($yq_cmd '.aipub_ha_mode' < "$vars_path")
  aipub_ha_mode_storage_class=$($yq_cmd '.aipub_ha_mode_storage_class' < "$vars_path")
  aipub_keycloak_ingress_class=$($yq_cmd '.aipub_keycloak_ingress_class' < "$vars_path")
  aipub_keycloak_ingress_subdomain=$($yq_cmd '.aipub_keycloak_ingress_subdomain' < "$vars_path")
  aipub_keycloak_replica_count=$($yq_cmd '.aipub_keycloak_replica_count' < "$vars_path")
  aipub_keycloak_postgresql_storage_size=$($yq_cmd '.aipub_keycloak_postgresql_storage_size' < "$vars_path")

  chart_root_path=$ki_etc_charts_path/aipub/$CHART_NAME
  resources_path=$chart_root_path/resources

  mkdir -p "$resources_path"
  if [[ $aipub_ha_mode == "true" ]]; then
    create_pvc_yml_file "keycloak-postgresql" "aipub" "$aipub_ha_mode_storage_class" "ReadWriteMany" "$aipub_keycloak_postgresql_storage_size"
  else
    create_pvc_yml_file "keycloak-postgresql" "aipub" "local-aipub-keycloak-postgresql" "ReadWriteOnce" "$aipub_keycloak_postgresql_storage_size"
  fi
  [[ $(has_files "$resources_path") = "true" ]] && kubectl apply -f "$resources_path"
  install_chart

  return 0
}

install_chart() {
  mkdir -p "$chart_root_path"
  cp -f "$ki_env_bin_path/charts/aipub/keycloak.tgz" "$chart_root_path/chart.tgz"
  create_values_yml_file
  helm install -n aipub $CHART_NAME "$chart_root_path/chart.tgz" -f "$chart_root_path/values.yml"

  return 0
}

create_values_yml_file() {
  local image_registry
  local replica_count
  local ingress_class
  local hostname
  image_registry="$internal_network_ki_cp_dns_name:$ki_cp_aipub_registry_port"
  replica_count=$aipub_keycloak_replica_count
  ingress_class=$aipub_keycloak_ingress_class
  hostname="$aipub_keycloak_ingress_subdomain.$aipub_ingress_zone"

  local tmp_file_path
  tmp_file_path="$ki_tmp_root_path/tmp-templates-vars.yml"
  touch "$tmp_file_path"
  $yq_cmd -i ".image_registry = \"$image_registry\"" "$tmp_file_path"
  $yq_cmd -i ".replica_count = $replica_count" "$tmp_file_path"
  $yq_cmd -i ".ingress_class = \"$ingress_class\"" "$tmp_file_path"
  $yq_cmd -i ".hostname = \"$hostname\"" "$tmp_file_path"
  $jinja2_cmd --format yaml -o "$chart_root_path/values.yml" "$SCRIPT_DIR_PATH"/templates/values.yml.j2 "$tmp_file_path"
  rm "$tmp_file_path"

  return 0
}

create_pvc_yml_file() {
  local name=$1
  local namespace=$2
  local storage_class=$3
  local access_mode=$4
  local storage=$5

  local tmp_file_path
  tmp_file_path="$ki_tmp_root_path/tmp-templates-vars.yml"
  touch "$tmp_file_path"
  $yq_cmd -i ".name = \"$name\"" "$tmp_file_path"
  $yq_cmd -i ".namespace = \"$namespace\"" "$tmp_file_path"
  $yq_cmd -i ".storage_class = \"$storage_class\"" "$tmp_file_path"
  $yq_cmd -i ".access_mode = \"$access_mode\"" "$tmp_file_path"
  $yq_cmd -i ".storage = \"$storage\"" "$tmp_file_path"
  $jinja2_cmd --format yaml -o "$resources_path/$name-pvc.yml" "$SCRIPT_DIR_PATH"/templates/resources/pvc.yml.j2 "$tmp_file_path"
  rm "$tmp_file_path"

  return 0
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
