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

SVC_NAME=ki-cp-k8s-cp-lb

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

svc_root_path=""
admin_socket_path=""
server_state_path=""
stats_password_path=""

main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  ki_etc_services_path=$($yq_cmd '.ki_etc_services_path' < "$vars_path")
  ki_tmp_root_path=$($yq_cmd '.ki_tmp_root_path' < "$vars_path")
  target_node=$($yq_cmd .target_node < "$vars_path")
  target_node_op=$($yq_cmd .target_node_op < "$vars_path")

  svc_root_path="$ki_etc_services_path"/$SVC_NAME
  [[ $update = "false" ]] && require_not_setup $SVC_NAME

  docker load -i "$ki_opt_bundle_path"/ki-cp-service-images/$SVC_NAME.tar

  admin_socket_path=$($yq_cmd '.ki_cp_k8s_cp_lb_admin_socket_path' < "$vars_path")
  server_state_path=$($yq_cmd '.ki_cp_k8s_cp_lb_server_state_path' < "$vars_path")
  stats_password_path=$($yq_cmd '.ki_cp_k8s_cp_lb_stats_password_path' < "$vars_path")

  mkdir -p "$svc_root_path"

  local haproxy_cfg_before
  local container_id_before
  haproxy_cfg_before=$(checksum_of "$svc_root_path/haproxy.cfg")
  container_id_before=$(get_container_id)

  create_compose_yml_file
  create_haproxy_cfg_file
  create_stats_password_file

  validate_haproxy_cfg

  local haproxy_cfg_changed="false"
  [[ $(checksum_of "$svc_root_path/haproxy.cfg") != "$haproxy_cfg_before" ]] && haproxy_cfg_changed="true"

  # Before the reload rather than after, since the running load balancer is the
  # only thing that knows which backends were taken out by hand
  [[ -n $container_id_before && $haproxy_cfg_changed = "true" ]] && save_server_state

  # No down first. Recreating the container drops every connection through it,
  # which for a node being added or removed is an outage of the whole control
  # plane, and up on its own leaves a running container alone
  docker compose -f "$svc_root_path/compose.yml" up -d

  # A container that compose replaced has read the new configuration already.
  # One it left alone has not, since the configuration reaches it as a bind
  # mount and nothing told it to look again
  [[ $haproxy_cfg_changed = "true" && -n $container_id_before && $container_id_before = $(get_container_id) ]] &&
    reload

  return 0
}

# What gather-facts.yml reads before it mints a password, so that the one this
# cluster is already using survives a run of the playbooks. Readable by root
# only, since it is the credential of the stats page
create_stats_password_file() {
  local password
  password=$($yq_cmd '.ki_cp_k8s_cp_lb_stats_admin_pw' < "$vars_path")

  (
    umask 077
    printf '%s\n' "$password" > "$stats_password_path"
  )

  return 0
}

# Before anything is started or reloaded. A configuration haproxy refuses takes
# the master down, the workers watch the master and exit with it, and the restart
# policy of the compose file turns that into a crash loop. Nothing else would
# catch it: apply-service-var-changes.yml runs this on every ki cp node without
# serial, so a file that does not parse would take every load balancer of the
# cluster at once, and keepalived can not move the vip to a node that is in the
# same state. The directives this file carries are not all plain haproxy either -
# the prometheus exporter is there only in a build that was made with USE_PROMEX
#
# run rather than exec, so that the first setup is covered as well as an update.
# It takes the volumes and the environment of the service from the compose file,
# and without --service-ports it publishes nothing, so it does not collide with
# the container that is already running
validate_haproxy_cfg() {
  docker compose -f "$svc_root_path/compose.yml" run --rm --entrypoint haproxy haproxy \
    -c -f /usr/local/etc/haproxy/haproxy.cfg ||
    die "[ERROR] haproxy refused the rendered configuration. Nothing has been started or reloaded"

  return 0
}

# SIGUSR2 is what the master process of haproxy takes as a reload. It forks a
# worker on the new configuration, hands it the listeners and leaves the old one
# to finish what it is holding, so nothing in flight is cut. The container stays
# up, which is why this is not a restart as far as docker is concerned
reload() {
  docker compose -f "$svc_root_path/compose.yml" kill -s USR2 haproxy

  return 0
}

# Best effort. A load balancer put there by a release that had no admin socket
# has nothing to ask, and losing which backends were out of rotation is not a
# reason to refuse the update
save_server_state() {
  printf 'show servers state\n' |
    docker compose -f "$svc_root_path/compose.yml" exec -T haproxy \
      sh -c "socat stdio '$admin_socket_path' > '$server_state_path'" ||
    msg "[WARN] Failed to save the state of the backends of the load balancer. they come back as the configuration has them"

  return 0
}

