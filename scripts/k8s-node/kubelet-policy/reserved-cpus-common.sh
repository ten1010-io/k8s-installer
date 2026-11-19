# shellcheck shell=bash

# What check-reserved-cpus.sh and check-kubelet-policy.sh both ask of a set of
# reserved cpus: which of its numbers the node has, which numa node each sits on
# and whether the threads of a core are in it together. One of them is given the
# set the inventory names and the other reads the one kubelet runs with, and the
# two have to count the same way or the check and the metric disagree about the
# same node.
#
# Sourced, never run. It leaves the shell options alone, because the script that
# sources it has already set its own.

# Where the kernel publishes the cpus it has online and the threads of each
# core, and which cpus belong to which numa node. Overridable so that this can
# be pointed at a directory of fixtures and checked without a machine that has
# two sockets, the way list-pci-devices.sh is
CPU_SYSFS_PATH=${CPU_SYSFS_PATH:-/sys/devices/system/cpu}
NUMA_NODES_PATH=${NUMA_NODES_PATH:-/sys/devices/system/node}

# The set being asked about and the cpus of the node, keyed by cpu number.
# Filled by load_reserved_cpus and read by everything below it
declare -A reserved_cpus=()
declare -A online_cpus=()

# The numbers of a cpu list as the kernel and kubelet write one, "0-3,48-51", one
# per line. Read as decimal whatever they look like: a number written 08 is
# cpu 8 and not an octal that does not exist
expand_cpu_list() {
  local list=${1//[[:space:]]/}
  local parts
  local part
  local first
  local last
  local cpu

  IFS=, read -ra parts <<< "$list"

  for part in "${parts[@]}"; do
    [[ -n $part ]] || continue

    first=${part%-*}
    last=${part#*-}

    for (( cpu = 10#$first; cpu <= 10#$last; cpu++ )); do
      echo "$cpu"
    done
  done

  return 0
}

# The cpus the node has online, as the kernel writes them, and nothing on a
# machine that does not say. Online rather than present, because that is the
# set kubelet builds its topology from: a cpu that was taken offline is one
# kubelet does not have
online_cpu_list() {
  [[ -f $CPU_SYSFS_PATH/online ]] || return 0

  tr -d '[:space:]' < "$CPU_SYSFS_PATH"/online

  return 0
}

load_reserved_cpus() {
  local cpu

  reserved_cpus=()
  online_cpus=()

  for cpu in $(expand_cpu_list "$1"); do
    reserved_cpus[$cpu]=1
  done

  for cpu in $(expand_cpu_list "$(online_cpu_list)"); do
    online_cpus[$cpu]=1
  done

  return 0
}

# The reserved cpus the node does not have online, one per line
absent_reserved_cpus() {
  local cpu

  for cpu in "${!reserved_cpus[@]}"; do
    [[ -n ${online_cpus[$cpu]-} ]] || echo "$cpu"
  done | sort -n

  return 0
}

# The threads of the core a cpu is on, as the kernel writes them, "0,48". A
# machine that does not say has one thread to a core
siblings_list_of() {
  local path=$CPU_SYSFS_PATH/cpu$1/topology/thread_siblings_list

  if [[ -f $path ]]; then
    tr -d '[:space:]' < "$path"
  else
    echo -n "$1"
  fi

  return 0
}

# One line per core the set holds some threads of and not all:
#
#   <threads of the core>  <those reserved>  <those not>
#
# tab separated, each a comma separated list, in the order of the cores
half_reserved_core_lines() {
  local cpu
  local sibling
  local siblings
  local held
  local free
  local -A seen=()

  for cpu in $(printf '%s\n' "${!reserved_cpus[@]}" | grep . | sort -n); do
    [[ -n ${online_cpus[$cpu]-} ]] || continue

    siblings=$(siblings_list_of "$cpu")
    [[ -z ${seen[$siblings]-} ]] || continue
    seen[$siblings]=1

    held=""
    free=""
    for sibling in $(expand_cpu_list "$siblings"); do
      if [[ -n ${reserved_cpus[$sibling]-} ]]; then
        held+="${held:+,}$sibling"
      else
        free+="${free:+,}$sibling"
      fi
    done

    [[ -n $free ]] || continue

    printf '%s\t%s\t%s\n' "$siblings" "$held" "$free"
  done

  return 0
}

# One line per numa node that has cpus:
#
#   <numa node>  <its cpus>
#
# tab separated and sorted by number, since the glob puts node10 before node2. A
# node with an empty cpulist is memory only - a cxl expander, hbm in flat mode -
# and has nothing that could be reserved, so it is left out. A kernel with no
# numa sysfs sees one pool, which is reported as node 0 holding every cpu
numa_cpu_lines() {
  local path
  local cpus

  if ! compgen -G "$NUMA_NODES_PATH/node*/cpulist" > /dev/null; then
    printf '0\t%s\n' "$(online_cpu_list)"
    return 0
  fi

  for path in "$NUMA_NODES_PATH"/node*; do
    [[ -f $path/cpulist ]] || continue

    cpus=$(tr -d '[:space:]' < "$path"/cpulist)
    [[ -n $cpus ]] || continue

    printf '%s\t%s\n' "${path##*/node}" "$cpus"
  done | sort -n

  return 0
}

# One line per numa node that has cpus:
#
#   <numa node>  <reserved cpus on it>  <cores of it reserved whole>
#
# tab separated. The first count is in threads, which is the unit the set is
# written in and the one kubelet takes off the allocatable cpu of the node. A
# core counts as whole when every thread of it is reserved, and is counted on
# the numa node its threads are on
numa_reserved_lines() {
  local id
  local cpus
  local cpu
  local sibling
  local siblings
  local count
  local whole
  local complete
  local -A seen=()

  while IFS=$'\t' read -r id cpus; do
    count=0
    whole=0
    seen=()

    for cpu in $(expand_cpu_list "$cpus"); do
      [[ -n ${reserved_cpus[$cpu]-} && -n ${online_cpus[$cpu]-} ]] || continue
      count=$(( count + 1 ))

      siblings=$(siblings_list_of "$cpu")
      [[ -z ${seen[$siblings]-} ]] || continue
      seen[$siblings]=1

      complete=1
      for sibling in $(expand_cpu_list "$siblings"); do
        [[ -n ${reserved_cpus[$sibling]-} ]] || complete=0
      done
      whole=$(( whole + complete ))
    done

    printf '%s\t%s\t%s\n' "$id" "$count" "$whole"
  done < <(numa_cpu_lines)

  return 0
}
