#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--vars-path path] [--metadata-path path]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--vars-path     File path
--metadata-path File path of what to put on the node object
EOF
  exit
}

parse_params() {
  vars_path=""
  metadata_path=""

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
    --metadata-path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      metadata_path="${2-}"
      shift
      ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ -z "${vars_path-}" ]] && die "[ERROR] Missing required option: --vars-path"
  [[ -z "${metadata_path-}" ]] && die "[ERROR] Missing required option: --metadata-path"

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

# The separator between the fields of a taint. A key, a value and an effect are
# all qualified names, so none of them can hold it
FIELD_SEPARATOR="|"

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""

ki_cp_node_label_key=""
knn=""
ki_cp_node=""

declare -A current_labels=()
declare -A desired_labels=()
declare -A managed_label_keys=()
declare -A current_taints=()
declare -A desired_taints=()
declare -A managed_taint_ids=()

# Puts the labels and the taints of one node onto its node object, and takes away
# the ones that were there and are not asked for any more.
#
# What it takes away is bounded on purpose. Only a key this installer applied on
# the last run - which the caller reads out of the record every node keeps - or
# the ki cp label, which nothing else writes, is ever removed. A label a site put
# on a node by hand, the ones kubelet sets, and the control plane taint kubeadm
# adds are all left where they are, because nothing here knows why they are
# there.
#
# Runs on a control plane node, since that is where the kubeconfig kubeadm wrote
# is, and is told which node it is acting on rather than acting on the node it is
# running on
main() {
  require_file_exists "$vars_path"
  require_file_exists "$metadata_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  ki_cp_node_label_key=$($yq_cmd '.ki_cp_node_label_key' < "$vars_path")
  knn=$($yq_cmd '.node' < "$metadata_path")
  # Lower cased because yq prints a scalar back the way it was written, so a file
  # carrying True rather than true would read as neither
  ki_cp_node=$($yq_cmd '.kiCpNode' < "$metadata_path")
  ki_cp_node=${ki_cp_node,,}

  read_current_node
  read_desired
  apply_labels
  apply_taints

  return 0
}

# One read of the node object rather than one per key. It is also what makes this
# quiet when there is nothing to do: every write below is conditioned on the node
# not already holding the value, so a run that changes nothing says nothing
read_current_node() {
  local node_json
  node_json=$(kubectl get node "$knn" -o json) ||
    die "[ERROR] Failed to read node[\"$knn\"] of the cluster"

  local line
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    current_labels["${line%%=*}"]="${line#*=}"
  done < <($yq_cmd -p json '.metadata.labels // {} | to_entries | .[] | .key + "=" + .value' <<< "$node_json")

  while IFS= read -r line; do
    [[ -z $line ]] && continue
    local key="${line%%"$FIELD_SEPARATOR"*}"
    local rest="${line#*"$FIELD_SEPARATOR"}"
    current_taints["$key$FIELD_SEPARATOR${rest#*"$FIELD_SEPARATOR"}"]="${rest%%"$FIELD_SEPARATOR"*}"
  done < <($yq_cmd -p json ".spec.taints // [] | .[] | .key + \"$FIELD_SEPARATOR\" + (.value // \"\") + \"$FIELD_SEPARATOR\" + .effect" <<< "$node_json")

  return 0
}

# The ki cp label is desired rather than special: a node of the group has it, a
# node that left the group does not, and it is managed either way so that leaving
# the group takes it off
read_desired() {
  local line
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    desired_labels["${line%%=*}"]="${line#*=}"
  done < <($yq_cmd '.labels // {} | to_entries | .[] | .key + "=" + .value' < "$metadata_path")

  while IFS= read -r line; do
    [[ -z $line ]] && continue
    managed_label_keys["$line"]=1
  done < <($yq_cmd '.previousLabels // {} | keys | .[]' < "$metadata_path")

  [[ $ki_cp_node = "true" ]] && desired_labels["$ki_cp_node_label_key"]=""
  managed_label_keys["$ki_cp_node_label_key"]=1

  while IFS= read -r line; do
    [[ -z $line ]] && continue
    local key="${line%%"$FIELD_SEPARATOR"*}"
    local rest="${line#*"$FIELD_SEPARATOR"}"
    desired_taints["$key$FIELD_SEPARATOR${rest#*"$FIELD_SEPARATOR"}"]="${rest%%"$FIELD_SEPARATOR"*}"
  done < <(read_taints_of ".taints")

  while IFS= read -r line; do
    [[ -z $line ]] && continue
    local key="${line%%"$FIELD_SEPARATOR"*}"
    local rest="${line#*"$FIELD_SEPARATOR"}"
    managed_taint_ids["$key$FIELD_SEPARATOR${rest#*"$FIELD_SEPARATOR"}"]=1
  done < <(read_taints_of ".previousTaints")

  return 0
}

read_taints_of() {
  local path=$1

  $yq_cmd "$path // [] | .[] | .key + \"$FIELD_SEPARATOR\" + (.value // \"\") + \"$FIELD_SEPARATOR\" + .effect" < "$metadata_path"

  return 0
}

apply_labels() {
  local key
  for key in "${!desired_labels[@]}"; do
    local value="${desired_labels[$key]}"
    [[ ${current_labels[$key]+set} = "set" && ${current_labels[$key]} = "$value" ]] && continue

    msg "[INFO] Labelling node[\"$knn\"] with label[\"$key=$value\"]"
    kubectl label node "$knn" "$key=$value" --overwrite > /dev/null ||
      die "[ERROR] Failed to put label[\"$key=$value\"] on node[\"$knn\"]"
  done

  for key in "${!managed_label_keys[@]}"; do
    [[ ${desired_labels[$key]+set} = "set" ]] && continue
    [[ ${current_labels[$key]+set} != "set" ]] && continue

    msg "[INFO] Taking label[\"$key\"] off node[\"$knn\"]"
    kubectl label node "$knn" "$key-" > /dev/null ||
      die "[ERROR] Failed to take label[\"$key\"] off node[\"$knn\"]"
  done

  return 0
}

apply_taints() {
  local id
  for id in "${!desired_taints[@]}"; do
    local value="${desired_taints[$id]}"
    [[ ${current_taints[$id]+set} = "set" && ${current_taints[$id]} = "$value" ]] && continue

    local key="${id%%"$FIELD_SEPARATOR"*}"
    local effect="${id##*"$FIELD_SEPARATOR"}"
    # A taint with no value is written without the equals sign, which is how
    # kubectl takes one and how the node reports it back
    local spec="$key:$effect"
    [[ -n $value ]] && spec="$key=$value:$effect"

    msg "[INFO] Tainting node[\"$knn\"] with taint[\"$spec\"]"
    kubectl taint node "$knn" "$spec" --overwrite > /dev/null ||
      die "[ERROR] Failed to put taint[\"$spec\"] on node[\"$knn\"]"
  done

  for id in "${!managed_taint_ids[@]}"; do
    [[ ${desired_taints[$id]+set} = "set" ]] && continue
    [[ ${current_taints[$id]+set} != "set" ]] && continue

    local key="${id%%"$FIELD_SEPARATOR"*}"
    local effect="${id##*"$FIELD_SEPARATOR"}"

    msg "[INFO] Taking taint[\"$key:$effect\"] off node[\"$knn\"]"
    kubectl taint node "$knn" "$key:$effect-" > /dev/null ||
      die "[ERROR] Failed to take taint[\"$key:$effect\"] off node[\"$knn\"]"
  done

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
