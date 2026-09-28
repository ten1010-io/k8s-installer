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

# Reports the time zone of the node, as an iana name.
#
# What reads it is the ki cp services: every one of them is a container that
# writes its own timestamps, and the zone they render in is whatever TZ says.
# Taking it from the node makes those timestamps read like the journal of the
# machine they are on, which is what somebody comparing the two during an
# incident needs. See docs/impl-notes.adoc
#
# timedatectl is asked first because it is what set the zone, and the symlink is
# read after it because a minimal install can be without systemd-timedated while
# still carrying /etc/localtime. A node that answers neither is reported as UTC:
# the containers then render what the node renders when it does not know either,
# and nothing has to fail over a timestamp
main() {
  local timezone

  timezone=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  [[ -z $timezone ]] && timezone=$(read_localtime_symlink)
  [[ -z $timezone ]] && timezone="Etc/UTC"

  echo "$timezone"

  return 0
}

read_localtime_symlink() {
  local target
  target=$(readlink -f /etc/localtime 2>/dev/null || true)

  [[ $target != */zoneinfo/* ]] && return 0

  echo "${target#*/zoneinfo/}"

  return 0
}

main
