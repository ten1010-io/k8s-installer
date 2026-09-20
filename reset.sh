#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
EOF
  exit
}

parse_params() {
  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

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

KI_OPT_ROOT_PATH="/opt/k8s-installer"

main() {
  require_root
  [[ ! -e $KI_OPT_ROOT_PATH ]] && die "[ERROR] Directory[\"$KI_OPT_ROOT_PATH\"] not exists"

  msg "[INFO] Removing directory[\"$KI_OPT_ROOT_PATH\"]"
  msg ""
  msg "[INFO] This removes the installer of the control node only. Run the"
  msg "[INFO] reset-cluster.yml and reset-k8s-installer.yml playbooks first if the"
  msg "[INFO] managed nodes have not been reset yet"
  msg ""
  msg "[INFO] The inventory and the variables live in this directory and go with it."
  msg "[INFO] Keep a copy of the following if they are to be reused, since setup.sh"
  msg "[INFO] lays down the files of the release rather than the edited ones"
  msg ""
  msg "[INFO] $KI_OPT_ROOT_PATH/ansible/inventory.yml"
  msg "[INFO] $KI_OPT_ROOT_PATH/ansible/group_vars/all/vars.yml"

  remove_root_directory
}

require_root() {
  [[ $(id -u) = "0" ]] && return 0

  die "[ERROR] This script must be run as root"
}

# This script is normally run from inside the directory it removes, and bash reads
# a script as it goes rather than all at once. exec hands the process over to rm,
# so bash is gone before the file it was reading disappears
remove_root_directory() {
  trap - SIGINT SIGTERM ERR EXIT
  exec rm -rf "$KI_OPT_ROOT_PATH"
}

main
