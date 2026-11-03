"""diff-applied-vars.py decides what update-cluster.yml does about a change.

The table in constant-vars.yml says what class a variable is, and the class says
how it is applied. What is asserted here is the one place the answer depends on
the node as well as the variable: the memory a node keeps for itself is a kubelet
restart everywhere except on a node running the static memory manager, whose
checkpoint records that memory and refuses a kubelet that reads a different
figure.
"""
import subprocess
import sys

import yaml

from conftest import PREFLIGHT


def diff(hostvars):
    result = subprocess.run(
        [sys.executable, str(PREFLIGHT / "diff-applied-vars.py")],
        input=yaml.safe_dump(hostvars), capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stdout + result.stderr
    return yaml.safe_load(result.stdout)


def record_as_applied(hostvars):
    """Every node recorded with exactly what it holds now, so that the next
    thing a test changes is the only change."""
    classified = {name for names in hostvars["localhost"]["ki_var_classes"].values() for name in names}
    for ih, node in hostvars.items():
        if ih == "localhost":
            continue
        node["ki_applied_vars"] = {name: node[name] for name in classified if name in node}


def changed(result, cls):
    return [(change["ih"], change["name"]) for change in result["changes"][cls]]


def test_a_cluster_recorded_as_it_is_has_nothing_to_apply(hostvars):
    record_as_applied(hostvars)

    result = diff(hostvars)

    assert all(not changes for changes in result["changes"].values())


def test_a_memory_reservation_is_a_kubelet_restart_on_a_node_running_no_memory_policy(hostvars):
    record_as_applied(hostvars)
    hostvars["node2"]["kubelet_system_reserved_memory"] = "3Gi"

    result = diff(hostvars)

    assert changed(result, "kubelet") == [("node2", "kubelet_system_reserved_memory")]
    assert changed(result, "kubelet_policy") == []


def test_a_memory_reservation_is_a_policy_change_on_a_node_running_the_static_memory_manager(hostvars):
    """The memory manager checkpoints the memory reserved per numa node and
    refuses a kubelet whose configuration says otherwise, so the change has to go
    the way a policy does: drained, the checkpoint taken away, started."""
    hostvars["node2"]["kubelet_memory_manager_policy"] = "static"
    record_as_applied(hostvars)
    hostvars["node2"]["kubelet_system_reserved_memory"] = "3Gi"

    result = diff(hostvars)

    assert changed(result, "kubelet_policy") == [("node2", "kubelet_system_reserved_memory")]
    assert changed(result, "kubelet") == []


def test_a_node_leaving_the_memory_policy_still_takes_its_reservation_through_the_drain(hostvars):
    """The checkpoint that disagrees is the one written under static, so what
    the node ran before decides as much as what it runs now."""
    hostvars["node2"]["kubelet_memory_manager_policy"] = "static"
    record_as_applied(hostvars)
    hostvars["node2"]["kubelet_memory_manager_policy"] = "none"
    hostvars["node2"]["kubelet_system_reserved_memory"] = "3Gi"

    result = diff(hostvars)

    assert set(changed(result, "kubelet_policy")) == {
        ("node2", "kubelet_memory_manager_policy"),
        ("node2", "kubelet_system_reserved_memory"),
    }
    assert changed(result, "kubelet") == []


def test_only_the_node_running_the_policy_is_drained_for_a_cluster_wide_change(hostvars):
    """vars.yml changes the value on every node, and only the node whose
    checkpoint records it pays with an eviction."""
    hostvars["node2"]["kubelet_memory_manager_policy"] = "static"
    record_as_applied(hostvars)
    for ih in ("node1", "node2"):
        hostvars[ih]["kubelet_kube_reserved_memory"] = "2Gi"

    result = diff(hostvars)

    assert changed(result, "kubelet") == [("node1", "kubelet_kube_reserved_memory")]
    assert changed(result, "kubelet_policy") == [("node2", "kubelet_kube_reserved_memory")]
