#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--out-path path]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--out-path      Directory to fill with the binaries release.yml declares, defaults to bundle/bin of
                this tree. It is emptied first
EOF
  exit
}

parse_params() {
  out_path=""

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --out-path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      out_path="${2-}"
      shift
      ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

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
  [[ -n ${work_path-} ]] && rm -rf "$work_path"

  return 0
}

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT
setup_colors
parse_params "$@"

# --- End of CLI template ---

# Fills bundle/bin with the binaries release.yml declares, from where each of
# them is published, and asks every one of them which version it is before
# calling the directory done.
#
# The question is asked with the same code the node asks it with,
# linux-bin-common.sh, so that a directory this tool passes is one
# install-programs.sh accepts. It is asked rather than a checksum file read:
# a checksum published next to a download is changed by whoever changes the
# download, and what the release scheme needs to know is that the file called
# "helm" in the bundle is the helm the release names. The binary itself is the
# only thing that can say so. This therefore has to run on linux/amd64, which
# is what the binaries are built for and what the nodes run
KI_ROOT_PATH=$(cd "$SCRIPT_DIR_PATH/.." &>/dev/null && pwd -P)
RELEASE_META_PATH="$KI_ROOT_PATH"/release.yml

# shellcheck source=../scripts/all-node/linux-bin/linux-bin-common.sh
source "$SCRIPT_DIR_PATH/../scripts/all-node/linux-bin/linux-bin-common.sh"

work_path=""

main() {
  [[ -f $RELEASE_META_PATH ]] || die "[ERROR] No such file or directory of which path is \"$RELEASE_META_PATH\""
  [[ -z $out_path ]] && out_path="$KI_ROOT_PATH/bundle/bin"

  require_linux_amd64
  require_command curl
  require_command tar

  local declared
  declared=$(declared_binaries)
  [[ -z $declared ]] && die "[ERROR] File[\"$RELEASE_META_PATH\"] declares no binaries. Entries are expected under binaries as \"  <name>: \\\"<version>\\\"\""

  work_path=$(mktemp -d)
  rm -rf "$out_path"
  mkdir -p "$out_path"

  local name version
  while read -r name version; do
    [[ -z $name ]] && continue
    fetch_binary "$name" "$version"
  done <<< "$declared"

  msg ""
  msg "[INFO] $(wc -l <<< "$declared") binaries under \"$out_path\", each the version release.yml declares"

  return 0
}

# The binaries are asked which version they are, so they have to run here
require_linux_amd64() {
  [[ $(uname -s) = "Linux" && $(uname -m) = "x86_64" ]] && return 0

  die "[ERROR] This runs on linux/amd64, which the binaries of the bundle are built for, and this machine is $(uname -s)/$(uname -m)"
}

require_command() {
  local command=$1

  type "$command" &>/dev/null && return 0

  die "[ERROR] Command[\"$command\"] is needed and not installed"
}

# The entries of the binaries block of release.yml, as "<name> <version>"
# lines, read the way check-release-docs.sh reads them. yq is one of the
# binaries this is about to fetch, so the file is read without it
declared_binaries() {
  awk '
    $0 == "binaries:" { in_block = 1; next }
    in_block {
      if ($0 ~ /^  [A-Za-z0-9._-]+: "[^"]+"$/) {
        name = $1
        sub(/:$/, "", name)
        version = $2
        gsub(/"/, "", version)
        print name, version
        next
      }
      exit
    }
  ' < "$RELEASE_META_PATH"

  return 0
}

# Where each binary is published and what it is called inside what is
# published there. A name this does not know stops the run: adding a binary
# to release.yml means saying where it comes from here, and how it is asked
# its version in linux-bin-common.sh
fetch_binary() {
  local name=$1
  local version=$2

  local url member
  case $name in
  helm)
    url="https://get.helm.sh/helm-v$version-linux-amd64.tar.gz"
    member="linux-amd64/helm"
    ;;
  etcdctl | etcdutl)
    url="https://github.com/etcd-io/etcd/releases/download/v$version/etcd-v$version-linux-amd64.tar.gz"
    member="etcd-v$version-linux-amd64/$name"
    ;;
  nerdctl)
    url="https://github.com/containerd/nerdctl/releases/download/v$version/nerdctl-$version-linux-amd64.tar.gz"
    member="nerdctl"
    ;;
  yq)
    url="https://github.com/mikefarah/yq/releases/download/v$version/yq_linux_amd64"
    member=""
    ;;
  crane)
    url="https://github.com/google/go-containerregistry/releases/download/v$version/go-containerregistry_Linux_x86_64.tar.gz"
    member="crane"
    ;;
  *)
    die "[ERROR] Binary[\"$name\"] is declared by release.yml and this script does not know where it is published. Add it to fetch_binary of fetch-bundle-binaries.sh and to binary_version of linux-bin-common.sh"
    ;;
  esac

  msg "[INFO] $name $version  <-  $url"

  # One download per url: the two etcd binaries come from one archive
  local archive
  archive="$work_path/$(basename "$url")"
  if [[ ! -f $archive ]]; then
    curl -fsSL --retry 3 "$url" -o "$archive" || die "[ERROR] Fail to download \"$url\""
  fi

  if [[ -z $member ]]; then
    install -m 0755 "$archive" "$out_path/$name"
  else
    local extract_path="$work_path/$name"
    mkdir -p "$extract_path"
    tar xzf "$archive" -C "$extract_path" "$member" 2>/dev/null ||
      die "[ERROR] Archive[\"$url\"] holds no \"$member\""
    install -m 0755 "$extract_path/$member" "$out_path/$name"
  fi

  local found
  found=$(binary_version "$out_path" "$name")
  [[ $found = "$version" ]] && return 0

  die "[ERROR] Binary[\"$name\"] was fetched as version[\"$version\"] and answers version[\"${found:-unknown}\"]. What \"$url\" serves is not what release.yml declares"
}

main
