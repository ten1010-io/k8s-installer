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
  check_interval_sec=10

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --check-interval)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      check_interval_sec="${2-}"
      [[ ! $check_interval_sec =~ ^[0-9]+$ ]] && die "[ERROR] Value for --check-interval option must be number"
      shift
      ;;
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
  while true; do
    delete_pods_on_not_ready_nodes

    sleep "$check_interval_sec"s
  done

  return 0
}

delete_pods_on_not_ready_nodes() {
  name_lines=$(get_not_ready_nodes)
  while read -r name; do
    [[ -z $name ]] && continue

    delete_keycloak_pods_if_exist "$name"
    delete_harbor_pods_if_exist "$name"
  done <<< "$name_lines"

  return 0
}

get_not_ready_nodes() {
  kubectl get nodes --no-headers | sed -n '/\sNotReady\s/ s/^\(\S\+\)\s\+NotReady.*$/\1/g p'

  return 0
}

delete_keycloak_pods_if_exist() {
  local node=$1

  local pods_count
  pods_count=$(kubectl get pods --no-headers -n aipub -l app.kubernetes.io/instance=keycloak --field-selector spec.nodeName="$node" 2> /dev/null | wc -l)
  if [[ $pods_count -gt 0 ]]; then
    msg "[INFO] Started to delete aipub keycloak pods on not ready node[\"$name\"]"
    kubectl delete pods -n aipub --grace-period=0 --force -l app.kubernetes.io/instance=keycloak --field-selector spec.nodeName="$node"
  fi

  return 0
}

delete_harbor_pods_if_exist() {
  local node=$1

  local pods_count
  pods_count=$(kubectl get pods --no-headers -n aipub -l app.kubernetes.io/name=harbor --field-selector spec.nodeName="$node" 2> /dev/null | wc -l)
  if [[ $pods_count -gt 0 ]]; then
    msg "[INFO] Started to delete aipub harbor pods on not ready node[\"$name\"]"
    kubectl delete pods -n aipub --grace-period=0 --force -l app.kubernetes.io/name=harbor --field-selector spec.nodeName="$node"
  fi

  return 0
}

main
