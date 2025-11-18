#!/usr/bin/env python3
from __future__ import annotations

import ipaddress
import sys
from ipaddress import IPv4Network, IPv4Address
from pathlib import Path
from typing import List, Any, Optional, Annotated, Union

import yaml
from pydantic import BaseModel, ValidationError, StringConstraints, ConfigDict, field_validator, Field, PositiveInt

FQDN_PATTERN = r"^((?!-)[A-Za-z0-9-]{1,63}(?<!-)\.)+[A-Za-z]{2,}$"
SUB_DOMAIN_PATTERN = r"^[a-z0-9]([a-z0-9\-.]*[a-z0-9])?$"
VALIDITY_PERIOD_PATTERN = r"^[0-9]+h$"
K8S_OBJ_NAME_PATTERN = SUB_DOMAIN_PATTERN
STORAGE_SIZE_PATTERN = r"^[0-9]+[EPTGMK]i$"


def main():
    hostvars = yaml.safe_load(sys.stdin)
    hostvars_errors: List[HostvarsError] = []

    check_type(hostvars_errors, hostvars)
    validate_ki_cp_ha_mode_vip(hostvars_errors, hostvars)
    validate_internal_network_subnets(hostvars_errors, hostvars)
    validate_k8s_ingress_classes(hostvars_errors, hostvars)
    validate_aipub_ha_mode_storage_class(hostvars_errors, hostvars)
    validate_aipub_cp_nodes(hostvars_errors, hostvars)

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

    ki_cp_nodes = lo_hostvars["groups"]["ki_cp_node"]
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


def validate_k8s_ingress_classes(hostvars_errors: List[HostvarsError], hostvars):
    lo_hostvars = hostvars["localhost"]
    k8s_ingress_classes = lo_hostvars["k8s_ingress_classes"]

    k8s_nodes: List[str] = lo_hostvars["groups"]["k8s_node"]

    for idx, item in enumerate(k8s_ingress_classes):
        if not set(item["controller_nodes"]).issubset(k8s_nodes):
            error = HostvarsError("localhost",
                                  ("k8s_ingress_classes", str(idx), "controller_nodes"),
                                  str(item["controller_nodes"]),
                                  "Value for variable[\"controller_nodes\"] must be nodes which belong to k8s_node group")
            hostvars_errors.append(error)
        if item["ha_mode"] and item["ha_mode_vip"] is None:
            error = HostvarsError("localhost",
                                  ("k8s_ingress_classes", str(idx), "ha_mode_vip"),
                                  str(item["ha_mode_vip"]),
                                  "Variable[\"ha_mode_vip\"] must be set when value for variable[\"ha_mode\"] is true")
            hostvars_errors.append(error)


def validate_aipub_ha_mode_storage_class(hostvars_errors: List[HostvarsError], hostvars):
    lo_hostvars = hostvars["localhost"]
    aipub_ha_mode: bool = lo_hostvars["aipub_ha_mode"]
    aipub_ha_mode_storage_class = lo_hostvars["aipub_ha_mode_storage_class"]

    if aipub_ha_mode and aipub_ha_mode_storage_class is None:
        error = HostvarsError("localhost",
                              ("aipub_ha_mode_storage_class",),
                              str(aipub_ha_mode_storage_class),
                              "Variable[\"aipub_ha_mode_storage_class\"] must be set when value for variable[\"aipub_ha_mode\"] is true")
        hostvars_errors.append(error)


