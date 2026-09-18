#!/usr/bin/env python3
"""Calculates kubelet resource reservations from the actual resources of a node.

Reservations are not a fixed amount. Kernel slab, page tables and network
buffers grow with the number of pods, containers and sockets on a node, which in
turn grows with the size of the node. A fixed value over reserves on small nodes
and under reserves on large ones, so the amount is calculated from the capacity
of the node with the tiered rates below.

Memory, cumulative over the tiers
    first 4Gi      25%
    4Gi ~ 8Gi      20%
    8Gi ~ 16Gi     10%
    16Gi ~ 128Gi    6%
    above 128Gi     2%

Cpu, cumulative over the tiers
    first core       6%
    2nd core         1%
    3rd ~ 4th core 0.5%
    above 4 cores 0.25%

The calculated total is split evenly between systemReserved and kubeReserved.
The split is cosmetic. enforceNodeAllocatable is left at its default value
["pods"], so neither value is enforced by a cgroup. Only their sum matters,
since that is what is subtracted from Capacity to get Allocatable.

Precedence of values, highest first
    1. Explicit kubelet_* variable set in inventory.yml or vars.yml
    2. Extra amount added when the node belongs to the ki_cp_node group
    3. The value calculated from the resources of the node
"""
from __future__ import annotations

import argparse
import re
import sys

import yaml

KIB = 1024
MIB = KIB * 1024
GIB = MIB * 1024

MEMORY_TIERS = [(4 * GIB, 0.25), (4 * GIB, 0.20), (8 * GIB, 0.10), (112 * GIB, 0.06)]
MEMORY_REMAINDER_RATE = 0.02
MEMORY_RESERVE_FLOOR = 255 * MIB

CPU_TIERS = [(1000, 0.06), (1000, 0.01), (2000, 0.005)]
CPU_REMAINDER_RATE = 0.0025

EPHEMERAL_STORAGE_RESERVE_RATE = 0.05
NODEFS_EVICTION_RATE = 0.10
IMAGEFS_EVICTION_RATE = 0.10
MEMORY_EVICTION_RATE = 0.01

# The configured lower bounds are sized for an ordinary node. On a node much
# smaller than that they would take an absurd share of the capacity, for example
# a 15Gi nodefs lower bound on a 20Gi filesystem leaves the node in permanent
# disk pressure. These ceilings are applied after the bounds and win over them
EPHEMERAL_STORAGE_RESERVE_CEILING_RATE = 0.10
NODEFS_EVICTION_CEILING_RATE = 0.25
MEMORY_EVICTION_CEILING_RATE = 0.10

DEFAULT_SYSTEM_RESERVED_PID = 2000
DEFAULT_KUBE_RESERVED_PID = 1000

QUANTITY_PATTERN = re.compile(r"^(?P<value>[0-9]+(?:\.[0-9]+)?)(?P<suffix>Ei|Pi|Ti|Gi|Mi|Ki)?$")
CPU_MILLICORES_PATTERN = re.compile(r"^[0-9]+$")
CPU_CORES_PATTERN = re.compile(r"^[0-9]+(\.[0-9]+)?$")

BINARY_SUFFIXES = {
    "Ki": KIB,
    "Mi": MIB,
    "Gi": GIB,
    "Ti": GIB * 1024,
    "Pi": GIB * 1024 ** 2,
    "Ei": GIB * 1024 ** 3,
}

NODE_RESOURCES_KEYS = ["cpu_millicores", "memory_kib", "nodefs_bytes", "imagefs_bytes", "pid_max"]


def die(msg):
    print(msg, file=sys.stderr)
    exit(1)


def parse_bytes(value, var_name):
    """Parses a Kubernetes binary quantity such as 500Mi or 2Gi into bytes."""
    matched = QUANTITY_PATTERN.match(str(value))
    if matched is None:
        die("[ERROR] Value[\"" + str(value) + "\"] for variable[\"" + var_name
            + "\"] is not a valid quantity")

    number = float(matched.group("value"))
    suffix = matched.group("suffix")
    if suffix is None:
        return int(number)

    return int(number * BINARY_SUFFIXES[suffix])


def parse_millicores(value, var_name):
    """Parses a Kubernetes cpu quantity such as 500m or 2 into millicores."""
    text = str(value)
    if text.endswith("m"):
        if CPU_MILLICORES_PATTERN.match(text[:-1]) is None:
            die("[ERROR] Value[\"" + text + "\"] for variable[\"" + var_name
                + "\"] is not a valid cpu quantity")
        return int(text[:-1])

    if CPU_CORES_PATTERN.match(text) is None:
        die("[ERROR] Value[\"" + text + "\"] for variable[\"" + var_name
            + "\"] is not a valid cpu quantity")

    return int(float(text) * 1000)


