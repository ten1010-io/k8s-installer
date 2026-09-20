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

SVC_NAME=ki-cp-keepalived

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""
jinja2_cmd=""

ki_etc_services_path=""
ki_tmp_root_path=""
target_node=""
target_node_op=""
inventory_hostname=""
ki_cp_ha_mode=""
ki_cp_ha_mode_vip=""

svc_root_path=""

main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  ki_etc_services_path=$($yq_cmd '.ki_etc_services_path' < "$vars_path")
  ki_tmp_root_path=$($yq_cmd '.ki_tmp_root_path' < "$vars_path")
  target_node=$($yq_cmd '.target_node' < "$vars_path")
  target_node_op=$($yq_cmd '.target_node_op' < "$vars_path")
  inventory_hostname=$($yq_cmd '.inventory_hostname' < "$vars_path")
  ki_cp_ha_mode=$($yq_cmd '.ki_cp_ha_mode' < "$vars_path")
  ki_cp_ha_mode_vip=$($yq_cmd '.ki_cp_ha_mode_vip' < "$vars_path")

  [[ $ki_cp_ha_mode = "false" ]] && exit 0
  svc_root_path="$ki_etc_services_path"/$SVC_NAME
  [[ $update = "false" ]] && require_not_setup $SVC_NAME

  docker load -i "$ki_opt_bundle_path"/ki-cp-service-images/$SVC_NAME.tar

  mkdir -p "$svc_root_path"
  $jinja2_cmd --format yaml -o "$svc_root_path""/check_node.sh" "$SCRIPT_DIR_PATH"/templates/check_node.sh.j2 "$vars_path"
  chmod +x "$svc_root_path""/check_node.sh"
  $jinja2_cmd --format yaml -o "$svc_root_path""/compose.yml" "$SCRIPT_DIR_PATH"/templates/compose.yml.j2 "$vars_path"
  create_keepalived_conf_file

  [[ $update = "true" && $(service_exists $SVC_NAME) = "true" ]] && docker compose -f "$svc_root_path/compose.yml" down
  docker compose -f "$svc_root_path/compose.yml" up -d

  return 0
}

create_keepalived_conf_file() {
  local interface
  local unicast_src_ip
  local priority
  local unicast_peers

  require_ki_cp_node "$inventory_hostname"
  interface=$(get_if "$inventory_hostname")
  unicast_src_ip=$(get_ip "$inventory_hostname")
  priority=$(get_priority "$inventory_hostname")
  unicast_peers=$(get_unicast_peers "$inventory_hostname")

  local tmp_file_path
  tmp_file_path="$ki_tmp_root_path"/tmp-templates-vars.yml
  touch "$tmp_file_path"
  $yq_cmd -i ".interface = \"$interface\"" "$tmp_file_path"
  $yq_cmd -i ".unicast_src_ip = \"$unicast_src_ip\"" "$tmp_file_path"
  $yq_cmd -i ".priority = \"$priority\"" "$tmp_file_path"
  $yq_cmd -i ".unicast_peers = $unicast_peers" "$tmp_file_path"
  $yq_cmd -i ".ki_cp_ha_mode_vip = load(\"$vars_path\").ki_cp_ha_mode_vip" "$tmp_file_path"
  $jinja2_cmd --format yaml -o "$svc_root_path""/keepalived.conf" "$SCRIPT_DIR_PATH"/templates/keepalived.conf.j2 "$tmp_file_path"
  rm "$tmp_file_path"
}

# Every node writes the same state, so nothing here derives one any more. What
# the derivation also did was reject a node that is not a member, and that is
# still worth doing before the rest of the render reads the node out of a list
# it is not in
require_ki_cp_node() {
  local ih=$1

  local is_member
  is_member=$($yq_cmd --null-input "$(get_ki_cp_ih_list) | contains([\"$ih\"])")
  [[ $is_member = "true" ]] ||
    die "[ERROR] Node[\"$ih\"] not belong to ki_cp_node group"

  return 0
}

get_if() {
  local ih=$1
  $yq_cmd ".internal_network_hosts.$ih.interfaces[0].if" < "$vars_path"
}

get_ip() {
  local ih=$1
  $yq_cmd ".internal_network_hosts.$ih.interfaces[0].ip" < "$vars_path"
}

get_priority() {
  local ih=$1

  local ki_cp_ih_list
  local idx
  ki_cp_ih_list=$(get_ki_cp_ih_list)
  idx=$($yq_cmd --null-input "$ki_cp_ih_list | .[] | select(. == \"$ih\") | key")
  [[ -z $idx ]] && die "[ERROR] Runtime error occurred"

  echo $((101 - "$idx"))
}

get_unicast_peers() {
  local ih=$1

  local ki_cp_ih_list
  local peer_ih_list
  local peers="[]"
  ki_cp_ih_list=$(get_ki_cp_ih_list)
  peer_ih_list=$($yq_cmd --null-input "$ki_cp_ih_list - [\"$ih\"] | join(\" \")")
  for peer_ih in $peer_ih_list; do
    local ip
    ip=$(get_ip "$peer_ih")
    peers=$($yq_cmd --null-input "$peers + [\"$ip\"]" -o json)
  done

  echo "$peers"
}

get_ki_cp_ih_list() {
  if [[ $target_node = "null" ]] || [[ $target_node != "null" && $target_node_op = "add" ]]; then
    $yq_cmd -o json '.groups.ki_cp_node' < "$vars_path"
  elif [[ $target_node != "null" && $target_node_op = "remove" ]]; then
    $yq_cmd -o json ".groups.ki_cp_node - [\"$target_node\"]" < "$vars_path"
  else
    die "[ERROR] Invalid variable[\"\target_node\"] or Invalid variable[\"\target_node_op\"]"
  fi
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
