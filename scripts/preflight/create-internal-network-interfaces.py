#!/usr/bin/env python3
import argparse
import ipaddress
import sys

import netifaces
import yaml


def die(msg):
    print(msg, file=sys.stderr)
    exit(1)


def get_ipv4_addresses(if_addresses):
    if netifaces.AF_INET not in if_addresses:
        return []

    return list(filter(lambda e: "addr" in e, if_addresses[netifaces.AF_INET]))


def find_sys_interfaces(cidr_str):
    cidr = ipaddress.ip_network(cidr_str)
    interfaces = []
    for interface in netifaces.interfaces():
        ipv4_addresses = get_ipv4_addresses(netifaces.ifaddresses(interface))
        for address in ipv4_addresses:
            ip = ipaddress.ip_address(address["addr"])
            if ip in cidr:
                interfaces.append({"if": interface, "ip": address["addr"]})

    return interfaces


def find_interface_by_ip(internal_network_interfaces, ip):
    for interface in internal_network_interfaces:
        if interface["ip"] == ip:
            return interface
    return None


parser = argparse.ArgumentParser()
parser.add_argument("ih")
args = parser.parse_args()

ih = args.ih
hostvars = yaml.safe_load(sys.stdin)
internal_network_ip = None

if ih not in hostvars:
    die(f"[ERROR] Variable[\"hostvars\"] invalid. it must has key [\"{ih}\"]")
if "internal_network_subnets" not in hostvars[ih]:
    die(f"[ERROR] Variable[\"hostvars[\"{ih}\"]\"] invalid. it must has key [\"internal_network_subnets\"]")
if "internal_network_ip" in hostvars[ih] and hostvars[ih]["internal_network_ip"]:
    internal_network_ip = hostvars[ih]["internal_network_ip"]

subnets = hostvars[ih]["internal_network_subnets"]
if len(subnets) < 1:
    die("[ERROR] Variable[\"hostvars[\"{ih}\"][\"internal_network_subnets\"]\"] invalid. it can not be empty")
for i, subnet in enumerate(subnets):
    try:
        ipaddress.ip_network(subnet)
    except:
        die(f"[ERROR] Variable[\"hostvars[\"{ih}\"][\"internal_network_subnets[{i}]\"]\"] invalid. it must be an IPv4 network")

found = []
for subnet in subnets:
    interfaces = find_sys_interfaces(subnet)
    found += list(map(lambda e: {
        "if": e["if"],
        "subnet": subnet,
        "ip": e["ip"]
    }, interfaces))

if internal_network_ip:
    internal_network_ip_interface = find_interface_by_ip(found, internal_network_ip)
    if internal_network_ip_interface:
        found = [internal_network_ip_interface]
    else:
        found = []

result = {"internal_network_interfaces": found}
yaml.dump(result, sys.stdout, default_flow_style=False)
