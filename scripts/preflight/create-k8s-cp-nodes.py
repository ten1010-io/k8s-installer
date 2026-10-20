#!/usr/bin/env python3
import sys

import yaml


def die(msg):
    print(msg, file=sys.stderr)
    exit(1)


hostvars = yaml.safe_load(sys.stdin)

# Two lists, because the question has two answers once a node is broken.
#
# k8s_cp_nodes is the control plane nodes a play may act on or talk to: the
# apiserver load balancer backends, the node every playbook delegates its
# kubectl to, the members a restore brings back. A node of the broken_node
# group is left out of every play, and in this list it would be a delegation
# to a machine that does not answer and a backend nobody can reach, so it is
# left out here, at the one place the list is made, rather than subtracted by
# each reader.
#
# k8s_cp_nodes_in_inventory is what the inventory declares, broken or not. It
# is for the readers that ask what the cluster is supposed to contain rather
# than whom to talk to: the check that every control plane node of the cluster
# is one the inventory knows, which a broken node still is, and the removal
# that has to know whether the node being taken out was a control plane node
# so that its etcd member goes with it
broken_ihs = hostvars.get("localhost", {}).get("groups", {}).get("broken_node", [])

declared = []
for ih in hostvars.keys():
    if ih == "localhost":
        continue

    if "k8s_cp" in hostvars[ih] and hostvars[ih]['k8s_cp']:
        declared.append(ih)

result = {
    "k8s_cp_nodes": [ih for ih in declared if ih not in broken_ihs],
    "k8s_cp_nodes_in_inventory": declared,
}
yaml.dump(result, sys.stdout, default_flow_style=False)
