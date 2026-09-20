#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--platform platform]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--platform      Platform to pull, defaults to linux/amd64
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

KI_ROOT_PATH=$SCRIPT_DIR_PATH/..
BUNDLE_PATH="$KI_ROOT_PATH"/bundle
YQ_CMD="$BUNDLE_PATH"/bin/yq
CRANE_CMD="$BUNDLE_PATH"/bin/crane

CONSTANT_VARS_PATH="$KI_ROOT_PATH"/ansible/group_vars/all/constant-vars.yml
SERVICE_IMAGES_PATH="$BUNDLE_PATH"/ki-cp-service-images

# Every file of this shape declares the contents of the registry named by it, so
# a registry is added to the bundle by adding one file rather than by editing a
# list that several of them share
REGISTRY_IMAGES_YML_SUFFIX="-images.yml"

main() {
  require_bundle

  build_service_images
  build_registry_images

  msg ""
  msg "[INFO] Bundle images built"

  return 0
}

require_bundle() {
  [[ ! -d $BUNDLE_PATH ]] && die "[ERROR] Directory[\"$BUNDLE_PATH\"] not exists. execute \"download-bundle.sh\" first"
  [[ ! -x $YQ_CMD ]] && die "[ERROR] File[\"$YQ_CMD\"] not exists or is not executable"
  [[ ! -x $CRANE_CMD ]] && die "[ERROR] File[\"$CRANE_CMD\"] not exists or is not executable"
  [[ ! -f $CONSTANT_VARS_PATH ]] && die "[ERROR] No such file or directory of which path is \"$CONSTANT_VARS_PATH\""

  return 0
}

# The ki cp services are run by docker, which loads them from a tar rather than
# pulling them, and docker load reads a docker archive and not an oci layout. The
# tar is named after the service so that the setup script of that service finds
# it from the name it already holds
build_service_images() {
  msg "[INFO] Building the ki cp service images"

  rm -rf "$SERVICE_IMAGES_PATH"
  mkdir -p "$SERVICE_IMAGES_PATH"

  local var
  local svc_name
  local image
  for var in $(get_service_image_vars); do
    svc_name=$(get_svc_name "$var")
    image=$($YQ_CMD ".$var" < "$CONSTANT_VARS_PATH")
    [[ -z $image || $image = "null" ]] && die "[ERROR] Variable[\"$var\"] has no value"

    msg "[INFO]   $svc_name  <-  $image"
    "$CRANE_CMD" pull --platform "$platform" --format tarball "$image" "$SERVICE_IMAGES_PATH/$svc_name.tar"
  done

  return 0
}

# A service is added to the bundle by declaring its image in constant-vars.yml,
# which is also where the compose template of that service reads it from
get_service_image_vars() {
  $YQ_CMD 'keys | .[] | select(test("^ki_cp_.+_image$"))' < "$CONSTANT_VARS_PATH"

  return 0
}

get_svc_name() {
  local var=$1

  sed -e 's/_image$//' -e 's/_/-/g' <<< "$var"

  return 0
}

# What ends up in a registry is pushed there rather than loaded, and a push has
# to preserve the digest of the image it was given, which a docker archive does
# not. These are oci layouts, one per image, because crane refuses to push a
# layout holding more than one entry to a single reference
build_registry_images() {
  local yml
  for yml in "$KI_ROOT_PATH"/*"$REGISTRY_IMAGES_YML_SUFFIX"; do
    [[ ! -f $yml ]] && continue
    build_registry "$yml"
  done

  return 0
}

build_registry() {
  local yml=$1

  local registry_name
  registry_name=$(basename "$yml" "$REGISTRY_IMAGES_YML_SUFFIX")

  local output_path
  output_path="$BUNDLE_PATH/$registry_name-images"

  msg "[INFO] Building the images of the registry[\"$registry_name\"]"

  rm -rf "$output_path"
  mkdir -p "$output_path"

  local images
  local mappings
  images=$($YQ_CMD -o json '.images' < "$yml")
  mappings=$($YQ_CMD -o json '.mappings // []' < "$yml")

  local full_name
  local repo_and_tag
  for full_name in $($YQ_CMD --null-input "$images | join(\" \")"); do
    repo_and_tag=$(get_repo_and_tag_from_mappings "$full_name" "$mappings")
    [[ -z $repo_and_tag ]] &&
      repo_and_tag=$(parse_repo_and_tag "$full_name")
    [[ -z $repo_and_tag ]] &&
      die "[ERROR] Invalid image name[\"$full_name\"]"

    # The path under the output directory is the reference the image is pushed
    # to, so nothing else has to carry the mapping from a file to a reference
    msg "[INFO]   $repo_and_tag  <-  $full_name"
    mkdir -p "$(dirname "$output_path/$repo_and_tag")"
    "$CRANE_CMD" pull --platform "$platform" --format oci --annotate-ref "$full_name" "$output_path/$repo_and_tag"
  done

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

parse_repo_and_tag() {
  local full_name=$1

  echo "$full_name" | grep -oP '^([a-z0-9A-Z]\.)*[a-z0-9-]+\.([a-z0-9]{2,24})+(\.co\.([a-z0-9]{2,24})|\.([a-z0-9]{2,24}))*(:[0-9]+)?/?\K[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*(\/[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*)*:[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}'

  return 0
}

main
