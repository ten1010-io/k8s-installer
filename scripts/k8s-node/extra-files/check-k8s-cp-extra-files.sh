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

FIELD_SEPARATOR="|"

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""

declare -a mount_paths=()
declare -A host_path_of=()
declare -A read_only_of=()

# Reports an argument of a control plane component that names a file this node
# does not have.
#
# An argument and a volume are declared together and mean nothing apart: the
# volume carries a directory of the node into the pod and the argument names a
# file inside it. A component given a path it can not read does not start, and
# what that costs is measured in README.adoc: the node has no apiserver until
# kubeadm puts its own manifest back, about five minutes, and the change did not
# apply. The other components are not in the load balancer, so a broken one of
# those is quieter and lasts longer. Saying so before anything is restarted turns
# either into a line of output.
#
# Which components there are and what each one was given is read out of
# ki_k8s_cp_components of the vars file rather than written out here, so opening
# one does not mean remembering this script. A component with no volumes_var
# takes no volumes, and no argument of it can name a file under a directory this
# would look in - that is etcd.
#
# Only volumes mounted read only are looked at. A writable one is a directory the
# component produces something in - an audit log is the case in hand - and being
# empty is what it looks like before the first write. A read only one is there to
# be consumed, so a file that is not in it is a mistake every time.
#
# Reported rather than failed, to stdout for a playbook to collect, the way
# check-vfio-pci.sh is. The playbook that has just placed the files is the one
# that turns silence into a requirement: at that point a missing file is not a
# warning about the future, it is this run having failed to do its job
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  local count
  count=$($yq_cmd '.ki_k8s_cp_components // [] | length' < "$vars_path")

  # One component at a time rather than one pool of volumes. A mount path is a
  # path inside one pod, so two components may mount different host paths at the
  # same place and neither says anything about the arguments of the other
  local idx
  for (( idx = 0; idx < count; idx++ )); do
    [[ $($yq_cmd ".ki_k8s_cp_components[$idx].volumes_var" < "$vars_path") = "null" ]] && continue

    local component
    component=$($yq_cmd ".ki_k8s_cp_components[$idx].name" < "$vars_path")

    mount_paths=()
    host_path_of=()
    read_only_of=()

    read_volumes "$idx"
    report_missing_files "$component" "$idx"
  done

  return 0
}

read_volumes() {
  local idx=$1

  local line
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    local mount_path="${line%%"$FIELD_SEPARATOR"*}"
    local rest="${line#*"$FIELD_SEPARATOR"}"
    mount_paths+=("$mount_path")
    host_path_of["$mount_path"]="${rest%%"$FIELD_SEPARATOR"*}"
    local read_only="${rest##*"$FIELD_SEPARATOR"}"
    read_only_of["$mount_path"]="${read_only,,}"
  done < <($yq_cmd ".ki_k8s_cp_components[$idx].volumes // [] | .[] | .mountPath + \"$FIELD_SEPARATOR\" + .hostPath + \"$FIELD_SEPARATOR\" + ((.readOnly // false) | tostring)" < "$vars_path")

  return 0
}

# The argument names a path inside the pod and this runs on the node, so the
# mount it falls under is what translates one into the other. The longest
# matching mount path wins, since a volume can be mounted inside another
report_missing_files() {
  local component=$1
  local idx=$2

  local line
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    local name="${line%%"$FIELD_SEPARATOR"*}"
    local value="${line#*"$FIELD_SEPARATOR"}"
    [[ $value != /* ]] && continue

    local mount_path
    mount_path=$(longest_mount_path_of "$value")
    [[ -z $mount_path ]] && continue
    [[ ${read_only_of["$mount_path"]} != "true" ]] && continue

    local node_path="${host_path_of["$mount_path"]}${value#"$mount_path"}"
    [[ -e $node_path ]] && continue

    echo "[WARN] Argument[\"$name\"] of the $component names path[\"$value\"], which is path[\"$node_path\"] of this node and is not there. The $component of this node will not start"
  done < <($yq_cmd ".ki_k8s_cp_components[$idx].args // [] | .[] | .name + \"$FIELD_SEPARATOR\" + (.value | tostring)" < "$vars_path")

  return 0
}

longest_mount_path_of() {
  local value=$1

  local longest=""
  local mount_path
  for mount_path in "${mount_paths[@]}"; do
    [[ $value != "$mount_path"/* && $value != "$mount_path" ]] && continue
    [[ ${#mount_path} -le ${#longest} ]] && continue
    longest="$mount_path"
  done

  echo "$longest"

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
