#!/usr/bin/env bash
# Takes what a node needs to be put back to where it is now, before an upgrade
# changes it. rollback-cluster.yml puts it back with restore-node.sh.
#
# kubeadm moves a cluster up one minor at a time and has no way down, and the
# schema of the applications only moves forward too. So a downgrade here is not
# a run of the upgrade in reverse: it is the node returned to a state it was in,
# with the cluster state of that moment, and everything written after the
# snapshot is lost. What that takes, per node:
#
#   packages.tsv   the versions of the packages an upgrade replaces
#   debs/          those packages themselves, picked out of --packages-dir by
#                  what each file says it is. A rollback can not download them
#   files.tar.gz   the configuration an upgrade rewrites: /etc/kubernetes, the
#                  records and compose files of /etc/k8s-installer, containerd,
#                  docker, the kubelet configuration
#   services.json  the ki cp services this node runs (compose projects)
#   etcd.db        on a k8s cp node, a snapshot of etcd
#   SHA256SUMS     of all of the above, checked before anything is restored
#
# The data of the registries is not taken: it is large, and an upgrade adds to
# it rather than taking anything away.

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] --vars-path path --id id [--packages-dir path] [--allow-missing-packages]
Available options:
-h, --help                  Print this help and exit
-v, --verbose               Print script debug info
--vars-path                 File path
--id                        Name of the snapshot, the same on every node of one run
--packages-dir              Directory searched (recursively) for the package files of
                            the versions installed now
--allow-missing-packages    Take the snapshot even when a package file is missing.
                            A rollback from it then can not put that package back
EOF
  exit
}

parse_params() {
  vars_path=""
  snapshot_id=""
  packages_dir=""
  allow_missing_packages="false"

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --vars-path) vars_path="${2:?}"; shift ;;
    --id) snapshot_id="${2:?}"; shift ;;
    --packages-dir) packages_dir="${2:?}"; shift ;;
    --allow-missing-packages) allow_missing_packages="true" ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

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

# The packages an upgrade of this installer replaces (release.yml packages and
# the kubernetes ones of k8s_versions). Only those installed are recorded
PACKAGES=(
  kubeadm kubelet kubectl kubernetes-cni cri-tools
  containerd.io docker-ce docker-ce-cli docker-ce-rootless-extras docker-buildx-plugin docker-compose-plugin
  libnvidia-container1 libnvidia-container-tools nvidia-container-toolkit nvidia-container-toolkit-base
)
# What an upgrade rewrites. Paths that do not exist on a node are skipped
FILES=(
  /etc/kubernetes
  /etc/k8s-installer
  /etc/containerd
  /etc/docker
  /etc/crictl.yaml
  /etc/default/kubelet
  /etc/systemd/system/kubelet.service.d
  /usr/lib/systemd/system/kubelet.service.d
  /var/lib/kubelet/config.yaml
  /var/lib/kubelet/kubeadm-flags.env
)

yq_cmd=""

