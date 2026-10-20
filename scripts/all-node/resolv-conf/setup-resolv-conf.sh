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
ki_cp_ha_mode=""
ki_cp_ha_mode_vip=""
target_node=""
target_node_op=""

main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory
  get_os_version

  ki_tmp_root_path=$($yq_cmd .ki_tmp_root_path < "$vars_path")
  ki_cp_ha_mode=$($yq_cmd .ki_cp_ha_mode < "$vars_path")
  ki_cp_ha_mode_vip=$($yq_cmd .ki_cp_ha_mode_vip < "$vars_path")
  target_node=$($yq_cmd .target_node < "$vars_path")
  target_node_op=$($yq_cmd .target_node_op < "$vars_path")

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
  setup_resolv_conf
}

ubuntu2404_setup() {
  setup_resolv_conf
}

rhel8_setup() {
  setup_resolv_conf
}

rhel9_setup() {
  setup_resolv_conf
}

rhel10_setup() {
  setup_resolv_conf
}

# One body for every os. systemd-resolved used to be turned off only where it
# ships enabled, on ubuntu, and rhel got the NetworkManager drop in alone - but
# what the file written below is for is kubelet, and kubeadm decides where
# kubelet reads its nameservers from by asking whether resolved is active on
# the node it runs on: active, and it points kubelet at the stub file under
# /run/systemd/resolve instead of /etc/resolv.conf. That answer is taken once,
# on the node that initialises the cluster, and uploaded for every node to
# download, so a rhel node that happened to have resolved running handed the
# stub path to nodes that have no such file. The service is stopped wherever it
# exists, then, and only the drop in is a rhel matter: NetworkManager would
# otherwise write the file back on the next lease
setup_resolv_conf() {
  disable_resolved
  [[ $os_distribution = "rhel" ]] && disable_nm_dns
  create_resolv_conf_file
  keep_own_hostname_resolvable
}

# The file written above names the cluster dns and nothing else: no search
# domain, because the one the node had came from its dhcp lease and names a
# network this installer knows nothing about. What that takes away is the
# node's own name. A cloud image is called ip-172-31-62-61, a name only the
# resolver of that cloud answers for, through the search domain the lease
# carried; with the cluster dns forwarding to a public upstream the name is
# gone, and the first thing to say so is sudo, which looks its own host up on
# every call and warns on every call when it can not. The warning is on stderr
# and nothing here reads it as an answer, but a shell that sees it at every
# sudo is one where every real message is lost among them, and kubeadm and
# kubelet look the name up too.
#
# So the name goes into /etc/hosts, against the address of this node, which is
# what the dhcp resolver would have answered and what kubelet is registered
# under. In the hosts file rather than as a record of the cluster dns, because
# a node has to know its own name while that dns is being handed over between
# ki cp nodes, which is when sudo is being run on it most. Left alone when the
# name is already mapped by a line this installer did not write: that is a
# site that put it there on purpose, with an address of its choosing. Our own
# line is replaced on every run, since the address can change with the
# inventory and the name with the node, and the reset leaves it where it is -
# the reset does not give the node its old resolver back either, and a node
# resolving through an upstream still needs its own name
HOSTS_PATH=/etc/hosts
HOSTS_LINE_MARK="# k8s-installer-own-hostname"

keep_own_hostname_resolvable() {
  local name
  name=$(hostname)
  [[ -z $name ]] && die "[ERROR] This node has no hostname to keep resolvable"

  local ip
  ip=$($yq_cmd "[.internal_network_interfaces[] | select(.ip != \"$ki_cp_ha_mode_vip\")][0].ip" < "$vars_path")
  [[ -z $ip || $ip = "null" ]] && die "[ERROR] Could not read the internal address of this node from file[\"$vars_path\"]"

  # Ours from a previous run goes first, so that what is checked below is what
  # somebody else wrote
  sed -i "/ $HOSTS_LINE_MARK\$/d" "$HOSTS_PATH"
  if grep -Eq "^[^#]*[[:space:]]$name([[:space:]]|\$)" "$HOSTS_PATH"; then
    msg "[INFO] Hostname[\"$name\"] is already mapped in $HOSTS_PATH, leaving it as it is"
    return 0
  fi

  # The short name beside the full one on a node whose hostname is qualified,
  # so that the one as well as the other answers. Nothing to add when they are
  # the same word
  local short
  short=${name%%.*}
  [[ $short = "$name" ]] && short=""
  printf '%s %s %s %s\n' "$ip" "$name" "$short" "$HOSTS_LINE_MARK" | tr -s ' ' >> "$HOSTS_PATH"
  msg "[INFO] Hostname[\"$name\"] mapped to address[\"$ip\"] in $HOSTS_PATH"

  return 0
}

create_resolv_conf_file() {
  local dns_servers
  local master_node_ip
  master_node_ip=$(get_ki_cp_master_node_ip)
  if [[ $ki_cp_ha_mode = "true" ]]; then
    dns_servers="[\"$ki_cp_ha_mode_vip\"]"
  else
    dns_servers="[\"$master_node_ip\"]"
  fi

  local tmp_file_path
  tmp_file_path="$ki_tmp_root_path"/tmp-templates-vars.yml
  touch "$tmp_file_path"
  $yq_cmd -i ".dns_servers = $dns_servers" "$tmp_file_path"
  rm -f /etc/resolv.conf
  $jinja2_cmd --format yaml -o "/etc/resolv.conf" "$SCRIPT_DIR_PATH"/templates/resolv.conf.j2 "$tmp_file_path"
  rm "$tmp_file_path"
}

get_ki_cp_master_node_ih() {
  if [[ $target_node = "null" ]] || [[ $target_node != "null" && $target_node_op = "add" ]]; then
    $yq_cmd '.groups.ki_cp_node[0]' < "$vars_path"
  elif [[ $target_node != "null" && $target_node_op = "remove" ]]; then
    $yq_cmd ".groups.ki_cp_node - [\"$target_node\"] | .[0]" < "$vars_path"
  else
    die "[ERROR] Invalid variable[\"target_node\"] or Invalid variable[\"target_node_op\"]"
  fi
}

get_ki_cp_master_node_ip() {
  local ih
  ih=$(get_ki_cp_master_node_ih)
  $yq_cmd '.internal_network_hosts.'"$ih"'.interfaces[0].ip' < "$vars_path"
}

disable_resolved() {
  local result
  result=$("$ki_opt_scripts_path"/systemctl.sh exists systemd-resolved)
  [[ $result = true ]] && "$ki_opt_scripts_path"/systemctl.sh disable systemd-resolved

  return 0
}

disable_nm_dns() {
  mkdir -p /etc/NetworkManager/conf.d
  cp -f "$SCRIPT_DIR_PATH/templates/90-dns-none.conf" /etc/NetworkManager/conf.d/
  systemctl reload NetworkManager

  return 0
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
