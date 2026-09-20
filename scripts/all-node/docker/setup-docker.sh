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

DROP_IN_DIR_PATH=/etc/systemd/system/docker.service.d
DROP_IN_PATH="$DROP_IN_DIR_PATH"/override.conf

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bin_path=""
ki_opt_venv_path=""

yq_cmd=""
jinja2_cmd=""

nvidia_gpu=""

main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  nvidia_gpu=$($yq_cmd '.nvidia_gpu' < "$vars_path")

  require_docker_not_enabled

  [[ $nvidia_gpu = "true" ]] && require_nvidia_gpu_exists

  $jinja2_cmd --format yaml -o "/etc/docker/daemon.json" "$SCRIPT_DIR_PATH"/templates/daemon.json.j2 "$vars_path"
  create_drop_in_file
  "$ki_opt_scripts_path"/systemctl.sh enable docker

  return 0
}

# docker.service comes with Restart=always, but also with a start limit of 3
# attempts and RestartSec=2, which is six seconds of grace. Anything dockerd
# waits on that is not ready yet, containerd among them, spends that budget and
# leaves the unit failed for good, with the dns server, the ntp server, the
# apiserver lb and the registry of a ki cp node inside it
#
# The window is widened rather than removed. Thirty attempts over five minutes
# covers a dependency that is merely slow, while a dockerd that can not start at
# all still ends up in failed, where it can be seen, instead of restarting out of
# sight forever
#
# A drop-in rather than an edit of the unit, so that it survives a docker package
# upgrade, which overwrites everything under /usr/lib
create_drop_in_file() {
  mkdir -p "$DROP_IN_DIR_PATH"
  cp -f "$SCRIPT_DIR_PATH"/templates/override.conf "$DROP_IN_PATH"
  "$ki_opt_scripts_path"/systemctl.sh reload

  return 0
}

require_nvidia_gpu_exists() {
  local result
  result=$("$ki_opt_scripts_path"/preflight/nvidia-gpu-exists.sh)

  [[ $result = "false" ]] && die "[ERROR] Nvidia gpu not detected"

  return 0
}

require_docker_not_enabled() {
  local result
  result=$("$ki_opt_scripts_path"/systemctl.sh is-enabled docker)

  [[ $result = true ]] && die "[ERROR] Docker already enabled"

  return 0
}

import_ki_opt_vars() {
  ki_opt_root_path=$(grep -oP  "^ki_opt_root_path: \K(.+)" < "$vars_path")
  ki_opt_scripts_path=$(grep -oP  "^ki_opt_scripts_path: \K(.+)" < "$vars_path")
  ki_opt_bin_path=$(grep -oP  "^ki_opt_bin_path: \K(.+)" < "$vars_path")
  ki_opt_venv_path=$(grep -oP  "^ki_opt_venv_path: \K(.+)" < "$vars_path")
}

setup_cmd_vars() {
  yq_cmd="$ki_opt_bin_path/bin/yq"
  jinja2_cmd="$ki_opt_venv_path/bin/jinja2"
}

validate_ki_opt_directory() {
  require_directory_exists "$ki_opt_scripts_path"
  require_directory_exists "$ki_opt_bin_path"
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
