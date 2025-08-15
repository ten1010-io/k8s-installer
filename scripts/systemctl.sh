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

main() {
  local command
  command=${args[0]}

  case "$command" in
    exists)
      require_args_length 2
      exists "${args[1]}"
      exit 0
    ;;
    is-enabled)
      require_args_length 2
      is_enabled "${args[1]}"
      exit 0
    ;;
    is-running)
      require_args_length 2
      is_running "${args[1]}"
      exit 0
    ;;
    enable)
      require_args_length 2
      enable "${args[1]}"
      exit 0
    ;;
    disable)
      require_args_length 2
      disable "${args[1]}"
      exit 0
    ;;
    reload)
      require_args_length 1
      reload
      exit 0
    ;;
  esac

  die "[ERROR] Command[\"$command\"] not found"
}

exists() {
  local svc_name
  svc_name=$1

  local exit_code=0
  systemctl status "$svc_name" > /dev/null 2>&1 || exit_code=$?
  if [[ $exit_code = 4 ]]; then
    echo "false"
  else
    echo "true"
  fi

  return 0
}

is_enabled() {
  local svc_name
  svc_name=$1

  local exit_code=0
  systemctl -q is-enabled "$svc_name" > /dev/null 2>&1 || exit_code=$?

  if [[ $exit_code = 0 ]]; then echo "true"; else echo "false"; fi

  return 0
}

is_running() {
  local svc_name
  svc_name=$1

  local exit_code=0
  systemctl -q is-active "$svc_name" > /dev/null 2>&1 || exit_code=$?

  if [[ $exit_code = 0 ]]; then echo "true"; else echo "false"; fi

  return 0
}

enable() {
  local svc_name
  svc_name=$1

  systemctl enable "$svc_name"
  systemctl start "$svc_name"

  return 0
}

disable() {
  local svc_name
  svc_name=$1

  systemctl stop "$svc_name"
  systemctl disable "$svc_name"

  return 0
}

reload() {
  systemctl daemon-reload

  return 0
}

require_args_length() {
  local required_len
  required_len=$1

  local actual_len=${#args[@]}
  [[ $required_len != "$actual_len" ]] && die "[ERROR] Illegal number of arguments. required [$required_len] but actual [$actual_len]"

  return 0
}

main
