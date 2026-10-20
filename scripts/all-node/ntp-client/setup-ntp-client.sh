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

UBUNTU2204_SUPPORTED_MINOR_VERSION=5
UBUNTU2404_SUPPORTED_MINOR_VERSION=5
RHEL8_SUPPORTED_MINOR_VERSION=10
RHEL9_SUPPORTED_MINOR_VERSION=8
RHEL10_SUPPORTED_MINOR_VERSION=2

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""
jinja2_cmd=""

os_info=""
os_distribution=""
os_major_version=""
os_minor_version=""

ki_tmp_root_path=""
internal_network_ki_cp_dns_name=""
node_is_ki_cp=""
ki_cp_ntp_server_upstream_servers=""

main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory
  get_os_version

  ki_tmp_root_path=$($yq_cmd ".ki_tmp_root_path" < "$vars_path")
  internal_network_ki_cp_dns_name=$($yq_cmd ".internal_network_ki_cp_dns_name" < "$vars_path")
  node_is_ki_cp=$($yq_cmd '.group_names | contains(["ki_cp_node"])' < "$vars_path")
  ki_cp_ntp_server_upstream_servers=$($yq_cmd -o json -I 0 ".ki_cp_ntp_server_upstream_servers" < "$vars_path")

  if [[ $os_distribution = "ubuntu" && $os_major_version = "22.04" && $os_minor_version -le "$UBUNTU2204_SUPPORTED_MINOR_VERSION" ]]; then
    ubuntu2204_setup
    exit 0
  fi

  if [[ $os_distribution = "ubuntu" && $os_major_version = "24.04" && $os_minor_version -le "$UBUNTU2404_SUPPORTED_MINOR_VERSION" ]]; then
    ubuntu2404_setup
    exit 0
  fi

  if [[ $os_distribution = "rhel" && $os_major_version = "8" && $os_minor_version -le "$RHEL8_SUPPORTED_MINOR_VERSION" ]]; then
    rhel8_setup
    exit 0
  fi

  if [[ $os_distribution = "rhel" && $os_major_version = "9" && $os_minor_version -le "$RHEL9_SUPPORTED_MINOR_VERSION" ]]; then
    rhel9_setup
    exit 0
  fi

  if [[ $os_distribution = "rhel" && $os_major_version = "10" && $os_minor_version -le "$RHEL10_SUPPORTED_MINOR_VERSION" ]]; then
    rhel10_setup
    exit 0
  fi

  die "[ERROR] OS not supported\n$os_info"
}

ubuntu2204_setup() {
  create_timesyncd_conf_file
  systemctl enable systemd-timesyncd
  systemctl restart systemd-timesyncd
}

ubuntu2404_setup() {
  create_timesyncd_conf_file
  systemctl enable systemd-timesyncd
  systemctl restart systemd-timesyncd
}

rhel8_setup() {
  create_chrony_conf_file
  systemctl enable chronyd
  systemctl restart chronyd
}

rhel9_setup() {
  create_chrony_conf_file
  systemctl enable chronyd
  systemctl restart chronyd
}

rhel10_setup() {
  create_chrony_conf_file
  systemctl enable chronyd
  systemctl restart chronyd
}

# What a node follows. A node that is not a ki cp follows the ki cp, whose ntp
# server follows the upstream of the site. A ki cp node follows that upstream
# itself, and must not follow its own ntp server: that server is a container
# that measures the clock of this very node against the upstream and hands out
# the corrected time without being allowed to apply it (chronyd -x), so a time
# daemon on the node that steers the node's clock by what the container says
# closes a loop in which each one's correction is the other's error. Measured
# on a single node: the container learned a frequency of -471 ppm and timesyncd
# pinned itself at +500 ppm, which held while the upstream answered and ran the
# clock 11 seconds off in 25 minutes once it did not.
#
# With no upstream at all the ki cp node follows its own ntp server after all.
# The loop needs the container to have measured something, and with nothing
# to measure against it hands out the clock of this node as it is, so the node
# steers by zero: this is the one case in which following it is harmless, and
# the case in which a node that followed nothing would never count as
# synchronised, which the clock check of check-node-state.sh asks about
ntp_servers_of_this_node() {
  local upstream_len
  upstream_len=$($yq_cmd --null-input "$ki_cp_ntp_server_upstream_servers | length")
  if [[ $node_is_ki_cp = "true" && $upstream_len -gt 0 ]]; then
    echo "$ki_cp_ntp_server_upstream_servers"
  else
    echo "[\"$internal_network_ki_cp_dns_name\"]"
  fi
}

create_timesyncd_conf_file() {
  local ntp_servers
  ntp_servers=$($yq_cmd --null-input "$(ntp_servers_of_this_node) | join(\" \")")

  local tmp_file_path
  tmp_file_path="$ki_tmp_root_path"/tmp-templates-vars.yml
  touch "$tmp_file_path"
  $yq_cmd -i ".ntp_servers = \"$ntp_servers\"" "$tmp_file_path"
  $jinja2_cmd --format yaml -o "/etc/systemd/timesyncd.conf" "$SCRIPT_DIR_PATH"/templates/timesyncd.conf.j2 "$tmp_file_path"
  rm "$tmp_file_path"
}

create_chrony_conf_file() {
  local ntp_servers
  ntp_servers=$(ntp_servers_of_this_node)

  local tmp_file_path
  tmp_file_path="$ki_tmp_root_path"/tmp-templates-vars.yml
  touch "$tmp_file_path"
  $yq_cmd -o json -i ".ntp_servers = $ntp_servers" "$tmp_file_path"
  $jinja2_cmd --format yaml -o "/etc/chrony.conf" "$SCRIPT_DIR_PATH"/templates/chrony.conf.j2 "$tmp_file_path"
  rm "$tmp_file_path"
}

import_ki_opt_vars() {
  ki_opt_root_path=$(grep -oP  "^ki_opt_root_path: \K(.+)" < "$vars_path")
  ki_opt_scripts_path=$(grep -oP  "^ki_opt_scripts_path: \K(.+)" < "$vars_path")
  ki_opt_bundle_path=$(grep -oP  "^ki_opt_bundle_path: \K(.+)" < "$vars_path")
  ki_opt_venv_path=$(grep -oP  "^ki_opt_venv_path: \K(.+)" < "$vars_path")
}

setup_cmd_vars() {
  yq_cmd="$ki_opt_bundle_path/bin/yq"
  jinja2_cmd="$ki_opt_venv_path/bin/jinja2"
}

get_os_version() {
  os_info=$("$ki_opt_scripts_path"/preflight/get-os-info.sh)

  os_distribution=$($yq_cmd .distribution <<< "$os_info")
  os_major_version=$($yq_cmd .major_version <<< "$os_info")
  os_minor_version=$($yq_cmd .minor_version <<< "$os_info")
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
