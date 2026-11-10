"""create-target-nodes.py decides which nodes an add-node run that named no
node adds, so what matters is who is in the list, who is not, and that it
refuses to guess when no control plane node could say what the cluster holds.

Run as a process on the rendered hostvars, like the validator, since that is
the contract derive-target-nodes.yml depends on.
"""
import subprocess
import sys

import yaml

from conftest import PREFLIGHT


def run(hostvars):
    return subprocess.run(
        [sys.executable, str(PREFLIGHT / "create-target-nodes.py")],
        input=yaml.safe_dump(hostvars),
        capture_output=True,
        text=True,
        check=False,
    )


def target_nodes(hostvars):
    result = run(hostvars)
    assert result.returncode == 0, result.stdout + result.stderr
    return yaml.safe_load(result.stdout)["target_nodes"]


def declare(hostvars, ih, hostname, k8s=True, ki_cp=False, k8s_cp=False):
    """A node the inventory names that has reported what derive-target-nodes.yml
    asks every node: its hostname, and whether it carries a release record."""
    groups = hostvars["localhost"]["groups"]
    groups["all"].append(ih)
    if k8s:
        groups["k8s_node"].append(ih)
    if ki_cp:
        groups["ki_cp_node"].append(ih)
    hostvars[ih] = {"hostname": hostname, "k8s_cp": k8s_cp, "ki_holds_applied_release": False}


def with_cluster(hostvars, names):
    """What the apiserver of the cluster lists, reported by the first control
    plane node that could run kubectl. The two nodes of the fixture are both
    control plane nodes and both in the cluster."""
    for ih in ("node1", "node2"):
        hostvars[ih]["hostname"] = ih
        hostvars[ih]["ki_holds_applied_release"] = True
    hostvars["node1"]["ki_cluster_node_names"] = names
    return hostvars


def test_a_k8s_node_the_cluster_does_not_list_is_a_target(hostvars):
    with_cluster(hostvars, ["node1", "node2"])
    declare(hostvars, "node3", "node3")

    assert target_nodes(hostvars) == ["node3"]


def test_the_nodes_the_cluster_lists_are_not_targets(hostvars):
    with_cluster(hostvars, ["node1", "node2"])

    assert target_nodes(hostvars) == []


def test_targets_come_in_inventory_order_and_a_cp_node_is_one_of_them(hostvars):
    with_cluster(hostvars, ["node1", "node2"])
    declare(hostvars, "node3", "node3", k8s_cp=True)
    declare(hostvars, "node4", "node4")

    assert target_nodes(hostvars) == ["node3", "node4"]


def test_the_cluster_names_nodes_by_hostname_not_by_inventory_name(hostvars):
    """kubectl lists hostnames. A node whose inventory name differs from its
    hostname is in the cluster when its hostname is, and only then."""
    with_cluster(hostvars, ["node1", "node2", "worker-a"])
    declare(hostvars, "node3", "worker-a")
    declare(hostvars, "node4", "worker-b")

    assert target_nodes(hostvars) == ["node4"]


def test_a_node_that_is_only_a_ki_cp_node_is_a_target_until_it_holds_a_release_record(hostvars):
    with_cluster(hostvars, ["node1", "node2"])
    declare(hostvars, "lb1", "lb1", k8s=False, ki_cp=True)
    declare(hostvars, "lb2", "lb2", k8s=False, ki_cp=True)
    hostvars["lb2"]["ki_holds_applied_release"] = True

    assert target_nodes(hostvars) == ["lb1"]


def test_a_broken_node_is_never_a_target(hostvars):
    with_cluster(hostvars, ["node1", "node2"])
    declare(hostvars, "node3", "node3")
    hostvars["localhost"]["groups"]["broken_node"] = ["node3"]
    hostvars["node3"] = {"k8s_cp": False}

    assert target_nodes(hostvars) == []


def test_the_second_cp_node_answers_when_the_first_could_not(hostvars):
    """A control plane node that is itself being added has no kubectl to ask.
    The list comes from whichever declared cp node answered."""
    with_cluster(hostvars, ["node1", "node2"])
    del hostvars["node1"]["ki_cluster_node_names"]
    hostvars["node2"]["ki_cluster_node_names"] = ["node1", "node2"]
    declare(hostvars, "node3", "node3")

    assert target_nodes(hostvars) == ["node3"]


def test_refuses_when_no_cp_node_could_list_the_cluster(hostvars):
    for ih in ("node1", "node2"):
        hostvars[ih]["hostname"] = ih
        hostvars[ih]["ki_holds_applied_release"] = True

    result = run(hostvars)

    assert result.returncode == 1
    assert "No control plane node" in result.stderr