# Empty before the first setup, when there is no compose file to ask about yet
get_container_id() {
  [[ -f "$svc_root_path/compose.yml" ]] || return 0
  docker compose -f "$svc_root_path/compose.yml" ps -q haproxy 2>/dev/null || true

  return 0
}

checksum_of() {
  local path=$1

  [[ -f $path ]] || { echo "absent"; return 0; }
  md5sum < "$path"

  return 0
}

create_compose_yml_file() {
  local tmp_file_path
  tmp_file_path="$ki_tmp_root_path"/tmp-templates-vars.yml
  touch "$tmp_file_path"
  $yq_cmd -i ".ki_cp_k8s_cp_lb_port = load(\"$vars_path\").ki_cp_k8s_cp_lb_port" "$tmp_file_path"
  $yq_cmd -i ".ki_cp_k8s_cp_lb_stats_port = load(\"$vars_path\").ki_cp_k8s_cp_lb_stats_port" "$tmp_file_path"
  $yq_cmd -i ".ki_cp_k8s_cp_lb_stats_admin_pw = load(\"$vars_path\").ki_cp_k8s_cp_lb_stats_admin_pw" "$tmp_file_path"
  # Never the vip. keepalived carries it as a secondary address on this same
  # interface and it is inside the internal subnet, so the preflight finds it
  # beside the node address on whichever node is holding it. Publishing the
  # unauthenticated /metrics of the stats port there would put it on the one
  # address the whole cluster routes to
  local vip
  vip=$($yq_cmd '.ki_cp_ha_mode_vip' < "$vars_path")
  $yq_cmd -i ".lb_bind_ip = (load(\"$vars_path\").internal_network_interfaces | map(select(.ip != \"$vip\")) | .[0].ip)" "$tmp_file_path"
  $yq_cmd -i ".ki_cp_k8s_cp_lb_image = load(\"$vars_path\").ki_cp_k8s_cp_lb_image" "$tmp_file_path"
  $yq_cmd -i ".ki_cp_service_log_max_size = load(\"$vars_path\").ki_cp_service_log_max_size" "$tmp_file_path"
  $yq_cmd -i ".ki_cp_service_log_max_file = load(\"$vars_path\").ki_cp_service_log_max_file" "$tmp_file_path"
  $jinja2_cmd --strict --format yaml -o "$svc_root_path""/compose.yml" "$SCRIPT_DIR_PATH"/templates/compose.yml.j2 "$tmp_file_path"
  rm "$tmp_file_path"
}

create_haproxy_cfg_file() {
  local backend_server_ih_list
  backend_server_ih_list=$(get_backend_server_ih_list)

  local tmp_file_path
  tmp_file_path="$ki_tmp_root_path"/tmp-templates-vars.yml
  touch "$tmp_file_path"
  $yq_cmd -i ".ki_cp_k8s_cp_lb_port = load(\"$vars_path\").ki_cp_k8s_cp_lb_port" "$tmp_file_path"
  $yq_cmd -i ".backend_server_ih_list = $backend_server_ih_list" "$tmp_file_path"
  $yq_cmd -i ".internal_network_hosts = load(\"$vars_path\").internal_network_hosts" "$tmp_file_path"
  $yq_cmd -i ".k8s_apiserver_port = load(\"$vars_path\").k8s_apiserver_port" "$tmp_file_path"
  $yq_cmd -i ".ki_cp_k8s_cp_lb_stats_port = load(\"$vars_path\").ki_cp_k8s_cp_lb_stats_port" "$tmp_file_path"
  $yq_cmd -i ".ki_cp_k8s_cp_lb_admin_socket_path = load(\"$vars_path\").ki_cp_k8s_cp_lb_admin_socket_path" "$tmp_file_path"
  $yq_cmd -i ".ki_cp_k8s_cp_lb_server_state_path = load(\"$vars_path\").ki_cp_k8s_cp_lb_server_state_path" "$tmp_file_path"
  $jinja2_cmd --strict --format yaml -o "$svc_root_path""/haproxy.cfg" "$SCRIPT_DIR_PATH"/templates/haproxy.cfg.j2 "$tmp_file_path"
  rm "$tmp_file_path"
}

get_backend_server_ih_list() {
  if [[ $target_node = "null" ]] || [[ $target_node != "null" && $target_node_op = "add" ]]; then
    $yq_cmd '.k8s_cp_nodes' -o json < "$vars_path"
  elif [[ $target_node != "null" && $target_node_op = "remove" ]]; then
    $yq_cmd ".k8s_cp_nodes - [\"$target_node\"]" -o json < "$vars_path"
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
