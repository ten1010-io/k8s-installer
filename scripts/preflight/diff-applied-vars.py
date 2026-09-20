#!/usr/bin/env python3
from __future__ import annotations

import sys
from typing import Any, Dict, List

import yaml

# The classes whose changes this refuses to apply, and why. Both are decided
# before anything is applied, so a run that is going to refuse does nothing at
# all rather than leaving half of the change in place
BLOCKING_CLASSES = {
    "immutable":
        "can not be changed on a cluster that already exists."
        " Put the old value back, or build the cluster again with the new one",
    "node_rebuild":
        "is settled while a node is provisioned and can not be reached afterwards."
        " Take each node below out with remove-node.yml and add it back with"
        " add-node.yml, one at a time",
}


def main():
    hostvars = yaml.safe_load(sys.stdin)
    var_classes = hostvars["localhost"]["ki_var_classes"]
    class_of = {name: cls for cls, names in var_classes.items() for name in names}

    changes: Dict[str, List[dict]] = {cls: [] for cls in var_classes}
    baseline_ihs: List[str] = []

    for ih in sorted(hostvars):
        if ih == "localhost":
            continue

        node_hostvars = hostvars[ih]
        applied = node_hostvars.get("ki_applied_vars")
        # A node nothing has recorded yet, which is every node of a cluster built
        # before there was a record. Nothing can be said about what changed, so
        # the run takes what the node has now as the starting point and says so
        if not applied:
            baseline_ihs.append(ih)
            continue

        for name, cls in class_of.items():
            if name not in node_hostvars:
                continue

            current = node_hostvars[name]
            if name in applied and applied[name] == current:
                continue

            changes[cls].append({
                "ih": ih,
                "name": name,
                "applied": applied.get(name),
                "current": current,
            })

    blocking = [(cls, changes[cls]) for cls in BLOCKING_CLASSES if changes[cls]]
    if blocking:
        print_blocking(blocking)
        exit(1)

    yaml.safe_dump({
        "changes": changes,
        "baseline_ihs": baseline_ihs,
        # Built here rather than in the playbook. Reporting a change is walking
        # two levels of a mapping of lists, which jinja does badly and reads
        # worse, and the playbook only ever wants to print it
        "summary": build_summary(changes),
    }, sys.stdout, default_flow_style=False)
    exit(0)


def build_summary(changes: Dict[str, List[dict]]) -> List[str]:
    return [
        f"[{cls}] node[\"{change['ih']}\"] variable[\"{change['name']}\"]"
        f" {fmt(change['applied'])} -> {fmt(change['current'])}"
        for cls in sorted(changes)
        for change in changes[cls]
    ]


def print_blocking(blocking: List[tuple]):
    print("[ERROR] Some of the variables that changed can not be applied to this cluster."
          " Nothing was applied", file=sys.stderr)
    for cls, cls_changes in blocking:
        print(f"\n  A variable of class[\"{cls}\"] {BLOCKING_CLASSES[cls]}:", file=sys.stderr)
        for change in cls_changes:
            print(f"    node[\"{change['ih']}\"] variable[\"{change['name']}\"]"
                  f" {fmt(change['applied'])} -> {fmt(change['current'])}", file=sys.stderr)


def fmt(value: Any) -> str:
    return yaml.safe_dump(value, default_flow_style=True).strip().rstrip("...").strip()


main()
