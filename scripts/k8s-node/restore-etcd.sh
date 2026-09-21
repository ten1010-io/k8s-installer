#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--vars-path path] [--snapshot path] [--cluster-token token] [--confirm-data-loss] <command>
Options come before the command. One given after it is not read and is rejected
Available options:
-h, --help            Print this help and exit
-v, --verbose         Print script debug info
--vars-path           File path
--snapshot            File path of the snapshot to restore. Required by restore
--cluster-token       Token every member restores with. Required by restore
--confirm-data-loss   Required by restore. See the description of the command
Available commands:
stop      Stop the control plane of this node and wait for etcd to be gone
restore   Replace the data directory of etcd with the contents of the snapshot
start     Start the control plane of this node again
status    Print the members of the restored cluster and whether they answer
EOF
  exit
}

parse_params() {
  vars_path=""
  snapshot_path=""
  cluster_token=""
  confirm_data_loss="false"

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
    --snapshot)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      snapshot_path="${2-}"
      shift
      ;;
    --cluster-token)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      cluster_token="${2-}"
      shift
      ;;
    --confirm-data-loss) confirm_data_loss="true" ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ -z "${vars_path-}" ]] && die "[ERROR] Missing required option: --vars-path"
  [[ ${#args[@]} -lt 1 ]] && die "[ERROR] Missing required command"

  # Parsing stops at the command, so anything after it that looks like an option
  # was never read. Saying so rather than ignoring it: a --confirm-data-loss
  # written after the command would otherwise mean nothing while looking like it
  # meant something
  local arg
  for arg in "${args[@]:1}"; do
    [[ $arg = -* ]] &&
      die "[ERROR] Option[\"$arg\"] was given after the command, where it is not read. Options go before the command"
  done

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

# The static pods taken out of the way while etcd is replaced. The apiserver is
# one of them because it is the only thing that talks to etcd, and leaving it up
# against an etcd that is being rebuilt only produces a pod that crash loops
CONTROL_PLANE_MANIFESTS=(etcd.yaml kube-apiserver.yaml)
ETCD_STOP_TIMEOUT=120
ETCD_PEER_PORT=2380

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""
etcdctl_cmd=""

k8s_manifests_path=""
k8s_etcd_data_path=""
k8s_cp_nodes=""
internal_network_hosts=""
ih_to_hostname_dict=""
hostname=""

held_manifests_path=""

# Rebuilds etcd on this node from a snapshot.
#
# Split into three commands because a restore is a thing the whole control plane
# does at once, and ansible only synchronises between tasks. Every node has to
# be stopped before any node is restored, or a member that is still running
# keeps serving the state that is being replaced, and every node has to be
# restored before any node is started, or the first one up forms the new cluster
# alone. One command doing all three would let the nodes run at their own pace.
#
# Restoring produces a new cluster rather than repairing the old one: the
# members get a new cluster id, and nothing that was written after the snapshot
# is in it
main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  k8s_manifests_path=$($yq_cmd '.k8s_manifests_path' < "$vars_path")
  k8s_etcd_data_path=$($yq_cmd '.k8s_etcd_data_path' < "$vars_path")
  k8s_cp_nodes=$($yq_cmd -o json '.k8s_cp_nodes' < "$vars_path")
  internal_network_hosts=$($yq_cmd -o json '.internal_network_hosts' < "$vars_path")
  ih_to_hostname_dict=$($yq_cmd -o json '.ih_to_hostname_dict' < "$vars_path")
  hostname=$($yq_cmd '.hostname' < "$vars_path")

  held_manifests_path="${k8s_manifests_path%/*}"/manifests-held-by-restore-etcd

  local command=${args[0]}
  case "$command" in
  stop) stop_control_plane ;;
  restore) restore_etcd_data ;;
  start) start_control_plane ;;
  status) print_status ;;
  *) die "[ERROR] Unknown command: $command" ;;
  esac

  return 0
}

