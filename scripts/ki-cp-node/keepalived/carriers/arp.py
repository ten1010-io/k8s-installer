"""The carrier of a network that listens to the node: gratuitous arp.

keepalived raises the address on an interface and announces it itself, and a
switch believes the announcement. So there is nothing to carry and nothing a
site has to prepare, and the one question left is the one the metrics ask -
whether the address is on an interface of this node, which is what
ki_cp_vip_held already reports. No unit is put on a node for this carrier,
since a carry that does nothing has nothing to be woken for; what is here is
so that the callers need not know which carrier is the one that does nothing.
"""
from __future__ import annotations

import argparse
import subprocess


def carry(args: argparse.Namespace) -> None:
    return None


def probe(args: argparse.Namespace) -> bool:
    output = subprocess.run(["ip", "-o", "addr", "show"], capture_output=True, text=True, check=True).stdout
    for line in output.splitlines():
        fields = line.split()
        if len(fields) >= 4 and fields[3].split("/")[0] == args.vip:
            return True
    return False


def preflight(args: argparse.Namespace) -> list[str]:
    return []
