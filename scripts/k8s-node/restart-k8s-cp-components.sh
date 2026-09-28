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

# How long a static pod is given to shut down on its own before it is killed.
# kubeadm sets no terminationGracePeriodSeconds on these, so nothing else bounds
# it, and an apiserver that is finishing a request wants more than the ten
# seconds crictl would otherwise allow. The same number renew-k8s-certs.sh uses
STATIC_POD_STOP_TIMEOUT=45

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""

# Replaces the control plane components of this node that read a placed file, so
# that they read it again.
#
# A control plane component reads what its arguments name once, at start. A file
# that changed on disk is not picked up by rewriting the static pod manifest
# either: the manifest is the same file it was, so kubelet sees nothing to do and
# the process goes on running with what it read when it started. Only a restart
# moves it.
#
# Which components there are and what a changed file costs each of them is
# placed_file_restart of ki_k8s_cp_components in the vars file, not a list here.
# "always" is the apiserver, since k8s_cp_extra_files was made for it and what
# reaches this script is that some file changed rather than which one: restarting
# it a second time inside a window the node is already out of costs seconds, and
# not restarting it costs a file that was placed and never read. "when_mounting"
# is the two that are only reached through a volume of their own, where
# restarting moves a leader rather than a process. "never" is etcd, which takes
# no volumes.
#
# The caller takes this node out of every load balancer first and puts it back
# after, the same as renewing a certificate. Nothing here does that, because a
# node only stops being reachable through the vip once every ki cp node has been
# told, and this runs on one node
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  restart_by_policy "always"

  # Before the rest rather than after all of it. What the caller is waiting to
  # put back into the load balancer is the apiserver, and the components below
  # hold a lease against it: one brought back while the apiserver it renews
  # against is still starting comes up only to lose it
  wait_apiserver_ready

  restart_by_policy "when_mounting"

  return 0
}

restart_by_policy() {
  local policy=$1

  local count
  count=$($yq_cmd '.ki_k8s_cp_components // [] | length' < "$vars_path")

  local idx
  for (( idx = 0; idx < count; idx++ )); do
    [[ $($yq_cmd ".ki_k8s_cp_components[$idx].placed_file_restart" < "$vars_path") = "$policy" ]] || continue

    # A placed file reaches a component through a volume and no other way, so one
    # that declares none can not be holding the file that changed
    if [[ $policy = "when_mounting" ]]; then
      [[ $($yq_cmd ".ki_k8s_cp_components[$idx].volumes // [] | length" < "$vars_path") -gt 0 ]] || continue
    fi

    restart_static_pod "$($yq_cmd ".ki_k8s_cp_components[$idx].static_pod" < "$vars_path")"
  done

  return 0
}

# Stopping the container is what restarts a static pod: kubelet sees it exit and
# starts it again from the manifest. Moving the manifest out and back would do it
# too, and would leave the node with no manifest at all if anything failed in
# between.
#
# stop rather than rm -f, which is a kill. The apiserver is given the time to
# turn its own /readyz negative and finish what it is holding, which is the
# graceful shutdown it has for exactly this
restart_static_pod() {
  local static_pod_name=$1

  local container_ids
  container_ids=$(crictl ps --name "$static_pod_name" -q)
  # Silence here would mean reporting a restart that did not happen: the file on
  # disk is new and the process still holds the old one, which is only found when
  # somebody asks why the change did nothing
  [[ -z $container_ids ]] &&
    die "[ERROR] Found no running container of static pod[\"$static_pod_name\"] to restart. the files of this node were placed but nothing has read them yet"

  msg "[INFO] Restarting static pod[\"$static_pod_name\"]"
  # shellcheck disable=SC2086
  crictl stop --timeout $STATIC_POD_STOP_TIMEOUT $container_ids > /dev/null ||
    die "[ERROR] Failed to restart static pod[\"$static_pod_name\"]"

  return 0
}

# kubelet replaces the container after it is stopped, so the command returning
# says nothing about whether this apiserver is serving again, and the caller is
# about to put the node back into the load balancer
wait_apiserver_ready() {
  "$ki_opt_scripts_path"/k8s-node/wait-k8s-apiserver.sh --vars-path "$vars_path" ||
    die "[ERROR] Failed to wait for the apiserver of this node being ready"

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
