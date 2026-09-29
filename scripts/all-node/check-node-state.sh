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

ki_opt_root_path=""
ki_opt_scripts_path=""
ki_opt_bundle_path=""
ki_opt_venv_path=""

yq_cmd=""
jinja2_cmd=""
etcdctl_cmd=""

playbook=""
inventory_hostname=""
target_node=""
target_node_op=""
ki_cp_ha_mode=""

ki_var_root_path=""
docker_root_path=""
ki_ephemeral_root_path=""
k8s_etcd_data_path=""
ki_preflight_disk_free_min=""
ki_preflight_disk_free_percent_min=""
ki_preflight_clock_offset_max_seconds=""

knn_to_ih_dict=""

# The node check_k8s_cluster_matches_inventory does not require the cluster and
# the inventory to agree about, held as a list so that it can be empty.
#
# A playbook that names a node with target_node_op is adding it or taking it
# away, so the two lists differ by exactly that node while the run is what closes
# the gap: add-node has not joined it yet, remove-node and remove-broken-node are
# taking it out. reboot-nodes names a node with no op, and for it the answer is
# the opposite - the node it is about to drain has to be a member already, and a
# node that is in the inventory and not in the cluster is exactly what has to be
# refused there rather than exempted
exempt_ih_list="[]"

main() {
  require_file_exists "$vars_path"
  import_ki_opt_vars
  setup_cmd_vars
  require_directory_exists "$ki_opt_root_path"
  validate_ki_opt_directory

  playbook=$($yq_cmd '.playbook' < "$vars_path")
  inventory_hostname=$($yq_cmd '.inventory_hostname' < "$vars_path")
  target_node=$($yq_cmd '.target_node' < "$vars_path")
  target_node_op=$($yq_cmd '.target_node_op' < "$vars_path")
  ki_cp_ha_mode=$($yq_cmd '.ki_cp_ha_mode' < "$vars_path")
  hostname_to_ih_dict=$($yq_cmd -o json '.hostname_to_ih_dict' < "$vars_path")

  ki_var_root_path=$($yq_cmd '.ki_var_root_path' < "$vars_path")
  docker_root_path=$($yq_cmd '.docker_root_path' < "$vars_path")
  ki_ephemeral_root_path=$($yq_cmd '.ki_ephemeral_root_path' < "$vars_path")
  k8s_etcd_data_path=$($yq_cmd '.k8s_etcd_data_path' < "$vars_path")
  ki_preflight_disk_free_min=$($yq_cmd '.ki_preflight_disk_free_min' < "$vars_path")
  ki_preflight_disk_free_percent_min=$($yq_cmd '.ki_preflight_disk_free_percent_min' < "$vars_path")
  ki_preflight_clock_offset_max_seconds=$($yq_cmd '.ki_preflight_clock_offset_max_seconds' < "$vars_path")

  knn_to_ih_dict=$(get_knn_to_ih_dict)

  [[ -n $target_node_op && $target_node_op != "null" ]] && exempt_ih_list="[\"$target_node\"]"

  # About this machine rather than about the cluster it is in, so they run for
  # every playbook and before the switch below. A node that has no room left or
  # whose clock is wrong fails whatever it was asked to do, at a place that does
  # not name either of them
  check_disk_space "$(get_node_check_severity)"
  check_clock "$(get_node_check_severity)"
  check_kernel_modules "$(get_node_check_severity)"
  require_no_etcd_alarm

  if [[ $playbook = "setup-cluster" ]]; then
    require_linux_packages_not_installed
    return 0
  fi

  if [[ $playbook = "add-node" || $playbook = "remove-node" ]]; then
    if [[ $inventory_hostname = "$target_node" ]]; then
      [[ $target_node_op = "add" ]] && require_linux_packages_not_installed
      return 0
    fi

    require_node_matches_its_role
    [[ $(is_k8s_cp_node "$inventory_hostname") = "true" ]] && check_k8s_cluster_matches_inventory

    return 0
  fi

  # Nothing about a single node is asked here. Whether the cluster can afford to
  # lose one is check-k8s-cluster-healthy.sh, which the play asks again between
  # nodes, and whether a node needs a reboot at all is decided from what it is
  # booted with. What is left for this is the run as a whole: an inventory that no
  # longer matches the cluster is a run that would drain a node the cluster does
  # not have
  if [[ $playbook = "reboot-nodes" ]]; then
    require_node_matches_its_role
    [[ $(is_k8s_cp_node "$inventory_hostname") = "true" ]] && check_k8s_cluster_matches_inventory

    return 0
  fi

  # The node being removed is not in the play, so this never runs on it. What it
  # checks instead is that the nodes that are left can carry out the removal:
  # deleting the node from the cluster and taking its etcd member out are both
  # writes, and a cluster that has lost quorum can not take either
  if [[ $playbook = "remove-broken-node" ]]; then
    require_node_matches_its_role

    if [[ $(is_k8s_cp_node "$inventory_hostname") = "true" ]]; then
      require_k8s_cluster_reachable
      require_etcd_quorum
      require_hostname_known "$target_node"
      check_k8s_cluster_matches_inventory
    fi

    return 0
  fi

  return 0
}