# Moved rather than deleted, and to a directory beside the one kubelet watches
# rather than inside it. kubelet reads every file of that directory, so a copy
# left there under another name is a second copy of the same static pod
stop_control_plane() {
  mkdir -p "$held_manifests_path"

  local manifest
  for manifest in "${CONTROL_PLANE_MANIFESTS[@]}"; do
    [[ -f "$k8s_manifests_path/$manifest" ]] || continue

    msg "[INFO] Holding static pod manifest[\"$manifest\"] of this node"
    mv "$k8s_manifests_path/$manifest" "$held_manifests_path/$manifest"
  done

  wait_etcd_stopped

  return 0
}

# The manifest being gone only tells kubelet to take the pod down. Replacing the
# data directory under an etcd that is still writing to it is what this waits to
# avoid
wait_etcd_stopped() {
  local elapsed=0
  while etcd_container_running; do
    [[ $elapsed -ge $ETCD_STOP_TIMEOUT ]] &&
      die "[ERROR] Failed to wait for etcd of this node to stop. it is still running $ETCD_STOP_TIMEOUT seconds after its manifest was taken away. the manifests of this node are held aside, so run the start command against it to put the control plane of this node back"

    sleep 2s
    elapsed=$((elapsed + 2))
  done

  msg "[INFO] Etcd of this node has stopped"

  return 0
}

# A crictl that fails says nothing about what is running, and answering "not
# running" to that is what would let the data directory be replaced under an
# etcd that is still writing to it. Not being able to tell is a reason to stop
etcd_container_running() {
  local output
  output=$(crictl ps --name '^etcd$' -q 2>&1) ||
    die "[ERROR] Failed to ask crictl what is running on this node, so whether etcd has stopped can not be told\n$output"

  [[ -n $output ]]
}

# The old data directory is renamed rather than removed. A restore that turns
# out to have been from the wrong snapshot is the moment the state it replaced
# matters most, and by then there is nothing left to take a snapshot of
restore_etcd_data() {
  [[ $confirm_data_loss = "true" ]] ||
    die "[ERROR] Restoring etcd replaces the state of the cluster with what the snapshot holds and everything written after it is lost. Pass --confirm-data-loss to say that is intended"
  [[ -n $snapshot_path ]] && [[ -n $cluster_token ]] ||
    die "[ERROR] Missing required option: --snapshot and --cluster-token are both required by the restore command"
  require_file_exists "$snapshot_path"

  local output
  output=$(etcdutl snapshot status "$snapshot_path" -w table 2>&1) ||
    die "[ERROR] Snapshot in file[\"$snapshot_path\"] can not be read back, so it is not one to restore from\n$output"
  msg "$output"

  etcd_container_running &&
    die "[ERROR] Etcd of this node is still running. run the stop command on every k8s cp node first"

  if [[ -d $k8s_etcd_data_path ]]; then
    local kept_path="$k8s_etcd_data_path".replaced-$(date -u +%Y%m%dT%H%M%SZ)
    msg "[INFO] Keeping the etcd data this node had in directory[\"$kept_path\"]"
    mv "$k8s_etcd_data_path" "$kept_path"
  fi

  local knn
  knn=$(convert_into_knn "$hostname")

  msg "[INFO] Restoring etcd of this node as member[\"$knn\"] from file[\"$snapshot_path\"]"
  etcdutl snapshot restore "$snapshot_path" \
      --name "$knn" \
      --data-dir "$k8s_etcd_data_path" \
      --initial-cluster "$(get_initial_cluster)" \
      --initial-cluster-token "$cluster_token" \
      --initial-advertise-peer-urls "$(get_peer_url "$(get_localhost_ih)")" ||
    die "[ERROR] Failed to restore etcd of this node from file[\"$snapshot_path\"]"

  return 0
}

