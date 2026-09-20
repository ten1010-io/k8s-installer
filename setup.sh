#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
EOF
  exit
}

parse_params() {
  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
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
}

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT
setup_colors
parse_params "$@"

# --- End of CLI template ---

# Kept in sync with ki_opt_root_path of group_vars/all/constant-vars.yml. It can
# not be read from there, since that file is only meaningful to ansible, which is
# what this script installs
KI_OPT_ROOT_PATH="/opt/k8s-installer"
KI_OPT_SCRIPTS_PATH="$KI_OPT_ROOT_PATH"/scripts
KI_OPT_BUNDLE_PATH="$KI_OPT_ROOT_PATH"/bundle
KI_OPT_ANSIBLE_PATH="$KI_OPT_ROOT_PATH"/ansible
KI_OPT_VENV_PATH="$KI_OPT_ROOT_PATH"/venv
KI_OPT_RELEASE_PATH="$KI_OPT_ROOT_PATH"/release
KI_OPT_RELEASE_META_PATH="$KI_OPT_ROOT_PATH"/release.yml

SRC_SCRIPTS_PATH="$SCRIPT_DIR_PATH"/scripts
SRC_ANSIBLE_PATH="$SCRIPT_DIR_PATH"/ansible
SRC_RELEASE_META_PATH="$SCRIPT_DIR_PATH"/release.yml

# Kept in sync with ki_release_snapshot_suffix of group_vars/all/constant-vars.yml
SNAPSHOT_SUFFIX="-SNAPSHOT"

version=""
src_bundle_archive_path=""

main() {
  require_root
  require_not_setup
  require_file_exists "$SRC_RELEASE_META_PATH"

  # yq is inside the bundle that has not been unpacked yet, so the one key needed
  # to work out which bundle this is, is read the way download-bundle.sh reads it
  version=$(grep -oP '^version: "\K[^"]+' < "$SRC_RELEASE_META_PATH")
  [[ -z $version ]] && die "[ERROR] File[\"$SRC_RELEASE_META_PATH\"] has no version"

  src_bundle_archive_path="$SCRIPT_DIR_PATH/bundle-$(get_bundle_version "$version").tgz"
  require_bundle_archive

  msg "[INFO] Setting up k8s installer release[\"$version\"] in \"$KI_OPT_ROOT_PATH\""
  warn_if_snapshot

  copy_installer
  copy_ansible
  copy_entrypoints
  setup_venv
  write_release

  msg ""
  msg "[INFO] K8s installer set up successfully"
  msg ""
  print_next_steps

  return 0
}

require_root() {
  [[ $(id -u) = "0" ]] && return 0

  die "[ERROR] This script must be run as root"
}

is_snapshot() {
  if [[ ${1-} == *"$SNAPSHOT_SUFFIX" ]]; then echo "true"; else echo "false"; fi
}

warn_if_snapshot() {
  [[ $(is_snapshot "$version") = "false" ]] && return 0

  msg ""
  msg "[WARN] Release[\"$version\"] is a snapshot, meant for development only. A node"
  msg "[WARN] that holds one can not be upgraded, only rebuilt, and the drift check"
  msg "[WARN] can not tell two builds of it apart"
  msg ""

  return 0
}

# The release file is the marker of a finished setup, so its presence is what
# separates a fresh install from an upgrade. Reinstalling over a deployment would
# leave the managed nodes on a release the control node no longer has
require_not_setup() {
  [[ ! -e $KI_OPT_RELEASE_PATH ]] && return 0

  msg "[ERROR] K8s installer release[\"$(<"$KI_OPT_RELEASE_PATH")\"] is already set up in \"$KI_OPT_ROOT_PATH\""
  die "[ERROR] Run \"upgrade.sh\" to upgrade it, or \"$KI_OPT_ROOT_PATH/reset.sh\" to remove it first"
}

# A patch release exists to fix what is in this repository, and republishing a
# gigabyte of packages and images to carry a corrected shell script is waste. The
# releases of one minor line therefore share one bundle, which in turn means the
# bundle of a minor line can never change: anything that needs a different package
# or image is a minor bump rather than a patch. See release.yml
get_bundle_version() {
  local version=$1

  echo "${version%.*}.x"

  return 0
}

