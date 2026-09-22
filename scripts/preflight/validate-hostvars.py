#!/usr/bin/env python3
from __future__ import annotations

import ipaddress
import sys
from ipaddress import IPv4Network, IPv4Address
from pathlib import Path
from typing import List, Any, Optional, Annotated, Union

import yaml
from pydantic import BaseModel, ValidationError, StringConstraints, ConfigDict, field_validator, Field, \
    PositiveInt

FQDN_PATTERN = r"^((?!-)[A-Za-z0-9-]{1,63}(?<!-)\.)+[A-Za-z]{2,}$"
K8S_MINOR_VERSION_PATTERN = r"^[0-9]+\.[0-9]+$"
VALIDITY_PERIOD_PATTERN = r"^[0-9]+h$"
STORAGE_SIZE_PATTERN = r"^[0-9]+[EPTGMK]i$"
CPU_QUANTITY_PATTERN = r"^([0-9]+m|[0-9]+(\.[0-9]+)?)$"
EVICTION_THRESHOLD_PATTERN = r"^([0-9]+(\.[0-9]+)?%|[0-9]+[EPTGMK]i)$"

# Variables a release removed, and what to do with the line that is left behind
REMOVED_VARS = {
    "containerd_root_path":
        "Variable[\"containerd_root_path\"] has been removed."
        " The container runtime root is no longer configurable, a node that needs it"
        " off the root filesystem sets variable[\"ephemeral_storage_device\"] instead,"
        " which bind mounts /var/lib/containerd onto that device."
        " Remove the line from vars.yml. See docs/impl-notes.adoc",
}


def main():
    hostvars = yaml.safe_load(sys.stdin)
    hostvars_errors: List[HostvarsError] = []

    check_type(hostvars_errors, hostvars)
    validate_removed_vars(hostvars_errors, hostvars)
    validate_var_classes(hostvars_errors, hostvars)
    validate_broken_node_group(hostvars_errors, hostvars)
    validate_control_node(hostvars_errors, hostvars)
    validate_ki_cp_ha_mode_vip(hostvars_errors, hostvars)
    validate_internal_network_subnets(hostvars_errors, hostvars)
    validate_kubelet_reservations(hostvars_errors, hostvars)
    validate_k8s_minor_version(hostvars_errors, hostvars)

    if len(hostvars_errors) > 0:
        print("[ERROR] Invalid hostvars", file=sys.stderr)
        print_hostvars_errors(hostvars_errors)
        exit(1)

    exit(0)


def check_type(hostvars_errors: List[HostvarsError], hostvars):
    for ih in hostvars.keys():
        try:
            VarsModel.model_validate(hostvars[ih])
        except ValidationError as e:
            for error in e.errors():
                hostvars_errors.append(build_hostvars_error(ih, error))
        try:
            ConstantVarsModel.model_validate(hostvars[ih])
        except ValidationError as e:
            for error in e.errors():
                hostvars_errors.append(build_hostvars_error(ih, error))


def validate_removed_vars(hostvars_errors: List[HostvarsError], hostvars):
    """Rejects a variable that a release has removed.

    An upgrade keeps the vars.yml of the user, so a variable that is gone stays in
    it. VarsModel ignores keys it does not know, which would leave the value
    looking like it still applies while nothing reads it any more. Saying so is
    the difference between a line to delete and a node that quietly behaves
    differently than the file it is configured by
    """
    for ih in hostvars.keys():
        for var_name, msg in REMOVED_VARS.items():
            if var_name not in hostvars[ih]:
                continue

            error = HostvarsError(ih, (var_name,), str(hostvars[ih][var_name]), msg)
            hostvars_errors.append(error)