# Whether the two checks above stop the run or only say something.
#
# A playbook that is taking a cluster apart or rescuing a node that has already
# failed is refused by nothing here: the operator came to fix or remove, and a
# full disk or a wrong clock is a reason they came rather than a reason to send
# them away. Everything else is building on this node and has no chance of
# ending well
get_node_check_severity() {
  case "$playbook" in
    reset-cluster | remove-broken-node) echo "warn" ;;
    *) echo "fail" ;;
  esac

  return 0
}

report_or_die() {
  local severity=$1
  local msg=$2

  [[ $severity = "fail" ]] && die "[ERROR] $msg"
  msg "[WARN] $msg"

  return 0
}

# The room left where this installer and kubernetes put things. One filesystem is
# reported once however many of those paths are on it, which on a node with no
# separate devices is all of them.
#
# Two thresholds rather than one. The absolute is what an upgrade actually needs,
# since it pushes a whole release of images into the registry on the ki cp nodes,
# and it is the number that means anything on a large disk. The percentage is for
# the small ones, where a filesystem can be over the absolute and still be close
# enough to the eviction thresholds of kubelet to start moving pods around
check_disk_space() {
  local severity=$1

  # A threshold that is not a number is the site saying not to ask, which is what
  # null in vars.yml arrives here as. validate-hostvars.py allows it on purpose
  local min_bytes
  min_bytes=$(to_bytes "$ki_preflight_disk_free_min") || return 0
  [[ $ki_preflight_disk_free_percent_min =~ ^[0-9]+$ ]] || return 0

  local seen_mounts=""
  local report=""
  local path
  for path in / "$ki_var_root_path" "$docker_root_path" "$ki_ephemeral_root_path" "$k8s_etcd_data_path"; do
    [[ -z $path || $path = "null" ]] && continue

    # The nearest parent that exists rather than the path itself. On a node being
    # set up none of these directories has been created yet, and a path that was
    # skipped for not existing left a separate filesystem for /var unmeasured on
    # setup-cluster, which is the one playbook still early enough to say so. The
    # parent is on the filesystem the directory will be created on
    local probe=$path
    while [[ ! -d $probe && $probe != "/" && $probe != "." ]]; do
      probe=$(dirname "$probe")
    done
    [[ -d $probe ]] || continue

    local line
    line=$(df -B1 --output=target,avail,size "$probe" 2>/dev/null | tail -1) || continue
    [[ -z $line ]] && continue

    local mount avail size
    read -r mount avail size <<< "$line"
    [[ $avail =~ ^[0-9]+$ && $size =~ ^[0-9]+$ && $size -gt 0 ]] || continue
    [[ " $seen_mounts " == *" $mount "* ]] && continue
    seen_mounts="$seen_mounts $mount"

    local percent
    percent=$(( avail * 100 / size ))

    [[ $avail -ge $min_bytes && $percent -ge $ki_preflight_disk_free_percent_min ]] && continue

    # Collected rather than reported here, because reporting is what ends the run
    # when the severity is fail: an operator told about the first full filesystem
    # clears it, runs again and is told about the next one
    [[ -n $report ]] && report="$report\n"
    report="${report}Filesystem[\"$mount\"] has $(to_human "$avail") free, which is $percent% of it"
  done

  [[ -z $report ]] && return 0

  report_or_die "$severity" \
    "$report\nThis node needs at least $ki_preflight_disk_free_min and $ki_preflight_disk_free_percent_min% free on each. What fills them is the images of the registries, the etcd snapshots and the container storage, and prune-k8s-registry.yml is what takes the images of releases this cluster no longer runs back out"

  return 0
}

