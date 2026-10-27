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

# A release records the sha256 of its bundle in release.yml and a snapshot
# leaves it empty. setup.sh, upgrade.sh and download-bundle.sh refuse a
# release that records none, so a release committed with the field empty is
# one no control node will install, and nothing before a customer's control
# node said so. The field is filled on the day the release is cut, by hand or
# by assemble-bundle.sh --write-sha256, which is the day it is forgotten.
#
# A snapshot that records one is the other mistake: its bundle is republished
# under the same name, so a value written for it is wrong by the next
# publish, and the scripts compare against whatever is there.
#
# Read the way those scripts read it, by the shape of the line, so that what
# passes here is what they will accept
KI_ROOT_PATH=$(cd "$SCRIPT_DIR_PATH/.." &>/dev/null && pwd -P)
RELEASE_META_PATH="$KI_ROOT_PATH"/release.yml

# Kept in step with the one download-bundle.sh carries
SNAPSHOT_SUFFIX="-SNAPSHOT"

main() {
  [[ -f $RELEASE_META_PATH ]] || die "[ERROR] No such file or directory of which path is \"$RELEASE_META_PATH\""

  local version
  version=$(grep -oP '^version: "\K[^"]+' < "$RELEASE_META_PATH" || true)
  [[ -z $version ]] && die "[ERROR] File[\"$RELEASE_META_PATH\"] has no version"

  grep -q '^bundle_sha256: "' < "$RELEASE_META_PATH" ||
    die "[ERROR] File[\"$RELEASE_META_PATH\"] has no bundle_sha256. it is written as bundle_sha256: \"<sha256>\", and only a snapshot leaves it empty"

  local sha256
  sha256=$(grep -oP '^bundle_sha256: "\K[^"]*' < "$RELEASE_META_PATH" || true)

  if [[ $version == *"$SNAPSHOT_SUFFIX" ]]; then
    [[ -z $sha256 ]] ||
      die "[ERROR] Release[\"$version\"] is a snapshot and records bundle_sha256[\"$sha256\"]. a snapshot bundle is republished under its name, so there is no one value to record: leave it empty"
    msg "[INFO] Release[\"$version\"] is a snapshot and records no bundle_sha256, as a snapshot does"
    return 0
  fi

  [[ -n $sha256 ]] ||
    die "[ERROR] Release[\"$version\"] records no bundle_sha256, and the scripts refuse a release without one. publish the bundle and record its sha256 before the release is committed"
  [[ $sha256 =~ ^[0-9a-f]{64}$ ]] ||
    die "[ERROR] Release[\"$version\"] records bundle_sha256[\"$sha256\"], which is not a sha256: sixty four hex digits, as sha256sum prints them"

  msg "[INFO] Release[\"$version\"] records the sha256 of its bundle"

  return 0
}

main
