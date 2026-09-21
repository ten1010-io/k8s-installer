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

# The static pods that hold a renewed certificate open. Each one reads its
# certificate once, at start, so none of them is using the new one until it has
# been restarted. etcd is in the list because its peer and server certificates
# are renewed too
STATIC_POD_NAMES=(kube-apiserver kube-controller-manager kube-scheduler etcd)
# How long each of them is given to shut down on its own before it is killed.
# kubeadm sets no terminationGracePeriodSeconds on these, so nothing else bounds
# it, and an apiserver that is finishing a request wants more than the ten
# seconds crictl would otherwise allow
STATIC_POD_STOP_TIMEOUT=45
# Long enough for etcd to rejoin and the apiserver behind it to answer, short
# enough that a node which is not coming back is reported rather than waited on
APISERVER_READY_TIMEOUT=300

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""

k8s_apiserver_port=""

# Renews the certificates kubeadm issued to this node and restarts what holds
# them, so the node serves on the new ones before anything is sent to it again.
#
# The caller takes this node out of every load balancer first and puts it back
# after. Nothing here does that, because a node only stops being reachable
# through the vip once every ki cp node has been told, and this runs on one node
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  k8s_apiserver_port=$($yq_cmd '.k8s_apiserver_port' < "$vars_path")

  renew_certs
  restart_static_pods
  wait_apiserver_ready
  refresh_kubeconfig

  return 0
}

renew_certs() {
  msg "[INFO] Renewing the certificates of this node"
  kubeadm certs renew all ||
    die "[ERROR] Failed to renew the certificates of this node"

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
restart_static_pods() {
  local name
  for name in "${STATIC_POD_NAMES[@]}"; do
    local container_ids
    container_ids=$(crictl ps --name "$name" -q)
    # Silence here would mean reporting a renewal that nothing is using: the
    # certificate on disk is new and the process still holds the old one, which
    # is only found when it expires
    [[ -z $container_ids ]] &&
      die "[ERROR] Found no running container of static pod[\"$name\"] to restart. the certificates of this node were renewed but nothing is serving on them yet"

    msg "[INFO] Restarting static pod[\"$name\"]"
    # shellcheck disable=SC2086
    crictl stop --timeout $STATIC_POD_STOP_TIMEOUT $container_ids > /dev/null ||
      die "[ERROR] Failed to restart static pod[\"$name\"]"
  done

  return 0
}

# Against this node rather than through the vip. What the caller needs to know
# before it puts the node back is whether this one is serving, and the vip would
# answer from whichever node happens to hold it
wait_apiserver_ready() {
  local elapsed=0
  while [[ $(get_apiserver_readyz) != "ok" ]]; do
    [[ $elapsed -ge $APISERVER_READY_TIMEOUT ]] &&
      die "[ERROR] Failed to wait for the apiserver of this node being ready. timeout occurred"

    sleep 2s
    elapsed=$(("$elapsed" + 2))
  done

  msg "[INFO] The apiserver of this node is ready"

  return 0
}

get_apiserver_readyz() {
  curl --silent --insecure --max-time 2 \
      "https://127.0.0.1:$k8s_apiserver_port/readyz" 2>/dev/null || true

  return 0
}

# admin.conf carries a certificate of its own and has just been renewed, and the
# copy under the home directory is what kubectl reads. Left alone it keeps the
# old certificate until it expires
refresh_kubeconfig() {
  [[ ! -f "$HOME"/.kube/config ]] && return 0

  cp -f /etc/kubernetes/admin.conf "$HOME"/.kube/config
  chown "$(id -u)":"$(id -g)" "$HOME"/.kube/config

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
