"""The kubelet configuration is rendered twice and the two are not the same thing.

One rendering is the cluster wide baseline, which kubeadm uploads and every node
downloads; the other is the patch a node lays over it. A key in the baseline
reaches every node, and a patch can not take a key away - which is how a policy
named on one node became the policy of the cluster once already (1b5b862).

What holds that shut is one flag. The template keeps every per node key behind
it and upload-k8s-kubelet-config.sh turns it on to render the baseline, so there
is no second list of those keys for the first one to drift from. What can still
drift is the name: a flag the script passes that the template does not gate on
leaves the gate open for good, with both files still looking right on their own.
Both halves of that name are read out of the files here rather than written down
beside them.
"""
import re

import yaml
from jinja2 import Environment, FileSystemLoader, meta

from conftest import REPO

K8S_NODE = REPO / "scripts" / "k8s-node"
TEMPLATES = K8S_NODE / "templates"
TEMPLATE = "kubeadm-kubelet-config.yml.j2"
UPLOAD_SCRIPT = K8S_NODE / "upload-k8s-kubelet-config.sh"

# What the template writes for every node, whatever that node asked for.
# serverTLSBootstrap is here rather than behind the gate on purpose: it is
# decided for the cluster, so the baseline carries it and a node that wanted it
# off could not take it back out of a merge
ALWAYS_PRESENT = {"apiVersion", "kind", "systemReserved", "kubeReserved", "evictionHard",
                  "serverTLSBootstrap"}

# The -D the upload script hands jinja2 to render the baseline, and the variable
# the template asks about before it writes anything that belongs to one node
BASELINE_FLAG_PASSED = re.compile(r"-D +(?P<name>[A-Za-z0-9_]+) *= *true")
BASELINE_FLAG_GATED = re.compile(r"{%-? +if +not +(?P<name>[A-Za-z0-9_]+) *[|%]")


def baseline_flag_passed():
    """The variable upload-k8s-kubelet-config.sh turns on for the baseline."""
    source = UPLOAD_SCRIPT.read_text(encoding="utf-8")
    found = BASELINE_FLAG_PASSED.search(source)
    assert found is not None, f"No baseline flag was passed to jinja2 in {UPLOAD_SCRIPT.name}"

    return found.group("name")


def baseline_flag_gated_on():
    """The variable the template keeps its per node keys behind."""
    source = (TEMPLATES / TEMPLATE).read_text(encoding="utf-8")
    found = BASELINE_FLAG_GATED.search(source)
    assert found is not None, f"No baseline gate was found in {TEMPLATE}"

    return found.group("name")


def policy_variables():
    """The kubelet variables the template decides a per node key on.

    Which ones those are is read off the gate rather than listed here: a
    variable the template names only below it is one the gate covers, and one
    named above it - the reservations, the gate itself, a key decided for the
    cluster - is written for every node and is not a per node key
    """
    source = (TEMPLATES / TEMPLATE).read_text(encoding="utf-8")
    names = meta.find_undeclared_variables(Environment().parse(source))
    gate = BASELINE_FLAG_GATED.search(source).start()

    return {name for name in names
            if name.startswith("kubelet_") and source.find(name) > gate}


def render(hostvars, **overrides):
    context = dict(hostvars["node1"])
    context.update(overrides)

    environment = Environment(loader=FileSystemLoader(str(TEMPLATES)), keep_trailing_newline=True)
    rendered = environment.get_template(TEMPLATE).render(**context)
    return yaml.safe_load(rendered)


def test_a_node_naming_no_policy_renders_no_policy_key(hostvars):
    """What the defaults render is what the cluster baseline carries."""
    document = render(hostvars)

    assert set(document) == ALWAYS_PRESENT


def test_the_baseline_is_rendered_with_the_flag_the_template_gates_on():
    """The name in the shell script against the name in the template.

    Neither file is where a per node key is added, and a name that stopped
    matching would hand every one of them to the cluster with both files still
    reading correctly on their own
    """
    assert baseline_flag_passed() == baseline_flag_gated_on()


def test_a_node_naming_every_policy_still_uploads_a_baseline_without_one(hostvars):
    """1b5b862 asked of the node that caused it: the one that named everything."""
    named = {name: "named-on-this-node" for name in policy_variables()}
    baseline = {**named, baseline_flag_gated_on(): True}

    assert set(render(hostvars, **named)) > ALWAYS_PRESENT, "nothing was named"
    assert set(render(hostvars, **baseline)) == ALWAYS_PRESENT


def test_a_cgroup_v1_node_exempts_itself_and_the_baseline_exempts_nobody(hostvars):
    """failCgroupV1 is not a policy and sits behind the gate for a harder reason.

    The node that happens to upload the baseline would be deciding the hierarchy
    every other node is allowed to come up on, and a node that inherited the
    exemption could never give it back
    """
    patch = render(hostvars, node_cgroup_version="v1")
    baseline = render(hostvars, node_cgroup_version="v1", **{baseline_flag_gated_on(): True})

    assert patch["failCgroupV1"] is False
    assert "failCgroupV1" not in baseline


def test_the_reservations_are_always_rendered(hostvars):
    document = render(hostvars)

    assert document["systemReserved"]["cpu"] == "40m"
    assert document["kubeReserved"]["memory"] == "1331Mi"
    assert document["evictionHard"]["nodefs.inodesFree"] == "5%"
    # The two halves are given the same cpu and the same memory, so the pids are
    # what says the template did not write one of them where the other goes
    assert document["systemReserved"]["pid"] == "2000"
    assert document["kubeReserved"]["pid"] == "1000"


def test_a_node_given_a_cpu_policy_renders_it(hostvars):
    document = render(hostvars, kubelet_cpu_manager_policy="static")

    assert document["cpuManagerPolicy"] == "static"
    assert "cpuManagerPolicyOptions" not in document


def test_full_pcpus_only_is_rendered_under_the_policy_that_takes_it(hostvars):
    """The option belongs to the static policy, so a node that asked for it
    without the policy renders neither rather than an option kubelet refuses."""
    with_policy = render(hostvars, kubelet_cpu_manager_policy="static",
                         kubelet_cpu_manager_full_pcpus_only=True)
    without_policy = render(hostvars, kubelet_cpu_manager_full_pcpus_only=True)

    assert with_policy["cpuManagerPolicyOptions"] == {"full-pcpus-only": "true"}
    assert "cpuManagerPolicyOptions" not in without_policy


def test_a_topology_policy_brings_its_scope(hostvars):
    document = render(hostvars, kubelet_topology_manager_policy="single-numa-node",
                      kubelet_topology_manager_scope="pod")

    assert document["topologyManagerPolicy"] == "single-numa-node"
    assert document["topologyManagerScope"] == "pod"


def test_the_reserved_cpus_and_the_pod_ceiling_are_rendered_when_named(hostvars):
    document = render(hostvars, kubelet_reserved_system_cpus="0-3,64-67", kubelet_max_pods=250)

    assert document["reservedSystemCPUs"] == "0-3,64-67"
    assert document["maxPods"] == 250
