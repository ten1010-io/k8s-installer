#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--vars-path path] [--update]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--vars-path     File path
--update        Upgrade the packages of a node that already has them
EOF
  exit
}

parse_params() {
  vars_path=""
  update="false"

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
    --update) update="true" ;;
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
UBUNTU2404_SUPPORTED_MINOR_VERSION=4
RHEL8_SUPPORTED_MINOR_VERSION=10

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""

os_info=""
os_distribution=""
os_major_version=""
os_minor_version=""

main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory
  get_os_version

  if [[ $os_distribution = "ubuntu" && $os_major_version = "22.04" && $os_minor_version -le "$UBUNTU2204_SUPPORTED_MINOR_VERSION" ]]; then
    ubuntu2204_install
    exit 0
  fi

  if [[ $os_distribution = "ubuntu" && $os_major_version = "24.04" && $os_minor_version -le "$UBUNTU2404_SUPPORTED_MINOR_VERSION" ]]; then
    ubuntu2404_install
    exit 0
  fi

  if [[ $os_distribution = "rhel" && $os_major_version = "8" && $os_minor_version -le "$RHEL8_SUPPORTED_MINOR_VERSION" ]]; then
    rhel8_install
    exit 0
  fi

  die "[ERROR] OS not supported\n$os_info"
}

ubuntu2204_install() {
  require_packages_installable

  begin_apt

  if [[ $("$ki_opt_scripts_path/systemctl.sh" exists systemd-timesyncd) = "true" ]]; then
    apt remove -y --purge --allow-change-held-packages \
      systemd-timesyncd
  fi

  if [[ $("$ki_opt_scripts_path/systemctl.sh" exists ntp) = "true" ]]; then
    apt remove -y --purge --allow-change-held-packages \
      ntp
  fi

  if [[ $("$ki_opt_scripts_path/systemctl.sh" exists chrony) = "true" ]]; then
    apt remove -y --purge --allow-change-held-packages \
      chrony
  fi

  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu22.04/nfs-common

  dpkg -R -i --force-confnew "$ki_opt_bundle_path"/linux-packages/ubuntu22.04/systemd

  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu22.04/libltdl7
  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu22.04/pigz
  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu22.04/slirp
  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu22.04/containerd
  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu22.04/conntrack
  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu22.04/ebtables
  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu22.04/docker

  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu22.04/nvidia-container-toolkit

  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu22.04/ethtool
  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu22.04/socat
  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu22.04/k8s

  end_apt

  "$ki_opt_scripts_path/systemctl.sh" reload

  settle_units

  return 0
}

ubuntu2404_install() {
  require_packages_installable

  begin_apt

  if [[ $("$ki_opt_scripts_path/systemctl.sh" exists systemd-timesyncd) = "true" ]]; then
    apt remove -y --purge --allow-change-held-packages \
      systemd-timesyncd
  fi

  if [[ $("$ki_opt_scripts_path/systemctl.sh" exists ntp) = "true" ]]; then
    apt remove -y --purge --allow-change-held-packages \
      ntp
  fi

  if [[ $("$ki_opt_scripts_path/systemctl.sh" exists chrony) = "true" ]]; then
    apt remove -y --purge --allow-change-held-packages \
      chrony
  fi

  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu24.04/nfs-common

  dpkg -R -i --force-confnew "$ki_opt_bundle_path"/linux-packages/ubuntu24.04/systemd
  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu24.04/dbus

  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu24.04/pigz
  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu24.04/slirp
  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu24.04/containerd
  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu24.04/iptables
  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu24.04/conntrack
  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu24.04/docker

  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu24.04/nvidia-container-toolkit

  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu24.04/ethtool
  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu24.04/k8s

  end_apt

  "$ki_opt_scripts_path/systemctl.sh" reload

  settle_units

  return 0
}

