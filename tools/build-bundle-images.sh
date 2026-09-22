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

# This fills the image half of a bundle that is being built, so it works on an
# unpacked bundle directory rather than on the archive the installer consumes.
# The archive is made from that directory once this has run
KI_ROOT_PATH=$(cd "$SCRIPT_DIR_PATH/.." &>/dev/null && pwd -P)
BUNDLE_PATH="$KI_ROOT_PATH"/bundle
YQ_CMD="$BUNDLE_PATH"/bin/yq
CRANE_CMD="$BUNDLE_PATH"/bin/crane

CONSTANT_VARS_PATH="$KI_ROOT_PATH"/ansible/group_vars/all/constant-vars.yml
RELEASE_META_PATH="$KI_ROOT_PATH"/release.yml
SERVICE_IMAGES_PATH="$BUNDLE_PATH"/ki-cp-service-images

# The one registry the bundle carries. Named here rather than found by looking
# for files of a shape, which used to pick up every *-images.yml beside it: the
# user registry declares its contents the same way and must not end up in a
# release bundle, since what it holds is chosen by whoever runs the cluster
K8S_REGISTRY_NAME="ki-cp-k8s-registry"
K8S_REGISTRY_IMAGES_YML_PATH="$KI_ROOT_PATH/$K8S_REGISTRY_NAME-images.yml"

main() {
  require_bundle
  require_version_matches_window

  build_service_images
  build_registry_images

  msg ""
  msg "[INFO] Bundle images built"

  return 0
}

require_bundle() {
  [[ ! -d $BUNDLE_PATH ]] && die "[ERROR] Directory[\"$BUNDLE_PATH\"] not exists. unpack the bundle being built there first"
  [[ ! -x $YQ_CMD ]] && die "[ERROR] File[\"$YQ_CMD\"] not exists or is not executable"
  [[ ! -x $CRANE_CMD ]] && die "[ERROR] File[\"$CRANE_CMD\"] not exists or is not executable"
  [[ ! -f $CONSTANT_VARS_PATH ]] && die "[ERROR] No such file or directory of which path is \"$CONSTANT_VARS_PATH\""
  [[ ! -f $K8S_REGISTRY_IMAGES_YML_PATH ]] && die "[ERROR] No such file or directory of which path is \"$K8S_REGISTRY_IMAGES_YML_PATH\""
  [[ ! -f $RELEASE_META_PATH ]] && die "[ERROR] No such file or directory of which path is \"$RELEASE_META_PATH\""

  return 0
}

# The minor of the version is the highest minor of the window, by the definition
# of the scheme rather than by convention: the number exists so that what a
# release can run is readable without a table. A release whose version and window
# disagree is one whose number says something untrue, and nothing downstream can
# work that out. Caught while the bundle is built, which is the last point at
# which the two are still being decided. See release.yml
require_version_matches_window() {
  local version
  version=$($YQ_CMD '.version' < "$RELEASE_META_PATH")
  [[ -z $version || $version = "null" ]] && die "[ERROR] File[\"$RELEASE_META_PATH\"] has no version"

  # 1.36.1-SNAPSHOT -> 1.36
  local version_minor="${version%%-*}"
  version_minor="${version_minor%.*}"

  local top
  top=$(get_k8s_minor_versions | sort -t. -k1,1n -k2,2n | tail -1)
  [[ -z $top ]] && die "[ERROR] File[\"$RELEASE_META_PATH\"] declares no kubernetes versions"

  [[ $version_minor = "$top" ]] && return 0

  msg "[ERROR] Release[\"$version\"] and the window it declares disagree"
  msg "[ERROR]   the version says kubernetes[\"$version_minor\"]"
  msg "[ERROR]   the highest minor of k8s_versions is kubernetes[\"$top\"]"
  die "[ERROR] The minor of the version is the highest minor the release carries. Fix whichever of the two is wrong"
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

    require_declared_digest "$var" "$image"

    msg "[INFO]   $svc_name  <-  $image"
    "$CRANE_CMD" pull --platform "$platform" --format tarball "$image" "$SERVICE_IMAGES_PATH/$svc_name.tar"
  done

  return 0
}

