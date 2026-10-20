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
# The units of the host that carry the vip through the api of the cloud when
# the site says that is how it is carried. Beside the metrics timer in the one
# directory a reset does not clear, and taken away by the same script that puts
# them there
CARRIER_NAME=ki-cp-vip-carrier
UNIT_DIR_PATH=/etc/systemd/system
CARRIER_SERVICE_PATH="$UNIT_DIR_PATH"/$CARRIER_NAME.service
CARRIER_PATH_PATH="$UNIT_DIR_PATH"/$CARRIER_NAME.path
CARRIER_TIMER_PATH="$UNIT_DIR_PATH"/$CARRIER_NAME.timer

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
ki_cp_ha_mode_vip_carrier=""

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
  ki_cp_ha_mode_vip_carrier=$($yq_cmd '.ki_cp_ha_mode_vip_carrier' < "$vars_path")

  [[ $ki_cp_ha_mode = "false" ]] && exit 0
  svc_root_path="$ki_etc_services_path"/$SVC_NAME
  [[ $update = "false" ]] && require_not_setup $SVC_NAME

  docker load -i "$ki_opt_bundle_path"/ki-cp-service-images/$SVC_NAME.tar

  mkdir -p "$svc_root_path"
  local rendered_before
  rendered_before=$(checksum_of_directory "$svc_root_path")
  $jinja2_cmd --format yaml -o "$svc_root_path""/check_node.sh" "$SCRIPT_DIR_PATH"/templates/check_node.sh.j2 "$vars_path"
  chmod +x "$svc_root_path""/check_node.sh"
  $jinja2_cmd --format yaml -o "$svc_root_path""/compose.yml" "$SCRIPT_DIR_PATH"/templates/compose.yml.j2 "$vars_path"
  create_keepalived_conf_file
  create_carrier_hook_files
  local rendered_after
  rendered_after=$(checksum_of_directory "$svc_root_path")

  [[ $update = "true" && $(service_exists $SVC_NAME) = "true" && $rendered_after != "$rendered_before" ]] &&
    docker compose -f "$svc_root_path/compose.yml" down
  docker compose -f "$svc_root_path/compose.yml" up -d

  # After the container, so that the first word keepalived writes lands in a
  # directory the unit is already watching, or is read by the service started
  # here: either way a node that comes up MASTER is carried
  if [[ $ki_cp_ha_mode_vip_carrier != "arp" ]]; then
    setup_carrier_units
  else
    remove_carrier_units
  fi

  return 0
}

# What the container calls on a transition and where it writes: the hook and
# the directory the state file lives in. arp is the one carrier that has
# nothing to be told, since the node announces the address itself, so it is the
# one that gets no hook; every other carrier is a call to an api that has to
# be made on the host. Taken away with arp so that a site that went back is
# left with what it had. The state directory goes too - a file in it saying
# MASTER would be the first thing the carrier read if the site came back, and
# a transition is what should say that, not a file from before
create_carrier_hook_files() {
  if [[ $ki_cp_ha_mode_vip_carrier != "arp" ]]; then
    mkdir -p "$svc_root_path"/state
    cp -f "$SCRIPT_DIR_PATH"/templates/notify.sh "$svc_root_path"/notify.sh
    chmod +x "$svc_root_path"/notify.sh
  else
    rm -rf "$svc_root_path"/state "$svc_root_path"/notify.sh
  fi

  return 0
}

# The path unit and the timer are what is enabled and the service is what they
# start, like the timer and service of the metrics. The service is run once
# here as well: the path unit only wakes on a write, and a keepalived that was
# already MASTER when the carrier was switched on has written its word already
setup_carrier_units() {
  $jinja2_cmd --format yaml -o "$CARRIER_SERVICE_PATH" "$SCRIPT_DIR_PATH"/templates/$CARRIER_NAME.service.j2 "$vars_path"
  $jinja2_cmd --format yaml -o "$CARRIER_PATH_PATH" "$SCRIPT_DIR_PATH"/templates/$CARRIER_NAME.path.j2 "$vars_path"
  cp -f "$SCRIPT_DIR_PATH"/templates/$CARRIER_NAME.timer "$CARRIER_TIMER_PATH"
  "$ki_opt_scripts_path"/systemctl.sh reload
  "$ki_opt_scripts_path"/systemctl.sh enable $CARRIER_NAME.path
  "$ki_opt_scripts_path"/systemctl.sh enable $CARRIER_NAME.timer
  "$ki_opt_scripts_path"/systemctl.sh restart $CARRIER_NAME.path
  "$ki_opt_scripts_path"/systemctl.sh restart $CARRIER_NAME.timer
  "$ki_opt_scripts_path"/systemctl.sh restart $CARRIER_NAME.service

  return 0
}

# Keyed on the unit files so that a node that never had them is a no-op, and
# one that had them is left with neither a watcher nor a service mid-attempt
remove_carrier_units() {
  [[ -f $CARRIER_PATH_PATH || -f $CARRIER_TIMER_PATH || -f $CARRIER_SERVICE_PATH ]] || return 0

  local unit
  for unit in $CARRIER_NAME.path $CARRIER_NAME.timer; do
    if [[ -f $UNIT_DIR_PATH/$unit && $("$ki_opt_scripts_path"/systemctl.sh exists "$unit") = "true" ]]; then
      "$ki_opt_scripts_path"/systemctl.sh disable "$unit"
      "$ki_opt_scripts_path"/systemctl.sh stop "$unit"
    fi
  done
  if [[ -f $CARRIER_SERVICE_PATH && $("$ki_opt_scripts_path"/systemctl.sh exists $CARRIER_NAME.service) = "true" ]]; then
    "$ki_opt_scripts_path"/systemctl.sh stop $CARRIER_NAME.service
  fi
  rm -f "$CARRIER_PATH_PATH" "$CARRIER_TIMER_PATH" "$CARRIER_SERVICE_PATH"
  "$ki_opt_scripts_path"/systemctl.sh reload

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
  $yq_cmd -i ".ki_cp_ha_mode_vip_carrier = load(\"$vars_path\").ki_cp_ha_mode_vip_carrier" "$tmp_file_path"
  $jinja2_cmd --strict --format yaml -o "$svc_root_path""/keepalived.conf" "$SCRIPT_DIR_PATH"/templates/keepalived.conf.j2 "$tmp_file_path"
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

# What the setup rendered, so that a run which changes nothing can leave the
# container where it is. compose notices a change to compose.yml by itself, but
# everything else here reaches the service as a bind mount and it has no way to
# know, which is why the service was taken down on every run whether or not
# there was anything new to read.
#
# The state directory is left out. keepalived writes it, not this script, and
# a transition between the two sums would read as a render that changed
checksum_of_directory() {
  local path=$1

  [[ ! -d $path ]] && { echo "absent"; return 0; }
  find "$path" -type f -not -path "$path/state/*" -exec md5sum {} + | sort | md5sum

  return 0
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
