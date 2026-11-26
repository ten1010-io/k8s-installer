"""The iscsi initiator, multipath and the one containerd setting a site can turn on.

Three things are decided off the node, and those are what is tested here: what
an inventory is allowed to say (validate-hostvars.py), what changing a variable
means on a cluster that exists (diff-applied-vars.py), and which node is given a
new initiator name when two of them share one (plan-iscsi-initiator-names.py).
The two files the variables are rendered into are read back as text.

What the scripts do on a node - whether a local disk is left out of a map,
whether a daemon a package started is stopped again - needs a node, and is
measured on one. See docs/impl-notes.adoc
"""
import subprocess
import sys

import yaml
from jinja2 import Environment, FileSystemLoader

from conftest import PREFLIGHT, REPO, assert_accepted, assert_refused
from test_diff_applied_vars import changed, diff, forget, record_as_applied

ALL_NODE = REPO / "scripts" / "all-node"


def turn_storage_on(node):
    node["iscsi_initiator_enabled"] = True
    node["iscsi_initiator_settings"] = {"node.session.scan": "manual",
                                        "node.session.timeo.replacement_timeout": 120}
    node["multipath_enabled"] = True
    node["multipath_defaults"] = {"find_multipaths": "no", "user_friendly_names": True}
    node["multipath_devices"] = [{"vendor": "EXAMPLE", "product": "LUN.*"}]


def test_a_node_with_the_initiator_and_multipath_on_is_accepted(hostvars):
    turn_storage_on(hostvars["node2"])

    assert_accepted(hostvars)


def test_multipath_on_with_no_device_named_is_refused(hostvars):
    """The file written excludes every device it is not told of, so this is a
    multipathd that is running and brings nothing together."""
    hostvars["node2"]["multipath_enabled"] = True

    assert_refused(hostvars, naming="multipath_enabled")


def test_devices_named_on_a_node_that_leaves_multipath_off_are_accepted(hostvars):
    """vars.yml may name the devices of the site once while inventory.yml turns
    multipath on per node, so a node that names them and stays off is not a
    mistake."""
    hostvars["node2"]["multipath_devices"] = [{"vendor": "EXAMPLE", "product": "LUN.*"}]

    assert_accepted(hostvars)


def test_a_multipath_device_carrying_a_key_nothing_renders_is_refused(hostvars):
    turn_storage_on(hostvars["node2"])
    hostvars["node2"]["multipath_devices"][0]["path_grouping_policy"] = "multibus"

    assert_refused(hostvars, naming="multipath_devices")


def test_a_multipath_value_that_would_close_its_own_quotes_is_refused(hostvars):
    """The value is written between a pair of quotes, so one carrying a quote
    ends where it stands and the rest of it is read as configuration."""
    turn_storage_on(hostvars["node2"])
    hostvars["node2"]["multipath_devices"][0]["vendor"] = 'EXAMPLE" } blacklist_exceptions { device { vendor ".*'

    assert_refused(hostvars, naming="multipath_devices")


def test_a_multipath_device_that_is_no_regular_expression_is_refused(hostvars):
    turn_storage_on(hostvars["node2"])
    hostvars["node2"]["multipath_devices"][0]["product"] = "LUN("

    assert_refused(hostvars, naming="multipath_devices")


def test_a_multipath_default_spelt_as_no_keyword_is_refused(hostvars):
    turn_storage_on(hostvars["node2"])
    hostvars["node2"]["multipath_defaults"] = {"find multipaths": "no"}

    assert_refused(hostvars, naming="multipath_defaults")


def test_an_iscsi_flag_written_as_a_yaml_boolean_is_refused(hostvars):
    """iscsid.conf spells a flag Yes or No. A yaml true would be written as the
    word true, which iscsid does not read as one."""
    turn_storage_on(hostvars["node2"])
    hostvars["node2"]["iscsi_initiator_settings"] = {"node.session.auth.chap_algs": True}

    assert_refused(hostvars, naming="iscsi_initiator_settings")


def test_an_iscsi_setting_carrying_a_second_line_is_refused(hostvars):
    turn_storage_on(hostvars["node2"])
    hostvars["node2"]["iscsi_initiator_settings"] = {"node.session.scan": "manual\nnode.startup = automatic"}

    assert_refused(hostvars, naming="iscsi_initiator_settings")


def test_an_indexed_iscsi_setting_is_accepted(hostvars):
    turn_storage_on(hostvars["node2"])
    hostvars["node2"]["iscsi_initiator_settings"] = {"node.conn[0].timeo.noop_out_interval": 5}

    assert_accepted(hostvars)