rhel8_install() {
  require_packages_installable

  [[ $(getenforce) != "Disabled" ]] && setenforce 0

  yum erase -y --disableplugin subscription-manager \
    systemd-timesyncd \
    ntp \
    chrony

  yum erase -y --disableplugin subscription-manager \
    podman \
    runc \
    systemd-container

  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/nfs-utils/*.rpm

  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/p11-kit/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/autogen-libopts/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/gmp/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/libidn2/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/libtasn1/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/nettle/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/gnutls/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/chrony/*.rpm

  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/audit/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/libsepol/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/pcre2/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/libselinux/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/libsemanage/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/python3-setools/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/checkpolicy/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/mcstrans/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/policycoreutils/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/selinux-policy/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/container-selinux/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/libseccomp/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/containerd/*.rpm

  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/systemd/*.rpm
  kill -TERM 1
  wait_systemd_ready 300
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/libaio/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/device-mapper/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/fuse3/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/fuse-overlayfs/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/libcgroup/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/slirp/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/conntrack/*.rpm
  if [[ $(rhel8_is_installed "^libibverbs\.") = "false" ]]; then
    rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/libibverbs/*.rpm
  fi
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/ebtables/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/docker/*.rpm

  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/nvidia-container-toolkit/*.rpm

  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/ethtool/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/libbpf/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/iproute/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/socat/*.rpm
  rpm --force -Uvh --oldpackage --replacepkgs "$ki_opt_bundle_path"/linux-packages/rhel8/k8s/*.rpm

  "$ki_opt_scripts_path/systemctl.sh" reload

  settle_units

  return 0
}

rhel8_is_installed() {
  local pkg_regex=$1

  local exit_code=0
  yum list installed --disableplugin subscription-manager 2> /dev/null | grep "$pkg_regex" > /dev/null 2>/dev/null || exit_code=$?

  if [[ $exit_code = "0" ]]; then echo "true"; else echo "false"; fi

  return 0
}

# A first install refuses to run over packages that are already there, because
# what it would be doing then is an upgrade it was not asked for. An update is
# that upgrade, so the same packages being present is the point
require_packages_installable() {
  [[ $update = "true" ]] && return 0

  require_not_installed containerd
  require_not_installed docker
  require_not_installed kubelet

  return 0
}

# A first install leaves every unit disabled, because what enables them is the
# playbook that sets each one up in its turn. An update finds them enabled and
# running and leaves them exactly as they are: disabling them would stop
# services that are serving, and restarting them is somebody else's job
# Which services run and when is the installer's to decide, not the distribution's.
#
# needrestart hooks itself into apt as a DPkg::Post-Invoke and restarts every
# daemon it finds running a binary that has been replaced. The first thing done
# here is an apt remove, so the hook fires before a single package of the bundle
# has been laid down, and on a second run it finds kubelet and containerd
# already carrying new binaries from the first one. Measured on a node whose
# upgrade was being repeated after a failure, it printed
#
#   Restarting services...
#    systemctl restart containerd.service kubelet.service multipathd.service ...
#
# and the kubelet that came back died on --pod-infra-container-image, which
# 1.35 removed and which /var/lib/kubelet/kubeadm-flags.env still named because
# kubeadm had not run yet. The node went NotReady and the upgrade that was being
# retried refused to start against it. See settle_units for the same hazard from
# the other direction.
#
# Everything this installs is restarted by something that runs after it and
# knows more, so there is nothing here for needrestart to be right about
begin_apt() {
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_SUSPEND=1

  return 0
}

end_apt() {
  export DEBIAN_FRONTEND=""
  unset NEEDRESTART_SUSPEND

  return 0
}

settle_units() {
  if [[ $update = "false" ]]; then
    "$ki_opt_scripts_path/systemctl.sh" disable kubelet
    "$ki_opt_scripts_path/systemctl.sh" disable docker.socket
    "$ki_opt_scripts_path/systemctl.sh" disable docker
    "$ki_opt_scripts_path/systemctl.sh" disable containerd

    return 0
  fi

  # Nothing is restarted here, on purpose. Every unit whose package this just
  # replaced is restarted by something that runs after it and knows more:
  # setup-containerd.sh and setup-docker.sh each render their configuration and
  # then restart, and kubelet is restarted by the caller once kubeadm has been
  # through. Restarting here as well means doing it twice, the first time onto
  # configuration that is about to be rewritten.
  #
  # For kubelet it was worse than wasteful. kubeadm records the flags it starts
  # kubelet with in /var/lib/kubelet/kubeadm-flags.env, and a release that drops
  # a flag leaves that file naming one the new binary does not know: 1.35
  # removed --pod-infra-container-image, and a kubelet restarted onto the new
  # package before that file was rewritten died parsing its own arguments,
  # restart after restart. With kubelet gone, the static pods it runs were never
  # picked up, so the control plane upgrade waited five minutes for a pod hash
  # that could not change and rolled itself back. "kubeadm upgrade node" is what
  # rewrites that file, which is why the old binary has to keep running until
  # then. begin_apt keeps needrestart from doing the same thing from outside
  return 0
}

require_not_installed() {
  local svc_name=$1

  local result
  result=$("$ki_opt_scripts_path/systemctl.sh" exists "$svc_name")
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
