#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--vars-path path]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--vars-path     File path
EOF
  exit
}

parse_params() {
  vars_path=""

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

# The two paths, which have to be the same in both scripts of this directory.
# See kernel-config-common.sh
source "$SCRIPT_DIR_PATH"/kernel-config-common.sh

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

jinja2_cmd=""

# Loads the kernel modules this node was told to load and sets the sysctls it was
# told to set, and keeps both across a reboot.
#
# What this is for is what a cni asks of a node. This installer brings kubernetes
# up and not the network on top of it, so the modules and sysctls kubernetes
# itself needs are written by configure-linux.sh while everything the layer above
# needs had nowhere to be declared - openvswitch and geneve for one cni, a
# conntrack or rp_filter setting for another. Run by hand instead, they are what a
# node quietly lacks after it has been rebuilt.
#
# Unlike the kernel command line, this is in force as soon as it has run: the
# module is loaded now and the file is what brings it back at the next boot. So
# nothing here asks for a reboot, and update-cluster.yml applies a change to a
# node that is already running
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  apply_modules
  apply_sysctls

  return 0
}

# Rendered first and loaded after, so that a module which can not be loaded is
# reported here rather than by a node that comes up without it after a reboot
# nobody was watching. The rendered file is read back for the list rather than the
# variables being read twice: what the node will boot with and what is loaded now
# are then the same text by construction
apply_modules() {
  render "$MODULES_LOAD_PATH" ki-kernel-modules.conf.j2 || {
    [[ -f $MODULES_LOAD_PATH ]] || return 0

    rm -f "$MODULES_LOAD_PATH"
    msg "[INFO] No kernel module is asked for any more. what is loaded stays loaded until this node is rebooted"

    return 0
  }

  local module
  while IFS= read -r module; do
    modprobe "$module" ||
      die "[ERROR] Failed to load kernelModule[\"$module\"] on this node"
  done < <(content_lines_of "$MODULES_LOAD_PATH")

  msg "[INFO] Loaded kernelModules[\"$(content_lines_of "$MODULES_LOAD_PATH" | tr '\n' ' ' | sed 's/ $//')\"]"

  return 0
}

# Written and then read back. "sysctl --system" reports a key it does not know and
# carries on, so its exit code says nothing about whether this node ended up
# holding what it was told; asking for each value afterwards does
apply_sysctls() {
  render "$SYSCTL_PATH" ki-sysctl.conf.j2 || {
    [[ -f $SYSCTL_PATH ]] || return 0

    rm -f "$SYSCTL_PATH"
    sysctl --system > /dev/null
    msg "[INFO] No sysctl is asked for any more. what this node holds stays until it is rebooted or set otherwise"

    return 0
  }

  sysctl --system > /dev/null

  local setting
  while IFS= read -r setting; do
    require_sysctl_applied "${setting%%=*}" "${setting#*=}"
  done < <(content_lines_of "$SYSCTL_PATH")

  msg "[INFO] Set sysctlCount[$(content_lines_of "$SYSCTL_PATH" | wc -l)]"

  return 0
}

# Renders the template and returns 1 when it came out with nothing in it, which
# is how an empty list and a list that was never there are told apart from a list
# with something in it. The file is only replaced once there is something to put
# in it, so a failed render leaves the node as it was
render() {
  local path=$1
  local template=$2

  mkdir -p "$(dirname "$path")"
  # Said here rather than left to errexit, which is not in force anywhere in this
  # function: bash turns it off for the whole body of a function called on the
  # left of a "||", and both callers call this one that way. A render that failed
  # would otherwise carry on to the emptiness check below and be read as a list
  # with nothing in it, which is what takes the file off the node - a broken venv
  # would quietly strip a node of every module and sysctl its cni asked for, and
  # say it had done what it was told
  $jinja2_cmd --format yaml -o "$path".tmp "$SCRIPT_DIR_PATH"/templates/"$template" "$vars_path" || {
    rm -f "$path".tmp
    die "[ERROR] Failed to render file[\"$path\"] from template[\"$template\"]"
  }

  if [[ -z $(content_lines_of "$path".tmp) ]]; then
    rm -f "$path".tmp
    return 1
  fi

  mv -f "$path".tmp "$path"

  return 0
}

# What the file says, without the line saying who wrote it and without the blank
# lines a template leaves behind
content_lines_of() {
  local path=$1

  [[ -f $path ]] || return 0
  grep -v '^[[:space:]]*\(#.*\)\?$' "$path" || true

  return 0
}

# A value with more than one field comes back separated by tabs, and the file may
# have been written with spaces, so both sides are squeezed before they are
# compared
require_sysctl_applied() {
  local key
  local want
  key=$(normalize_spaces "$1")
  want=$(normalize_spaces "$2")

  local path
  path=$(proc_path_of "$key")

  [[ -e $path ]] || die "[ERROR] Sysctl[\"$key\"] is not known to this node"

  # A key that can be set and not read - net.ipv4.route.flush is 0200, and root
  # is refused a read of it the same as anybody - has nothing to compare. Asking
  # anyway is how a value that did go in is reported as a node that never heard
  # of it
  [[ -r $path ]] || {
    msg "[INFO] Sysctl[\"$key\"] can be written and not read, so what it took was not read back"

    return 0
  }

  local got
  got=$(< "$path")

  [[ $(normalize_spaces "$got") = "$want" ]] ||
    die "[ERROR] Sysctl[\"$key\"] holds value[\"$got\"] rather than value[\"$want\"] after it was set"

  return 0
}

# The file a key names. sysctl takes either separator, and the two are not
# interchangeable in a key that already carries one: an interface whose name has
# a dot in it - a vlan, say - is only reachable by the slash spelling, and
# turning every dot of that into a slash would name a directory that is not there
proc_path_of() {
  local key=$1

  if [[ $key = */* ]]; then
    echo "/proc/sys/$key"

    return 0
  fi

  echo "/proc/sys/${key//./\/}"

  return 0
}

normalize_spaces() {
  tr -s '[:space:]' ' ' <<< "$1" | sed 's/^ //; s/ $//'

  return 0
}

import_ki_opt_vars() {
  ki_opt_root_path=$(grep -oP  "^ki_opt_root_path: \K(.+)" < "$vars_path")
  ki_opt_scripts_path=$(grep -oP  "^ki_opt_scripts_path: \K(.+)" < "$vars_path")
  ki_opt_bundle_path=$(grep -oP  "^ki_opt_bundle_path: \K(.+)" < "$vars_path")
  ki_opt_venv_path=$(grep -oP  "^ki_opt_venv_path: \K(.+)" < "$vars_path")
}

setup_cmd_vars() {
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
