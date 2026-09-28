#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] --metrics-path path --services-path path
       --pki-path path --dns-name name --registry-port n --user-registry-port n
       --python path [--vip address]
Available options:
-h, --help             Print this help and exit
-v, --verbose          Print script debug info
--metrics-path         File to write, in the prometheus text format a node
                       exporter textfile collector reads
--services-path        Directory holding one directory per ki cp service
--pki-path             Directory holding the certificate authority of this
                       installation
--dns-name             The ki cp name, which is both what the name server is
                       asked for and what the registries are served as
--registry-port        Port of the registry kubeadm pulls from
--user-registry-port   Port of the registry the workloads pull from
--python               Interpreter the probes run under
--vip                  The virtual address of the ki cp nodes. Left out on a
                       cluster that has none
EOF
  exit
}

parse_params() {
  metrics_path=""
  services_path=""
  pki_path=""
  dns_name=""
  registry_port=""
  user_registry_port=""
  python_path=""
  vip=""

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --metrics-path | --services-path | --pki-path | --dns-name | \
    --registry-port | --user-registry-port | --python | --vip)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      case "${1-}" in
        --metrics-path) metrics_path="${2-}" ;;
        --services-path) services_path="${2-}" ;;
        --pki-path) pki_path="${2-}" ;;
        --dns-name) dns_name="${2-}" ;;
        --registry-port) registry_port="${2-}" ;;
        --user-registry-port) user_registry_port="${2-}" ;;
        --python) python_path="${2-}" ;;
        --vip) vip="${2-}" ;;
      esac
      shift
      ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  local required
  for required in metrics_path services_path pki_path dns_name registry_port user_registry_port python_path; do
    [[ -z "${!required}" ]] && die "[ERROR] Missing required option: --${required//_/-}"
  done

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

# What the metrics of this node are written to before they are put in place, and
# what the collector reads. The move is what makes the file appear whole: a
# textfile collector reads whatever is there when it is scraped, so a file being
# appended to in place is read half written
TMP_SUFFIX=".tmp"
# Long enough for a docker daemon under load, short enough that a daemon that has
# stopped answering does not hold the timer open until the next firing
DOCKER_TIMEOUT_SECONDS=10
# The certificate authority of this installation, which is what the registries
# are served with. Beside the other pki of the node
CA_FILE_NAME="ki-ca.crt"

probe_cmd=()

# Writes what this ki cp node is doing right now, in the format a node exporter
# textfile collector reads.
#
# The services of a ki cp node are docker containers rather than pods, so nothing
# inside the cluster discovers them, and the questions an operator asks first -
# who holds the vip, is the name server answering, are the registries serving -
# have no answer anywhere until someone logs in. The check-* scripts of this
# installer answer them at the end of a playbook run, which is the wrong moment:
# a cluster goes weeks without a playbook and these change on their own.
#
# Every probe writes a number even when it failed. A series that disappears and a
# series that says 0 are different things to whatever reads this, and the one
# that has to be seen is the 0
main() {
  require_directory_exists "$services_path"

  probe_cmd=("$python_path" "$SCRIPT_DIR_PATH"/ki-cp-probe.py)

  mkdir -p "$(dirname "$metrics_path")"

  begin_metrics_file
  write_service_metrics
  write_vip_metric
  write_dns_metric
  write_registry_metrics
  publish_metrics_file

  return 0
}

begin_metrics_file() {
  : > "$metrics_path$TMP_SUFFIX"

  return 0
}

emit() {
  printf '%s\n' "$1" >> "$metrics_path$TMP_SUFFIX"

  return 0
}

