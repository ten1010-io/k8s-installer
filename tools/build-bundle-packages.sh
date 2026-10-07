#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] --os os --out-path path [--root path]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--os            ubuntu22.04, ubuntu24.04, rhel9 or rhel10, which must be what this machine runs
--out-path      Directory to fill, laid out as bundle/linux-packages/<os> is
--root          Resolve against the package database under this directory instead of this machine's
EOF
  exit
}

parse_params() {
  os=""
  out_path=""
  root=""

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --os)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      os="${2-}"
      shift
      ;;
    --out-path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      out_path="${2-}"
      shift
      ;;
    --root)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      root="${2-}"
      shift
      ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ -z "${os-}" ]] && die "[ERROR] Missing required option: --os"
  [[ -z "${out_path-}" ]] && die "[ERROR] Missing required option: --out-path"
  case $os in
  ubuntu22.04 | ubuntu24.04 | rhel9 | rhel10) ;;
  *) die "[ERROR] Option --os takes ubuntu22.04, ubuntu24.04, rhel9 or rhel10" ;;
  esac

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

# Fills bundle/linux-packages/<os> from the repositories, on a machine that runs
# the OLDEST release of that os the installer supports.
#
# Each directory is one principal package and whatever this machine lacks for
# it, resolved by the package manager against what is installed here. Run on the
# oldest release, that is the closure an old node needs and a newer one skips:
# install-packages.sh hands dpkg and rpm only what is not already there at the
# version the bundle holds. The repository serves the newest packages of the
# release whatever point of it asks, so what lands here is the same content a
# node of the newest point has.
#
# The oldest release is the oldest minor for rhel (9.0, 10.0) and the GA image
# for ubuntu (22.04 with no point release, 24.04 the same), since the installer
# accepts a node of any point release from the first one on. An install
# transaction that only downloads is what resolves it: a library that is
# installed but too old for what is being pulled gets upgraded along with it,
# where a plain download of what is missing would leave the hole for a node to
# find. Weak dependencies (recommends) are left out, since dpkg and rpm on the
# node never ask for them.
#
# Even so, what a cloud image holds is not what a minimal install holds. The
# check that counts is a fresh machine of the oldest release with its
# repositories disabled installing the whole bundle, which is what
# setup-cluster.yml on such a machine is.
#
# When no machine of the oldest release has a repository, --root stands in for
# it. The package manager resolves against the database of whatever root it is
# given, so a copy of that database and of /etc/os-release from a fresh machine
# of the oldest release, placed under a directory here, is enough: this machine
# only lends its repositories, and what it has installed itself is never
# consulted. For rhel that is /var/lib/rpm (Red Hat retires the cloud images of
# the minors it no longer supports, and the KVM guest image of such a minor from
# the customer portal has no repository at all). For ubuntu it is
# /var/lib/dpkg/status, which the GA root tarball at
# cloud-images.ubuntu.com/releases/<codename>/release-<serial>/ carries, so no
# machine of the GA image is needed at all.
#
# The docker repository is added for containerd.io and docker, at the versions
# release.yml declares. The python packages are one set for every os of a
# python and are not taken here. The kubernetes packages and the nvidia toolkit
# are not taken either: the rpms carry no distribution tag and the debs are one
# build for every ubuntu, so they are copied from the directory of another os
DOCKER_RPM_REPO_URL="https://download.docker.com/linux/rhel/docker-ce.repo"
DOCKER_DEB_REPO_URL="https://download.docker.com/linux/ubuntu"

# The order install-packages.sh installs the directories in, which is what the
# dedupe below follows: a package that two principals resolve to is kept in the
# directory installed first
RPM_INSTALL_ORDER=(nfs-utils chrony container-selinux containerd systemd openssh fuse-overlayfs slirp conntrack iptables-nft nftables docker ethtool iproute socat libibverbs)
DEB_INSTALL_ORDER=(nfs-common systemd dbus pigz slirp containerd iptables ebtables conntrack nftables docker ethtool socat)

release_meta_path="$SCRIPT_DIR_PATH"/../release.yml

# rpm or deb, after the os
family=""

# Set by harvest_kernel for the one directory that is allowed to hold a kernel
take_kernel="false"

