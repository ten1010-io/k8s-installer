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

SVC_NAME=ki-node-metrics
UNIT_DIR_PATH=/etc/systemd/system
SERVICE_PATH="$UNIT_DIR_PATH"/$SVC_NAME.service
TIMER_PATH="$UNIT_DIR_PATH"/$SVC_NAME.timer
# What the checks of this node write, and the only files this component owns. The
# certificate expiry beside them belongs to check-cert-expiry.sh and is left alone
METRICS_FILES=(kernel-args.prom vfio-pci.prom nvidia-cdi.prom k8s-cp-file-drift.prom)

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""

metrics_path=""

# Takes the timer and what it wrote away, so that a node the cluster no longer
# holds stops answering about a cluster it is not in
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  metrics_path=$($yq_cmd '.ki_metrics_path' < "$vars_path")

  disable_timer
  delete_unit_files
  delete_metrics_files

  return 0
}

# Keyed on the unit file rather than on the timer being enabled, so that running
# this twice is a no-op the second time and a node that never got this far is not
# asked to disable something systemd has never heard of
disable_timer() {
  if [[ -f $TIMER_PATH && $("$ki_opt_scripts_path"/systemctl.sh exists $SVC_NAME.timer) = "true" ]]; then
    "$ki_opt_scripts_path"/systemctl.sh disable $SVC_NAME.timer
  fi

  return 0
}

delete_unit_files() {
  rm -f "$SERVICE_PATH"
  rm -f "$TIMER_PATH"
  "$ki_opt_scripts_path"/systemctl.sh reload

  return 0
}

# Only the files this component writes. The directory stays, since the
# certificate expiry of this node is written into it by something else
delete_metrics_files() {
  local file
  for file in "${METRICS_FILES[@]}"; do
    rm -f "$metrics_path/$file"
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
