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

main() {
  distribution="$(get_distribution)"
  major_version="$(get_major_version "$distribution")"
  minor_version="$(get_minor_version "$distribution" "$major_version")"

  print_yaml "$distribution" "$major_version" "$minor_version"
}

get_distribution() {
  grep -oP "^ID=\"?\K\w+(?=\"?$)" /etc/os-release
}

get_major_version() {
  local distribution="$1"

  local version_id
  version_id="$(grep -oP "^VERSION_ID=\"?\K[0-9.]+(?=\"?$)" /etc/os-release)"

  if [[ $distribution = "ubuntu" ]]; then
    echo "$version_id"
    return 0
  fi

  if [[ $distribution = "rhel" ]]; then
    echo "$version_id" | grep -oP "^[0-9]+(?=.[0-9]+$)"
    return 0
  fi

  msg "[ERROR] Distribution[$distribution] is not supported"
  return 1
}

get_minor_version() {
  local distribution="$1"
  local major_version="$2"

  local version_id
  version_id=$(grep -oP "^VERSION_ID=\"?\K[0-9.]+(?=\"?$)" /etc/os-release)
  local version
  version=$(grep -oP "^VERSION=\"?\K[0-9.a-zA-Z \(\)]+(?=\"?$)" /etc/os-release)

  if [[ $distribution = "ubuntu" ]]; then
    local minor_version
    minor_version="$(echo "$version" | grep -oP "$major_version.\K[0-9]+")"

    [[ -z $minor_version ]] && minor_version="0"

    echo "$minor_version"
    return 0
  fi

  if [ "$distribution" = "rhel" ]; then
    echo "$version_id" | grep -oP "^[0-9]+.\K[0-9]+$"
    return 0
  fi

  msg "[ERROR] Distribution[$distribution] is not supported"
  return 1
}

print_yaml() {
  cat <<EOF
---
distribution: "$1"
major_version: "$2"
minor_version: "$3"
EOF
}

main