# Nothing held is nothing to do, not an error. The failure messages of the other
# commands tell the operator to run this against every k8s cp node, and the
# rescue of the stop play runs it on a node whose stop may not have got as far as
# holding anything. Refusing there would break the way back out
start_control_plane() {
  [[ -d $held_manifests_path ]] || {
    msg "[INFO] No static pod manifest of this node is being held, so there is nothing to put back"
    return 0
  }

  local manifest
  for manifest in "${CONTROL_PLANE_MANIFESTS[@]}"; do
    [[ -f "$held_manifests_path/$manifest" ]] || continue

    msg "[INFO] Putting static pod manifest[\"$manifest\"] of this node back"
    mv "$held_manifests_path/$manifest" "$k8s_manifests_path/$manifest"
  done

  rmdir "$held_manifests_path" 2>/dev/null || true

  return 0
}

# What says the restore worked. The manifests being back only means kubelet has
# been told to start the pods again; the members still have to find each other
# and elect a leader before the cluster answers, which takes longer
print_status() {
  local output
  output=$($etcdctl_cmd -w table --command-timeout=10s member list 2>&1) ||
    die "[ERROR] The restored etcd of this node does not answer yet\n$output"
  msg "$output"

  output=$($etcdctl_cmd --endpoints=https://127.0.0.1:2379 --command-timeout=10s endpoint health 2>&1) ||
    die "[ERROR] The restored etcd of this node is not healthy yet\n$output"
  msg "$output"

  return 0
}

# Every member of the cluster the snapshot is being restored into, which is
# every k8s cp node. The list has to be identical on all of them
get_initial_cluster() {
  local entries=""
  local ih

  while read -r ih; do
    [[ -z $ih ]] && continue

    local entry
    entry="$(convert_into_knn "$(get_hostname "$ih")")=$(get_peer_url "$ih")"
    if [[ -z $entries ]]; then entries="$entry"; else entries="$entries,$entry"; fi
  done < <($yq_cmd -o json <<< "$k8s_cp_nodes" '.[]' | tr -d '"')

  echo "$entries"

  return 0
}

get_peer_url() {
  local ih=$1

  echo "https://$(get_ip "$ih"):$ETCD_PEER_PORT"

  return 0
}

get_ip() {
  local ih=$1

  $yq_cmd <<< "$internal_network_hosts" ".$ih.interfaces[0].ip"

  return 0
}

get_localhost_ih() {
  local ih

  while read -r ih; do
    [[ -z $ih ]] && continue
    [[ $(get_hostname "$ih") = "$hostname" ]] && { echo "$ih"; return 0; }
  done < <($yq_cmd -o json <<< "$ih_to_hostname_dict" 'keys | .[]' | tr -d '"')

  die "[ERROR] Fail to find the node of the inventory this node is, for hostname[\"$hostname\"]"
}

get_hostname() {
  local ih=$1

  local node_hostname
  node_hostname=$($yq_cmd <<< "$ih_to_hostname_dict" ".$ih")
  [[ -z $node_hostname || $node_hostname = "null" ]] && die "[ERROR] Fail to get hostname for ih[\"$ih\"]"

  echo "$node_hostname"
}

convert_into_knn() {
  local node_hostname=$1

  sed "s/_/-/g" <<< "${node_hostname,,}"

  return 0
}

import_ki_opt_vars() {
  ki_opt_root_path=$(grep -oP  "^ki_opt_root_path: \K(.+)" < "$vars_path")
  ki_opt_scripts_path=$(grep -oP  "^ki_opt_scripts_path: \K(.+)" < "$vars_path")
  ki_opt_bundle_path=$(grep -oP  "^ki_opt_bundle_path: \K(.+)" < "$vars_path")
  ki_opt_venv_path=$(grep -oP  "^ki_opt_venv_path: \K(.+)" < "$vars_path")
}

setup_cmd_vars() {
  yq_cmd="$ki_opt_bundle_path/bin/yq"
  etcdctl_cmd="etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/peer.crt --key=/etc/kubernetes/pki/etcd/peer.key"
}

validate_ki_opt_directory() {
  require_directory_exists "$ki_opt_scripts_path"
  require_directory_exists "$ki_opt_bundle_path"
  require_directory_exists "$ki_opt_venv_path"

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
