#!/usr/bin/env python3
import sys

import yaml


def die(msg):
    print(msg, file=sys.stderr)
    exit(1)


hostvars = yaml.safe_load(sys.stdin)

nodes = []
for ih in hostvars.keys():
    if ih == "localhost":
        continue

    if "k8s_cp" in hostvars[ih] and hostvars[ih]['k8s_cp']:
        nodes.append(ih)

result = {"k8s_cp_nodes": nodes}
yaml.dump(result, sys.stdout, default_flow_style=False)
