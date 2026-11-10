#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--node name] [--metrics-path path]
                                  [--report-hugepages]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--node          Name to report this node under
--metrics-path  Also write what was measured to this file, in the prometheus text
                format a node exporter textfile collector reads
--report-hugepages
                Also say when the kernel allocated fewer hugepages of a size than
                this node declared. Left out, what is printed is only what a
                reboot would change
EOF
  exit
}

parse_params() {
  node=""
  metrics_path=""
  report_hugepages="false"

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
    --report-hugepages) report_hugepages="true" ;;
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

# The record of what was put on the command line, which is what this compares
# against, and the record of what was taken off it. See kernel-args-common.sh
source "$SCRIPT_DIR_PATH"/kernel-args-common.sh

# Where the kernel says how many pages of each size it is holding, one directory
# per size it supports: hugepages-2048kB, hugepages-1048576kB
HUGEPAGES_SYSFS_PATH=/sys/kernel/mm/hugepages

# The sizes this node declared and the sizes the kernel allocated, as kB keyed
# associative arrays. Filled by count_hugepages and read by whatever reports
declare -A declared_hugepages=()
declare -A allocated_hugepages=()

# Says whether this node is booted with the kernel command line arguments it was
# configured with, and prints nothing when it is.
#
# Written rather than in force is the whole of what can go wrong here, and the
# two look the same from the outside: the arguments take effect at a boot, so a
# node that was configured and never rebooted reads exactly like one where the
# bootloader did not take them. Reported rather than failed, and to stdout for a
# playbook to collect, the way check-vfio-pci.sh is.
#
# Both directions. An argument that was added is missing from the command line
# until the boot, and one that was taken away is still on it until the boot;
# the first is read off the record and /proc/cmdline, the second off the record
# of what was taken away and the id of the boot it was taken away in. Either is
# a node that has to be rebooted, which is how reboot-k8s-nodes.yml and
# update-cluster.yml read a line printed here.
#
# Nothing is read out of the vars file of the node, and the node is named on the
# command line, so that this can be run at any time - including after
# reset-vars-file.yml has taken that file away, which is where every playbook
# imports the report from, and by an operator who has just rebooted a node and
# come back to confirm it. check-vfio-pci.sh is the same shape for the same
# reason
main() {
  # Measured before the record is looked at, so that a node whose arguments were
  # taken away writes a metric saying it is missing none. Left to the early exit
  # below, the last number it wrote would stand for good
  local missing
  missing=$(missing_args)

  # Read in this boot or taken away: a node that has booted since the arguments
  # were taken off has nothing left to say about them
  local stale
  stale=$(removed_args)

  count_hugepages

  [[ -n $metrics_path ]] && write_metrics_file "$missing" "$stale"

  # A node that was given no argument and had none taken away has nothing to
  # take, which is most of them
  [[ -f $RECORD_PATH || -n $stale ]] || exit 0

  report_missing_args "$missing"
  report_stale_args "$stale"

  # Only when asked, and only once the node is booted with its arguments.
  #
  # What this script prints is read as "this node needs a reboot": reboot-k8s-nodes.yml
  # reboots a node that says anything here and refuses one that still says
  # something after its reboot, and setup-boot-config.yml decides the same way.
  # Pages the kernel could not find are not that - a reboot is what just failed to
  # allocate them, and a node that reported them on this line would be rebooted at
  # every run and refused after each one. So the report of a shortfall goes to the
  # metrics always and to stdout only for the caller that prints rather than
  # decides, which is check-kernel-args.yml at the end of a run.
  #
  # And not before the node is booted with its arguments: then the pages are short
  # because the line never reached the kernel, which the report above already says
  [[ -f $RECORD_PATH && -z $missing && $report_hugepages = "true" ]] && report_short_hugepages

  exit 0
}

# The arguments this node was given and is not booted with, one per line
missing_args() {
  [[ -f $RECORD_PATH ]] || return 0

  local cmdline
  cmdline=$(cat /proc/cmdline)

  local arg
  while IFS= read -r arg; do
    [[ -z $arg ]] && continue
    grep -qwF -- "$arg" <<< "$cmdline" || echo "$arg"
  done < "$RECORD_PATH"

  return 0
}

# Compared as fixed strings rather than as patterns. A kernel argument carries
# dots more often than not, and a dot in a pattern matches anything, so a node
# booted with a differently spelled argument would read as one that took it
report_missing_args() {
  local missing=$1

  [[ -z $missing ]] && return 0

  local joined
  joined=$(tr '\n' ' ' <<< "$missing")

  echo "[WARN] node[\"$node\"] is not booted with kernelCmdlineExtraArgs[\"${joined% }\"]. the configuration is written and takes effect when the node is rebooted"

  return 0
}

