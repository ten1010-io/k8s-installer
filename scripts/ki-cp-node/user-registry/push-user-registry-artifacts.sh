#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--vars-path path] [--archive-path path]
Available options:
-h, --help       Print this help and exit
-v, --verbose    Print script debug info
--vars-path      File path
--archive-path   The archive build-user-registry-artifacts.sh produced
EOF
  exit
}

parse_params() {
  vars_path=""
  archive_path=""

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
    --archive-path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      archive_path="${2-}"
      shift
      ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ -z "${vars_path-}" ]] && die "[ERROR] Missing required option: --vars-path"
  [[ -z "${archive_path-}" ]] && die "[ERROR] Missing required option: --archive-path"

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

# What a run stopped in the middle of its pushes leaves behind, a failed push or
# a signal alike: the pushes still running, which would go on writing into a
# registry nobody waits on any more; what crane said of each, in push_logs_path;
# and a registry still writable, which takes a push from anywhere until the next
# run of this puts it back
cleanup() {
  # set -E hands the ERR trap to the subshell of a $(...) as well. What is left
  # behind is the main shell's to clean up, once, and it does when the failure
  # reaches it
  [[ $BASHPID == "$$" ]] || return 0
  # Not to be interrupted from here on. A second ctrl-c that landed between the
  # down and the up of set_readonly would leave the registry stopped, which is
  # worse than writable. Ignored rather than reset, because docker compose
  # inherits a signal that is ignored
  trap '' SIGINT SIGTERM SIGHUP
  trap - ERR EXIT

  local running
  running=$(jobs -rp)
  if [[ -n $running ]]; then
    # shellcheck disable=SC2086
    kill $running 2> /dev/null || true
    wait 2> /dev/null || true
  fi
  if [[ -n ${push_logs_path-} ]]; then
    rm -rf "$push_logs_path"
  fi
  if [[ ${registry_writable-} == "true" ]]; then
    # Said to nobody. When the connection this ran over is gone, so is what the
    # output was written to, and docker compose dies of that write before it
    # has done anything, which left the registry writable. In a subshell, so
    # that a registry that does not come back ends the attempt rather than the
    # cleanup, and the warning is reached
    (set_readonly "true") > /dev/null 2>&1 ||
      msg "[WARN] The user registry could not be made readonly again: run this again" || true
  fi
}

set -Eeuo pipefail
trap cleanup ERR EXIT
# A signal ends the run once cleanup is done. Returning from the trap instead
# would carry on where the run was, with the pushes killed and nothing left to
# clean up after it
trap 'cleanup; exit 130' SIGINT
trap 'cleanup; exit 143' SIGTERM
setup_colors
parse_params "$@"

# --- End of CLI template ---

SVC_NAME=ki-cp-user-registry

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""
jinja2_cmd=""
crane_cmd=""

ki_var_root_path=""
ki_etc_services_path=""
ki_tmp_root_path=""
ki_cp_user_registry_port=""
ki_cp_user_registry_push_jobs=""

etc_svc_root_path=""
var_svc_root_path=""

# For cleanup: where the output of the pushes is kept while they run, and whether
# this run has the registry writable
push_logs_path=""
registry_writable="false"

# Puts the artifacts of an archive, images and charts alike, into the user
# registry of this node.
#
# Additive. What is already here and not in the archive stays, because an
# archive says what is being added rather than what the cluster is supposed to
# hold: a workload running on an image left out of this one would otherwise stop
# being able to start. Removing is prune-user-registry.sh, which is asked for
# separately
main() {
  require_file_exists "$vars_path"
  require_file_exists "$archive_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  ki_var_root_path=$($yq_cmd '.ki_var_root_path' < "$vars_path")
  ki_etc_services_path=$($yq_cmd '.ki_etc_services_path' < "$vars_path")
  ki_tmp_root_path=$($yq_cmd '.ki_tmp_root_path' < "$vars_path")
  ki_cp_user_registry_port=$($yq_cmd '.ki_cp_user_registry_port' < "$vars_path")
  ki_cp_user_registry_push_jobs=$($yq_cmd '.ki_cp_user_registry_push_jobs' < "$vars_path")
  resolve_push_jobs

  etc_svc_root_path="$ki_etc_services_path"/$SVC_NAME
  var_svc_root_path="$ki_var_root_path"/$SVC_NAME
  require_directory_exists "$etc_svc_root_path"

  local artifacts_path
  artifacts_path="$ki_tmp_root_path"/$SVC_NAME-artifacts
  extract_archive "$artifacts_path"

  # Writable only while this is pushing, and readonly again before it returns.
  # Between those two the registry would take a push from anywhere, and a push
  # that did not come through here reaches one node out of several
  registry_writable="true"
  set_readonly "false"
  push_artifacts "$artifacts_path"
  set_readonly "true"
  registry_writable="false"

  rm -rf "$artifacts_path"
  report_usage

  return 0
}

