#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--vars-path path] [--delete]
Available options:
-h, --help     Print this help and exit
-v, --verbose  Print script debug info
--vars-path    File path
--delete       Actually delete. Without it nothing is removed and what would be
               is printed
EOF
  exit
}

parse_params() {
  vars_path=""
  delete="false"

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
    --delete) delete="true" ;;
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

registry_host=""

# Removes from the k8s registry everything the bundle does not hold, and
# reclaims what those images were holding.
#
# A registry is filled by pushing and never by removing, so every release that
# has been through a cluster is still in it: an upgrade adds the images of the
# new one and leaves the images of the old. Measured on a three node cluster one
# minor after it was built, the storage held two of everything and 355M.
#
# What to keep is not asked for. The bundle is the release, and of the release
# the cluster runs the kubernetes minor vars.yml named, so the images directory
# of that minor is the answer already: the minors beside it in the bundle are
# ones this cluster does not run, and a cluster that has just moved up one is
# the reason anything is here to remove at all. prune-user-registry.sh takes a
# keep file only because nothing on the node can know what a workload needs.
# Getting it wrong here costs a re-push from the bundle rather than a trip
# across the air gap, which is why the two are not the same command.
#
# Not part of an upgrade. upgrade-k8s-nodes.yml goes one node at a time, so an
# upgrade that fails part way through leaves the nodes before it on the new
# release and the ones after it on the old, and the images this would remove are
# the ones those nodes still have to pull. It is asked for once the cluster is
# whole again.
#
# Says what it would remove and removes nothing unless --delete is passed
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
  registry_host="127.0.0.1:$ki_cp_k8s_registry_port"
  require_directory_exists "$etc_svc_root_path"
  require_directory_exists "$images_path"

  local to_delete
  to_delete=$(get_refs_to_delete)

  if [[ -z $to_delete ]]; then
    msg "[INFO] The k8s registry of this node holds nothing outside the bundle"
    report_usage
    return 0
  fi

  msg "[INFO] These images are in the k8s registry and not in the bundle:"
  local ref
  while read -r ref; do
    [[ -z $ref ]] && continue
    msg "[INFO]   $ref"
  done <<< "$to_delete"

  if [[ $delete = "false" ]]; then
    msg "[INFO] Nothing was removed. pass --delete to remove them"
    report_usage
    return 0
  fi

  # Deleting is a write, and the registry is left readonly so that nothing can
  # push to it directly. readonly refuses a DELETE the same way it refuses a
  # PUT, whatever REGISTRY_STORAGE_DELETE_ENABLED says, so the window is opened
  # for exactly as long as the deleting takes. collect_garbage puts it back:
  # it rewrites the compose file readonly on its way out.
  #
  # Rendering it from the same template setup-k8s-registry.sh renders is what
  # keeps the file it leaves behind identical to the one that script would have
  # written, so the next --update reads no difference and opens no window of its
  # own. A run that dies between here and the readonly render leaves the
  # writable one there, which is the difference that asks for the whole of the
  # bundle again
  set_readonly "false"
  delete_refs "$to_delete"
  collect_garbage
  report_usage

  # Nothing is done to the record setup-k8s-registry.sh keeps of what the
  # storage was filled from. It is a claim that everything in the bundle is in
  # the registry, and removing what the bundle does not hold leaves that claim
  # exactly as true as it was

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

# Everything the registry serves, against everything the bundle holds
get_refs_to_delete() {
  local kept
  kept=$(get_kept_refs)

  local repo
  local tag
  for repo in $($crane_cmd catalog --insecure "$registry_host"); do
    for tag in $($crane_cmd ls --insecure "$registry_host/$repo"); do
      grep -qxF "$repo:$tag" <<< "$kept" && continue
      echo "$repo:$tag"
    done
  done

  return 0
}

# Walked the way setup-k8s-registry.sh walks it to push: a layout is found by
# the oci-layout file at its root and the reference it is served under is its
# path below the images directory. Reading it the same way is what makes the
# two sides the same strings, including for a repository under a path of its own
get_kept_refs() {
  local layout
  for layout in $(find "$images_path" -name oci-layout -printf '%h\n' | sort); do
    echo "${layout#"$images_path"/}"
  done

  return 0
}

# By digest. A registry refuses to delete a manifest addressed by tag, so the
# tag is resolved first and the digest is what is handed back to it
delete_refs() {
  local refs=$1

  local ref
  local digest
  while read -r ref; do
    [[ -z $ref ]] && continue

    digest=$($crane_cmd digest --insecure "$registry_host/$ref") ||
      die "[ERROR] Failed to resolve the digest of image[\"$ref\"]"

    msg "[INFO] Deleting image[\"$ref\"]"
    $crane_cmd delete --insecure "$registry_host/${ref%%:*}@$digest" ||
      die "[ERROR] Failed to delete image[\"$ref\"]"
  done <<< "$refs"

  return 0
}

# Deleting a manifest only unlinks it. What it was holding is still on disk
# until the registry walks its storage, and it will not do that while anything
# could be uploading, so the registry is stopped for it rather than left running
collect_garbage() {
  msg "[INFO] Reclaiming the storage of the deleted images"

  docker compose -f "$etc_svc_root_path/compose.yml" down

  docker run --rm \
      -v "$var_svc_root_path/registry:/var/lib/registry" \
      "$(get_registry_image)" \
      bin/registry garbage-collect --delete-untagged /etc/docker/registry/config.yml ||
    die "[ERROR] Failed to reclaim the storage of the deleted images. the registry is down, bring it back with setup-k8s-registry.sh --update"

  remove_empty_repositories

  set_readonly "true"

  return 0
}

# Garbage collection reclaims the blobs and leaves the directory of the
# repository standing. The catalog is a listing of those directories, so an
# image whose last tag is gone goes on being named by it: nothing can be pulled
# from it, and the operator who just removed it sees it in the catalog and
# reasonably concludes it is still there. Runs while the registry is down, which
# is where garbage collection already left it
remove_empty_repositories() {
  local repositories_path="$var_svc_root_path/registry/docker/registry/v2/repositories"
  [[ ! -d $repositories_path ]] && return 0

  local tags_path
  local repo_path
  while read -r tags_path; do
    [[ -z $tags_path ]] && continue
    [[ -n $(ls -A "$tags_path") ]] && continue

    # .../<repo>/_manifests/tags -> .../<repo>
    repo_path=$(dirname "$(dirname "$tags_path")")
    msg "[INFO] Removing the empty repository[\"${repo_path#"$repositories_path"/}\"]"
    rm -rf "$repo_path"
  done <<< "$(find "$repositories_path" -type d -name tags)"

  # A repository under a path of its own, library/nginx and the like, leaves the
  # directory above it behind once it goes
  find "$repositories_path" -mindepth 1 -type d -empty -delete

  return 0
}

get_registry_image() {
  $yq_cmd '.ki_cp_k8s_registry_image' < "$vars_path"

  return 0
}

report_usage() {
  msg "[INFO] The k8s registry of this node holds $(du -sh "$var_svc_root_path" | cut -f1)"

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