# What every dnf or apt call below is given: nothing, or the root to resolve
# against. The repositories stay those of this machine
pm_opts=()

main() {
  case $os in
  rhel*) family=rpm ;;
  ubuntu*) family=deb ;;
  esac

  require_this_os
  setup_pm_opts
  [[ -f $release_meta_path ]] || die "[ERROR] No such file or directory of which path is \"$release_meta_path\""

  rm -rf "$out_path"
  mkdir -p "$out_path"

  add_docker_repo

  "harvest_${family}_all"

  report

  return 0
}

harvest_rpm_all() {
  local containerd_version docker_version buildx_version compose_version
  containerd_version=$(declared_version containerd.io)
  docker_version=$(declared_version docker-ce)
  buildx_version=$(declared_version docker-buildx-plugin)
  compose_version=$(declared_version docker-compose-plugin)

  harvest nfs-utils nfs-utils
  harvest chrony chrony
  harvest container-selinux container-selinux
  harvest containerd "containerd.io-$containerd_version"
  harvest systemd systemd systemd-libs systemd-pam systemd-udev
  # openssh is not a dependency of anything here, and it has to move whenever
  # openssl does: the sshd of rhel 9.0 to 9.3 checks the openssl it was built
  # against at every connection and refuses the 3.5 the newest minor carries
  # with "OpenSSL version mismatch", which no rpm dependency says. A node whose
  # openssl was raised without its openssh is a node nobody can reach again
  harvest openssh openssh openssh-server openssh-clients
  harvest fuse-overlayfs fuse-overlayfs
  harvest slirp slirp4netns
  harvest conntrack conntrack-tools
  harvest iptables-nft iptables-nft
  harvest nftables nftables
  # containerd.io is named again so that docker-ce resolves to the declared one
  # rather than to the newest the repository has
  harvest docker "containerd.io-$containerd_version" "docker-ce-$docker_version" "docker-ce-cli-$docker_version" \
    "docker-ce-rootless-extras-$docker_version" "docker-buildx-plugin-$buildx_version" "docker-compose-plugin-$compose_version"
  harvest ethtool ethtool
  harvest iproute iproute iproute-tc
  harvest socat socat
  # Installed by the node script only when absent, so resolved on its own
  harvest libibverbs libibverbs

  dedupe "${RPM_INSTALL_ORDER[@]}"

  # The kernel of rhel 10, resolved on its own and outside the dedupe. It is
  # not a dependency of anything above and must not be: it is installed by a
  # different script, beside the running kernel rather than over it, and only
  # on a node that cannot load the modules.
  #
  # Pinned to the newest kernel-core the repository holds rather than asked for
  # by name. The four packages of a kernel are one build, and a mirror in the
  # middle of taking in a new one serves the modules of that build before its
  # kernel-core: asked by name, dnf picks the newest modules and finds no kernel
  # that provides what they want, and the whole directory fails. Measured on
  # the day 211.63.1 arrived
  [[ $os = "rhel10" ]] && harvest_kernel kernel "kernel-core-$(newest_kernel_version)"     "kernel-modules-$(newest_kernel_version)" "kernel-modules-core-$(newest_kernel_version)"     "kernel-modules-extra-$(newest_kernel_version)"

  # setup-venv.sh installs python3.12 before install-packages.sh has laid down
  # anything, so it is resolved after the dedupe and keeps its whole closure -
  # libtirpc among it, which nfs-utils carries too. The python of the newest
  # minor brings its openssl, so openssh comes with it for the reason above: the
  # control node is the first node whose openssl moves, and it moves before any
  # playbook has connected to anything. rhel 10 boots with 3.12 and needs no
  # such directory
  # expat as well: the pyexpat of 3.12 calls a symbol of expat 2.4 and later, and
  # expat versions none of its symbols, so rpm can not say that the 2.2 of 9.0 is
  # too old. ensurepip is the first thing to notice, with an undefined symbol
  [[ $os = "rhel9" ]] && harvest python3.12 python3.12 expat openssh openssh-server openssh-clients

  return 0
}

