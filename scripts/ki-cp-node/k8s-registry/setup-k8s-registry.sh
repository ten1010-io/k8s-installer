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

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""
jinja2_cmd=""
crane_cmd=""

ki_var_root_path=""
ki_etc_services_path=""
ki_cp_k8s_registry_port=""
k8s_minor_version=""

etc_svc_root_path=""
var_svc_root_path=""
images_path=""
pushed_images_path=""

main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  ki_var_root_path=$($yq_cmd '.ki_var_root_path' < "$vars_path")
  ki_etc_services_path=$($yq_cmd '.ki_etc_services_path' < "$vars_path")
  ki_cp_k8s_registry_port=$($yq_cmd '.ki_cp_k8s_registry_port' < "$vars_path")
  k8s_minor_version=$($yq_cmd '.k8s_minor_version' < "$vars_path")

  etc_svc_root_path="$ki_etc_services_path"/$SVC_NAME
  var_svc_root_path="$ki_var_root_path"/$SVC_NAME
  # Below the minor rather than above it. The bundle holds the images of every
  # minor the release supports, one directory each, and the path of a layout
  # under this one is the reference it is pushed to, so the minor has to be part
  # of where the walk starts and not something it walks through
  images_path="$ki_opt_bundle_path"/$SVC_NAME-images/$k8s_minor_version
  pushed_images_path="$var_svc_root_path"/pushed-images
  [[ $update = "false" ]] && require_not_setup $SVC_NAME
  require_directory_exists "$images_path"

  docker load -i "$ki_opt_bundle_path"/ki-cp-service-images/$SVC_NAME.tar

  mkdir -p "$var_svc_root_path"
  mkdir -p "$etc_svc_root_path"

  local compose_yml_before
  local images
  compose_yml_before=$(checksum_of "$etc_svc_root_path/compose.yml")
  # Rendered readonly before anything is compared, so that what the comparison
  # holds is the file a run which finished left behind. A run which died between
  # the push and the readonly render left the writable one there instead, and
  # that difference is what asks for the whole of it again
  create_compose_yml_file "true"
  images=$(checksum_of_images)

  if [[ $(service_up_to_date "$compose_yml_before" "$images") = "true" ]]; then
    docker compose -f "$etc_svc_root_path/compose.yml" up -d
    wait_registry_ready 60
    return 0
  fi

  # Seeded by pushing rather than by unpacking a copy of the storage directory of
  # some other registry, so that the bundle does not have to agree with the
  # internal layout of the registry image the release happens to pin
  create_compose_yml_file "false"
  start_service
  wait_registry_ready 60
  push_images

  # Left readonly, which is also what makes the garbage collection of a later
  # prune safe to run: nothing can be uploading while it walks the storage
  create_compose_yml_file "true"
  start_service

  # Last of all, so that anything which goes wrong above leaves a record
  # disagreeing with the bundle, and a next run which pushes the whole of it
  # again rather than one which believes the storage is filled
  echo "$images" > "$pushed_images_path"

  return 0
}

create_compose_yml_file() {
  local readonly_enabled=$1

  $jinja2_cmd -D var_svc_root_path="$var_svc_root_path" \
              -D readonly_enabled="$readonly_enabled" \
              --format yaml \
              -o "$etc_svc_root_path""/compose.yml" \
              "$SCRIPT_DIR_PATH"/templates/compose.yml.j2 "$vars_path"

  return 0
}

start_service() {
  [[ $(service_exists $SVC_NAME) = "true" ]] && docker compose -f "$etc_svc_root_path/compose.yml" down
  docker compose -f "$etc_svc_root_path/compose.yml" up -d

  return 0
}

wait_registry_ready() {
  local timeout=$1

  local elapsed=0
  while true; do
    if curl -sk --max-time 3 "https://127.0.0.1:$ki_cp_k8s_registry_port/v2/" > /dev/null 2>&1; then
      return 0
    fi
    [[ $elapsed -ge $timeout ]] && die "[ERROR] Failed to wait for the registry being ready. timeout occurred"

    sleep 2s
    elapsed=$(("$elapsed" + 2))
  done
}

# The path of a layout under the images directory is the reference it is pushed
# to. Pushing is additive on purpose: an upgrade adds the images of the new
# release while the nodes that have not moved yet still pull the old ones
push_images() {
  local layout
  local ref
  for layout in $(find "$images_path" -name oci-layout -printf '%h\n' | sort); do
    ref=${layout#"$images_path"/}
    msg "[INFO] Pushing image[\"$ref\"]"
    # Loopback, and the certificate of the registry is issued for its dns name
    # rather than for an address, so the name it would be verified against is not
    # the one being connected to
    $crane_cmd push --insecure "$layout" "127.0.0.1:$ki_cp_k8s_registry_port/$ref" > /dev/null
  done

  return 0
}

# Whether this run has anything to do. This service is not a render followed by a
# restart like the rest of the ki cp services: it is a write window opened to push
# the images of the bundle through, and opening it takes the registry down twice.
# apply-service-var-changes.yml runs without serial, so that happens on every ki cp
# node at once and leaves the cluster with nowhere to pull an image of the release
# from, which is the accident upgrade-k8s-registry.yml goes one node at a time to
# avoid. The window is therefore opened only when the compose file about to be
# written differs from the one the service is running under, or when the bundle
# holds images the storage was not filled from
service_up_to_date() {
  local compose_yml_before=$1
  local images=$2

  [[ $update = "true" ]] || { echo "false"; return 0; }
  [[ $(service_exists $SVC_NAME) = "true" ]] || { echo "false"; return 0; }
  [[ $(checksum_of "$etc_svc_root_path/compose.yml") = "$compose_yml_before" ]] || { echo "false"; return 0; }
  [[ $(recorded_images) = "$images" ]] || { echo "false"; return 0; }

  echo "true"

  return 0
}

# The path of a layout under the images directory is the reference it is pushed
# to and its index.json names the digest that lands there, so the two together
# are the whole of what a push would put in the registry. The blobs beside them
# are a hundred and seventy megabytes and say nothing the digest does not
checksum_of_images() {
  find "$images_path" -name index.json -exec md5sum {} + | sort | md5sum

  return 0
}

# What the storage was last filled from, kept beside the storage rather than
# beside the compose file: it is a claim about what the registry holds, and the
# claim and the thing it describes have to be lost together. Removing it is also
# the way back for a registry damaged from outside, which nothing compared here
# can see
recorded_images() {
  [[ -f $pushed_images_path ]] || { echo "absent"; return 0; }
  cat "$pushed_images_path"

  return 0
}

checksum_of() {
  local path=$1

  [[ -f $path ]] || { echo "absent"; return 0; }
  md5sum < "$path"

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
