#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--vars-path path] [--control-node]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--vars-path     File path
--control-node  Run by a playbook that can reboot the control node, so do not refuse it
EOF
  exit
}

parse_params() {
  vars_path=""
  control_node="false"

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
    --control-node) control_node="true" ;;
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

# Gives a node a kernel that can load the modules the cluster needs, when the
# one it runs can not.
#
# Only rhel 10 is ever in that position: it moved br_netfilter and the netfilter
# matches into kernel-modules-extra, which a minimal install does not hold, and
# a node without them fails a long way from here - configure-linux.sh stops at
# modprobe, or docker and kube-proxy start and then refuse every rule they try
# to write. That package is built for one kernel, so the bundle can not carry it
# alone: it carries the newest kernel of the newest minor with it, and a node
# that lacks the modules is moved onto that kernel and rebooted.
#
# Four rules keep that from making this installer a kernel manager:
#
#   - only a node whose running kernel can not load the modules is touched. One
#     that can keeps whatever kernel it has
#   - only while a node is being built. setup-boot-config.yml is the one caller,
#     and the upgrade never comes here, so a release that carries a newer kernel
#     does not roll it onto nodes that already work
#   - a node running a kernel newer than the bundle's is refused rather than
#     moved back. Which leaves it where it was before any of this: a node that
#     has to be given kernel-modules-extra by whoever owns it
#   - a node that would have to reboot and may not - provision_reboot is off, or
#     it is the control node, which this run cannot reboot - is refused before
#     anything is installed. check-node-state.sh says so earlier and in more
#     words; this is the same decision taken again where it would otherwise
#     be acted on
#
# The kernel is installed beside the running one rather than over it. rpm's -U
# would take the old kernel out, and the kernel meta package of the node still
# names it; -i leaves both, and the new one becomes the default entry the way
# any newly installed kernel does. A node already on the bundle's kernel that
# lacks only the modules gets the modules and needs no reboot at all.
#
# The control node is refused by the fourth rule because setup-boot-config.yml,
# which calls this while a cluster is being built, runs on it and can not
# reboot it. setup-control-node.yml can, by scheduling the reboot for after it
# has ended, and says so with --control-node: then the control node is a node
# like any other here.
#
# What is printed on stdout is for the playbook: whether this node has to be
# rebooted before what was installed is in force

# Kept in step with the one every script of this directory and
# check-node-state.sh source
source "$SCRIPT_DIR_PATH"/kernel-common.sh

RHEL10_SUPPORTED_MINOR_VERSION=2

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""

os_info=""
os_distribution=""
os_major_version=""
os_minor_version=""

provision_reboot=""
inventory_hostname=""
ki_control_node_ih=""

main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory
  get_os_version

  provision_reboot=$($yq_cmd '.provision_reboot' < "$vars_path")
  inventory_hostname=$($yq_cmd '.inventory_hostname' < "$vars_path")
  ki_control_node_ih=$($yq_cmd '.ki_control_node_ih' < "$vars_path")

  local missing
  missing=$(missing_kernel_modules | tr '\n' ' ')

  if [[ -z $missing ]]; then
    msg "[INFO] Kernel[\"$(uname -r)\"] loads every module this node needs"
    print_yaml false
    exit 0
  fi

  if [[ $os_distribution = "rhel" && $os_major_version = "10" && $os_minor_version -le "$RHEL10_SUPPORTED_MINOR_VERSION" ]]; then
    rhel10_setup "$missing"
    exit 0
  fi

  die "[ERROR] Kernel[\"$(uname -r)\"] can not load module[ $missing]. The container runtime and kube-proxy write their rules with these, and this installer carries no kernel for this operating system"
}

