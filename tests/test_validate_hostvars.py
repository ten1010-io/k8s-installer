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


def test_a_vip_carrier_without_ha_mode_is_refused(hostvars):
    """aws-eni says the address is to be moved through the ec2 api, and a cluster
    that is not in ha mode has no address to move."""
    hostvars["localhost"]["ki_cp_ha_mode"] = False
    hostvars["localhost"]["ki_cp_ha_mode_vip"] = None
    hostvars["localhost"]["ki_cp_ha_mode_vip_carrier"] = "aws-eni"

    assert_refused(hostvars, naming="ki_cp_ha_mode_vip_carrier")


def test_a_vip_carrier_nobody_wrote_is_refused(hostvars):
    hostvars["localhost"]["ki_cp_ha_mode_vip_carrier"] = "nlb"

    assert_refused(hostvars, naming="ki_cp_ha_mode_vip_carrier")


def test_the_ec2_vip_carrier_is_accepted_in_ha_mode(hostvars):
    hostvars["localhost"]["ki_cp_ha_mode_vip_carrier"] = "aws-eni"

    assert_accepted(hostvars)


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


def test_kube_proxy_enabled_that_is_not_a_boolean_is_refused(hostvars):
    """The template writes proxy.disabled from it either way, so a value that is
    neither would render a cluster the user did not ask for."""
    for node in hostvars.values():
        node["k8s_kube_proxy_enabled"] = "maybe"

    assert_refused(hostvars, naming="k8s_kube_proxy_enabled")


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


def test_the_connection_user_of_vars_yml_needs_no_class(hostvars, tmp_path):
    """ansible_user says who to log in as, which no class applies and the
    inventory may already carry per node, so vars.yml may carry it too."""
    ansible = tmp_path / "ansible"
    (ansible / "group_vars" / "all").mkdir(parents=True)
    (ansible / "group_vars" / "all" / "vars.yml").write_text(
        "ansible_user: operator\n", encoding="utf-8")
    (ansible / "inventory.yml").write_text("all:\n  hosts: {}\n", encoding="utf-8")
    hostvars["localhost"]["ki_opt_ansible_path"] = str(ansible)

    assert_accepted(hostvars)


def give_memory_policy(node):
    """A node set up the way a gpu virtual machine node is, with the reserved
    memory create-kubelet-reservations.py would have added for it."""
    node["kubelet_cpu_manager_policy"] = "static"
    node["kubelet_topology_manager_policy"] = "single-numa-node"
    node["kubelet_topology_manager_scope"] = "pod"
    node["kubelet_memory_manager_policy"] = "static"
    # 1331Mi + 1331Mi + 500Mi, over the two numa nodes the fixture reports
    node["kubelet_reservations"]["reserved_memory"] = [
        {"numa_node": 0, "limits": {"memory": "1581Mi"}},
        {"numa_node": 1, "limits": {"memory": "1581Mi"}},
    ]


def test_a_gpu_virtual_machine_node_is_accepted(hostvars):
    give_memory_policy(hostvars["node2"])

    assert_accepted(hostvars)


def test_the_memory_policy_without_a_topology_policy_is_refused(hostvars):
    """The memory manager hands the topology manager a numa hint, and with the
    topology policy at none there is no alignment for the hint to go into."""
    give_memory_policy(hostvars["node2"])
    hostvars["node2"]["kubelet_topology_manager_policy"] = "none"
    hostvars["node2"]["kubelet_topology_manager_scope"] = "container"

    assert_refused(hostvars, naming="kubelet_memory_manager_policy")


def test_reserved_memory_that_does_not_add_up_is_refused(hostvars):
    """The equality kubelet checks when it starts, checked before a node is given
    the file: the list is derived from the three it has to equal, and this is
    what catches the day that stops being true."""
    give_memory_policy(hostvars["node2"])
    hostvars["node2"]["kubelet_reservations"]["reserved_memory"][1]["limits"]["memory"] = "1580Mi"

    assert_refused(hostvars, naming="reserved_memory")


