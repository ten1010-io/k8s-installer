#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--vars-path path]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--vars-path     File path
EOF
  exit
}

parse_params() {
  vars_path=""

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
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ -z "${vars_path-}" ]] && die "[ERROR] Missing required option: --vars-path"

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

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

# The drop in of kubelet.service this owns. 20 sorts after the 10-kubeadm.conf
# the kubelet package ships, and the name says whose it is, so that a reset
# removes this one file and nothing of kubeadm's
DROP_IN_DIR_PATH=/etc/systemd/system/kubelet.service.d
DROP_IN_PATH="$DROP_IN_DIR_PATH"/20-ki-kubelet-policy-state.conf

# The file drop-kubelet-policy-state.sh leaves behind once it has run in a boot,
# and the same path it looks for. Spelled here as well because this script puts
# it there too - see mark_this_boot_as_started
MARKER_PATH=/run/k8s-installer/kubelet-policy-state-dropped

# Makes kubelet.service take the checkpoints of its cpu manager and memory
# manager away at the first start of every boot. See
# drop-kubelet-policy-state.sh for why a checkpoint is worth keeping across a
# restart and worth nothing across a boot.
#
# On every k8s node, whatever its policies. A node that runs the default
# policies writes checkpoints that say so and loses nothing when they go, and a
# node whose policies are turned on later by update-cluster.yml is then already
# covered - the drop in does not have to know what the node runs, only that it
# runs kubelet. The unit is written again by the same callers that write the
# kubelet configuration of a node, which is also where the path of the scripts
# directory is known from
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  create_drop_in_file
  mark_this_boot_as_started

  return 0
}

# The boot this runs in has had its first kubelet start already, or is about to
# have one that has nothing to take away, so the drop in starts counting from the
# next boot.
#
# Without this the first restart after the drop in is written would be the first
# start of the boot as far as the drop in can tell, and it would take the
# checkpoints away from a kubelet whose containers are still running - which is
# exactly the case the checkpoints are kept for, and the case the caller did not
# drain the node for. A cluster built before the drop in existed is given it by
# update-k8s-node-kubelet.sh on a plain restart, and a node that already pins
# cpus and memory would have had every assignment redone under it. On the init
# and join paths kubelet has not started yet and there is no checkpoint to lose,
# so the marker costs nothing there and one rule covers both
mark_this_boot_as_started() {
  mkdir -p "$(dirname "$MARKER_PATH")"
  touch "$MARKER_PATH"

  return 0
}

# The - lets kubelet start even if this could not run, since a kubelet that does
# not start is the failure this exists to prevent. The script writes nothing to
# the unit's environment and reads no vars file, so it needs nothing that is not
# on the node at boot
create_drop_in_file() {
  mkdir -p "$DROP_IN_DIR_PATH"

  cat > "$DROP_IN_PATH".tmp <<EOF
# Written by k8s-installer: see $ki_opt_scripts_path/k8s-node/kubelet-policy/drop-kubelet-policy-state.sh
[Service]
ExecStartPre=-$ki_opt_scripts_path/k8s-node/kubelet-policy/drop-kubelet-policy-state.sh
EOF

  chmod 0644 "$DROP_IN_PATH".tmp
  mv -f "$DROP_IN_PATH".tmp "$DROP_IN_PATH"

  "$ki_opt_scripts_path"/systemctl.sh reload

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
