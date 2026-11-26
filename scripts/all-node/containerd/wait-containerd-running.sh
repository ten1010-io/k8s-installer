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

# How long containerd is given to answer after it was restarted. It answers
# within a second or two on a node that is running nothing, and a node that was
# only cordoned still has its containers for the daemon to find again
CONTAINERD_UP_TIMEOUT=120
POLL_INTERVAL=3

# Waits until the containerd of this node answers on the socket kubelet talks to
# it over, and checks that it is running with what it was just told.
#
# What this sits between is a restart of containerd and a node being given work
# again. systemctl returns once the unit has been started, and a containerd
# that does not like its configuration is, for a moment, a unit that was
# started. So the runtime is asked, the way kubelet asks it.
#
# And then asked what it holds. A key of the configuration that containerd does
# not know is not an error to it, so a setting written under the wrong table is
# a file that loads and a setting that is not in force. The one setting this
# installer makes switchable is read back out of the running daemon and
# compared with the variable it was rendered from
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  wait_containerd_up
  require_device_ownership_as_declared

  return 0
}

wait_containerd_up() {
  local elapsed=0
  while ! crictl info > /dev/null 2>&1; do
    [[ $elapsed -ge $CONTAINERD_UP_TIMEOUT ]] &&
      die "[ERROR] Failed to wait for containerd answering on its cri socket. timeout occurred\n$(journalctl -u containerd -n 20 --no-pager 2>/dev/null || true)"

    sleep ${POLL_INTERVAL}s
    elapsed=$((elapsed + POLL_INTERVAL))
  done

  return 0
}

require_device_ownership_as_declared() {
  local want
  want=$($yq_cmd '.containerd_device_ownership_from_security_context // false' < "$vars_path")

  local got
  got=$(crictl info | $yq_cmd -p json '.config.deviceOwnershipFromSecurityContext // false')

  [[ $got = "$want" ]] ||
    die "[ERROR] containerd of this node runs with device_ownership_from_security_context[$got] and variable[\"containerd_device_ownership_from_security_context\"] is $want"

  msg "[INFO] containerd of this node answers and runs with device_ownership_from_security_context[$got]"

  return 0
}

import_ki_opt_vars() {
  ki_opt_root_path=$(grep -oP  "^ki_opt_root_path: \K(.+)" < "$vars_path")
  ki_opt_scripts_path=$(grep -oP  "^ki_opt_scripts_path: \K(.+)" < "$vars_path")
  ki_opt_bundle_path=$(grep -oP  "^ki_opt_bundle_path: \K(.+)" < "$vars_path")
  ki_opt_venv_path=$(grep -oP  "^ki_opt_venv_path: \K(.+)" < "$vars_path")
}

setup_cmd_vars() {
  yq_cmd="$ki_opt_bundle_path/bin/$(uname -m)/yq"
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
