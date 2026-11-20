#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--device path | --path path] [--mount-path path]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--device        Block device that holds the ephemeral storage of the node
--path          Directory of a filesystem that is already mounted, in place of a device
--mount-path    Directory the device is mounted at
EOF
  exit
}

parse_params() {
  device=""
  path=""
  mount_path=""

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --device)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      device="${2-}"
      shift
      ;;
    --path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      path="${2-}"
      shift
      ;;
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

  [[ -z "${device-}" && -z "${path-}" ]] && die "[ERROR] Missing required option: --device or --path"
  [[ -n "${device-}" && -n "${path-}" ]] &&
    die "[ERROR] Option --device and option --path are both given. A node keeps its ephemeral storage on one of them"
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

# Moves everything kubelet accounts as ephemeral storage off the root filesystem,
# so that an image or a pod log can not fill the disk the operating system runs on
#
# The three paths are fixed by kubelet and the container runtime, and a device can
# only be mounted at one of them, so the device is mounted once and its
# subdirectories are bind mounted onto the three. /var/log/pods has no kubelet
# flag at all, which is what makes bind mounting the only option
#
# Unlike the other setup scripts this one takes its input as arguments rather than
# reading the vars file. It has to run before gather-facts.yml, which measures the
# filesystem to calculate the kubelet reservations, and the vars file is written
# after that. See docs/impl-notes.adoc

FS_TYPE=ext4
FS_LABEL=ki-ephemeral

FSTAB_PATH=/etc/fstab
FSTAB_BEGIN_MARKER="# BEGIN k8s-installer ephemeral-storage"
FSTAB_END_MARKER="# END k8s-installer ephemeral-storage"

KUBELET_PATH=/var/lib/kubelet
POD_LOGS_PATH=/var/log/pods
CONTAINERD_PATH=/var/lib/containerd

# Subdirectory of the mounted device, and the path it is bind mounted onto. Kept
# as an ordered list rather than an associative array so that the fstab entries
# come out the same on every node
BIND_MOUNTS=(
  "kubelet:$KUBELET_PATH"
  "pod-logs:$POD_LOGS_PATH"
  "containerd:$CONTAINERD_PATH"
)

DROP_IN_FILE_NAME=10-ephemeral-storage.conf
SVC_NAMES=(containerd kubelet)

# Derived from the location of this script rather than read from the vars file,
# which does not exist yet at the point this runs
ki_opt_scripts_path=$(cd "$SCRIPT_DIR_PATH"/../.. &>/dev/null && pwd -P)

main() {
  if [[ -n $path ]]; then
    setup_directory
    return 0
  fi

  require_block_device

  # Checked before the guards below, so that a repeated run against a node that is
  # already set up is a no op rather than a failure
  if is_configured; then
    msg "[INFO] Ephemeral storage of device[\"$device\"] already configured"
    return 0
  fi

  require_runtimes_not_enabled
  require_bind_mount_targets_empty

  prepare_filesystem

  local uuid
  uuid=$(get_filesystem_uuid)

  write_fstab_entries "UUID=$uuid $mount_path $FS_TYPE defaults 0 2"
  mount_all

  return 0
}

# The directory takes the place of the device and nothing else changes: it is
# bind mounted at the mount path, where the device would be mounted, and from
# there on the node is laid out the way a device leaves it. That is what lets
# reset-ephemeral-storage.sh take both apart the same way.
#
# Everything is checked before the first line is written. The filesystem is the
# site's and so is what is on it, so a run that is refused leaves nothing behind
setup_directory() {
  require_directory
  require_directory_apart
  require_configured_from_directory_or_not_at_all

  if is_configured; then
    msg "[INFO] Ephemeral storage of directory[\"$path\"] already configured"
    return 0
  fi

  require_nothing_half_set_up
  require_directory_filesystem
  require_directory_subdirectories_unused
  require_runtimes_not_enabled
  require_bind_mount_targets_empty

  # requires-mounts-for has systemd mount the filesystem holding the directory
  # before this, which it does from the line of /etc/fstab that
  # require_directory_filesystem asked for
  write_fstab_entries "$path $mount_path none bind,x-systemd.requires-mounts-for=$path 0 0"
  mount_all

  return 0
}

