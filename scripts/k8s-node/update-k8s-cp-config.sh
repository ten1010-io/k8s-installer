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

ki_etc_kubeadm_path=""

# Writes the control plane manifests of this node again from the kubeadm
# configuration the cluster holds, so that what its apiserver is running with is
# what was uploaded.
#
# Uploading the configuration is not enough on its own. kubeadm keeps it in a
# ConfigMap and kubelet runs the apiserver from a file in the static pod
# directory, so an argument that was added reaches the node the next time
# something writes that file, which without this is the next cluster upgrade.
#
# The caller takes this node out of every load balancer first and puts it back
# after, the same as renewing a certificate: the apiserver is replaced, and a
# node only stops being reachable through the vip once every ki cp node has been
# told
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  ki_etc_kubeadm_path=$($yq_cmd '.ki_etc_kubeadm_path' < "$vars_path")

  rewrite_control_plane
  wait_apiserver_ready

  return 0
}

# The phase rather than the whole of "upgrade node", which would rewrite the
# kubelet configuration of this node as well and is the wrong verb for a cluster
# that is not moving anywhere. Reading the configuration from the cluster is also
# what makes this work on a control plane node that joined: nothing on such a
# node holds an InitConfiguration to render a manifest from.
#
# Certificate renewal is off. It is on by default for an upgrade, and leaving it
# on would renew the certificates of a node every time an argument changes, which
# is a second thing happening under one word. renew-certs.yml is where that is
# asked for.
#
# The patches directory is the one kubeadm was given at init and at join, so a
# release that starts patching a control plane component is not left out here
rewrite_control_plane() {
  msg "[INFO] Writing the control plane manifests of this node from the configuration of the cluster"
  kubeadm upgrade node phase control-plane \
      --certificate-renewal=false \
      --patches "$ki_etc_kubeadm_path""/patches" ||
    die "[ERROR] Failed to write the control plane manifests of this node"

  return 0
}

# kubelet replaces the containers after the manifests change, so the command
# returning says nothing about whether this apiserver is serving again, and the
# caller is about to put the node back into the load balancer
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
