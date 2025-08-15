#!/usr/bin/env python3
import sys

import yaml


def die(msg):
    print(msg, file=sys.stderr)
    exit(1)


hostvars = yaml.safe_load(sys.stdin)

ih_to_hostname_dict = {}
hostname_to_ih_dict = {}
for ih in hostvars.keys():
    if ih == "localhost":
        continue

    if "hostname" in hostvars[ih]:
        ih_to_hostname_dict[ih] = hostvars[ih]["hostname"]
        hostname_to_ih_dict[hostvars[ih]["hostname"]] = ih

result = {"ih_to_hostname_dict": ih_to_hostname_dict, "hostname_to_ih_dict": hostname_to_ih_dict}
yaml.dump(result, sys.stdout, default_flow_style=False)
