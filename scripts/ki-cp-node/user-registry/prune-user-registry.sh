#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--vars-path path] [--keep-path path] [--delete]
Available options:
-h, --help     Print this help and exit
-v, --verbose  Print script debug info
--vars-path    File path
--keep-path    The file declaring the images to keep, in the shape of
               ki-cp-user-registry-images.yml
--delete       Actually delete. Without it nothing is removed and what would be
               is printed
EOF
  exit
}

parse_params() {
  vars_path=""
  keep_path=""
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
    --keep-path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      keep_path="${2-}"
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
  [[ -z "${keep_path-}" ]] && die "[ERROR] Missing required option: --keep-path"

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

etc_svc_root_path=""
var_svc_root_path=""

registry_host=""

# Removes from the user registry everything the keep file does not name, and
# reclaims what those images were holding.
#
# Says what it would remove and removes nothing unless --delete is passed. A
# registry inside an air gap is the only copy of what it holds: an image deleted
# here is fetched again by crossing the gap with it, so the cost of deleting one
# image too many is a trip rather than a command
main() {
  require_file_exists "$vars_path"
  require_file_exists "$keep_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  ki_var_root_path=$($yq_cmd '.ki_var_root_path' < "$vars_path")
  ki_etc_services_path=$($yq_cmd '.ki_etc_services_path' < "$vars_path")
  ki_cp_user_registry_port=$($yq_cmd '.ki_cp_user_registry_port' < "$vars_path")

  etc_svc_root_path="$ki_etc_services_path"/$SVC_NAME
  var_svc_root_path="$ki_var_root_path"/$SVC_NAME
  registry_host="127.0.0.1:$ki_cp_user_registry_port"
  require_directory_exists "$etc_svc_root_path"

  local to_delete
  to_delete=$(get_refs_to_delete)

  if [[ -z $to_delete ]]; then
    msg "[INFO] The user registry of this node holds nothing the keep file does not name"
    report_usage
    return 0
  fi

  msg "[INFO] These images are in the user registry and not in the keep file:"
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
  # it rewrites the compose file readonly on its way out
  set_readonly "false"
  delete_refs "$to_delete"
  collect_garbage
  report_usage

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

# Everything the registry serves, against everything the keep file names. The
# keep file is read for the references the images are served under, which is
# what build-user-registry-images.sh derived the layout paths from, so the two
# sides are the same strings
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

get_kept_refs() {
  local images
  local mappings
  images=$($yq_cmd -o json '.images' < "$keep_path")
  mappings=$($yq_cmd -o json '.mappings // []' < "$keep_path")

  local full_name
  local repo_and_tag
  for full_name in $($yq_cmd --null-input "$images | join(\" \")"); do
    repo_and_tag=$(get_repo_and_tag_from_mappings "$full_name" "$mappings")
    [[ -z $repo_and_tag ]] &&
      repo_and_tag=$(parse_repo_and_tag "$full_name")
    [[ -z $repo_and_tag ]] &&
      die "[ERROR] Invalid image name[\"$full_name\"] in file[\"$keep_path\"]"

    echo "$repo_and_tag"
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
    die "[ERROR] Failed to reclaim the storage of the deleted images. the registry is down, bring it back with setup-user-registry.sh --update"

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
  $yq_cmd '.ki_cp_user_registry_image' < "$vars_path"

  return 0
}

report_usage() {
  msg "[INFO] The user registry of this node holds $(du -sh "$var_svc_root_path" | cut -f1)"

  return 0
}

get_repo_and_tag_from_mappings() {
  local full_name=$1
  local mappings=$2

  for (( i=0; i<$($yq_cmd --null-input "$mappings | length"); i++ )); do
    local from
    local to
    from=$($yq_cmd --null-input "$mappings | .[$i][\"from\"]")
    to=$($yq_cmd --null-input "$mappings | .[$i][\"to\"]")
    if [[ $full_name = "$from" ]]; then
      echo "$to"
      return 0
    fi
  done

  echo ""

  return 0
}

parse_repo_and_tag() {
  local full_name=$1

  echo "$full_name" | grep -oP '^([a-z0-9A-Z]\.)*[a-z0-9-]+\.([a-z0-9]{2,24})+(\.co\.([a-z0-9]{2,24})|\.([a-z0-9]{2,24}))*(:[0-9]+)?/?\K[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*(\/[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*)*:[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}'

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
