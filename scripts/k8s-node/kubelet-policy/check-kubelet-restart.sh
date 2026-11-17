#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--vars-path path] [--node name]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--vars-path     File path
--node          Name to report this node under
EOF
  exit
}

parse_params() {
  vars_path=""
  node=""

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --vars-path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      vars_path="${2-}"
      shift
      ;;
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

  [[ -z "${vars_path-}" ]] && die "[ERROR] Missing required option: --vars-path"
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
  [[ -n "${pods_json_path-}" ]] && rm -f "$pods_json_path"
}

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT
setup_colors
parse_params "$@"

# --- End of CLI template ---

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

pods_json_path=""

# Says which running containers kubelet of this node would refuse to admit again
# if it were restarted now, one line each, and nothing when there are none.
#
# Asked before kubelet is restarted for a configuration change. A restart is
# meant to leave the containers running - containerd holds them and kubelet picks
# them back up - and on a node whose cpu manager runs the static policy with
# full-pcpus-only, before kubernetes 1.37, it does not: a container that holds
# more exclusive cpus than are left free is refused and killed. See
# find-containers-refused-on-restart.py for how that is worked out, and
# docs/impl-notes.adoc for what was measured.
#
# The version is asked of the binary on disk rather than of the cluster, because
# that is the binary a restart starts
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  local kubelet_version
  kubelet_version=$(kubelet --version) ||
    die "[ERROR] Failed to ask kubelet of this node for its version"

  write_pods_json

  "$ki_opt_venv_path"/bin/python3 "$SCRIPT_DIR_PATH"/find-containers-refused-on-restart.py \
      --node "$node" \
      --kubelet-version "$kubelet_version" \
      --pods-json-path "$pods_json_path" ||
    die "[ERROR] Failed to work out which containers a restart of kubelet would refuse on node[\"$node\"]"

  return 0
}

# Only to name the pods in the report. A runtime that does not answer leaves the
# file empty and the pods are named by their uid
write_pods_json() {
  pods_json_path=$(mktemp)
  crictl pods -o json > "$pods_json_path" 2>/dev/null || true

  return 0
}

import_ki_opt_vars() {
  ki_opt_root_path=$(grep -oP  "^ki_opt_root_path: \K(.+)" < "$vars_path")
  ki_opt_scripts_path=$(grep -oP  "^ki_opt_scripts_path: \K(.+)" < "$vars_path")
  ki_opt_bundle_path=$(grep -oP  "^ki_opt_bundle_path: \K(.+)" < "$vars_path")
  ki_opt_venv_path=$(grep -oP  "^ki_opt_venv_path: \K(.+)" < "$vars_path")
}

validate_ki_opt_directory() {
  require_directory_exists "$ki_opt_scripts_path"
  require_directory_exists "$ki_opt_bundle_path"
  require_directory_exists "$ki_opt_venv_path"

  return 0
}

require_file_exists() {
  local path=$1

  [[ ! -e $path ]] && die "[ERROR] No such file or directory of which path is \"$path\""
  [[ ! -f $path ]] && die "[ERROR] File[\"$path\"] is not a regular file"

  return 0
}

require_directory_exists() {
  local path=$1

  [[ ! -e $path ]] && die "[ERROR] No such file or directory of which path is \"$path\""
  [[ ! -d $path ]] && die "[ERROR] File[\"$path\"] is not a directory"

  return 0
}

main