def validate_var_classes(hostvars_errors: List[HostvarsError], hostvars):
    """Rejects a variable of vars.yml that no class covers.

    ki_var_classes says what changing a variable means, and update-cluster.yml has
    nothing to do with one that is not in it. Left unchecked, adding a variable
    and forgetting to classify it produces a variable that silently never gets
    applied to a cluster that already exists, which is found the hard way. The
    check runs here so that it is found by whoever adds it
    """
    lo_hostvars = hostvars["localhost"]
    var_classes = lo_hostvars.get("ki_var_classes")
    ansible_path = lo_hostvars.get("ki_opt_ansible_path")
    if not var_classes or not ansible_path:
        return

    classified = {name for names in var_classes.values() for name in names}

    user_vars_path = Path(ansible_path) / "group_vars" / "all" / "vars.yml"
    for var_name, value in sorted(read_yaml_mapping(user_vars_path).items()):
        if var_name in classified:
            continue

        hostvars_errors.append(build_unclassified_error(var_name, value, "vars.yml"))

    # inventory.yml is read as a file too. hostvars carries hundreds of names
    # ansible itself defines, so what a node was actually given can only be seen
    # in the file it was given in. The ansible_ ones configure the connection
    # rather than the cluster, and nothing here applies them
    inventory_path = Path(ansible_path) / "inventory.yml"
    for var_name, value in sorted(read_inventory_host_vars(inventory_path).items()):
        if var_name in classified or var_name.startswith("ansible_"):
            continue

        hostvars_errors.append(build_unclassified_error(var_name, value, "inventory.yml"))


def build_unclassified_error(var_name: str, value: Any, file_name: str) -> HostvarsError:
    return HostvarsError(
        "localhost", (var_name,), str(value),
        f"Variable[\"{var_name}\"] of {file_name} is in no class of variable"
        f"[\"ki_var_classes\"] of constant-vars.yml, so nothing knows what changing"
        f" it means. Put it in the class that says how it is applied")


def read_yaml_mapping(path: Path) -> dict:
    try:
        return yaml.safe_load(path.read_text()) or {}
    except OSError:
        return {}


def read_inventory_host_vars(path: Path) -> dict:
    """Every variable the inventory sets on a host, across all of its groups."""
    host_vars = {}
    for group in read_yaml_mapping(path).values():
        if not isinstance(group, dict):
            continue

        for node_vars in (group.get("hosts") or {}).values():
            if isinstance(node_vars, dict):
                host_vars.update(node_vars)

    return host_vars


def get_broken_node_ihs(hostvars) -> List[str]:
    """The nodes every play leaves out, because they can no longer be reached.

    They report nothing, so anything derived from what a node reports has no entry
    for them and the checks over those have to skip them
    """
    return hostvars["localhost"].get("groups", {}).get("broken_node", [])


def validate_broken_node_group(hostvars_errors: List[HostvarsError], hostvars):
    """Requires the inventory to declare the broken_node group.

    Every play excludes that group, and a pattern excluding a group that is not
    declared excludes nothing while looking like it does. An inventory kept across
    an upgrade predates the group, so the absence is reported rather than assumed
    to mean that no node is broken
    """
    if "broken_node" in hostvars["localhost"].get("groups", {}):
        control_node_ih = hostvars["localhost"].get("control_node_ih")
        if control_node_ih in get_broken_node_ihs(hostvars):
            error = HostvarsError("localhost",
                                  ("control_node_ih",),
                                  str(control_node_ih),
                                  f"Node[\"{control_node_ih}\"] is declared as the control node and as a"
                                  " broken node. The control node is the node the playbooks run from, so it"
                                  " can not be one of the nodes they leave out. Hand the control node over"
                                  " to another node of the ki_cp_node group first. See README.adoc")
            hostvars_errors.append(error)
        return

    error = HostvarsError("localhost",
                          ("groups", "broken_node"),
                          "None",
                          "Inventory does not declare the broken_node group. Every playbook"
                          " excludes it so that a node that can no longer be reached does not"
                          " stop the others from being worked on. Add it to inventory.yml:"
                          "\n\nbroken_node:\n  hosts: {}")
    hostvars_errors.append(error)


