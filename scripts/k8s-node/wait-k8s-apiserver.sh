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

# Long enough for a control plane that is being replaced to come back, short
# enough that one which is not coming back is reported rather than waited on
APISERVER_READY_TIMEOUT=300
# How long the answer has to keep coming before it is believed. See
# wait_apiserver_ready for what this is sized against
APISERVER_STABLE_SECONDS=30
POLL_INTERVAL=2
# The answer /readyz gives when the apiserver is serving
READY_BODY=ok

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""

k8s_apiserver_port=""

# Waits until the apiserver of this node is serving and stays that way.
#
# What this is between is a node being worked on and the same node being given
# traffic again. Putting it back the moment the work returns is too early:
# kubeadm rewrites a static pod manifest and kubelet replaces the container
# after that, so the command finishing says nothing about whether the apiserver
# is up. The load balancer only learns of a backend that died from its own
# health check, which takes inter times fall to notice, and everything sent to
# that node until then fails.
#
# renew-certs does the same wait inside renew-k8s-certs.sh, where the restart it
# waits on is its own
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  k8s_apiserver_port=$($yq_cmd '.k8s_apiserver_port' < "$vars_path")

  wait_apiserver_ready

  return 0
}

# Against this node rather than through the vip. What the caller needs to know
# is whether this one is serving, and the vip would answer from whichever node
# happens to hold it, including while this one is down.
#
# One answer is not enough, because the apiserver this node runs is replaced
# twice and the first replacement is already serving when the second one is
# about to start. kubeadm rewrites the static pod manifest, kubelet brings that
# container up, and then kubeadm rewrites /var/lib/kubelet/config.yaml, so the
# kubelet restart that has to follow the package upgrade comes up against a
# configuration it did not have and builds the static pods again. Measured on
# one node of a 1.36 to 1.37 upgrade:
#
#   02:23:14  kubeadm writes /var/lib/kubelet/config.yaml
#   02:23:15  kubelet is restarted, the container from 02:20 still serving
#   02:23:15  a single probe here is answered by that container and passes
#   02:23:17  kubelet stops it
#   02:23:18  the node is given traffic again
#   02:23:21  the load balancer notices, three seconds of refused connections
#   02:23:27  the replacement is running
#
# So what is waited for is not an answer but an answer that keeps coming. The
# window has to outlast the gap between the restart and the stop, two seconds
# there, and the eleven the replacement took to come back. Thirty is that with
# room, and it is paid once per control plane node
wait_apiserver_ready() {
  local elapsed=0
  local stable=0

  while :; do
    if [[ $(get_apiserver_readyz) = "$READY_BODY" ]]; then
      [[ $stable -ge $APISERVER_STABLE_SECONDS ]] && break
      stable=$(("$stable" + "$POLL_INTERVAL"))
    else
      # The apiserver went away again, so nothing counted before it says
      # anything about the one answering now
      stable=0
    fi

    [[ $elapsed -ge $APISERVER_READY_TIMEOUT ]] &&
      die "[ERROR] Failed to wait for the apiserver of this node being ready. timeout occurred"

    sleep "$POLL_INTERVAL"s
    elapsed=$(("$elapsed" + "$POLL_INTERVAL"))
  done

  msg "[INFO] The apiserver of this node is ready"

  return 0
}

get_apiserver_readyz() {
  curl --silent --insecure --max-time 2 \
      "https://127.0.0.1:$k8s_apiserver_port/readyz" 2>/dev/null || true

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
