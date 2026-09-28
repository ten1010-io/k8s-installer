#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--node name] [--ca-path path]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--node          Name to report this node under
--ca-path       File path of the cluster ca to check what is served against
EOF
  exit
}

parse_params() {
  node=""
  ca_path=""

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --node)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      node="${2-}"
      shift
      ;;
    --ca-path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      ca_path="${2-}"
      shift
      ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ -z "${node-}" ]] && die "[ERROR] Missing required option: --node"
  [[ -z "${ca_path-}" ]] && die "[ERROR] Missing required option: --ca-path"

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

# Filled by read_served_cert. Globals because it has two answers to give - what
# was served, and why nothing was - and a function has one
served_cert=""
handshake_status=0

KUBELET_PORT=10250

# How long the port is given to answer. openssl has no timeout of its own, and a
# kubelet that accepts the connection and then does not finish the handshake -
# one that is restarting, or on a node under memory pressure - would hold this
# open with nothing to end it. Every playbook imports this at the end with
# any_errors_fatal, so a run that did all its work would hang on the last step
PROBE_TIMEOUT_SECONDS=10

# What timeout exits with when it kills what it was given, which is how a
# handshake that never finished is told apart from one that was refused
TIMEOUT_EXIT_STATUS=124

# Says whether this node serves a certificate the cluster issued or one kubelet
# signed for itself.
#
# Turning kubelet_server_tls_bootstrap on does not make a node verifiable. It
# makes kubelet ask, and the request sits there until something approves it -
# kube-controller-manager signs these and does not approve them, on purpose.
# While it waits kubelet has nothing to serve and does not fall back to one it
# signed itself: it refuses every handshake on this port, so the node answers
# nothing at all. That is the state worth naming, and it reads from the outside
# exactly like a node whose kubelet is gone, so this separates the two.
#
# So this asks the port rather than the disk. What matters is the certificate a
# client is handed, and a node can hold an issued one and still be serving the
# old one, or hold none at all and be serving fine on a request approved an hour
# ago. The answer is in the handshake.
#
# Reported rather than failed, and to stdout for a playbook to collect, the way
# check-vfio-pci.sh is. A node waiting for an approval is not a broken node, and
# whoever approves may not be whoever is running this
main() {
  read_served_cert
  if [[ -z $served_cert ]]; then
    report_nothing_served
    exit 0
  fi

  if [[ ! -r $ca_path ]]; then
    echo "[WARN] node[\"$node\"] holds no readable cluster ca at \"$ca_path\", so what it serves was not compared"
    exit 0
  fi

  signed_by_cluster_ca "$served_cert" && exit 0

  report_wrong_issuer

  exit 0
}

# What is established here is one thing: this certificate was not signed by the
# ca the node holds. Naming a cause from that would be a guess, and the obvious
# guess is the wrong one - a node waiting for an approval serves nothing at all
# rather than something, so whatever this is, it is not a request nobody
# answered. What is left is a node running something other than what the cluster
# asked for, which is the direction to look in rather than an answer
report_wrong_issuer() {
  local issuer
  issuer=$(get_issuer "$served_cert")

  echo "[WARN] node[\"$node\"] is serving a certificate the cluster ca at \"$ca_path\" did not sign, issued by[\"$issuer\"]."
  echo "       The cluster asked for issued certificates and this node is answering with one from somewhere else."
  echo "       A node still waiting for an approval serves nothing at all, so this is not that."
  echo "       Look at what \"serverTLSBootstrap\" says in /var/lib/kubelet/config.yaml there, and at \"journalctl -u kubelet\""

  return 0
}

# Nothing came back, and the reasons for that want different answers. A port with
# nothing on it is a node whose kubelet is not running, which is not what this
# playbook is about. A port that accepts and then refuses the handshake is
# kubelet running with no issued certificate, which is exactly what a request
# nothing has approved looks like - and saying "did not answer" there sends
# whoever reads it to go and check whether kubelet is alive, which it is. A
# handshake that simply never finished is neither, and guessing between them is
# what this exists not to do
report_nothing_served() {
  if [[ $handshake_status -eq $TIMEOUT_EXIT_STATUS ]]; then
    echo "[WARN] node[\"$node\"] did not finish a handshake on port $KUBELET_PORT within ${PROBE_TIMEOUT_SECONDS}s, so what it serves was not read"
    return 0
  fi

  if ! port_is_open; then
    echo "[WARN] node[\"$node\"] did not answer on port $KUBELET_PORT, so what it serves was not read"
    return 0
  fi

  echo "[WARN] node[\"$node\"] is serving no certificate at all on port $KUBELET_PORT, so nothing reaches its kubelet - kubectl logs, kubectl exec and metrics-server included."
  echo "       The cluster asked for issued certificates and kubelet has none, so it has stopped answering rather than serve one of its own."
  echo "       kubectl get csr --field-selector spec.signerName=kubernetes.io/kubelet-serving"

  return 0
}

# Whether anything is listening, asked without tls so that a refused handshake
# still counts as open
port_is_open() {
  timeout "$PROBE_TIMEOUT_SECONDS" bash -c "exec 3<>/dev/tcp/127.0.0.1/$KUBELET_PORT" &> /dev/null
}

# The certificate as a client is handed it. kubelet asks for a client
# certificate and this offers none, which fails at the http layer rather than
# during the handshake, so the server certificate is read before any of that
# matters.
#
# The handshake and the parse are two steps rather than a pipeline, because
# pipefail reports the rightmost failure and the one worth keeping is the
# leftmost: openssl reading nothing fails whatever went wrong upstream, and that
# would bury the status that says the handshake timed out
read_served_cert() {
  local pem

  pem=$(timeout "$PROBE_TIMEOUT_SECONDS" openssl s_client -connect 127.0.0.1:$KUBELET_PORT </dev/null 2>/dev/null) ||
    handshake_status=$?
  [[ $handshake_status -eq 0 ]] || return 0

  served_cert=$(openssl x509 2>/dev/null <<< "$pem") || served_cert=""

  return 0
}

# Asked of the cluster ca rather than of the name on the certificate. A name
# says which authority is claimed and not which one signed, and the claim is
# cheap to hold: kubeadm calls its ca "kubernetes" on every cluster it builds,
# so a node still serving a certificate issued by the cluster that stood here
# before this one carries exactly the name a comparison would have been looking
# for. openssl verify walks the chain against the ca the node holds, which is
# the question, and that ca is the one the apiserver is pointed at with
# kubelet-certificate-authority
signed_by_cluster_ca() {
  local cert=$1

  openssl verify -CAfile "$ca_path" <<< "$cert" &> /dev/null
}

# For the report rather than for the decision, so the whole name as openssl
# prints it: whoever reads this is about to go and look for that authority
get_issuer() {
  local cert=$1

  openssl x509 -noout -issuer 2>/dev/null <<< "$cert" | sed 's/^issuer=//'

  return 0
}

main