def validate_control_node(hostvars_errors: List[HostvarsError], hostvars):
    """Requires the control node to be a node of the ki_cp_node group.

    sync-ansible.yml keeps the ansible directory of every ki cp node the same as
    the one of the control node, so that losing the control node costs nothing
    more than running the playbooks from another one. That only holds while the
    control node is one of them, and while the inventory says which one it is
    """
    lo_hostvars = hostvars["localhost"]
    localhost_ih = lo_hostvars.get("localhost_ih")
    control_node_ih = lo_hostvars.get("control_node_ih")
    ki_cp_node_ihs = lo_hostvars.get("groups", {}).get("ki_cp_node", [])

    # An unset ansible variable can reach here either as None or as the string it
    # was templated into
    if localhost_ih is None or localhost_ih in ("", "None"):
        error = HostvarsError("localhost",
                              ("localhost_ih",),
                              str(localhost_ih),
                              "Control node must be one of the nodes of the inventory,"
                              " but no node has the hostname of the control node")
        hostvars_errors.append(error)
        return

    if localhost_ih not in ki_cp_node_ihs:
        error = HostvarsError("localhost",
                              ("localhost_ih",),
                              str(localhost_ih),
                              f"Control node is the node[\"{localhost_ih}\"], which is not in the ki_cp_node group."
                              " Control node must be a node of the ki_cp_node group")
        hostvars_errors.append(error)
        return

    # The bootstrap playbooks single out the control node by what the inventory
    # declares, since they run before there are any facts to derive it from.
    # check-control-node.yml compares that declaration against the hostname of the
    # node it names, and here it is compared against the node the hostnames
    # actually resolve to
    if control_node_ih != localhost_ih:
        error = HostvarsError("localhost",
                              ("control_node_ih",),
                              str(control_node_ih),
                              f"The inventory declares node[\"{control_node_ih}\"] as the control node,"
                              f" but the hostname of the control node is that of node[\"{localhost_ih}\"]."
                              " Point control_node_ih of inventory.yml at the node the playbooks are run from")
        hostvars_errors.append(error)
        return

    # Removing the node the playbook is running from would tear down the installer
    # underneath the run, so the removal is done from one of the other ki cp nodes
    if lo_hostvars.get("target_node_op") == "remove" and lo_hostvars.get("target_node") == localhost_ih:
        error = HostvarsError("localhost",
                              ("target_node",),
                              str(localhost_ih),
                              f"Node[\"{localhost_ih}\"] is the control node and can not be removed from the"
                              " cluster. Run this from another node of the ki_cp_node group")
        hostvars_errors.append(error)


def validate_ki_cp_ha_mode_vip(hostvars_errors: List[HostvarsError], hostvars):
    lo_hostvars = hostvars["localhost"]
    ki_cp_ha_mode: bool = lo_hostvars["ki_cp_ha_mode"]
    ki_cp_ha_mode_vip = lo_hostvars["ki_cp_ha_mode_vip"]

    if ki_cp_ha_mode and ki_cp_ha_mode_vip is None:
        error = HostvarsError("localhost",
                              ("ki_cp_ha_mode_vip",),
                              str(ki_cp_ha_mode_vip),
                              "Variable[\"ki_cp_ha_mode_vip\"] must be set when value for variable[\"ki_cp_ha_mode\"] is true")
        hostvars_errors.append(error)


