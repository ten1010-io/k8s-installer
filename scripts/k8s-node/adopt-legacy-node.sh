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
--sync-cluster-config
                On the first k8s cp node: upload the kubeadm configuration of
                vars.yml at the kubernetes version the cluster runs now
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
    --sync-cluster-config) action="sync" ;;
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
  sync) sync_cluster_config ;;
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
    # Taken over before. Checked again all the same: a run of this playbook
    # again is how a vars.yml that was fixed after a refusal gets looked at
    [[ $recorded == "$LEGACY_RELEASE_PREFIX"* ]] ||
    die "[ERROR] Node[\"$inventory_hostname\"] already records release[\"$recorded\"] in \"$ki_etc_applied_release_path\". It is a node of this installer and has nothing to be taken over"
  fi

  [[ -d $LEGACY_ROOT_PATH ]] ||
    msg "[WARN] Node[\"$inventory_hostname\"] has no \"$LEGACY_ROOT_PATH\". The legacy installer keeps it on the node it ran from, so this is expected of every other node"

  [[ -f /etc/kubernetes/kubelet.conf ]] ||
    die "[ERROR] Node[\"$inventory_hostname\"] has no /etc/kubernetes/kubelet.conf, so it is not a node of a running cluster. Add it with add-node.yml once the cluster is taken over"

  [[ -d $ki_etc_root_path ]] ||
    die "[ERROR] Node[\"$inventory_hostname\"] has no \"$ki_etc_root_path\". The installers of 5.0.x write it on every node they build, so this is not a node of one"

  [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]] && require_apiserver_flags_declared

  return 0
}

# The 5.0.x installer turned on audit and the token webhook of AIPub by editing
# the static pod manifest of kube-apiserver, not through kubeadm. kubeadm writes
# that manifest anew from its own configuration at every upgrade, so a flag
# that lives only in the manifest is gone after the first one - and with it the
# audit log, or every login of AIPub. Such a flag has to be declared in
# k8s_apiserver_extra_args, which is what this installer hands kubeadm. Only the
# flags of the features 5.0.x added this way are asked; the rest kubeadm writes
# itself
require_apiserver_flags_declared() {
  local declared missing=()
  declared=$($yq_cmd -o json '.k8s_apiserver_extra_args // []' < "$vars_path")

  local flag name value
  while read -r flag; do
    name=${flag%%=*}; name=${name#--}
    value=${flag#*=}
    [[ $name =~ ^(audit-|authentication-token-webhook-|authentication-config|authorization-config|encryption-provider-config|admission-control-config-file|oidc-) ]] || continue
    [[ $($yq_cmd --null-input "$declared | map(select(.name == \"$name\" and .value == \"$value\")) | length") -ge 1 ]] ||
      missing+=("$flag")
  done < <($yq_cmd '.spec.containers[0].command[]' < /etc/kubernetes/manifests/kube-apiserver.yaml | grep -E '^--[^=]+=')

  # The files those flags name reach the container through hostPath volumes
  # added the same way, and a flag kept without its volume is worse than one
  # dropped: kube-apiserver does not start. Measured: the token webhook of 5.0.x
  # names a CA under /etc/k8s-installer/certs, mounted by a volume of its own.
  # kubeadm adds its own volumes for the certificates of the node; any other
  # hostPath has to be declared
  local declared_volumes path
  declared_volumes=$($yq_cmd -o json '[.k8s_apiserver_extra_volumes // [] | .[].hostPath]' < "$vars_path")
  while read -r path; do
    [[ $path =~ ^/etc/(kubernetes/pki|ssl/certs|ca-certificates|pki)$|^/usr/(local/)?share/ca-certificates$ ]] && continue
    [[ $($yq_cmd --null-input "$declared_volumes | map(select(. == \"$path\")) | length") -ge 1 ]] ||
      missing+=("volume hostPath $path")
  done < <($yq_cmd '.spec.volumes[] | select(.hostPath) | .hostPath.path' < /etc/kubernetes/manifests/kube-apiserver.yaml)

  [[ ${#missing[@]} -eq 0 ]] && return 0

  die "[ERROR] kube-apiserver of node[\"$inventory_hostname\"] runs with flags or volumes kubeadm does not know of, and the next upgrade would drop them:\n$(printf '  %s\n' "${missing[@]}")\nDeclare each flag in k8s_apiserver_extra_args and each volume in k8s_apiserver_extra_volumes"
}

# Hands kubeadm the configuration this installer renders from vars.yml - the
# extra arguments and volumes above among it - while keeping the kubernetes
# version the cluster runs now. upload-k8s-cluster-config.sh writes the version
# of k8s_minor_version, which before an upgrade is the one to go to, and a
# control plane written from that would be an upgrade nobody ran kubeadm for.
# What the cluster has to keep as it is - endpoint, image repository, subnets -
# is compared first and a difference refused, since a takeover is not where
# those change
sync_cluster_config() {
  local current tmp_vars rendered key
  current=$(kubectl --kubeconfig /etc/kubernetes/admin.conf -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}') ||
    die "[ERROR] Failed to read kubeadm-config of the cluster"

  tmp_vars=$(mktemp)
  # Expanded now: the trap runs after the local is gone
  trap "rm -f '$tmp_vars'; trap - RETURN" RETURN
  cp "$vars_path" "$tmp_vars"
  $yq_cmd -i ".k8s_version = \"$($yq_cmd '.kubernetesVersion' <<<"$current")\"" "$tmp_vars"

  rendered=$($ki_opt_venv_path/bin/jinja2 --format yaml "$SCRIPT_DIR_PATH"/templates/kubeadm-cluster-config.yml.j2 "$tmp_vars")
  for key in kubernetesVersion controlPlaneEndpoint imageRepository networking.podSubnet networking.serviceSubnet networking.dnsDomain etcd.local.dataDir; do
    local now next
    now=$($yq_cmd ".$key // \"\"" <<<"$current")
    next=$($yq_cmd "select(.kind == \"ClusterConfiguration\") | .$key // \"\"" <<<"$rendered")
    # Left out of the template is left to kubeadm, which fills in its default
    if [[ -z $next ]]; then
      case $key in
      networking.dnsDomain) next="cluster.local" ;;
      etcd.local.dataDir) next="/var/lib/etcd" ;;
      esac
    fi
    [[ $now = "$next" ]] ||
      die "[ERROR] vars.yml renders $key \"$next\" but the cluster has \"$now\". A takeover keeps it as it is; make vars.yml say \"$now\""
  done

  "$SCRIPT_DIR_PATH"/upload-k8s-cluster-config.sh --vars-path "$tmp_vars"
  msg "[INFO] kubeadm-config of the cluster now holds the configuration of vars.yml at kubernetes $($yq_cmd '.k8s_version' < "$tmp_vars")"

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
