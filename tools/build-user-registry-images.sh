#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--platform platform]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--platform      The platform of the images to pull. Defaults to linux/amd64
EOF
  exit
}

parse_params() {
  platform="linux/amd64"

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --platform)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      platform="${2-}"
      shift
      ;;
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

KI_ROOT_PATH=$(cd "$SCRIPT_DIR_PATH/.." &>/dev/null && pwd -P)
BUNDLE_PATH="$KI_ROOT_PATH"/bundle
YQ_CMD="$BUNDLE_PATH"/bin/yq
CRANE_CMD="$BUNDLE_PATH"/bin/crane

REGISTRY_NAME="ki-cp-user-registry"
IMAGES_YML_PATH="$KI_ROOT_PATH"/$REGISTRY_NAME-images.yml
ARCHIVE_PATH="$KI_ROOT_PATH"/$REGISTRY_NAME-images.tgz

# Collects the images a cluster of this project is meant to serve from its user
# registry into one archive, so that they can be carried across an air gap and
# pushed with push-user-registry-images.yml on the other side.
#
# Run where the images can still be reached. Everything it needs comes out of
# the bundle, which is the same crane the nodes push with: a build of it picked
# up somewhere else would be a second version of the one tool that has to agree
# with itself on both sides of the gap
main() {
  require_bundle
  require_images_yml

  local staging_path
  staging_path=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$staging_path'" EXIT

  pull_images "$staging_path/$REGISTRY_NAME-images"
  create_archive "$staging_path"

  msg ""
  msg "[INFO] Wrote \"$ARCHIVE_PATH\""
  msg "[INFO] Carry it to the control node and push it with:"
  msg "[INFO]   ansible-playbook -i inventory.yml playbooks/push-user-registry-images.yml -e archive=<path>"

  return 0
}

require_bundle() {
  [[ ! -d $BUNDLE_PATH ]] &&
    die "[ERROR] Directory[\"$BUNDLE_PATH\"] not exists. run ./download-bundle.sh first, which brings the crane this needs"
  [[ ! -x $YQ_CMD ]] && die "[ERROR] File[\"$YQ_CMD\"] not exists or is not executable"
  [[ ! -x $CRANE_CMD ]] && die "[ERROR] File[\"$CRANE_CMD\"] not exists or is not executable"

  return 0
}

require_images_yml() {
  [[ ! -f $IMAGES_YML_PATH ]] &&
    die "[ERROR] No such file or directory of which path is \"$IMAGES_YML_PATH\". declare the images to carry in it, the way $KI_ROOT_PATH/ki-cp-k8s-registry-images.yml declares the ones of the cluster itself"

  return 0
}

# One oci layout per image, the same shape the bundle carries its registry
# images in, because crane refuses to push a layout holding more than one entry
# to a single reference. The path under the output directory is the reference
# the image is pushed to, so nothing else has to carry a mapping from a file to
# a reference
pull_images() {
  local output_path=$1

  local images
  local mappings
  images=$($YQ_CMD -o json '.images' < "$IMAGES_YML_PATH")
  mappings=$($YQ_CMD -o json '.mappings // []' < "$IMAGES_YML_PATH")

  [[ $($YQ_CMD --null-input "$images | length") -eq 0 ]] &&
    die "[ERROR] File[\"$IMAGES_YML_PATH\"] declares no image under key[\"images\"]"

  mkdir -p "$output_path"

  msg "[INFO] Pulling the images of the registry[\"$REGISTRY_NAME\"] for platform[\"$platform\"]"

  local full_name
  local repo_and_tag
  for full_name in $($YQ_CMD --null-input "$images | join(\" \")"); do
    repo_and_tag=$(get_repo_and_tag_from_mappings "$full_name" "$mappings")
    [[ -z $repo_and_tag ]] &&
      repo_and_tag=$(parse_repo_and_tag "$full_name")
    [[ -z $repo_and_tag ]] &&
      die "[ERROR] Invalid image name[\"$full_name\"]"

    msg "[INFO]   $repo_and_tag  <-  $full_name"
    mkdir -p "$(dirname "$output_path/$repo_and_tag")"
    "$CRANE_CMD" pull --platform "$platform" --format oci --annotate-ref "$full_name" "$output_path/$repo_and_tag"
  done

  return 0
}

create_archive() {
  local staging_path=$1

  rm -f "$ARCHIVE_PATH"
  tar czf "$ARCHIVE_PATH" -C "$staging_path" "$REGISTRY_NAME-images"

  return 0
}

get_repo_and_tag_from_mappings() {
  local full_name=$1
  local mappings=$2

  for (( i=0; i<$($YQ_CMD --null-input "$mappings | length"); i++ )); do
    local from
    local to
    from=$($YQ_CMD --null-input "$mappings | .[$i][\"from\"]")
    to=$($YQ_CMD --null-input "$mappings | .[$i][\"to\"]")
    if [[ $full_name = "$from" ]]; then
      echo "$to"
      return 0
    fi
  done

  echo ""

  return 0
}

# The registry an image is pulled from is not part of where it is put: the user
# registry serves it under its own name, so docker.io/library/nginx:1.25 becomes
# library/nginx:1.25 there. The same expression build-bundle-images.sh reads
# names with, so both files of images are written the same way
parse_repo_and_tag() {
  local full_name=$1

  echo "$full_name" | grep -oP '^([a-z0-9A-Z]\.)*[a-z0-9-]+\.([a-z0-9]{2,24})+(\.co\.([a-z0-9]{2,24})|\.([a-z0-9]{2,24}))*(:[0-9]+)?/?\K[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*(\/[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*)*:[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}'

  return 0
}

main
