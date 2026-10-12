#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] --os os --out-path path [--root path]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--os            ubuntu22.04, ubuntu24.04, rhel8, rhel9 or rhel10, which must be what this machine runs
--out-path      Directory to fill, laid out as bundle/linux-packages/<os> is
--root          Resolve against the package database under this directory instead of this
                machine's. Given more than once, every root is resolved and the directories hold
                the union, which is how a closure covers both the oldest image and a minimal install
EOF
  exit
}

parse_params() {
  os=""
  out_path=""
  roots=()

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
      roots+=("${2-}")
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
  ubuntu22.04 | ubuntu24.04 | rhel8 | rhel9 | rhel10) ;;
  *) die "[ERROR] Option --os takes ubuntu22.04, ubuntu24.04, rhel8, rhel9 or rhel10" ;;
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
# The oldest release is the oldest minor for rhel (8.0, 9.0, 10.0) and the GA
# image for ubuntu (22.04 with no point release, 24.04 the same), since the
# installer accepts a node of any point release from the first one on. An install
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
# Which roots, then. A closure is "what this baseline lacks", and no one image
# is the right baseline. An image that holds more than a minimal install has
# packages pinned to the versions of what the closure raises - the openssl
# command to openssl-libs, sssd-common to sssd-nfs-idmap - and rpm refuses to
# raise one without the other, so the closure has to carry those too, and only
# a baseline that has them installed asks for them. A smaller image lacks
# packages the bigger one has - a cloud image has no libtirpc, the guest image
# of the customer portal does - and only a baseline without them asks for them.
# So --root is given several times and the directories hold the union: the
# first root decides the version of every name it produces, since what it chose
# was chosen against the most constraints, and each later root only adds names
# none before it produced. The order is the image with the most installed
# first, the other images of the supported range after it, and last the oldest
# image stripped to what a minimal install holds, which is made like so:
#
#   dnf -y --installroot=/root/min --releasever=<major> --setopt=reposdir=/etc/yum.repos.d \
#     --setopt=install_weak_deps=False --exclude 'kernel*' install @core
#   rpm --root /root/min -qa --queryformat '%{NAME}\n' | sort -u > /root/core.names
#   # /root/old holds var/lib/rpm and etc/os-release copied from the oldest image
#   for p in $(rpm --root /root/old -qa --queryformat '%{NAME}\n' | sort -u | grep -vxF -f /root/core.names); do
#     rpm --root /root/old -e --nodeps --justdb --allmatches "$p"
#   done
#
# --justdb takes the entries out of the database and touches nothing else. The
# machine this runs on is one of the images, named as "--root /". A single
# root was tried twice and each time a fresh image of another kind refused the
# bundle at the first playbook, which is what the fresh image is for.
#
# The docker repository is added for containerd.io and docker, at the versions
# release.yml declares. The python packages are one set for every os of a
# python and are not taken here. The kubernetes packages and the nvidia toolkit
# are not taken either: the rpms carry no distribution tag and the debs are one
# build for every ubuntu, so they are copied from the directory of another os
DOCKER_RPM_REPO_URL="https://download.docker.com/linux/rhel/docker-ce.repo"
DOCKER_DEB_REPO_URL="https://download.docker.com/linux/ubuntu"

# The directories are resolved in the order the node installs them, each one
# against the state the ones before it leave behind: the principals of a
# directory are added to those of every directory before it, the package
# manager plans the whole of it as one transaction against the baseline, and
# what that transaction holds that no earlier directory holds is what the new
# directory gets. A directory planned alone against the bare baseline can not
# be trusted beside the others: containerd on rhel 8.0 took the
# policycoreutils-python-utils of 8.0, to match the python3-policycoreutils 8.0
# had, while nfs-utils, planned the same way, had already raised that one to
# 8.10's, and rpm on the node refused the pair.
#
# A group is a run of directories a node installs in sequence, and a new group
# starts from the bare baseline again. The directories install-packages.sh
# installs are one group. The python directory setup-venv.sh lays down is a
# group of its own, since on the control node it goes down before any of them
# and on every other node not at all; the kernel of rhel 10 the same
group_specs=()
group_dirs=()
group_n=0
scratch=""