def validate_internal_network_subnets(hostvars_errors: List[HostvarsError], hostvars):
    lo_hostvars = hostvars["localhost"]
    internal_network_subnets: List[str] = lo_hostvars["internal_network_subnets"]
    ki_cp_ha_mode: bool = lo_hostvars["ki_cp_ha_mode"]
    ki_cp_ha_mode_vip = lo_hostvars["ki_cp_ha_mode_vip"]

    broken_node_ihs = get_broken_node_ihs(hostvars)
    ki_cp_nodes = [ih for ih in lo_hostvars["groups"]["ki_cp_node"] if ih not in broken_node_ihs]
    internal_network_hosts = lo_hostvars["internal_network_hosts"]

    for ih in internal_network_hosts:
        if len(internal_network_hosts[ih]["interfaces"]) <= 0:
            error = HostvarsError("localhost",
                                  ("internal_network_subnets",),
                                  str(internal_network_subnets),
                                  f"Node[\"{ih}\"] not belong to any of given internal_network_subnets")
            hostvars_errors.append(error)
    if len(hostvars_errors) > 0:
        return

    subnets = []
    for ki_cp_node in ki_cp_nodes:
        subnets.append(internal_network_hosts[ki_cp_node]["interfaces"][0]["subnet"])
    if len(set(subnets)) != 1:
        error = HostvarsError("localhost",
                              ("internal_network_subnets",),
                              str(internal_network_subnets),
                              "Nodes in ki_cp_node group must belong to same subnet")
        hostvars_errors.append(error)
    if ki_cp_ha_mode and len(set(subnets)) == 1:
        cidr = ipaddress.ip_network(subnets[0])
        ip = ipaddress.ip_address(ki_cp_ha_mode_vip)
        if not ip in cidr:
            error = HostvarsError("localhost",
                                  ("ki_cp_ha_mode_vip",),
                                  str(ki_cp_ha_mode_vip),
                                  "Value for variable[\"ki_cp_ha_mode_vip\"] must be ip address which belongs to a subnet of nodes in ki_cp_node group")
            hostvars_errors.append(error)


def validate_k8s_minor_version(hostvars_errors: List[HostvarsError], hostvars):
    """Rejects a kubernetes minor that this release does not carry.

    The minor is the choice of whoever runs the cluster and the patch of it
    belongs to the release, so k8s_version is read out of the k8s_versions of
    release.yml rather than set anywhere. A minor that is no key there leaves
    k8s_version empty, and everything downstream would be building a cluster of
    no particular version: kubeadm asked for nothing, packages looked for under
    a bundle directory that does not exist. Saying which minors the release
    holds answers all of it at once.

    An upgrade keeps the vars.yml of the user, so this is also what a cluster
    sitting below the window of a new release runs into. That cluster reaches
    the bottom of the window on the release it is already on, and is upgraded
    after
    """
    lo_hostvars = hostvars["localhost"]
    k8s_minor_version = lo_hostvars.get("k8s_minor_version")
    k8s_versions = lo_hostvars.get("ki_release_k8s_versions")
    # Nothing to say without the release metadata, which is read from the
    # installer directory of the control node and not from any of this
    if not k8s_versions:
        return

    carried = ", ".join(sorted(k8s_versions, reverse=True))
    release_version = lo_hostvars.get("ki_release_version")

    if k8s_minor_version is None:
        hostvars_errors.append(HostvarsError(
            "localhost",
            ("k8s_minor_version",),
            str(k8s_minor_version),
            f"Variable[\"k8s_minor_version\"] of vars.yml is not set, so nothing says which"
            f" kubernetes minor this cluster runs. Release[\"{release_version}\"] carries"
            f" {carried}. A cluster that already exists takes the one it is running, which"
            f" \"kubectl version\" prints"))
        return

    if k8s_minor_version in k8s_versions:
        # Carried but not described. The release author left a field out, and
        # every one of them is something a node is built or configured with
        entry = k8s_versions[k8s_minor_version] or {}
        missing = [f for f in ("kubernetes", "pause") if not entry.get(f)]
        if missing:
            hostvars_errors.append(HostvarsError(
                "localhost",
                ("k8s_minor_version",),
                str(k8s_minor_version),
                f"Release[\"{release_version}\"] carries kubernetes[\"{k8s_minor_version}\"] but says"
                f" nothing about its {' and '.join(missing)}. Every field of an entry of"
                f" k8s_versions in release.yml is something a node is built with, so the"
                f" release is incomplete rather than the cluster misconfigured"))
        return

    error = HostvarsError(
        "localhost",
        ("k8s_minor_version",),
        str(k8s_minor_version),
        f"Release[\"{release_version}\"] does not carry"
        f" kubernetes[\"{k8s_minor_version}\"]. It carries {carried}."
        f" A cluster below that window is raised to the lowest minor of it on the"
        f" release it is already on, and upgraded to this one after")
    hostvars_errors.append(error)

