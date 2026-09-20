#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
TMP_REGISTRY_NAME=ki-tmp-registry

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
EOF
  exit
}

parse_params() {
  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

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

  if [[ $(container_exists "$TMP_REGISTRY_NAME") = "true" ]]; then
    docker stop $TMP_REGISTRY_NAME > /dev/null
    docker rm $TMP_REGISTRY_NAME > /dev/null
  fi

  rm -rf "$tmp_dir"
}

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT
setup_colors
parse_params "$@"

# --- End of CLI template ---

YQ_CMD=$SCRIPT_DIR_PATH/bin/bin/yq
TMP_REGISTRY_PORT=57636
OUTPUT_PATH="$SCRIPT_DIR_PATH/bin/registry-data"

registry_image=""
registries=""

tmp_dir=""

main() {
  [[ ! -e $SCRIPT_DIR_PATH/bin ]] && die "[ERROR] Directory \"bin\" not exists. execute \"download-bin.sh\" first"
  [[ $(has_command docker) = "false" ]] && die "[ERROR] Command[\"docker\"] not exists"

  registry_image=$($YQ_CMD '.registry_image' < "$SCRIPT_DIR_PATH/registry-images.yml")
  registries=$($YQ_CMD -o json '.registries' < "$SCRIPT_DIR_PATH/registry-images.yml")

  mkdir -p "$OUTPUT_PATH"
  tmp_dir=$(mktemp -d)

  for (( i=0; i<$($YQ_CMD --null-input "$registries | length"); i++ )); do
    local registry_name
    local images
    local mappings
    registry_name=$($YQ_CMD --null-input "$registries | .[$i][\"name\"]")
    images=$($YQ_CMD -o json --null-input "$registries | .[$i][\"images\"]")
    mappings=$($YQ_CMD -o json --null-input "$registries | .[$i][\"mappings\"]")

    mkdir "$tmp_dir/registry"

    docker run \
      --name $TMP_REGISTRY_NAME \
      -q \
      -d \
      -p 127.0.0.1:$TMP_REGISTRY_PORT:5000 \
      -v "$tmp_dir/registry:/var/lib/registry" \
      "$registry_image" > /dev/null

    local full_name
    local repo_and_tag
    local tmp_full_name
    for full_name in $($YQ_CMD --null-input "$images | join(\" \")"); do
      repo_and_tag=$(get_repo_and_tag_from_mappings "$full_name" "$mappings")
      [[ -z $repo_and_tag ]] &&
        repo_and_tag=$(parse_repo_and_tag "$full_name")
      [[ -z $repo_and_tag ]] &&
        die "[ERROR] Invalid image name[\"$full_name\"]"
      tmp_full_name="127.0.0.1:$TMP_REGISTRY_PORT/$repo_and_tag"

      docker pull "$full_name"
      docker tag "$full_name" "$tmp_full_name"
      docker push "$tmp_full_name"
      docker rmi "$tmp_full_name"
    done

    docker stop $TMP_REGISTRY_NAME > /dev/null
    docker rm $TMP_REGISTRY_NAME > /dev/null

    tar czfv "$OUTPUT_PATH/$registry_name.tgz" -C "$tmp_dir" registry
    rm -rf "$tmp_dir/registry"
  done

  return 0
}

get_repo_and_tag_from_mappings() {
  local full_name=$1
  local mappings=$2

  for (( i=0; i<$($YQ_CMD --null-input "$mappings | length"); i++ )); do
    local from
    local to
    from=$($YQ_CMD --null-input "$mappings | .[$i][\"from\"]")
    to=$($YQ_CMD --null-input "$mappings | .[$i][\"to\"]")
    if [[ $full_name = "$from" ]]; then
      echo "$to"
      return 0
    fi
  done

  echo ""
  return 0
}

parse_repo_and_tag() {
  local full_name=$1

  echo "$full_name" | grep -oP '^([a-z0-9A-Z]\.)*[a-z0-9-]+\.([a-z0-9]{2,24})+(\.co\.([a-z0-9]{2,24})|\.([a-z0-9]{2,24}))*(:[0-9]+)?/?\K[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*(\/[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*)*:[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}'

  return 0
}

container_exists() {
  local name=$1

  local exit_code=0
  docker inspect "$name" > /dev/null 2>&1 || exit_code=$?

  if [[ $exit_code = 0 ]]; then echo "true"; else echo "false"; fi

  return 0
}

has_command() {
  local command
  command=$1

  exit_code=0
  type "$command" &>/dev/null || exit_code=$?
  if [[ $exit_code = 0 ]]; then echo "true"; else echo "false"; fi

  return 0
}

main