# Whether the kernel of this node can load what a node of the cluster loads:
# overlay for the container storage, br_netfilter so that bridged traffic reaches
# the filter, and the netfilter matches that kube-proxy, kubelet and docker write
# their rules with, which the nft backed iptables loads through nft_compat.
#
# A distribution kernel used to have all of these in its base package, so nothing
# asked. rhel 10 moved br_netfilter and every xt_ module into kernel-modules-extra,
# which a minimal install does not hold, and a node without them fails a long
# way from here: configure-linux.sh stops at modprobe, or docker and kube-proxy
# start and then refuse every rule they try to write, saying only that an
# extension revision is not supported. The bundle can not carry those modules,
# since they are built for one kernel and the node decides which kernel that is.
#
# Asked with a dry run rather than by loading, because check-node-state.sh
# changes nothing about a node, and a module that is built in answers the dry
# run the same way one on disk does
check_kernel_modules() {
  local severity=$1

  local missing=""
  local module
  for module in overlay br_netfilter nf_conntrack nft_compat xt_conntrack xt_comment xt_addrtype xt_mark xt_nat xt_multiport xt_statistic xt_recent; do
    modprobe -n "$module" &>/dev/null && continue
    missing="$missing $module"
  done

  [[ -z $missing ]] && return 0

  report_or_die "$severity" \
    "Kernel[\"$(uname -r)\"] can not load module[$missing ]. The container runtime and kube-proxy write their rules with these, and this installer does not carry kernel modules. On rhel 10 they are in kernel-modules-extra, so install the one of the running kernel and run this again:\n  dnf install kernel-modules-extra-$(uname -r)"

  return 0
}

# Both of the time daemons this installer knows how to set up leave their verdict
# in the same place: timedatectl reads the flag the kernel carries, which is set
# by whichever of them is disciplining the clock. The offset is the part they
# answer differently, so the daemon that is there decides how it is asked rather
# than the operating system, which is the same question one step further away
check_clock() {
  local severity=$1

  # Null is the site saying not to ask, and it turns off the synchronised flag
  # below as well as the offset. A node with no time source at all can not be
  # answered by any threshold, so an off switch is the only thing that lets an
  # air-gapped site that runs no ntp take this release
  [[ $ki_preflight_clock_offset_max_seconds =~ ^[0-9]+$ ]] || return 0

  local synchronized
  synchronized=$(timedatectl show -p NTPSynchronized --value 2>/dev/null) || return 0

  if [[ $synchronized != "yes" ]]; then
    report_or_die "$severity" \
      "The clock of this node is not synchronised to a time source. Certificates are issued against it and etcd measures its peers by it, so a node that is wrong about the time produces failures that name neither. Check the time daemon of this node before going on"
    return 0
  fi

  local offset_seconds
  offset_seconds=$(get_clock_offset_seconds)

  # Anything that is not a number is not an answer, and not an answer is not a
  # failure: the flag above has already said the clock is being disciplined.
  # chronyc is why this is a pattern rather than a test for the empty string - it
  # prints "506 Cannot talk to daemon" on its standard output, not its standard
  # error, when the daemon it asks is not running, so a node whose chronyd is
  # merely stopped reported that sentence as its offset and refused the playbook
  [[ $offset_seconds =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]] || return 0

  local over
  over=$(awk -v offset="$offset_seconds" -v max="$ki_preflight_clock_offset_max_seconds" \
    'BEGIN { if (offset < 0) offset = -offset; print (offset > max) ? "true" : "false" }')
  [[ $over = "true" ]] || return 0

  report_or_die "$severity" \
    "The clock of this node is ${offset_seconds}s away from its time source, which is more than the ${ki_preflight_clock_offset_max_seconds}s this allows. It reports itself as synchronised, so the source it is following is the thing to look at"

  return 0
}

