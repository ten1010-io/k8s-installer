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
ki_cp_user_registry_port=""
ki_cp_ha_mode=""
inventory_hostname=""

etc_svc_root_path=""
var_svc_root_path=""
registry_host=""
source_host=""

# Makes the user registry of this node serve what the other ki cp nodes serve.
#
# What belongs in this registry is decided by whoever runs the cluster and
# arrives on an archive, so unlike the k8s registry there is nothing on a new
# node to fill it from and add-ki-cp-node.yml could only leave it empty. A pod
# pulls from whichever node is answering the vip at the time, so one empty
# registry among several is a workload that starts or fails depending on where
# it was scheduled, found long after the node was added.
#
# The archive is not the only copy of what it holds, though. Every other ki cp
# node is already serving exactly that, on this side of the air gap, which is
# what this reads from.
#
# Copies without being asked twice, where prune-user-registry.sh removes nothing
# unless it is. The caution there is that deleting inside an air gap costs a trip
# across it; copying between two nodes of the same cluster costs disk and can
# only make them agree, so there is nothing to protect an operator from
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  ki_var_root_path=$($yq_cmd '.ki_var_root_path' < "$vars_path")
  ki_etc_services_path=$($yq_cmd '.ki_etc_services_path' < "$vars_path")
  ki_cp_user_registry_port=$($yq_cmd '.ki_cp_user_registry_port' < "$vars_path")
  ki_cp_ha_mode=$($yq_cmd '.ki_cp_ha_mode' < "$vars_path")
  inventory_hostname=$($yq_cmd '.inventory_hostname' < "$vars_path")

  # One ki cp node is the whole of the registry of the cluster, so there is
  # nobody for it to agree with
  [[ $ki_cp_ha_mode = "false" ]] && exit 0

  etc_svc_root_path="$ki_etc_services_path"/$SVC_NAME
  var_svc_root_path="$ki_var_root_path"/$SVC_NAME
  require_directory_exists "$etc_svc_root_path"

  registry_host="127.0.0.1:$ki_cp_user_registry_port"
  source_host=$(find_source_host)
  [[ -z $source_host ]] &&
    die "[ERROR] No other ki_cp_node is answering for its user registry. There is nothing to read from, and a node left empty is a workload that fails as soon as it holds the vip"

  local refs
  refs=$(get_refs_to_copy)

  if [[ -z $refs ]]; then
    msg "[INFO] The user registry of this node already serves what the others do"
    report_usage
    return 0
  fi

  msg "[INFO] These images are served by node[\"$source_host\"] and not by this one:"
  local ref
  while read -r ref; do
    msg "[INFO]   $ref"
  done <<< "$refs"

  # Writable only while this is copying, and readonly again before it returns,
  # the way push-user-registry-images.sh opens it. Rendered from the same
  # template setup-user-registry.sh renders, so the file left behind is the one
  # that script would have written and the next --update reads no difference
  set_readonly "false"
  copy_refs "$refs"
  set_readonly "true"

  report_usage

  return 0
}

# A peer rather than the vip. The vip can be held by the very node this is
# filling, whose answer is the one answer not worth having, and every ki cp node
# serves the same registry anyway: what is wanted is any of the others that is
# answering
find_source_host() {
  local ih
  local ip
  for ih in $(get_peer_ih_list); do
    ip=$(get_ip "$ih")
    if curl -sk --max-time 3 "https://$ip:$ki_cp_user_registry_port/v2/" > /dev/null 2>&1; then
      echo "$ip:$ki_cp_user_registry_port"
      return 0
    fi
  done

  echo ""

  return 0
}

get_peer_ih_list() {
  $yq_cmd ".groups.ki_cp_node - [\"$inventory_hostname\"] | join(\" \")" < "$vars_path"

  return 0
}

get_ip() {
  local ih=$1

  $yq_cmd ".internal_network_hosts.$ih.interfaces[0].ip" < "$vars_path"

  return 0
}

# Everything the source serves, against what this node serves under the same
# reference. Compared by digest rather than by whether the tag is there at all: a
# tag pointing at different content on two nodes is the same divergence as a tag
# missing from one of them, and the digest is what a pod ends up running
get_refs_to_copy() {
  local repo
  local tag
  local ref
  for repo in $($crane_cmd catalog --insecure "$source_host"); do
    for tag in $($crane_cmd ls --insecure "$source_host/$repo"); do
      ref="$repo:$tag"
      [[ $(digest_of "$source_host/$ref") = "$(digest_of "$registry_host/$ref")" ]] && continue
      echo "$ref"
    done
  done

  return 0
}

# Absent rather than a failure, so that a reference this node does not serve at
# all compares as different instead of stopping the run
digest_of() {
  local ref=$1

  $crane_cmd digest --insecure "$ref" 2>/dev/null || echo "absent"

  return 0
}

copy_refs() {
  local refs=$1

  local ref
  while read -r ref; do
    [[ -z $ref ]] && continue
    msg "[INFO] Copying image[\"$ref\"]"
    # crane copy keeps the digest, which is the whole reason this registry is
    # filled by pushing rather than by loading a tarball into it
    $crane_cmd copy --insecure "$source_host/$ref" "$registry_host/$ref" > /dev/null ||
      die "[ERROR] Failed to copy image[\"$ref\"]"
  done <<< "$refs"

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
