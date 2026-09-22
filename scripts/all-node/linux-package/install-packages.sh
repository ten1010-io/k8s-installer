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

k8s_minor_version=""
k8s_packages_path=""

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

  k8s_minor_version=$($yq_cmd '.k8s_minor_version' < "$vars_path")

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
  set_k8s_packages_path ubuntu22.04
  require_declared_packages ubuntu22.04 deb

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
  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu22.04/nftables
  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu22.04/docker

  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu22.04/nvidia-container-toolkit

  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu22.04/ethtool
  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu22.04/socat
  dpkg -R -i "$k8s_packages_path"

  end_apt

  "$ki_opt_scripts_path/systemctl.sh" reload

  settle_units

  return 0
}

ubuntu2404_install() {
  require_packages_installable
  set_k8s_packages_path ubuntu24.04
  require_declared_packages ubuntu24.04 deb

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
  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu24.04/nftables
  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu24.04/docker

  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu24.04/nvidia-container-toolkit

  dpkg -R -i "$ki_opt_bundle_path"/linux-packages/ubuntu24.04/ethtool
  dpkg -R -i "$k8s_packages_path"

  end_apt

  "$ki_opt_scripts_path/systemctl.sh" reload

  settle_units

  return 0
}

rhel8_install() {
  require_packages_installable
  set_k8s_packages_path rhel8
  require_declared_packages rhel8 rpm

  [[ $(getenforce) != "Disabled" ]] && setenforce 0

  yum erase -y --disableplugin subscription-manager \
    systemd-timesyncd \
    ntp \
    chrony

  yum erase -y --disableplugin subscription-manager \
    podman \
    runc \
    systemd-container

  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/nfs-utils

  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/p11-kit
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/autogen-libopts
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/gmp
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/libidn2
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/libtasn1
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/nettle
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/gnutls
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/chrony

  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/audit
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/libsepol
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/pcre2
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/libselinux
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/libsemanage
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/python3-setools
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/checkpolicy
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/mcstrans
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/policycoreutils
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/selinux-policy
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/container-selinux
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/libseccomp
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/containerd

  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/systemd
  kill -TERM 1
  wait_systemd_ready 300
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/libaio
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/device-mapper
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/fuse3
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/fuse-overlayfs
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/libcgroup
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/slirp
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/conntrack
  if [[ $(rhel8_is_installed "^libibverbs\.") = "false" ]]; then
    rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/libibverbs
  fi
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/ebtables
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/nftables
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/docker

  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/nvidia-container-toolkit

  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/ethtool
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/libbpf
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/iproute
  rhel8_install_rpms "$ki_opt_bundle_path"/linux-packages/rhel8/socat
  rhel8_install_rpms "$k8s_packages_path"

  "$ki_opt_scripts_path/systemctl.sh" reload

  settle_units

  return 0
}

# The packages of kubernetes sit one directory below the rest, under the name of
# the minor they are, because the bundle carries every minor the release supports
# and this node may only be given the one the cluster runs. Handing dpkg the
# directory above would hand it three kubelets
set_k8s_packages_path() {
  local os_dir=$1

  k8s_packages_path="$ki_opt_bundle_path/linux-packages/$os_dir/k8s/$k8s_minor_version"
  [[ ! -d $k8s_packages_path ]] &&
    die "[ERROR] No such directory of which path is \"$k8s_packages_path\". The bundle of this release does not carry the packages of kubernetes[\"$k8s_minor_version\"]"

  return 0
}