# Empty when there is no answer to be had, which is not a failure: the flag read
# above has already answered whether the clock is being disciplined at all. The
# caller takes anything that is not a number as that same silence, which is what
# a daemon that is installed but not running comes back as
get_clock_offset_seconds() {
  if [[ $(has_command chronyc) = "true" ]]; then
    # Field 5 of the csv is the offset in seconds, signed, as chrony last
    # measured it
    chronyc -c tracking 2>/dev/null | cut -d, -f5
    return 0
  fi

  # timesync-status rather than show-timesync, which has no offset to give: the
  # timesync1 interface carries the four timestamps of the last packet and
  # nothing derived from them, and this is the command that does the arithmetic.
  # show-timesync -p Offset answers with an empty string on every version of
  # systemd, so reading it left the offset half of this check never running on
  # the nodes that take timesyncd, which is every ubuntu one
  local offset_line
  offset_line=$(timedatectl timesync-status 2>/dev/null | grep -E "^ *Offset: ") || return 0

  # A formatted timespan rather than a number, so it is read as one: a sign, then
  # however many <value><unit> pieces systemd chose to print it in. Anything that
  # does not read as that leaves nothing behind, which is the silence above
  awk -v line="$offset_line" 'BEGIN {
    sub(/^ *Offset: */, "", line)
    sign = (line ~ /^-/) ? -1 : 1
    sub(/^[-+]/, "", line)

    count = split(line, piece, " ")
    for (i = 1; i <= count; i++) {
      if (match(piece[i], /^[0-9]+(\.[0-9]+)?/) == 0) exit
      value = substr(piece[i], 1, RLENGTH) + 0
      unit = substr(piece[i], RLENGTH + 1)

      if (unit == "us") seconds += value / 1000000
      else if (unit == "ms") seconds += value / 1000
      else if (unit == "s") seconds += value
      else if (unit == "min") seconds += value * 60
      else if (unit == "h") seconds += value * 3600
      else if (unit == "d") seconds += value * 86400
      else if (unit == "" && value == 0) seconds += 0
      else exit
    }

    printf "%.6f", sign * seconds
  }'

  return 0
}

# An alarm is etcd refusing writes, which is the cluster refusing writes: nothing
# is created, no node joins, and the playbooks that change a cluster fail at
# whichever write they reach first, naming that write rather than the alarm.
#
# Only the playbooks that go on to change a live cluster ask. Setting one up has
# no etcd to ask yet, taking one apart does not care, and a node being rescued is
# already being asked about quorum where that matters: require_etcd_quorum tells
# an alarm apart from a lost quorum, so remove-broken-node is answered there and
# answered correctly. check-node-state asks because asking is all it came to do
require_no_etcd_alarm() {
  case "$playbook" in
    add-node | remove-node | upgrade-cluster | check-node-state) ;;
    *) return 0 ;;
  esac

  [[ $(is_k8s_cp_node "$inventory_hostname") = "true" ]] || return 0
  [[ $inventory_hostname = "$target_node" && $target_node_op = "add" ]] && return 0

  local alarms
  alarms=$(get_etcd_alarms)
  [[ -z $alarms ]] && return 0

  die "[ERROR] Etcd has raised an alarm on this cluster, so it is refusing writes and this playbook would fail partway through:\n$alarms\nDefragment every member and disarm the alarm with defrag-etcd.yml before running this again"
}

