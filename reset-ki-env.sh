#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
EOF
  exit
}

parse_params() {
  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

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

KI_ROOT_PATH=$SCRIPT_DIR_PATH
SCRIPTS_PATH=$KI_ROOT_PATH/scripts
BIN_PATH=$KI_ROOT_PATH/bin

YQ_CMD=$BIN_PATH/bin/yq

declare -a ok_result_ih_list=()
declare -a ok_result_hosts=()
declare -a ok_result_ports=()
declare -a ok_result_users=()

declare -a warning_result_ih_list=()
declare -a warning_result_hosts=()
declare -a warning_result_ports=()
declare -a warning_result_users=()
declare -a warning_result_exit_code_list=()
declare -a warning_result_stderr_list=()

declare -a failed_result_ih_list=()
declare -a failed_result_hosts=()
declare -a failed_result_ports=()
declare -a failed_result_users=()
declare -a failed_result_exit_code_list=()
declare -a failed_result_stderr_list=()

localhost_hostvars_ki_env_path=""

declare -a all_group_hostvars_ih_list=()
declare -a all_group_hostvars_ansible_hosts=()
declare -a all_group_hostvars_ansible_ports=()
declare -a all_group_hostvars_ansible_ssh_users=()
declare -a all_group_hostvars_ki_env_paths=()

inventory=""
constant_vars=""

main() {
  import_hostvars
  validate_hostvars
  reset_all_group_nodes
  reset_localhost

  msg ""
  msg "[INFO] Localhost and all group nodes has been reset successfully"

  return 0
}

import_hostvars() {
  inventory=$(<"$KI_ROOT_PATH"/inventory.yml)
  constant_vars=$(<"$KI_ROOT_PATH"/group_vars/all/constant-vars.yml)

  local ansible_host
  local ansible_port
  local ansible_ssh_user
  local ki_env_path

  localhost_hostvars_ki_env_path=$($YQ_CMD '.control_node.hosts.localhost.ki_env_path' <<< "$inventory")
  [[ $localhost_hostvars_ki_env_path = "null" ]] && localhost_hostvars_ki_env_path=$($YQ_CMD '.ki_env_path' <<< "$constant_vars")

  for ih in $($YQ_CMD '.all.hosts | keys | join(" ")' <<< "$inventory"); do
    all_group_hostvars_ih_list+=("$ih")

    ansible_host=$($YQ_CMD '.all.hosts.'"$ih"'.ansible_host' <<< "$inventory")
    all_group_hostvars_ansible_hosts+=("$ansible_host")

    ansible_port=$($YQ_CMD '.all.hosts.'"$ih"'.ansible_port' <<< "$inventory")
    [[ $ansible_port = "null" ]] && ansible_port=$($YQ_CMD '.ansible_port' <<< "$constant_vars")
    all_group_hostvars_ansible_ports+=("$ansible_port")

    ansible_ssh_user=$($YQ_CMD '.all.hosts.'"$ih"'.ansible_ssh_user' <<< "$inventory")
    [[ $ansible_ssh_user = "null" ]] && ansible_ssh_user=$($YQ_CMD '.ansible_ssh_user' <<< "$constant_vars")
    all_group_hostvars_ansible_ssh_users+=("$ansible_ssh_user")

    ki_env_path=$($YQ_CMD '.all.hosts.'"$ih"'.ki_env_path' <<< "$inventory")
    [[ $ki_env_path = "null" ]] && ki_env_path=$($YQ_CMD '.ki_env_path' <<< "$constant_vars")
    all_group_hostvars_ki_env_paths+=("$ki_env_path")
  done
}

validate_hostvars() {
  validate_ki_env_path "localhost" "$localhost_hostvars_ki_env_path"

  for i in "${!all_group_hostvars_ih_list[@]}"; do
    validate_ansible_host "${all_group_hostvars_ih_list[$i]}" "${all_group_hostvars_ansible_hosts[$i]}"
    validate_ansible_port "${all_group_hostvars_ih_list[$i]}" "${all_group_hostvars_ansible_ports[$i]}"
    validate_ansible_ssh_user "${all_group_hostvars_ih_list[$i]}" "${all_group_hostvars_ansible_ssh_users[$i]}"
    validate_ki_env_path "${all_group_hostvars_ih_list[$i]}" "${all_group_hostvars_ki_env_paths[$i]}"
  done
}

reset_all_group_nodes() {
  check_ssh_connection_with_ssh
  msg ""
  remove_ki_env_directory_with_ssh
}

reset_localhost() {
  msg "[INFO] Started to reset localhost"

  rm -rf "$localhost_hostvars_ki_env_path"
}

check_ssh_connection_with_ssh() {
  msg "[INFO] Started to check ssh connection for all group nodes"
  msg ""

  for i in "${!all_group_hostvars_ih_list[@]}"; do
    msg "[INFO] Checking ssh connection to a node[\"${all_group_hostvars_ih_list[$i]}\"]..."
    execute_ssh \
      "${all_group_hostvars_ih_list[$i]}" \
      "${all_group_hostvars_ansible_hosts[$i]}" \
      "${all_group_hostvars_ansible_ports[$i]}" \
      "${all_group_hostvars_ansible_ssh_users[$i]}" \
      "handle_ssh" \
      "exit"
  done

  print_result
  [[ ${#failed_result_ih_list[@]} -gt 0 ]] && exit 1
  clear_result

  return 0
}

remove_ki_env_directory_with_ssh() {
  msg "[INFO] Started to remove ki-env directory for all group nodes"
  msg ""

  for i in "${!all_group_hostvars_ih_list[@]}"; do
    msg "[INFO] Removing in the node[\"${all_group_hostvars_ih_list[$i]}\"]..."
    execute_ssh \
      "${all_group_hostvars_ih_list[$i]}" \
      "${all_group_hostvars_ansible_hosts[$i]}" \
      "${all_group_hostvars_ansible_ports[$i]}" \
      "${all_group_hostvars_ansible_ssh_users[$i]}" \
      "handle_ssh" \
      "rm -rf ${all_group_hostvars_ki_env_paths[$i]}"
  done

  print_result
  [[ ${#failed_result_ih_list[@]} -gt 0 ]] && exit 1
  clear_result

  return 0
}

execute_ssh() {
  local ih=$1
  local host=$2
  local port=$3
  local user=$4
  local handler=$5
  local script=$6

  local exit_code=0
  local stderr
    stderr=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -p "$port" "$user"@"$host" "$script" 2>&1 > /dev/null) || exit_code=$?

  $handler \
    "${all_group_hostvars_ih_list[$i]}" \
    "${all_group_hostvars_ansible_hosts[$i]}" \
    "${all_group_hostvars_ansible_ports[$i]}" \
    "${all_group_hostvars_ansible_ssh_users[$i]}" \
    $exit_code \
    "$stderr"

  return 0
}

handle_ssh() {
  local ih=$1
  local host=$2
  local port=$3
  local user=$4
  local exit_code=$5
  local stderr=$6

  if [[ $exit_code = 0 ]]; then
    if [[ -z $stderr ]]; then
      add_host_to_ok_result "$ih" "$host" "$port" "$user"
    else
      add_host_to_warning_result "$ih" "$host" "$port" "$user" "$exit_code" "$stderr"
    fi

    return 0
  fi

  add_host_to_failed_result "$ih" "$host" "$port" "$user" "$exit_code" "$stderr"
  return 0
}

print_result() {
  print_ok_result
  msg ""
  print_warning_result
  msg ""
  print_failed_result
}

print_ok_result() {
  msg "${GREEN}ok(${#ok_result_ih_list[@]}):${NOFORMAT}"
  for i in "${!ok_result_ih_list[@]}"; do
    local ssh
    ssh=$(build_ssh_str "${ok_result_hosts[$i]}" "${ok_result_ports[$i]}" "${ok_result_users[$i]}")
    msg "${GREEN}[${ok_result_ih_list[$i]}]${NOFORMAT} ssh: $ssh";
  done
}

print_warning_result() {
  msg "${YELLOW}warning(${#warning_result_ih_list[@]}):${NOFORMAT}"
  for i in "${!warning_result_ih_list[@]}"; do
    local ssh
    ssh="ssh: \"$(build_ssh_str "${warning_result_hosts[$i]}" "${warning_result_ports[$i]}" "${warning_result_users[$i]}")\""

    local exit_code
    exit_code="exit_code: \"${warning_result_exit_code_list[$i]}\""

    local stderr=
    if [[ ${warning_result_stderr_list[$i]} = "" ]]; then
      stderr="stderr: \"\""
    else
      stderr="stderr:\n${warning_result_stderr_list[$i]}"
    fi

    msg "${YELLOW}[${warning_result_ih_list[$i]}]${NOFORMAT} $ssh $exit_code $stderr";
  done
}

print_failed_result() {
  msg "${RED}failed(${#failed_result_ih_list[@]}):${NOFORMAT}"
  for i in "${!failed_result_ih_list[@]}"; do
    local ssh
    ssh="ssh: \"$(build_ssh_str "${failed_result_hosts[$i]}" "${failed_result_ports[$i]}" "${failed_result_users[$i]}")\""

    local exit_code
    exit_code="exit_code: \"${failed_result_exit_code_list[$i]}\""

    local stderr=
    if [[ ${failed_result_stderr_list[$i]} = "" ]]; then
      stderr="stderr: \"\""
    else
      stderr="stderr:\n${failed_result_stderr_list[$i]}"
    fi

    msg "${RED}[${failed_result_ih_list[$i]}]${NOFORMAT} $ssh $exit_code $stderr";
  done
}

add_host_to_ok_result() {
  local ih=$1
  local host=$2
  local port=$3
  local user=$4

  ok_result_ih_list+=("$ih")
  ok_result_hosts+=("$host")
  ok_result_ports+=("$port")
  ok_result_users+=("$user")
}

add_host_to_warning_result() {
  local ih=$1
  local host=$2
  local port=$3
  local user=$4
  local exit_code=$5
  local stderr=$6

  warning_result_ih_list+=("$ih")
  warning_result_hosts+=("$host")
  warning_result_ports+=("$port")
  warning_result_users+=("$user")
  warning_result_exit_code_list+=("$exit_code")
  warning_result_stderr_list+=("$stderr")
}

add_host_to_failed_result() {
  local ih=$1
  local host=$2
  local port=$3
  local user=$4
  local exit_code=$5
  local stderr=$6

  failed_result_ih_list+=("$ih")
  failed_result_hosts+=("$host")
  failed_result_ports+=("$port")
  failed_result_users+=("$user")
  failed_result_exit_code_list+=("$exit_code")
  failed_result_stderr_list+=("$stderr")
}

clear_result() {
  ok_result_ih_list=()
  ok_result_hosts=()
  ok_result_ports=()
  ok_result_users=()

  warning_result_ih_list=()
  warning_result_hosts=()
  warning_result_ports=()
  warning_result_users=()
  warning_result_exit_code_list=()
  warning_result_stderr_list=()

  failed_result_ih_list=()
  failed_result_hosts=()
  failed_result_ports=()
  failed_result_users=()
  failed_result_exit_code_list=()
  failed_result_stderr_list=()
}

validate_ansible_host() {
  local ih=$1
  local ansible_host=$2

  ip_regex="^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$";
  hostname_regex="^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])$";

  [[ ! $ansible_host =~ $ip_regex ]] && [[ ! $ansible_host =~ $hostname_regex ]] && die "[ERROR] Invalid ansible_host variable[\"$ansible_host\"] for host[\"$ih\"]"

  return 0
}

validate_ansible_port() {
  local ih=$1
  local ansible_port=$2

  port_regex="^([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$"

  [[ ! $ansible_port =~ $port_regex ]] && die "[ERROR] Invalid ansible_port variable[\"$ansible_port\"] for host[\"$ih\"]"

  return 0
}

validate_ansible_ssh_user() {
  local ih=$1
  local ansible_ssh_user=$2

  username_regex="^[a-z_]([a-z0-9_-]{0,31}|[a-z0-9_-]{0,30}\$)$"

  [[ ! $ansible_ssh_user =~ $username_regex ]] && die "[ERROR] Invalid ansible_ssh_user variable[\"$ansible_ssh_user\"] for host[\"$ih\"]"

  return 0
}

validate_ki_env_path() {
  local ih=$1
  local ki_env_path=$2

  absolute_path_regex="^/|(/[\\w-]+)+$"

  [[ ! $ki_env_path =~ $absolute_path_regex ]] && die "[ERROR] Invalid ki_env_path variable[\"$ki_env_path\"] for host[\"$ih\"]"

  return 0
}

build_ssh_str() {
  local host=$1
  local port=$2
  local user=$3

  echo "$user@$host -p $port"
}

main