# One entry per service directory rather than a list written here, so that a
# service added to a ki cp node is measured without this script being told about
# it.
#
# The restart count is written beside the state because the state alone does not
# say what a crash looping service looks like: restart=always brings the
# container back, so a service failing every few seconds reads as up in almost
# every scrape.
#
# Which is why the containers asked for are every container of the project and
# not the ones that happen to be up. A container that has stopped is not listed
# by "ps -q" at all, so the count of a service that is down comes out 0 - the
# answer for a service that has never failed, given at the one moment the count
# is what is being looked for. Docker reports a container between restarts as
# running, so what this reaches is the one that has come to rest: killed,
# stopped, or restarted for the last time. Whether it is up is read from the
# container either way
write_service_metrics() {
  emit "# HELP ki_cp_service_up Whether the container of this ki cp service is running"
  emit "# TYPE ki_cp_service_up gauge"

  local up_lines=""
  local restart_lines=""

  local service_dir
  for service_dir in "$services_path"/*/; do
    local compose_path="$service_dir"compose.yml
    [[ -f $compose_path ]] || continue

    local service
    service=$(basename "$service_dir")

    local containers=0
    local containers_running=0
    local restarts=0

    local container_ids
    container_ids=$(timeout $DOCKER_TIMEOUT_SECONDS docker compose -f "$compose_path" ps -q --all 2>/dev/null) || container_ids=""

    local container_id
    for container_id in $container_ids; do
      local state
      state=$(timeout $DOCKER_TIMEOUT_SECONDS docker inspect \
                --format '{{.State.Running}} {{.RestartCount}}' "$container_id" 2>/dev/null) || state=""
      [[ -z $state ]] && continue

      containers=$((containers + 1))
      [[ ${state%% *} = "true" ]] && containers_running=$((containers_running + 1))

      # Checked before it is added to anything. A count that is not a number is
      # docker answering something this did not ask for, and arithmetic on it
      # under set -u ends the script: the services after this one go unmeasured
      # and the file nothing replaced goes on being read as current, which is
      # the one outcome every 0 in here exists to avoid
      local count=${state##* }
      [[ $count =~ ^[0-9]+$ ]] && restarts=$((restarts + count))
    done

    # Up when every container of the service is, rather than when any one is.
    # Each ki cp service is one container today, but the services are read off
    # the directory so that a new one is measured without this being told about
    # it, and for a service that is two containers "one of them is running" is
    # not what ki_cp_service_up == 0 is alerted on
    local running=0
    [[ $containers -gt 0 && $containers_running -eq $containers ]] && running=1

    up_lines+="ki_cp_service_up{service=\"$service\"} $running"$'\n'
    restart_lines+="ki_cp_service_restarts_total{service=\"$service\"} $restarts"$'\n'
  done

  [[ -n $up_lines ]] && printf '%s' "$up_lines" >> "$metrics_path$TMP_SUFFIX"

  emit "# HELP ki_cp_service_restarts_total How many times docker has restarted the container of this ki cp service"
  emit "# TYPE ki_cp_service_restarts_total counter"
  [[ -n $restart_lines ]] && printf '%s' "$restart_lines" >> "$metrics_path$TMP_SUFFIX"

  return 0
}

# Per node, which is what makes the answer useful once the nodes are added up:
# nothing holding the address and two nodes holding it are both wrong and neither
# is visible from one node. Read from the interfaces of this node rather than
# from keepalived, because what the cluster is reached at is the address that is
# on a node and not the state of the process that is meant to put it there
#
# Nothing is written when the cluster has no vip. In that mode there is no
# address to hold and a series saying 0 forever would read as one that is missing
write_vip_metric() {
  [[ -z $vip ]] && return 0

  local held=0
  ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$vip" && held=1

  emit "# HELP ki_cp_vip_held Whether the ki cp virtual address is on an interface of this node"
  emit "# TYPE ki_cp_vip_held gauge"
  emit "ki_cp_vip_held{vip=\"$vip\"} $held"

  return 0
}

# A query rather than a connection to the port. bind holds the port open while it
# is refusing to answer for a zone it failed to load, and the name asked for here
# is the one every node in the cluster resolves to reach the registries
write_dns_metric() {
  local answers
  answers=$("${probe_cmd[@]}" dns --server 127.0.0.1 --name "$dns_name" 2>/dev/null) || answers=""
  # Anything but a 0 or a 1 is not written. A textfile collector that cannot
  # parse a line drops the whole file, so one probe printing something
  # unexpected would take every metric here with it
  [[ $answers =~ ^[01]$ ]] || answers=0

  emit "# HELP ki_cp_dns_answers Whether the name server of this node answers for the ki cp name"
  emit "# TYPE ki_cp_dns_answers gauge"
  emit "ki_cp_dns_answers{name=\"$dns_name\"} $answers"

  return 0
}

# Asked over the loopback, so that what is measured is the registry of this node
# rather than whichever one the vip points at. The repository count is here for
# the comparison between nodes: they are filled one by one and a node that was
# missed serves a catalog that is short, which nothing notices until a pod is
# scheduled onto it
write_registry_metrics() {
  emit "# HELP ki_cp_registry_up Whether the registry of this node answers over the loopback"
  emit "# TYPE ki_cp_registry_up gauge"

  local up_lines=""
  local count_lines=""

  local entry
  for entry in "k8s:$registry_port" "user:$user_registry_port"; do
    local registry=${entry%%:*}
    local port=${entry##*:}

    # One call for both numbers. They are two questions about the same registry
    # and the probe answers them on one connection, so asking twice would be a
    # second interpreter and a second handshake for an answer it already had
    local answer
    answer=$("${probe_cmd[@]}" registry --address 127.0.0.1 --port "$port" \
               --server-name "$dns_name" --ca-path "$pki_path/$CA_FILE_NAME" 2>/dev/null) || answer=""

    local up=${answer%% *}
    local repositories=${answer##* }
    [[ $up =~ ^[01]$ ]] || up=0
    [[ $repositories =~ ^[0-9]+$ ]] || repositories=0

    up_lines+="ki_cp_registry_up{registry=\"$registry\"} $up"$'\n'
    count_lines+="ki_cp_registry_repositories{registry=\"$registry\"} $repositories"$'\n'
  done

  printf '%s' "$up_lines" >> "$metrics_path$TMP_SUFFIX"

  emit "# HELP ki_cp_registry_repositories How many repositories the registry of this node serves"
  emit "# TYPE ki_cp_registry_repositories gauge"
  printf '%s' "$count_lines" >> "$metrics_path$TMP_SUFFIX"

  return 0
}

# The write time, so that a file nothing is refreshing any more can be told from
# a node where nothing is happening. The certificate expiry file needs no such
# thing because an expiry that was written once stays true, and none of the
# values above do
publish_metrics_file() {
  emit "# HELP ki_cp_metrics_written_seconds Unix time at which this file was last written"
  emit "# TYPE ki_cp_metrics_written_seconds gauge"
  emit "ki_cp_metrics_written_seconds $(date +%s)"

  chmod 0644 "$metrics_path$TMP_SUFFIX"
  mv -f "$metrics_path$TMP_SUFFIX" "$metrics_path"

  return 0
}

require_directory_exists() {
  local path=$1

  [[ ! -e $path ]] && die "[ERROR] No such file or directory of which path is \"$path\""
  [[ ! -d $path ]] && die "[ERROR] Directory[\"$path\"] is not a directory"

  return 0
}

main