# Empty when there is no alarm, and empty again when the cluster can not be asked
# at all. Those are different things and neither of them is this function's to
# judge: a cluster that can not be reached is not a cluster with an alarm, and
# deciding that here would block the playbook that came to fix it.
# require_k8s_cluster_reachable and require_etcd_quorum are where that is decided
get_etcd_alarms() {
  local output
  output=$($etcdctl_cmd --endpoints=https://127.0.0.1:2379 --command-timeout=10s alarm list 2>/dev/null) || return 0
  [[ -z ${output//[[:space:]]/} ]] && return 0

  echo "$output"

  return 0
}

to_bytes() {
  local value=$1

  [[ $value =~ ^[0-9]+$ ]] && { echo "$value"; return 0; }
  [[ $value =~ ^([0-9]+)(Ki|Mi|Gi|Ti|Pi|Ei)$ ]] || return 1

  local number=${BASH_REMATCH[1]}
  local unit=${BASH_REMATCH[2]}
  local exponent
  case "$unit" in
    Ki) exponent=1 ;;
    Mi) exponent=2 ;;
    Gi) exponent=3 ;;
    Ti) exponent=4 ;;
    Pi) exponent=5 ;;
    Ei) exponent=6 ;;
  esac

  awk -v number="$number" -v exponent="$exponent" 'BEGIN { printf "%d", number * (1024 ^ exponent) }'

  return 0
}

to_human() {
  local bytes=$1

  awk -v bytes="$bytes" 'BEGIN {
    split("B Ki Mi Gi Ti Pi", unit, " ")
    i = 1
    while (bytes >= 1024 && i < 6) { bytes /= 1024; i++ }
    printf (i == 1) ? "%d%s" : "%.1f%s", bytes, unit[i]
  }'

  return 0
}

has_command() {
  local name=$1

  if command -v "$name" > /dev/null 2>&1; then echo "true"; else echo "false"; fi

  return 0
}

# That this node is still the node the inventory says it is: the packages are on
# it and it is running the ki cp services if it is a ki cp node and none of them
# if it is not. Every playbook that works on a cluster that already exists asks
# this of every node it is going to touch, which is why it is one function rather
# than the same five lines in each branch of main
require_node_matches_its_role() {
  require_linux_packages_installed

  if [[ $(is_ki_cp_node "$inventory_hostname") = "true" ]]; then
    require_ki_cp_node
  else
    require_not_ki_cp_node
  fi

  return 0
}

require_k8s_cluster_reachable() {
  local output
  local exit_code=0
  output=$(kubectl get --raw /readyz 2>&1) || exit_code=$?

  [[ $exit_code != 0 ]] && die "[ERROR] K8s cluster not reachable from this node\n$output"

  return 0
}

