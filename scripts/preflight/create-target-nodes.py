#!/usr/bin/env python3
import sys

import yaml


def die(msg):
    print(msg, file=sys.stderr)
    exit(1)


# The name a node of this hostname carries in the cluster, which is what
# convert_into_knn of join-k8s-cluster.sh and init-k8s-cluster.sh registers it
# under: lower case, with dashes where the hostname has underscores. Compared
# as it is, a node called Node_4 that joined as node-4 would never be found in
# the cluster and every run would take it for a node to add
def convert_into_knn(hostname):
    return hostname.lower().replace("_", "-")


hostvars = yaml.safe_load(sys.stdin)

# The nodes an add-node run that named no node is to add: every node of the
# inventory that the cluster does not hold yet, in inventory order.
#
# Two kinds of membership, because the inventory declares two kinds of node. A
# k8s node is in the cluster when the apiserver lists it, which is the same
# answer check-node-state.sh holds the inventory against later in the run. A
# node that is only a ki cp node is listed by nothing, so what says it was
# built is the release record every node of a cluster carries, which
# reset-cluster-record.yml takes away when the node is removed.
#
# What the apiserver lists are node names, and the inventory names are not, so
# derive-target-nodes.yml asks each node its hostname first and this compares
# the node name that hostname joins under. A broken node is left out: it is in
# no play, and adding it back is what remove-broken-node.yml and a rebuild are
# for
localhost = hostvars.get("localhost", {})
groups = localhost.get("groups", {})
broken_ihs = groups.get("broken_node", [])
k8s_ihs = groups.get("k8s_node", [])
ki_cp_ihs = groups.get("ki_cp_node", [])

cluster_node_names = None
for ih in k8s_ihs:
    if ih in broken_ihs:
        continue
    names = hostvars.get(ih, {}).get("ki_cluster_node_names")
    if names is not None:
        cluster_node_names = names
        break

if cluster_node_names is None:
    die("[ERROR] No control plane node of the inventory could list the nodes of the cluster")

target_nodes = []
for ih in groups.get("all", []):
    if ih == "localhost" or ih in broken_ihs:
        continue

    node = hostvars.get(ih, {})
    if ih in k8s_ihs:
        hostname = node.get("hostname")
        if not hostname:
            die(f"[ERROR] Node[\"{ih}\"] reported no hostname")
        if convert_into_knn(hostname) not in cluster_node_names:
            target_nodes.append(ih)
    elif ih in ki_cp_ihs:
        if not node.get("ki_holds_applied_release", False):
            target_nodes.append(ih)

yaml.dump({"target_nodes": target_nodes}, sys.stdout, default_flow_style=False)