# The other half of the same report: taken off the bootloader and still on the
# kernel. Not compared against /proc/cmdline, which would also match an
# argument the site put on the line itself, but decided by whether the node has
# booted since - see removed_args
report_stale_args() {
  local stale=$1

  [[ -z $stale ]] && return 0

  local joined
  joined=$(tr '\n' ' ' <<< "$stale")

  echo "[WARN] node[\"$node\"] is still booted with kernelCmdlineExtraArgs[\"${joined% }\"], which were taken away. they go when the node is rebooted"

  return 0
}

# What the node declared and what it got, per page size.
#
# Declared is read out of the record the way the kernel reads the command line:
# a hugepages= belongs to the hugepagesz= before it, and one that comes before
# any hugepagesz= belongs to the default size, which is default_hugepagesz= if
# the node names one and what the kernel booted with otherwise. The per numa node
# form, hugepages=0:32,1:32, is the sum of its counts: the question here is how
# many pages the node has, not where.
#
# Allocated is what the kernel says, which is the whole point of counting both.
# Asking for pages at boot is not getting them - a 1G page wants a gigabyte of
# physically contiguous memory, and a kernel that can not find enough of them
# takes what it can and says so once, early in dmesg, where nothing reads it. The
# node comes up, kubelet reports the pages it found, and a virtual machine that
# was sized for the declared count is refused or lands on the other numa node.
# The two numbers side by side are what lets a monitoring system say that
count_hugepages() {
  local path
  local kb

  for path in "$HUGEPAGES_SYSFS_PATH"/hugepages-*kB; do
    [[ -f $path/nr_hugepages ]] || continue
    kb=${path##*/hugepages-}
    kb=${kb%kB}
    allocated_hugepages[$kb]=$(cat "$path/nr_hugepages")
  done

  [[ -f $RECORD_PATH ]] || return 0

  local default_kb
  default_kb=$(booted_default_hugepage_kb)
  local size_kb=""
  local arg
  local value

  while IFS= read -r arg; do
    value=${arg#*=}
    case "$arg" in
      default_hugepagesz=*) default_kb=$(hugepage_size_kb "$value") ;;
      hugepagesz=*) size_kb=$(hugepage_size_kb "$value") ;;
      hugepages=*)
        kb=${size_kb:-$default_kb}
        declared_hugepages[$kb]=$(( ${declared_hugepages[$kb]:-0} + $(hugepage_count "$value") ))
        ;;
    esac
  done < "$RECORD_PATH"

  return 0
}

# The default huge page size of the running kernel, in kB. 2048 on x86 unless
# the node booted with default_hugepagesz=, and that is what /proc/meminfo says
booted_default_hugepage_kb() {
  local kb
  kb=$(grep -oP "^Hugepagesize:\s+\K[0-9]+" /proc/meminfo || true)

  echo "${kb:-2048}"

  return 0
}

# A size as the command line spells it - 2M, 1G, 2048K, 1024M - in kB
hugepage_size_kb() {
  local value=$1
  local number=${value%%[KkMmGg]*}
  local unit=${value#"$number"}

  case "$unit" in
    [Gg]*) echo $(( number * 1024 * 1024 )) ;;
    [Mm]*) echo $(( number * 1024 )) ;;
    [Kk]*) echo "$number" ;;
    *) echo $(( number / 1024 )) ;;
  esac

  return 0
}

