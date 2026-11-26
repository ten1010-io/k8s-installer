#!/usr/bin/env python3
"""Decides which nodes are given a new iscsi initiator name, and refuses the
nodes that share one and can not be given another.

A storage system tells its initiators apart by their name and by nothing else.
Two nodes holding one name are one node to it: what it grants the name it
grants both, and a session one of them makes can take the place of the other's.
Nothing on either node says so, since each of them is, to itself, correctly
configured. The usual way to get there is machines cloned from an image that
had the initiator installed, which all wake up holding the name the image was
given.

Reads the hostvars of the run on stdin, where every node carries what
get-iscsi-initiator-state.sh said of it, and looks only at the nodes
iscsi_initiator_enabled is on for: the name of a node that is no initiator is
a file nothing reads.

Of the nodes that share a name, which one moves is decided by what a new name
would cost each of them:

  a node this installer has not made an initiator yet, holding no session
      costs nothing. Nothing has ever been granted the name it holds, so it is
      given a new one as it is set up - a node being built is always this

  a node that is an initiator of this installer already, or holds a session
      is known to a storage system by its name. Renaming it takes away what
      that name was granted, under volumes that may be in use, so it is not
      renamed here

One node of a group keeps the name, the others that can move are moved, and a
group with more than one node that can not move is refused with their names:
that is for a person to settle, by logging one of them out and giving it a name
by hand. Only the nodes this run is setting up are renamed, since the others
are not being touched by it
"""
from __future__ import annotations

import sys
from typing import Dict, List

import yaml


def main():
    hostvars = yaml.safe_load(sys.stdin)
    target_nodes = hostvars["localhost"].get("target_nodes")
    broken = set(hostvars["localhost"].get("ki_broken_nodes") or [])

    by_name: Dict[str, List[str]] = {}
    states = {}
    for ih in sorted(hostvars):
        if ih == "localhost" or ih in broken:
            continue

        node_hostvars = hostvars[ih]
        if node_hostvars.get("iscsi_initiator_enabled") is not True:
            continue

        # A node that was not asked, which is one the play could not reach. It
        # is left out rather than read as a node with no name
        state = node_hostvars.get("ki_iscsi_initiator_state")
        if not isinstance(state, dict):
            continue

        states[ih] = state
        name = state.get("name") or ""
        # No name yet is a name setup-iscsi-initiator.sh makes, and two nodes
        # with none do not share anything
        if name:
            by_name.setdefault(name, []).append(ih)

    new_name_ihs: List[str] = []
    refused: List[tuple] = []
    for name, ihs in sorted(by_name.items()):
        if len(ihs) < 2:
            continue

        fixed = [ih for ih in ihs if not can_be_renamed(states[ih])]
        if len(fixed) > 1:
            refused.append((name, fixed))
            continue

        keeper = fixed[0] if fixed else keeper_of(ihs, target_nodes)
        new_name_ihs += [ih for ih in ihs if ih != keeper and is_target(ih, target_nodes)]

    if refused:
        print_refused(refused)
        exit(1)

    yaml.safe_dump({"new_name_ihs": sorted(new_name_ihs)}, sys.stdout, default_flow_style=False)
    exit(0)


def can_be_renamed(state: dict) -> bool:
    return state.get("managed") is not True and int(state.get("sessions") or 0) == 0


def is_target(ih: str, target_nodes) -> bool:
    """Whether this run sets the node up. A playbook pointed at no node sets up
    every one of them, which is what a null target_nodes says."""
    return target_nodes is None or ih in target_nodes


def keeper_of(ihs: List[str], target_nodes) -> str:
    """The node of a group that keeps the name when every one of them could move.

    One the run is not setting up, when there is one: it is not being touched,
    so it could not be renamed now anyway, and keeping its name is what leaves
    the group with no two alike once the others have moved. Otherwise the first
    by name, so that the same inventory gives the same answer every time
    """
    standing = [ih for ih in ihs if not is_target(ih, target_nodes)]

    return sorted(standing or ihs)[0]


def print_refused(refused: List[tuple]):
    print("[ERROR] Some nodes share an iscsi initiator name and can not be given another",
          file=sys.stderr)
    for name, ihs in refused:
        print(f"\n  initiatorName[\"{name}\"] is held by node[{', '.join(ihs)}]", file=sys.stderr)
    print("\n  Each of them is already an iscsi initiator of this installer or holds a session, so a"
          " storage system knows it by that name and renaming it here would take its volumes away."
          " Take the volumes off all but one of the nodes above, give each of the others a name of"
          " its own in /etc/iscsi/initiatorname.iscsi (iscsi-iname prints one) and restart iscsid"
          " there", file=sys.stderr)


main()
