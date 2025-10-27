#!/usr/bin/env python3
from __future__ import annotations

import sys
from ipaddress import IPv4Network, IPv4Address
from pathlib import Path
from typing import List, Any, Optional, Annotated, Union

import yaml
from pydantic import BaseModel, ValidationError, StringConstraints, ConfigDict, field_validator, Field


def main():
    hostvars = yaml.safe_load(sys.stdin)
    hostvars_errors: List[HostvarsError] = []

    errors = validate_type(hostvars)
    hostvars_errors.extend(errors)

    errors = validate(hostvars)
    hostvars_errors.extend(errors)

    if len(hostvars_errors) > 0:
        print("[ERROR] Invalid hostvars", file=sys.stderr)
        print_hostvars_errors(hostvars_errors)
        exit(1)

    exit(0)


def validate_type(hostvars):
    hostvars_errors: List[HostvarsError] = []

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

    return hostvars_errors


def validate(hostvars):
    hostvars_errors: List[HostvarsError] = []

    return hostvars_errors


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
        Annotated[str, StringConstraints(pattern=r"^((?!-)[A-Za-z0-9-]{1,63}(?<!-)\.)+[A-Za-z]{2,}$")]] = None
    internal_network_extra_zone_a_records: Optional[List[ARecordModel]] = None
    ki_cp_ha_mode: bool
    ki_cp_ha_mode_vip: IPv4Address
    ki_cp_dns_server_upstream_servers: List[IPv4Address]
    ki_cp_ntp_server_upstream_servers: List[
        Annotated[
            Union[
                IPv4Address,
                Annotated[str, StringConstraints(pattern=r"^((?!-)[A-Za-z0-9-]{1,63}(?<!-)\.)+[A-Za-z]{2,}$")]
            ],
            Field(union_mode='left_to_right')
        ]
    ]


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
        "ki_etc_root_path",
        "ki_etc_pki_path",
        "ki_etc_services_path",
        "ki_etc_kubeadm_path",
        "ki_etc_charts_path",
        "ki_var_services_path")
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
    ki_etc_root_path: Path
    ki_etc_pki_path: Path
    ki_etc_services_path: Path
    ki_etc_kubeadm_path: Path
    ki_etc_charts_path: Path
    ki_var_services_path: Path
    internal_network_ip: IPv4Address | None
    internal_network_zone: Annotated[
        str, StringConstraints(pattern=r'^((?!-)[A-Za-z0-9-]{1,63}(?<!-)\.)+[A-Za-z]{2,}$')]
    internal_network_ki_cp_dns_name: Annotated[
        str, StringConstraints(pattern=r'^((?!-)[A-Za-z0-9-]{1,63}(?<!-)\.)+[A-Za-z]{2,}$')]
    ki_cp_k8s_cp_lb_port: int = Field(ge=0, le=65535)
    ki_cp_k8s_cp_lb_stats_port: int = Field(ge=0, le=65535)
    ki_cp_k8s_registry_port: int = Field(ge=0, le=65535)
    k8s_version: str
    k8s_apiserver_port: int = Field(ge=0, le=65535)
    k8s_service_subnet: IPv4Network
    k8s_pod_subnet: IPv4Network
    nvidia_gpu: bool
    target_node: str | None
    target_node_op: str | None
    k8s_cp: Optional[bool] = None


class HostvarsError:
    def __init__(self, ih: str, location: tuple, _input: Any, msg: str):
        self.ih = ih
        self.location = location
        self.input = _input
        self.msg = msg


class ARecordModel(BaseModel):
    name: str
    ip: IPv4Address


main()