harvest_deb_all() {
  local containerd_version docker_version buildx_version compose_version
  containerd_version=$(declared_version containerd.io)
  docker_version=$(declared_version docker-ce)
  buildx_version=$(declared_version docker-buildx-plugin)
  compose_version=$(declared_version docker-compose-plugin)

  harvest nfs-common nfs-common
  # The image ships every one of these, and they are built from one source at
  # one version, so systemd can not move without them. Named so that a split
  # like the systemd-resolved of 24.04 is carried whatever the image calls it
  harvest systemd systemd systemd-sysv systemd-timesyncd udev libnss-systemd libpam-systemd
  harvest dbus dbus
  harvest pigz pigz
  harvest slirp slirp4netns
  harvest containerd "containerd.io=$containerd_version"
  harvest iptables iptables
  harvest ebtables ebtables
  harvest conntrack conntrack
  harvest nftables nftables
  # containerd.io is named again so that docker-ce resolves to the declared one
  # rather than to the newest the repository has
  harvest docker "containerd.io=$containerd_version" "docker-ce=$docker_version" "docker-ce-cli=$docker_version" \
    "docker-ce-rootless-extras=$docker_version" "docker-buildx-plugin=$buildx_version" "docker-compose-plugin=$compose_version"
  harvest ethtool ethtool
  harvest socat socat

  dedupe "${DEB_INSTALL_ORDER[@]}"

  # setup-venv.sh lays these down before install-packages.sh has touched the
  # node, in this order, so they are resolved after the dedupe above and deduped
  # among themselves only. The GA image carries the python of the os, and the
  # venv package of the newest point wants that python at its own version, so
  # the whole interpreter moves with it
  if [[ $os = "ubuntu22.04" ]]; then
    harvest python3.10 python3.10
    harvest python3 python3
    harvest python3-distutils python3-distutils
    harvest python3.10-venv python3.10-venv
    dedupe python3.10 python3 python3-distutils python3.10-venv
  else
    harvest python3.12 python3.12
    harvest python3.12-venv python3.12-venv
    dedupe python3.12 python3.12-venv
  fi

  return 0
}

# The os a /etc/os-release describes, in the words --os takes: the id and the
# major for rhel, the id and the whole version for ubuntu
os_of() {
  local os_release_path=$1

  local id version
  id=$(grep -oP '^ID="?\K\w+(?="?$)' "$os_release_path")
  version=$(grep -oP '^VERSION_ID="?\K[0-9.]+(?="?$)' "$os_release_path")
  [[ $id = "rhel" ]] && version=${version%%.*}

  echo "$id$version"

  return 0
}

require_this_os() {
  [[ $(os_of /etc/os-release) = "$os" ]] ||
    die "[ERROR] This machine runs $(grep -oP '^PRETTY_NAME="\K[^"]+' /etc/os-release) and the packages of $os have to be resolved on a machine that runs it, or with the repositories of one"

  [[ -z $root ]] && return 0

  local db_path
  case $family in
  rpm) db_path=var/lib/rpm ;;
  deb) db_path=var/lib/dpkg/status ;;
  esac
  [[ -f $root/etc/os-release && -e $root/$db_path ]] ||
    die "[ERROR] Directory[\"$root\"] has to hold the etc/os-release and $db_path of the machine to resolve for"
  [[ $(os_of "$root"/etc/os-release) = "$os" ]] ||
    die "[ERROR] Directory[\"$root\"] holds the database of $(os_of "$root"/etc/os-release), not of $os"

  msg "[INFO] Resolving for $(grep -oP '^PRETTY_NAME="\K[^"]+' "$root"/etc/os-release) from its package database, with the repositories of this machine"

  return 0
}

setup_pm_opts() {
  [[ -z $root ]] && return 0

  case $family in
  rpm)
    local major=${os#rhel}
    pm_opts=(--installroot "$root" --releasever "$major" --setopt=reposdir=/etc/yum.repos.d)
    ;;
  deb)
    pm_opts=(-o "Dir::State::status=$root/var/lib/dpkg/status")
    ;;
  esac

  return 0
}

add_docker_repo() {
  case $family in
  rpm)
    dnf -y -q config-manager --add-repo "$DOCKER_RPM_REPO_URL"
    ;;
  deb)
    local codename
    codename=$(grep -oP '^VERSION_CODENAME=\K\w+' /etc/os-release)
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "$DOCKER_DEB_REPO_URL/gpg" -o /etc/apt/keyrings/docker.asc
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] $DOCKER_DEB_REPO_URL $codename stable" > /etc/apt/sources.list.d/docker.list
    apt-get -q update >/dev/null
    ;;
  esac

  return 0
}

