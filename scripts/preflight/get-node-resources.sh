#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--nodefs-path path] [--imagefs-path path]
Available options:
-h, --help        Print this help and exit
-v, --verbose     Print script debug info
--nodefs-path     Kubelet root path. Used to determine the filesystem of nodefs
--imagefs-path    Container runtime root path. Used to determine the filesystem of imagefs
EOF
  exit
}

parse_params() {
  nodefs_path="/var/lib/kubelet"
  imagefs_path="/var/lib/containerd"

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --nodefs-path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      nodefs_path="${2-}"
      shift
      ;;
    --imagefs-path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      imagefs_path="${2-}"
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

# Reports the compute resources of the node. The values are used to calculate
# kubelet resource reservations. See create-kubelet-reservations.py
#
# cpu_millicores and memory_kib are obtained from the same sources kubelet uses
# to report Capacity.cpu and Capacity.memory, so the calculated reservations
# match what kubelet accounts for

main() {
  local cpu_millicores
  local memory_kib
  local nodefs_bytes
  local imagefs_bytes
  local pid_max

  cpu_millicores=$(get_cpu_millicores)
  memory_kib=$(get_memory_kib)
  nodefs_bytes=$(get_filesystem_size_bytes "$nodefs_path")
  imagefs_bytes=$(get_filesystem_size_bytes "$imagefs_path")
  pid_max=$(get_pid_max)

  print_yaml "$cpu_millicores" "$memory_kib" "$nodefs_bytes" "$imagefs_bytes" "$pid_max"

  return 0
}

get_cpu_millicores() {
  local cpu_count
  cpu_count=$(nproc)

  [[ ! $cpu_count =~ ^[0-9]+$ ]] && die "[ERROR] Fail to get cpu count"
  [[ $cpu_count -le 0 ]] && die "[ERROR] Invalid cpu count[\"$cpu_count\"]"

  echo $(( cpu_count * 1000 ))

  return 0
}

get_memory_kib() {
  local memory_kib
  memory_kib=$(grep -oP "^MemTotal:\s+\K[0-9]+" /proc/meminfo)

  [[ -z $memory_kib ]] && die "[ERROR] Fail to get MemTotal from /proc/meminfo"

  echo "$memory_kib"

  return 0
}

# df fails on a path that does not exist. At the time this script runs, neither
# the kubelet nor the container runtime is installed yet, so walk up to the
# nearest existing ancestor before calling df
get_filesystem_size_bytes() {
  local path=$1

  local existing_path
  existing_path=$(get_nearest_existing_ancestor "$path")

  local size
  size=$(df -B1 --output=size "$existing_path" | tail -1 | tr -d " ")

  [[ ! $size =~ ^[0-9]+$ ]] && die "[ERROR] Fail to get filesystem size of path[\"$existing_path\"]"

  echo "$size"

  return 0
}

get_nearest_existing_ancestor() {
  local path=$1

  while [[ ! -e $path && $path != "/" ]]; do
    path=$(dirname "$path")
  done

  echo "$path"

  return 0
}

get_pid_max() {
  local pid_max
  pid_max=$(cat /proc/sys/kernel/pid_max)

  [[ ! $pid_max =~ ^[0-9]+$ ]] && die "[ERROR] Fail to get pid_max from /proc/sys/kernel/pid_max"

  echo "$pid_max"

  return 0
}

print_yaml() {
  cat <<EOF
---
cpu_millicores: $1
memory_kib: $2
nodefs_bytes: $3
imagefs_bytes: $4
pid_max: $5
EOF
}

main
