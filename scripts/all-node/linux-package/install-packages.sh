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
RHEL8_SUPPORTED_MINOR_VERSION=10

ki_env_path=""
ki_env_scripts_path=""
ki_env_bin_path=""
ki_env_ki_venv_path=""

yq_cmd=""

os_info=""
os_distribution=""
os_major_version=""
os_minor_version=""

main() {
  require_file_exists "$vars_path"
  import_ki_env_vars
  setup_cmd_vars
  require_directory_exists "$ki_env_path"
  validate_ki_env_directory
  get_os_version

  if [[ $os_distribution = "ubuntu" && $os_major_version = "22.04" && $os_minor_version -le "$UBUNTU2204_SUPPORTED_MINOR_VERSION" ]]; then
    ubuntu2204_install
    exit 0
  fi

  if [[ $os_distribution = "rhel" && $os_major_version = "8" && $os_minor_version -le "$RHEL8_SUPPORTED_MINOR_VERSION" ]]; then
    rhel8_install
    exit 0
  fi

  die "[ERROR] OS not supported\n$os_info"
}

ubuntu2204_install() {
  require_not_installed containerd
  require_not_installed docker
  require_not_installed kubelet

  export DEBIAN_FRONTEND=noninteractive

  if [[ $("$ki_env_scripts_path/systemctl.sh" exists systemd-timesyncd) = "true" ]]; then
    apt remove -y --purge --allow-change-held-packages \
      systemd-timesyncd
  fi

  if [[ $("$ki_env_scripts_path/systemctl.sh" exists ntp) = "true" ]]; then
    apt remove -y --purge --allow-change-held-packages \
      ntp
  fi

  if [[ $("$ki_env_scripts_path/systemctl.sh" exists chrony) = "true" ]]; then
    apt remove -y --purge --allow-change-held-packages \
      chrony
  fi

  dpkg -i "$ki_env_bin_path"/linux-packages/ubuntu22.04/systemd/*.deb

  dpkg -i "$ki_env_bin_path"/linux-packages/ubuntu22.04/libltdl7/*.deb
  dpkg -i "$ki_env_bin_path"/linux-packages/ubuntu22.04/pigz/*.deb
  dpkg -i "$ki_env_bin_path"/linux-packages/ubuntu22.04/slirp/*.deb
  dpkg -i "$ki_env_bin_path"/linux-packages/ubuntu22.04/containerd/*.deb
  dpkg -i "$ki_env_bin_path"/linux-packages/ubuntu22.04/conntrack/*.deb
  dpkg -i "$ki_env_bin_path"/linux-packages/ubuntu22.04/ebtables/*.deb
  dpkg -i "$ki_env_bin_path"/linux-packages/ubuntu22.04/docker/*.deb

  dpkg -i "$ki_env_bin_path"/linux-packages/ubuntu22.04/nvidia-container-toolkit/*.deb

  dpkg -i "$ki_env_bin_path"/linux-packages/ubuntu22.04/ethtool/*.deb
  dpkg -i "$ki_env_bin_path"/linux-packages/ubuntu22.04/socat/*.deb
  dpkg -i "$ki_env_bin_path"/linux-packages/ubuntu22.04/k8s/*.deb
  cp -f "$SCRIPT_DIR_PATH/templates/crictl.yaml" /etc/

  export DEBIAN_FRONTEND=""

  "$ki_env_scripts_path/systemctl.sh" reload

  "$ki_env_scripts_path/systemctl.sh" disable kubelet
  "$ki_env_scripts_path/systemctl.sh" disable docker.socket
  "$ki_env_scripts_path/systemctl.sh" disable docker
  "$ki_env_scripts_path/systemctl.sh" disable containerd

  return 0
}

rhel8_install() {
  require_not_installed containerd
  require_not_installed docker
  require_not_installed kubelet

  setenforce 0

  yum erase -y --disableplugin subscription-manager \
    systemd-timesyncd \
    ntp \
    chrony

  yum erase -y --disableplugin subscription-manager \
    podman \
    runc

  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/p11-kit/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/autogen-libopts/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/gmp/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/libidn2/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/libtasn1/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/nettle/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/gnutls/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/chrony/*.rpm

  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/audit/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/libsepol/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/pcre2/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/libselinux/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/libsemanage/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/python3-setools/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/checkpolicy/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/mcstrans/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/policycoreutils/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/selinux-policy/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/container-selinux/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/libseccomp/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/containerd/*.rpm

  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/systemd/*.rpm
  kill -TERM 1
  wait_systemd_ready 300
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/libaio/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/device-mapper/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/fuse3/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/fuse-overlayfs/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/libcgroup/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/slirp/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/conntrack/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/ebtables/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/docker/*.rpm
  sed -i '/StartLimitBurst=/ s/^StartLimitBurst=.\+$/StartLimitBurst=0/g' /usr/lib/systemd/system/docker.service
  sed -i '/StartLimitInterval=/ s/^StartLimitInterval=.\+$/StartLimitInterval=0/g' /usr/lib/systemd/system/docker.service

  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/nvidia-container-toolkit/*.rpm

  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/ethtool/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/libbpf/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/iproute/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/socat/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_env_bin_path"/linux-packages/rhel8/k8s/*.rpm
  cp -f "$SCRIPT_DIR_PATH/templates/crictl.yaml" /etc/

  "$ki_env_scripts_path/systemctl.sh" reload

  "$ki_env_scripts_path/systemctl.sh" disable kubelet
  "$ki_env_scripts_path/systemctl.sh" disable docker.socket
  "$ki_env_scripts_path/systemctl.sh" disable docker
  "$ki_env_scripts_path/systemctl.sh" disable containerd

  return 0
}

require_not_installed() {
  local svc_name=$1

  local result
  result=$("$ki_env_scripts_path/systemctl.sh" exists "$svc_name")
  [[ $result = true ]] && die "[ERROR] Service[\"$svc_name\"] already installed"

  return 0
}

wait_systemd_ready() {
  local timeout=$1

  local elapsed=0
  elapsed=0

  while true; do
    local is_ready
    is_ready=$(is_systemd_ready)
    [[ $is_ready = "true" ]] && break
    [[ $elapsed -ge $timeout ]] && die "[ERROR] Failed to wait for systemd being ready. timeout occurred"

    sleep 3s
    elapsed=$(("$elapsed" + 3))
  done

  return 0
}

is_systemd_ready() {
  local exit_code=0
  systemctl daemon-reexec > /dev/null 2>&1 || exit_code=$?

  if [[ $exit_code = 0 ]]; then echo "true"; else echo "false"; fi

  return 0
}

import_ki_env_vars() {
  ki_env_path=$(grep -oP  "^ki_env_path: \K(.+)" < "$vars_path")
  ki_env_scripts_path=$(grep -oP  "^ki_env_scripts_path: \K(.+)" < "$vars_path")
  ki_env_bin_path=$(grep -oP  "^ki_env_bin_path: \K(.+)" < "$vars_path")
  ki_env_ki_venv_path=$(grep -oP  "^ki_env_ki_venv_path: \K(.+)" < "$vars_path")
}

setup_cmd_vars() {
  yq_cmd="$ki_env_bin_path/bin/yq"
  jinja2_cmd="$ki_env_ki_venv_path/bin/jinja2"
}

get_os_version() {
  os_info=$("$ki_env_scripts_path"/preflight/get-os-info.sh)

  os_distribution=$($yq_cmd .distribution <<< "$os_info")
  os_major_version=$($yq_cmd .major_version <<< "$os_info")
  os_minor_version=$($yq_cmd .minor_version <<< "$os_info")
}

validate_ki_env_directory() {
  require_directory_exists "$ki_env_scripts_path"
  require_directory_exists "$ki_env_bin_path"
  require_directory_exists "$ki_env_ki_venv_path"

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