def test_the_memory_policy_without_reserved_memory_is_refused(hostvars):
    give_memory_policy(hostvars["node2"])
    del hostvars["node2"]["kubelet_reservations"]["reserved_memory"]

    assert_refused(hostvars, naming="reserved_memory")


def test_a_percentage_eviction_threshold_under_the_memory_policy_is_refused(hostvars):
    give_memory_policy(hostvars["node2"])
    hostvars["node2"]["kubelet_eviction_hard_memory_available"] = "5%"
    hostvars["node2"]["kubelet_reservations"]["eviction_hard"]["memory.available"] = "5%"

    assert_refused(hostvars, naming="kubelet_eviction_hard_memory_available")


RHEL_8 = {"distribution": "rhel", "major_version": "8", "minor_version": "10", "kernel_version": "4.18"}
RHEL_9 = {"distribution": "rhel", "major_version": "9", "minor_version": "6", "kernel_version": "5.14"}
UBUNTU_22_04_GA_KERNEL = {"distribution": "ubuntu", "major_version": "22.04", "minor_version": "5",
                          "kernel_version": "5.15"}
PER_NUMA_NODE_HUGEPAGES = ["hugepagesz=1G", "hugepages=0:4,1:4"]


def test_per_numa_node_hugepages_on_rhel_8_are_refused(hostvars):
    """Linux 5.16 added hugepages=<node>:<count>, and the 4.18 kernel of rhel 8
    reads the whole argument as a bad number: the node boots with no pages."""
    hostvars["node2"]["node_os"] = RHEL_8
    hostvars["node2"]["kernel_cmdline_extra_args"] = PER_NUMA_NODE_HUGEPAGES

    assert_refused(hostvars, naming="kernel_cmdline_extra_args")


def test_per_numa_node_hugepages_on_the_ga_kernel_of_ubuntu_22_04_are_refused(hostvars):
    """The same release boots a 5.15 or a 6.8 depending on the kernel package,
    and 5.15 is a kernel before the form like the 4.18 of rhel 8 is. What is
    refused is the kernel, not the distribution."""
    hostvars["node2"]["node_os"] = UBUNTU_22_04_GA_KERNEL
    hostvars["node2"]["kernel_cmdline_extra_args"] = PER_NUMA_NODE_HUGEPAGES

    assert_refused(hostvars, naming="kernel_cmdline_extra_args")


def test_per_numa_node_hugepages_on_a_kernel_that_reads_them_are_accepted(hostvars):
    """The fixture is ubuntu 22.04 on the 6.8 hwe kernel, which is past 5.16."""
    hostvars["node2"]["kernel_cmdline_extra_args"] = PER_NUMA_NODE_HUGEPAGES

    assert_accepted(hostvars)


def test_per_numa_node_hugepages_on_rhel_9_are_accepted_as_a_backport(hostvars):
    """5.14 is before the form by number and reads it anyway: rhel 9 carries the
    change as a backport, so it is let through by name rather than by number."""
    hostvars["node2"]["node_os"] = RHEL_9
    hostvars["node2"]["kernel_cmdline_extra_args"] = PER_NUMA_NODE_HUGEPAGES

    assert_accepted(hostvars)


def test_one_count_of_hugepages_on_rhel_8_is_accepted(hostvars):
    hostvars["node2"]["node_os"] = RHEL_8
    hostvars["node2"]["kernel_cmdline_extra_args"] = ["hugepagesz=1G", "hugepages=8"]

    assert_accepted(hostvars)


def test_a_local_ntp_fallback_that_is_not_a_bool_is_refused(hostvars):
    hostvars["localhost"]["ki_cp_ntp_server_local_fallback"] = "sometimes"

    assert_refused(hostvars, naming="ki_cp_ntp_server_local_fallback")
