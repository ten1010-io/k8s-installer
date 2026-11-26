#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--vars-path path] [--check] [--new-initiator-name]
Available options:
-h, --help              Print this help and exit
-v, --verbose           Print script debug info
--vars-path             File path
--check                 Refuse what this would refuse and change nothing
--new-initiator-name    Give this node a new initiator name, whatever it holds
EOF
  exit
}

parse_params() {
  vars_path=""
  check="false"
  new_initiator_name="false"

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
    --new-initiator-name) new_initiator_name="true" ;;
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

# The paths and the restore, which have to be the same in every script of this
# directory. See iscsi-initiator-common.sh
source "$SCRIPT_DIR_PATH"/iscsi-initiator-common.sh

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

os_info=""
os_distribution=""
os_major_version=""
os_minor_version=""

iscsi_initiator_enabled=""
state_path=""
login_unit=""

# Makes this node an iscsi initiator, or stops it being one, as
# iscsi_initiator_enabled of the node says.
#
# What this is for is a volume that reaches a node as a lun. Something above
# this installer attaches it - a csi driver, usually - and what that needs of a
# node is the same whoever makes it: the daemon up, a name the storage system can
# tell this node by, and the timeouts the site wants a session to run with. Left
# to be done by hand, it is done after the node has joined, and whatever reads
# the name of a node when it starts has by then started without one. Done here,
# while the node is being built, the order is right by construction.
#
# Three things, all of them only on a node the variable is on for:
#
#   the name      Made when the node has none, and left alone when it has one. It
#                 is how a storage system knows the node, so a node keeps the one
#                 it has for as long as it holds a session under it.
#                 --new-initiator-name is how a node that was found sharing its
#                 name with another is given its own; see
#                 plan-iscsi-initiator-names.py for who decides that
#   the settings  iscsi_initiator_settings, laid over the iscsid.conf the node
#                 held. A session reads them when it is made, so a setting
#                 changed here reaches the sessions made after it
#   the daemon    iscsid enabled and started, and the unit that logs back in at
#                 boot enabled
#
# A node the variable is off for is left exactly as it is, unless this
# installer was what turned its initiator on. Then turning the variable off puts
# the node back: the configuration and the units as they were before. That is
# refused while the node holds a session, since a session is a volume something
# is using
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory
  get_os_version

  iscsi_initiator_enabled=$($yq_cmd '.iscsi_initiator_enabled // false' < "$vars_path")
  state_path="$($yq_cmd '.ki_etc_root_path' < "$vars_path")/$ISCSI_STATE_DIR_NAME"
  login_unit=$(iscsi_login_unit_of "$os_distribution")

  if [[ $os_distribution = "ubuntu" && $os_major_version = "22.04" && $os_minor_version -le "$UBUNTU2204_SUPPORTED_MINOR_VERSION" ]]; then
    ubuntu2204_setup
    exit 0
  fi

  if [[ $os_distribution = "ubuntu" && $os_major_version = "24.04" && $os_minor_version -le "$UBUNTU2404_SUPPORTED_MINOR_VERSION" ]]; then
    ubuntu2404_setup
    exit 0
  fi

  if [[ $os_distribution = "rhel" && $os_major_version = "8" && $os_minor_version -le "$RHEL8_SUPPORTED_MINOR_VERSION" ]]; then
    rhel8_setup
    exit 0
  fi

  if [[ $os_distribution = "rhel" && $os_major_version = "9" && $os_minor_version -le "$RHEL9_SUPPORTED_MINOR_VERSION" ]]; then
    rhel9_setup
    exit 0
  fi

  if [[ $os_distribution = "rhel" && $os_major_version = "10" && $os_minor_version -le "$RHEL10_SUPPORTED_MINOR_VERSION" ]]; then
    rhel10_setup
    exit 0
  fi

  die "[ERROR] OS not supported\n$os_info"
}

ubuntu2204_setup() {
  apply
}

ubuntu2404_setup() {
  apply
}

rhel8_setup() {
  apply
}

rhel9_setup() {
  apply
}

rhel10_setup() {
  apply
}

apply() {
  if [[ $iscsi_initiator_enabled != "true" ]]; then
    turn_off
    return 0
  fi

  # A name is only replaced under a node that is using it for nothing. The
  # storage system on the other end knows the node by the old one, and what it
  # granted that name is not granted to the new
  if [[ $new_initiator_name = "true" && $(iscsi_session_count) -gt 0 ]]; then
    die "[ERROR] This node holds iscsiSessionCount[$(iscsi_session_count)], so its initiator name can not be replaced: the storage system knows the node by the name those sessions were made under"
  fi

  [[ $check = "true" ]] && return 0

  require_initiator_installed

  local newly_ours="false"
  if [[ ! -d $state_path ]]; then
    remember_node_state
    newly_ours="true"
  fi

  local was_active
  was_active=$(iscsi_unit_active_word "$ISCSID_UNIT")

  local renamed="false"
  if [[ $new_initiator_name = "true" || -z $(iscsi_initiator_name) ]]; then
    write_initiator_name
    renamed="true"
  fi

  local conf_changed="false"
  write_iscsid_conf && conf_changed="true"

  systemctl enable "$ISCSID_UNIT" "$login_unit" > /dev/null 2>&1 ||
    die "[ERROR] Failed to enable unit[\"$ISCSID_UNIT\"] and unit[\"$login_unit\"]"

  # iscsid reads its name and its own settings once, as it starts. A daemon
  # that was already up is started again for either; the sessions it holds are
  # the kernel's and stay where they are across that
  if [[ $was_active = "active" && ($renamed = "true" || $conf_changed = "true") ]]; then
    systemctl restart "$ISCSID_UNIT"
  else
    systemctl start "$ISCSID_UNIT"
  fi

  [[ $(iscsi_unit_active_word "$ISCSID_UNIT") = "active" ]] ||
    die "[ERROR] Unit[\"$ISCSID_UNIT\"] is not active after it was started"

  # The one line of stdout, read by the playbook. It says the name of this node
  # is one nothing that was already running has read: the node was not an
  # initiator of this installer before, or it was and has just been renamed
  if [[ $newly_ours = "true" || $renamed = "true" ]]; then
    echo "initiator-name-is-new"
  fi

  msg "[INFO] This node is an iscsi initiator named initiatorName[\"$(iscsi_initiator_name)\"]"

  return 0
}

