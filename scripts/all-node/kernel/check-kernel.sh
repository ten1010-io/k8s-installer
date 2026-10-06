#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--node name]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--node          Name to report this node under
EOF
  exit
}

parse_params() {
  node=""

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --node)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      node="${2-}"
      shift
      ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ -z "${node-}" ]] && die "[ERROR] Missing required option: --node"

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

# Says which of the modules a node of the cluster loads its running kernel can
# not, one line each on stdout, and nothing when it loads them all. Run by
# setup-boot-config.yml on a node that was just rebooted onto the kernel of the
# bundle, where a line is a failure: the run was asked to deliver a node that
# can load these and has not. Also what an operator who installed
# kernel-modules-extra by hand runs to see whether that was enough

source "$SCRIPT_DIR_PATH"/kernel-common.sh

main() {
  local module
  while IFS= read -r module; do
    [[ -z $module ]] && continue
    echo "Node[\"$node\"] runs kernel[\"$(uname -r)\"], which can not load module[\"$module\"]"
  done < <(missing_kernel_modules)

  exit 0
}

main
