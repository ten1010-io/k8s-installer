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

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""
etcdctl_cmd=""

ki_etcd_backup_path=""
ki_etcd_backup_retention_count=""

# Takes a snapshot of etcd on this node, before anything that is about to change
# the cluster gets the chance to go wrong.
#
# Every k8s cp node takes its own. A snapshot holds the whole keyspace, so one
# would be enough to restore from, but a single copy lives on a node that can be
# the one that is lost. There is nowhere else to put it: the installer runs in an
# air gap and can not assume object storage or an export, so the copies are what
# there is. Carrying one off the node is the operator's to do and worth doing
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  ki_etcd_backup_path=$($yq_cmd '.ki_etcd_backup_path' < "$vars_path")
  ki_etcd_backup_retention_count=$($yq_cmd '.ki_etcd_backup_retention_count' < "$vars_path")

  # Checked rather than used as it comes. An upgrade keeps the vars.yml of the
  # user, so a cluster upgraded into this release has no count in it and yq
  # answers "null", which the arithmetic below would read as the name of a
  # variable and abort on. Saying which variable is missing beats that
  [[ $ki_etcd_backup_retention_count =~ ^[0-9]+$ ]] ||
    die "[ERROR] Variable[\"ki_etcd_backup_retention_count\"] is \"$ki_etcd_backup_retention_count\", which is not a number of snapshots to keep. Add it to vars.yml"
  [[ $ki_etcd_backup_retention_count -ge 1 ]] ||
    die "[ERROR] Variable[\"ki_etcd_backup_retention_count\"] is 0, which would remove the snapshot this is about to take"

  require_etcd_quorum

  local snapshot_path
  snapshot_path="$ki_etcd_backup_path"/etcd-$(date -u +%Y%m%dT%H%M%SZ).db

  mkdir -p "$ki_etcd_backup_path"
  chmod 700 "$ki_etcd_backup_path"

  save_snapshot "$snapshot_path"
  require_snapshot_usable "$snapshot_path"
  remove_snapshots_over_retention

  msg "[INFO] Etcd snapshot saved to file[\"$snapshot_path\"]"

  return 0
}

# A snapshot of a cluster that has lost quorum is taken from a member that may
# be behind the ones that are gone, so it would record less than the cluster
# held. Refusing says the cluster needs restoring rather than backing up, which
# is also what the caller of this wanted to know before it changed anything
require_etcd_quorum() {
  local output
  local exit_code=0
  output=$($etcdctl_cmd --endpoints=https://127.0.0.1:2379 --command-timeout=10s endpoint health 2>&1) || exit_code=$?

  [[ $exit_code != 0 ]] && die "[ERROR] Etcd cluster has no quorum, so a snapshot of it would not be one to restore from\n$output"

  return 0
}

# Written under a temporary name and moved into place only once it has been read
# back. A snapshot that was interrupted is a file of the right name and the
# wrong contents, and the moment that is found out is the moment it is needed
save_snapshot() {
  local snapshot_path=$1

  local tmp_path="$snapshot_path".partial
  rm -f "$tmp_path"

  (
    umask 077
    $etcdctl_cmd --endpoints=https://127.0.0.1:2379 snapshot save "$tmp_path"
  ) || {
    rm -f "$tmp_path"
    die "[ERROR] Failed to save an etcd snapshot to file[\"$snapshot_path\"]"
  }

  mv "$tmp_path" "$snapshot_path"

  return 0
}

# etcdutl rather than etcdctl. Reading a snapshot back is a local operation on a
# file and etcd moved it out of etcdctl, which only talks to a running cluster
require_snapshot_usable() {
  local snapshot_path=$1

  local output
  output=$(etcdutl snapshot status "$snapshot_path" -w table 2>&1) || {
    rm -f "$snapshot_path"
    die "[ERROR] Etcd snapshot in file[\"$snapshot_path\"] can not be read back, so it was removed rather than kept as one to restore from\n$output"
  }

  msg "$output"

  return 0
}

# Oldest first, which the names sort into because they carry a utc timestamp in
# a fixed width. Kept bounded because nothing else removes them: these sit on the
# root filesystem of a control plane node, and a directory that only grows there
# ends as a control plane that stopped for lack of disk
remove_snapshots_over_retention() {
  local snapshot_paths
  mapfile -t snapshot_paths < <(find "$ki_etcd_backup_path" -maxdepth 1 -type f -name 'etcd-*.db' | sort)

  local over=$((${#snapshot_paths[@]} - ki_etcd_backup_retention_count))
  [[ $over -le 0 ]] && return 0

  local i
  for ((i = 0; i < over; i++)); do
    msg "[INFO] Removing etcd snapshot over the retention count in file[\"${snapshot_paths[$i]}\"]"
    rm -f "${snapshot_paths[$i]}"
  done

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
