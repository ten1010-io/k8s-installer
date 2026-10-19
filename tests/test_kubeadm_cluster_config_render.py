"""Whether kube-proxy is installed is a line of the ClusterConfiguration.

It is there rather than in the skipPhases of the InitConfiguration because the
ClusterConfiguration is what kubeadm upgrade reads back out of the cluster, and
proxy.disabled is the field it skips the addon/kube-proxy phase on. The template
writes the field both ways, so the ConfigMap says what vars.yml says, and this
is where that is checked: a rendering that drops the line on one value would be
a cluster that gets kube-proxy back at its next upgrade.
"""
import yaml
from jinja2 import Environment, FileSystemLoader
from jinja2.nativetypes import NativeEnvironment

from conftest import REPO

TEMPLATES = REPO / "scripts" / "k8s-node" / "templates"
TEMPLATE = "kubeadm-cluster-config.yml.j2"


def _resolved(value, context):
    """A value of group_vars with the templates inside it evaluated.

    The fixture resolves the top level strings of group_vars and leaves what
    sits inside a list or a mapping as written, which is enough for the
    validator. This template loops over ki_k8s_cp_components, whose args and
    volumes are templates over the extra args variables, so those are
    evaluated here the way ansible would: to the list they name, not to the
    text of it
    """
    if isinstance(value, str) and "{{" in value:
        return NativeEnvironment().from_string(value).render(**context)
    if isinstance(value, list):
        return [_resolved(item, context) for item in value]
    if isinstance(value, dict):
        return {key: _resolved(item, context) for key, item in value.items()}

    return value


def render(hostvars, **overrides):
    context = dict(hostvars["node1"])
    context.update(overrides)
    context["ki_k8s_cp_components"] = _resolved(context["ki_k8s_cp_components"], context)

    environment = Environment(loader=FileSystemLoader(str(TEMPLATES)), keep_trailing_newline=True)
    rendered = environment.get_template(TEMPLATE).render(**context)
    return yaml.safe_load(rendered)


def test_the_default_keeps_kube_proxy(hostvars):
    """What vars.yml ships renders a cluster with kube-proxy, as every cluster
    built before the variable existed has."""
    document = render(hostvars)

    assert document["proxy"] == {"disabled": False}


def test_a_cluster_asked_for_no_kube_proxy_renders_the_addon_disabled(hostvars):
    document = render(hostvars, k8s_kube_proxy_enabled=False)

    assert document["proxy"] == {"disabled": True}


def test_the_rest_of_the_configuration_does_not_move_with_kube_proxy(hostvars):
    """The field is one line added, not a different document."""
    with_kube_proxy = render(hostvars)
    without_kube_proxy = render(hostvars, k8s_kube_proxy_enabled=False)

    del with_kube_proxy["proxy"]
    del without_kube_proxy["proxy"]
    assert with_kube_proxy == without_kube_proxy
    assert with_kube_proxy["networking"] == {
        "serviceSubnet": hostvars["node1"]["k8s_service_subnet"],
        "podSubnet": hostvars["node1"]["k8s_pod_subnet"],
    }
