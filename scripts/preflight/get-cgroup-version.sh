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

# Reports which cgroup hierarchy the node actually boots, which is what decides
# whether kubelet will run on it at all.
#
# kubernetes 1.35 made failCgroupV1 default to true, so a kubelet of 1.35 or
# newer refuses to start on a cgroup v1 host, and kubeadm made cgroup v1 a fatal
# preflight error in the same release. Both are opened per node rather than for
# the cluster, so what a node boots has to be known before its configuration is
# rendered.
#
# The node is asked rather than the distribution read, the way
# get-node-resources.sh asks. The distribution is only the default: rhel 8 comes
# up on cgroup v1 and ubuntu 22.04 and 24.04 on cgroup v2, but a node given
# systemd.unified_cgroup_hierarchy on its kernel command line is on the other
# one, and a node that was moved has to be read as moved.
#
# The question asked here is the one kubelet asks itself. kubelet calls the
# hierarchy unified when the filesystem mounted at /sys/fs/cgroup is cgroup2 and
# treats everything else as v1, which includes the hybrid layout where a cgroup2
# hierarchy is mounted further down while the controllers are still on v1
CGROUP_ROOT_PATH=/sys/fs/cgroup

main() {
  local cgroup_version
  cgroup_version=$(get_cgroup_version)

  print_yaml "$cgroup_version"
}

get_cgroup_version() {
  local fs_type
  fs_type=$(stat -fc %T "$CGROUP_ROOT_PATH") ||
    die "[ERROR] Fail to read the filesystem mounted at \"$CGROUP_ROOT_PATH\""

  [[ $fs_type = "cgroup2fs" ]] && { echo "v2"; return 0; }

  echo "v1"

  return 0
}

print_yaml() {
  cat <<YAML
---
cgroup_version: "$1"
YAML

  return 0
}

main
