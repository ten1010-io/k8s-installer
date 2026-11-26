#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--mount-path path]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--mount-path    Directory the ephemeral storage device is mounted at
EOF
  exit
}

parse_params() {
  mount_path=""

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --mount-path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      mount_path="${2-}"
      shift
      ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ -z "${mount_path-}" ]] && die "[ERROR] Missing required option: --mount-path"

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

# Takes the ephemeral storage of the node apart. It has to run before
# uninstall-packages.sh, which does rm -rf on the container runtime root: with the
# bind mount still up the contents go but the rmdir of the mount point fails with
# EBUSY, and that ends the whole reset. See docs/impl-notes.adoc
#
# The filesystem is left on the device. The data on it is cleared so that the node
# can be installed again, but reformatting is the decision of whoever owns the
# disk, not of a reset

FSTAB_PATH=/etc/fstab
FSTAB_BEGIN_MARKER="# BEGIN k8s-installer ephemeral-storage"
FSTAB_END_MARKER="# END k8s-installer ephemeral-storage"

KUBELET_PATH=/var/lib/kubelet
POD_LOGS_PATH=/var/log/pods
CONTAINERD_PATH=/var/lib/containerd

BIND_MOUNTS=(
  "kubelet:$KUBELET_PATH"
  "pod-logs:$POD_LOGS_PATH"
  "containerd:$CONTAINERD_PATH"
)

DROP_IN_FILE_NAME=10-ephemeral-storage.conf
SVC_NAMES=(containerd kubelet)

ki_opt_scripts_path=$(cd "$SCRIPT_DIR_PATH"/../.. &>/dev/null && pwd -P)

# Whether the node was set up from a device, read before the entries go: the
# first of them mounts the device by its uuid, and is a bind mount when the node
# was given a directory. Only a device is the installer's to delete in without
# looking twice, so anything else, entries already gone or edited by hand
# included, is treated as the other kind
of_device="false"

main() {
  if ! is_configured; then
    msg "[INFO] Ephemeral storage not configured. nothing to reset"

    return 0
  fi

  require_runtimes_not_running

  local first_entry
  first_entry=$(sed -n "/^$FSTAB_BEGIN_MARKER\$/{n;p;}" "$FSTAB_PATH")
  if [[ $first_entry = UUID=* ]]; then
    of_device="true"
  fi

  unmount_bind_mounts
  clear_subdirectories
  unmount_device
  # The fstab entries go before the drop in files, so that the daemon reload at
  # the end of the latter is what makes systemd forget both
  remove_fstab_entries
  remove_drop_in_files
  remove_mount_path

  return 0
}

# Anything this script has left behind counts, so that a run which failed part way
# through is finished rather than skipped
is_configured() {
  grep -qF "$FSTAB_BEGIN_MARKER" "$FSTAB_PATH" && return 0
  is_mountpoint "$mount_path" && return 0

  local entry
  for entry in "${BIND_MOUNTS[@]}"; do
    if is_mountpoint "${entry#*:}"; then
      return 0
    fi
  done

  return 1
}

require_runtimes_not_running() {
  local svc_name
  local error_msg
  for svc_name in "${SVC_NAMES[@]}"; do
    if [[ $("$ki_opt_scripts_path"/systemctl.sh is-running "$svc_name") = "true" ]]; then
      error_msg="[ERROR] Service[\"$svc_name\"] still running."
      error_msg+=" The mounts it holds open can not be taken apart under it."
      error_msg+=" Reset the container runtimes first"
      die "$error_msg"
    fi
  done

  return 0
}

# Recursive, because kubelet leaves the volume mounts of pods under its directory
# behind when it is stopped rather than drained, and a plain umount of the bind
# mount would fail with EBUSY on them
unmount_bind_mounts() {
  local entry
  local target
  for entry in "${BIND_MOUNTS[@]}"; do
    target=${entry#*:}
    if is_mountpoint "$target"; then
      umount -R "$target"
    fi
  done

  return 0
}

# Cleared through the mount path rather than through the bind mounts, which are
# gone by now. That also keeps the deletion away from anything still mounted under
# the target paths
clear_subdirectories() {
  if ! is_mountpoint "$mount_path"; then
    return 0
  fi

  # -xdev stops at another filesystem, which a mount left under a directory of
  # the site need not be: a bind mount of the same filesystem is deleted
  # through. So with a directory nothing is deleted while anything is mounted
  # below the mount path
  local left
  left=$(findmnt -rno TARGET | grep "^$mount_path/" || true)
  if [[ $of_device != "true" && -n $left ]]; then
    die "[ERROR] Still mounted under[\"$mount_path\"]: ${left//$'\n'/, }. Unmount them and reset again"
  fi

  local entry
  local path
  for entry in "${BIND_MOUNTS[@]}"; do
    path="$mount_path/${entry%%:*}"
    if [[ -d $path ]]; then
      find "$path" -mindepth 1 -xdev -delete
    fi
  done

  return 0
}

unmount_device() {
  if is_mountpoint "$mount_path"; then
    umount "$mount_path"
  fi

  return 0
}

remove_drop_in_files() {
  local svc_name
  for svc_name in "${SVC_NAMES[@]}"; do
    rm -f /etc/systemd/system/"$svc_name".service.d/"$DROP_IN_FILE_NAME"
  done
  "$ki_opt_scripts_path"/systemctl.sh reload

  return 0
}

# The markers carry no slash, which is what lets the address range use the
# ordinary delimiter
remove_fstab_entries() {
  sed -i "/^$FSTAB_BEGIN_MARKER\$/,/^$FSTAB_END_MARKER\$/d" "$FSTAB_PATH"

  return 0
}

# Only the mount point of this installer is removed. The three bind mount targets
# belong to kubelet and to the container runtime, and uninstall-packages.sh is
# what deals with those
remove_mount_path() {
  if is_mountpoint "$mount_path"; then
    die "[ERROR] Directory[\"$mount_path\"] is still a mount point"
  fi
  # With a directory behind it, the mount path is the whole directory of the
  # site for as long as the bind mount is up, and the check above is all that
  # says it is not. rmdir removes the mount point when it is one and nothing
  # when it is not
  if [[ $of_device != "true" ]]; then
    rmdir "$mount_path"

    return 0
  fi
  rm -rf "$mount_path"

  return 0
}

is_mountpoint() {
  local path=$1

  findmnt -nro TARGET --mountpoint "$path" > /dev/null 2>&1

  return $?
}

main