# The bundle is expected as the archive it is published as, named after the minor
# line it belongs to. An air gapped control node carries it in on media rather than
# downloading it, and the name is what keeps the bundle of one line from being
# unpacked next to the source tree of another
require_bundle_archive() {
  [[ ! -e $src_bundle_archive_path ]] &&
    die "[ERROR] File[\"$src_bundle_archive_path\"] not exists. execute \"download-bundle.sh\", or place the bundle of this release there"
  [[ ! -f $src_bundle_archive_path ]] && die "[ERROR] File[\"$src_bundle_archive_path\"] is not a regular file"

  return 0
}

# Replaced rather than merged, so the control node can not end up holding files of
# two releases at once. This mirrors what setup-k8s-installer.yml does on the
# managed nodes
copy_installer() {
  mkdir -p "$KI_OPT_ROOT_PATH"

  rm -rf "$KI_OPT_SCRIPTS_PATH"
  cp -r "$SRC_SCRIPTS_PATH" "$KI_OPT_SCRIPTS_PATH"

  rm -rf "$KI_OPT_BUNDLE_PATH"
  tar xzf "$src_bundle_archive_path" -C "$KI_OPT_ROOT_PATH"
  require_directory_exists "$KI_OPT_BUNDLE_PATH"

  cp -f "$SRC_RELEASE_META_PATH" "$KI_OPT_RELEASE_META_PATH"

  return 0
}

# The source tree holds this directory in the shape it is deployed in, so it goes
# over as one piece. inventory.yml and group_vars/all/vars.yml are edited by the
# operator once it is there, which makes this the only place that writes them.
# upgrade.sh leaves both alone
#
# The ssh scripts live in it rather than at the root of the deployment, because
# what they configure is the transport ansible runs over. sync-ansible.yml then
# carries them to every ki cp node with the rest of the directory, so a node
# taking over as the control node can put its own key on the managed nodes
copy_ansible() {
  rm -rf "$KI_OPT_ANSIBLE_PATH"
  cp -r "$SRC_ANSIBLE_PATH" "$KI_OPT_ANSIBLE_PATH"

  chmod 755 "$KI_OPT_ANSIBLE_PATH"/configure-control-node-ssh.sh
  chmod 755 "$KI_OPT_ANSIBLE_PATH"/reset-control-node-ssh.sh

  return 0
}

# Removing the installer is not something ansible does, so reset.sh sits at the
# root of the deployment. Placed there so that removing a cluster never needs the
# source tree to be cloned again
copy_entrypoints() {
  cp -f "$SCRIPT_DIR_PATH"/reset.sh "$KI_OPT_ROOT_PATH"/
  chmod 755 "$KI_OPT_ROOT_PATH"/reset.sh

  return 0
}

setup_venv() {
  "$KI_OPT_SCRIPTS_PATH"/setup-venv.sh --root-path "$KI_OPT_ROOT_PATH"

  return 0
}

write_release() {
  "$KI_OPT_SCRIPTS_PATH"/write-release.sh --root-path "$KI_OPT_ROOT_PATH" --version "$version"

  return 0
}

print_next_steps() {
  msg "[INFO] To configure SSH of the control node and the managed nodes, run the following"
  msg ""
  msg "$KI_OPT_ANSIBLE_PATH/configure-control-node-ssh.sh"
  msg ""
  msg "[INFO] Then edit the inventory and the variables"
  msg ""
  msg "$KI_OPT_ANSIBLE_PATH/inventory.yml"
  msg "$KI_OPT_ANSIBLE_PATH/group_vars/all/vars.yml"
  msg ""
  msg "[INFO] Then deploy the installer to the managed nodes and set up the cluster"
  msg ""
  msg "source $KI_OPT_VENV_PATH/bin/activate"
  msg "cd $KI_OPT_ANSIBLE_PATH"
  msg "ansible-playbook -i inventory.yml playbooks/setup-k8s-installer.yml"
  msg "ansible-playbook -i inventory.yml playbooks/setup-cluster.yml"

  return 0
}

require_directory_exists() {
  local path=$1

  [[ ! -e $path ]] && die "[ERROR] No such file or directory of which path is \"$path\""
  [[ ! -d $path ]] && die "[ERROR] File[\"$path\"] is not a directory"

  return 0
}

require_file_exists() {
  local path=$1

  [[ ! -e $path ]] && die "[ERROR] No such file or directory of which path is \"$path\""
  [[ ! -f $path ]] && die "[ERROR] File[\"$path\"] is not a regular file"

  return 0
}

main
