#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

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
}

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT
setup_colors
parse_params "$@"

# --- End of CLI template ---

# A node runs a script by its path, so one that is not executable in the tree is
# "command not found" there and nowhere earlier. The mode is easy to lose without
# noticing: git on a windows checkout reports 644 for every file, so a script
# authored on one goes in without the bit and every local check still passes. It
# shows up when a playbook first reaches a node, which is the most expensive
# place to find it.
#
# A file with no shebang is sourced rather than executed and is expected to stay
# 644. That is what tells the two apart, so there is no list of exceptions to
# keep here
KI_ROOT_PATH=$(cd "$SCRIPT_DIR_PATH/.." &>/dev/null && pwd -P)

main() {
  cd "$KI_ROOT_PATH" || die "[ERROR] No such directory as \"$KI_ROOT_PATH\""

  local failed="false"
  local mode
  local path

  while read -r mode _ _ path; do
    case "$path" in
      *.sh) ;;
      *) continue ;;
    esac

    if has_shebang "$path"; then
      [[ $mode = "100755" ]] && continue
      msg "[ERROR] File[\"$path\"] starts with a shebang and is mode[\"$mode\"]. A node executes it by"
      msg "        path, so it has to be 100755. Fix it with: git update-index --chmod=+x $path"
      failed="true"
      continue
    fi

    [[ $mode = "100644" ]] && continue
    msg "[ERROR] File[\"$path\"] has no shebang and is mode[\"$mode\"]. A file without one is sourced"
    msg "        rather than executed, so it is expected to be 100644"
    failed="true"
  done < <(git ls-files -s scripts)

  [[ $failed = "true" ]] && die "[ERROR] Some scripts carry a mode that does not match what they are"

  msg "[INFO] Every script of scripts/ carries the mode its shebang says it should"

  return 0
}

has_shebang() {
  local path=$1

  [[ -f $path ]] || return 1
  [[ $(head -c 2 "$path") = "#!" ]]
}

main