main() {
  [[ -f $vars_path ]] || die "[ERROR] No such file of which path is \"$vars_path\""
  import_ki_opt_vars
  yq_cmd="$ki_opt_bundle_path/bin/$(uname -m)/yq"

  ki_var_root_path=$($yq_cmd '.ki_var_root_path' < "$vars_path")
  k8s_manifests_path=$($yq_cmd '.k8s_manifests_path' < "$vars_path")
  inventory_hostname=$($yq_cmd '.inventory_hostname' < "$vars_path")

  local root="$ki_var_root_path/snapshots"
  local dir="$root/$snapshot_id"
  [[ -e $dir ]] && die "[ERROR] Snapshot[\"$snapshot_id\"] already exists on node[\"$inventory_hostname\"] in \"$dir\". Use another --id"

  mkdir -p "$root"
  chmod 700 "$root"
  local tmp="$dir.partial"
  rm -rf "$tmp"
  mkdir -p "$tmp/debs"

  record_packages "$tmp"
  collect_debs "$tmp"
  archive_files "$tmp"
  record_services "$tmp"
  [[ -f $k8s_manifests_path/etcd.yaml ]] && save_etcd "$tmp"
  write_meta "$tmp"

  (cd "$tmp" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
  mv "$tmp" "$dir"

  msg "[INFO] Snapshot[\"$snapshot_id\"] of node[\"$inventory_hostname\"] saved in \"$dir\" ($(du -sh "$dir" | cut -f1))"

  return 0
}

record_packages() {
  local out=$1/packages.tsv

  command -v dpkg-query >/dev/null ||
    die "[ERROR] Node[\"$inventory_hostname\"] has no dpkg. A snapshot that can put packages back is taken on debian and ubuntu nodes only so far"

  : > "$out"
  local p v
  for p in "${PACKAGES[@]}"; do
    v=$(dpkg-query -W -f '${db:Status-Status} ${Version}' "$p" 2>/dev/null) || continue
    [[ $v == installed\ * ]] || continue
    printf '%s\t%s\n' "$p" "${v#installed }" >> "$out"
  done

  [[ -s $out ]] || die "[ERROR] Node[\"$inventory_hostname\"] has none of the packages of a cluster node installed"

  return 0
}

collect_debs() {
  local snap=$1
  local missing=()

  if [[ -n $packages_dir ]]; then
    [[ -d $packages_dir ]] || die "[ERROR] No such directory of which path is \"$packages_dir\""
    local f name ver
    while IFS= read -r -d '' f; do
      name=$(dpkg-deb -f "$f" Package 2>/dev/null) || continue
      ver=$(dpkg-deb -f "$f" Version 2>/dev/null) || continue
      [[ $(dpkg-deb -f "$f" Architecture) == "$(dpkg --print-architecture)" || $(dpkg-deb -f "$f" Architecture) == all ]] || continue
      if awk -F'\t' -v n="$name" -v v="$ver" '$1 == n && $2 == v {found = 1} END {exit !found}' "$snap/packages.tsv"; then
        cp -n "$f" "$snap/debs/${name}_${ver//:/%3a}.deb"
      fi
    done < <(find "$packages_dir" -name '*.deb' -print0)
  fi

  local p v
  while IFS=$'\t' read -r p v; do
    [[ -f "$snap/debs/${p}_${v//:/%3a}.deb" ]] || missing+=("$p=$v")
  done < "$snap/packages.tsv"

  [[ ${#missing[@]} -eq 0 ]] && return 0

  if [[ $allow_missing_packages = "true" ]]; then
    msg "[WARN] Node[\"$inventory_hostname\"] snapshot holds no package file for: ${missing[*]}. A rollback from it leaves these at the version the upgrade installed"
    printf '%s\n' "${missing[@]}" > "$snap/debs/MISSING"
    return 0
  fi

  die "[ERROR] Node[\"$inventory_hostname\"] runs packages no file of \"${packages_dir:-<none given>}\" holds: ${missing[*]}\nA rollback could not put them back. Point -e snapshot_packages_dir= at the package directory of the installer that installed them, or pass -e snapshot_allow_missing_packages=true"
}

archive_files() {
  local snap=$1
  local present=()
  local f
  for f in "${FILES[@]}"; do
    [[ -e $f ]] && present+=("${f#/}")
  done

  # The snapshots themselves and the etcd backups are not configuration
  tar -C / --exclude='etc/k8s-installer/*.partial' -czf "$snap/files.tar.gz" "${present[@]}"
  printf '%s\n' "${present[@]/#//}" > "$snap/files.list"

  return 0
}

record_services() {
  local snap=$1

  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    docker compose ls -a --format json > "$snap/services.json"
  else
    echo '[]' > "$snap/services.json"
  fi

  return 0
}

save_etcd() {
  local snap=$1
  local etcdctl="$ki_opt_bundle_path/bin/$(uname -m)/etcdctl"
  [[ -x $etcdctl ]] || etcdctl=$(command -v etcdctl) || die "[ERROR] No etcdctl to take a snapshot of etcd with"

  "$etcdctl" --endpoints=https://127.0.0.1:2379 --command-timeout=60s \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/peer.crt \
    --key=/etc/kubernetes/pki/etcd/peer.key \
    snapshot save "$snap/etcd.db" >/dev/null ||
    die "[ERROR] Failed to take a snapshot of etcd on node[\"$inventory_hostname\"]"
  chmod 600 "$snap/etcd.db"

  return 0
}

write_meta() {
  local snap=$1
  local kubelet_version applied_release
  kubelet_version=$(kubelet --version 2>/dev/null | awk '{print $2}') || kubelet_version=""
  applied_release=$(cat /etc/k8s-installer/applied-release 2>/dev/null) || applied_release=""

  cat > "$snap/meta.yml" <<EOF
id: "$snapshot_id"
node: "$inventory_hostname"
taken_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
kubelet_version: "$kubelet_version"
applied_release: "$applied_release"
has_etcd: $([[ -f $snap/etcd.db ]] && echo true || echo false)
EOF

  return 0
}

import_ki_opt_vars() {
  ki_opt_bundle_path=$(grep -oP "^ki_opt_bundle_path: \K(.+)" < "$vars_path")
}

main
