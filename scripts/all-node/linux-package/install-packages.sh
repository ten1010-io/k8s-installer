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

# shellcheck source=rpm-common.sh
source "$SCRIPT_DIR_PATH/rpm-common.sh"
# shellcheck source=deb-common.sh
source "$SCRIPT_DIR_PATH/deb-common.sh"

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

k8s_minor_version=""
k8s_packages_path=""

# What a rhel install erases before it lays the bundle down: the time services
# the bundled chrony replaces, and the container tools containerd.io conflicts
# with
RHEL_ERASED_PACKAGES=(systemd-timesyncd ntp chrony podman runc systemd-container)

# What an ubuntu install removes before it lays the bundle down: the time
# services that are not systemd-timesyncd, which is the one setup-ntp-client.sh
# runs on an ubuntu. systemd-timesyncd itself is left where it is: the systemd
# directory carries it and goes in at its version (setup_deb_plan_args), so
# there is nothing a removal would do that the install does not
UBUNTU_REMOVED_PACKAGES=(ntp chrony)

# The directories of an ubuntu, in the order the dependencies between them want
UBUNTU_DEB_DIRS=(nfs-common systemd dbus pigz slirp containerd iptables ebtables conntrack nftables docker nvidia-container-toolkit ethtool socat)

# The arguments plan-rpm-install.py is given on this node: which packages are
# the release's own and go in at their version whatever the node holds
rpm_plan_args=()

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

  if [[ $os_distribution = "rhel" && $os_major_version = "9" && $os_minor_version -le "$RHEL9_SUPPORTED_MINOR_VERSION" ]]; then
    rhel9_install
    exit 0
  fi

  if [[ $os_distribution = "rhel" && $os_major_version = "10" && $os_minor_version -le "$RHEL10_SUPPORTED_MINOR_VERSION" ]]; then
    rhel10_install
    exit 0
  fi

  die "[ERROR] OS not supported\n$os_info"
}

ubuntu2204_install() {
  require_packages_installable
  set_k8s_packages_path ubuntu22.04
  require_declared_packages ubuntu22.04 deb
  setup_deb_plan_args ubuntu22.04
  ubuntu_require_installable ubuntu22.04

  begin_apt

  if [[ $("$ki_opt_scripts_path/systemctl.sh" exists ntp) = "true" ]]; then
    apt remove -y --purge --allow-change-held-packages \
      ntp
  fi

  if [[ $("$ki_opt_scripts_path/systemctl.sh" exists chrony) = "true" ]]; then
    apt remove -y --purge --allow-change-held-packages \
      chrony
  fi

  ubuntu_install_debs ubuntu22.04

  end_apt

  "$ki_opt_scripts_path/systemctl.sh" reload

  settle_units

  return 0
}

ubuntu2404_install() {
  require_packages_installable
  set_k8s_packages_path ubuntu24.04
  require_declared_packages ubuntu24.04 deb
  setup_deb_plan_args ubuntu24.04
  ubuntu_require_installable ubuntu24.04

  begin_apt

  if [[ $("$ki_opt_scripts_path/systemctl.sh" exists ntp) = "true" ]]; then
    apt remove -y --purge --allow-change-held-packages \
      ntp
  fi

  if [[ $("$ki_opt_scripts_path/systemctl.sh" exists chrony) = "true" ]]; then
    apt remove -y --purge --allow-change-held-packages \
      chrony
  fi

  ubuntu_install_debs ubuntu24.04

  end_apt

  "$ki_opt_scripts_path/systemctl.sh" reload

  settle_units

  return 0
}

rhel8_install() {
  rhel_install rhel8
}

rhel9_install() {
  rhel_install rhel9
}

rhel10_install() {
  rhel_install rhel10
}