extract_archive() {
  local artifacts_path=$1

  rm -rf "$artifacts_path"
  mkdir -p "$(dirname "$artifacts_path")"
  # pigz reads, writes and checks on threads of their own while it inflates, so
  # an archive of several GB is unpacked sooner where it is installed. The same
  # gzip either way, and plain tar where it is not
  if command -v pigz > /dev/null 2>&1; then
    tar -I pigz -xf "$archive_path" -C "$(dirname "$artifacts_path")"
  else
    tar xzf "$archive_path" -C "$(dirname "$artifacts_path")"
  fi

  require_directory_exists "$artifacts_path"

  return 0
}

set_readonly() {
  local readonly_enabled=$1

  $jinja2_cmd -D var_svc_root_path="$var_svc_root_path" \
              -D readonly_enabled="$readonly_enabled" \
              --format yaml \
              -o "$etc_svc_root_path""/compose.yml" \
              "$SCRIPT_DIR_PATH"/templates/compose.yml.j2 "$vars_path" || return 1

  # Each step is checked by hand because cleanup calls this where set -e is off,
  # and going on from a compose.yml that was not rendered would bring the
  # registry back the way it was and say nothing
  docker compose -f "$etc_svc_root_path/compose.yml" down || return 1
  docker compose -f "$etc_svc_root_path/compose.yml" up -d || return 1
  wait_registry_ready 60

  return 0
}

# How many pushes push_artifacts runs at once. A number the site set is taken as
# it is. Left null, it is half the cpus of this node, at least 2 and at most 4:
# constant-vars.yml says why. Said once in the output either way, because the
# count is what a slow or a loaded node is first asked about
resolve_push_jobs() {
  if [[ -z $ki_cp_user_registry_push_jobs || $ki_cp_user_registry_push_jobs = "null" ]]; then
    local cpus
    if command -v nproc > /dev/null 2>&1; then
      cpus=$(nproc)
    else
      cpus=$(getconf _NPROCESSORS_ONLN)
    fi
    [[ $cpus =~ ^[1-9][0-9]*$ ]] ||
      die "[ERROR] Failed to count the cpus of this node. got \"$cpus\""

    ki_cp_user_registry_push_jobs=$((cpus / 2))
    [[ $ki_cp_user_registry_push_jobs -lt 2 ]] && ki_cp_user_registry_push_jobs=2
    [[ $ki_cp_user_registry_push_jobs -gt 4 ]] && ki_cp_user_registry_push_jobs=4
    msg "[INFO] Pushing $ki_cp_user_registry_push_jobs artifacts at a time ($cpus cpus)"
    return 0
  fi

  [[ $ki_cp_user_registry_push_jobs =~ ^[1-9][0-9]*$ ]] ||
    die "[ERROR] Variable[\"ki_cp_user_registry_push_jobs\"] is \"$ki_cp_user_registry_push_jobs\", which is not a count of one or more"
  msg "[INFO] Pushing $ki_cp_user_registry_push_jobs artifacts at a time (ki_cp_user_registry_push_jobs)"

  return 0
}