# Refuses to build when a tag no longer points at what constant-vars.yml records
# it pointed at. Several of these tags move by design, and a bundle that quietly
# holds something other than the one built from the same source last time is
# exactly what the release scheme exists to prevent.
#
# The image is still pulled by the tag rather than by the digest. Pulling by
# digest loses the tag: crane writes the tarball under the placeholder reference
# "i-was-a-digest", docker load brings the image in under that name, and the
# compose file of the service then asks for a name that is not there and tries to
# fetch it, which in an air gap is where the install stops.
#
# Asked without a platform, so that what is compared is the index and one
# recorded digest holds for every architecture the bundle is built for
require_declared_digest() {
  local var=$1
  local image=$2

  local declared
  declared=$($YQ_CMD ".${var}_digest" < "$CONSTANT_VARS_PATH")
  [[ -z $declared || $declared = "null" ]] &&
    die "[ERROR] Variable[\"${var}_digest\"] has no value. Run \"crane digest $image\" and record what it prints"

  local actual
  actual=$("$CRANE_CMD" digest "$image")

  [[ $actual = "$declared" ]] && return 0

  msg "[ERROR] Image[\"$image\"] is no longer what variable[\"${var}_digest\"] records"
  msg "[ERROR]   recorded: $declared"
  msg "[ERROR]   registry: $actual"
  die "[ERROR] The tag was moved. Find out what changed, and if the new image is wanted, record the new digest in the same commit that says so"
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
# One directory per kubernetes minor the release carries, because a node is
# given the images of the minor its cluster runs and the registry is filled from
# that directory alone. release.yml decides which minors those are, so a minor
# in the window with no images declared for it is a failed build rather than a
# bundle that is quietly missing half of what a cluster will ask for
build_registry_images() {
  local output_root
  output_root="$BUNDLE_PATH/$K8S_REGISTRY_NAME-images"

  rm -rf "$output_root"

  local minor
  for minor in $(get_k8s_minor_versions); do
    build_registry_images_of_minor "$minor" "$output_root/$minor"
  done

  return 0
}

get_k8s_minor_versions() {
  $YQ_CMD '.k8s_versions | keys | .[]' < "$RELEASE_META_PATH"

  return 0
}

build_registry_images_of_minor() {
  local minor=$1
  local output_path=$2

  local yml="$K8S_REGISTRY_IMAGES_YML_PATH"

  msg "[INFO] Building the images of the registry[\"$K8S_REGISTRY_NAME\"] for kubernetes[\"$minor\"]"

  mkdir -p "$output_path"

  local images
  local mappings
  images=$($YQ_CMD -o json ".[\"$minor\"].images" < "$yml")
  mappings=$($YQ_CMD -o json ".[\"$minor\"].mappings // []" < "$yml")
  [[ -z $images || $images = "null" ]] &&
    die "[ERROR] File[\"$yml\"] declares no images for kubernetes[\"$minor\"], which release.yml says this release carries. Ask the kubeadm of that minor for them. See the comment at the top of that file"

  require_declared_pause "$minor" "$images"

  local full_name
  local repo_and_tag
  for full_name in $($YQ_CMD --null-input "$images | join(\" \")"); do
    repo_and_tag=$(get_repo_and_tag_from_mappings "$full_name" "$mappings")
    [[ -z $repo_and_tag ]] &&
      repo_and_tag=$(parse_repo_and_tag "$full_name")
    [[ -z $repo_and_tag ]] &&
      die "[ERROR] Invalid image name[\"$full_name\"]"

    # The path under the directory of the minor is the reference the image is
    # pushed to, so nothing else has to carry the mapping from a file to a
    # reference
    msg "[INFO]   $repo_and_tag  <-  $full_name"
    mkdir -p "$(dirname "$output_path/$repo_and_tag")"
    "$CRANE_CMD" pull --platform "$platform" --format oci --annotate-ref "$full_name" "$output_path/$repo_and_tag"
  done

  return 0
}

# The nodes are told which sandbox image to pull by k8s_versions of release.yml,
# and the registry is filled from the list here. Those are two files, so they can
# disagree, and a node whose containerd asks for a pause the registry does not
# hold is a node where nothing starts at all. Compared while the bundle is built,
# which is the one moment both are in hand
require_declared_pause() {
  local minor=$1
  local images=$2

  local in_list
  in_list=$($YQ_CMD --null-input "$images | map(select(test(\"/pause:\"))) | .[0] // \"\"")
  in_list=${in_list##*:}
  [[ -z $in_list ]] &&
    die "[ERROR] File[\"$K8S_REGISTRY_IMAGES_YML_PATH\"] declares no pause image for kubernetes[\"$minor\"]. kubeadm asks for one, so the list is incomplete"

  local declared
  declared=$($YQ_CMD ".k8s_versions[\"$minor\"].pause" < "$RELEASE_META_PATH")
  [[ -z $declared || $declared = "null" ]] &&
    die "[ERROR] File[\"$RELEASE_META_PATH\"] declares no pause for kubernetes[\"$minor\"]. The nodes read it from there and never from the image list"

  [[ $declared = "$in_list" ]] && return 0

  msg "[ERROR] The pause of kubernetes[\"$minor\"] is declared twice and the two disagree"
  msg "[ERROR]   release.yml:                   $declared"
  msg "[ERROR]   $K8S_REGISTRY_NAME-images.yml: $in_list"
  die "[ERROR] The registry would be filled with one and the nodes told to pull the other. Take the one the kubeadm of that minor asks for"
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