rhel10_setup() {
  local missing=$1

  local kernel_dir="$ki_opt_bundle_path/linux-packages/rhel10/kernel"
  local bundle_version
  bundle_version=$(bundle_kernel_version "$kernel_dir")
  [[ -z $bundle_version ]] &&
    die "[ERROR] Kernel[\"$(uname -r)\"] can not load module[ $missing] and the bundle carries no kernel for rhel 10. Install kernel-modules-extra of the running kernel and run this again"

  local running_version
  running_version=$(running_kernel_version)
  local order
  order=$(compare_kernel_versions "$running_version" "$bundle_version")

  if [[ $order -gt 0 ]]; then
    die "[ERROR] Kernel[\"$(uname -r)\"] can not load module[ $missing] and is newer than kernel[\"$bundle_version\"] of the bundle, which this installer will not move a node back to. Install kernel-modules-extra of the running kernel and run this again:\n  dnf install kernel-modules-extra-$(uname -r)"
  fi

  if [[ $order -eq 0 ]]; then
    # The bundle's kernel is the one running and only its modules are missing.
    # They are built for exactly this kernel, so they load as soon as they are
    # on disk
    install_kernel_rpms "$kernel_dir"
    depmod -a >&2
    msg "[INFO] Installed the modules of kernel[\"$(uname -r)\"] from the bundle"
    print_yaml false
    return 0
  fi

  [[ $provision_reboot != "true" ]] &&
    die "[ERROR] Kernel[\"$(uname -r)\"] can not load module[ $missing]. The bundle carries kernel[\"$bundle_version\"], but putting it on this node needs a reboot and provision_reboot is off. Set provision_reboot: true, or install kernel-modules-extra of the running kernel and run this again"
  [[ $control_node = "false" && $inventory_hostname = "$ki_control_node_ih" ]] &&
    die "[ERROR] Kernel[\"$(uname -r)\"] can not load module[ $missing]. The bundle carries kernel[\"$bundle_version\"], but this node is the control node, which this run can not reboot. Run setup-control-node.yml, which installs that kernel and reboots this node, and run this again"

  install_kernel_rpms "$kernel_dir"
  msg "[INFO] Installed kernel[\"$bundle_version\"] from the bundle beside kernel[\"$(uname -r)\"]"
  msg "[WARN] This node has to be rebooted before it runs the kernel that loads module[ $missing]"
  print_yaml true

  return 0
}

# Installed, not upgraded, and only what is not there yet: the kernel packages
# are install-only, which dnf knows and rpm alone does not, so -U would take the
# running kernel out from under the kernel meta package that names it. A package
# already there at the version the bundle holds is skipped the way
# install-packages.sh skips one, since the run that installed it may have been
# stopped before its reboot
install_kernel_rpms() {
  local dir=$1

  local to_install=()
  local rpm_file
  local nvr
  for rpm_file in "$dir"/*.rpm; do
    [[ -e $rpm_file ]] || continue
    nvr=$(rpm -qp --queryformat '%{NAME}-%{VERSION}-%{RELEASE}' "$rpm_file" 2>/dev/null)
    [[ -n $nvr ]] && rpm -q "$nvr" &>/dev/null && continue
    to_install+=("$rpm_file")
  done

  [[ ${#to_install[@]} = 0 ]] && return 0

  # To stderr with everything else said here: stdout is the one line the
  # playbook reads back
  rpm -ivh "${to_install[@]}" >&2

  return 0
}

print_yaml() {
  cat <<YAML
---
reboot_required: "$1"
YAML

  return 0
}

import_ki_opt_vars() {
  ki_opt_root_path=$(grep -oP  "^ki_opt_root_path: \K(.+)" < "$vars_path")
  ki_opt_scripts_path=$(grep -oP  "^ki_opt_scripts_path: \K(.+)" < "$vars_path")
  ki_opt_bundle_path=$(grep -oP  "^ki_opt_bundle_path: \K(.+)" < "$vars_path")
  ki_opt_venv_path=$(grep -oP  "^ki_opt_venv_path: \K(.+)" < "$vars_path")
}

get_os_version() {
  os_info=$("$ki_opt_scripts_path"/preflight/get-os-info.sh)

  os_distribution=$($yq_cmd .distribution <<< "$os_info")
  os_major_version=$($yq_cmd .major_version <<< "$os_info")
  os_minor_version=$($yq_cmd .minor_version <<< "$os_info")
}

setup_cmd_vars() {
  yq_cmd="$ki_opt_bundle_path/bin/yq"

  return 0
}

validate_ki_opt_directory() {
  require_directory_exists "$ki_opt_scripts_path"
  require_directory_exists "$ki_opt_bundle_path"

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
