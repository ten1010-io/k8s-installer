#!/usr/bin/env bash
# Brings the ki cp services a 5.0.x installer left on a ki cp node to the names
# this installer runs them under, so that setup-*.sh --update of this installer
# can take them over. Run by adopt-legacy.yml before those --update runs.
#
# What differs, and what is done about it:
#
#   ki-cp-aipub-registry  the registry of the images of the applications, port
#                         5001. This installer runs the same registry, same
#                         image, port and layout of its data, as
#                         ki-cp-user-registry. The old project is stopped, its
#                         data directory renamed to the new one, and its compose
#                         directory kept aside. setup-user-registry.sh --update
#                         then starts the new project on the same data
#   ki-cp-k8s-cp-lb       same project name, but the haproxy.cfg of 5.0.x names
#                         its servers server1.. and has no admin socket, so the
#                         drain an upgrade does through lb-admin.sh can not
#                         reach it. Nothing done here: setup-k8s-cp-lb.sh
#                         --update renders it anew, and the old files are kept
#                         aside here first
#   the other projects    same names. Kept aside here, re-rendered by the
#                         upgrade
#
# Everything kept aside goes to <ki_var_root_path>/adopt-legacy/<time>, which is
# also what restore-node.sh of a rollback does not need: it puts the snapshot
# back, and the snapshot holds the same files.

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] --vars-path path
EOF
  exit
}

parse_params() {
  vars_path=""

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --vars-path) vars_path="${2:?}"; shift ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  [[ -z $vars_path ]] && die "[ERROR] Missing required option: --vars-path"

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

OLD_REGISTRY="ki-cp-aipub-registry"
NEW_REGISTRY="ki-cp-user-registry"

main() {
  [[ -f $vars_path ]] || die "[ERROR] No such file of which path is \"$vars_path\""
  ki_opt_bundle_path=$(grep -oP "^ki_opt_bundle_path: \K(.+)" < "$vars_path")
  yq_cmd="$ki_opt_bundle_path/bin/$(uname -m)/yq"

  ki_var_root_path=$($yq_cmd '.ki_var_root_path' < "$vars_path")
  ki_etc_services_path=$($yq_cmd '.ki_etc_services_path' < "$vars_path")
  ki_cp_user_registry_port=$($yq_cmd '.ki_cp_user_registry_port' < "$vars_path")
  inventory_hostname=$($yq_cmd '.inventory_hostname' < "$vars_path")

  kept_path="$ki_var_root_path/adopt-legacy/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$kept_path"
  [[ -d $ki_etc_services_path ]] && cp -a "$ki_etc_services_path" "$kept_path/services"

  rename_registry

  msg "[INFO] ki cp services of node[\"$inventory_hostname\"] are ready to be taken over. What they were is kept in \"$kept_path\""

  return 0
}

project_exists() {
  docker compose ls -a --format json | $yq_cmd -p json -e ".[] | select(.Name == \"$1\")" >/dev/null 2>&1
}

rename_registry() {
  if ! project_exists "$OLD_REGISTRY"; then
    msg "[INFO] Node[\"$inventory_hostname\"] runs no service[\"$OLD_REGISTRY\"]"
    return 0
  fi
  project_exists "$NEW_REGISTRY" &&
    die "[ERROR] Node[\"$inventory_hostname\"] runs both service[\"$OLD_REGISTRY\"] and service[\"$NEW_REGISTRY\"]. Which one holds the images can not be told here. Stop the one that is not in use and run this again"

  local old_port
  old_port=$($yq_cmd '.services.registry.ports[0]' < "$ki_etc_services_path/$OLD_REGISTRY/compose.yml")
  [[ ${old_port%%:*} = "$ki_cp_user_registry_port" ]] ||
    msg "[WARN] Service[\"$OLD_REGISTRY\"] listens on ${old_port%%:*}, and service[\"$NEW_REGISTRY\"] will listen on $ki_cp_user_registry_port. Everything that pulls from the old port has to be pointed at the new one"

  [[ -e $ki_var_root_path/$NEW_REGISTRY ]] &&
    die "[ERROR] \"$ki_var_root_path/$NEW_REGISTRY\" already exists, so the data of service[\"$OLD_REGISTRY\"] can not be moved there. Look at what it holds and move it away first"

  msg "[INFO] Stopping service[\"$OLD_REGISTRY\"] of node[\"$inventory_hostname\"]"
  docker compose -f "$ki_etc_services_path/$OLD_REGISTRY/compose.yml" down

  msg "[INFO] Moving its data to \"$ki_var_root_path/$NEW_REGISTRY\""
  mv "$ki_var_root_path/$OLD_REGISTRY" "$ki_var_root_path/$NEW_REGISTRY"
  mv "$ki_etc_services_path/$OLD_REGISTRY" "$kept_path/$OLD_REGISTRY.compose"

  return 0
}

main
