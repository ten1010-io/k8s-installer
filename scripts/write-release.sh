#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--root-path path] [--version version]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--root-path     Directory path
--version       Release version to stamp onto the node
EOF
  exit
}

parse_params() {
  ki_opt_root_path=""
  version=""

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --root-path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      ki_opt_root_path="${2-}"
      shift
      ;;
    --version)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      version="${2-}"
      shift
      ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ -z "${ki_opt_root_path-}" ]] && die "[ERROR] Missing required option: --root-path"
  [[ -z "${version-}" ]] && die "[ERROR] Missing required option: --version"

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

KI_OPT_SCRIPTS_PATH="$ki_opt_root_path"/scripts
KI_OPT_BUNDLE_PATH="$ki_opt_root_path"/bundle
KI_OPT_VENV_PATH="$ki_opt_root_path"/venv
KI_OPT_RELEASE_PATH="$ki_opt_root_path"/release

# The release file marks the node as holding a complete deployment, so it is
# written only after everything else it claims is in place. A node that failed
# part way through keeps no file and is reported as not deployed rather than as
# running the release it never finished installing
main() {
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  printf '%s\n' "$version" > "$KI_OPT_RELEASE_PATH"

  msg "[INFO] Release[\"$version\"] written to \"$KI_OPT_RELEASE_PATH\""

  return 0
}

validate_ki_opt_directory() {
  require_directory_exists "$KI_OPT_SCRIPTS_PATH"
  require_directory_exists "$KI_OPT_BUNDLE_PATH"
  require_directory_exists "$KI_OPT_VENV_PATH"

  return 0
}

require_directory_exists() {
  local path=$1

  [[ ! -e $path ]] && die "[ERROR] No such file or directory of which path is \"$path\""
  [[ ! -d $path ]] && die "[ERROR] File[\"$path\"] is not a directory"

  return 0
}

main