# Where the harvest functions write: one directory per baseline while the
# baselines are being resolved, and the union of them is what --out-path ends
# up holding. Each directory remembers the group it was harvested in, which is
# the scope a name is counted once within when the baselines are joined
harvest_out=""
declare -A dir_group
# ... and the place of each directory in the install order, which is where a
# name is placed when the baselines disagree about it
declare -A dir_pos
harvest_seq=0

# The baseline being resolved, one of roots, set by main for each in turn
root=""

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

  [[ -f $release_meta_path ]] || die "[ERROR] No such file or directory of which path is \"$release_meta_path\""

  rm -rf "$out_path" "$out_path.baselines"
  mkdir -p "$out_path"

  add_docker_repo

  # "" is this machine, and so is /
  [[ ${#roots[@]} = 0 ]] && roots=("")
  local i=0
  for root in "${roots[@]}"; do
    [[ $root = "/" ]] && root=""
    pm_opts=()
    require_this_os
    setup_pm_opts

    harvest_out="$out_path.baselines/$i"
    mkdir -p "$harvest_out"
    group_n=0
    harvest_seq=0
    "harvest_${family}_all"
    i=$((i + 1))
  done

  union_baselines
  [[ $family = "rpm" ]] && verify_union_rpm

  report

  return 0
}

harvest_rpm_all() {
  local containerd_version docker_version buildx_version compose_version
  containerd_version=$(declared_version containerd.io)
  docker_version=$(declared_version docker-ce)
  buildx_version=$(declared_version docker-buildx-plugin)
  compose_version=$(declared_version docker-compose-plugin)

  new_group
  # The images of the rhel 8 minors hold different sets, in both directions,
  # and the baseline is one of them. policycoreutils-python-utils is on the
  # images of 8.6 and later and not on 8.0, and it is built in lockstep with
  # the python3-policycoreutils nfs-utils raises, so it is raised here along
  # with it or rpm on those nodes refuses the directory
  if [[ $os = "rhel8" ]]; then
    harvest nfs-utils nfs-utils policycoreutils-python-utils
  else
    harvest nfs-utils nfs-utils
  fi
  harvest chrony chrony
  harvest container-selinux container-selinux
  # libseccomp as well on rhel 8: the runc of containerd.io calls
  # seccomp_api_get, which libseccomp has from 2.4 on, and the 2.3 of 8.0
  # satisfies the unversioned requirement and leaves runc dying with "undefined
  # symbol" under every container
  if [[ $os = "rhel8" ]]; then
    harvest containerd "containerd.io-$containerd_version" libseccomp
  else
    harvest containerd "containerd.io-$containerd_version"
  fi
  harvest systemd systemd systemd-libs systemd-pam systemd-udev
  # openssh is not a dependency of anything here, and it has to move whenever
  # openssl does: the sshd of rhel 9.0 to 9.3 checks the openssl it was built
  # against at every connection and refuses the 3.5 the newest minor carries
  # with "OpenSSL version mismatch", which no rpm dependency says. A node whose
  # openssl was raised without its openssh is a node nobody can reach again.
  # Nothing moves the openssl of rhel 8, so its sshd is left alone
  [[ $os != "rhel8" ]] && harvest openssh openssh openssh-server openssh-clients
  harvest fuse-overlayfs fuse-overlayfs
  harvest slirp slirp4netns
  harvest conntrack conntrack-tools
  # Installed by the node script only when absent, and before iptables, whose
  # libpcap on rhel 8 wants it: resolved here so that it lands in the directory
  # the guard is on rather than in the one iptables is in
  harvest libibverbs libibverbs
  # The iptables kubelet and docker ask for is iptables-nft from rhel 9 on, and
  # on rhel 8 it is iptables itself, nft based already, with the ebtables shim
  # the kubelet of that era still wants beside it
  # libpcap is named on rhel 8 for the same reason as policycoreutils-python-utils
  # above, the other way round: the image of 8.0 has it and the images of 8.4
  # and later do not, and iptables wants its library
  if [[ $os = "rhel8" ]]; then
    harvest iptables iptables iptables-ebtables libpcap
  else
    harvest iptables iptables-nft
  fi
  harvest nftables nftables
  # containerd.io is named again so that docker-ce resolves to the declared one
  # rather than to the newest the repository has
  harvest docker "containerd.io-$containerd_version" "docker-ce-$docker_version" "docker-ce-cli-$docker_version" \
    "docker-ce-rootless-extras-$docker_version" "docker-buildx-plugin-$buildx_version" "docker-compose-plugin-$compose_version"
  harvest ethtool ethtool
  harvest iproute iproute iproute-tc
  harvest socat socat
  # The headers of the gnutls and selinux chains, which the rhel 8 bundle has
  # always carried and a site may build against. Last, so that each one meets
  # the library it wants at the exact version the directories before it laid
  # down
  # The pkgconf set is named because the headers want pkg-config, the image of
  # 8.0 has all four, and the images of 8.1 to 8.3 have none
  [[ $os = "rhel8" ]] && harvest devel gmp-devel gnutls-devel libidn2-devel libtasn1-devel nettle-devel p11-kit-devel \
    pcre2-devel libselinux-devel libsepol-devel libverto-devel pkgconf-pkg-config pkgconf pkgconf-m4 libpkgconf

  # The kernel of rhel 10, resolved on its own as a group of its own. It is
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
  if [[ $os = "rhel10" ]]; then
    new_group
    harvest_kernel kernel "kernel-core-$(newest_kernel_version)" "kernel-modules-$(newest_kernel_version)" \
      "kernel-modules-core-$(newest_kernel_version)" "kernel-modules-extra-$(newest_kernel_version)"
  fi

  # setup-venv.sh installs python3.12 before install-packages.sh has laid down
  # anything, so it is a group of its own and keeps its whole closure -
  # libtirpc among it, which nfs-utils carries too. The python of the newest
  # minor brings its openssl, so openssh comes with it for the reason above: the
  # control node is the first node whose openssl moves, and it moves before any
  # playbook has connected to anything. rhel 10 boots with 3.12 and needs no
  # such directory
  # expat as well: the pyexpat of 3.12 calls a symbol of expat 2.4 and later, and
  # expat versions none of its symbols, so rpm can not say that the 2.2 of 9.0 is
  # too old. ensurepip is the first thing to notice, with an undefined symbol
  if [[ $os = "rhel9" ]]; then
    new_group
    harvest python3.12 python3.12 expat openssh openssh-server openssh-clients
  fi
  # rhel 8 boots with python 3.6 and carries 3.12 as a package of its own too,
  # and nothing of 3.12 reaches its openssl or its expat
  if [[ $os = "rhel8" ]]; then
    new_group
    harvest python3.12 python3.12
  fi

  return 0
}

harvest_deb_all() {
  local containerd_version docker_version buildx_version compose_version
  containerd_version=$(declared_version containerd.io)
  docker_version=$(declared_version docker-ce)
  buildx_version=$(declared_version docker-buildx-plugin)
  compose_version=$(declared_version docker-compose-plugin)

  new_group
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

  # setup-venv.sh lays these down before install-packages.sh has touched the
  # node, in this order, so they are a group of their own. The GA image carries
  # the python of the os, and the venv package of the newest point wants that
  # python at its own version, so the whole interpreter moves with it
  new_group
  if [[ $os = "ubuntu22.04" ]]; then
    harvest python3.10 python3.10
    harvest python3 python3
    harvest python3-distutils python3-distutils
    harvest python3.10-venv python3.10-venv
  else
    harvest python3.12 python3.12
    harvest python3.12-venv python3.12-venv
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
    # The rpm database of rhel 8 is Berkeley DB, and a copy of it brings the
    # environment files of whoever had it open. They belong to that machine
    rm -f "$root"/var/lib/rpm/__db.*
    # The rpm of rhel 10 keeps its database under /usr/lib/sysimage/rpm and
    # looks nowhere else, so a root that holds it under var/lib/rpm alone reads
    # as a machine with nothing installed, and every directory comes out as a
    # fresh install of the whole system. Both paths lead to the one copy
    if [[ ! -e $root/usr/lib/sysimage/rpm ]]; then
      mkdir -p "$root"/usr/lib/sysimage
      ln -s ../../../var/lib/rpm "$root"/usr/lib/sysimage/rpm
    fi
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

new_group() {
  group_n=$((group_n + 1))
  group_specs=()
  group_dirs=()
  scratch="$harvest_out/.scratch-$group_n"
  mkdir -p "$scratch"

  return 0
}

# Adds the principals of a directory to the group, has the whole group planned
# and downloaded into the scratch of the group, and gives the directory what
# arrived that no earlier directory of the group holds. A file of the scratch
# that an earlier directory holds is one that earlier transaction brought and
# this one still wants; a file none holds is new to this transaction, whether a
# package or a newer build of one an earlier directory carries, and rpm and dpkg
# move a node up to it in the order the directories are installed
#
# A principal is carried whether or not the baseline has it. The images of the
# minors differ in what they hold, in both directions, and the baseline is one
# image of one minor: pkgconf is on the 8.0 image and not on 8.1 to 8.3, and a
# devel directory planned against 8.0 would hold headers that want pkg-config
# and no pkg-config for the node that lacks it. So what a directory is named
# for is fetched at the newest build when the plan brought nothing of it, and
# a node that has it already skips the file
harvest() {
  local dir=$1
  shift

  group_specs+=("$@")
  "download_$family" "$dir"
  "fetch_named_$family" "$@"

  mkdir -p "$harvest_out/$dir"
  local file name earlier
  for file in "$scratch"/*."$family"; do
    [[ -e $file ]] || continue
    name=$(basename "$file")
    for earlier in "${group_dirs[@]}"; do
      [[ -e "$harvest_out/$earlier/$name" ]] && continue 2
    done
    cp -p "$file" "$harvest_out/$dir/$name"
  done
  group_dirs+=("$dir")
  dir_group[$dir]=$group_n
  dir_pos[$dir]=$harvest_seq
  harvest_seq=$((harvest_seq + 1))

  return 0
}

harvest_kernel() {
  take_kernel="true"
  harvest "$@"
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
#
# And what dnf brings along is asked for again at the newest build the
# repository has. The solver takes the newest build of what it is named, but
# for a dependency it takes whatever satisfies the requirement with the least
# change, and on an old baseline that is the build that fits the old library it
# finds installed: nfs-utils on 8.0 brought a keyutils that wants the
# keyutils-libs 8.0 has, exactly, and a node of 8.9 that has a newer one can
# not take it. Every package new to the baseline that the transaction holds
# below the newest build is therefore named at that build and the transaction
# planned again, until none is, which is the state a node of the newest minor
# is in. What release.yml pins, and the kernel, are left at the build they
# were asked for
download_rpm() {
  local dir=$1

  local excludes=()
  [[ $take_kernel = "true" ]] || excludes=(--exclude "kernel*")
  local attempt
  for attempt in 1 2 3 4 5 6 7 8; do
    local plan
    plan=$(dnf "${pm_opts[@]}" --assumeno --setopt=install_weak_deps=False "${excludes[@]}" install "${group_specs[@]}" 2>&1 || true)
    grep -q '^Dependencies resolved' <<< "$plan" ||
      die "[ERROR] Fail to resolve the packages of directory[\"$dir\"]:\n$plan"

    # A downgrade to the newest build the repository has is a different thing:
    # the image holds a build the repository no longer serves - the gmp of the
    # 8.6 image is 6.1.2-11.el8_6.1, a z-stream build that rpm reads as newer
    # than the 6.1.2-11.el8 every later minor has - and the only way to the
    # state of the newest minor is down to it, which rpm on the node does with
    # --oldpackage. Only a downgrade past a build the repository still holds is
    # the solver taking a wrong turn, and that one is refused
    local downgrades spec name version newest wrong=""
    downgrades=$(sed -n '/^Downgrading:/,/^$/p' <<< "$plan" | awk 'NF >= 4 && $1 != "Downgrading:" {print $1 " " $3}')
    while read -r name version; do
      [[ -z $name ]] && continue
      spec="$name-$version"
      newest=$(dnf "${pm_opts[@]}" -q repoquery --latest-limit 1 --arch x86_64,noarch --queryformat '%{version}-%{release}' "$name" 2>/dev/null | tail -1)
      if [[ ${version#*:} = "$newest" ]]; then
        msg "[INFO] Directory[\"$dir\"] moves package[\"$name\"] down to the newest build the repository has, $newest, which the baseline is past"
        continue
      fi
      msg "[WARN] Directory[\"$dir\"] would downgrade to package[\"$spec\"]. resolving again without it"
      excludes+=(--exclude "$spec")
      wrong=yes
    done <<< "$downgrades"
    [[ -n $wrong ]] && continue

    # The scratch holds this transaction and nothing else, so what a round
    # before this one took and this one no longer wants is not left behind to
    # be copied as if it were. keepcache, or dnf takes what it downloaded here
    # back on its next transaction: a package fetched for a run that installed
    # nothing is a temporary file to it, wherever it was told to put it, and a
    # "dnf install" of anything afterwards leaves the directory empty
    rm -f "$scratch"/*.rpm
    dnf "${pm_opts[@]}" -y -q install --downloadonly --downloaddir "$scratch" "${excludes[@]}" \
      --setopt=install_weak_deps=False --setopt=keepcache=True "${group_specs[@]}" >/dev/null ||
      die "[ERROR] Fail to download the packages of directory[\"$dir\"]"

    local stale
    stale=$(stale_rpms)
    [[ -z $stale ]] && return 0

    local spec
    for spec in $stale; do
      msg "[INFO] Directory[\"$dir\"]: package[\"$spec\"] is newer than what the solver took. resolving again with it"
      group_specs+=("$spec")
    done
  done

  die "[ERROR] Directory[\"$dir\"] is still behind the repository after $attempt attempts"
}

# The rpms of the scratch that the baseline does not have and the repository
# holds a newer build of, each as the spec of that newer build, less what is
# pinned.
#
# Only what is new to the baseline. For a package the baseline has, the solver
# moves to the build a requirement asks for and no further, and asking for the
# newest of that one asks for the newest of everything it is built in lockstep
# with: on rhel 10.0 the kernel directory, whose kernel wants a dracut and a
# systemd, came out holding bash and coreutils and 180 others. The bias that
# matters is the other one, a new package taken at the build that fits the old
# library found installed, and that is what is corrected here
stale_rpms() {
  local names=()
  declare -A have
  local file nvra
  for file in "$scratch"/*.rpm; do
    [[ -e $file ]] || continue
    nvra=$(rpm -qp --queryformat '%{NAME} %{VERSION}-%{RELEASE} %{ARCH}' "$file" 2>/dev/null)
    [[ -z $nvra ]] && continue
    baseline_has "${nvra%% *}" && continue
    names+=("${nvra%% *}")
    have["${nvra%% *}"]="${nvra#* }"
  done
  [[ ${#names[@]} = 0 ]] && return 0

  local newest
  newest=$(dnf "${pm_opts[@]}" -q repoquery --latest-limit 1 --arch x86_64,noarch \
    --queryformat '%{name} %{version}-%{release}' "${names[@]}" 2>/dev/null)

  local name vr arch
  while read -r name vr; do
    [[ -z $name || -z ${have[$name]-} ]] && continue
    is_pinned "$name" && continue
    arch=${have[$name]#* }
    [[ ${have[$name]% *} = "$vr" ]] && continue
    echo "$name-$vr.$arch"
  done <<< "$newest"

  return 0
}

# Whether the baseline, this machine or the root given, has the package
baseline_has() {
  local name=$1

  if [[ -n $root ]]; then
    rpm --root "$root" -q "$name" &>/dev/null
  else
    rpm -q "$name" &>/dev/null
  fi
}

# Whether a package was asked for at a build of its own: by release.yml, by the
# kernel of rhel 10, or by a round of this
is_pinned() {
  local name=$1

  [[ $name = kernel* ]] && return 0
  local spec
  for spec in "${group_specs[@]}"; do
    [[ $spec = "$name-"[0-9]* ]] && return 0
  done

  return 1
}

# Fetches the principals the plan brought nothing of, see harvest
fetch_named_rpm() {
  local in_scratch
  in_scratch=$(rpm -qp --queryformat '%{NAME}\n' "$scratch"/*.rpm 2>/dev/null || true)

  local spec name
  for spec in "$@"; do
    name=$(dnf "${pm_opts[@]}" -q repoquery --latest-limit 1 --arch x86_64,noarch --queryformat '%{name}' "$spec" 2>/dev/null | head -1)
    [[ -z $name ]] && die "[ERROR] The repositories of this machine hold no package[\"$spec\"]"
    grep -qx "$name" <<< "$in_scratch" && continue
    dnf "${pm_opts[@]}" -q download --destdir "$scratch" --arch x86_64,noarch "$spec" >/dev/null ||
      die "[ERROR] Fail to download package[\"$spec\"]"
  done

  return 0
}

fetch_named_deb() {
  local in_scratch
  in_scratch=$(for f in "$scratch"/*.deb; do [[ -e $f ]] && dpkg-deb -f "$f" Package; done)

  local spec name
  for spec in "$@"; do
    name=${spec%%=*}
    grep -qx "$name" <<< "$in_scratch" && continue
    (cd "$scratch" && apt-get -q download -o APT::Sandbox::User=root "$spec" >/dev/null) ||
      die "[ERROR] Fail to download package[\"$spec\"]"
  done

  return 0
}

# apt moves nothing down unless told to by name, and nothing here pulls a
# kernel, so neither guard of the rpm side is needed. What it may do instead is
# remove: a principal that conflicts with something the image holds is resolved
# by taking that something out, which dpkg on the node is never asked to do, so
# a plan that removes anything is refused rather than shipped short
#
# Nor does apt need asking twice for the newest build: it installs the
# candidate of every package it touches, dependencies included
download_deb() {
  local dir=$1

  local plan
  plan=$(apt-get -s install --no-install-recommends "${pm_opts[@]}" "${group_specs[@]}" 2>&1 || true)
  local summary
  summary=$(grep -oP '^\d+ upgraded, \d+ newly installed, .*' <<< "$plan")
  [[ -z $summary ]] && die "[ERROR] Fail to resolve the packages of directory[\"$dir\"]:\n$plan"
  grep -qP '(^| )[1-9]\d* (downgraded|to remove)' <<< "$summary" &&
    die "[ERROR] Directory[\"$dir\"] would downgrade or remove something, which is not a closure:\n$plan"

  # A scratch of its own for the archives, or they land in /var/cache/apt
  # beside everything else this machine ever fetched. apt leaves its lock and
  # its partial directory behind in there, and neither is a package. Fetched as
  # root rather than as _apt, which can not write under a directory of root's
  # and says so for every file before falling back to root anyway
  rm -f "$scratch"/*.deb
  apt-get -y -q install --download-only --no-install-recommends "${pm_opts[@]}" \
    -o "Dir::Cache::archives=$scratch" -o APT::Sandbox::User=root "${group_specs[@]}" >/dev/null ||
    die "[ERROR] Fail to download the packages of directory[\"$dir\"]"
  rm -rf "$scratch/lock" "$scratch/partial"

  return 0
}

# One directory of --out-path per directory any baseline produced, holding
# one file per package name: the highest build any baseline took, in the
# earliest directory any baseline put it in. A name is counted once within the
# group the directory belongs to - the directories install-packages.sh
# installs are one group, the python directories and the kernel are groups of
# their own and hold their whole closure.
#
# The highest build, because every baseline's requirement is a floor and the
# highest meets all of them, and because two builds of one name in one
# directory is a transaction rpm dies on: against 8.3 nfs-utils raised
# libsemanage to 2.9-10 and devel on to 2.9-12, against 8.0 nfs-utils went
# straight to 2.9-12, and a rule that let the first baseline keep both of its
# builds put 2.9-10 and 2.9-12 side by side in nfs-utils. The partner a build
# has to move with on some image is what verify_union_rpm finds.
#
# The earliest directory, because the baselines disagree about that as much
# as about builds: gnutls came up at chrony against 8.0, whose gnutls is too
# old for the chrony of 8.10, and at devel against 8.6, whose gnutls serves
# chrony and only the headers want it exact. Kept at devel, an 8.0 node fails
# at chrony. The baseline that wanted it earliest had what it needs by then,
# and what it needs is placed by the same rule
union_baselines() {
  declare -A best_file best_version place pos
  local baseline dir name file pkg key p version
  for baseline in "$out_path.baselines"/*/; do
    for dir in "$baseline"*/; do
      [[ -d $dir ]] || continue
      name=$(basename "$dir")
      p=${dir_pos[$name]-0}
      for file in "$dir"*."$family"; do
        [[ -f $file ]] || continue
        pkg=$(package_name_of "$file")
        version=$(package_version_of "$file")
        key="${dir_group[$name]-$name}:$pkg"
        if [[ -z ${best_file[$key]-} ]]; then
          best_file[$key]=$file
          best_version[$key]=$version
          place[$key]=$name
          pos[$key]=$p
          continue
        fi
        if [[ $(printf '%s\n' "${best_version[$key]}" "$version" | sort -V | tail -1) != "${best_version[$key]}" ]]; then
          best_file[$key]=$file
          best_version[$key]=$version
        fi
        if [[ $p -lt ${pos[$key]} ]]; then
          place[$key]=$name
          pos[$key]=$p
        fi
      done
    done
  done

  for key in "${!best_file[@]}"; do
    mkdir -p "$out_path/${place[$key]}"
    cp -p "${best_file[$key]}" "$out_path/${place[$key]}/"
  done

  return 0
}

package_version_of() {
  local file=$1

  case $family in
  rpm) rpm -qp --queryformat '%{EPOCH}:%{VERSION}-%{RELEASE}' "$file" 2>/dev/null | sed 's/^(none):/0:/' ;;
  deb) dpkg-deb -f "$file" Version ;;
  esac
}

# The union installed on every baseline, by rpm itself, against a copy of the
# baseline's database and nothing else: --justdb takes the transaction into
# the database and touches no file, so what rpm refuses here is what it would
# refuse on a node of that image, and for the same reason. Two reasons come
# up. A package the union raises has a partner the image holds and the
# baseline that raised it did not - the unbound-libs the headers want sits
# beside a python3-unbound on the images of 8.3 and later, built in lockstep,
# and rpm will not move one without the other - so the partner is fetched at
# the newest build into the same directory. And a package a baseline chose
# wants something that baseline had and this image lacks, which is fetched
# the same way. Each directory is installed in the order the node installs
# them, and the groups a node installs on their own start from the bare copy
# again. What is added is tried on every baseline once more, until a pass
# adds nothing
verify_union_rpm() {
  local pass added
  for pass in 1 2 3 4; do
    added=""
    local i=0 r
    for r in "${roots[@]}"; do
      [[ $r = "/" ]] && r=""
      verify_union_rpm_on "$r" "$i" || added=yes
      i=$((i + 1))
    done
    [[ -z $added ]] && return 0
  done

  die "[ERROR] The directories still do not install on every baseline after $pass passes"
}

# Returns 1 when something had to be added for this baseline
verify_union_rpm_on() {
  local r=$1 i=$2

  local check="$out_path.check/$i"
  rm -rf "$check"
  mkdir -p "$check/var/lib" "$check/usr/lib/sysimage"
  if [[ -n $r ]]; then
    cp -a "$r"/var/lib/rpm "$check"/var/lib/rpm
  else
    cp -a "$(readlink -f /var/lib/rpm)" "$check"/var/lib/rpm
  fi
  rm -f "$check"/var/lib/rpm/__db.*
  ln -s ../../../var/lib/rpm "$check"/usr/lib/sysimage/rpm

  # The groups, each in install order; the first is the one the node installs
  # as a sequence, the others stand alone on the bare copy
  local groups=() g dir
  for dir in "${!dir_group[@]}"; do
    g=${dir_group[$dir]}
    [[ " ${groups[*]} " = *" $g "* ]] || groups+=("$g")
  done

  local rc=0 result
  for g in "${groups[@]}"; do
    local db="$check.g$g"
    rm -rf "$db"; cp -a "$check" "$db"
    while read -r dir; do
      [[ -z $dir ]] && continue
      compgen -G "$out_path/$dir/*.rpm" >/dev/null || continue
      # A kernel is installed beside the one running, never over it, which is
      # how setup-kernel.sh lays the kernel directory down; -U would take the
      # running kernel out and leave the "kernel" package of the image wanting
      # it
      local mode=-U
      compgen -G "$out_path/$dir/kernel-core-*.rpm" >/dev/null && mode=-i
      # Fixed and tried again before the next directory is tried, since the
      # next one is planned on this one having gone in: left failing, every
      # directory after it fails for what this one holds, and the fix for
      # those is to fetch what is already here
      local round
      for round in 1 2 3 4 5; do
        if result=$(rpm --root "$db" $mode --justdb --force --nodigest --nosignature "$out_path/$dir"/*.rpm 2>&1); then
          break
        fi
        [[ $round = 5 ]] && die "[ERROR] Directory[\"$dir\"] still does not install on baseline $i after what was fetched for it:\n$result"
        result=$(grep -vE '^warning:' <<< "$result" || true)
        verify_fix_rpm "$dir" "$i" "$result" || rc=1
      done
    done < <(for dir in "${!dir_group[@]}"; do [[ ${dir_group[$dir]} = "$g" ]] && echo "${dir_pos[$dir]} $dir"; done | sort -n | cut -d' ' -f2)
    rm -rf "$db"
  done
  rm -rf "$check"

  return $rc
}

# Reads what rpm refused and fetches what satisfies it into the directory.
# Returns 1 when it fetched something, so that the pass is repeated
verify_fix_rpm() {
  local dir=$1 i=$2 result=$3

  local line need by name fetched=""
  while read -r line; do
    [[ $line =~ ^[[:space:]]*(.+)[[:space:]]is[[:space:]]needed[[:space:]]by[[:space:]](\(installed\)[[:space:]])?(.+)$ ]] || continue
    need=${BASH_REMATCH[1]}
    by=${BASH_REMATCH[3]}
    if [[ -n ${BASH_REMATCH[2]} ]]; then
      # The partner the image holds: named without its version and arch
      name=${by%.*}
      name=${name%-*}
      name=${name%-*}
    else
      # What the directory's package wants and this image lacks: of whoever
      # provides it, the one the image holds, since a provider the image has
      # at too low a build is what "needed" means then, and selinux-policy-any
      # is otherwise answered by the mls policy rather than the targeted one
      # the image runs; else the first
      local providers
      providers=$(dnf -q repoquery --arch x86_64,noarch --queryformat '%{name}' --whatprovides "$need" 2>/dev/null | sort -u)
      [[ -z $providers ]] && die "[ERROR] Directory[\"$dir\"] wants \"$need\" on baseline $i and the repositories hold nothing that provides it"
      name=""
      local candidate
      while read -r candidate; do
        rpm --root "$out_path.check/$i" -q "$candidate" &>/dev/null && { name=$candidate; break; }
      done <<< "$providers"
      [[ -z $name ]] && name=$(head -1 <<< "$providers")
    fi
    [[ $fetched = *" $name "* ]] && continue
    fetched+=" $name "

    # What the bundle holds already is copied over rather than fetched, at
    # the build the bundle chose, and what release.yml pins is fetched at the
    # build it pins; the rest at the newest
    local have
    have=$(find "$out_path" -maxdepth 2 -name "$name-[0-9]*.rpm" | head -1)
    if [[ -n $have ]]; then
      msg "[INFO] Directory[\"$dir\"] on baseline $i: \"$need\" is needed by $by. copying package[\"$name\"] into it from directory[\"$(basename "$(dirname "$have")")\"]"
      cp -p "$have" "$out_path/$dir/"
      continue
    fi
    local spec=$name
    grep -q "^  $name: \"" "$release_meta_path" && spec="$name-$(declared_version "$name")"
    msg "[INFO] Directory[\"$dir\"] on baseline $i: \"$need\" is needed by $by. fetching package[\"$spec\"] into it"
    dnf -q download --destdir "$out_path/$dir" --arch x86_64,noarch "$spec" >/dev/null ||
      die "[ERROR] Fail to download package[\"$spec\"]"
  done <<< "$result"

  if [[ -z $fetched ]]; then
    die "[ERROR] Directory[\"$dir\"] does not install on baseline $i and nothing here answers it:\n$result"
  fi

  return 1
}

package_name_of() {
  local file=$1

  case $family in
  rpm) rpm -qp --queryformat '%{NAME}' "$file" 2>/dev/null ;;
  deb) dpkg-deb -f "$file" Package ;;
  esac
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
  rpm) copy_from="other rhel" ;;
  deb) copy_from="other ubuntu" ;;
  esac
  msg "[INFO] $(du -sh "$out_path" | cut -f1) under \"$out_path\". Copy k8s and nvidia-container-toolkit from the $copy_from directory next to these"

  # What each baseline produced is kept until here, so that a refusal above
  # can be read back to the baseline that caused it
  rm -rf "$out_path.baselines"

  return 0
}

main
