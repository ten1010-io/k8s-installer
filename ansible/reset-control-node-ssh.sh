#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
EOF
  exit
}

parse_params() {
  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

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

public_key=""

# The inverse of configure-control-node-ssh.sh, limited to what that script added
# on purpose. The key pair is left in place because it may predate the installer
# and be used for other things, and PermitRootLogin is left alone because
# tightening it from here could lock the operator out of a node they still need
main() {
  require_id_rsa_pub
  reset_authorized_keys

  msg "[INFO] SSH of control node reset successfully"
  msg ""
  msg "[INFO] The key pair[\"~/.ssh/id_rsa\"] and the sshd configuration were left"
  msg "[INFO] untouched. Remove them by hand if they are no longer needed"
  msg ""
  print_how_to_reset_managed_node_ssh

  return 0
}

require_id_rsa_pub() {
  [[ ! -e ~/.ssh/id_rsa.pub ]] && die "[ERROR] File[\"~/.ssh/id_rsa.pub\"] not exists. nothing to reset"
  [[ ! -f ~/.ssh/id_rsa.pub ]] && die "[ERROR] File[\"~/.ssh/id_rsa.pub\"] is not a regular file"

  public_key=$(<~/.ssh/id_rsa.pub)

  [[ ! $public_key =~ ^ssh-(ed25519|rsa|dss|ecdsa).+ ]] && die "[ERROR] File[\"~/.ssh/id_rsa.pub\"] is not a ssh key file"

  return 0
}

reset_authorized_keys() {
  [[ ! -e ~/.ssh/authorized_keys ]] && return 0

  sed -i '\#'"$public_key"'# d' ~/.ssh/authorized_keys
  sed -i -z 's/\n\{2,\}/\n/g' ~/.ssh/authorized_keys

  return 0
}

print_how_to_reset_managed_node_ssh() {
  echo "[INFO] To reset SSH of managed node, run the following on the managed node"
  echo ""
  echo 'key="'"$public_key"'"'
  cat << "EOF"
sed -i '\#'"$key"'# d' ~/.ssh/authorized_keys
sed -i -z 's/\n\{2,\}/\n/g' ~/.ssh/authorized_keys
EOF

  return 0
}

main
