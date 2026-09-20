#!/usr/bin/env python3
import sys

import yaml


def die(msg):
    print(msg, file=sys.stderr)
    exit(1)


hostvars = yaml.safe_load(sys.stdin)

# A node of the broken_node group is left out of every play, so it never reported
# its interfaces. It is left out here rather than reported as invalid, and every
# lookup of this dictionary subtracts the node being removed before it reaches
# for an entry, so nothing asks for the one that is missing
broken_ihs = hostvars.get("localhost", {}).get("groups", {}).get("broken_node", [])

hosts = {}
for ih in hostvars.keys():
    if ih == "localhost":
        continue

    if ih in broken_ihs:
        continue

    if "internal_network_interfaces" not in hostvars[ih]:
        die(f"[ERROR] Variable[\"hostvars[\"{ih}\"]\"] invalid. it must has key [\"internal_network_interfaces\"]")

    hosts[ih] = {}
    hosts[ih]["interfaces"] = hostvars[ih]["internal_network_interfaces"]

result = {"internal_network_hosts": hosts}
yaml.dump(result, sys.stdout, default_flow_style=False)
