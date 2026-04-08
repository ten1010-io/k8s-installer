#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--vars-path path]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--vars-path     File path
EOF
  exit
}

parse_params() {
  vars_path=""

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

ki_env_path=""
ki_env_scripts_path=""
ki_env_bin_path=""
ki_env_ki_venv_path=""

yq_cmd=""
jinja2_cmd=""
python3_cmd=""

ki_etc_charts_path=""
ki_tmp_root_path=""
k8s_load_balancers=""
ih_to_hostname_dict=""

resources_root_path=""

main() {
  require_file_exists "$vars_path"
  import_ki_env_vars
  setup_cmd_vars
  require_directory_exists "$ki_env_path"
  validate_ki_env_directory

  ki_etc_charts_path=$($yq_cmd '.ki_etc_charts_path' < "$vars_path")
  ki_tmp_root_path=$($yq_cmd '.ki_tmp_root_path' < "$vars_path")
  k8s_load_balancers=$($yq_cmd -o json '.k8s_load_balancers' < "$vars_path")
  ih_to_hostname_dict=$($yq_cmd -o json '.ih_to_hostname_dict' < "$vars_path")

  resources_root_path=$ki_etc_charts_path/k8s/cilium/resources

  msg "[INFO] Started to wait for cilium CRDs being ready"
  wait_cilium_crds_ready 300
  kubectl label node --all node.kubernetes.io/exclude-from-external-load-balancers-
  create_api_resources

  return 0
}

wait_cilium_crds_ready() {
  local timeout=$1
  local elapsed=0

  while true; do
    local exit_code=0
    kubectl get crd ciliumloadbalancerippools.cilium.io > /dev/null 2>&1 || exit_code=$?
    [[ $exit_code -eq 0 ]] && break
    [[ $elapsed -ge $timeout ]] && die "[ERROR] Failed to wait for cilium CRDs being ready. timeout occurred"

    sleep 3s
    elapsed=$(("$elapsed" + 3))
  done

  return 0
}

create_api_resources() {
  create_resource_files
  [[ $(has_files "$resources_root_path") = "true" ]] && kubectl apply -f "$resources_root_path"

  return 0
}

create_resource_files() {
  mkdir -p "$resources_root_path"

  local lbs_len
  lbs_len=$($yq_cmd --null-input "$k8s_load_balancers | length")

  local name
  local vip
  local nodes
  for (( i=0; i<"$lbs_len"; i++ )); do
    name=$($yq_cmd --null-input "$k8s_load_balancers | .[$i][\"name\"]")
    vip=$($yq_cmd --null-input "$k8s_load_balancers | .[$i][\"vip\"]")
    nodes=$($yq_cmd -o json --null-input "$k8s_load_balancers | .[$i][\"nodes\"]")

    [[ $vip = "null" ]] && die "[ERROR] Variable[\"vip\"] must not be null for load balancer \"$name\""

    create_pool_yml_file "$name" "$vip"
    create_announcement_yml_file "$name" "$nodes"
  done

  return 0
}

create_pool_yml_file() {
  local name=$1
  local vip=$2

  local resource_name="$name.load-balancers.k8s-installer.ten1010.io"

  local tmp_file_path
  tmp_file_path="$ki_tmp_root_path/tmp-templates-vars.yml"
  touch "$tmp_file_path"
  $yq_cmd -i ".name = \"$resource_name\"" "$tmp_file_path"
  $yq_cmd -i ".lb_name = \"$name\"" "$tmp_file_path"
  $yq_cmd -i ".address = \"$vip\"" "$tmp_file_path"
  $jinja2_cmd --format yaml -o "$resources_root_path/$resource_name-pool.yml" "$SCRIPT_DIR_PATH"/templates/resources/lb-ip-pool.yml.j2 "$tmp_file_path"
  rm "$tmp_file_path"

  return 0
}

create_announcement_yml_file() {
  local name=$1
  local nodes=$2

  local resource_name="$name.load-balancers.k8s-installer.ten1010.io"

  local knn_list
  knn_list=$(get_knn_list "$nodes")

  local tmp_file_path
  tmp_file_path="$ki_tmp_root_path/tmp-templates-vars.yml"
  touch "$tmp_file_path"
  $yq_cmd -i ".name = \"$resource_name\"" "$tmp_file_path"
  $yq_cmd -i ".lb_name = \"$name\"" "$tmp_file_path"
  $yq_cmd -o json -i ".knn_list = $knn_list" "$tmp_file_path"
  $jinja2_cmd --format yaml -o "$resources_root_path/$resource_name-announcement.yml" "$SCRIPT_DIR_PATH"/templates/resources/lb-l2-announcement-policy.yml.j2 "$tmp_file_path"
  rm "$tmp_file_path"

  return 0
}

get_knn_list() {
  local nodes=$1

  local knn_list="[]"
  local knn
  for ih in $($yq_cmd '. | join(" ")' <<< "$nodes"); do
    knn=$(get_knn "$ih")
    knn_list=$($yq_cmd -o json ". + [\"$knn\"]" <<< "$knn_list")
  done

  echo "$knn_list"
}

get_knn() {
  local ih=$1

  convert_into_knn "$(get_hostname "$ih")"
  return 0
}

convert_into_knn() {
  local hostname=$1

  sed "s/_/-/g" <<< "${hostname,,}"

  return 0
}

get_hostname() {
  local ih=$1

  local hostname
  hostname=$($yq_cmd <<< "$ih_to_hostname_dict" ".$ih")
  [[ -z $hostname || $hostname = "null" ]] && die "[ERROR] Fail to get hostname for ih[\"$ih\"]"

  echo "$hostname"
}

has_files() {
  local dir_path=$1

  if [[ -n "$(ls -A "$dir_path" 2>/dev/null)" ]]; then echo "true"; else echo "false"; fi

  return 0
}

import_ki_env_vars() {
  ki_env_path=$(grep -oP  "^ki_env_path: \K(.+)" < "$vars_path")
  ki_env_scripts_path=$(grep -oP  "^ki_env_scripts_path: \K(.+)" < "$vars_path")
  ki_env_bin_path=$(grep -oP  "^ki_env_bin_path: \K(.+)" < "$vars_path")
  ki_env_ki_venv_path=$(grep -oP  "^ki_env_ki_venv_path: \K(.+)" < "$vars_path")
}

setup_cmd_vars() {
  yq_cmd="$ki_env_bin_path/bin/yq"
  jinja2_cmd="$ki_env_ki_venv_path/bin/jinja2"
  python3_cmd="$ki_env_ki_venv_path/bin/python3"
}

validate_ki_env_directory() {
  require_directory_exists "$ki_env_scripts_path"
  require_directory_exists "$ki_env_bin_path"
  require_directory_exists "$ki_env_ki_venv_path"

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
