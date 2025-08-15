#!/usr/bin/env python3
import sys

import yaml


def die(msg):
    print(msg, file=sys.stderr)
    exit(1)


hostvars = yaml.safe_load(sys.stdin)

hosts = {}
for ih in hostvars.keys():
    if ih == "localhost":
        continue

    if "internal_network_interfaces" not in hostvars[ih]:
        die(f"[ERROR] Variable[\"hostvars[\"{ih}\"]\"] invalid. it must has key [\"internal_network_interfaces\"]")

    hosts[ih] = {}
    hosts[ih]["interfaces"] = hostvars[ih]["internal_network_interfaces"]

result = {"internal_network_hosts": hosts}
yaml.dump(result, sys.stdout, default_flow_style=False)
