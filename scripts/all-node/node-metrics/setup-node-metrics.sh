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

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""
jinja2_cmd=""

metrics_path=""

# Whether the timer was already running when this started, which decides whether
# enabling it below runs the checks on its own. See write_metrics_now
timer_was_active=""

# Runs the checks of this node on a timer and leaves what they measured where a
# node exporter textfile collector reads it.
#
# The checks already answer at the end of a playbook run. What they answer about
# does not wait for one: kernel arguments and vfio-pci bindings come into force
# at a boot, a driver appears when somebody installs it, and an apiserver
# restarts for its own reasons. A file written only by playbooks would go on
# reporting a node as pending long after it was rebooted, and an alert that is
# wrong more often than it is right is an alert people learn to close.
#
# That is the difference from the certificate expiry, which is written by the
# playbooks alone: a certificate moves when something issues or renews it, and
# both of those are a playbook
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  metrics_path=$($yq_cmd '.ki_metrics_path' < "$vars_path")

  mkdir -p "$metrics_path"

  create_unit_files
  enable_timer
  write_metrics_now

  return 0
}

create_unit_files() {
  $jinja2_cmd --format yaml -o "$SERVICE_PATH" "$SCRIPT_DIR_PATH"/templates/$SVC_NAME.service.j2 "$vars_path"
  cp -f "$SCRIPT_DIR_PATH"/templates/$SVC_NAME.timer "$TIMER_PATH"
  "$ki_opt_scripts_path"/systemctl.sh reload

  return 0
}

# The timer is enabled and the service is not. The service is the work and the
# timer is what asks for it, so enabling both would run it once at every boot for
# no reason and leave a finished oneshot looking like a unit that should be up.
#
# What it was doing beforehand is remembered, because that is what decides
# whether enabling it has already run the checks. See write_metrics_now
enable_timer() {
  timer_was_active=$("$ki_opt_scripts_path"/systemctl.sh is-running $SVC_NAME.timer)

  "$ki_opt_scripts_path"/systemctl.sh enable $SVC_NAME.timer

  return 0
}

# So that what is on the node is what this run measured rather than what the run
# before it did.
#
# Only where enabling the timer has not already done it. systemctl.sh enable
# starts the timer as well as enabling it, and a timer whose OnBootSec has
# already passed elapses the moment it is started - so on a node being set up for
# the first time the checks have just run and running them again is work for
# nothing. On a node that already had the timer, starting an active unit does
# nothing at all, and that is the run that most needs this: the unit it replaced
# may name other files than the one it just wrote.
#
# A node whose boot was less than OnBootSec ago is the one case where neither
# runs them now, and there the timer is about to
write_metrics_now() {
  [[ $timer_was_active = "true" ]] || return 0

  "$ki_opt_scripts_path"/systemctl.sh restart $SVC_NAME.service

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
