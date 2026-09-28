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

# .gitattributes says why this matters: every file of this repository is consumed
# on a linux node, and a shell script that reaches one with CRLF has a carriage
# return in its shebang and does not run. The attribute keeps the working tree
# right on a fresh checkout whatever core.autocrlf says; this looks at what is
# actually stored, which is what a node ends up with and what an attribute added
# after the fact does not retroactively fix.
#
# It is a script rather than a few lines in the workflow so that it can be run
# before pushing, which is the only place it can still be cheap to fix. The
# tooling that rewrites a script is what writes the carriage returns, and it does
# so without saying anything
KI_ROOT_PATH=$(cd "$SCRIPT_DIR_PATH/.." &>/dev/null && pwd -P)

main() {
  cd "$KI_ROOT_PATH" || die "[ERROR] No such directory as \"$KI_ROOT_PATH\""

  # i/ is how the file is stored and w/ is how it was checked out. "-text" is a
  # file git treats as binary and "none" is a file with no line endings at all,
  # and neither of those is a shell script with a carriage return in it.
  local bad
  bad=$(git ls-files --eol |
    awk '$1 !~ /^i\/(lf|none|-text)$/ || $2 !~ /^w\/(lf|none|-text)$/') ||
    die "[ERROR] Failed to ask git how the files of this repository are stored, so how they are stored can not be told"

  if [[ -n $bad ]]; then
    msg "$bad"
    die "[ERROR] The files above are not stored with LF. Fix them with: git add --renormalize ."
  fi

  msg "[INFO] Every file of this repository is stored with LF"

  return 0
}

main
