#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--vars-path path] [--update]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--vars-path     File path
--update
EOF
  exit
}

parse_params() {
  vars_path=""
  update="false"

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
    --update) update="true" ;;
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

SVC_NAME=ki-cp-dns-server

ki_env_path=""
ki_env_scripts_path=""
ki_env_bin_path=""
ki_env_ki_venv_path=""

yq_cmd=""
jinja2_cmd=""

ki_etc_services_path=""
ki_tmp_root_path=""
ki_cp_ha_mode=""
ki_cp_ha_mode_vip=""
target_node=""
target_node_op=""
internal_network_extra_zone=""

svc_root_path=""

main() {
  require_file_exists "$vars_path"
  import_ki_env_vars
  setup_cmd_vars
  require_directory_exists "$ki_env_path"
  validate_ki_env_directory

  ki_etc_services_path=$($yq_cmd '.ki_etc_services_path' < "$vars_path")
  ki_tmp_root_path=$($yq_cmd .ki_tmp_root_path < "$vars_path")
  ki_cp_ha_mode=$($yq_cmd .ki_cp_ha_mode < "$vars_path")
  ki_cp_ha_mode_vip=$($yq_cmd .ki_cp_ha_mode_vip < "$vars_path")
  target_node=$($yq_cmd .target_node < "$vars_path")
  target_node_op=$($yq_cmd .target_node_op < "$vars_path")
  internal_network_extra_zone=$($yq_cmd '.internal_network_extra_zone' < "$vars_path")

  svc_root_path="$ki_etc_services_path"/$SVC_NAME
  [[ $update = "false" ]] && require_not_setup $SVC_NAME

  disable_resolved

  docker load -i "$ki_env_bin_path"/images/bind9/*.tar

  mkdir -p "$svc_root_path"
  $jinja2_cmd --format yaml -o "$svc_root_path""/compose.yml" "$SCRIPT_DIR_PATH"/templates/compose.yml.j2 "$vars_path"
  $jinja2_cmd --format yaml -o "$svc_root_path""/named.conf.local" "$SCRIPT_DIR_PATH"/templates/named.conf.local.j2 "$vars_path"
  create_named_conf_options_file
  create_internal_network_zone_db_file
  if [[ $internal_network_extra_zone != "null" ]]; then
    create_internal_network_extra_zone_db_file
  fi

  [[ $update = "true" && $(service_exists $SVC_NAME) = "true" ]] && docker compose -f "$svc_root_path/compose.yml" down
  docker compose -f "$svc_root_path/compose.yml" up -d

  $yq_cmd -i -o json -P '.dns = ["172.17.0.1"]' /etc/docker/daemon.json
  systemctl restart docker

  return 0
}

create_named_conf_options_file() {
  local servers_len
  local recursion
  servers_len=$($yq_cmd '.ki_cp_dns_server_upstream_servers | length' < "$vars_path")
  if [[ $servers_len -gt 0 ]]; then
    recursion="yes"
  else
    recursion="no"
  fi

  local tmp_file_path
  tmp_file_path="$ki_tmp_root_path"/tmp-templates-vars.yml
  touch "$tmp_file_path"
  $yq_cmd -o json -i ".upstream_servers = load(\"$vars_path\").ki_cp_dns_server_upstream_servers" "$tmp_file_path"
  $yq_cmd -o json -i ".recursion = \"$recursion\"" "$tmp_file_path"
  $jinja2_cmd --format yaml -o "$svc_root_path""/named.conf.options" "$SCRIPT_DIR_PATH"/templates/named.conf.options.j2 "$tmp_file_path"
  rm "$tmp_file_path"
}

create_internal_network_zone_db_file() {
  local ns1_a_record_ip
  local ki_cp_a_record_ip
  local master_node_ip
  if [[ $ki_cp_ha_mode = "true" ]]; then
    ns1_a_record_ip=$ki_cp_ha_mode_vip
    ki_cp_a_record_ip=$ki_cp_ha_mode_vip
  else
    master_node_ip=$(get_ki_cp_master_node_ip)
    ns1_a_record_ip=$master_node_ip
    ki_cp_a_record_ip=$master_node_ip
  fi

  local tmp_file_path
  tmp_file_path="$ki_tmp_root_path"/tmp-templates-vars.yml
  touch "$tmp_file_path"
  $yq_cmd -i ".internal_network_zone = load(\"$vars_path\").internal_network_zone" "$tmp_file_path"
  $yq_cmd -i ".ns1_a_record_ip = \"$ns1_a_record_ip\"" "$tmp_file_path"
  $yq_cmd -i ".ki_cp_a_record_ip = \"$ki_cp_a_record_ip\"" "$tmp_file_path"
  $jinja2_cmd --format yaml -o "$svc_root_path""/internal-network-zone-db" "$SCRIPT_DIR_PATH"/templates/internal-network-zone-db.j2 "$tmp_file_path"
  rm "$tmp_file_path"
}

create_internal_network_extra_zone_db_file() {
  local ns1_a_record_ip
  if [[ $ki_cp_ha_mode = "true" ]]; then
    ns1_a_record_ip=$ki_cp_ha_mode_vip
  else
    master_node_ip=$(get_ki_cp_master_node_ip)
    ns1_a_record_ip=$master_node_ip
  fi

  local tmp_file_path
  tmp_file_path="$ki_tmp_root_path"/tmp-templates-vars.yml
  touch "$tmp_file_path"
  $yq_cmd -i ".internal_network_extra_zone = load(\"$vars_path\").internal_network_extra_zone" "$tmp_file_path"
  $yq_cmd -i ".ns1_a_record_ip = \"$ns1_a_record_ip\"" "$tmp_file_path"
  $yq_cmd -i ".a_records = load(\"$vars_path\").internal_network_extra_zone_a_records" "$tmp_file_path"
  $jinja2_cmd --format yaml -o "$svc_root_path""/internal-network-extra-zone-db" "$SCRIPT_DIR_PATH"/templates/internal-network-extra-zone-db.j2 "$tmp_file_path"
  rm "$tmp_file_path"
}

get_ki_cp_master_node_ih() {
  if [[ $target_node = "null" ]] || [[ $target_node != "null" && $target_node_op = "add" ]]; then
    $yq_cmd '.groups.ki_cp_node[0]' < "$vars_path"
  elif [[ $target_node != "null" && $target_node_op = "remove" ]]; then
    $yq_cmd ".groups.ki_cp_node - [\"$target_node\"] | .[0]" < "$vars_path"
  else
    die "[ERROR] Invalid variable[\"\target_node\"] or Invalid variable[\"\target_node_op\"]"
  fi
}

get_ki_cp_master_node_ip() {
  local ih
  ih=$(get_ki_cp_master_node_ih)
  $yq_cmd '.internal_network_hosts.'"$ih"'.interfaces[0].ip' < "$vars_path"
}

service_exists() {
  local svc_name=$1

  local ls_lines_len
  ls_lines_len=$(docker compose ls -a --filter name='^'"$svc_name"'$' | wc -l)
  if [[ $ls_lines_len = 2 ]]; then echo "true"; else echo "false"; fi

  return 0
}

require_not_setup() {
  local svc_name=$1

  [[ $(service_exists "$svc_name") = "true" ]] && die "[ERROR] Service[\"$svc_name\"] already setup"

  return 0
}

disable_resolved() {
  local result
  result=$("$ki_env_scripts_path"/systemctl.sh exists "systemd-resolved")
  [[ $result = true ]] && "$ki_env_scripts_path"/systemctl.sh disable systemd-resolved

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