def validate_kubelet_reservations(hostvars_errors: List[HostvarsError], hostvars):
    """Validates the values calculated by create-kubelet-reservations.py.

    A wrong value here makes kubelet fail to start, which is hard to diagnose
    afterwards, so it is caught before kubeadm is run
    """
    broken_node_ihs = get_broken_node_ihs(hostvars)

    for ih in hostvars.keys():
        if ih == "localhost":
            continue

        if ih in broken_node_ihs:
            continue

        if "kubelet_reservations" not in hostvars[ih]:
            error = HostvarsError(ih,
                                  ("kubelet_reservations",),
                                  "None",
                                  "Variable[\"kubelet_reservations\"] not set. it must be gathered by gather-facts")
            hostvars_errors.append(error)
            continue

        try:
            KubeletReservationsModel.model_validate(hostvars[ih]["kubelet_reservations"])
        except ValidationError as e:
            for error in e.errors():
                hostvars_errors.append(build_hostvars_error(ih, error))


def print_hostvars_errors(errors: List[HostvarsError]):
    for idx, error in enumerate(errors):
        print(f"Error {idx + 1}:", file=sys.stderr)
        print(f"  ih: {error.ih}", file=sys.stderr)
        location_str = " / ".join(map(lambda e: str(e), error.location))
        print(f"  location: {location_str}", file=sys.stderr)
        print(f"  input: {error.input}", file=sys.stderr)
        print(f"  msg: {error.msg}", file=sys.stderr)


def build_hostvars_error(ih, error) -> HostvarsError:
    return HostvarsError(ih, error['loc'], error['input'], error['msg'])