def test_the_containerd_device_ownership_set_on_a_node_is_refused(hostvars, tmp_path):
    """Cluster wide: whether a pod can open its volume must not depend on where
    it was scheduled. The check reads inventory.yml as a file, so the file is
    what the test writes."""
    ansible = tmp_path / "ansible"
    (ansible / "group_vars" / "all").mkdir(parents=True)
    (ansible / "group_vars" / "all" / "vars.yml").write_text("{}\n", encoding="utf-8")
    (ansible / "inventory.yml").write_text(
        "all:\n  hosts:\n    node2:\n      containerd_device_ownership_from_security_context: true\n",
        encoding="utf-8")
    hostvars["localhost"]["ki_opt_ansible_path"] = str(ansible)

    assert_refused(hostvars, naming="containerd_device_ownership_from_security_context")


def test_the_storage_variables_set_on_a_node_are_classified(hostvars, tmp_path):
    """The other half of the same read: set per node in inventory.yml, the five
    of them are variables a class covers and are let through."""
    ansible = tmp_path / "ansible"
    (ansible / "group_vars" / "all").mkdir(parents=True)
    (ansible / "group_vars" / "all" / "vars.yml").write_text(
        "containerd_device_ownership_from_security_context: true\n", encoding="utf-8")
    (ansible / "inventory.yml").write_text(yaml.safe_dump({"all": {"hosts": {"node2": {
        "iscsi_initiator_enabled": True,
        "iscsi_initiator_settings": {"node.session.scan": "manual"},
        "multipath_enabled": True,
        "multipath_defaults": {"find_multipaths": "no"},
        "multipath_devices": [{"vendor": "EXAMPLE", "product": "LUN.*"}],
    }}}}), encoding="utf-8")
    hostvars["localhost"]["ki_opt_ansible_path"] = str(ansible)

    assert_accepted(hostvars)


def test_turning_the_initiator_and_multipath_on_is_applied_without_a_drain(hostvars):
    """Filed under the class that writes a file and tells a daemon, on the node
    that changed and no other."""
    record_as_applied(hostvars)
    turn_storage_on(hostvars["node2"])

    result = diff(hostvars)

    assert sorted(changed(result, "node_storage")) == [
        ("node2", "iscsi_initiator_enabled"), ("node2", "iscsi_initiator_settings"),
        ("node2", "multipath_defaults"), ("node2", "multipath_devices"), ("node2", "multipath_enabled")]
    assert changed(result, "kubelet_policy") == []
    assert changed(result, "container_runtime") == []
    assert changed(result, "node_reboot") == []


def test_the_containerd_setting_is_a_drain_of_every_node(hostvars):
    record_as_applied(hostvars)
    for node in hostvars.values():
        node["containerd_device_ownership_from_security_context"] = True

    result = diff(hostvars)

    assert sorted(changed(result, "container_runtime")) == [
        ("node1", "containerd_device_ownership_from_security_context"),
        ("node2", "containerd_device_ownership_from_security_context")]
    assert changed(result, "node_storage") == []


def test_a_cluster_from_before_the_variables_existed_has_nothing_to_apply(hostvars):
    """The record of such a cluster holds none of the six. Compared against the
    fallback of the release, which is off and empty, an inventory that leaves
    them alone is no change: the upgrade does nothing to those nodes."""
    record_as_applied(hostvars)
    for name in ("iscsi_initiator_enabled", "iscsi_initiator_settings", "multipath_enabled",
                 "multipath_defaults", "multipath_devices",
                 "containerd_device_ownership_from_security_context"):
        forget(hostvars, name)

    result = diff(hostvars)

    assert all(not changes for changes in result["changes"].values())


def plan(hostvars):
    return subprocess.run(
        [sys.executable, str(PREFLIGHT / "plan-iscsi-initiator-names.py")],
        input=yaml.safe_dump(hostvars), capture_output=True, text=True, check=False)


def name_node(hostvars, ih, name, *, managed=False, sessions=0):
    hostvars[ih]["iscsi_initiator_enabled"] = True
    hostvars[ih]["ki_iscsi_initiator_state"] = {"name": name, "managed": managed, "sessions": sessions}


def new_names(hostvars):
    result = plan(hostvars)
    assert result.returncode == 0, result.stdout + result.stderr
    return yaml.safe_load(result.stdout)["new_name_ihs"]


IQN = "iqn.2004-10.com.ubuntu:01:5c1ab5c1ab5"


def test_nodes_with_names_of_their_own_are_left_alone(hostvars):
    name_node(hostvars, "node1", IQN + "1", managed=True, sessions=2)
    name_node(hostvars, "node2", IQN + "2")

    assert new_names(hostvars) == []


def test_a_node_being_built_that_shares_a_name_with_one_in_use_is_given_a_new_one(hostvars):
    name_node(hostvars, "node1", IQN, managed=True, sessions=2)
    name_node(hostvars, "node2", IQN)
    hostvars["localhost"]["target_nodes"] = ["node2"]

    assert new_names(hostvars) == ["node2"]


def test_two_nodes_built_from_one_image_end_up_with_two_names(hostvars):
    """Neither has been set up, so either could move. One keeps the name and
    the other is given a new one, the same one every time."""
    name_node(hostvars, "node1", IQN)
    name_node(hostvars, "node2", IQN)

    assert new_names(hostvars) == ["node2"]


