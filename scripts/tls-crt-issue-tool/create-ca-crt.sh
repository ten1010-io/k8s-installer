#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--cn name] [--days arg] [-o path]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--cn            Common name
--days          Specifies the number of days until a newly generated certificate expires
-o              Output path
EOF
  exit
}

parse_params() {
  common_name=""
  days=3650
  output_path="$SCRIPT_DIR_PATH"/output

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --cn)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      common_name="${2-}"
      shift
      ;;
    --days)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      days="${2-}"
      [[ ! $days =~ ^[0-9]+$ ]] && die "[ERROR] Value for --days option must be number"
      shift
      ;;
    -o)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      output_path="${2-}"
      shift
      ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ -z "${common_name-}" ]] && die "[ERROR] Missing required option: --cn"

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

TEMPLATES_PATH=$SCRIPT_DIR_PATH/templates

main() {
  mkdir -p "$output_path"

  [[ -e "$output_path"/ca.crt ]] && die "[ERROR] File[\"$output_path/ca.crt\"] already exists"

  cp -f "$TEMPLATES_PATH"/ca.conf "$output_path"
  sed -i 's/CN =/CN = '"$common_name"'/g' "$output_path/ca.conf"
  openssl req -x509 -out "$output_path/ca.crt" -keyout "$output_path/ca.key" -config "$output_path/ca.conf" -newkey rsa -days "$days"
}

main