class VarsModel(BaseModel):
    @field_validator(
        "ki_var_root_path",
        "docker_root_path")
    @classmethod
    def must_be_absolute(cls, path: Path) -> Path:
        if not path.is_absolute():
            raise ValueError("path must be absolute")
        return path

    @field_validator("ephemeral_storage_device")
    @classmethod
    def must_be_absolute_when_set(cls, path: Optional[Path]) -> Optional[Path]:
        if path is not None and not path.is_absolute():
            raise ValueError("path must be absolute")
        return path

    model_config = ConfigDict(regex_engine='python-re')

    ki_var_root_path: Path
    docker_root_path: Path

    # None means the node keeps its ephemeral storage on the root filesystem
    ephemeral_storage_device: Optional[Path] = None

    internal_network_subnets: list[IPv4Network]

    internal_network_extra_zone: Optional[
        Annotated[str, StringConstraints(pattern=FQDN_PATTERN)]] = None
    internal_network_extra_zone_a_records: Optional[List[ARecordModel]] = None

    ki_cp_ha_mode: bool
    ki_cp_ha_mode_vip: Optional[IPv4Address] = None
    ki_cp_dns_dnssec_validation: bool
    ki_cp_dns_server_upstream_servers: List[IPv4Address]
    ki_cp_ntp_server_upstream_servers: List[
        Annotated[
            Union[
                IPv4Address,
                Annotated[str, StringConstraints(pattern=FQDN_PATTERN)]
            ],
            Field(union_mode='left_to_right')
        ]
    ]

    # Optional to the model and required all the same. An upgrade keeps the
    # vars.yml of the user, so the release that adds this variable meets clusters
    # whose file has no line for it, and "Field required" is not an instruction.
    # validate_k8s_minor_version says what to write instead
    k8s_minor_version: Optional[
        Annotated[str, StringConstraints(pattern=K8S_MINOR_VERSION_PATTERN)]] = None
    k8s_certificate_validity_period: Annotated[str, StringConstraints(pattern=VALIDITY_PERIOD_PATTERN)]

    # Explicit overrides. None means the value is calculated from the resources
    # of the node by create-kubelet-reservations.py
    kubelet_system_reserved_cpu: Optional[
        Annotated[str, StringConstraints(pattern=CPU_QUANTITY_PATTERN)]] = None
    kubelet_system_reserved_memory: Optional[
        Annotated[str, StringConstraints(pattern=STORAGE_SIZE_PATTERN)]] = None
    kubelet_system_reserved_ephemeral_storage: Optional[
        Annotated[str, StringConstraints(pattern=STORAGE_SIZE_PATTERN)]] = None
    kubelet_system_reserved_pid: Optional[PositiveInt] = None
    kubelet_kube_reserved_cpu: Optional[
        Annotated[str, StringConstraints(pattern=CPU_QUANTITY_PATTERN)]] = None
    kubelet_kube_reserved_memory: Optional[
        Annotated[str, StringConstraints(pattern=STORAGE_SIZE_PATTERN)]] = None
    kubelet_kube_reserved_ephemeral_storage: Optional[
        Annotated[str, StringConstraints(pattern=STORAGE_SIZE_PATTERN)]] = None
    kubelet_kube_reserved_pid: Optional[PositiveInt] = None
    kubelet_eviction_hard_memory_available: Optional[
        Annotated[str, StringConstraints(pattern=EVICTION_THRESHOLD_PATTERN)]] = None
    kubelet_eviction_hard_nodefs_available: Optional[
        Annotated[str, StringConstraints(pattern=EVICTION_THRESHOLD_PATTERN)]] = None
    kubelet_eviction_hard_imagefs_available: Optional[
        Annotated[str, StringConstraints(pattern=EVICTION_THRESHOLD_PATTERN)]] = None
    kubelet_eviction_hard_nodefs_inodes_free: Annotated[
        str, StringConstraints(pattern=EVICTION_THRESHOLD_PATTERN)]

    kubelet_auto_memory_available_min: Annotated[str, StringConstraints(pattern=STORAGE_SIZE_PATTERN)]
    kubelet_auto_memory_available_max: Annotated[str, StringConstraints(pattern=STORAGE_SIZE_PATTERN)]
    kubelet_auto_nodefs_available_min: Annotated[str, StringConstraints(pattern=STORAGE_SIZE_PATTERN)]
    kubelet_auto_nodefs_available_max: Annotated[str, StringConstraints(pattern=STORAGE_SIZE_PATTERN)]
    kubelet_auto_ephemeral_storage_min: Annotated[str, StringConstraints(pattern=STORAGE_SIZE_PATTERN)]
    kubelet_auto_ephemeral_storage_max: Annotated[str, StringConstraints(pattern=STORAGE_SIZE_PATTERN)]

    kubelet_ki_cp_extra_cpu: Annotated[str, StringConstraints(pattern=CPU_QUANTITY_PATTERN)]
    kubelet_ki_cp_extra_memory: Annotated[str, StringConstraints(pattern=STORAGE_SIZE_PATTERN)]


