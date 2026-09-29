#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] --os os --out-path path [--root path]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--os            rhel9 or rhel10, which must be what this machine runs
--out-path      Directory to fill, laid out as bundle/linux-packages/<os> is
--root          Resolve against the rpm database under this directory instead of this machine's
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
  [[ $os != "rhel9" && $os != "rhel10" ]] && die "[ERROR] Option --os takes rhel9 or rhel10"

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

# Fills bundle/linux-packages/rhel9 or rhel10 from the repositories, on a machine
# that runs the OLDEST minor the release supports.
#
# Each directory is one principal package and whatever this machine lacks for
# it, resolved by dnf against what is installed here. Run on the oldest minor,
# that is the closure an old node needs and a newer one skips: install-packages.sh
# hands rpm only what is not already there at the version the bundle holds. The
# repository serves the newest packages of the major whatever minor asks, so
# what lands here is the same content a node of the newest minor has.
#
# Resolved as an install that only downloads, not with "dnf download --resolve".
# The latter takes what is missing and nothing else: a library that is installed
# but too old for what is being pulled is left where it is, and the hole only
# shows on a node. The systemd of rhel 10.2 wants an openssl the 10.0 image does
# not have, and "download --resolve" handed over systemd alone. An install
# transaction upgrades what has to be upgraded, and --downloadonly keeps it off
# this machine, so every directory is resolved against the same untouched state.
# Weak dependencies are left out, since rpm on the node never asks for them.
#
# Even so, what a cloud image holds is not what a minimal install holds. The
# check that counts is a fresh machine of the oldest minor with its repositories
# disabled installing the whole bundle, which is what setup-cluster.yml on such a
# machine is.
#
# The kernel is never taken. iptables-nft of some rhel 10 builds asks for
# kernel-modules-extra, which pulls a whole new kernel after it, and a kernel is
# something the node decides for itself. check-node-state.sh is what says when a
# node lacks the modules that package holds.
#
# When no machine of the oldest minor has a repository, --root stands in for
# it. Red Hat retires the cloud images of the minors it no longer supports, and
# the KVM guest image of such a minor from the customer portal has no repository
# at all. dnf resolves against the rpm database of whatever root it is given, so
# a copy of /var/lib/rpm and /etc/os-release from a fresh machine of that minor,
# placed under a directory here, is enough: this machine only lends its
# repositories, and what it has installed itself is never consulted.
#
# The docker repository is added for containerd.io and docker, at the versions
# release.yml declares; the python packages, the kubernetes packages and the
# nvidia toolkit are not taken here. python-packages is one set for every os of
# a python, and the kubernetes and nvidia rpms carry no distribution tag and are
# the same files on rhel 8, 9 and 10, so they are copied from the rhel8 directory
DOCKER_REPO_URL="https://download.docker.com/linux/rhel/docker-ce.repo"

# The order install-packages.sh installs the directories in, which is what the
# dedupe below follows: an rpm that two principals resolve to is kept in the
# directory installed first
INSTALL_ORDER=(nfs-utils chrony container-selinux containerd systemd openssh fuse-overlayfs slirp conntrack iptables-nft nftables docker ethtool iproute socat libibverbs)

release_meta_path="$SCRIPT_DIR_PATH"/../release.yml

# What every dnf call below is given: nothing, or the root to resolve against.
# The repositories stay those of this machine, which is what reposdir does
dnf_opts=()

main() {
  require_this_os
  setup_dnf_opts
  [[ -f $release_meta_path ]] || die "[ERROR] No such file or directory of which path is \"$release_meta_path\""

  local containerd_version docker_version buildx_version compose_version
  containerd_version=$(declared_version containerd.io)
  docker_version=$(declared_version docker-ce)
  buildx_version=$(declared_version docker-buildx-plugin)
  compose_version=$(declared_version docker-compose-plugin)

  rm -rf "$out_path"
  mkdir -p "$out_path"

  dnf -y -q config-manager --add-repo "$DOCKER_REPO_URL"

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

  dedupe

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

  report

  return 0
}

require_this_os() {
  local id major
  id=$(grep -oP '^ID="?\K\w+(?="?$)' /etc/os-release)
  major=$(grep -oP '^VERSION_ID="?\K[0-9]+' /etc/os-release)
  [[ "$id$major" = "$os" ]] || die "[ERROR] This machine runs $id $major and the packages of $os have to be resolved on a machine that runs it, or with the repositories of one"

  [[ -z $root ]] && return 0

  [[ -f $root/etc/os-release && -d $root/var/lib/rpm ]] ||
    die "[ERROR] Directory[\"$root\"] has to hold the etc/os-release and var/lib/rpm of the machine to resolve for"
  id=$(grep -oP '^ID="?\K\w+(?="?$)' "$root"/etc/os-release)
  major=$(grep -oP '^VERSION_ID="?\K[0-9]+' "$root"/etc/os-release)
  [[ "$id$major" = "$os" ]] || die "[ERROR] Directory[\"$root\"] holds the database of $id $major, not of $os"

  msg "[INFO] Resolving for $(grep -oP '^PRETTY_NAME="\K[^"]+' "$root"/etc/os-release) from its rpm database, with the repositories of this machine"

  return 0
}

setup_dnf_opts() {
  [[ -z $root ]] && return 0

  local major=${os#rhel}
  dnf_opts=(--installroot "$root" --releasever "$major" --setopt=reposdir=/etc/yum.repos.d)

  return 0
}

declared_version() {
  local name=$1

  local version
  version=$(grep -oP "^  $name: \"\K[^\"]+" < "$release_meta_path")
  [[ -z $version ]] && die "[ERROR] File[\"$release_meta_path\"] declares no version of package[\"$name\"]"

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
harvest() {
  local dir=$1
  shift

  local excludes=(--exclude "kernel*")
  local attempt
  for attempt in 1 2 3 4 5; do
    local plan
    plan=$(dnf "${dnf_opts[@]}" --assumeno --setopt=install_weak_deps=False "${excludes[@]}" install "$@" 2>&1 || true)
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
  dnf "${dnf_opts[@]}" -y -q install --downloadonly --downloaddir "$out_path/$dir" "${excludes[@]}" \
    --setopt=install_weak_deps=False --setopt=keepcache=True "$@" >/dev/null ||
    die "[ERROR] Fail to download the packages of directory[\"$dir\"]"

  return 0
}

dedupe() {
  declare -A seen
  local dir file name
  for dir in "${INSTALL_ORDER[@]}"; do
    for file in "$out_path/$dir"/*.rpm; do
      [[ -e $file ]] || continue
      name=$(rpm -qp --queryformat '%{NAME}' "$file" 2>/dev/null)
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
    count=$(find "$dir" -name '*.rpm' | wc -l)
    if [[ $count = 0 ]]; then
      # Nothing this minor lacks for it, which the node script reads as a
      # directory holding no rpm
      rmdir "$dir"
      msg "[INFO] $(basename "$dir"): nothing this minor lacks"
      continue
    fi
    msg "[INFO] $(basename "$dir") ($count): $(find "$dir" -name '*.rpm' -printf '%f ' | sed 's/\.\(x86_64\|noarch\)\.rpm//g')"
  done

  msg "[INFO] $(du -sh "$out_path" | cut -f1) under \"$out_path\". Copy k8s and nvidia-container-toolkit from the rhel8 directory next to these"

  return 0
}

main