# The version release.yml declares, in the form the package manager of this os
# takes: the upstream version alone for dnf, which matches on a prefix, and the
# whole version of the repository for apt, which matches on nothing less. The
# deb of 29.8.1 is 5:29.8.1-1~ubuntu.22.04~jammy, and the epoch and the
# packaging release around it are looked up rather than guessed
declared_version() {
  local name=$1

  local version
  version=$(grep -oP "^  $name: \"\K[^\"]+" < "$release_meta_path")
  [[ -z $version ]] && die "[ERROR] File[\"$release_meta_path\"] declares no version of package[\"$name\"]"

  if [[ $family = "deb" ]]; then
    local deb_version
    deb_version=$(apt-cache madison "$name" | awk -v v="$version" '$3 ~ "^([0-9]+:)?" v "-" { print $3; exit }')
    [[ -z $deb_version ]] && die "[ERROR] The repositories of this machine hold no package[\"$name\"] of version[\"$version\"], which release.yml declares"
    version=$deb_version
  fi

  echo "$version"

  return 0
}

harvest() {
  "harvest_$family" "$@"
}

harvest_kernel() {
  take_kernel="true"
  harvest_rpm "$@"
  take_kernel="false"

  return 0
}

# The newest kernel-core the repository serves, as version-release, in the
# order rpm keeps rather than the one sort would guess at
newest_kernel_version() {
  local version
  version=$(dnf "${pm_opts[@]}" -q repoquery --latest-limit 1 --queryformat '%{version}-%{release}' kernel-core 2>/dev/null | tail -1)
  [[ -z $version ]] && die "[ERROR] The repository serves no kernel-core, so the kernel of rhel 10 can not be taken"

  echo "$version"

  return 0
}

# A closure that downgrades anything is refused and resolved again without the
# package it wanted to downgrade to. The solver is allowed to move a dependency
# down when that is the smallest change that satisfies a requirement, and it did:
# the newest systemd of rhel 10 wants an openssl symbol that the 10.0 GA build of
# openssl-libs claims to provide, so on a 10.0 machine dnf moved openssl-libs down
# to that build rather than up to the 3.5 the newer minors carry. On a 10.0 node
# that systemd could not start and pid 1 died; on a 10.2 node rpm refused the
# downgrade outright. Neither is a closure. Excluding the build it moved down to
# leaves the solver only the way up, which is the state a node of the newest
# minor is in, and what every node is being brought to
#
# The kernel is never taken along with anything else. iptables-nft of some rhel
# 10 builds asks for kernel-modules-extra, which pulls a whole new kernel after
# it, and a dependency closure is not where a node's kernel gets decided. It is
# taken once, on purpose, into a directory of its own for rhel 10, through
# harvest_kernel: the modules that iptables-nft wants live in kernel-modules-extra
# there, which is built for one kernel, so the bundle carries the newest kernel
# of the newest minor with them and kernel/setup-kernel.sh moves a node that
# lacks the modules onto it. rhel 9 keeps those modules in kernel-modules-core
# and needs none of this
harvest_rpm() {
  local dir=$1
  shift

  local excludes=()
  [[ $take_kernel = "true" ]] || excludes=(--exclude "kernel*")
  local attempt
  for attempt in 1 2 3 4 5; do
    local plan
    plan=$(dnf "${pm_opts[@]}" --assumeno --setopt=install_weak_deps=False "${excludes[@]}" install "$@" 2>&1 || true)
    grep -q '^Dependencies resolved' <<< "$plan" ||
      die "[ERROR] Fail to resolve the packages of directory[\"$dir\"]:\n$plan"

    local downgrades
    downgrades=$(sed -n '/^Downgrading:/,/^$/p' <<< "$plan" | awk 'NF >= 4 && $1 != "Downgrading:" {print $1 "-" $3}')
    [[ -z $downgrades ]] && break

    local spec
    for spec in $downgrades; do
      msg "[WARN] Directory[\"$dir\"] would downgrade to package[\"$spec\"]. resolving again without it"
      excludes+=(--exclude "$spec")
    done
    [[ $attempt = 5 ]] && die "[ERROR] Directory[\"$dir\"] still downgrades after excluding what it downgraded to"
  done

  # keepcache, or dnf takes what it downloaded here back on its next transaction:
  # a package fetched for a run that installed nothing is a temporary file to it,
  # wherever it was told to put it, and a "dnf install" of anything afterwards
  # leaves the directory empty
  mkdir -p "$out_path/$dir"
  dnf "${pm_opts[@]}" -y -q install --downloadonly --downloaddir "$out_path/$dir" "${excludes[@]}" \
    --setopt=install_weak_deps=False --setopt=keepcache=True "$@" >/dev/null ||
    die "[ERROR] Fail to download the packages of directory[\"$dir\"]"

  return 0
}

