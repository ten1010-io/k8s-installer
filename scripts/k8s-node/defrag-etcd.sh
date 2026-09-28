#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--vars-path path]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--vars-path     File path
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

# How long the member is given to rewrite its database. The default of etcdctl is
# five seconds, which is shorter than a defragmentation of anything but an empty
# member, and a timeout here looks like a failure while the member carries on
# rewriting itself in the background
DEFRAG_TIMEOUT=10m

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""
etcdctl_cmd=""

# Defragments the etcd member of this node.
#
# What defragmentation does is give back the space the keys that are gone were
# holding. It is not what removes them - the apiserver compacts its own history
# every few minutes - so a member whose database is large and whose keys are few
# is fragmented, and nothing but this returns that space to the filesystem.
#
# It blocks the member while it runs. That is the whole reason this is called one
# node at a time by a caller that has taken the node out of every load balancer
# first, the same as renewing a certificate: the members that are not being
# worked on carry the cluster.
#
# The alarm is not disarmed here. It is one thing for the cluster rather than one
# per member, and disarming it before every member has room again is how it comes
# straight back
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  local before
  before=$(get_db_size)

  defrag

  local after
  after=$(get_db_size)

  msg "[INFO] Defragmented the etcd member of this node, from $(to_human "$before") to $(to_human "$after")"

  require_room_under_quota "$after"

  return 0
}

# Whether this member has room again, asked of the member rather than of the
# alarm.
#
# The alarm can not answer it. A NOSPACE alarm is raised by the write that runs
# out of room and never by the cluster noticing that it is full, so between one
# refused write and the next a cluster that is still over its quota carries no
# alarm at all - listing the alarms straight after disarming them comes back
# empty whatever state the members are in. The size against the quota is the
# condition itself, it comes out of the same status the sizes above come from,
# and it is per member, which is what being out of room is.
#
# Failing here stops the run before the members after this one are touched and
# before anything is disarmed, and says which node it was
require_room_under_quota() {
  local size=$1

  local quota
  quota=$(get_db_quota)

  [[ $size -lt $quota ]] && return 0

  die "[ERROR] The etcd member of this node holds $(to_human "$size") against a backend quota of $(to_human "$quota"), so it is still out of room after being defragmented. Nothing here returns more than this did: what the file holds is what the cluster holds, so the cluster needs either a larger quota or less in it"
}

defrag() {
  $etcdctl_cmd --endpoints=https://127.0.0.1:2379 --command-timeout=$DEFRAG_TIMEOUT defrag ||
    die "[ERROR] Failed to defragment the etcd member of this node"

  return 0
}

# The size of the file the member keeps its database in, which is what
# defragmentation changes. DbSizeInUse is what the keys actually need and does
# not move here, so the two together are what says whether this was worth doing
get_db_size() {
  $etcdctl_cmd --endpoints=https://127.0.0.1:2379 --command-timeout=10s endpoint status -w fields |
    grep -oP '^"DBSize"\s*:\s*\K[0-9]+' ||
    die "[ERROR] Failed to read the database size of the etcd member of this node"

  return 0
}

# The size the member refuses to write past. It is a member setting rather than
# a cluster one - nothing here sets it, so it is whatever etcd was started with,
# which is 2GiB unless the operator raised it
get_db_quota() {
  $etcdctl_cmd --endpoints=https://127.0.0.1:2379 --command-timeout=10s endpoint status -w fields |
    grep -oP '^"DBSizeQuota"\s*:\s*\K[0-9]+' ||
    die "[ERROR] Failed to read the database quota of the etcd member of this node"

  return 0
}

to_human() {
  local bytes=$1

  awk -v bytes="$bytes" 'BEGIN {
    split("B Ki Mi Gi Ti Pi", unit, " ")
    i = 1
    while (bytes >= 1024 && i < 6) { bytes /= 1024; i++ }
    printf (i == 1) ? "%d%s" : "%.1f%s", bytes, unit[i]
  }'

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
  etcdctl_cmd="etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/peer.crt --key=/etc/kubernetes/pki/etcd/peer.key"
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
