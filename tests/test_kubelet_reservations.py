"""create-kubelet-reservations.py decides how much of a node kubernetes may not have.

What it gets wrong does not fail anything: the node comes up, the scheduler is
given a number that is too large or too small, and the node is either wasted or
over committed until something falls over on it. So what is asserted here is the
behaviour the module documents rather than the arithmetic, which would only be
the same sum written twice.
"""
import subprocess
import sys

import yaml

from conftest import PREFLIGHT

KIB = 1024
MIB = KIB * 1024
GIB = MIB * 1024


def reservations(hostvars, ih):
    result = subprocess.run(
        [sys.executable, str(PREFLIGHT / "create-kubelet-reservations.py"), ih],
        input=yaml.safe_dump(hostvars), capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stdout + result.stderr
    return yaml.safe_load(result.stdout)["kubelet_reservations"]


def bytes_of(quantity):
    units = {"Ki": KIB, "Mi": MIB, "Gi": GIB}
    for suffix, factor in units.items():
        if quantity.endswith(suffix):
            return int(quantity[: -len(suffix)]) * factor
    return int(quantity)


def millicores_of(quantity):
    return int(quantity[:-1]) if quantity.endswith("m") else int(float(quantity) * 1000)


def set_capacity(node, *, cpu_millicores=None, memory_kib=None):
    if cpu_millicores is not None:
        node["node_resources"]["cpu_millicores"] = cpu_millicores
    if memory_kib is not None:
        node["node_resources"]["memory_kib"] = memory_kib


def test_a_ki_cp_node_is_reserved_the_extra_its_services_need(hostvars):
    """node1 runs keepalived, the dns server, the registries and the load
    balancer with docker, which kubelet does not account for."""
    ki_cp = reservations(hostvars, "node1")
    plain = reservations(hostvars, "node2")

    extra_cpu = millicores_of(hostvars["node1"]["kubelet_ki_cp_extra_cpu"])
    extra_memory = bytes_of(hostvars["node1"]["kubelet_ki_cp_extra_memory"])

    assert (millicores_of(ki_cp["system_reserved"]["cpu"])
            - millicores_of(plain["system_reserved"]["cpu"])) == extra_cpu
    assert (bytes_of(ki_cp["system_reserved"]["memory"])
            - bytes_of(plain["system_reserved"]["memory"])) == extra_memory


def test_the_extra_lands_on_one_side_only(hostvars):
    """The split between the two is cosmetic, so what a node that is not a ki cp
    node reserves under kubeReserved is the same on one that is."""
    assert (reservations(hostvars, "node1")["kube_reserved"]
            == reservations(hostvars, "node2")["kube_reserved"])


def test_a_small_node_is_not_left_reserving_almost_nothing(hostvars):
    """Below the floor the tiers would leave a node with a reservation that does
    not cover the kernel it is running."""
    set_capacity(hostvars["node2"], cpu_millicores=1000, memory_kib=512 * KIB)

    reserved = reservations(hostvars, "node2")
    total = (bytes_of(reserved["system_reserved"]["memory"])
             + bytes_of(reserved["kube_reserved"]["memory"]))

    # The tiers alone would give a node this size 128Mi. The floor is what takes
    # it to 255Mi, less the megabyte the halves lose to being rounded down to Mi
    assert total >= 250 * MIB


def test_a_larger_node_is_never_reserved_less_than_a_smaller_one(hostvars):
    set_capacity(hostvars["node2"], memory_kib=8 * KIB * KIB)
    smaller = reservations(hostvars, "node2")
    set_capacity(hostvars["node2"], memory_kib=128 * KIB * KIB)
    larger = reservations(hostvars, "node2")

    def total(reserved):
        return (bytes_of(reserved["system_reserved"]["memory"])
                + bytes_of(reserved["kube_reserved"]["memory"]))

    assert total(larger) > total(smaller)


def test_what_the_inventory_says_wins_over_what_was_calculated(hostvars):
    """The first of the three levels of precedence the module documents."""
    hostvars["node2"]["kubelet_system_reserved_memory"] = "3Gi"
    hostvars["node2"]["kubelet_system_reserved_cpu"] = "750m"

    reserved = reservations(hostvars, "node2")

    assert reserved["system_reserved"]["memory"] == "3Gi"
    assert reserved["system_reserved"]["cpu"] == "750m"


def test_an_eviction_threshold_is_not_larger_than_the_disk_it_is_on(hostvars):
    """The lower bounds are sized for an ordinary node, and on a small one they
    would put the node in permanent disk pressure."""
    hostvars["node2"]["node_resources"]["nodefs_bytes"] = 20 * GIB
    hostvars["node2"]["node_resources"]["imagefs_bytes"] = 20 * GIB

    reserved = reservations(hostvars, "node2")

    assert bytes_of(reserved["eviction_hard"]["nodefs.available"]) < 20 * GIB
    assert bytes_of(reserved["eviction_hard"]["imagefs.available"]) < 20 * GIB
