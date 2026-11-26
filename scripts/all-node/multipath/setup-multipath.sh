#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--vars-path path] [--check]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--vars-path     File path
--check         Refuse what this would refuse and change nothing
EOF
  exit
}

parse_params() {
  vars_path=""
  check="false"

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
    --check) check="true" ;;
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

# The paths and the restore, which have to be the same in both scripts of this
# directory. See multipath-common.sh
source "$SCRIPT_DIR_PATH"/multipath-common.sh

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""
jinja2_cmd=""

multipath_enabled=""
state_path=""

# Writes the multipath configuration of this node and brings multipathd up
# under it, or takes both away again, as multipath_enabled of the node says.
#
# What this is for is a volume that reaches a node over more than one path - a
# lun behind two controllers, two fabrics, two portals. Without multipath the
# node sees it as that many unrelated disks, and whatever opens one of them
# loses the volume when that one path goes.
#
# The file is written whole, and it names what to bring together rather than
# what to leave alone: every device is excluded, and the ones of
# multipath_devices are excepted from that. The other way round is a list of
# the local disks of each node, which is a list that is different on every
# machine and wrong the day a disk is added. A device nobody named is then one
# multipath does not touch - the disk the node boots from, an nvme drive, the
# device given to ephemeral_storage_device.
#
# Which is also the one way this can hurt: a node that already runs something
# on a multipath map whose device is not named would, at its next boot, find
# that map gone. So the maps a node holds are looked at before the file is
# written, and a node holding one made of devices the new file excludes is
# refused. The same question is asked with --check, before anything is changed
# anywhere.
#
# A node the variable is off for is left exactly as it is, unless this
# installer was what wrote its configuration. Then turning the variable off puts
# the node back - the file it held, or none, and the unit as it was - which is
# refused while the node holds a map, since a map is a volume something is using
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  multipath_enabled=$($yq_cmd '.multipath_enabled // false' < "$vars_path")
  state_path="$($yq_cmd '.ki_etc_root_path' < "$vars_path")/$MULTIPATH_STATE_DIR_NAME"

  if [[ $multipath_enabled != "true" ]]; then
    turn_off
    return 0
  fi

  require_maps_stay_named

  [[ $check = "true" ]] && return 0

  require_multipath_installed

  [[ -d $state_path ]] || remember_node_state

  local conf_changed="false"
  write_multipath_conf && conf_changed="true"

  systemctl enable "$MULTIPATHD_UNIT" > /dev/null 2>&1 ||
    die "[ERROR] Failed to enable unit[\"$MULTIPATHD_UNIT\"]"

  # A daemon that is already up is told to read the file again, which adds and
  # drops maps to match it and leaves the ones that did not change where they
  # are. Restarting it would do the same with a gap in the middle during which
  # nothing answers for a path that fails
  if [[ $(multipath_unit_active_word "$MULTIPATHD_UNIT") = "active" ]]; then
    if [[ $conf_changed = "true" ]]; then
      multipathd reconfigure > /dev/null ||
        die "[ERROR] Failed to have multipathd read file[\"$MULTIPATH_CONF_PATH\"] again"
    fi
  else
    systemctl start "$MULTIPATHD_UNIT"
  fi

  [[ $(multipath_unit_active_word "$MULTIPATHD_UNIT") = "active" ]] ||
    die "[ERROR] Unit[\"$MULTIPATHD_UNIT\"] is not active after it was started"

  msg "[INFO] multipathd of this node runs with file[\"$MULTIPATH_CONF_PATH\"] of this installer, holding multipathMapCount[$(multipath_map_count)]"

  return 0
}

turn_off() {
  [[ -d $state_path ]] || return 0

  local maps
  maps=$(multipath_map_count)
  [[ $maps -gt 0 ]] &&
    die "[ERROR] Variable[\"multipath_enabled\"] is off for this node and the node holds multipathMapCount[$maps]. A map is a volume something is using, so multipath is not turned off under it. Take the volumes off this node first, or turn the variable back on"

  [[ $check = "true" ]] && return 0

  multipath_restore_node_state "$state_path"

  msg "[INFO] multipath of this node is as it was before this installer turned it on"

  return 0
}