def test_two_nodes_in_use_under_one_name_are_refused_by_name(hostvars):
    """Renaming either takes away what the storage system granted the name,
    under volumes that may be in use. That is for a person to settle."""
    name_node(hostvars, "node1", IQN, managed=True)
    name_node(hostvars, "node2", IQN, managed=True)

    result = plan(hostvars)

    assert result.returncode != 0, "was accepted"
    assert "node1, node2" in result.stderr, result.stderr
    assert IQN in result.stderr, result.stderr


def test_a_node_that_holds_a_session_is_not_renamed_though_this_installer_never_set_it_up(hostvars):
    """An initiator somebody set up by hand is known to a storage system by its
    name just the same."""
    name_node(hostvars, "node1", IQN, sessions=1)
    name_node(hostvars, "node2", IQN, sessions=1)

    assert plan(hostvars).returncode != 0


def test_a_node_this_run_is_not_setting_up_is_not_renamed(hostvars):
    """add-node touches the nodes it was pointed at. The other one keeps the
    name, since it could not be given another by this run."""
    name_node(hostvars, "node1", IQN)
    name_node(hostvars, "node2", IQN)
    hostvars["localhost"]["target_nodes"] = ["node1"]

    assert new_names(hostvars) == ["node1"]


def test_the_name_of_a_node_that_is_no_initiator_is_not_compared(hostvars):
    """A node the variable is off for holds a file nothing reads."""
    name_node(hostvars, "node1", IQN, managed=True)
    name_node(hostvars, "node2", IQN, managed=True)
    hostvars["node2"]["iscsi_initiator_enabled"] = False

    assert new_names(hostvars) == []


def test_nodes_with_no_name_yet_share_nothing(hostvars):
    name_node(hostvars, "node1", "")
    name_node(hostvars, "node2", "")

    assert new_names(hostvars) == []


def render(directory, template, **variables):
    environment = Environment(loader=FileSystemLoader(str(ALL_NODE / directory / "templates")),
                              keep_trailing_newline=True)
    return environment.get_template(template).render(**variables)


def test_multipath_conf_excludes_every_device_and_excepts_the_ones_named():
    rendered = render("multipath", "multipath.conf.j2",
                      multipath_defaults={"find_multipaths": "no", "user_friendly_names": True,
                                          "polling_interval": 5},
                      multipath_devices=[{"vendor": "EXAMPLE", "product": "LUN.*"},
                                         {"vendor": "OTHER", "product": "DISK"}])

    blacklist, exceptions = rendered.split("blacklist_exceptions {")
    assert 'vendor ".*"' in blacklist and 'product ".*"' in blacklist
    assert 'vendor "EXAMPLE"' not in blacklist
    assert exceptions.count("device {") == 2
    assert 'vendor "EXAMPLE"\n        product "LUN.*"' in exceptions
    assert 'vendor "OTHER"\n        product "DISK"' in exceptions
    # a yaml true is a word multipath takes, and a number is itself
    assert '    find_multipaths "no"\n' in rendered
    assert '    user_friendly_names "yes"\n' in rendered
    assert '    polling_interval "5"\n' in rendered
    assert rendered.count("{") == rendered.count("}")


def containerd_config(**variables):
    return render("containerd", "config.toml.j2",
                  internal_network_ki_cp_dns_name="ki-cp.ki.local", ki_cp_k8s_registry_port=5000,
                  k8s_pause_version="3.10.1", **variables)


def test_the_containerd_configuration_of_a_cluster_that_leaves_the_setting_off_is_unchanged():
    """Off renders nothing at all, not the key set to false: a node of a cluster
    that never turned it on holds the file it held before the variable existed,
    byte for byte, so taking the release restarts nothing for it."""
    off = containerd_config(containerd_device_ownership_from_security_context=False)
    never_named = containerd_config()

    assert off == never_named
    assert "device_ownership_from_security_context" not in off
    assert '  [plugins."io.containerd.cri.v1.runtime"]\n\n    [plugins."io.containerd.cri.v1.runtime".containerd]\n' in off


def test_the_containerd_setting_is_rendered_into_the_cri_runtime_table():
    """Under the table of the cri runtime plugin and before the first table
    nested in it. A key written after a nested table header belongs to that
    table, which containerd loads without complaint and does not read."""
    on = containerd_config(containerd_device_ownership_from_security_context=True)

    table = on.index('[plugins."io.containerd.cri.v1.runtime"]\n')
    key = on.index("    device_ownership_from_security_context = true\n")
    nested = on.index('[plugins."io.containerd.cri.v1.runtime".containerd]')
    assert table < key < nested
    between = on[table + len('[plugins."io.containerd.cri.v1.runtime"]\n'):key]
    assert all(line.strip().startswith("#") for line in between.splitlines() if line.strip()), between
