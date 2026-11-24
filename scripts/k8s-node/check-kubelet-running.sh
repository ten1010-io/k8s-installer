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

# How many times the unit is asked and how far apart. A kubelet that refuses its
# configuration is started again every ten seconds and is up for about a quarter
# of a second each time (measured on 1.36), so one question can land on the
# quarter second and three questions two seconds apart can not. Overridable so
# that a test does not have to wait
KUBELET_QUESTIONS=${KUBELET_QUESTIONS:-3}
KUBELET_QUESTION_INTERVAL=${KUBELET_QUESTION_INTERVAL:-2}

# Says whether the kubelet of this node is running, true or false, and waits for
# nothing.
#
# Asked before a node is drained. A drain evicts the pods of a node and waits
# for each of them to be gone, and gone is something only the kubelet of that
# node can say. With no kubelet the wait runs out and the drain fails - measured,
# five minutes later - on a node whose pods nothing is running anyway. That is
# the node an apply that failed leaves behind: its kubelet was given a
# configuration it refuses and has been starting over since, and what brings it
# back is the configuration being written again, which is the step the drain is
# in front of.
#
# wait-kubelet-running.sh is the other question, for a node that was just
# rebooted: it waits for the unit to come up. This one is for a node nothing was
# done to, where a unit that is not running now is not about to be.
#
# Asked of the unit on the node rather than of the cluster, for the reason given
# there: the node object keeps the Ready a kubelet last reported for as long as
# the lease allows, so a kubelet that died a moment ago still reads as Ready
main() {
  local asked=0

  while :; do
    systemctl -q is-active kubelet > /dev/null 2>&1 || { echo "false"; exit 0; }

    asked=$((asked + 1))
    [[ $asked -lt $KUBELET_QUESTIONS ]] || break

    sleep "$KUBELET_QUESTION_INTERVAL"s
  done

  echo "true"

  exit 0
}

main
