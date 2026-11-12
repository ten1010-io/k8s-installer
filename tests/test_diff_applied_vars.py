"""diff-applied-vars.py decides what update-cluster.yml does about a change.

The table in constant-vars.yml says what class a variable is, and the class says
how it is applied. Two things are asserted here. One is the place the answer
depends on the node as well as the variable: the memory a node keeps for itself
is a kubelet restart everywhere except on a node running the static memory
manager, whose checkpoint records that memory and refuses a kubelet that reads a
different figure. The other is what a variable the record does not hold is
compared against: the fallback of the release where the class is applied, so
that a value set in the same run as the upgrade that added the variable is
applied rather than written down as applied, and what the node holds now where
the class refuses.
"""
import subprocess
import sys

import yaml

from conftest import ANSIBLE, PREFLIGHT

CONSTANT_VARS = ANSIBLE / "group_vars/all/constant-vars.yml"

BLOCKING_CLASSES = {"immutable", "cluster_upgrade", "node_rebuild"}


def diff(hostvars, constant_vars=CONSTANT_VARS):
    result = subprocess.run(
        [sys.executable, str(PREFLIGHT / "diff-applied-vars.py"), "--constant-vars-path", str(constant_vars)],
        input=yaml.safe_dump(hostvars), capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stdout + result.stderr
    return yaml.safe_load(result.stdout)


def forget(hostvars, name):
    """The record of every node as a release before the variable wrote it."""
    for ih, node in hostvars.items():
        if ih != "localhost":
            node["ki_applied_vars"].pop(name, None)


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


def diff_refused(hostvars):
    """What update-cluster.yml is told when the diff refuses: the exit code and
    the text, which names the class and the node."""
    result = subprocess.run(
        [sys.executable, str(PREFLIGHT / "diff-applied-vars.py"), "--constant-vars-path", str(CONSTANT_VARS)],
        input=yaml.safe_dump(hostvars), capture_output=True, text=True, check=False)
    assert result.returncode != 0, result.stdout
    return result.stderr


def test_a_kernel_command_line_change_is_a_reboot_of_that_node(hostvars):
    """Read at a boot and applied by one: update-cluster.yml writes the node
    and reboots it rather than refusing it, and only the node that changed."""
    record_as_applied(hostvars)
    hostvars["node2"]["kernel_cmdline_extra_args"] = ["hugepagesz=2M", "hugepages=512"]

    result = diff(hostvars)

    assert changed(result, "node_reboot") == [("node2", "kernel_cmdline_extra_args")]
    assert changed(result, "node_rebuild") == []


def test_an_emptied_kernel_command_line_is_the_same_reboot(hostvars):
    """Taking the arguments away is written and rebooted for the way adding
    them is: an empty list is not nothing to do."""
    hostvars["node2"]["kernel_cmdline_extra_args"] = ["hugepagesz=2M", "hugepages=512"]
    record_as_applied(hostvars)
    hostvars["node2"]["kernel_cmdline_extra_args"] = []

    result = diff(hostvars)

    assert changed(result, "node_reboot") == [("node2", "kernel_cmdline_extra_args")]


def test_a_vfio_pci_change_is_still_refused(hostvars):
    """vfio-pci takes effect at a boot too and stays a rebuild: it changes what
    the node is to the cluster, not a value it runs with."""
    record_as_applied(hostvars)
    hostvars["node2"]["vfio_pci_device_ids"] = ["10de:2230"]

    stderr = diff_refused(hostvars)

    assert 'class["node_rebuild"]' in stderr
    assert 'node["node2"] variable["vfio_pci_device_ids"]' in stderr


def test_a_refused_change_takes_the_reboot_with_it(hostvars):
    """Refusals are decided before anything is applied, so a kernel command
    line change beside a refused one is not written either."""
    record_as_applied(hostvars)
    hostvars["node2"]["kernel_cmdline_extra_args"] = ["hugepagesz=2M", "hugepages=512"]
    hostvars["node2"]["vfio_pci_device_ids"] = ["10de:2230"]

    stderr = diff_refused(hostvars)

    assert 'variable["vfio_pci_device_ids"]' in stderr
    assert "Nothing was applied" in stderr


def test_a_variable_the_record_lacks_is_compared_against_the_fallback_of_the_release(hostvars):
    """The cluster of the rig: built before the memory manager policy had a name,
    upgraded to the release that gave it one and told, in the same run, to run
    static on one node. Nothing recorded "none", and the node has to be drained
    all the same, because none is what the fallback says it was running with."""
    record_as_applied(hostvars)
    forget(hostvars, "kubelet_memory_manager_policy")
    hostvars["node2"]["kubelet_cpu_manager_policy"] = "static"
    hostvars["node2"]["kubelet_topology_manager_policy"] = "restricted"
    hostvars["node2"]["kubelet_memory_manager_policy"] = "static"
    forget(hostvars, "kubelet_cpu_manager_policy")
    forget(hostvars, "kubelet_topology_manager_policy")

    result = diff(hostvars)

    assert set(changed(result, "kubelet_policy")) == {
        ("node2", "kubelet_cpu_manager_policy"),
        ("node2", "kubelet_topology_manager_policy"),
        ("node2", "kubelet_memory_manager_policy"),
    }
    assert all(change["compared_with"] == "fallback" and change["applied"] == "none"
               for change in result["changes"]["kubelet_policy"])
    assert result["baseline_names"] == []
    assert any("kubelet_memory_manager_policy\"] none -> static (not recorded" in line
               for line in result["summary"])


def test_an_upgrade_that_keeps_the_fallback_passes_quietly(hostvars):
    """The same cluster with nothing set: every node runs what the fallback says,
    so there is nothing to apply and nothing to announce as a starting point."""
    record_as_applied(hostvars)
    forget(hostvars, "kubelet_memory_manager_policy")

    result = diff(hostvars)

    assert all(not changes for changes in result["changes"].values())
    assert result["baseline_names"] == []
    assert result["summary"] == []


def test_a_memory_reservation_on_a_node_whose_record_predates_the_policy_follows_the_fallback(hostvars):
    """What the node ran before is the fallback where the record says nothing, so
    a reservation changed on a node that never recorded a policy and runs none
    is a restart, not a drain."""
    record_as_applied(hostvars)
    forget(hostvars, "kubelet_memory_manager_policy")
    hostvars["node2"]["kubelet_system_reserved_memory"] = "3Gi"

    result = diff(hostvars)

    assert changed(result, "kubelet") == [("node2", "kubelet_system_reserved_memory")]
    assert changed(result, "kubelet_policy") == []


def test_a_variable_of_a_blocking_class_the_record_lacks_is_taken_as_it_is(hostvars):
    """A record is not always complete - upgrade-cluster.yml writes only the
    classes it applied - and a refusal is not something to risk on that, so a
    node_rebuild variable nobody recorded is the starting point and is said to be."""
    record_as_applied(hostvars)
    forget(hostvars, "vfio_pci_device_ids")
    hostvars["node2"]["vfio_pci_device_ids"] = ["10de:1eb8"]

    result = diff(hostvars)

    assert all(not changes for changes in result["changes"].values())
    assert result["baseline_names"] == ["vfio_pci_device_ids"]


def test_a_variable_the_release_gives_no_fallback_is_compared_against_nothing(hostvars):
    """A variable no node held before it was named holds nothing in its record,
    so a value now is a change from that. constant-vars.yml gives every applied
    variable a fallback today; this is what the rule does for one that has none."""
    hostvars["localhost"]["ki_var_classes"]["service"].append("ki_cp_dns_server_extra_option")
    record_as_applied(hostvars)
    hostvars["node1"]["ki_cp_dns_server_extra_option"] = "minimal-responses yes"

    result = diff(hostvars)

    assert changed(result, "service") == [("node1", "ki_cp_dns_server_extra_option")]
    change = result["changes"]["service"][0]
    assert change["compared_with"] == "unset" and change["applied"] is None
    assert any("(unset) -> minimal-responses yes (not recorded" in line for line in result["summary"])


def test_every_variable_of_a_class_update_cluster_applies_has_a_fallback():
    """The rule above rests on the fallback being there: a variable a release
    adds to an applied class without one is compared against nothing, and a value
    everybody already held reads as a change on every node. So adding one means
    adding its fallback, and this is what says so before a cluster does."""
    constant_vars = yaml.safe_load(CONSTANT_VARS.read_text(encoding="utf-8"))

    # Declared on the localhost entry of inventory.yml and held by no node, so no
    # record ever holds it or lacks it
    held_by_no_node = {"control_node_ih"}

    missing = sorted(
        name
        for cls, names in constant_vars["ki_var_classes"].items()
        if cls not in BLOCKING_CLASSES
        for name in names
        if name not in constant_vars and name not in held_by_no_node)

    assert missing == [], f"applied variables without a fallback in constant-vars.yml: {missing}"


def test_the_fallbacks_are_the_values_vars_yml_ships():
    """A fallback that differs from the line vars.yml ships is a deliberate
    statement that an upgraded cluster runs something other than a new one
    would, and the one such statement there is says so beside its line."""
    constant_vars = yaml.safe_load(CONSTANT_VARS.read_text(encoding="utf-8"))
    vars_yml = yaml.safe_load((ANSIBLE / "group_vars/all/vars.yml").read_text(encoding="utf-8"))
    deliberate = {"ki_cp_ntp_server_local_fallback"}

    differing = sorted(
        name
        for names in constant_vars["ki_var_classes"].values()
        for name in names
        if name in constant_vars and name in vars_yml and name not in deliberate
        and constant_vars[name] != vars_yml[name])

    assert differing == [], f"fallbacks that differ from the line vars.yml ships: {differing}"


def test_an_optional_variable_taken_out_of_vars_yml_is_a_change(hostvars):
    """The line removed resolves to the fallback, null, and the record says what
    it held, so the zone the dns server still serves is a change to apply. The
    direction a variable can not be seen moving in is unset to unset, and with
    every applied variable carrying a fallback no node holds one unset."""
    for ih in ("node1", "node2"):
        hostvars[ih]["internal_network_extra_zone"] = "example.com"
    record_as_applied(hostvars)
    for ih in ("node1", "node2"):
        hostvars[ih]["internal_network_extra_zone"] = None

    result = diff(hostvars)

    assert changed(result, "service") == [("node1", "internal_network_extra_zone"),
                                          ("node2", "internal_network_extra_zone")]
    assert any("example.com -> null" in line for line in result["summary"])


def test_every_classified_variable_a_node_can_hold_is_always_defined(hostvars):
    """What the test above rests on: a classified variable is never absent from
    a node, so a line taken out of vars.yml is a value the diff sees rather than
    a name it skips. control_node_ih is declared on localhost and held by no node."""
    classified = {name for names in hostvars["localhost"]["ki_var_classes"].values() for name in names}

    for ih in ("node1", "node2"):
        missing = sorted(classified - set(hostvars[ih]) - {"control_node_ih"})
        assert missing == [], f"{ih} holds no value for {missing}"