# apt moves nothing down unless told to by name, and nothing here pulls a
# kernel, so neither guard of the rpm side is needed. What it may do instead is
# remove: a principal that conflicts with something the image holds is resolved
# by taking that something out, which dpkg on the node is never asked to do, so
# a plan that removes anything is refused rather than shipped short
harvest_deb() {
  local dir=$1
  shift

  local plan
  plan=$(apt-get -s install --no-install-recommends "${pm_opts[@]}" "$@" 2>&1 || true)
  local summary
  summary=$(grep -oP '^\d+ upgraded, \d+ newly installed, .*' <<< "$plan")
  [[ -z $summary ]] && die "[ERROR] Fail to resolve the packages of directory[\"$dir\"]:\n$plan"
  grep -qP '(^| )[1-9]\d* (downgraded|to remove)' <<< "$summary" &&
    die "[ERROR] Directory[\"$dir\"] would downgrade or remove something, which is not a closure:\n$plan"

  # A directory of its own for the archives, or they land in /var/cache/apt
  # beside everything else this machine ever fetched. apt leaves its lock and
  # its partial directory behind in there, and neither is a package. Fetched as
  # root rather than as _apt, which can not write under a directory of root's
  # and says so for every file before falling back to root anyway
  mkdir -p "$out_path/$dir"
  apt-get -y -q install --download-only --no-install-recommends "${pm_opts[@]}" \
    -o "Dir::Cache::archives=$out_path/$dir" -o APT::Sandbox::User=root "$@" >/dev/null ||
    die "[ERROR] Fail to download the packages of directory[\"$dir\"]"
  rm -rf "$out_path/$dir/lock" "$out_path/$dir/partial"

  return 0
}

package_name_of() {
  local file=$1

  case $family in
  rpm) rpm -qp --queryformat '%{NAME}' "$file" 2>/dev/null ;;
  deb) dpkg-deb -f "$file" Package ;;
  esac
}

dedupe() {
  declare -A seen
  local dir file name
  for dir in "$@"; do
    for file in "$out_path/$dir"/*."$family"; do
      [[ -e $file ]] || continue
      name=$(package_name_of "$file")
      if [[ -n ${seen[$name]-} ]]; then
        rm -f "$file"
      else
        seen[$name]=$dir
      fi
    done
  done

  return 0
}

report() {
  local dir count
  for dir in "$out_path"/*/; do
    dir=${dir%/}
    count=$(find "$dir" -name "*.$family" | wc -l)
    if [[ $count = 0 ]]; then
      # Nothing the oldest release lacks for it, which the node script reads as
      # a directory holding no package
      rmdir "$dir"
      msg "[INFO] $(basename "$dir"): nothing the oldest release lacks"
      continue
    fi
    msg "[INFO] $(basename "$dir") ($count): $(find "$dir" -name "*.$family" -printf '%f ' | sed -e 's/\.\(x86_64\|noarch\)\.rpm//g' -e 's/_\(amd64\|all\)\.deb//g' -e 's/%3a/:/g')"
  done

  local copy_from
  case $family in
  rpm) copy_from=rhel8 ;;
  deb) copy_from="other ubuntu" ;;
  esac
  msg "[INFO] $(du -sh "$out_path" | cut -f1) under \"$out_path\". Copy k8s and nvidia-container-toolkit from the $copy_from directory next to these"

  return 0
}

main