# Refuses a bundle that does not hold what the release says it holds.
#
# The packages release.yml declares are the ones the installer chose: they come
# from the repository of whoever makes them rather than from the distribution,
# which is why one name and one upstream version cover every os here. Everything
# else under linux-packages is the dependency closure an offline install needs,
# named and versioned per distribution and picked by nobody, so it is neither
# declared nor checked. A package in the bundle that is not declared is fine; a
# package declared and not in the bundle is not.
#
# Left unchecked, the version of containerd or docker a node ends up with is
# whatever the directory the bundle was filled from happened to hold, and two
# nodes of one cluster can differ without anything saying so. Which is not
# hypothetical: the bundle this check was written against carried docker compose
# 2.40.3 for ubuntu 22.04 and 5.1.0 for ubuntu 24.04, and both ki cp nodes of the
# test cluster were running the ki cp services under them
require_declared_packages() {
  local os_dir=$1
  local pkg_kind=$2

  local declared
  declared=$($yq_cmd '.ki_release_packages // {} | to_entries | .[] | .key + " " + (.value | tostring)' < "$vars_path")
  [[ -z $declared ]] &&
    die "[ERROR] Variable[\"ki_release_packages\"] of file[\"$vars_path\"] is empty. it is read from packages of release.yml, so a vars file without it was not written by the playbooks of this release"

  local bundled
  bundled=$(list_bundled_packages "$ki_opt_bundle_path/linux-packages/$os_dir" "$pkg_kind")

  local errors=""
  local name
  local version
  local found
  while read -r name version; do
    [[ -z $name ]] && continue

    found=$(awk -v n="$name" '$1 == n { print $2; exit }' <<< "$bundled")
    if [[ -z $found ]]; then
      errors+="\n  package[\"$name\"] is declared as version[\"$version\"] and is not in the bundle"
      continue
    fi

    [[ $found != "$version" ]] &&
      errors+="\n  package[\"$name\"] is declared as version[\"$version\"] and the bundle holds version[\"$found\"]"
  done <<< "$declared"

  [[ -n $errors ]] &&
    die "[ERROR] The bundle does not hold what release[\"$($yq_cmd '.ki_release_version' < "$vars_path")\"] declares under packages, for os[\"$os_dir\"]:$errors"

  return 0
}

# The name and the upstream version of every package file under a directory, one
# line each.
#
# Upstream version alone: a deb carries an epoch in front and a packaging release
# behind, an rpm carries a release behind, and those differ per os by design.
# 28.5.2 arrives as docker-ce_5:28.5.2-1~ubuntu.22.04~jammy on one node and as
# docker-ce-28.5.2-1.el8 on another, and both are the docker a release names.
# "rpm --queryformat %{VERSION}" already answers that way and a deb version is cut
# down to it here.
#
# The k8s directory is left out. Those packages are pinned per minor by
# k8s_versions rather than once for the release, and this node is only handed the
# minor its cluster runs
list_bundled_packages() {
  local dir=$1
  local pkg_kind=$2

  local files=()
  mapfile -t files < <(find "$dir" -path "$dir/k8s" -prune -o -type f -name "*.$pkg_kind" -print)
  [[ ${#files[@]} = 0 ]] && return 0

  if [[ $pkg_kind = "rpm" ]]; then
    rpm -qp --queryformat '%{NAME} %{VERSION}\n' "${files[@]}" 2>/dev/null
    return 0
  fi

  local file
  for file in "${files[@]}"; do
    dpkg-deb -W --showformat='${Package} ${Version}\n' "$file"
  done | sed -e 's/ [0-9]*:/ /' -e 's/-[^ -]*$//'

  return 0
}

# Hands rpm the packages of a directory, less the ones already installed at the
# version the bundle holds.
#
# Reinstalling a package that is already there reads like a no-op, and on the
# ubuntu path dpkg treats it as one. containerd.io is not: it declares
# "Provides: containerd" and "Conflicts: containerd" at once, and rpm exempts a
# package from its own conflict only while the incoming one replaces a different
# version of itself. Handed the copy that is already installed, it finds the
# incoming conflict met by the installed provide and refuses the transaction:
#
#   containerd conflicts with containerd.io-1.7.28-1.el8.x86_64
#   containerd conflicts with (installed) containerd.io-1.7.28-1.el8.x86_64
#
# Which is every --update of a release that left containerd where it was, and
# most releases do: the run stops there, with the packages after it untouched and
# the node half updated. containerd.io is the only package of the bundle that
# declares a conflict on something it provides without a version bound, but that
# is a fact about what the bundle holds today rather than about rpm, so the skip
# is not written around that one name.
#
# Leaving what is already installed alone is also what an update is asking for. A
# version the node does not have still goes in, downgrade and all
rhel8_install_rpms() {
  local dir=$1

  local to_install=()
  local rpm_file
  local nvr
  for rpm_file in "$dir"/*.rpm; do
    # An unmatched glob arrives as itself, which is a directory holding no rpm
    [[ -e $rpm_file ]] || continue

    # The epoch is left out, since that is the form "rpm -q" takes
    nvr=$(rpm -qp --queryformat '%{NAME}-%{VERSION}-%{RELEASE}' "$rpm_file" 2>/dev/null)
    [[ -n $nvr ]] && rpm -q "$nvr" &>/dev/null && continue

    to_install+=("$rpm_file")
  done

  [[ ${#to_install[@]} = 0 ]] && return 0

  rpm --force -Uvh --oldpackage --replacepkgs "${to_install[@]}"

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
