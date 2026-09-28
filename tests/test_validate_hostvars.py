"""What validate-hostvars.py is for is refusing an inventory before a node is touched.

Every test here takes an inventory the validator accepts and breaks one thing in
it. What is asserted is that the run stops and that the report names the variable
to fix, since a refusal nobody can act on costs as much as no refusal at all.
"""
from conftest import assert_accepted, assert_refused


def test_the_inventory_the_tests_start_from_is_accepted(hostvars):
    assert_accepted(hostvars)


def test_ha_mode_without_a_vip_is_refused(hostvars):
    hostvars["localhost"]["ki_cp_ha_mode"] = True
    hostvars["localhost"]["ki_cp_ha_mode_vip"] = None

    assert_refused(hostvars, naming="ki_cp_ha_mode_vip")


def test_a_vip_outside_the_subnet_of_the_ki_cp_nodes_is_refused(hostvars):
    hostvars["localhost"]["ki_cp_ha_mode"] = True
    hostvars["localhost"]["ki_cp_ha_mode_vip"] = "10.0.0.10"

    assert_refused(hostvars, naming="ki_cp_ha_mode_vip")


def test_a_control_node_outside_the_ki_cp_group_is_refused(hostvars):
    """The group is checked against the node the hostnames actually resolve to,
    which is what localhost_ih carries rather than what the inventory declares."""
    hostvars["localhost"]["localhost_ih"] = "node2"

    assert_refused(hostvars, naming="localhost_ih")


def test_a_control_node_other_than_the_declared_one_is_refused(hostvars):
    """The other half: the node the playbooks are being run from is not the one
    control_node_ih names, so the bootstrap plays would single out the wrong one."""
    hostvars["localhost"]["control_node_ih"] = "node2"

    assert_refused(hostvars, naming="control_node_ih")


def test_an_inventory_with_no_broken_node_group_is_refused(hostvars):
    del hostvars["localhost"]["groups"]["broken_node"]

    assert_refused(hostvars, naming="broken_node")


def test_the_pod_subnet_overlapping_the_service_subnet_is_refused(hostvars):
    for node in hostvars.values():
        node["k8s_service_subnet"] = "10.244.0.0/16"

    assert_refused(hostvars, naming="k8s_service_subnet")


def test_the_pod_subnet_overlapping_the_internal_network_is_refused(hostvars):
    for node in hostvars.values():
        node["k8s_pod_subnet"] = "192.168.0.0/16"

    assert_refused(hostvars, naming="k8s_pod_subnet")


def test_an_apiserver_argument_carrying_its_dashes_is_refused(hostvars):
    for node in hostvars.values():
        node["k8s_apiserver_extra_args"] = [
            {"name": "--audit-policy-file", "value": "/etc/kubernetes/audit/policy.yaml"},
        ]

    assert_refused(hostvars, naming="k8s_apiserver_extra_args")


def test_two_apiserver_volumes_of_one_name_are_refused(hostvars):
    volumes = [
        {"name": "audit", "hostPath": "/etc/kubernetes/audit", "mountPath": "/etc/kubernetes/audit"},
        {"name": "audit", "hostPath": "/var/log/kubernetes", "mountPath": "/var/log/kubernetes"},
    ]
    for node in hostvars.values():
        node["k8s_apiserver_extra_volumes"] = volumes

    assert_refused(hostvars, naming="k8s_apiserver_extra_volumes")


def test_an_apiserver_volume_with_a_relative_path_is_refused(hostvars):
    for node in hostvars.values():
        node["k8s_apiserver_extra_volumes"] = [
            {"name": "audit", "hostPath": "etc/kubernetes/audit", "mountPath": "/etc/kubernetes/audit"},
        ]

    assert_refused(hostvars, naming="hostPath")


def test_handing_over_every_gpu_without_naming_a_device_is_refused(hostvars):
    hostvars["node2"]["gpu_passthrough"] = True
    hostvars["node2"]["vfio_pci_device_ids"] = []

    assert_refused(hostvars, naming="gpu_passthrough")


def test_a_pci_device_id_that_is_not_one_is_refused(hostvars):
    hostvars["node2"]["vfio_pci_device_ids"] = ["10de:2230", "nvidia"]

    assert_refused(hostvars, naming="vfio_pci_device_ids")


def test_a_variable_no_class_covers_is_refused(hostvars, tmp_path):
    """A variable of vars.yml that ki_var_classes does not carry is one
    update-cluster.yml would never apply, and the check reads the file rather
    than the mapping - so the file is what the test writes."""
    ansible = tmp_path / "ansible"
    (ansible / "group_vars" / "all").mkdir(parents=True)
    (ansible / "group_vars" / "all" / "vars.yml").write_text(
        "a_variable_nothing_knows_how_to_apply: true\n", encoding="utf-8")
    (ansible / "inventory.yml").write_text("all:\n  hosts: {}\n", encoding="utf-8")
    hostvars["localhost"]["ki_opt_ansible_path"] = str(ansible)

    assert_refused(hostvars, naming="a_variable_nothing_knows_how_to_apply")