# The path of a layout under the artifacts directory is the reference it is
# pushed to, which is what build-user-registry-artifacts.sh laid it out for.
#
# Up to ki_cp_user_registry_push_jobs pushes run at once. What crane says goes
# to a file of its own push and is printed when that push ends, so the lines of
# two pushes never mix. The first push that fails stops any further one from
# starting; the ones already running are let finish, and every one of them that
# failed is named before this fails. With one job that is the loop this used to
# be: push, and stop at the first failure
push_artifacts() {
  local artifacts_path=$1

  local logs_path
  logs_path=$(mktemp -d -p "$ki_tmp_root_path")
  push_logs_path=$logs_path

  local -a pids=()
  local -A refs_by_pid=()
  local -A logs_by_pid=()
  local -a failed_refs=()
  local log

  local layout
  local ref
  for layout in $(find "$artifacts_path" -name oci-layout -printf '%h\n' | sort); do
    reap_pushes
    [[ ${#failed_refs[@]} -gt 0 ]] && break
    while [[ ${#pids[@]} -ge $ki_cp_user_registry_push_jobs ]]; do
      wait -n || true
      reap_pushes
    done
    [[ ${#failed_refs[@]} -gt 0 ]] && break

    ref=${layout#"$artifacts_path"/}
    msg "[INFO] Pushing artifact[\"$ref\"]"
    # Loopback, and the certificate of the registry is issued for its dns name
    # rather than for an address, so the name it would be verified against is not
    # the one being connected to
    log="$logs_path/${#logs_by_pid[@]}.log"
    $crane_cmd push --insecure "$layout" "127.0.0.1:$ki_cp_user_registry_port/$ref" > /dev/null 2> "$log" &
    pids+=("$!")
    refs_by_pid[$!]=$ref
    logs_by_pid[$!]=$log
  done

  while [[ ${#pids[@]} -gt 0 ]]; do
    wait -n || true
    reap_pushes
  done

  rm -rf "$logs_path"
  push_logs_path=""

  if [[ ${#failed_refs[@]} -gt 0 ]]; then
    for ref in "${failed_refs[@]}"; do
      msg "[ERROR] Failed to push artifact[\"$ref\"]"
    done
    die "[ERROR] Failed to push ${#failed_refs[@]} artifact(s)"
  fi

  return 0
}

# Takes every push of push_artifacts that has ended out of pids, prints what
# crane said and records the push in failed_refs when it failed. A push counts as
# ended once bash no longer lists it as a running job, which is asked of bash
# rather than of the pid: a pid is handed out again once its process is gone.
# bash keeps the status of a finished job for the wait below, and the status is
# asked for by pid because the wait -n that woke the caller can not say whose it
# was on the bash of rhel 8
reap_pushes() {
  local alive
  alive=$(jobs -rp)
  alive=" ${alive//$'\n'/ } "

  local -a running=()
  local pid
  for pid in "${pids[@]}"; do
    if [[ $alive == *" $pid "* ]]; then
      running+=("$pid")
      continue
    fi
    # under the name of its artifact: with several pushes ending together, what
    # crane said would otherwise have to be matched to an artifact by its order
    if [[ -s ${logs_by_pid[$pid]} ]]; then
      msg "[INFO] crane on artifact[\"${refs_by_pid[$pid]}\"]:"
      cat >&2 "${logs_by_pid[$pid]}"
    fi
    if ! wait "$pid"; then
      failed_refs+=("${refs_by_pid[$pid]}")
    fi
  done
  pids=("${running[@]}")

  return 0
}

# Said out loud because nothing else will. The registry only grows from here
# until somebody prunes it, and the first sign of that being a problem should
# not be a node running out of disk
report_usage() {
  msg "[INFO] The user registry of this node holds $(du -sh "$var_svc_root_path" | cut -f1)"

  return 0
}

wait_registry_ready() {
  local timeout=$1

  local elapsed=0
  while true; do
    if curl -sk --max-time 3 "https://127.0.0.1:$ki_cp_user_registry_port/v2/" > /dev/null 2>&1; then
      return 0
    fi
    [[ $elapsed -ge $timeout ]] && die "[ERROR] Failed to wait for the registry being ready. timeout occurred"

    sleep 2s
    elapsed=$(("$elapsed" + 2))
  done
}

import_ki_opt_vars() {
  ki_opt_root_path=$(grep -oP  "^ki_opt_root_path: \K(.+)" < "$vars_path")
  ki_opt_scripts_path=$(grep -oP  "^ki_opt_scripts_path: \K(.+)" < "$vars_path")
  ki_opt_bundle_path=$(grep -oP  "^ki_opt_bundle_path: \K(.+)" < "$vars_path")
  ki_opt_venv_path=$(grep -oP  "^ki_opt_venv_path: \K(.+)" < "$vars_path")
}

setup_cmd_vars() {
  yq_cmd="$ki_opt_bundle_path/bin/$(uname -m)/yq"
  jinja2_cmd="$ki_opt_venv_path/bin/jinja2"
  crane_cmd="$ki_opt_bundle_path/bin/$(uname -m)/crane"
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
