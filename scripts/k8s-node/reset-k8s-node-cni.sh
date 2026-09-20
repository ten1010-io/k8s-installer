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

# Network interfaces and state directories left behind by CNI plugins.
# Kept as an explicit list since a CNI managed interface can not be told apart
# from an operator managed one at runtime.
CNI_LINK_NAMES=(
  cni0
  flannel.1
  flannel-v6.1
  kube-ipvs0
  kube-bridge
  vxlan.calico
  vxlan-v6.calico
  tunl0
  cilium_host
  cilium_net
  cilium_vxlan
  antrea-gw0
  weave
  datapath
)

CNI_STATE_PATHS=(
  /etc/cni/net.d
  /var/lib/cni
  /var/lib/calico
  /var/lib/cilium
  /var/lib/weave
  /var/run/flannel
  /var/run/calico
  /var/run/cilium
)

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bin_path=""
ki_opt_venv_path=""

yq_cmd=""
jinja2_cmd=""

main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  delete_cni_links
  delete_cni_state_paths

  "$ki_opt_scripts_path/flush-iptables.sh"

  return 0
}

delete_cni_links() {
  local name

  for name in "${CNI_LINK_NAMES[@]}"; do
    if [[ $(link_exists "$name") = "true" ]]; then
      # Best effort. some interfaces, such as tunl0, are provided by a kernel
      # module and can not be deleted
      ip link del "$name" || msg "[WARN] Failed to delete network interface[\"$name\"]"
    fi
  done

  return 0
}

delete_cni_state_paths() {
  local path
  local real_path
  local mount_point

  for path in "${CNI_STATE_PATHS[@]}"; do
    # /var/run is a symlink to /run on the supported distributions, so resolve
    # the path before comparing it against mount points
    real_path=$(readlink -f "$path" 2>/dev/null || echo "$path")
    if [[ ! -e $real_path ]]; then
      continue
    fi

    # Some CNI plugins, such as cilium, mount a filesystem below their state
    # directory. its contents can not be removed, so unmount it first. the
    # deepest mount point comes first
    while read -r mount_point; do
      if [[ -n $mount_point ]]; then
        umount "$mount_point" || msg "[WARN] Failed to unmount[\"$mount_point\"]"
      fi
    done < <(list_mount_points_under "$real_path")

    # Best effort. a mount point that could not be unmounted keeps its contents
    rm -rf "$real_path" || msg "[WARN] Failed to delete directory[\"$real_path\"]"
  done

  return 0
}

list_mount_points_under() {
  local path=$1

  findmnt -rno TARGET | awk -v p="$path" '$0 == p || index($0, p "/") == 1' | sort -r

  return 0
}

link_exists() {
  local name=$1

  local exit_code=0
  ip link show "$name" > /dev/null 2>&1 || exit_code=$?
  if [[ $exit_code = 0 ]]; then echo "true"; else echo "false"; fi

  return 0
}

import_ki_opt_vars() {
  ki_opt_root_path=$(grep -oP  "^ki_opt_root_path: \K(.+)" < "$vars_path")
  ki_opt_scripts_path=$(grep -oP  "^ki_opt_scripts_path: \K(.+)" < "$vars_path")
  ki_opt_bin_path=$(grep -oP  "^ki_opt_bin_path: \K(.+)" < "$vars_path")
  ki_opt_venv_path=$(grep -oP  "^ki_opt_venv_path: \K(.+)" < "$vars_path")
}

setup_cmd_vars() {
  yq_cmd="$ki_opt_bin_path/bin/yq"
  jinja2_cmd="$ki_opt_venv_path/bin/jinja2"
}

validate_ki_opt_directory() {
  require_directory_exists "$ki_opt_scripts_path"
  require_directory_exists "$ki_opt_bin_path"
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
