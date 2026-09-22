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

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""
jinja2_cmd=""

main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory
  require_declared_binaries

  mkdir -p /etc/sudoers.d
  cp -f "$SCRIPT_DIR_PATH/templates/z-k8s-installer" /etc/sudoers.d/

  install_program helm
  install_program etcdctl
  install_program etcdutl
  install_program nerdctl

  return 0
}

install_program() {
  local program=$1

  cp -f "$ki_opt_bundle_path/bin/$program" "/usr/local/bin/$program"
  chown root:root "/usr/local/bin/$program"
  chmod 755 "/usr/local/bin/$program"
}

# Refuses a bundle whose binaries are not the ones release.yml names.
#
# Asking them is the only way. A package file carries its version inside it, but
# bundle/bin holds a file called "helm" and nothing about that name says which
# helm it is, which is exactly how a bundle ends up quietly holding another one.
#
# Every binary declared is checked rather than only the four this script lays
# down. What is being checked is the bundle, and yq and crane never leave it
require_declared_binaries() {
  local declared
  declared=$($yq_cmd '.ki_release_binaries // {} | to_entries | .[] | .key + " " + (.value | tostring)' < "$vars_path")
  [[ -z $declared ]] &&
    die "[ERROR] Variable[\"ki_release_binaries\"] of file[\"$vars_path\"] is empty. it is read from binaries of release.yml, so a vars file without it was not written by the playbooks of this release"

  local errors=""
  local name
  local version
  local found
  while read -r name version; do
    [[ -z $name ]] && continue

    if [[ ! -f "$ki_opt_bundle_path/bin/$name" ]]; then
      errors+="\n  binary[\"$name\"] is declared as version[\"$version\"] and is not in the bundle"
      continue
    fi

    found=$(binary_version "$name")
    [[ $found != "$version" ]] &&
      errors+="\n  binary[\"$name\"] is declared as version[\"$version\"] and the bundle holds version[\"${found:-unknown}\"]"
  done <<< "$declared"

  [[ -n $errors ]] &&
    die "[ERROR] The bundle does not hold what release[\"$($yq_cmd '.ki_release_version' < "$vars_path")\"] declares under binaries:$errors"

  return 0
}

# What a binary of bundle/bin answers when asked its version.
#
# Each one is asked its own way and answers in its own shape:
#
#   helm     v3.13.1+g3547a4b
#   etcdctl  etcdctl version: 3.5.23
#   crane    0.22.1
#   yq       yq (https://github.com/mikefarah/yq/) version v4.47.1
#   nerdctl  nerdctl version 2.1.5
#
# so the invocation is per tool and what is taken from the output is the first
# thing in it shaped like a version. A name this does not know stops the run
# rather than being passed over: adding a binary to release.yml means saying how
# it is asked, the same way adding a variable means saying what changing it does
binary_version() {
  local program=$1

  local output
  case $program in
  helm | crane | etcdctl | etcdutl)
    output=$("$ki_opt_bundle_path/bin/$program" version 2>&1) || true
    ;;
  yq | nerdctl)
    output=$("$ki_opt_bundle_path/bin/$program" --version 2>&1) || true
    ;;
  *)
    die "[ERROR] Binary[\"$program\"] is declared by release.yml and this script does not know how to ask its version. Add it to binary_version of install-programs.sh"
    ;;
  esac

  grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' <<< "$output" | head -1 | sed 's/^v//' || true

  return 0
}

import_ki_opt_vars() {
  ki_opt_root_path=$(grep -oP  "^ki_opt_root_path: \K(.+)" < "$vars_path")
  ki_opt_scripts_path=$(grep -oP  "^ki_opt_scripts_path: \K(.+)" < "$vars_path")
  ki_opt_bundle_path=$(grep -oP  "^ki_opt_bundle_path: \K(.+)" < "$vars_path")
  ki_opt_venv_path=$(grep -oP  "^ki_opt_venv_path: \K(.+)" < "$vars_path")
}

setup_cmd_vars() {
  yq_cmd="$ki_opt_bundle_path/bin/yq"
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
