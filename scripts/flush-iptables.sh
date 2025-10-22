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
  if [[ $(has_command iptables) = "true" ]]; then
    disable_service_if_exists ufw
    disable_service_if_exists firewalld
    iptables -F; iptables -t nat -F; iptables -t mangle -F
    iptables -X; iptables -t nat -X; iptables -t mangle -X
    restart_service_if_running docker
  fi

  return 0
}

has_command() {
  local command
  command=$1

  exit_code=0
  type "$command" &>/dev/null || exit_code=$?
  if [[ $exit_code = 0 ]]; then echo "true"; else echo "false"; fi

  return 0
}

disable_service_if_exists() {
  local svc_name=$1

  local result
  result=$("$SCRIPT_DIR_PATH/systemctl.sh" exists "$svc_name")
  [[ $result = true ]] && "$SCRIPT_DIR_PATH/systemctl.sh" disable "$svc_name"

  return 0
}

restart_service_if_running() {
  local svc_name=$1

  local result
  result=$("$SCRIPT_DIR_PATH/systemctl.sh" is-running "$svc_name")
  [[ $result = true ]] && systemctl restart "$svc_name"

  return 0
}

main
