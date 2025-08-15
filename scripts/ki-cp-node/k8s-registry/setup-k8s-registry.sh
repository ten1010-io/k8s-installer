#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--vars-path path] [--update]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--vars-path     File path
--update
EOF
  exit
}

parse_params() {
  vars_path=""
  update="false"

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
    --update) update="true" ;;
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

SVC_NAME=ki-cp-k8s-registry

ki_env_path=""
ki_env_scripts_path=""
ki_env_bin_path=""
ki_env_ki_venv_path=""

yq_cmd=""
jinja2_cmd=""

ki_etc_services_path=""
ki_var_services_path=""

etc_svc_root_path=""
var_svc_root_path=""

main() {
  require_file_exists "$vars_path"
  import_ki_env_vars
  setup_cmd_vars
  require_directory_exists "$ki_env_path"
  validate_ki_env_directory

  ki_etc_services_path=$($yq_cmd '.ki_etc_services_path' < "$vars_path")
  ki_var_services_path=$($yq_cmd '.ki_var_services_path' < "$vars_path")

  etc_svc_root_path="$ki_etc_services_path"/$SVC_NAME
  var_svc_root_path="$ki_var_services_path"/$SVC_NAME
  [[ $update = "false" ]] && require_not_setup $SVC_NAME

  docker load -i "$ki_env_bin_path"/images/registry/*.tar

  mkdir -p "$var_svc_root_path"
  tar xzf "$ki_env_bin_path"/registry-data/k8s-registry-data.tgz -C "$var_svc_root_path"

  mkdir -p "$etc_svc_root_path"
  $jinja2_cmd -D var_svc_root_path="$var_svc_root_path" \
              --format yaml \
              -o "$etc_svc_root_path""/compose.yml" \
              "$SCRIPT_DIR_PATH"/templates/compose.yml.j2 "$vars_path"

  [[ $update = "true" && $(service_exists $SVC_NAME) = "true" ]] && docker compose -f "$etc_svc_root_path/compose.yml" down
  docker compose -f "$etc_svc_root_path/compose.yml" up -d

  return 0
}

service_exists() {
  local svc_name=$1

  local ls_lines_len
  ls_lines_len=$(docker compose ls -a --filter name='^'"$svc_name"'$' | wc -l)
  if [[ $ls_lines_len = 2 ]]; then echo "true"; else echo "false"; fi

  return 0
}

require_not_setup() {
  local svc_name=$1

  [[ $(service_exists "$svc_name") = "true" ]] && die "[ERROR] Service[\"$svc_name\"] already setup"

  return 0
}

import_ki_env_vars() {
  ki_env_path=$(grep -oP  "^ki_env_path: \K(.+)" < "$vars_path")
  ki_env_scripts_path=$(grep -oP  "^ki_env_scripts_path: \K(.+)" < "$vars_path")
  ki_env_bin_path=$(grep -oP  "^ki_env_bin_path: \K(.+)" < "$vars_path")
  ki_env_ki_venv_path=$(grep -oP  "^ki_env_ki_venv_path: \K(.+)" < "$vars_path")
}

setup_cmd_vars() {
  yq_cmd="$ki_env_bin_path/bin/yq"
  jinja2_cmd="$ki_env_ki_venv_path/bin/jinja2"
}

validate_ki_env_directory() {
  require_directory_exists "$ki_env_scripts_path"
  require_directory_exists "$ki_env_bin_path"
  require_directory_exists "$ki_env_ki_venv_path"

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