# A count as the command line spells it: 64, or 0:32,1:32 summed
hugepage_count() {
  local value=$1
  local total=0
  local parts
  local part

  IFS=, read -ra parts <<< "$value"
  for part in "${parts[@]}"; do
    total=$(( total + ${part#*:} ))
  done

  echo "$total"

  return 0
}

# A size in kB as the label of its metric: 2M, 1G, and the kB figure for a size
# that is a whole number of neither
hugepage_size_label() {
  local kb=$1

  if (( kb % (1024 * 1024) == 0 )); then
    echo "$(( kb / 1024 / 1024 ))G"
  elif (( kb % 1024 == 0 )); then
    echo "$(( kb / 1024 ))M"
  else
    echo "${kb}K"
  fi

  return 0
}

# Every size either side knows about, sorted, so that a size the node declared
# and the kernel does not support is reported with nothing allocated and a size
# the kernel supports and the node never asked for is reported with nothing
# declared
hugepage_sizes_kb() {
  printf '%s\n' "${!declared_hugepages[@]}" "${!allocated_hugepages[@]}" | grep . | sort -nu

  return 0
}

# Two shortfalls that look the same in the numbers and are put right in opposite
# ways. A size the kernel has and could not fill is short of memory, and a
# smaller count or a bigger machine fixes it. A size the kernel does not have at
# all is the wrong size for that kernel, and no amount of memory fixes it: which
# sizes exist follows from the page size the kernel was built with, so a kernel
# of 64K pages (arm64, the one DGX OS runs on Grace) has 2M, 512M and 16G where
# one of 4K pages has 2M and 1G. The kernel drops the argument with one line in
# dmesg, and "hugepagesz=1G", which is what every example for x86 says, is the
# one that gets dropped there. The kernel lists a directory for every size it
# has whether or not any page of it was asked for, so a size with no directory
# is one it does not have
report_short_hugepages() {
  local kb
  local declared
  local allocated
  local label

  for kb in $(hugepage_sizes_kb); do
    declared=${declared_hugepages[$kb]:-0}
    [[ $declared -gt 0 ]] || continue
    label=$(hugepage_size_label "$kb")

    if [[ -z ${allocated_hugepages[$kb]+known} ]]; then
      echo "[WARN] node[\"$node\"] declared $declared hugepages of size[\"$label\"] and the kernel it is booted with has no hugepages of that size, so it took none. this kernel has [$(supported_hugepage_labels)]: the sizes follow from the page size the kernel was built with, $(getconf PAGESIZE) bytes here, and more memory does not add one. declare one of those sizes instead"
      continue
    fi

    allocated=${allocated_hugepages[$kb]}
    [[ $declared -gt $allocated ]] || continue

    echo "[WARN] node[\"$node\"] declared $declared hugepages of size[\"$label\"] and the kernel allocated $allocated. a page of that size needs that much contiguous memory at boot, and the kernel takes what it finds and says so only in dmesg"
  done

  return 0
}

# The sizes the running kernel has, as they are written on the command line and
# smallest first: "2M 512M 16G"
supported_hugepage_labels() {
  local kb
  local labels=""

  for kb in $(printf '%s\n' "${!allocated_hugepages[@]}" | grep . | sort -n); do
    labels+="$(hugepage_size_label "$kb") "
  done

  echo "${labels% }"

  return 0
}

# Writes what was measured where a node exporter textfile collector reads it, so
# that the answer is there between playbook runs as well as at the end of one.
#
# Replaced rather than appended to, and moved into place, because a collector
# reads whatever is there when it is scraped. Whether the file is still being
# refreshed is not carried in it: node_exporter already exports
# node_textfile_mtime_seconds for every file it reads
write_metrics_file() {
  local missing=$1
  local stale=$2

  local missing_count=0
  [[ -n $missing ]] && missing_count=$(grep -c . <<< "$missing")

  local stale_count=0
  [[ -n $stale ]] && stale_count=$(grep -c . <<< "$stale")

  mkdir -p "$(dirname "$metrics_path")"

  cat > "$metrics_path".tmp <<EOF
# HELP ki_node_kernel_args_missing Kernel command line arguments this node was given and is not booted with
# TYPE ki_node_kernel_args_missing gauge
ki_node_kernel_args_missing $missing_count
# HELP ki_node_kernel_args_stale Kernel command line arguments taken away from this node that it is still booted with
# TYPE ki_node_kernel_args_stale gauge
ki_node_kernel_args_stale $stale_count
# HELP ki_node_hugepages_declared Hugepages of each size this node was told to allocate at boot
# TYPE ki_node_hugepages_declared gauge
# HELP ki_node_hugepages_allocated Hugepages of each size the kernel of this node is holding
# TYPE ki_node_hugepages_allocated gauge
EOF

  local kb
  local label
  for kb in $(hugepage_sizes_kb); do
    label=$(hugepage_size_label "$kb")
    echo "ki_node_hugepages_declared{size=\"$label\"} ${declared_hugepages[$kb]:-0}" >> "$metrics_path".tmp
    echo "ki_node_hugepages_allocated{size=\"$label\"} ${allocated_hugepages[$kb]:-0}" >> "$metrics_path".tmp
  done

  chmod 0644 "$metrics_path".tmp
  mv -f "$metrics_path".tmp "$metrics_path"

  return 0
}

main
