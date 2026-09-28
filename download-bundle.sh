#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
EOF
  exit
}

parse_params() {
  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
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

DOWNLOAD_BASE_URL="https://k8s-installer-bundle.s3.ap-northeast-2.amazonaws.com"

# Kept in step with the one setup.sh and upgrade.sh carry
SNAPSHOT_SUFFIX="-SNAPSHOT"

KI_ROOT_PATH=$SCRIPT_DIR_PATH
RELEASE_META_PATH="$KI_ROOT_PATH"/release.yml

version=""
bundle_archive_path=""
download_url=""

main() {
  [[ ! -f $RELEASE_META_PATH ]] && die "[ERROR] No such file or directory of which path is \"$RELEASE_META_PATH\""

  # yq is in the bundle this is about to download, so the one key needed here is
  # read the way the node scripts read their vars file
  version=$(grep -oP '^version: "\K[^"]+' < "$RELEASE_META_PATH")
  [[ -z $version ]] && die "[ERROR] File[\"$RELEASE_META_PATH\"] has no version"

  bundle_archive_path="$KI_ROOT_PATH/bundle-$version.tgz"
  download_url="$DOWNLOAD_BASE_URL/bundle-$version.tgz"

  [[ -e $bundle_archive_path ]] && die "[ERROR] File[\"$bundle_archive_path\"] already exists"

  msg "[INFO] Downloading the bundle of release[\"$version\"] from \"$download_url\""

  # Left as the archive it arrived as. setup.sh unpacks it straight into the
  # installer directory, and an air gapped control node never runs this script at
  # all: the archive is carried in on media and dropped here under the same name
  download_bundle_tgz
  verify_bundle_archive

  msg "[INFO] Bundle saved to \"$bundle_archive_path\""
}

# The archive is checked where it lands rather than where it is unpacked, so
# that a download that ended short is a failed download instead of a file that
# looks like a bundle. It is removed on a mismatch: left behind, the next run
# would stop at the guard above saying the file already exists.
#
# An empty checksum is a snapshot, whose bundle is republished under the same
# name as often as development needs and so has no one value to check against
verify_bundle_archive() {
  # A grep that matches nothing ends this script without a word, so the line is
  # asked for by its shape before its value is read. A key that is not there, or
  # a value left unquoted, is a release.yml this can not read rather than a
  # release that declares nothing
  grep -q '^bundle_sha256: "' < "$RELEASE_META_PATH" ||
    die "[ERROR] File[\"$RELEASE_META_PATH\"] has no bundle_sha256. it is written as bundle_sha256: \"<sha256>\", and only a snapshot leaves it empty"

  local expected
  expected=$(grep -oP '^bundle_sha256: "\K[^"]*' < "$RELEASE_META_PATH")
  if [[ -z $expected ]]; then
    [[ $version == *"$SNAPSHOT_SUFFIX" ]] ||
      die "[ERROR] Release[\"$version\"] declares no bundle_sha256. a release bundle is published once, so fill it in release.yml"

    msg "[INFO] Release[\"$version\"] is a snapshot, whose bundle is republished under the same name, so there is nothing to check it against"
    return 0
  fi

  local actual
  actual=$(sha256sum "$bundle_archive_path" | cut -d' ' -f1)
  if [[ $actual != "$expected" ]]; then
    rm -f "$bundle_archive_path"
    die "[ERROR] Bundle of release[\"$version\"] has sha256[\"$actual\"] and release.yml declares sha256[\"$expected\"]. the file was removed"
  fi

  msg "[INFO] Bundle matches the sha256 release.yml declares"

  return 0
}

has_command() {
  local command
  command=$1

  exit_code=0
  type "$command" &>/dev/null || exit_code=$?
  if [[ $exit_code = 0 ]]; then echo "true"; else echo "false"; fi

  return 0
}

# Both of these write the archive in place as it arrives and leave behind
# whatever they had written when the transfer does not finish. curl only learned
# --remove-on-error in 7.76 and the rhel 8 path carries an older one, and wget
# has nothing of the kind, so what they leave is removed here
download_bundle_tgz() {
  local has_curl
  has_curl=$(has_command curl)
  local has_wget
  has_wget=$(has_command wget)

  if [[ "${has_curl}" = "true" ]]; then
    curl -fL "$download_url" -o "$bundle_archive_path" || remove_partial_archive
    return 0
  fi

  if [[ "${has_wget}" = "true" ]]; then
    wget "$download_url" -O "$bundle_archive_path" || remove_partial_archive
    return 0
  fi

  msg "[ERROR] Fail to download bundle.tgz. either curl or wget must be installed"
  return 1
}

# A transfer that stopped part way is a failed download, not a bundle. Left in
# place it is worse than nothing: the next run reads it as the archive already
# being there and stops before downloading anything
remove_partial_archive() {
  rm -f "$bundle_archive_path"
  die "[ERROR] Fail to download the bundle of release[\"$version\"] from \"$download_url\". the partial file was removed"
}

main
