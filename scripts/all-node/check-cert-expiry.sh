#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--days n] path...
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--days          Report certificates that expire within this many days
path...         Certificate files, or directories to search for *.crt in.
                A path that does not exist is skipped
EOF
  exit
}

parse_params() {
  days=""

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --days)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      days="${2-}"
      [[ ! $days =~ ^[0-9]+$ ]] && die "[ERROR] Value for --days option must be number"
      shift
      ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ -z "${days-}" ]] && die "[ERROR] Missing required option: --days"
  [[ ${#args[@]} -eq 0 ]] && die "[ERROR] Missing required argument: path"

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

# Reports certificates that are close to expiring, one line per certificate, and
# says nothing when there is nothing to say. It never fails on an expiring
# certificate, because the playbooks that would fix one have to be able to run.
#
# The certificates of the cluster and the ones of the installer expire on very
# different scales. Those kubeadm issues last three years and are renewed in
# place, while the ki pki lasts ten and its ca and its leaf expire together, which
# leaves rebuilding the cluster as the answer rather than a rotation. Either way
# the deadline is only useful if it is seen coming, which is all this does.
#
# Certificates embedded in the kubeconfig files are not covered here. They are
# issued with the rest, so the files under the pki directory stand in for them,
# and "kubeadm certs check-expiration" reports them exactly
main() {
  local path
  for path in "${args[@]}"; do
    [[ ! -e $path ]] && continue

    if [[ -d $path ]]; then
      local crt
      while IFS= read -r crt; do
        [[ -n $crt ]] && report_if_expiring "$crt"
      done < <(find "$path" -type f -name '*.crt' | sort)
      continue
    fi

    report_if_expiring "$path"
  done

  return 0
}

report_if_expiring() {
  local crt=$1

  local not_after
  not_after=$(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | cut -d= -f2-) || return 0
  [[ -z $not_after ]] && return 0

  local days_left
  days_left=$(( ($(date -d "$not_after" +%s) - $(date +%s)) / 86400 ))

  [[ $days_left -gt $days ]] && return 0

  if [[ $days_left -lt 0 ]]; then
    echo "[WARN] Certificate[\"$crt\"] expired $(( -days_left )) days ago, on $(date -d "$not_after" +%F)"
  else
    echo "[WARN] Certificate[\"$crt\"] expires in $days_left days, on $(date -d "$not_after" +%F)"
  fi

  return 0
}

main