# A linearizable read, so it answers whether the cluster can still be written to
# rather than whether this member is up. Removing a node is a write, and a
# cluster that has lost quorum takes none: with two members one loss is already
# too many, and no playbook can recover from that. Restoring etcd comes first
require_etcd_quorum() {
  local output
  local exit_code=0
  output=$($etcdctl_cmd --endpoints=https://127.0.0.1:2379 --command-timeout=10s endpoint health 2>&1) || exit_code=$?

  [[ $exit_code = 0 ]] && return 0

  # An alarm refuses the same write a lost quorum refuses, so it fails this the
  # same way, and the two want opposite answers: restoring etcd over an alarm
  # throws away everything written since the snapshot to undo what a defragment
  # undoes. The alarm is asked for rather than read out of the message above,
  # because a cluster that has really lost quorum can not answer that question
  # either, which is what makes the answer worth having
  local alarms
  alarms=$(get_etcd_alarms)
  [[ -n $alarms ]] &&
    die "[ERROR] Etcd has raised an alarm on this cluster, so it is refusing the writes this playbook came to make. The cluster still has quorum:\n$alarms\nDefragment every member and disarm the alarm with defrag-etcd.yml before running this again"

  die "[ERROR] Etcd cluster has no quorum, so no node can be removed from it. Restore etcd first\n$output"
}

# The node of the cluster a node of the inventory is, is matched by hostname, and
# a node that can not be reached did not report one. gather-facts.yml fills it in
# from what the last run recorded, so the only way to be without it is for the
# node to have been out of reach ever since that record began
require_hostname_known() {
  local ih=$1

  [[ $(is_k8s_node "$ih") = "false" ]] && return 0

  local hostname
  hostname=$($yq_cmd ".ih_to_hostname_dict.$ih" < "$vars_path")
  [[ -n $hostname && $hostname != "null" ]] && return 0

  local msg="[ERROR] Hostname of node[\"$ih\"] is not known, so which node of the k8s cluster it is"
  msg+=" can not be established. No run of gather-facts has reached it since the node record began."
  msg+=" Add it to the ih_to_hostname_dict of the node record file and run this again"
  die "$msg"

  return 0
}

require_linux_packages_installed() {
  [[ $("$ki_opt_scripts_path/systemctl.sh" exists containerd) = "false" ]] && die "[ERROR] Linux package[\"containerd\"] not installed"
  [[ $("$ki_opt_scripts_path/systemctl.sh" exists docker) = "false" ]] && die "[ERROR] Linux package[\"containerd\"] not installed"
  [[ $("$ki_opt_scripts_path/systemctl.sh" exists kubelet) = "false" ]] && die "[ERROR] Linux package[\"containerd\"] not installed"

  return 0
}

require_linux_packages_not_installed() {
  [[ $("$ki_opt_scripts_path/systemctl.sh" exists containerd) = "true" ]] && die "[ERROR] Linux package[\"containerd\"] already installed"
  [[ $("$ki_opt_scripts_path/systemctl.sh" exists docker) = "true" ]] && die "[ERROR] Linux package[\"docker\"] already installed"
  [[ $("$ki_opt_scripts_path/systemctl.sh" exists kubelet) = "true" ]] && die "[ERROR] Linux package[\"kubelet\"] already installed"

  return 0
}

require_ki_cp_node() {
  [[ $ki_cp_ha_mode = "true" && $(docker_service_exists ki-cp-keepalived) = "false" ]] &&
    die "[ERROR] Node is expected to be ki cp node but, docker service[\"ki-cp-keepalived\"] not exists"
  [[ $(docker_service_exists ki-cp-dns-server) = "false" ]] &&
    die "[ERROR] Node is expected to be ki cp node but, docker service[\"ki-cp-dns-server\"] not exists"
  [[ $(docker_service_exists ki-cp-ntp-server) = "false" ]] &&
    die "[ERROR] Node is expected to be ki cp node but, docker service[\"ki-cp-ntp-server\"] not exists"
  [[ $(docker_service_exists ki-cp-k8s-cp-lb) = "false" ]] &&
    die "[ERROR] Node is expected to be ki cp node but, docker service[\"ki-cp-k8s-cp-lb\"] not exists"
  [[ $(docker_service_exists ki-cp-k8s-registry) = "false" ]] &&
    die "[ERROR] Node is expected to be ki cp node but, docker service[\"ki-cp-k8s-registry\"] not exists"

  return 0
}

require_not_ki_cp_node() {
  [[ $(docker_service_exists ki-cp-keepalived) = "true" ]] &&
    die "[ERROR] Node is expected not to be ki cp node but, docker service[\"ki-cp-keepalived\"] exists"
  [[ $(docker_service_exists ki-cp-dns-server) = "true" ]] &&
    die "[ERROR] Node is expected not to be ki cp node but, docker service[\"ki-cp-dns-server\"] exists"
  [[ $(docker_service_exists ki-cp-ntp-server) = "true" ]] &&
    die "[ERROR] Node is expected not to be ki cp node but, docker service[\"ki-cp-ntp-server\"] exists"
  [[ $(docker_service_exists ki-cp-k8s-cp-lb) = "true" ]] &&
    die "[ERROR] Node is expected not to be ki cp node but, docker service[\"ki-cp-k8s-cp-lb\"] exists"
  [[ $(docker_service_exists ki-cp-k8s-registry) = "true" ]] &&
    die "[ERROR] Node is expected not to be ki cp node but, docker service[\"ki-cp-k8s-registry\"] exists"

  return 0
}

check_k8s_cluster_matches_inventory() {
  check_k8s_cluster_all_nodes
  check_k8s_cluster_cp_nodes

  return 0
}

check_k8s_cluster_all_nodes() {
  local diff_ih_list
  local diff_len
  local ih_list1
  local ih_list2

  ih_list1=$(get_k8s_cluster_all_ih_list)
  if [[ $target_node_op = "add" ]]; then
    ih_list2=$($yq_cmd -o json --null-input "$(get_inventory_k8s_node_ih_list) - [\"$target_node\"]")
  else
    ih_list2=$(get_inventory_k8s_node_ih_list)
  fi
  diff_ih_list=$($yq_cmd -o json --null-input "$ih_list1 - $ih_list2")
  diff_len=$($yq_cmd --null-input "$diff_ih_list | length")
  if [[ $diff_len -gt 0 ]]; then
    [[ $diff_len = 1 && $target_node_op = "add" && $($yq_cmd --null-input "$diff_ih_list | .[0]") = "$target_node" ]] &&
      die "[ERROR] K8s cluster already has node[\"$target_node\"]"

    die "[ERROR] K8s cluster has nodes that are not in inventory\n$diff_ih_list"
  fi

  ih_list1=$(get_k8s_cluster_all_ih_list)
  ih_list2=$($yq_cmd -o json --null-input "$(get_inventory_k8s_node_ih_list) - $exempt_ih_list")
  diff_ih_list=$($yq_cmd -o json --null-input "$ih_list2 - $ih_list1")
  diff_len=$($yq_cmd --null-input "$diff_ih_list | length")
  [[ $diff_len -gt 0 ]] && die "[ERROR] Inventory has k8s nodes that are not in k8s cluster\n$diff_ih_list"

  return 0
}

check_k8s_cluster_cp_nodes() {
  local diff_ih_list
  local diff_len
  local ih_list1
  local ih_list2

  ih_list1=$(get_k8s_cluster_cp_ih_list)
  if [[ $target_node_op = "add" ]]; then
    ih_list2=$($yq_cmd -o json --null-input "$(get_inventory_k8s_cp_node_ih_list) - [\"$target_node\"]")
  else
    ih_list2=$(get_inventory_k8s_cp_node_ih_list)
  fi
  diff_ih_list=$($yq_cmd -o json --null-input "$ih_list1 - $ih_list2")
  diff_len=$($yq_cmd --null-input "$diff_ih_list | length")
  if [[ $diff_len -gt 0 ]]; then
    [[ $diff_len = 1 && $target_node_op = "add" && $($yq_cmd --null-input "$diff_ih_list | .[0]") = "$target_node" ]] &&
      die "[ERROR] K8s cluster already has control plane node[\"$target_node\"]"

    die "[ERROR] K8s cluster has control plane nodes that are not in inventory\n$diff_ih_list"
  fi

  ih_list1=$(get_k8s_cluster_cp_ih_list)
  ih_list2=$($yq_cmd -o json --null-input "$(get_inventory_k8s_cp_node_ih_list) - $exempt_ih_list")
  diff_ih_list=$($yq_cmd -o json --null-input "$ih_list2 - $ih_list1")
  diff_len=$($yq_cmd --null-input "$diff_ih_list | length")
  [[ $diff_len -gt 0 ]] && die "[ERROR] Inventory has k8s control plane nodes that are not in k8s cluster\n$diff_ih_list"

  return 0
}

get_k8s_cluster_all_ih_list() {
  local k8s_cluster_all_node_list
  k8s_cluster_all_node_list=$(get_k8s_cluster_all_node_list)

  local ih_list="[]"
  for knn in $($yq_cmd '. | join(" ")' <<< "$k8s_cluster_all_node_list"); do
    ih=$($yq_cmd ".[\"$knn\"]" <<< "$knn_to_ih_dict")
    [[ -z $ih || $ih = "null" ]] && die "[ERROR] K8s cluster has the node[\"$ih\"] that is not in inventory"
    ih_list=$($yq_cmd -o json ". + [\"$ih\"]" <<< "$ih_list")
  done

  echo "$ih_list"
}

get_k8s_cluster_cp_ih_list() {
  local k8s_cluster_cp_node_list
  k8s_cluster_cp_node_list=$(get_k8s_cluster_cp_node_list)

  local ih_list="[]"
  for knn in $($yq_cmd '. | join(" ")' <<< "$k8s_cluster_cp_node_list"); do
    ih=$($yq_cmd ".[\"$knn\"]" <<< "$knn_to_ih_dict")
    [[ -z $ih || $ih = "null" ]] && die "[ERROR] K8s cluster has the node[\"$ih\"] that is not in inventory"
    ih_list=$($yq_cmd -o json ". + [\"$ih\"]" <<< "$ih_list")
  done

  echo "$ih_list"
}

get_inventory_k8s_node_ih_list() {
  $yq_cmd -o json ".groups.k8s_node" < "$vars_path"
}

get_inventory_k8s_cp_node_ih_list() {
  $yq_cmd -o json ".k8s_cp_nodes" < "$vars_path"
}

get_k8s_cluster_all_node_list() {
  local name_lines
  local name
  name_lines=$(kubectl get nodes -o name)

  local knn_list="[]"
  local knn
  while read -r name; do
    [[ ! $name =~ ^node/ ]] && continue
    knn=${name:5}
    knn_list=$($yq_cmd -o json ". + [\"$knn\"]" <<< "$knn_list")
  done <<< "$name_lines"

  echo "$knn_list"
}

get_k8s_cluster_cp_node_list() {
  local name_lines
  local name
  name_lines=$(kubectl get nodes -o name -l node-role.kubernetes.io/control-plane=)

  local knn_list="[]"
  local knn
  while read -r name; do
    [[ ! $name =~ ^node/ ]] && continue
    knn=${name:5}
    knn_list=$($yq_cmd -o json ". + [\"$knn\"]" <<< "$knn_list")
  done <<< "$name_lines"

  echo "$knn_list"
}

get_knn_to_ih_dict() {
  local knn_to_ih_dict="{}"
  local knn
  local ih
  for hostname in $($yq_cmd '. | keys | join(" ")' <<< "$hostname_to_ih_dict"); do
    knn=$(convert_into_knn "$hostname")
    ih=$($yq_cmd ".[\"$hostname\"]" <<< "$hostname_to_ih_dict")
    knn_to_ih_dict=$($yq_cmd -o json ".[\"$knn\"] = \"$ih\"" <<< "$knn_to_ih_dict")
  done

  echo "$knn_to_ih_dict"
}

convert_into_knn() {
  local hostname=$1

  sed "s/_/-/g" <<< "${hostname,,}"

  return 0
}

docker_service_exists() {
  local svc_name=$1

  local ls_lines_len
  ls_lines_len=$(docker compose ls -a --filter name='^'"$svc_name"'$' | wc -l)
  if [[ $ls_lines_len = 2 ]]; then echo "true"; else echo "false"; fi

  return 0
}

is_ki_cp_node() {
  ih=$1

  $yq_cmd ".groups.ki_cp_node | contains([\"$ih\"])" < "$vars_path"
}

is_k8s_cp_node() {
  ih=$1

  $yq_cmd ".k8s_cp_nodes | contains([\"$ih\"])" < "$vars_path"
}

is_k8s_node() {
  ih=$1

  $yq_cmd ".groups.k8s_node | contains([\"$ih\"])" < "$vars_path"
}

import_ki_opt_vars() {
  ki_opt_root_path=$(grep -oP  "^ki_opt_root_path: \K(.+)" < "$vars_path")
  ki_opt_scripts_path=$(grep -oP  "^ki_opt_scripts_path: \K(.+)" < "$vars_path")
  ki_opt_bundle_path=$(grep -oP  "^ki_opt_bundle_path: \K(.+)" < "$vars_path")
  ki_opt_venv_path=$(grep -oP  "^ki_opt_venv_path: \K(.+)" < "$vars_path")
}

setup_cmd_vars() {
  yq_cmd="$ki_opt_bundle_path/bin/yq"
  jinja2_cmd="$ki_opt_venv_path/bin/jinja2"
  etcdctl_cmd="etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/peer.crt --key=/etc/kubernetes/pki/etcd/peer.key"
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
