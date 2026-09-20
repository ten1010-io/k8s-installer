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

DOWNLOAD_URL="https://k8s-installer-bin.s3.ap-northeast-2.amazonaws.com/1.0.x/bundle.tgz"

KI_ROOT_PATH=$SCRIPT_DIR_PATH
BUNDLE_PATH="$KI_ROOT_PATH"/bundle
BUNDLE_ARCHIVE_PATH="$KI_ROOT_PATH"/bundle.tgz

main() {
  [[ -e $BUNDLE_PATH && -d $BUNDLE_PATH ]] && die "[ERROR] Directory \"bundle\" already exists"
  [[ -e $BUNDLE_PATH ]] && die "[ERROR] File of which name is \"bundle\" exists"

  download_bundle_tgz
  tar xzfv "$BUNDLE_ARCHIVE_PATH" --directory "$KI_ROOT_PATH"
  rm -f "$BUNDLE_ARCHIVE_PATH"
}

has_command() {
  local command
  command=$1

  exit_code=0
  type "$command" &>/dev/null || exit_code=$?
  if [[ $exit_code = 0 ]]; then echo "true"; else echo "false"; fi

  return 0
}

download_bundle_tgz() {
  local has_curl
  has_curl=$(has_command curl)
  local has_wget
  has_wget=$(has_command wget)

  if [[ "${has_curl}" = "true" ]]; then
    curl -L "$DOWNLOAD_URL" -o "$BUNDLE_ARCHIVE_PATH"
    return 0
  fi

  if [[ "${has_wget}" = "true" ]]; then
    wget "$DOWNLOAD_URL" -O "$BUNDLE_ARCHIVE_PATH"
    return 0
  fi

  msg "[ERROR] Fail to download bundle.tgz. either curl or wget must be installed"
  return 1
}

main
