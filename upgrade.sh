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

KI_OPT_ROOT_PATH="/opt/k8s-installer"
KI_OPT_SCRIPTS_PATH="$KI_OPT_ROOT_PATH"/scripts
KI_OPT_BIN_PATH="$KI_OPT_ROOT_PATH"/bin
KI_OPT_ANSIBLE_PATH="$KI_OPT_ROOT_PATH"/ansible
KI_OPT_VENV_PATH="$KI_OPT_ROOT_PATH"/venv
KI_OPT_RELEASE_PATH="$KI_OPT_ROOT_PATH"/release
KI_OPT_RELEASE_META_PATH="$KI_OPT_ROOT_PATH"/release.yml

SRC_BIN_PATH="$SCRIPT_DIR_PATH"/bin
SRC_SCRIPTS_PATH="$SCRIPT_DIR_PATH"/scripts
SRC_ANSIBLE_PATH="$SCRIPT_DIR_PATH"/ansible
SRC_RELEASE_META_PATH="$SCRIPT_DIR_PATH"/release.yml

YQ_CMD="$SRC_BIN_PATH"/bin/yq

# Kept in sync with ki_release_snapshot_suffix of group_vars/all/constant-vars.yml
SNAPSHOT_SUFFIX="-SNAPSHOT"

version=""
installed_version=""

main() {
  require_root
  require_setup
  require_bin_downloaded
  require_file_exists "$SRC_RELEASE_META_PATH"

  version=$($YQ_CMD '.version' < "$SRC_RELEASE_META_PATH")
  [[ -z $version || $version = "null" ]] && die "[ERROR] File[\"$SRC_RELEASE_META_PATH\"] has no version"
  installed_version=$(<"$KI_OPT_RELEASE_PATH")

  require_upgradable

  if [[ $installed_version = "$version" ]]; then
    msg "[INFO] Redeploying snapshot[\"$version\"] in \"$KI_OPT_ROOT_PATH\""
  else
    msg "[INFO] Upgrading k8s installer in \"$KI_OPT_ROOT_PATH\" from release[\"$installed_version\"] to release[\"$version\"]"
  fi
  warn_if_snapshot

  # Removed first, so that a control node that fails part way through reports
  # itself as not deployed rather than as running a release it does not have
  rm -f "$KI_OPT_RELEASE_PATH"

  copy_installer
  copy_ansible
  copy_entrypoints
  setup_venv
  write_release

  msg ""
  if [[ $installed_version = "$version" ]]; then
    msg "[INFO] Snapshot redeployed successfully"
  else
    msg "[INFO] K8s installer upgraded successfully"
  fi
  msg ""
  print_next_steps

  return 0
}

require_root() {
  [[ $(id -u) = "0" ]] && return 0

  die "[ERROR] This script must be run as root"
}