# Refuses a node holding a map that the file about to be written would no
# longer bring together.
#
# The vendor and the product of every path of every map are read from sysfs and
# matched against multipath_devices the way multipath itself matches them: as
# extended regular expressions, found anywhere in the string. An nvme path has
# no vendor file, and multipath calls the vendor of every one of them NVME
require_maps_stay_named() {
  # Two lists read side by side rather than one of pairs. yq is not jq here:
  # ".[] | .vendor, .product" prints every vendor and then every product
  # whichever way it is bracketed, so a pair read off consecutive lines is the
  # vendor of one device against the vendor of the next
  local vendor_regexes=() product_regexes=()
  mapfile -t vendor_regexes < <($yq_cmd '.multipath_devices // [] | .[] | .vendor' < "$vars_path")
  mapfile -t product_regexes < <($yq_cmd '.multipath_devices // [] | .[] | .product' < "$vars_path")

  local errors=""
  local dm name slave vendor product
  while read -r dm name; do
    [[ -z $dm ]] && continue

    for slave in /sys/block/"$dm"/slaves/*; do
      [[ -e $slave ]] || continue

      vendor=$(read_trimmed "$slave/device/vendor")
      product=$(read_trimmed "$slave/device/model")
      [[ -z $vendor && $(basename "$slave") = nvme* ]] && vendor="NVME"

      [[ $(is_named_device "$vendor" "$product") = "true" ]] && continue

      errors+="\n  map[\"$name\"] path[\"$(basename "$slave")\"] vendor[\"$vendor\"] product[\"$product\"]"
    done
  done < <(multipath_maps)

  [[ -n $errors ]] &&
    die "[ERROR] This node holds a multipath map made of a device variable[\"multipath_devices\"] does not name. The configuration this installer writes excludes every device it is not told of, so that map would not be brought together again at the next boot. Name the device in multipath_devices, or take the map off the node first:$errors"

  return 0
}

# Reads vendor_regexes and product_regexes of the caller, which bash lets a
# function do: entry i of one belongs with entry i of the other
is_named_device() {
  local vendor=$1
  local product=$2

  local i
  for i in "${!vendor_regexes[@]}"; do
    if [[ $vendor =~ ${vendor_regexes[$i]} && $product =~ ${product_regexes[$i]} ]]; then
      echo "true"
      return 0
    fi
  done

  echo "false"

  return 0
}

# What a sysfs attribute holds, without the padding scsi fills its fixed width
# fields with
read_trimmed() {
  local path=$1

  [[ -r $path ]] || return 0
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "$path"

  return 0
}

# Written to a directory beside the real one and moved into place, so that the
# directory is never there half filled: its presence is what every later run
# reads as "the file is ours, and what the node held before is in here"
remember_node_state() {
  rm -rf "$state_path".tmp
  mkdir -p "$state_path".tmp

  if [[ -f $MULTIPATH_CONF_PATH ]]; then
    cp -p "$MULTIPATH_CONF_PATH" "$state_path".tmp/multipath.conf.orig
  fi

  local unit
  while read -r unit; do
    [[ -z $unit ]] && continue
    echo "$unit $(multipath_unit_enabled_word "$unit") $(multipath_unit_active_word "$unit")"
  done < <(multipath_unit_names) > "$state_path".tmp/units-before

  mv "$state_path".tmp "$state_path"

  return 0
}

# Renders multipath.conf and returns 0 when that changed the file and 1 when it
# did not.
#
# The file that was there is kept until multipath has read the new one without
# complaint. multipath does not refuse a keyword it does not know - it logs the
# line and carries on with the rest - so a misspelt key of multipath_defaults
# is a setting that is quietly not in force, and the only place it is said is
# the output of a command nobody runs. It is run here, and a file multipath
# complains about is taken back off the node.
#
# Every step says what it does when it fails rather than leaving that to
# errexit, which is not in force anywhere in this function: bash turns it off
# for the whole body of a function called on the left of a "&&", and that is
# how the caller reads the answer
write_multipath_conf() {
  local rendered="$MULTIPATH_CONF_PATH".ki-tmp
  $jinja2_cmd --format yaml -o "$rendered" "$SCRIPT_DIR_PATH"/templates/multipath.conf.j2 "$vars_path" || {
    rm -f "$rendered"
    die "[ERROR] Failed to render file[\"$MULTIPATH_CONF_PATH\"]"
  }

  if cmp -s "$rendered" "$MULTIPATH_CONF_PATH"; then
    rm -f "$rendered"
    return 1
  fi

  local previous="$MULTIPATH_CONF_PATH".ki-previous
  rm -f "$previous"
  if [[ -f $MULTIPATH_CONF_PATH ]]; then
    cp -p "$MULTIPATH_CONF_PATH" "$previous" ||
      die "[ERROR] Failed to copy file[\"$MULTIPATH_CONF_PATH\"]"
  fi

  chmod 0644 "$rendered"
  mv -f "$rendered" "$MULTIPATH_CONF_PATH" ||
    die "[ERROR] Failed to write file[\"$MULTIPATH_CONF_PATH\"]"

  local complaints
  complaints=$(multipath -t 2>&1 > /dev/null | grep -F "$MULTIPATH_CONF_PATH" || true)
  if [[ -n $complaints ]]; then
    if [[ -f $previous ]]; then
      mv -f "$previous" "$MULTIPATH_CONF_PATH"
    else
      rm -f "$MULTIPATH_CONF_PATH"
    fi
    die "[ERROR] multipath does not take the file rendered from variable[\"multipath_defaults\"] and variable[\"multipath_devices\"], so it was not left on this node:\n$complaints"
  fi

  rm -f "$previous"

  return 0
}

require_multipath_installed() {
  local result
  result=$("$ki_opt_scripts_path"/systemctl.sh exists "$MULTIPATHD_UNIT")

  [[ $result = "false" ]] && die "[ERROR] Service[\"$MULTIPATHD_UNIT\"] not installed. execute \"install-packages.sh\" first"

  return 0
}

import_ki_opt_vars() {
  ki_opt_root_path=$(grep -oP  "^ki_opt_root_path: \K(.+)" < "$vars_path")
  ki_opt_scripts_path=$(grep -oP  "^ki_opt_scripts_path: \K(.+)" < "$vars_path")
  ki_opt_bundle_path=$(grep -oP  "^ki_opt_bundle_path: \K(.+)" < "$vars_path")
  ki_opt_venv_path=$(grep -oP  "^ki_opt_venv_path: \K(.+)" < "$vars_path")
}

setup_cmd_vars() {
  yq_cmd="$ki_opt_bundle_path/bin/$(uname -m)/yq"
  jinja2_cmd="$ki_opt_venv_path/bin/jinja2"
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
