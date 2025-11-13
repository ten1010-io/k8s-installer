#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--check-interval] [-f]
Available options:
-h, --help        Print this help and exit
-v, --verbose     Print script debug info
--check-interval  Check interval
-f                File path of sts-list.txt
EOF
  exit
}

parse_params() {
  check_interval_sec=10
  sts_list_txt_path=""

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
    -f)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      sts_list_txt_path="${2-}"
      shift
      ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ -z "${sts_list_txt_path-}" ]] && die "[ERROR] Missing required option: -f"

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

JSONPATH="{range .items[*]}{.spec.nodeName}{'/'}{.metadata.namespace}{'/'}{.metadata.name}{'/'}{.metadata.ownerReferences[0].kind}{'/'}{.metadata.ownerReferences[0].name}{'\n'}"

sts_list=""
not_ready_nodes=""
all_pod_lines=""

main() {
  [[ ! -e $sts_list_txt_path ]] && die "[ERROR] File[\"$sts_list_txt_path\"] not exists"
  readarray -t sts_list < "$sts_list_txt_path"

  while true; do
    not_ready_nodes=$(kubectl get nodes --no-headers | sed -n '/\sNotReady\s/ s/^\(\S\+\)\s\+NotReady.*$/\1/g p')
    all_pod_lines=$(kubectl get pods -A -o jsonpath="$JSONPATH")
    delete_sts_pods_on_not_ready_nodes

    sleep "$check_interval_sec"s
  done

  return 0
}

delete_sts_pods_on_not_ready_nodes() {
  local name sts

  while read -r name; do
    [[ -z $name ]] && continue

    for sts in "${sts_list[@]}"; do
      [[ -z $sts ]] && continue

      delete_pods "$name" "$sts"
    done
  done <<< "$not_ready_nodes"

  return 0
}

delete_pods() {
  local node_name=$1
  local sts=$2

  local sts_ns sts_name target_pod_lines line words token pod_name

  sts_ns=$(get_ns "$sts")
  sts_name=$(get_name "$sts")

  local exit_code=0
  target_pod_lines=$(grep -oP '^'"$node_name"'/'"$sts_ns"'/[a-z0-9\-\.]+/StatefulSet/'"$sts_name"'$' <<< "$all_pod_lines") || exit_code=$?
  [[ $exit_code -ne 0 ]] && return 0

  OLD_IFS=$IFS; IFS=$'\n'
  for line in $target_pod_lines; do
    words=()
    OLD_IFS=$IFS; IFS="/"
    for token in $line; do
      words+=("$token")
    done
    IFS=$OLD_IFS
    pod_name=${words[2]}
    msg "[INFO] Started to delete pod[\"$sts_ns/$pod_name\"] of sts[\"$sts\"] on not ready node[\"$node_name\"]"
    kubectl delete pod -n "$sts_ns" "$pod_name" --ignore-not-found --grace-period=0 --force
  done
  IFS=$OLD_IFS

  return 0
}

get_ns() {
  local sts=$1

  words=()
  OLD_IFS=$IFS; IFS="/"
  for token in $sts; do
    words+=("$token")
  done
  IFS=$OLD_IFS

  echo "${words[0]}"

  return 0
}

get_name() {
  local sts=$1

  words=()
  OLD_IFS=$IFS; IFS="/"
  for token in $sts; do
    words+=("$token")
  done
  IFS=$OLD_IFS

  echo "${words[1]}"

  return 0
}

main