def format_mib(value_bytes):
    """Formats bytes as a whole number of Mi.

    Kubelet accepts any Mi value, and keeping a single unit avoids rounding
    surprises when the rendered values are compared between nodes.
    """
    return str(max(1, value_bytes // MIB)) + "Mi"


def format_millicores(value_millicores):
    return str(max(1, value_millicores)) + "m"


def clamp(value, minimum, maximum):
    return max(minimum, min(value, maximum))


def clamp_with_ceiling(value, minimum, maximum, total, ceiling_rate):
    """Clamps to the configured bounds, then caps at a share of the total.

    The ceiling wins over the lower bound on purpose, so that a bound sized for
    an ordinary node cannot consume a small node.
    """
    return min(clamp(value, minimum, maximum), int(total * ceiling_rate))


def calculate_tiered(total, tiers, remainder_rate):
    remaining = total
    reserved = 0.0
    for size, rate in tiers:
        if remaining <= 0:
            return int(reserved)
        chunk = min(remaining, size)
        reserved += chunk * rate
        remaining -= chunk

    reserved += remaining * remainder_rate

    return int(reserved)


def get_node_resources(host_vars, ih):
    if "node_resources" not in host_vars:
        die("[ERROR] Variable[\"hostvars[\"" + ih
            + "\"]\"] invalid. it must has key [\"node_resources\"]")

    node_resources = host_vars["node_resources"]
    for key in NODE_RESOURCES_KEYS:
        if key not in node_resources:
            die("[ERROR] Variable[\"hostvars[\"" + ih
                + "\"][\"node_resources\"]\"] invalid. it must has key [\"" + key + "\"]")

    return node_resources


def require_var(host_vars, ih, var_name):
    if var_name not in host_vars or host_vars[var_name] is None:
        die("[ERROR] Variable[\"" + var_name + "\"] of node[\"" + ih + "\"] must be set")

    return host_vars[var_name]


def get_override(host_vars, var_name):
    """Returns the explicitly configured value, or None when it is not set."""
    if var_name not in host_vars:
        return None

    return host_vars[var_name]


def is_ki_cp_node(host_vars, ih):
    if "groups" not in host_vars or "ki_cp_node" not in host_vars["groups"]:
        die("[ERROR] Variable[\"hostvars[\"" + ih
            + "\"][\"groups\"]\"] invalid. it must has key [\"ki_cp_node\"]")

    return ih in host_vars["groups"]["ki_cp_node"]


def build_reservations(host_vars, ih):
    node_resources = get_node_resources(host_vars, ih)

    cpu_millicores = int(node_resources["cpu_millicores"])
    memory_bytes = int(node_resources["memory_kib"]) * KIB
    nodefs_bytes = int(node_resources["nodefs_bytes"])
    imagefs_bytes = int(node_resources["imagefs_bytes"])
    pid_max = int(node_resources["pid_max"])

    total_memory_reserve = max(
        calculate_tiered(memory_bytes, MEMORY_TIERS, MEMORY_REMAINDER_RATE),
        MEMORY_RESERVE_FLOOR)
    total_cpu_reserve = calculate_tiered(cpu_millicores, CPU_TIERS, CPU_REMAINDER_RATE)

    system_memory = total_memory_reserve // 2
    kube_memory = total_memory_reserve - system_memory
    system_cpu = total_cpu_reserve // 2
    kube_cpu = total_cpu_reserve - system_cpu

    if is_ki_cp_node(host_vars, ih):
        system_cpu += parse_millicores(
            require_var(host_vars, ih, "kubelet_ki_cp_extra_cpu"), "kubelet_ki_cp_extra_cpu")
        system_memory += parse_bytes(
            require_var(host_vars, ih, "kubelet_ki_cp_extra_memory"), "kubelet_ki_cp_extra_memory")

    ephemeral_storage_min = parse_bytes(
        require_var(host_vars, ih, "kubelet_auto_ephemeral_storage_min"),
        "kubelet_auto_ephemeral_storage_min")
    ephemeral_storage_max = parse_bytes(
        require_var(host_vars, ih, "kubelet_auto_ephemeral_storage_max"),
        "kubelet_auto_ephemeral_storage_max")
    memory_available_min = parse_bytes(
        require_var(host_vars, ih, "kubelet_auto_memory_available_min"),
        "kubelet_auto_memory_available_min")
    memory_available_max = parse_bytes(
        require_var(host_vars, ih, "kubelet_auto_memory_available_max"),
        "kubelet_auto_memory_available_max")
    nodefs_available_min = parse_bytes(
        require_var(host_vars, ih, "kubelet_auto_nodefs_available_min"),
        "kubelet_auto_nodefs_available_min")
    nodefs_available_max = parse_bytes(
        require_var(host_vars, ih, "kubelet_auto_nodefs_available_max"),
        "kubelet_auto_nodefs_available_max")

    ephemeral_storage_reserve = clamp_with_ceiling(
        int(nodefs_bytes * EPHEMERAL_STORAGE_RESERVE_RATE),
        ephemeral_storage_min,
        ephemeral_storage_max,
        nodefs_bytes,
        EPHEMERAL_STORAGE_RESERVE_CEILING_RATE)
    system_ephemeral_storage = ephemeral_storage_reserve // 2
    kube_ephemeral_storage = ephemeral_storage_reserve - system_ephemeral_storage

    memory_available = clamp_with_ceiling(
        int(memory_bytes * MEMORY_EVICTION_RATE),
        memory_available_min, memory_available_max,
        memory_bytes, MEMORY_EVICTION_CEILING_RATE)
    nodefs_available = clamp_with_ceiling(
        int(nodefs_bytes * NODEFS_EVICTION_RATE),
        nodefs_available_min, nodefs_available_max,
        nodefs_bytes, NODEFS_EVICTION_CEILING_RATE)
    # imagefs reuses the nodefs bounds. The two are the same filesystem unless
    # the container runtime root is on a separate mount
    imagefs_available = clamp_with_ceiling(
        int(imagefs_bytes * IMAGEFS_EVICTION_RATE),
        nodefs_available_min, nodefs_available_max,
        imagefs_bytes, NODEFS_EVICTION_CEILING_RATE)

    system_reserved = {
        "cpu": format_millicores(system_cpu),
        "memory": format_mib(system_memory),
        "ephemeral-storage": format_mib(system_ephemeral_storage),
        "pid": min(DEFAULT_SYSTEM_RESERVED_PID, pid_max // 10),
    }
    kube_reserved = {
        "cpu": format_millicores(kube_cpu),
        "memory": format_mib(kube_memory),
        "ephemeral-storage": format_mib(kube_ephemeral_storage),
        "pid": min(DEFAULT_KUBE_RESERVED_PID, pid_max // 20),
    }
    eviction_hard = {
        "memory.available": format_mib(memory_available),
        "nodefs.available": format_mib(nodefs_available),
        "imagefs.available": format_mib(imagefs_available),
        "nodefs.inodesFree": require_var(
            host_vars, ih, "kubelet_eviction_hard_nodefs_inodes_free"),
    }

    apply_overrides(host_vars, system_reserved, kube_reserved, eviction_hard)

    return {
        "system_reserved": system_reserved,
        "kube_reserved": kube_reserved,
        "eviction_hard": eviction_hard,
    }


def apply_overrides(host_vars, system_reserved, kube_reserved, eviction_hard):
    """Explicitly configured values take precedence over the calculated ones."""
    overrides = [
        (system_reserved, "cpu", "kubelet_system_reserved_cpu"),
        (system_reserved, "memory", "kubelet_system_reserved_memory"),
        (system_reserved, "ephemeral-storage", "kubelet_system_reserved_ephemeral_storage"),
        (system_reserved, "pid", "kubelet_system_reserved_pid"),
        (kube_reserved, "cpu", "kubelet_kube_reserved_cpu"),
        (kube_reserved, "memory", "kubelet_kube_reserved_memory"),
        (kube_reserved, "ephemeral-storage", "kubelet_kube_reserved_ephemeral_storage"),
        (kube_reserved, "pid", "kubelet_kube_reserved_pid"),
        (eviction_hard, "memory.available", "kubelet_eviction_hard_memory_available"),
        (eviction_hard, "nodefs.available", "kubelet_eviction_hard_nodefs_available"),
        (eviction_hard, "imagefs.available", "kubelet_eviction_hard_imagefs_available"),
    ]

    for target, key, var_name in overrides:
        value = get_override(host_vars, var_name)
        if value is not None:
            target[key] = value

    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("inventory_hostname")
    parsed_args = parser.parse_args()
    ih = parsed_args.inventory_hostname

    hostvars = yaml.safe_load(sys.stdin)

    if ih not in hostvars:
        die("[ERROR] Variable[\"hostvars\"] has no key [\"" + ih + "\"]")

    result = {"kubelet_reservations": build_reservations(hostvars[ih], ih)}
    yaml.dump(result, sys.stdout, default_flow_style=False)


main()
