#!/usr/bin/env python3
"""Names the containers kubelet would refuse to admit again if it were restarted now.

A restarted kubelet admits every pod already running on the node once more, and
the cpu manager is asked to allocate for each of them. Before kubernetes 1.37 the
static policy with the full-pcpus-only option does one thing in the wrong order
there: it checks that the cpus a container asks for are free before it looks
whether that container already holds them. The checkpoint it restored has already
taken those cpus out of the free ones, so a container that holds more cpus than
are left free is refused with SMTAlignmentError and killed, while it was running
on exactly the cpus it asked for. kubernetes/kubernetes#129078, fixed by #129079
in 1.37 and not backported.

So the answer is worked out the way kubelet works it out, from what kubelet will
read: the policy and the reserved cpus of its configuration, the free cpus and the
assignments of its checkpoint, the cores of the machine, and the version of the
binary that a restart would start. Free is the default cpu set less every core
that holds a reserved cpu, which is what kubelet counts as available physical
cpus. A container is named when it holds more than that.

Without reservedSystemCPUs kubelet picks the reserved cpus itself, as many as the
cpu of systemReserved and kubeReserved add up to, and this can not see which. It
counts them as if each sat on a core of its own, which is the most cores they can
take, so that what is named is never less than what kubelet would refuse.

Prints one line per container and nothing when a restart refuses nothing.
"""
from __future__ import annotations

import argparse
import json
import math
import pathlib
import re
import sys

import yaml

# The first release whose static policy looks at the checkpoint first
FIXED_IN = (1, 37)


def main() -> int:
    args = parse_args()

    config = read_yaml(args.kubelet_config_path)
    if config.get("cpuManagerPolicy", "none") != "static":
        return 0
    options = config.get("cpuManagerPolicyOptions") or {}
    if str(options.get("full-pcpus-only", "false")).lower() != "true":
        return 0
    if version_of(args.kubelet_version) >= FIXED_IN:
        return 0

    state_path = pathlib.Path(args.cpu_manager_state_path)
    # Nothing has been handed out yet, or the checkpoint goes away before kubelet
    # comes back, which is a restart this has nothing to say about
    if not state_path.is_file():
        return 0
    state = json.loads(state_path.read_text())
    # A checkpoint of another policy is refused by kubelet as a whole, before any
    # pod is admitted. That is the policy changing, which is not a restart
    if state.get("policyName") != "static":
        return 0

    cpu_path = pathlib.Path(args.cpu_sysfs_path)
    default = parse_cpuset(state.get("defaultCpuSet", ""))
    reserved = config.get("reservedSystemCPUs")
    if reserved:
        reserved_physical = cores_of(parse_cpuset(str(reserved)), cpu_path)
        free = len(default - reserved_physical)
    else:
        most = math.ceil(reserved_cpu_of(config)) * len(siblings_of(min(default, default=0), cpu_path))
        free = max(len(default) - most, 0)

    names = pod_names(args.pods_json_path)
    for pod_uid, containers in sorted((state.get("entries") or {}).items()):
        for container, cpus in sorted(containers.items()):
            held = len(parse_cpuset(cpus))
            if held <= free:
                continue
            print(f"Node[\"{args.node}\"] pod[\"{names.get(pod_uid, pod_uid)}\"] container[\"{container}\"]"
                  f" holds {held} exclusive cpus, and a restarted kubelet would find {free} free and refuse it"
                  f" with SMTAlignmentError")

    return 0


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--node", required=True, help="Name to report this node under")
    parser.add_argument("--kubelet-version", required=True,
                        help="What the kubelet binary a restart would start says of its version")
    parser.add_argument("--kubelet-config-path", default="/var/lib/kubelet/config.yaml")
    parser.add_argument("--cpu-manager-state-path", default="/var/lib/kubelet/cpu_manager_state")
    parser.add_argument("--cpu-sysfs-path", default="/sys/devices/system/cpu")
    parser.add_argument("--pods-json-path", default=None,
                        help="What crictl pods -o json printed, to name a pod by more than its uid")

    return parser.parse_args()


def read_yaml(path: str) -> dict:
    file_path = pathlib.Path(path)
    if not file_path.is_file():
        return {}

    return yaml.safe_load(file_path.read_text()) or {}


# Unreadable reads as affected: a version this can not place is not one it can
# say has the fix
def version_of(text: str) -> tuple:
    match = re.search(r"v?(\d+)\.(\d+)", text)
    if match is None:
        return (0, 0)

    return (int(match.group(1)), int(match.group(2)))


def parse_cpuset(text: str) -> set:
    cpus = set()
    for part in text.strip().split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            first, last = part.split("-", 1)
            cpus.update(range(int(first), int(last) + 1))
        else:
            cpus.add(int(part))

    return cpus


def siblings_of(cpu: int, cpu_path: pathlib.Path) -> set:
    path = cpu_path / f"cpu{cpu}" / "topology" / "thread_siblings_list"
    if not path.is_file():
        return {cpu}

    return parse_cpuset(path.read_text())


def cores_of(cpus: set, cpu_path: pathlib.Path) -> set:
    cores = set()
    for cpu in cpus:
        cores |= siblings_of(cpu, cpu_path)

    return cores


def reserved_cpu_of(config: dict) -> float:
    total = 0.0
    for key in ("systemReserved", "kubeReserved"):
        quantity = (config.get(key) or {}).get("cpu")
        if quantity is not None:
            total += parse_cpu_quantity(str(quantity))

    return total


def parse_cpu_quantity(text: str) -> float:
    text = text.strip()
    if text.endswith("m"):
        return int(text[:-1]) / 1000

    return float(text)


# Pod names are a courtesy for the operator who reads the report. Without them
# the uid is still exactly the pod, so a missing or unreadable file costs nothing
def pod_names(path) -> dict:
    if path is None:
        return {}
    try:
        items = json.loads(pathlib.Path(path).read_text()).get("items") or []
    except (OSError, ValueError):
        return {}

    names = {}
    for item in items:
        metadata = item.get("metadata") or {}
        uid = metadata.get("uid")
        if uid:
            names[uid] = f"{metadata.get('namespace', '')}/{metadata.get('name', '')}"

    return names


if __name__ == "__main__":
    sys.exit(main())