turn_off() {
  [[ -d $state_path ]] || return 0

  local sessions
  sessions=$(iscsi_session_count)
  [[ $sessions -gt 0 ]] &&
    die "[ERROR] Variable[\"iscsi_initiator_enabled\"] is off for this node and the node holds iscsiSessionCount[$sessions]. A session is a volume something is using, so the initiator is not turned off under it. Take the volumes off this node first, or turn the variable back on"

  [[ $check = "true" ]] && return 0

  iscsi_restore_node_state "$state_path"

  msg "[INFO] The iscsi initiator of this node is as it was before this installer turned it on"

  return 0
}

# Written to a directory beside the real one and moved into place, so that the
# directory is never there half filled: its presence is what every later run
# reads as "the node is ours, and what it was before is in here"
remember_node_state() {
  [[ -f $ISCSID_CONF_PATH ]] ||
    die "[ERROR] No such file of which path is \"$ISCSID_CONF_PATH\", which the package of the initiator lays down"

  rm -rf "$state_path".tmp
  mkdir -p "$state_path".tmp

  cp -p "$ISCSID_CONF_PATH" "$state_path".tmp/iscsid.conf.orig

  local unit
  while read -r unit; do
    [[ -z $unit ]] && continue
    echo "$unit $(iscsi_unit_enabled_word "$unit") $(iscsi_unit_active_word "$unit")"
  done < <(iscsi_unit_names) > "$state_path".tmp/units-before

  mv "$state_path".tmp "$state_path"

  return 0
}

write_initiator_name() {
  command -v iscsi-iname > /dev/null ||
    die "[ERROR] Command[\"iscsi-iname\"] not found, which the package of the initiator lays down. execute \"install-packages.sh\" first"

  local name
  name=$(iscsi-iname)
  [[ -n $name ]] || die "[ERROR] Command[\"iscsi-iname\"] printed no name"

  (
    umask 077
    printf 'InitiatorName=%s\n' "$name" > "$INITIATOR_NAME_PATH".tmp
  )
  mv -f "$INITIATOR_NAME_PATH".tmp "$INITIATOR_NAME_PATH"

  return 0
}

# Renders iscsid.conf as the one the node held with iscsi_initiator_settings
# laid over it, and returns 0 when that changed the file and 1 when it did not.
#
# Started from the copy taken before this installer touched the node rather
# than from the file as it is, so that a setting taken out of the variable is a
# setting gone from the node: the render has no memory of the one before it.
#
# A key the variable names is taken out of the copy wherever it is assigned and
# written once at the end. iscsid would take the last assignment either way;
# leaving the first in place is how a person reading the file finds the value
# that is not in force.
#
# Every step says what it does when it fails rather than leaving that to
# errexit, which is not in force anywhere in this function: bash turns it off
# for the whole body of a function called on the left of a "&&", and that is
# how the caller reads the answer
write_iscsid_conf() {
  local settings
  settings=$($yq_cmd '.iscsi_initiator_settings // {} | to_entries | .[] | .key + "=" + (.value | tostring)' < "$vars_path") ||
    die "[ERROR] Failed to read variable[\"iscsi_initiator_settings\"] of file[\"$vars_path\"]"

  local rendered="$ISCSID_CONF_PATH".ki-tmp
  cp -p "$state_path/iscsid.conf.orig" "$rendered" ||
    die "[ERROR] Failed to copy file[\"$state_path/iscsid.conf.orig\"]"

  if [[ -n $settings ]]; then
    awk -v keys="$(cut -d= -f1 <<< "$settings")" '
      BEGIN {
        count = split(keys, list, "\n")
        for (i = 1; i <= count; i++) owned[list[i]] = 1
      }
      {
        line = $0
        sub(/^[ \t]+/, "", line)
        separator = index(line, "=")
        if (line !~ /^#/ && separator > 0) {
          key = substr(line, 1, separator - 1)
          sub(/[ \t]+$/, "", key)
          if (key in owned) next
        }
        print
      }' "$state_path/iscsid.conf.orig" > "$rendered" ||
      die "[ERROR] Failed to render file[\"$ISCSID_CONF_PATH\"]"

    {
      echo ""
      echo "# Written by k8s-installer. iscsi_initiator_settings of this node"
      local setting
      while IFS= read -r setting; do
        echo "${setting%%=*} = ${setting#*=}"
      done <<< "$settings"
    } >> "$rendered"
  fi

  if cmp -s "$rendered" "$ISCSID_CONF_PATH"; then
    rm -f "$rendered"
    return 1
  fi

  mv -f "$rendered" "$ISCSID_CONF_PATH" ||
    die "[ERROR] Failed to write file[\"$ISCSID_CONF_PATH\"]"

  return 0
}

require_initiator_installed() {
  local result
  result=$("$ki_opt_scripts_path"/systemctl.sh exists "$ISCSID_UNIT")

  [[ $result = "false" ]] && die "[ERROR] Service[\"$ISCSID_UNIT\"] not installed. execute \"install-packages.sh\" first"

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
