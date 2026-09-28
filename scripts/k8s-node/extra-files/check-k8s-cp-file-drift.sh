#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--node name] [--mount static-pod=path]... [--metrics-path path] [file...]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--node          Name to report this node under
--mount         A directory of this node mounted into a static pod, written
                <static pod name>=<directory> and given once per volume. Only
                files under one of them are looked at, and each is compared
                against the static pod it is mounted into
--metrics-path  Also write what was measured to this file, in the prometheus text
                format a node exporter textfile collector reads
file...         The files this installer placed on this node
EOF
  exit
}

parse_params() {
  node=""
  mount_processes=()
  mount_paths=()
  metrics_path=""

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --node)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      node="${2-}"
      shift
      ;;
    --metrics-path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      metrics_path="${2-}"
      shift
      ;;
    --mount)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      [[ "${2-}" != *=* ]] && die "[ERROR] Option --mount takes <static pod name>=<directory>, and got: ${2-}"
      mount_processes+=("${2%%=*}")
      mount_paths+=("${2#*=}")
      shift
      ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ -z "${node-}" ]] && die "[ERROR] Missing required option: --node"

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

# Reports a file that was written after the static pod that reads it started.
#
# A control plane component reads what its arguments name once, at start. Placing
# a file again is therefore not the same as the component using it, and the two
# can not be told apart by looking at the node: the file on disk is the new one
# either way. What tells them apart is which happened last.
#
# apply-k8s-cp-extra-files.yml restarts the components of a node whose files it
# changed, so the ordinary path leaves nothing here to find. This is for the
# cases that path can not see - a file edited on a node by hand, or one that
# already held the new bytes when the declaration caught up with it, where the
# copy has nothing to write and so nothing is restarted.
#
# Per static pod rather than against the apiserver for all of them. A mounted
# directory belongs to what mounted it, and the moment to compare against is when
# that process started: the static pods of one node do not start together, and a
# file is only late for the one reading it. Which pods there are arrives on the
# command line, so this holds no list of components of its own and a component
# opened in ki_k8s_cp_components reaches it through the play that calls it.
#
# The process rather than the container, because the process is the thing that
# did the reading, and because asking for it needs nothing but pgrep and /proc:
# this runs on its own as well as out of a playbook, so it reads no vars file and
# calls nothing out of the installer directory.
#
# Only files under a directory that pod has mounted. A file placed anywhere else
# is not something it could have read, so it being newer says nothing. One under
# a mounted directory that no argument names is reported even so: which files the
# arguments reach is worked out from the vars file of the node, and this is meant
# to answer without one.
#
# Reported rather than failed, to stdout for a playbook to collect, the way
# check-vfio-pci.sh is. The answer is a restart of that one component, and
# whoever runs this may not be the one who decides when that happens
# One line per static pod, filled in as each is measured. The metric of a node is
# one file however many components it runs, so it is written once after all of
# them rather than by whichever was looked at last
metric_lines=()