# rhel 8, 9 and 10 are one path over three directories. The closure of each was
# resolved on the oldest minor the release supports against what that minor
# already has (tools/build-bundle-packages.sh), so a directory holds the
# principal package and whatever an old minor lacks for it, and the three
# directories hold the same names in the same order. What one rhel needs and
# another does not, such as the libcgroup of 8 or the devel headers only its
# bundle carries, is inside the directory that asked for it or is a directory
# the other two leave empty.
#
# iptables is the one principal whose package differs: on 8 it is iptables
# itself with the ebtables shim beside it, and from 9 on the only thing that
# provides what kubelet and docker ask for is iptables-nft
rhel_install() {
  local os_dir=$1

  require_packages_installable
  set_k8s_packages_path "$os_dir"
  require_declared_packages "$os_dir" rpm
  setup_rpm_plan_args

  # The openssl systemd brings is one the sshd of an old minor refuses to load,
  # so the openssh built against it follows at once. Its package restarts sshd;
  # the connection this runs over survives that, and the next one is served by
  # the new daemon. On a minor that already holds both at a newer version, the
  # plan keeps the two of them
  local dirs=(nfs-utils chrony container-selinux containerd systemd openssh fuse-overlayfs slirp conntrack)
  if [[ $(rhel_is_installed "^libibverbs\.") = "false" ]]; then
    dirs+=(libibverbs)
  fi
  # iptables: iptables itself on 8, iptables-nft from 9 on. devel: the headers of
  # what came before, which only the rhel 8 bundle carries; empty on the others
  dirs+=(iptables nftables docker nvidia-container-toolkit ethtool iproute socat devel)

  local base="$ki_opt_bundle_path/linux-packages/$os_dir"
  rhel_require_installable "$base" "${dirs[@]}"

  [[ $(getenforce) != "Disabled" ]] && setenforce 0

  dnf erase -y --disableplugin subscription-manager \
    systemd-timesyncd \
    ntp \
    chrony

  dnf erase -y --disableplugin subscription-manager \
    podman \
    runc \
    systemd-container

  # Planned once over every directory, now that the node is as the install
  # leaves it: a source the node keeps is kept in the directory its devel
  # package sits in as much as in the one its library does
  rhel_plan_install "$base" "${dirs[@]}"

  local dir
  for dir in "${dirs[@]}"; do
    rhel_install_rpms "$base/$dir"
    if [[ $dir = "systemd" ]]; then
      rhel_reexec_systemd_if_installed
    fi
  done
  rhel_install_rpms "$k8s_packages_path"

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
# package release.yml declares that the node holds at another version still goes
# in, downgrade and all. A dependency the node holds at a newer version does not:
# plan-rpm-install.py says why, and rpm_install_planned of rpm-common.sh prints
# it
#
# Hands dpkg the directories of an ubuntu, in the order the dependencies between
# them want. One list for both: a directory is one principal and what the GA
# image of that ubuntu lacks for it (tools/build-bundle-packages.sh fills them),
# and a principal the GA image already holds at the newest version has no
# directory at all. Such a one is skipped here, since dpkg refuses a directory
# with no deb in it.
#
# The GA image is the oldest point release, so a node of a later one holds much
# of a directory newer. A dependency it holds newer it keeps, with the rest of
# its source package, and a package the release declares goes in at its version
# all the same (deb-common.sh). What is installed at the version the bundle
# holds is not handed over either.
#
# The plan is made once over every directory, now that the node is as the
# install leaves it, and each directory is then installed from it: a source
# the node keeps is kept wherever its debs sit
ubuntu_install_debs() {
  local os_dir=$1

  local base="$ki_opt_bundle_path/linux-packages/$os_dir"

  local files=()
  mapfile -t files < <(ubuntu_deb_files "$os_dir")
  deb_plan_install "${files[@]}"

  local dir
  for dir in "${UBUNTU_DEB_DIRS[@]}"; do
    if [[ $dir = "systemd" ]]; then
      ubuntu_install_deb_dir "$base/$dir" --force-confnew
    else
      ubuntu_install_deb_dir "$base/$dir"
    fi
  done
  ubuntu_install_deb_dir "$k8s_packages_path"

  return 0
}

ubuntu_install_deb_dir() {
  local dir=$1
  shift

  local files=()
  mapfile -t files < <(deb_files_of "$dir")
  if [[ ${#files[@]} = 0 ]]; then
    msg "[INFO] Directory[\"$(basename "$dir")\"] holds no deb. nothing this os lacks for it"
    return 0
  fi

  deb_install_planned "$(basename "$dir")" "$@" -- "${files[@]}"

  return 0
}

# Every deb an ubuntu install lays down, one path per line, in the order the
# directories are installed
ubuntu_deb_files() {
  local os_dir=$1

  local base="$ki_opt_bundle_path/linux-packages/$os_dir"
  local dir
  for dir in "${UBUNTU_DEB_DIRS[@]}"; do
    deb_files_of "$base/$dir"
  done
  deb_files_of "$k8s_packages_path"

  return 0
}

# The packages release.yml declares, and the packages of kubernetes, go in at
# their version whatever the node holds.
#
# So does the systemd directory, alone among the dependencies. The bundle names
# systemd as a principal rather than taking what something else requires
# (tools/build-bundle-packages.sh), and setup-ntp-client.sh runs the time of an
# ubuntu on the systemd-timesyncd built with it, which wants systemd at exactly
# its version. A node whose systemd is one build newer than the bundle's, an
# image released after the bundle or a node patched since, would otherwise keep
# its own and leave the bundle's timesyncd out; where the image ships chrony
# instead, as the ubuntu images of ec2 do, that node would end the install with
# no time service and no way to get one offline. The bundle's systemd is the
# newest build of the same version the repository had when the bundle was made,
# one build behind such a node at most, and going down to it is what every
# install did before there was a plan. What it would break on the node is
# found by the apt simulation of ubuntu_require_installable before anything is
# removed
setup_deb_plan_args() {
  local os_dir=$1

  deb_principal_dirs=("$k8s_packages_path" "$ki_opt_bundle_path/linux-packages/$os_dir/systemd")
  deb_principals=()

  local name
  while read -r name; do
    [[ -n $name ]] && deb_principals+=("$name")
  done < <($yq_cmd '.ki_release_packages // {} | keys | .[]' < "$vars_path")

  return 0
}

# Refuses the node before anything is removed, if the plan would break or take
# away a package of it
ubuntu_require_installable() {
  local os_dir=$1

  local files=()
  mapfile -t files < <(ubuntu_deb_files "$os_dir")

  deb_require_installable "${UBUNTU_REMOVED_PACKAGES[@]}" -- "${files[@]}"

  return 0
}

# Hands rpm the rpms of one directory the plan of rhel_plan_install says go in
rhel_install_rpms() {
  local dir=$1

  local files=()
  local rpm_file
  for rpm_file in "$dir"/*.rpm; do
    # An unmatched glob arrives as itself, which is a directory holding no rpm
    [[ -e $rpm_file ]] && files+=("$rpm_file")
  done

  rpm_installed_count=0
  [[ ${#files[@]} = 0 ]] && return 0

  rpm_install_planned "$(basename "$dir")" "${files[@]}"

  return 0
}

# Every rpm under the directories given, one path per line, in the order the
# directories are installed. A name is a directory of the bundle under base, a
# path is itself; the packages of kubernetes come last, as they are installed
rhel_rpm_files() {
  local base=$1
  shift

  local dir
  local rpm_file
  for dir in "$@"; do
    [[ $dir = /* ]] || dir="$base/$dir"
    for rpm_file in "$dir"/*.rpm; do
      [[ -e $rpm_file ]] && printf '%s\n' "$rpm_file"
    done
  done

  return 0
}

# Plans the whole install at once, every directory and the packages of
# kubernetes, so that each directory is then installed from one plan
rhel_plan_install() {
  local base=$1
  shift

  local files=()
  mapfile -t files < <(rhel_rpm_files "$base" "$@" "$k8s_packages_path")

  rpm_plan_install "${rpm_plan_args[@]}" -- "${files[@]}"

  return 0
}

# The packages release.yml declares, and the packages of kubernetes, go in at
# their version whatever the node holds. Every other rpm of the bundle is a
# dependency, which the node keeps where it holds a newer one
setup_rpm_plan_args() {
  rpm_plan_args=(--principal-dir "$k8s_packages_path")

  local name
  while read -r name; do
    [[ -n $name ]] && rpm_plan_args+=(--principal "$name")
  done < <($yq_cmd '.ki_release_packages // {} | keys | .[]' < "$vars_path")

  return 0
}

# Refuses the node before anything is erased, if rpm would refuse what the plan
# lays down
rhel_require_installable() {
  local base=$1
  shift

  local files=()
  mapfile -t files < <(rhel_rpm_files "$base" "$@" "$k8s_packages_path")

  rpm_require_installable "${RHEL_ERASED_PACKAGES[@]}" -- "${rpm_plan_args[@]}" -- "${files[@]}"

  return 0
}

# systemd re-executes on SIGTERM to pid 1, which is how the one just laid down
# takes over without a reboot. Where the node kept its own, there is nothing to
# take over
rhel_reexec_systemd_if_installed() {
  if [[ $rpm_installed_count = 0 ]]; then
    msg "[INFO] systemd of the node is kept. not re-executing it"
    return 0
  fi

  kill -TERM 1
  wait_systemd_ready 300

  return 0
}

rhel_is_installed() {
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
