"""What create-k8s-cp-nodes.py is for is the list of control plane nodes the
plays delegate to and the node scripts put behind the apiserver load balancer,
so what matters is who is in it and who is not.

Run as a process on the rendered hostvars, like the validator, since that is
the contract gather-facts.yml depends on.
"""
import subprocess
import sys

import yaml

from conftest import PREFLIGHT


def run(hostvars):
    result = subprocess.run(
        [sys.executable, str(PREFLIGHT / "create-k8s-cp-nodes.py")],
        input=yaml.safe_dump(hostvars),
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return yaml.safe_load(result.stdout)


def test_every_control_plane_node_is_listed_in_inventory_order(hostvars):
    lists = run(hostvars)

    assert lists["k8s_cp_nodes"] == ["node1", "node2"]
    assert lists["k8s_cp_nodes_in_inventory"] == ["node1", "node2"]


def test_a_worker_is_in_neither_list(hostvars):
    hostvars["node2"]["k8s_cp"] = False

    lists = run(hostvars)

    assert lists["k8s_cp_nodes"] == ["node1"]
    assert lists["k8s_cp_nodes_in_inventory"] == ["node1"]


def test_a_broken_node_is_declared_but_not_acted_on(hostvars):
    """k8s_cp_nodes is where every play finds a control plane node to delegate
    to and where the load balancer finds its backends, and a node that can no
    longer be reached is in neither place. It stays declared, in its groups and
    in k8s_cp_nodes_in_inventory, so that the cluster still holding it is not
    read as holding a stranger, and its removal knows it was a control plane
    node whose etcd member has to go."""
    hostvars["localhost"]["groups"]["broken_node"] = ["node1"]
    hostvars["localhost"]["ki_broken_nodes"] = ["node1"]
    # A broken node is left out of every play, so it reported no facts, but its
    # inventory variables are still what hostvars holds for it
    hostvars["node1"] = {"k8s_cp": True}

    lists = run(hostvars)

    assert lists["k8s_cp_nodes"] == ["node2"]
    assert lists["k8s_cp_nodes_in_inventory"] == ["node1", "node2"]
