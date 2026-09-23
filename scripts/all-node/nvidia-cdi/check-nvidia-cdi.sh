#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--node name]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--node          Name to report this node under
EOF
  exit
}

parse_params() {
  node=""

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
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ -z "${node-}" ]] && die "[ERROR] Missing required option: --node"

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

# Says whether a node that has nvidia gpus can actually hand them to containers.
#
# Nothing here configures anything, and that is the point. containerd carries
# enable_cdi and reads /etc/cdi and /var/run/cdi out of the box, and the
# specification in those directories is written by nvidia-cdi-refresh, two
# systemd units that ship with nvidia-container-toolkit-base and fire when the
# toolkit is installed, when the driver is installed, and at every boot. Every
# part of that is somebody else's, which leaves the installer with one job: to
# say when it did not happen.
#
# Nothing is declared in the inventory for this. Whether a node has gpus is a
# fact about the node, and asking it is cheaper and truer than carrying a
# variable that says so and can be wrong. A node with no driver is not a node
# that failed, it is a node without gpus, and this says nothing about it.
#
# A node that has the driver and no gpu the driver can see is a third thing, and
# the one place where this and the vfio-pci work of the same branch meet. There
# is nothing to fix about its containers - the cards went to a guest on purpose -
# but the toolkit's refresh unit restarts every second for as long as that node
# is up, and this is the only thing on the node that will say so.
#
# Reported rather than failed, and to stdout for a playbook to collect, the way
# check-vfio-pci.sh is. See docs/impl-notes.adoc
main() {
  # A node the toolkit is not on has a bigger problem than this, and
  # install-packages.sh is what says so
  command -v nvidia-ctk > /dev/null 2>&1 || exit 0

  # No driver, no gpus, nothing to say. The installer does not carry the driver
  # and does not ask for one
  driver_installed || exit 0

  # The driver is here and can not see a gpu, which is not the same node as the
  # one above and must not be treated as it. It is the shape a node takes when
  # its cards were bound to vfio-pci - the passthrough of this same installer is
  # how that happens on purpose - and the toolkit does not sit quietly through it
  if ! nvidia_smi_works; then
    report_driver_without_gpus
    exit 0
  fi

  [[ $(cdi_gpu_count) -gt 0 ]] && exit 0

  report_missing_cdi_devices

  exit 0
}

# Whether the node carries the driver at all, which is a different question from
# whether the driver can see anything. The binary rather than the module: a node
# whose kernel was upgraded past its driver has the one and not the other, and it
# belongs with the case below rather than with the node that has no gpus
driver_installed() {
  command -v nvidia-smi > /dev/null 2>&1
}

nvidia_smi_works() {
  nvidia-smi -L > /dev/null 2>&1
}

# How often the refresh unit has restarted, which is the measure of the problem
# rather than a state to branch on. Its own value when it can not be read
refresh_restarts() {
  systemctl show nvidia-cdi-refresh.service -p NRestarts --value 2>/dev/null || echo "unknown"
}

# How many gpus the driver sees, for the report. Only ever read after nvidia-smi
# has been shown to work
gpu_count() {
  nvidia-smi -L 2>/dev/null | grep -c "^GPU" || true
}

# The devices the specification actually offers. nvidia-ctk reads the same
# directories containerd does, so an empty answer here is an empty answer there
cdi_gpu_count() {
  nvidia-ctk cdi list 2>/dev/null | grep -c "nvidia\.com/gpu" || true
}

# Not "this node can not serve its gpus": it has none to serve and that may well
# be deliberate. What is reported is the unit, because the toolkit's own
# nvidia-cdi-refresh.service opens with nvidia-smi -L as an ExecStart carrying no
# - prefix, and carries Restart=on-failure with RestartSec=1s and no working
# start limit. On a node in this state it fails and restarts for as long as the
# node is up, and nothing else on the node will ever say so
report_driver_without_gpus() {
  echo "[WARN] node[\"$node\"] carries the nvidia driver and no gpu the driver can see"
  echo "  nvidia-cdi-refresh.service restarts since boot: $(refresh_restarts)"
  echo "  Containers being given no gpu here is expected if the cards of this node were"
  echo "  passed through. The restarts are not: that unit retries every second for as long"
  echo "  as the node is up, and this is the only thing that reports it."
  echo "  If this node is meant to pass its cards through, take the unit out of the way:"
  echo "    systemctl disable --now nvidia-cdi-refresh.path nvidia-cdi-refresh.service"
  echo "  If it is not, the driver has lost its cards and that is the thing to look at:"
  echo "    nvidia-smi -L; dmesg | grep -i nvrm"
  echo "  Then: ansible-playbook -i inventory.yml playbooks/tasks/check-nvidia-cdi.yml"

  return 0
}

report_missing_cdi_devices() {
  echo "[WARN] node[\"$node\"] has nvidia gpus and no cdi devices, so containers can not be given one"
  echo "  gpus the driver sees: $(gpu_count)"
  echo "  cdi devices: none"
  echo "  The specification is written by nvidia-cdi-refresh, which comes with the toolkit and"
  echo "  runs when the driver is installed and at every boot. Look at why it has not:"
  echo "    systemctl status nvidia-cdi-refresh.path nvidia-cdi-refresh.service"
  echo "    journalctl -u nvidia-cdi-refresh.service"
  echo "    systemctl restart nvidia-cdi-refresh.service"
  echo "  That service does not regenerate after the mig devices of a node are reconfigured,"
  echo "  which is the one case it has to be restarted by hand"

  return 0
}

main