require_setup() {
  [[ -e $KI_OPT_RELEASE_PATH ]] && return 0

  msg "[ERROR] No k8s installer release is set up in \"$KI_OPT_ROOT_PATH\""
  die "[ERROR] Run \"setup.sh\" to set it up first"
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

# A release only declares the releases it was tested to upgrade from, so anything
# else is rejected here rather than left to fail somewhere in the middle of the
# cluster upgrade
require_upgradable() {
  # A snapshot keeps its name while its content changes, so nothing can be said
  # about what a node holding one actually has. Neither upgradable_from nor the
  # changed flags of a release describe a delta from it, which leaves replacing it
  # with itself as the only transition it has
  if [[ $(is_snapshot "$installed_version") = "true" ]]; then
    [[ $installed_version = "$version" ]] && return 0

    msg "[ERROR] The installed release[\"$installed_version\"] is a snapshot, so it can only be"
    msg "[ERROR] replaced by itself"
    die "[ERROR] Run \"$KI_OPT_ROOT_PATH/reset.sh\" and \"setup.sh\" to move to release[\"$version\"]"
  fi

  local upgradable_from
  upgradable_from=$($YQ_CMD -o json '.upgradable_from' < "$SRC_RELEASE_META_PATH")

  local is_upgradable
  is_upgradable=$($YQ_CMD --null-input "$upgradable_from | contains([\"$installed_version\"])")

  [[ $is_upgradable = "true" ]] && return 0

  msg "[ERROR] Release[\"$version\"] can not be upgraded from the installed release[\"$installed_version\"]"
  die "[ERROR] Releases that it can be upgraded from are $upgradable_from"
}

require_bin_downloaded() {
  [[ ! -e $SRC_BIN_PATH ]] && die "[ERROR] Directory[\"$SRC_BIN_PATH\"] not exists. execute \"download-bin.sh\" first"
  [[ ! -d $SRC_BIN_PATH ]] && die "[ERROR] File[\"$SRC_BIN_PATH\"] is not a directory"
  [[ ! -f $YQ_CMD ]] && die "[ERROR] File[\"$YQ_CMD\"] not exists. execute \"download-bin.sh\" first"

  return 0
}

copy_installer() {
  rm -rf "$KI_OPT_SCRIPTS_PATH"
  cp -r "$SRC_SCRIPTS_PATH" "$KI_OPT_SCRIPTS_PATH"

  rm -rf "$KI_OPT_BIN_PATH"
  cp -r "$SRC_BIN_PATH" "$KI_OPT_BIN_PATH"

  cp -f "$SRC_RELEASE_META_PATH" "$KI_OPT_RELEASE_META_PATH"

  return 0
}

# The directory is replaced as a whole, so that a playbook or a variable file the
# new release dropped does not survive on the control node. inventory.yml and
# group_vars/all/vars.yml belong to the operator and are put back untouched, with
# the files of the new release left beside them, so that variables the release
# added can be diffed in and merged by hand
copy_ansible() {
  local tmp_path
  tmp_path=$(mktemp -d)

  cp -f "$KI_OPT_ANSIBLE_PATH"/inventory.yml "$tmp_path"/inventory.yml
  cp -f "$KI_OPT_ANSIBLE_PATH"/group_vars/all/vars.yml "$tmp_path"/vars.yml

  rm -rf "$KI_OPT_ANSIBLE_PATH"
  cp -r "$SRC_ANSIBLE_PATH" "$KI_OPT_ANSIBLE_PATH"

  chmod 755 "$KI_OPT_ANSIBLE_PATH"/configure-control-node-ssh.sh
  chmod 755 "$KI_OPT_ANSIBLE_PATH"/reset-control-node-ssh.sh

  mv -f "$KI_OPT_ANSIBLE_PATH"/group_vars/all/vars.yml "$KI_OPT_ANSIBLE_PATH"/group_vars/all/vars.yml.new
  mv -f "$KI_OPT_ANSIBLE_PATH"/inventory.yml "$KI_OPT_ANSIBLE_PATH"/inventory.yml.new

  cp -f "$tmp_path"/inventory.yml "$KI_OPT_ANSIBLE_PATH"/inventory.yml
  cp -f "$tmp_path"/vars.yml "$KI_OPT_ANSIBLE_PATH"/group_vars/all/vars.yml

  rm -rf "$tmp_path"

  return 0
}

# Removing the installer is not something ansible does, so reset.sh sits at the
# root of the deployment rather than in the ansible directory the ssh scripts
# went to
copy_entrypoints() {
  cp -f "$SCRIPT_DIR_PATH"/reset.sh "$KI_OPT_ROOT_PATH"/
  chmod 755 "$KI_OPT_ROOT_PATH"/reset.sh

  return 0
}

# The packages of the new release can not be reconciled into the existing
# environment offline, so it is built again from scratch
setup_venv() {
  "$KI_OPT_SCRIPTS_PATH"/setup-venv.sh --root-path "$KI_OPT_ROOT_PATH" --force

  return 0
}

write_release() {
  "$KI_OPT_SCRIPTS_PATH"/write-release.sh --root-path "$KI_OPT_ROOT_PATH" --version "$version"

  return 0
}

print_next_steps() {
  msg "[INFO] Review the variables the new release added, then merge what is needed"
  msg ""
  msg "diff $KI_OPT_ANSIBLE_PATH/group_vars/all/vars.yml $KI_OPT_ANSIBLE_PATH/group_vars/all/vars.yml.new"
  msg "diff $KI_OPT_ANSIBLE_PATH/inventory.yml $KI_OPT_ANSIBLE_PATH/inventory.yml.new"
  msg ""
  msg "[INFO] Then upgrade the installer of the managed nodes"
  msg ""
  msg "source $KI_OPT_VENV_PATH/bin/activate"
  msg "cd $KI_OPT_ANSIBLE_PATH"
  msg "ansible-playbook -i inventory.yml playbooks/upgrade-k8s-installer.yml"

  return 0
}

require_file_exists() {
  local path=$1

  [[ ! -e $path ]] && die "[ERROR] No such file or directory of which path is \"$path\""
  [[ ! -f $path ]] && die "[ERROR] File[\"$path\"] is not a regular file"

  return 0
}

main
