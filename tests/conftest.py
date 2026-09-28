"""The inventory the tests start from, built out of the repository itself.

validate-hostvars.py reads what ansible hands it, which is every variable of
group_vars merged with what the inventory sets on a node and with the facts
gather-facts.yml derives. Writing that mapping out by hand would be a second
copy of group_vars, and a variable added there would leave the tests passing
against a cluster nobody runs.

So the defaults are read from group_vars and rendered. Ansible is not here to
do that, and the templates in constant-vars.yml reach for things only ansible
has - hostvars, the lookup plugin, the from_yaml filter - so those are supplied
below, and the few values that ansible would keep as objects rather than as text
are put back as objects after the rendering.

What is left to the tests is what the inventory and the facts say: the nodes,
their addresses, the groups, and what each machine reported about itself.

These tests need a posix host. What they assert about is a validator that
refuses a path unless it is absolute, and "/var/lib/k8s-installer" is not
absolute on windows.
"""
import copy
import subprocess
import sys
from pathlib import Path

import pytest
import yaml
from jinja2 import ChainableUndefined, Environment

REPO = Path(__file__).resolve().parents[1]
ANSIBLE = REPO / "ansible"
PREFLIGHT = REPO / "scripts" / "preflight"

NODE1_IP = "192.168.0.1"
NODE2_IP = "192.168.0.2"
INTERNAL_SUBNET = "192.168.0.0/24"
# vars.yml ships ha mode on and the vip unset, which is not an inventory anyone
# can run: the address is the one thing only the site knows. So the cluster the
# tests start from is the one an operator would have written
KI_CP_VIP = "192.168.0.10"


def _lookup_file(kind, path):
    """The file lookup, which is the only kind group_vars asks for."""
    if kind != "file":
        raise ValueError(f"lookup(\"{kind}\") is not one these tests supply")

    return Path(path).read_text(encoding="utf-8")


def _render_group_vars():
    """group_vars/all as ansible would have it, with the templates resolved."""
    merged = {}
    for name in ("constant-vars.yml", "vars.yml"):
        merged.update(yaml.safe_load((ANSIBLE / "group_vars/all" / name).read_text(encoding="utf-8")))

    # The lookups of group_vars read the release metadata at the path a node
    # keeps it at, which is not where this checkout has it. What moves is the
    # path, so that a lookup added over some other file reads that file rather
    # than this one
    merged["ki_opt_release_meta_path"] = str(REPO / "release.yml")

    environment = Environment(undefined=ChainableUndefined)
    environment.filters["from_yaml"] = yaml.safe_load
    environment.globals["lookup"] = _lookup_file

    context = dict(merged)
    context["hostvars"] = {"localhost": {"control_node_ih": "node1"}}

    # A value can be written in terms of another, so this goes round until
    # nothing changes rather than assuming an order
    for _ in range(16):
        changed = False
        for name, value in list(merged.items()):
            if not isinstance(value, str) or "{{" not in value:
                continue

            rendered = environment.from_string(value).render(**context)
            if rendered != value:
                merged[name] = rendered
                context[name] = rendered
                changed = True
        if not changed:
            break

    release = yaml.safe_load((REPO / "release.yml").read_text(encoding="utf-8"))
    k8s = release["k8s_versions"].get(merged["k8s_minor_version"], {})
    merged.update({
        "ki_release_version": release["version"],
        "ki_release_upgradable_from": release["upgradable_from"],
        "ki_release_k8s_versions": release["k8s_versions"],
        "ki_release_packages": release["packages"],
        "ki_release_binaries": release["binaries"],
        "ki_release_k8s": k8s,
        "k8s_version": k8s.get("kubernetes", ""),
        "k8s_pause_version": k8s.get("pause", ""),
        "ki_broken_nodes": [],
        "ki_control_node_ih": "node1",
    })
    return merged


def _build_hostvars():
    """A two node cluster: node1 is the ki cp node and both run the control plane."""
    defaults = _render_group_vars()
    addresses = {"node1": NODE1_IP, "node2": NODE2_IP}
    groups = {
        "all": ["node1", "node2"],
        "ki_cp_node": ["node1"],
        "k8s_node": ["node1", "node2"],
        "broken_node": [],
        "control_node": ["localhost"],
    }
    internal_network_hosts = {
        name: {"interfaces": [{"ip": address, "subnet": INTERNAL_SUBNET}]}
        for name, address in addresses.items()
    }

    defaults["ki_cp_ha_mode_vip"] = KI_CP_VIP

    hostvars = {}
    for name, address in addresses.items():
        # A copy of its own, so that a test breaking a list or a mapping on one
        # node is not also breaking it on the node beside it
        node = copy.deepcopy(defaults)
        node.update({
            "groups": groups,
            "inventory_hostname": name,
            "ansible_host": address,
            "k8s_cp": True,
            "internal_network_ip": address,
            "internal_network_interfaces": internal_network_hosts[name]["interfaces"],
            # what get-cgroup-version.sh reported, which gather-facts.yml sets
            # before anything renders a kubelet configuration
            "node_cgroup_version": "v2",
            # what get-node-resources.sh reported: 4 cores, 16Gi, 200G
            "node_resources": {
                "cpu_millicores": 4000,
                "memory_kib": 16 * 1024 * 1024,
                "nodefs_bytes": 200 * 1024 ** 3,
                "imagefs_bytes": 200 * 1024 ** 3,
                "pid_max": 4194304,
            },
            # what create-kubelet-reservations.py answered for the capacity
            # above, which gather-facts.yml sets before the validator runs
            "kubelet_reservations": {
                "system_reserved": {"cpu": "40m", "memory": "1331Mi",
                                    "ephemeral-storage": "5120Mi", "pid": 2000},
                "kube_reserved": {"cpu": "40m", "memory": "1331Mi",
                                  "ephemeral-storage": "5120Mi", "pid": 1000},
                "eviction_hard": {"memory.available": "500Mi", "nodefs.available": "20480Mi",
                                  "imagefs.available": "20480Mi", "nodefs.inodesFree": "5%"},
            },
        })
        hostvars[name] = node

    localhost = copy.deepcopy(defaults)
    localhost.update({
        "groups": groups,
        "inventory_hostname": "localhost",
        "control_node_ih": "node1",
        "localhost_ih": "node1",
        "internal_network_hosts": internal_network_hosts,
        "ki_opt_ansible_path": str(ANSIBLE),
    })
    hostvars["localhost"] = localhost
    return hostvars


@pytest.fixture(scope="session")
def _inventory():
    """Built once. Reading group_vars and rendering it gives the same answer
    every time, and the copy below is what keeps the tests apart."""
    return _build_hostvars()


@pytest.fixture
def hostvars(_inventory):
    """A fresh copy per test, since every test but the first one breaks it."""
    return copy.deepcopy(_inventory)


def run_validator(hostvars):
    return subprocess.run(
        [sys.executable, str(PREFLIGHT / "validate-hostvars.py")],
        input=yaml.safe_dump(hostvars),
        capture_output=True,
        text=True,
        check=False,
    )


def assert_accepted(hostvars):
    result = run_validator(hostvars)
    assert result.returncode == 0, result.stdout + result.stderr


def assert_refused(hostvars, *, naming):
    """Refused, and the report says which variable, which is half of its job."""
    result = run_validator(hostvars)
    assert result.returncode != 0, "was accepted"
    report = result.stdout + result.stderr
    assert naming in report, report
    return report
