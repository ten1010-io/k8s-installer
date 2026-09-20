#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--vars-path path] <command> [server]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--vars-path     File path
Available commands:
drain <server>       Stop giving the server new connections, leave the ones it has
ready <server>       Give the server connections again
wait-ready <server>  Wait for the load balancer to be giving the server traffic
status               Print the state of every server of the backend
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
  [[ ${#args[@]} -lt 1 ]] && die "[ERROR] Missing required command"

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
BACKEND_NAME=backend
# The columns of "show stat" that hold the name of a server, its operational
# state, the result of its last health check and how many sessions it is holding
NAME_FIELD=2
SESSIONS_FIELD=5
STATUS_FIELD=18
CHECK_STATUS_FIELD=37
# Long enough for an apiserver that is being restarted to come back, short enough
# that one which never will is reported rather than waited on
WAIT_READY_TIMEOUT=300

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""

ki_etc_services_path=""

etc_svc_root_path=""
admin_socket_path=""

# Taking a backend out of rotation before the apiserver on it is stopped is what
# keeps the requests in flight from failing. Without it the load balancer only
# learns of the loss from its health check, and everything it sent in the
# meantime fails.
#
# This talks to the runtime api of haproxy over the socket the load balancer
# keeps inside its container. Every ki cp node runs a load balancer of its own
# and the vip can move between them at any moment, so a node is only out of
# rotation once it has been drained on all of them
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  ki_etc_services_path=$($yq_cmd '.ki_etc_services_path' < "$vars_path")
  admin_socket_path=$($yq_cmd '.ki_cp_k8s_cp_lb_admin_socket_path' < "$vars_path")

  etc_svc_root_path="$ki_etc_services_path"/$SVC_NAME
  require_directory_exists "$etc_svc_root_path"

  local command=${args[0]}
  local server=${args[1]-}

  case "$command" in
  drain)
    require_server "$server"
    set_server_state "$server" drain
    ;;
  ready)
    require_server "$server"
    set_server_state "$server" ready
    ;;
  wait-ready)
    require_server "$server"
    require_server_exists "$server"
    wait_ready "$server" $WAIT_READY_TIMEOUT
    ;;
  status) print_status ;;
  *) die "[ERROR] Unknown command: $command" ;;
  esac

  return 0
}

require_server() {
  local server=${1-}

  [[ -z $server ]] && die "[ERROR] Missing required argument: server"

  return 0
}

# drain rather than maint. A server in maintenance has the sessions it is holding
# cut by the on-marked-down setting of the backend, which is meant for a server
# that failed rather than for one being taken out on purpose
set_server_state() {
  local server=$1
  local state=$2

  require_server_exists "$server"

  local result
  result=$(send "set server $BACKEND_NAME/$server state $state")
  [[ -n $result ]] && die "[ERROR] Failed to set the state of the server[\"$server\"]\n$result"

  msg "[INFO] Server[\"$server\"] of the backend is now \"$state\""

  return 0
}

# Waits for the load balancer to be giving the server traffic again rather than
# for its apiserver to answer, which are not the same thing: a server whose check
# has only just started passing reads "DOWN 1/2" until it has passed rise times
wait_ready() {
  local server=$1
  local timeout=$2

  local elapsed=0
  while [[ $(get_server_field "$server" $STATUS_FIELD) != "UP" ]]; do
    [[ $elapsed -ge $timeout ]] &&
      die "[ERROR] Failed to wait for the server[\"$server\"] being ready. timeout occurred"

    sleep 2s
    elapsed=$(("$elapsed" + 2))
  done

  msg "[INFO] Server[\"$server\"] of the backend is ready"

  return 0
}

print_status() {
  printf "%-24s %-14s %-10s %s\n" "SERVER" "STATE" "CHECK" "SESSIONS"
  get_backend_server_lines |
    awk -F, -v n=$NAME_FIELD -v s=$STATUS_FIELD -v c=$CHECK_STATUS_FIELD -v e=$SESSIONS_FIELD \
      '{ printf "%-24s %-14s %-10s %s\n", $n, $s, $c, $e }'

  return 0
}

require_server_exists() {
  local server=$1

  [[ -z $(get_server_field "$server" $NAME_FIELD) ]] &&
    die "[ERROR] The backend has no server[\"$server\"]. run \"status\" for the servers it has"

  return 0
}

get_server_field() {
  local server=$1
  local index=$2

  get_backend_server_lines | awk -F, -v n=$NAME_FIELD -v s="$server" -v i="$index" '$n == s { print $i }'

  return 0
}

# show stat prints one line per proxy, and the two of them whose name field reads
# FRONTEND or BACKEND are the proxy itself rather than one of its servers
get_backend_server_lines() {
  send "show stat" |
    awk -F, -v n=$NAME_FIELD -v b="$BACKEND_NAME" '$1 == b && $n != "FRONTEND" && $n != "BACKEND"'

  return 0
}

# socat rather than the /dev/tcp of bash, which speaks no unix socket, and rather
# than one installed on the node, where it is not present on every distribution.
# The image of the load balancer carries it
send() {
  local command=$1

  printf '%s\n' "$command" |
    docker compose --project-directory "$etc_svc_root_path" exec -T haproxy \
      socat stdio "$admin_socket_path" ||
    die "[ERROR] Failed to reach the runtime api of the load balancer through the socket[\"$admin_socket_path\"]"

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
