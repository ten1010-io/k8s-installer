#!/usr/bin/env bash
# Takes over a node built by the installer of AIPub 5.0.x, which kept itself in
# /var/lib/ki-env and recorded nothing this installer reads. That installer
# already laid out /etc/k8s-installer and /var/lib/k8s-installer the way this
# one does - pki, the compose files of the ki cp services, the registry data -
# so what a node lacks is the handful of records this installer writes when it
# builds a node itself:
#
#   - the kubelet patch of kubeadm, which upgrade-k8s-node.sh passes to every
#     kubeadm upgrade and which a node built by kubeadm here always has
#   - applied-release, which check-cluster-upgradable.yml asks before it lets a
#     cluster be upgraded. A node without it is a node this installer did not
#     build, and the upgrade refuses it - which is right until this script has
#     looked at the node
#
# applied-release is written last and only by --record, after every ki cp
# service is in the shape this installer expects, so a node that stopped half
# way is still refused by the upgrade rather than taken for one that is done.
#
# The legacy installer is left where it is. Nothing of /var/lib/ki-env is
# removed: it holds the packages of the release the node runs now, and
# rollback-cluster.yml installs them back from a snapshot of the node.

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] --vars-path path (--check | --prepare | --record release)
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--vars-path     File path
--check         Refuse a node this installer can not take over, change nothing
--prepare       Write the kubelet patch of kubeadm
--record        Write applied-release, the last step of a takeover
EOF
  exit
}

parse_params() {
  vars_path=""
  action=""
  legacy_release=""

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --vars-path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      vars_path="${2-}"
      shift
      ;;
    --check) action="check" ;;
    --prepare) action="prepare" ;;
    --record)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      action="record"
      legacy_release="${2-}"
      shift
      ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  [[ -z "${vars_path-}" ]] && die "[ERROR] Missing required option: --vars-path"
  [[ -z "${action-}" ]] && die "[ERROR] One of --check, --prepare and --record is required"

  return 0
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg=$1
  local code=${2-1}
  msg "$msg"
  exit "$code"
}

set -Eeuo pipefail

parse_params "$@"

LEGACY_ROOT_PATH="/var/lib/ki-env"
LEGACY_RELEASE_PREFIX="legacy-"

yq_cmd=""
jinja2_cmd=""

main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars

  ki_etc_root_path=$($yq_cmd '.ki_etc_root_path' < "$vars_path")
  ki_etc_kubeadm_path=$($yq_cmd '.ki_etc_kubeadm_path' < "$vars_path")
  ki_etc_applied_release_path=$($yq_cmd '.ki_etc_applied_release_path' < "$vars_path")
  inventory_hostname=$($yq_cmd '.inventory_hostname' < "$vars_path")

  case $action in
  check) check_node ;;
  prepare) check_node; create_kubelet_config_patch_file ;;
  record) record_applied_release ;;
  esac

  return 0
}

check_node() {
  # A node of this installer records the release it was built with. One that
  # does is not legacy, whatever else is lying around on it
  if [[ -f $ki_etc_applied_release_path ]]; then
    local recorded
    recorded=$(<"$ki_etc_applied_release_path")
    [[ $recorded == "$LEGACY_RELEASE_PREFIX"* ]] && return 0
    die "[ERROR] Node[\"$inventory_hostname\"] already records release[\"$recorded\"] in \"$ki_etc_applied_release_path\". It is a node of this installer and has nothing to be taken over"
  fi

  [[ -d $LEGACY_ROOT_PATH ]] ||
    msg "[WARN] Node[\"$inventory_hostname\"] has no \"$LEGACY_ROOT_PATH\". The legacy installer keeps it on the node it ran from, so this is expected of every other node"

  [[ -f /etc/kubernetes/kubelet.conf ]] ||
    die "[ERROR] Node[\"$inventory_hostname\"] has no /etc/kubernetes/kubelet.conf, so it is not a node of a running cluster. Add it with add-node.yml once the cluster is taken over"

  [[ -d $ki_etc_root_path ]] ||
    die "[ERROR] Node[\"$inventory_hostname\"] has no \"$ki_etc_root_path\". The installers of 5.0.x write it on every node they build, so this is not a node of one"

  return 0
}

create_kubelet_config_patch_file() {
  local patch_path="$ki_etc_kubeadm_path/patches/kubeletconfiguration+merge.yaml"

  mkdir -p "$ki_etc_kubeadm_path/patches"
  [[ -f $patch_path ]] && cp -p "$patch_path" "$patch_path.before-adopt"
  $jinja2_cmd --format yaml \
              -o "$patch_path" \
              "$SCRIPT_DIR_PATH"/templates/kubeadm-kubelet-config.yml.j2 \
              "$vars_path"

  # What the kubelet runs with now against what the next kubeadm upgrade will
  # give it. Not refused: a reservation that moves is what vars.yml asks for.
  # Said, because it is the one thing of a takeover a workload can feel
  local key
  for key in systemReserved kubeReserved evictionHard maxPods; do
    local now next
    now=$($yq_cmd -o json ".$key // null" < /var/lib/kubelet/config.yaml)
    next=$($yq_cmd -o json ".$key // null" < "$patch_path")
    [[ $next = "null" || $now = "$next" ]] && continue
    msg "[WARN] Node[\"$inventory_hostname\"] kubelet $key changes at the next upgrade: $now -> $next"
  done

  return 0
}

record_applied_release() {
  [[ $legacy_release == "$LEGACY_RELEASE_PREFIX"* ]] ||
    die "[ERROR] Release[\"$legacy_release\"] given to --record is not a legacy one. It has to start with \"$LEGACY_RELEASE_PREFIX\" so that nothing takes it for a release of this installer"

  echo "$legacy_release" > "$ki_etc_applied_release_path"
  msg "[INFO] Node[\"$inventory_hostname\"] recorded as release[\"$legacy_release\"]"

  return 0
}

import_ki_opt_vars() {
  ki_opt_root_path=$(grep -oP "^ki_opt_root_path: \K(.+)" < "$vars_path")
  ki_opt_bundle_path=$(grep -oP "^ki_opt_bundle_path: \K(.+)" < "$vars_path")
  ki_opt_venv_path=$(grep -oP "^ki_opt_venv_path: \K(.+)" < "$vars_path")
}

setup_cmd_vars() {
  yq_cmd="$ki_opt_bundle_path/bin/$(uname -m)/yq"
  jinja2_cmd="$ki_opt_venv_path/bin/jinja2"
}

require_file_exists() {
  local path=$1

  [[ ! -e $path ]] && die "[ERROR] No such file or directory of which path is \"$path\""
  [[ ! -f $path ]] && die "[ERROR] File[\"$path\"] is not a regular file"

  return 0
}

main