def validate_aipub_cp_nodes(hostvars_errors: List[HostvarsError], hostvars):
    lo_hostvars = hostvars["localhost"]
    aipub_cp_nodes = lo_hostvars["aipub_cp_nodes"]

    k8s_nodes: List[str] = lo_hostvars["groups"]["k8s_node"]

    if not set(aipub_cp_nodes).issubset(k8s_nodes):
        error = HostvarsError("localhost",
                              ("aipub_cp_nodes",),
                              str(aipub_cp_nodes),
                              "Must belong to k8s_node group")
        hostvars_errors.append(error)


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
        "containerd_root_path",
        "docker_root_path")
    @classmethod
    def must_be_absolute(cls, path: Path) -> Path:
        if not path.is_absolute():
            raise ValueError("path must be absolute")
        return path

    model_config = ConfigDict(regex_engine='python-re')

    ki_var_root_path: Path
    containerd_root_path: Path
    docker_root_path: Path

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

    k8s_certificate_validity_period: Annotated[str, StringConstraints(pattern=VALIDITY_PERIOD_PATTERN)]
    k8s_ingress_classes: List[K8sIngressClassModel]

    aipub_ingress_zone: Annotated[str, StringConstraints(pattern=FQDN_PATTERN)]
    aipub_ha_mode: bool
    aipub_ha_mode_storage_class: Optional[Annotated[str, StringConstraints(pattern=K8S_OBJ_NAME_PATTERN)]] = None
    aipub_cp_nodes: List[Annotated[str, StringConstraints(pattern=K8S_OBJ_NAME_PATTERN)]]

    aipub_keycloak_ingress_class: Annotated[str, StringConstraints(pattern=K8S_OBJ_NAME_PATTERN)]
    aipub_keycloak_ingress_subdomain: Annotated[str, StringConstraints(pattern=SUB_DOMAIN_PATTERN)]
    aipub_keycloak_replica_count: PositiveInt
    aipub_keycloak_postgresql_storage_size: Annotated[str, StringConstraints(pattern=STORAGE_SIZE_PATTERN)]

    aipub_harbor_ingress_class: Annotated[str, StringConstraints(pattern=K8S_OBJ_NAME_PATTERN)]
    aipub_harbor_ingress_subdomain: Annotated[str, StringConstraints(pattern=SUB_DOMAIN_PATTERN)]
    aipub_harbor_replica_count: PositiveInt
    aipub_harbor_registry_storage_size: Annotated[str, StringConstraints(pattern=STORAGE_SIZE_PATTERN)]
    aipub_harbor_postgresql_storage_size: Annotated[str, StringConstraints(pattern=STORAGE_SIZE_PATTERN)]
    aipub_harbor_redis_storage_size: Annotated[str, StringConstraints(pattern=STORAGE_SIZE_PATTERN)]


class ConstantVarsModel(BaseModel):
    @field_validator(
        "ansible_python_interpreter",
        "ki_env_path",
        "ki_env_scripts_path",
        "ki_env_bin_path",
        "ki_env_ki_venv_path",
        "ki_tmp_root_path",
        "ki_tmp_localhost_vars_path",
        "ki_tmp_vars_path",
        "ki_tmp_pki_path",
        "ki_tmp_ki_ca_crt_path",
        "ki_tmp_join_credentials_path",
        "ki_tmp_charts_path",
        "ki_etc_root_path",
        "ki_etc_pki_path",
        "ki_etc_services_path",
        "ki_etc_kubeadm_path",
        "ki_etc_charts_path",
        "ki_var_aipub_local_pv_path")
    @classmethod
    def must_be_absolute(cls, path: Path) -> Path:
        if not path.is_absolute():
            raise ValueError("path must be absolute")
        return path

    model_config = ConfigDict(regex_engine='python-re')

    ansible_python_interpreter: Path
    ansible_port: int = Field(ge=0, le=65535)
    ansible_ssh_user: Annotated[str, StringConstraints(pattern=r"^[a-z_]([a-z0-9_-]{0,31}|[a-z0-9_-]{0,30}\$)$")]

    ki_env_path: Path
    ki_env_scripts_path: Path
    ki_env_bin_path: Path
    ki_env_ki_venv_path: Path

    ki_tmp_root_path: Path
    ki_tmp_localhost_vars_path: Path
    ki_tmp_vars_path: Path
    ki_tmp_pki_path: Path
    ki_tmp_ki_ca_crt_path: Path
    ki_tmp_join_credentials_path: Path
    ki_tmp_charts_path: Path

    ki_etc_root_path: Path
    ki_etc_pki_path: Path
    ki_etc_services_path: Path
    ki_etc_kubeadm_path: Path
    ki_etc_charts_path: Path

    ki_var_aipub_local_pv_path: Path

    internal_network_ip: IPv4Address | None
    internal_network_zone: Annotated[str, StringConstraints(pattern=FQDN_PATTERN)]
    internal_network_ki_cp_dns_name: Annotated[str, StringConstraints(pattern=FQDN_PATTERN)]

    ki_cp_k8s_cp_lb_port: int = Field(ge=0, le=65535)
    ki_cp_k8s_cp_lb_stats_port: int = Field(ge=0, le=65535)
    ki_cp_k8s_registry_port: int = Field(ge=0, le=65535)
    ki_cp_aipub_registry_port: int = Field(ge=0, le=65535)

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


class K8sIngressClassModel(BaseModel):
    name: Annotated[str, StringConstraints(pattern=K8S_OBJ_NAME_PATTERN)]
    controller_nodes: List[Annotated[str, StringConstraints(pattern=K8S_OBJ_NAME_PATTERN)]]
    ha_mode: bool
    ha_mode_vip: Optional[IPv4Address] = None
    http_hostport: int = Field(ge=0, le=65535)
    https_hostport: int = Field(ge=0, le=65535)


main()