class ConstantVarsModel(BaseModel):
    @field_validator(
        "ansible_python_interpreter",
        "ki_opt_root_path",
        "ki_opt_scripts_path",
        "ki_opt_bundle_path",
        "ki_opt_venv_path",
        "ki_tmp_root_path",
        "ki_tmp_localhost_vars_path",
        "ki_tmp_vars_path",
        "ki_tmp_pki_path",
        "ki_tmp_ki_ca_crt_path",
        "ki_tmp_join_credentials_path",
        "ki_etc_root_path",
        "ki_etc_pki_path",
        "ki_etc_services_path",
        "ki_etc_kubeadm_path")
    @classmethod
    def must_be_absolute(cls, path: Path) -> Path:
        if not path.is_absolute():
            raise ValueError("path must be absolute")
        return path

    model_config = ConfigDict(regex_engine='python-re')

    ansible_python_interpreter: Path
    ansible_port: int = Field(ge=0, le=65535)
    ansible_ssh_user: Annotated[str, StringConstraints(pattern=r"^[a-z_]([a-z0-9_-]{0,31}|[a-z0-9_-]{0,30}\$)$")]

    ki_opt_root_path: Path
    ki_opt_scripts_path: Path
    ki_opt_bundle_path: Path
    ki_opt_venv_path: Path

    ki_tmp_root_path: Path
    ki_tmp_localhost_vars_path: Path
    ki_tmp_vars_path: Path
    ki_tmp_pki_path: Path
    ki_tmp_ki_ca_crt_path: Path
    ki_tmp_join_credentials_path: Path

    ki_etc_root_path: Path
    ki_etc_pki_path: Path
    ki_etc_services_path: Path
    ki_etc_kubeadm_path: Path

    internal_network_ip: IPv4Address | None
    internal_network_zone: Annotated[str, StringConstraints(pattern=FQDN_PATTERN)]
    internal_network_ki_cp_dns_name: Annotated[str, StringConstraints(pattern=FQDN_PATTERN)]

    ki_cp_k8s_cp_lb_port: int = Field(ge=0, le=65535)
    ki_cp_k8s_cp_lb_stats_port: int = Field(ge=0, le=65535)
    ki_cp_k8s_registry_port: int = Field(ge=0, le=65535)

    k8s_version: str
    k8s_apiserver_port: int = Field(ge=0, le=65535)
    k8s_service_subnet: IPv4Network
    k8s_pod_subnet: IPv4Network
    k8s_ca_certificate_validity_period: Annotated[str, StringConstraints(pattern=VALIDITY_PERIOD_PATTERN)]
    k8s_cp: bool

    nvidia_gpu: bool

    target_node: str | None
    target_node_op: str | None


class HostvarsError:
    def __init__(self, ih: str, location: tuple, _input: Any, msg: str):
        self.ih = ih
        self.location = location
        self.input = _input
        self.msg = msg


class ARecordModel(BaseModel):
    name: str
    ip: IPv4Address


class KubeletReservedModel(BaseModel):
    model_config = ConfigDict(regex_engine='python-re', populate_by_name=True)

    cpu: Annotated[str, StringConstraints(pattern=CPU_QUANTITY_PATTERN)]
    memory: Annotated[str, StringConstraints(pattern=STORAGE_SIZE_PATTERN)]
    ephemeral_storage: Annotated[
        str, StringConstraints(pattern=STORAGE_SIZE_PATTERN)] = Field(alias="ephemeral-storage")
    pid: PositiveInt


class KubeletEvictionHardModel(BaseModel):
    model_config = ConfigDict(regex_engine='python-re', populate_by_name=True)

    memory_available: Annotated[
        str, StringConstraints(pattern=EVICTION_THRESHOLD_PATTERN)] = Field(alias="memory.available")
    nodefs_available: Annotated[
        str, StringConstraints(pattern=EVICTION_THRESHOLD_PATTERN)] = Field(alias="nodefs.available")
    imagefs_available: Annotated[
        str, StringConstraints(pattern=EVICTION_THRESHOLD_PATTERN)] = Field(alias="imagefs.available")
    nodefs_inodes_free: Annotated[
        str, StringConstraints(pattern=EVICTION_THRESHOLD_PATTERN)] = Field(alias="nodefs.inodesFree")


class KubeletReservationsModel(BaseModel):
    model_config = ConfigDict(regex_engine='python-re')

    system_reserved: KubeletReservedModel
    kube_reserved: KubeletReservedModel
    eviction_hard: KubeletEvictionHardModel


main()
