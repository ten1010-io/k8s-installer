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
jinja2_cmd=""

ki_tmp_join_credentials_path=""
ki_etc_kubeadm_path=""

main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  ki_tmp_join_credentials_path=$($yq_cmd '.ki_tmp_join_credentials_path' < "$vars_path")
  ki_etc_kubeadm_path=$($yq_cmd '.ki_etc_kubeadm_path' < "$vars_path")

  # Both of these are captured together with their stderr, so a failure has to be
  # looked at here rather than left to set -e. Dying on the assignment takes the
  # reason down with it: what kubeadm said is inside the variable being assigned,
  # and the run reports a script that exited 1 with nothing on either stream. A
  # clean install once spent a minute here against an apiserver it could not
  # reach yet and said none of that
  exit_code=0
  join_command=$(kubeadm token create --ttl 30m --print-join-command 2>&1) || exit_code=$?
  [[ $exit_code != 0 ]] &&
    die "[ERROR] Failed to create a join token. kubeadm said:\n$join_command"

  token=$(sed -nE 's/.*--token ([^ ]+).*/\1/p' <<< "$join_command")
  discovery_token_ca_cert_hash=$(sed -nE 's/.*--discovery-token-ca-cert-hash ([^ ]+).*/\1/p' <<< "$join_command")
  # An empty one would be written to the credentials file and fail at whichever
  # node tried to join with it, a long way from what went wrong
  [[ -z $token || -z $discovery_token_ca_cert_hash ]] &&
    die "[ERROR] Failed to read a join token out of what kubeadm printed:\n$join_command"

  # --config is not optional here, however little this phase seems to need it.
  # Run without one, kubeadm reads the ClusterConfiguration out of the cluster and
  # has no InitConfiguration at all, so the timeouts of v1beta4 keep their zero
  # value and kubernetesAPICall becomes no time whatsoever. The client then
  # refuses before it sends anything:
  #
  #   unable to create ClusterRoleBinding: client rate limiter Wait returned an
  #   error: rate: Wait(n=1) would exceed context deadline
  #
  # which names a rate limiter and means an expired deadline. Handed the same
  # configuration the node was built from, the phase takes a tenth of a second.
  # The two files are what init-k8s-cluster.sh rendered and they stay on the node,
  # which matters because add-node runs this on a cp node that is already up
  require_file_exists "$ki_etc_kubeadm_path/kubeadm-cluster-config.yml"
  require_file_exists "$ki_etc_kubeadm_path/kubeadm-init-config.yml"

  kubeadm_config_path=$(mktemp)
  cat "$ki_etc_kubeadm_path/kubeadm-cluster-config.yml" > "$kubeadm_config_path"
  echo "---" >> "$kubeadm_config_path"
  cat "$ki_etc_kubeadm_path/kubeadm-init-config.yml" >> "$kubeadm_config_path"

  exit_code=0
  upload_certs_output=$(kubeadm init phase upload-certs --upload-certs --config "$kubeadm_config_path" 2>&1) || exit_code=$?
  rm -f "$kubeadm_config_path"
  [[ $exit_code != 0 ]] &&
    die "[ERROR] Failed to upload the certificates. kubeadm said:\n$upload_certs_output"
  certificate_key=$(tail -1 <<< "$upload_certs_output")

  print_yaml "$token" "$discovery_token_ca_cert_hash" "$certificate_key" > "$ki_tmp_join_credentials_path"

  return 0
}

print_yaml() {
  cat <<EOF
---
token: "$1"
discovery_token_ca_cert_hash: "$2"
certificate_key: "$3"
EOF
}

import_ki_opt_vars() {
  ki_opt_root_path=$(grep -oP  "^ki_opt_root_path: \K(.+)" < "$vars_path")
  ki_opt_scripts_path=$(grep -oP  "^ki_opt_scripts_path: \K(.+)" < "$vars_path")
  ki_opt_bundle_path=$(grep -oP  "^ki_opt_bundle_path: \K(.+)" < "$vars_path")
  ki_opt_venv_path=$(grep -oP  "^ki_opt_venv_path: \K(.+)" < "$vars_path")
}

setup_cmd_vars() {
  yq_cmd="$ki_opt_bundle_path/bin/yq"
  jinja2_cmd="$ki_opt_venv_path/bin/jinja2"
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
