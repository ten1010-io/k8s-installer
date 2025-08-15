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

main() {
  configure_id_rsa_pub
  configure_authorized_keys
  configure_sshd_config

  msg "[INFO] SSH of control node configured successfully"
  msg ""
  print_how_to_configure_managed_node_ssh

  return 0
}

configure_id_rsa_pub() {
  if [[ -e ~/.ssh/id_rsa.pub ]]; then
    msg "[INFO] File[\"~/.ssh/id_rsa.pub\"] already exists. k8s installer will configure with existing id_rsa.pub"

    [[ ! -f ~/.ssh/id_rsa.pub ]] && die "[ERROR] File[\"~/.ssh/id_rsa.pub\"] is not a regular file"
  else
    msg "[INFO] k8s installer will create id_rsa.pub"

    ssh-keygen -N '' <<< $'\ny'
  fi

  public_key=$(<~/.ssh/id_rsa.pub)

  [[ ! $public_key =~ ^ssh-(ed25519|rsa|dss|ecdsa).+ ]] && die "[ERROR] File[\"~/.ssh/id_rsa.pub\"] is not a ssh key file"

  return 0
}

configure_authorized_keys() {
  mkdir -p ~/.ssh
  echo "" >> ~/.ssh/authorized_keys
  sed -i '\#'"$public_key"'# d' ~/.ssh/authorized_keys
  sed -i '1 i\'"$public_key" ~/.ssh/authorized_keys
  sed -i -z 's/\n\{2,\}/\n/g' ~/.ssh/authorized_keys
}

configure_sshd_config() {
  [[ ! $(whoami) = "root" ]] && return 0

  sudo sed -i '/^PermitRootLogin/ d' /etc/ssh/sshd_config
  sudo sed -i '$ a\\nPermitRootLogin prohibit-password' /etc/ssh/sshd_config
  sudo sed -i -z 's/\n\{3,\}/\n\n/g' /etc/ssh/sshd_config
  sudo systemctl restart sshd
}

print_how_to_configure_managed_node_ssh() {
  echo "[INFO] To configure SSH of managed node, run the following on the managed node"
  echo ""
  echo 'key="'"$public_key"'"'
  cat << "EOF"
mkdir -p ~/.ssh
echo "" >> ~/.ssh/authorized_keys
sed -i '\#'"$key"'# d' ~/.ssh/authorized_keys
sed -i '1 i\'"$key" ~/.ssh/authorized_keys
sed -i -z 's/\n\{2,\}/\n/g' ~/.ssh/authorized_keys
EOF
  echo ""
  echo "[INFO] If using root user, run the following on the managed node"
  echo ""
  cat << "EOF"
sudo sed -i '/^PermitRootLogin/ d' /etc/ssh/sshd_config
sudo sed -i '$ a\\nPermitRootLogin prohibit-password' /etc/ssh/sshd_config
sudo sed -i -z 's/\n\{3,\}/\n\n/g' /etc/ssh/sshd_config
sudo systemctl restart sshd
EOF
}

main
