#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--vars-path path] [--archive-path path]
Available options:
-h, --help       Print this help and exit
-v, --verbose    Print script debug info
--vars-path      File path
--archive-path   The archive build-user-registry-images.sh produced
EOF
  exit
}

parse_params() {
  vars_path=""
  archive_path=""

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
    --archive-path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      archive_path="${2-}"
      shift
      ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ -z "${vars_path-}" ]] && die "[ERROR] Missing required option: --vars-path"
  [[ -z "${archive_path-}" ]] && die "[ERROR] Missing required option: --archive-path"

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

SVC_NAME=ki-cp-user-registry

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""
jinja2_cmd=""
crane_cmd=""

ki_var_root_path=""
ki_etc_services_path=""
ki_tmp_root_path=""
ki_cp_user_registry_port=""

etc_svc_root_path=""
var_svc_root_path=""

# Puts the images of an archive into the user registry of this node.
#
# Additive. What is already here and not in the archive stays, because an
# archive says what is being added rather than what the cluster is supposed to
# hold: a workload running on an image left out of this one would otherwise stop
# being able to start. Removing is prune-user-registry.sh, which is asked for
# separately
main() {
  require_file_exists "$vars_path"
  require_file_exists "$archive_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  ki_var_root_path=$($yq_cmd '.ki_var_root_path' < "$vars_path")
  ki_etc_services_path=$($yq_cmd '.ki_etc_services_path' < "$vars_path")
  ki_tmp_root_path=$($yq_cmd '.ki_tmp_root_path' < "$vars_path")
  ki_cp_user_registry_port=$($yq_cmd '.ki_cp_user_registry_port' < "$vars_path")

  etc_svc_root_path="$ki_etc_services_path"/$SVC_NAME
  var_svc_root_path="$ki_var_root_path"/$SVC_NAME
  require_directory_exists "$etc_svc_root_path"

  local images_path
  images_path="$ki_tmp_root_path"/$SVC_NAME-images
  extract_archive "$images_path"

  # Writable only while this is pushing, and readonly again before it returns.
  # Between those two the registry would take a push from anywhere, and a push
  # that did not come through here reaches one node out of several
  set_readonly "false"
  push_images "$images_path"
  set_readonly "true"

  rm -rf "$images_path"
  report_usage

  return 0
}

extract_archive() {
  local images_path=$1

  rm -rf "$images_path"
  mkdir -p "$(dirname "$images_path")"
  tar xzf "$archive_path" -C "$(dirname "$images_path")"

  require_directory_exists "$images_path"

  return 0
}

set_readonly() {
  local readonly_enabled=$1

  $jinja2_cmd -D var_svc_root_path="$var_svc_root_path" \
              -D readonly_enabled="$readonly_enabled" \
              --format yaml \
              -o "$etc_svc_root_path""/compose.yml" \
              "$SCRIPT_DIR_PATH"/templates/compose.yml.j2 "$vars_path"

  docker compose -f "$etc_svc_root_path/compose.yml" down
  docker compose -f "$etc_svc_root_path/compose.yml" up -d
  wait_registry_ready 60

  return 0
}

# The path of a layout under the images directory is the reference it is pushed
# to, which is what build-user-registry-images.sh laid it out for
push_images() {
  local images_path=$1

  local layout
  local ref
  for layout in $(find "$images_path" -name oci-layout -printf '%h\n' | sort); do
    ref=${layout#"$images_path"/}
    msg "[INFO] Pushing image[\"$ref\"]"
    # Loopback, and the certificate of the registry is issued for its dns name
    # rather than for an address, so the name it would be verified against is not
    # the one being connected to
    $crane_cmd push --insecure "$layout" "127.0.0.1:$ki_cp_user_registry_port/$ref" > /dev/null ||
      die "[ERROR] Failed to push image[\"$ref\"]"
  done

  return 0
}

# Said out loud because nothing else will. The registry only grows from here
# until somebody prunes it, and the first sign of that being a problem should
# not be a node running out of disk
report_usage() {
  msg "[INFO] The user registry of this node holds $(du -sh "$var_svc_root_path" | cut -f1)"

  return 0
}

wait_registry_ready() {
  local timeout=$1

  local elapsed=0
  while true; do
    if curl -sk --max-time 3 "https://127.0.0.1:$ki_cp_user_registry_port/v2/" > /dev/null 2>&1; then
      return 0
    fi
    [[ $elapsed -ge $timeout ]] && die "[ERROR] Failed to wait for the registry being ready. timeout occurred"

    sleep 2s
    elapsed=$(("$elapsed" + 2))
  done
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
  crane_cmd="$ki_opt_bundle_path/bin/crane"
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