# Given the way it is written into /etc/fstab and compared with what is there:
# absolute, with no link and no dot on the way, and made of characters a field
# of fstab holds as they are. Never made here. A directory that is missing is a
# path spelled wrong or a disk that is not mounted yet, and making it would put
# the data on whatever filesystem happens to be underneath
require_directory() {
  [[ $path =~ ^/[A-Za-z0-9._/@+-]*$ ]] ||
    die "[ERROR] Directory[\"$path\"] is not an absolute path of letters, digits and . _ - @ + /"
  [[ ! -e $path ]] && die "[ERROR] No such file or directory of which path is \"$path\". It is not made here: mount the filesystem and make the directory first"
  [[ ! -d $path ]] && die "[ERROR] File[\"$path\"] is not a directory"

  local real_path
  real_path=$(realpath -e "$path")
  [[ $real_path != "$path" ]] &&
    die "[ERROR] Directory[\"$path\"] is \"$real_path\" once its links and dots are followed. Give that path"

  return 0
}

# Neither inside nor around the mount path and the three paths that are bind
# mounted, which would mount the directory into itself
require_directory_apart() {
  local other
  for other in "$mount_path" "$KUBELET_PATH" "$POD_LOGS_PATH" "$CONTAINERD_PATH"; do
    if [[ $path = "$other" || $path = "$other"/* || $other = "$path"/* ]]; then
      die "[ERROR] Directory[\"$path\"] holds or is inside[\"$other\"], which this mounts onto"
    fi
  done

  return 0
}

# What the block in /etc/fstab was written from, whichever of the two it was:
# the first field of its first entry
configured_source() {
  sed -n "/^$FSTAB_BEGIN_MARKER\$/{n;p;}" "$FSTAB_PATH" | cut -d' ' -f1

  return 0
}

# is_configured does not look at what the node was set up from, so a node that
# was given another directory, or a device, would be reported as done
require_configured_from_directory_or_not_at_all() {
  local source
  source=$(configured_source)

  local error_msg="[ERROR] Ephemeral storage is already set up from[\"$source\"], not from directory[\"$path\"]."
  error_msg+=" Take the node out with remove-node and add it back with add-node"
  [[ -n $source && $source != "$path" ]] && die "$error_msg"

  return 0
}

# A run that stopped part way has mounts up that mounting again would stack
# another on top of. reset-ephemeral-storage.sh finishes taking those apart
require_nothing_half_set_up() {
  local target
  for target in "$mount_path" "$KUBELET_PATH" "$POD_LOGS_PATH" "$CONTAINERD_PATH"; do
    if is_mountpoint "$target"; then
      die "[ERROR] Directory[\"$target\"] is already a mount point, left by a run that did not finish. Reset the node first"
    fi
  done

  return 0
}

# What the device gets by being formatted here has to be asked of a filesystem
# that is the site's.
#
# Not the root filesystem, which is what this exists to get the data off, and
# where a directory ends up when the disk meant for it is not mounted. ext4 or
# xfs, which is what containerd is run on; that also leaves out anything reached
# over the network and anything kept in memory. Mounted without ro, noexec,
# nosuid or nodev, since the root filesystems of the containers run from here.
#
# And mounted by a line of /etc/fstab, without _netdev. The bind mount waits for
# the filesystem at boot through the unit systemd makes of that line; a
# filesystem mounted by hand would not be there after a reboot, and the bind
# mount would be made from the empty directory underneath it. One that waits for
# the network is mounted after the local filesystems the bind mounts belong to
require_directory_filesystem() {
  local fs_target fs_type fs_options
  fs_target=$(findmnt -nro TARGET -T "$path")
  fs_type=$(findmnt -nro FSTYPE -T "$path")
  fs_options=$(findmnt -nro OPTIONS -T "$path")

  [[ $fs_target = / ]] &&
    die "[ERROR] Directory[\"$path\"] is on the root filesystem. Give a directory of another filesystem, and check that it is mounted"
  [[ $fs_type != ext4 && $fs_type != xfs ]] &&
    die "[ERROR] Directory[\"$path\"] is on a[\"$fs_type\"] filesystem, expected ext4 or xfs"

  local option
  for option in ro noexec nosuid nodev; do
    [[ ,$fs_options, = *,$option,* ]] &&
      die "[ERROR] Filesystem[\"$fs_target\"] is mounted with option[\"$option\"], which containers can not run under"
  done

  local fstab_options
  fstab_options=$(findmnt --fstab -nro OPTIONS --mountpoint "$fs_target") ||
    die "[ERROR] Filesystem[\"$fs_target\"] has no line in $FSTAB_PATH. It has to be mounted from there at boot, before the bind mounts"
  [[ ,$fstab_options, = *,_netdev,* ]] &&
    die "[ERROR] Filesystem[\"$fs_target\"] is mounted with option[\"_netdev\"] in $FSTAB_PATH. Give a directory of a local disk"

  return 0
}

# Looked at through the directory itself, before anything is mounted. A link is
# refused because the data would be kept where it points, and the reset, which
# does not follow one, would leave that data in place
require_directory_subdirectories_unused() {
  local entry
  for entry in "${BIND_MOUNTS[@]}"; do
    [[ -L $path/${entry%%:*} ]] &&
      die "[ERROR] File[\"$path/${entry%%:*}\"] is a symbolic link. Remove it, or give another directory"
    require_directory_empty "$path/${entry%%:*}" \
      "It holds data of an earlier installation, or of something else. Empty it, or give another directory"
  done

  return 0
}

# The rest of a set up, the same from a device and from a directory
mount_all() {
  "$ki_opt_scripts_path"/systemctl.sh reload

  mkdir -p "$mount_path"
  mount "$mount_path"

  create_directories
  require_subdirectories_empty

  mount_bind_mounts
  share_kubelet_mount
  create_drop_in_files

  return 0
}

is_configured() {
  grep -qF "$FSTAB_BEGIN_MARKER" "$FSTAB_PATH" || return 1
  is_mountpoint "$mount_path" || return 1

  local entry
  for entry in "${BIND_MOUNTS[@]}"; do
    is_mountpoint "${entry#*:}" || return 1
  done

  return 0
}

require_block_device() {
  [[ ! -e $device ]] && die "[ERROR] No such file or directory of which path is \"$device\""
  [[ ! -b $device ]] && die "[ERROR] File[\"$device\"] is not a block device"

  return 0
}

# The bind mounts have to be in place before either service writes anything, or
# what it wrote lands on the root filesystem and is then hidden by the mount,
# occupying a disk nothing reports on any more
require_runtimes_not_enabled() {
  local svc_name
  local error_msg
  for svc_name in "${SVC_NAMES[@]}"; do
    if [[ $("$ki_opt_scripts_path"/systemctl.sh is-enabled "$svc_name") = "true" ]]; then
      error_msg="[ERROR] Service[\"$svc_name\"] already enabled."
      error_msg+=" Ephemeral storage is set up while the node is provisioned, not afterwards."
      error_msg+=" Take the node out with remove-node and add it back with add-node"
      die "$error_msg"
    fi
  done

  return 0
}

require_bind_mount_targets_empty() {
  local entry
  for entry in "${BIND_MOUNTS[@]}"; do
    require_directory_empty "${entry#*:}" \
      "It holds data that the bind mount would hide. See docs/impl-notes.adoc"
  done

  return 0
}

require_subdirectories_empty() {
  local reason="Device[\"$device\"] holds data of an earlier installation."
  reason+=" Wipe it with \"wipefs -a $device\" to reuse the device"
  [[ -n $path ]] && reason="Directory[\"$path\"] holds data of an earlier installation"

  local entry
  for entry in "${BIND_MOUNTS[@]}"; do
    require_directory_empty "$mount_path/${entry%%:*}" "$reason"
  done

  return 0
}

prepare_filesystem() {
  require_device_not_mounted
  require_no_partition_table

  local fs_type
  fs_type=$(probe_device TYPE)

  if [[ -n $fs_type ]]; then
    local error_msg="[ERROR] Device[\"$device\"] holds a[\"$fs_type\"] filesystem, expected[\"$FS_TYPE\"]."
    error_msg+=" Wipe it with \"wipefs -a $device\" to reuse the device"
    [[ $fs_type != "$FS_TYPE" ]] && die "$error_msg"
    # reset-ephemeral-storage.sh leaves the filesystem behind, so finding one here
    # is the ordinary state of a node that is being installed again
    msg "[INFO] Device[\"$device\"] already holds a $FS_TYPE filesystem. it is reused as is"

    return 0
  fi

  # The quota and project features are only settable while the filesystem is being
  # made. Nothing uses them yet, but turning them on later would mean reformatting
  # a disk that holds the cluster, and the kubelet feature that needs them is the
  # quota based ephemeral storage isolation. The prjquota mount option that
  # enforces them is deliberately not set
  mkfs."$FS_TYPE" -q -L "$FS_LABEL" -O quota,project -E quotatype=prjquota "$device"

  return 0
}

# A device carrying a partition table is either the whole disk of the node, which
# may well be the one the operating system runs on, or a disk someone else is
# using. Neither is something to format
require_no_partition_table() {
  local pt_type
  pt_type=$(probe_device PTTYPE)

  local error_msg="[ERROR] Device[\"$device\"] holds a[\"$pt_type\"] partition table."
  error_msg+=" Point at a partition of it, or wipe the device"

  [[ -n $pt_type ]] && die "$error_msg"

  return 0
}

require_device_not_mounted() {
  local target
  target=$(findmnt -nro TARGET --source "$device" | head -1) || target=""

  [[ -n $target ]] && die "[ERROR] Device[\"$device\"] is already mounted at[\"$target\"]"

  return 0
}

get_filesystem_uuid() {
  local uuid
  uuid=$(probe_device UUID)

  [[ -z $uuid ]] && die "[ERROR] Fail to get the uuid of device[\"$device\"]"

  echo "$uuid"

  return 0
}

# Probes the device itself rather than reading the blkid cache, which still holds
# what was there before the filesystem was made
probe_device() {
  local tag=$1

  local value
  value=$(blkid -p -s "$tag" -o value "$device" 2>/dev/null) || value=""

  echo "$value"

  return 0
}

# The device is recorded by uuid. A name like /dev/sdb is not stable across a
# reboot, and pointing the entry at whatever took the name would be worse than
# failing to mount
#
# nofail is deliberately absent. A node whose ephemeral storage did not mount has
# to fail to boot rather than come up and quietly write to the root filesystem
#
# systemd derives the dependency of a bind mount on its source from the source
# path, but requires-mounts-for says it outright rather than relying on the
# version of systemd the node happens to have
write_fstab_entries() {
  local mount_path_entry=$1

  remove_fstab_entries

  {
    echo "$FSTAB_BEGIN_MARKER"
    echo "$mount_path_entry"

    local entry
    for entry in "${BIND_MOUNTS[@]}"; do
      echo "$mount_path/${entry%%:*} ${entry#*:} none bind,x-systemd.requires-mounts-for=$mount_path 0 0"
    done

    echo "$FSTAB_END_MARKER"
  } >> "$FSTAB_PATH"

  return 0
}

# The whole block between the markers goes, so that writing it again replaces
# what an earlier run left rather than adding a second copy. The markers carry no
# slash, which is what lets the address range use the ordinary delimiter
remove_fstab_entries() {
  sed -i "/^$FSTAB_BEGIN_MARKER\$/,/^$FSTAB_END_MARKER\$/d" "$FSTAB_PATH"

  return 0
}

create_directories() {
  local entry
  for entry in "${BIND_MOUNTS[@]}"; do
    mkdir -p "$mount_path/${entry%%:*}"
    # /var/log/pods is created by kubelet the first time it runs, which is after
    # this, so the mount point has to be made here
    mkdir -p "${entry#*:}"
  done

  return 0
}

# Mounted by target so that the fstab entry written above is what gets used, which
# makes a mistake in it show up here rather than at the next reboot
mount_bind_mounts() {
  local entry
  for entry in "${BIND_MOUNTS[@]}"; do
    mount "${entry#*:}"
  done

  return 0
}

# Csi drivers mount volumes under the kubelet directory and need those mounts to
# propagate between the host and the container that creates them, which only
# happens while the mount is shared. A bind mount inherits the propagation of its
# parent and that is shared on the supported systems, but saying it here means the
# node does not depend on that being true. This does not outlive a reboot, after
# which the inherited propagation is what applies again
share_kubelet_mount() {
  mount --make-rshared "$KUBELET_PATH"

  return 0
}

create_drop_in_files() {
  local svc_name
  local drop_in_dir_path
  for svc_name in "${SVC_NAMES[@]}"; do
    drop_in_dir_path=/etc/systemd/system/"$svc_name".service.d
    mkdir -p "$drop_in_dir_path"
    cp -f "$SCRIPT_DIR_PATH"/templates/"$DROP_IN_FILE_NAME" "$drop_in_dir_path"/"$DROP_IN_FILE_NAME"
  done
  "$ki_opt_scripts_path"/systemctl.sh reload

  return 0
}

is_mountpoint() {
  local path=$1

  findmnt -nro TARGET --mountpoint "$path" > /dev/null 2>&1

  return $?
}

require_directory_empty() {
  local path=$1
  local reason=${2-}

  [[ ! -e $path ]] && return 0
  [[ ! -d $path ]] && die "[ERROR] File[\"$path\"] is not a directory"
  [[ -n $(find "$path" -mindepth 1 -maxdepth 1 -print -quit) ]] &&
    die "[ERROR] Directory[\"$path\"] is not empty. $reason"

  return 0
}

main
