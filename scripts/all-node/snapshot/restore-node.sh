#!/usr/bin/env bash
# Puts a node back to a snapshot taken by snapshot-node.sh. Driven by
# rollback-cluster.yml, one command at a time, because the order matters across
# nodes: etcd is stopped on every k8s cp node before any node is touched, and
# restored on all of them before any kubelet is started again.
#
#   check      the snapshot is there, whole, and holds every package it lists
#   packages   stop kubelet, install the package files of the snapshot
#              (downgrading), put the configuration of the snapshot back and
#              restart containerd and docker. The static pod manifests of etcd
#              and kube-apiserver go to where restore-etcd.sh holds them, so
#              that its start command is what brings them back, after etcd is
#              restored
#   services   ki cp node: the compose projects of the snapshot running again,
#              the ones that came after it stopped
#   start      start kubelet
#
# What is replaced is kept next to it (*.before-rollback-<time>) and nothing is
# deleted.

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] --vars-path path --id id (check | packages | services | start)
EOF
  exit
}

parse_params() {
  vars_path=""
  snapshot_id=""

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --vars-path) vars_path="${2:?}"; shift ;;
    --id) snapshot_id="${2:?}"; shift ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  command="${1-}"
  [[ -z $vars_path ]] && die "[ERROR] Missing required option: --vars-path"
  [[ $snapshot_id =~ ^[A-Za-z0-9._-]+$ ]] || die "[ERROR] --id must be a plain name, got \"$snapshot_id\""

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

HELD_BY_RESTORE_ETCD=(etcd.yaml kube-apiserver.yaml)
# Projects of the legacy installer whose data this installer keeps under
# another name. Put back under the old name when the snapshot ran the old one
RENAMED_SERVICES=("ki-cp-aipub-registry:ki-cp-user-registry")

yq_cmd=""
stamp=$(date -u +%Y%m%dT%H%M%SZ)

main() {
  [[ -f $vars_path ]] || die "[ERROR] No such file of which path is \"$vars_path\""
  ki_opt_bundle_path=$(grep -oP "^ki_opt_bundle_path: \K(.+)" < "$vars_path")
  yq_cmd="$ki_opt_bundle_path/bin/$(uname -m)/yq"

  ki_var_root_path=$($yq_cmd '.ki_var_root_path' < "$vars_path")
  ki_etc_services_path=$($yq_cmd '.ki_etc_services_path' < "$vars_path")
  k8s_manifests_path=$($yq_cmd '.k8s_manifests_path' < "$vars_path")
  inventory_hostname=$($yq_cmd '.inventory_hostname' < "$vars_path")
  held_manifests_path="${k8s_manifests_path%/*}"/manifests-held-by-restore-etcd
  snap="$ki_var_root_path/snapshots/$snapshot_id"

  case $command in
  check) check_snapshot ;;
  packages) check_snapshot; restore_packages_and_files ;;
  services) restore_services ;;
  start) systemctl start kubelet; msg "[INFO] kubelet of node[\"$inventory_hostname\"] started" ;;
  *) die "[ERROR] Unknown command \"$command\"" ;;
  esac

  return 0
}

check_snapshot() {
  [[ -d $snap ]] || die "[ERROR] Node[\"$inventory_hostname\"] has no snapshot[\"$snapshot_id\"] in \"$snap\""
  (cd "$snap" && sha256sum --quiet -c SHA256SUMS) ||
    die "[ERROR] Snapshot[\"$snapshot_id\"] of node[\"$inventory_hostname\"] does not match its SHA256SUMS. It is not one to restore from"
  [[ -f $snap/debs/MISSING ]] &&
    msg "[WARN] Snapshot[\"$snapshot_id\"] of node[\"$inventory_hostname\"] holds no file for: $(tr '\n' ' ' < "$snap/debs/MISSING"). These stay at the version installed now"

  return 0
}

