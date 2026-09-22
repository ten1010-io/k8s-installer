#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--days n] [--metrics-path path] path...
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--days          Report certificates that expire within this many days
--metrics-path  Also write every certificate found to this file, in the
                prometheus text format a node exporter textfile collector reads
path...         Certificate files, or directories to search for *.crt in.
                A path that does not exist is skipped
EOF
  exit
}

parse_params() {
  days=""
  metrics_path=""

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
    --metrics-path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      metrics_path="${2-}"
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
# With --metrics-path it also writes every certificate it found to a file, in the
# prometheus text format, so that the same measurement is there for a monitoring
# system to read rather than only for whoever is running the playbook. The report
# is about the ones that are close and the file is about all of them.
#
# Certificates embedded in the kubeconfig files are not covered here. They are
# issued with the rest, so the files under the pki directory stand in for them,
# and "kubeadm certs check-expiration" reports them exactly
main() {
  [[ -n $metrics_path ]] && begin_metrics_file

  local path
  for path in "${args[@]}"; do
    [[ ! -e $path ]] && continue

    if [[ -d $path ]]; then
      local crt
      while IFS= read -r crt; do
        [[ -n $crt ]] && read_certificate "$crt"
      done < <(find "$path" -type f -name '*.crt' | sort)
      continue
    fi

    read_certificate "$path"
  done

  [[ -n $metrics_path ]] && publish_metrics_file

  return 0
}

# Every certificate is measured, and what is done with the measurement is where
# the two consumers part: the report is only about the ones that are close, and
# the metrics file carries all of them so that a dashboard can show a deadline
# that is still years away
read_certificate() {
  local crt=$1

  local not_after
  not_after=$(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | cut -d= -f2-) || return 0
  [[ -z $not_after ]] && return 0

  local expires_at
  expires_at=$(date -d "$not_after" +%s)

  report_if_expiring "$crt" "$expires_at"
  [[ -n $metrics_path ]] && write_metric "$crt" "$expires_at"

  return 0
}

report_if_expiring() {
  local crt=$1
  local expires_at=$2

  local days_left
  days_left=$(( (expires_at - $(date +%s)) / 86400 ))

  [[ $days_left -gt $days ]] && return 0

  if [[ $days_left -lt 0 ]]; then
    echo "[WARN] Certificate[\"$crt\"] expired $(( -days_left )) days ago, on $(date -d "@$expires_at" +%F)"
  else
    echo "[WARN] Certificate[\"$crt\"] expires in $days_left days, on $(date -d "@$expires_at" +%F)"
  fi

  return 0
}

# The expiry as a point in time rather than as days left. A gauge counting down
# is only right at the moment it is written, which would make the file wrong the
# day after. An absolute time stays true while it sits there, and how long is
# left is the subtraction whoever reads it is already doing.
#
# That is also why nothing refreshes this file on a schedule. The value moves
# only when a certificate is issued or renewed, and both of those are a playbook
# that comes through here on its way past
begin_metrics_file() {
  mkdir -p "$(dirname "$metrics_path")"

  cat > "$metrics_path".tmp <<EOF
# HELP ki_certificate_not_after_seconds Unix time at which the certificate expires
# TYPE ki_certificate_not_after_seconds gauge
EOF

  return 0
}

write_metric() {
  local crt=$1
  local expires_at=$2

  echo "ki_certificate_not_after_seconds{path=\"$crt\"} $expires_at" >> "$metrics_path".tmp

  return 0
}

# The move is what makes the file appear whole. A textfile collector reads
# whatever is there when it is scraped, so a file being appended to in place is
# read half written, and the metrics of that node disappear and come back for
# reasons that have nothing to do with its certificates
publish_metrics_file() {
  chmod 0644 "$metrics_path".tmp
  mv -f "$metrics_path".tmp "$metrics_path"

  return 0
}

main
