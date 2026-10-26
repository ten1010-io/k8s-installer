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
RELEASE_META_PATH="$KI_ROOT_PATH"/release.yml

# Kept in sync with ki_opt_root_path of group_vars/all/constant-vars.yml, the way
# setup.sh keeps its copy: this runs on a box that need not have ansible at all
KI_OPT_ROOT_PATH="/opt/k8s-installer"
KI_OPT_BUNDLE_BIN_PATH="$KI_OPT_ROOT_PATH"/bundle/bin
KI_OPT_RELEASE_META_PATH="$KI_OPT_ROOT_PATH"/release.yml

# Set by locate_bundle_bin once it knows which copy of the bundle they come from
YQ_CMD=""
CRANE_CMD=""

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
  require_images_yml

  local staging_path
  staging_path=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$staging_path'" EXIT

  locate_bundle_bin "$staging_path"

  pull_references "$staging_path/$REGISTRY_NAME-images"
  create_archive "$staging_path"

  msg ""
  msg "[INFO] Wrote \"$ARCHIVE_PATH\""
  msg "[INFO] Carry it to the control node and push it with:"
  msg "[INFO]   ansible-playbook -i inventory.yml playbooks/push-user-registry-images.yml -e archive=<path>"

  return 0
}

# The bundle is never unpacked into this tree. download-bundle.sh leaves it beside
# the tree as the archive it was published as, and setup.sh unpacks that into
# /opt/k8s-installer on the control node, so there is no bundle/ here to look in:
# the one place that has such a directory is the machine a bundle is built on.
# Asking for it sent the user back to a download-bundle.sh they had already run.
# The two binaries are looked for where the bundle actually is, in this order:
#
#   1. bundle-<version>.tgz beside this tree. It is what download-bundle.sh
#      leaves, and the sha256 of release.yml was checked against this very file.
#      Only the two binaries are taken out of it, into the staging directory:
#      the archive is a couple of gigabytes and nothing else in it is of use here
#   2. /opt/k8s-installer/bundle, where setup.sh unpacked it, for a tree that
#      sits on the control node and whose archive has since been cleared away.
#      Taken only when the release set up there is the release of this tree,
#      since the bundle of another release carries another crane, and the whole
#      point of reaching for the bundle is to pull with the crane the nodes push
#      with
#
# The members are asked for by name rather than searched for, so an archive that
# lacks one is refused as not being a bundle instead of failing further on
locate_bundle_bin() {
  local staging_path=$1

  # yq is one of the two things being looked for, so the one key needed to name
  # the archive is read the way download-bundle.sh reads it
  local version
  version=$(grep -oP '^version: "\K[^"]+' < "$RELEASE_META_PATH" || true)
  [[ -z $version ]] && die "[ERROR] File[\"$RELEASE_META_PATH\"] has no version"

  local archive_path="$KI_ROOT_PATH/bundle-$version.tgz"
  if [[ -f $archive_path ]]; then
    msg "[INFO] Taking crane and yq out of \"$archive_path\""
    tar xzf "$archive_path" -C "$staging_path" bundle/bin/crane bundle/bin/yq ||
      die "[ERROR] File[\"$archive_path\"] holds no bundle/bin/crane or no bundle/bin/yq. it is not a bundle of this installer, or did not arrive whole"
    require_bundle_bin "$staging_path/bundle/bin"
    return 0
  fi

  if [[ -d $KI_OPT_BUNDLE_BIN_PATH ]]; then
    local opt_version
    opt_version=$(grep -oP '^version: "\K[^"]+' < "$KI_OPT_RELEASE_META_PATH" 2>/dev/null || true)
    [[ $opt_version != "$version" ]] &&
      die "[ERROR] File[\"$archive_path\"] not exists, and what is set up in \"$KI_OPT_ROOT_PATH\" is release[\"${opt_version:-unknown}\"] rather than release[\"$version\"] of this tree, whose bundle carries another crane. run ./download-bundle.sh, which brings the one this needs"
    msg "[INFO] Using crane and yq of \"$KI_OPT_BUNDLE_BIN_PATH\", where setup.sh unpacked the bundle of release[\"$version\"]"
    require_bundle_bin "$KI_OPT_BUNDLE_BIN_PATH"
    return 0
  fi

  die "[ERROR] File[\"$archive_path\"] not exists. run ./download-bundle.sh, which brings the crane this needs, or place the bundle of release[\"$version\"] there"
}