restore_packages_and_files() {
  systemctl stop kubelet

  # Every ki cp service down before its compose files go back. docker is
  # restarted below, and a container of the upgraded release still standing then
  # comes back up on its own, with a bind mount whose source the snapshot does
  # not have - docker makes a directory there, and the next setup of that
  # service fails on a directory where it writes a file. Measured: the
  # extra zone file of ki-cp-dns-server. services brings back the ones of the
  # snapshot.
  # Before the packages, while the docker and containerd that started those
  # containers still run: once dpkg has put an older containerd under them,
  # docker can no longer stop a container ("tried to kill container, but did not
  # receive an exit event", measured going back from containerd 2.3 to 1.7)
  stop_compose_projects

  # Every file at once, so dpkg resolves the dependencies among them (kubeadm
  # of the old minor wants the kubelet and cri-tools of that minor)
  local debs=("$snap"/debs/*.deb)
  if [[ -e ${debs[0]} ]]; then
    msg "[INFO] Installing the packages of snapshot[\"$snapshot_id\"]: $(cut -f1,2 --output-delimiter== "$snap/packages.tsv" | tr '\n' ' ')"
    DEBIAN_FRONTEND=noninteractive dpkg -i --force-downgrade --force-confold "${debs[@]}"
    apt-mark hold kubeadm kubelet kubectl >/dev/null 2>&1 || true
  fi

  # Once more: a run that stopped after dpkg last time comes here with the
  # packages done and docker unable to stop what still stands, which a restart
  # of docker on the packages now installed clears
  stop_compose_projects

  local p
  while read -r p; do
    [[ -e $p ]] && mv "$p" "$p.before-rollback-$stamp"
  done < "$snap/files.list"
  tar -C / -xzf "$snap/files.tar.gz"

  # etcd and kube-apiserver of the snapshot wait where restore-etcd.sh start
  # takes them from. The stop command of restore-etcd.sh moved the ones of the
  # upgraded release there, and those are not to come back
  if [[ -d $held_manifests_path ]]; then
    local m
    for m in "${HELD_BY_RESTORE_ETCD[@]}"; do
      rm -f "$held_manifests_path/$m"
      [[ -f $k8s_manifests_path/$m ]] && mv "$k8s_manifests_path/$m" "$held_manifests_path/$m"
    done
  fi

  systemctl daemon-reload
  systemctl restart containerd
  systemctl is-enabled docker >/dev/null 2>&1 && systemctl restart docker

  msg "[INFO] Node[\"$inventory_hostname\"] has the packages and configuration of snapshot[\"$snapshot_id\"]. What it had is kept as *.before-rollback-$stamp"

  return 0
}

stop_compose_projects() {
  command -v docker >/dev/null && docker compose version >/dev/null 2>&1 || return 0

  local name
  for name in $(docker compose ls -a --format json | $yq_cmd -p json '.[].Name'); do
    docker compose -p "$name" down && continue
    msg "[WARN] Failed to take compose project[\"$name\"] down. Restarting docker and trying once more"
    systemctl restart docker
    docker compose -p "$name" down ||
      die "[ERROR] Failed to take compose project[\"$name\"] down even after a restart of docker"
  done

  return 0
}

restore_services() {
  command -v docker >/dev/null || return 0

  local wanted
  wanted=$($yq_cmd -p json '.[].Name' < "$snap/services.json")

  # Running now but not in the snapshot: stopped, data left where it is. By
  # project name, since the packages command already put the compose files of
  # the snapshot in place and the file such a project was started from is gone
  local name
  for name in $(docker compose ls -a --format json | $yq_cmd -p json '.[].Name'); do
    grep -qx "$name" <<<"$wanted" && continue
    msg "[INFO] Stopping service[\"$name\"], which node[\"$inventory_hostname\"] did not run at snapshot[\"$snapshot_id\"]"
    docker compose -p "$name" down
  done

  local pair old new
  for pair in "${RENAMED_SERVICES[@]}"; do
    old=${pair%%:*}; new=${pair#*:}
    grep -qx "$old" <<<"$wanted" || continue
    if [[ -d $ki_var_root_path/$new && ! -e $ki_var_root_path/$old ]]; then
      msg "[INFO] Moving the data of service[\"$new\"] back to service[\"$old\"]"
      mv "$ki_var_root_path/$new" "$ki_var_root_path/$old"
    fi
  done

  for name in $wanted; do
    [[ -f $ki_etc_services_path/$name/compose.yml ]] ||
      die "[ERROR] Snapshot[\"$snapshot_id\"] ran service[\"$name\"] but has no compose file of it"
    docker compose -f "$ki_etc_services_path/$name/compose.yml" up -d
  done

  return 0
}

main