main() {
  # A node that declares no file and is not being metered has nothing to answer.
  # With a metrics path it still has something: the count it wrote last time
  [[ ${#args[@]} -eq 0 && -z $metrics_path ]] && exit 0
  [[ ${#mount_processes[@]} -eq 0 ]] && exit 0

  local process_name
  for process_name in $(printf '%s\n' "${mount_processes[@]}" | sort -u); do
    report_process "$process_name"
  done

  # No component of this node was answerable, so the file goes rather than
  # standing at what the last run said. See write_metrics_file
  if [[ -n $metrics_path ]]; then
    if [[ ${#metric_lines[@]} -gt 0 ]]; then
      write_metrics_file
    else
      delete_metrics_file
    fi
  fi

  return 0
}

report_process() {
  local process_name=$1

  local started_at
  started_at=$(newest_process_started_at "$process_name")
  # Nothing has read anything. A node where that pod is not running has a louder
  # problem than this one, and a line here would be noise on top of it.
  #
  # It contributes no metric either. What is drifted is unanswerable where there
  # is no process for a file to be newer than, and a zero would read as "nothing
  # has drifted", which is the one answer this can not give. The series of that
  # pod gaps, which is what an unanswerable question looks like
  [[ -z $started_at ]] && return 0

  # Measured once and handed to both the metric and the report, the way
  # check-kernel-args.sh does it. Two passes over the same files can disagree
  # about one written between them, and then the report names a file the metric
  # did not count
  local lines=""
  [[ ${#args[@]} -gt 0 ]] && lines=$(drifted_file_lines "$process_name" "$started_at")

  # Counted whatever the report then does with it, so that a node whose files
  # were taken out of the declaration stops reporting the ones it used to hold
  local drifted=0
  [[ -n $lines ]] && drifted=$(grep -c . <<< "$lines")
  metric_lines+=("ki_node_cp_files_drifted{static_pod=\"$process_name\"} $drifted")

  report_drifted_files "$process_name" "$lines"

  return 0
}

# Writes what was measured where a node exporter textfile collector reads it, so
# that the answer is there between playbook runs as well as at the end of one.
# This one answers about running processes, and those restart for their own
# reasons: a file that drifted before a restart has not drifted after one.
#
# Labelled by static pod, the way check-cert-expiry.sh labels by path. The
# question is asked once per component, and one number for the node would say it
# is running something other than what it holds without saying which component
# is, which is the whole of what the operator has to act on.
#
# Replaced rather than appended to, and moved into place, because a collector
# reads whatever is there when it is scraped. Whether the file is still being
# refreshed is not carried in it: node_exporter already exports
# node_textfile_mtime_seconds for every file it reads
write_metrics_file() {
  mkdir -p "$(dirname "$metrics_path")"

  {
    echo "# HELP ki_node_cp_files_drifted Files of this node written after the static pod that reads them started"
    echo "# TYPE ki_node_cp_files_drifted gauge"
    printf '%s\n' "${metric_lines[@]}"
  } > "$metrics_path".tmp

  chmod 0644 "$metrics_path".tmp
  mv -f "$metrics_path".tmp "$metrics_path"

  return 0
}

# So that the series gaps rather than standing still. See main
delete_metrics_file() {
  rm -f "$metrics_path"

  return 0
}

# Silence is the report when the node is running what it holds, the way
# check-vfio-pci.sh says nothing about a node that has taken its configuration.
#
# The command to ask again is part of the report rather than something to go and
# find. What the operator is told to do takes a node out of its load balancers,
# so they come back afterwards to see whether it worked
report_drifted_files() {
  local process_name=$1
  local lines=$2

  [[ -z $lines ]] && return 0

  echo "[WARN] Node[\"$node\"] holds files written after static pod[\"$process_name\"] started, so that pod is running something else"
  echo "$lines" | sed 's/^/  /'
  echo "  Put the change in the declared file and run update-cluster.yml, which restarts this"
  echo "  pod the way the installer does: the node leaves every load balancer while it"
  echo "  happens, and one node is done at a time"
  echo "  Then: ansible-playbook -i inventory.yml playbooks/tasks/check-k8s-cp-file-drift.yml"

  return 0
}

drifted_file_lines() {
  local process_name=$1
  local started_at=$2

  local file
  local modified_at
  for file in "${args[@]}"; do
    [[ -e $file ]] || continue
    is_mounted "$file" "$process_name" || continue

    modified_at=$(stat -c %Y "$file")
    [[ $modified_at -le $started_at ]] && continue

    echo "$file written $(( modified_at - started_at )) seconds after that $process_name started"
  done

  return 0
}

# When the named process that is running now started, in the same seconds since
# the epoch that stat gives for a file, which makes the comparison a subtraction.
#
# Field 22 of /proc/<pid>/stat is when the process started, in clock ticks since
# the machine booted, and btime of /proc/stat is when that boot was. Neither of
# them moves again once the process exists.
#
# Not the modification time of /proc/<pid>, which reads like the same answer and
# is not one. That timestamp belongs to the procfs inode rather than to the
# process, so it is when the directory was last looked up into the dentry cache.
# Measured on rhel 8.10: a process started at 1790053521 answered with 1790053521
# and, immediately after the caches were dropped, with the time of the drop. A
# node under memory pressure does that to itself, and what it answers then is
# "started just now" - which makes every file older than its component and this
# check silent, in exactly the case it exists for.
#
# Not "ps -o lstart=" either, which prints the date in whatever language the node
# is set to and would have to be parsed back - measured: on a node set to another
# language it answers with a date that "date -d" refuses.
#
# The newest of them when there is more than one. A restart leaves the process
# that is shutting down beside the one that has taken over, and it is the one
# that has taken over that read the files. The lowest pid, which is what pgrep
# lists first, is the other one
newest_process_started_at() {
  local process_name=$1

  local boot_at
  boot_at=$(awk '/^btime /{print $2}' /proc/stat)
  local ticks_per_second
  ticks_per_second=$(getconf CLK_TCK)

  local newest=""
  local pid
  local started_at
  while read -r pid; do
    started_at=$(process_started_at "$pid" "$boot_at" "$ticks_per_second")
    [[ -z $started_at ]] && continue
    [[ -n $newest && $started_at -le $newest ]] && continue
    newest=$started_at
  done < <(pgrep -x "$process_name" || true)

  echo "$newest"

  return 0
}

# A process that ended between pgrep and this leaves nothing rather than an
# error. The name of a process can carry a space or a bracket of its own, so the
# fields are counted from the last ")" rather than from the start of the line:
# what follows it is field 3, which puts field 22 twentieth
process_started_at() {
  local pid=$1
  local boot_at=$2
  local ticks_per_second=$3

  local stat_line
  stat_line=$(cat "/proc/$pid/stat" 2>/dev/null) || return 0
  [[ -z $stat_line ]] && return 0

  local fields
  read -r -a fields <<< "${stat_line##*") "}"
  local ticks="${fields[19]-}"
  [[ -z $ticks ]] && return 0

  echo $(( boot_at + ticks / ticks_per_second ))

  return 0
}

is_mounted() {
  local file=$1
  local process_name=$2

  local idx
  for idx in "${!mount_paths[@]}"; do
    [[ ${mount_processes[$idx]} = "$process_name" ]] || continue

    local host_path="${mount_paths[$idx]}"
    # A directory written with a trailing slash is an ordinary way to write one,
    # and without this the match below would be asking for a path carrying two
    while [[ $host_path = */ ]]; do
      host_path="${host_path%/}"
    done

    [[ $file = "$host_path" || $file = "$host_path"/* ]] && return 0
  done

  return 1
}

main