require_bundle_bin() {
  local bin_path=$1

  YQ_CMD="$bin_path"/yq
  CRANE_CMD="$bin_path"/crane
  [[ ! -x $YQ_CMD ]] && die "[ERROR] File[\"$YQ_CMD\"] not exists or is not executable"
  [[ ! -x $CRANE_CMD ]] && die "[ERROR] File[\"$CRANE_CMD\"] not exists or is not executable"

  return 0
}

require_images_yml() {
  [[ ! -f $IMAGES_YML_PATH ]] &&
    die "[ERROR] No such file or directory of which path is \"$IMAGES_YML_PATH\". declare the images to carry in it, the way $KI_ROOT_PATH/ki-cp-k8s-registry-images.yml declares the ones of the cluster itself"

  return 0
}

# The images and the charts of the keep file, into one tree. Both end up in the
# same registry and are carried in the same archive, so the only thing that tells
# them apart here is how they are pulled
pull_references() {
  local output_path=$1

  local images
  local charts
  local mappings
  images=$($YQ_CMD -o json '.images // []' < "$IMAGES_YML_PATH")
  charts=$($YQ_CMD -o json '.charts // []' < "$IMAGES_YML_PATH")
  mappings=$($YQ_CMD -o json '.mappings // []' < "$IMAGES_YML_PATH")

  [[ $($YQ_CMD --null-input "$images | length") -eq 0 &&
     $($YQ_CMD --null-input "$charts | length") -eq 0 ]] &&
    die "[ERROR] File[\"$IMAGES_YML_PATH\"] declares nothing under key[\"images\"] or key[\"charts\"]"

  mkdir -p "$output_path"

  pull_list "$output_path" "$images" "$mappings" image
  pull_list "$output_path" "$charts" "$mappings" chart

  return 0
}

# One oci layout per reference, the same shape the bundle carries its registry
# images in, because crane refuses to push a layout holding more than one entry
# to a single reference. The path under the output directory is the reference it
# is pushed to, so nothing else has to carry a mapping from a file to a reference.
#
# An image is pulled for one platform and a chart is pulled whole. --platform
# picks a child of an index, and the manifest of a chart is not one: asking for a
# platform there is asking a question the artifact does not answer. The oci format
# is what carries either - a docker tarball holds an image configuration and a
# chart has none, so --format oci is not a preference here but the reason this
# works for both
pull_list() {
  local output_path=$1
  local refs=$2
  local mappings=$3
  local kind=$4

  [[ $($YQ_CMD --null-input "$refs | length") -eq 0 ]] && return 0

  local -a platform_args=()
  if [[ $kind = "image" ]]; then
    platform_args=(--platform "$platform")
    msg "[INFO] Pulling the images of the registry[\"$REGISTRY_NAME\"] for platform[\"$platform\"]"
  else
    msg "[INFO] Pulling the charts of the registry[\"$REGISTRY_NAME\"]"
  fi

  local full_name
  local repo_and_tag
  for full_name in $($YQ_CMD --null-input "$refs | join(\" \")"); do
    repo_and_tag=$(get_repo_and_tag_from_mappings "$full_name" "$mappings")
    [[ -z $repo_and_tag ]] &&
      repo_and_tag=$(parse_repo_and_tag "$full_name")
    [[ -z $repo_and_tag ]] &&
      die "[ERROR] Invalid $kind name[\"$full_name\"]"

    msg "[INFO]   $repo_and_tag  <-  $full_name"
    mkdir -p "$(dirname "$output_path/$repo_and_tag")"
    "$CRANE_CMD" pull "${platform_args[@]}" --format oci --annotate-ref "$full_name" "$output_path/$repo_and_tag"
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
