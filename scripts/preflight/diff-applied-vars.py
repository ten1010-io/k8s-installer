#!/usr/bin/env python3
"""Works out what changed on each node since it was last built or updated.

Reads the hostvars of the run on stdin, compares every classified variable of
every node against what the node recorded in applied-vars.yml, and files each
difference under the class constant-vars.yml gives the variable. What a record
does not hold is not read as unchanged: see baseline_of
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any, Dict, List, Set

import yaml

# The classes whose changes this refuses to apply, and why. All of them are decided
# before anything is applied, so a run that is going to refuse does nothing at
# all rather than leaving half of the change in place
BLOCKING_CLASSES = {
    "immutable":
        "can not be changed on a cluster that already exists."
        " Put the old value back, or build the cluster again with the new one",
    "cluster_upgrade":
        "is applied by moving the cluster itself, which this playbook does not do."
        " Run upgrade-cluster.yml, which takes the cluster up one kubernetes minor"
        " at a time and is also what records the variable the first time,"
        " so a record that predates it reads as a change here",
    "node_rebuild":
        "is settled while a node is provisioned and can not be reached afterwards."
        " Take each node below out with remove-node.yml and add it back with"
        " add-node.yml, one at a time",
}

# What a node's record says about a variable it does not name: that the node
# never held it when the record was written. Compared against as a value, so a
# variable that went from nothing to something is a change like any other. Never
# equal to anything a node holds
UNSET = object()


def main():
    args = parse_args()
    hostvars = yaml.safe_load(sys.stdin)
    var_classes = hostvars["localhost"]["ki_var_classes"]
    class_of = {name: cls for cls, names in var_classes.items() for name in names}
    memory_reservation_vars = set(hostvars["localhost"].get("ki_kubelet_memory_reservation_vars") or [])
    fallbacks = read_fallbacks(args.constant_vars_path, class_of)

    changes: Dict[str, List[dict]] = {cls: [] for cls in var_classes}
    baseline_ihs: List[str] = []
    baseline_names: Set[str] = set()

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
            # Only control_node_ih, which is declared on localhost and held by no
            # node. Every other classified variable has a fallback, so a line taken
            # out of vars.yml or inventory.yml resolves to it rather than to
            # nothing, and is compared like any other value
            if name not in node_hostvars:
                continue

            current = node_hostvars[name]
            before, compared_with = baseline_of(name, cls, applied, fallbacks)
            if compared_with == "nothing":
                baseline_names.add(name)
                continue

            if before == current:
                continue

            change = {
                "ih": ih,
                "name": name,
                "applied": None if before is UNSET else before,
                "current": current,
                "compared_with": compared_with,
            }
            changes[class_on_node(cls, name, node_hostvars, applied, fallbacks, memory_reservation_vars)].append(change)

    blocking = [(cls, changes[cls]) for cls in BLOCKING_CLASSES if changes[cls]]
    if blocking:
        print_blocking(blocking)
        exit(1)

    yaml.safe_dump({
        "changes": changes,
        "baseline_ihs": baseline_ihs,
        "baseline_names": sorted(baseline_names),
        # Built here rather than in the playbook. Reporting a change is walking
        # two levels of a mapping of lists, which jinja does badly and reads
        # worse, and the playbook only ever wants to print it
        "summary": build_summary(changes),
    }, sys.stdout, default_flow_style=False)
    exit(0)


def parse_args():
    parser = argparse.ArgumentParser(description="Diff the variables of every node against what it recorded")
    parser.add_argument("--constant-vars-path", required=True, type=Path,
                        help="constant-vars.yml of the release, read for the fallbacks of the variables")
    return parser.parse_args()


def baseline_of(name: str, cls: str, applied: dict, fallbacks: dict):
    """What the current value of a variable is compared against, and where that
    came from: "record", "fallback", "unset" or "nothing".

    A variable the record holds is compared against what it holds. The rest are
    variables a release added after the record was written, and they are where a
    run can go wrong quietly: nothing was applied with a value, and reading that
    as "nothing changed" records whatever the inventory says now as applied,
    which on a variable set in the same run as the upgrade is a drain that never
    happened written down as done.

    So for a class this playbook applies, the comparison is against what the node
    was running with before the release gave the variable a name. That is the
    fallback constant-vars.yml declares for it, by definition: the fallback is the
    value a vars.yml written before the line existed resolves to, and a cluster
    taking the release is exactly that vars.yml. A variable the release gives no
    fallback is one no node held before, so what it recorded is nothing, and a
    value now is a change from that.

    A blocking class is the one place the old reading stays: there a difference
    is a refusal rather than an apply, and the record of a node is not always
    complete. upgrade-cluster.yml records only the classes it applied, so a node
    whose first record it wrote has no line for k8s_cp or the subnets, and
    comparing those against a fallback would refuse a cluster that is exactly as
    it was and tell its owner to rebuild every node. The window that leaves is
    covered by the checks that ask the machine: check-kube-proxy-as-declared.yml
    for the one immutable variable with a fallback, check-vfio-pci.yml for the
    node_rebuild ones. What the node holds now is the starting point there, and
    the run says so
    """
    if name in applied:
        return applied[name], "record"

    if cls in BLOCKING_CLASSES:
        return None, "nothing"

    if name in fallbacks:
        return fallbacks[name], "fallback"

    return UNSET, "unset"


def read_fallbacks(path: Path, class_of: dict) -> dict:
    """The fallback constant-vars.yml declares for each classified variable.

    Read from the file rather than from the hostvars on stdin, which carry only
    the value a node ended up with: the fallback is what that value would have
    been had vars.yml and inventory.yml said nothing, and once they have said
    something it is gone from the merge. The file is the release's own, which is
    what upgrade.sh replaces, so it says what this release falls back to and not
    what the operator wrote
    """
    if not path.is_file():
        print(f"[ERROR] File[\"{path}\"] does not exist. It is constant-vars.yml of the release,"
              " which this reads for the fallbacks of the variables", file=sys.stderr)
        exit(1)

    with path.open(encoding="utf-8") as f:
        constant_vars = yaml.safe_load(f) or {}

    fallbacks = {}
    for name in class_of:
        if name not in constant_vars:
            continue

        value = constant_vars[name]
        # A fallback is a value, written in the file as the value it is. One
        # written as a template would need ansible to say what it is, and the
        # comparison below would be against the text of the template
        if isinstance(value, str) and "{{" in value:
            print(f"[ERROR] Variable[\"{name}\"] of file[\"{path}\"] is a template, and a fallback"
                  " of a classified variable has to be a plain value", file=sys.stderr)
            exit(1)

        fallbacks[name] = value

    return fallbacks


def class_on_node(cls: str, name: str, node_hostvars: dict, applied: dict, fallbacks: dict,
                  memory_reservation_vars: Set[str]) -> str:
    """The class a change has on this node, which is the table's answer but once.

    The memory a node keeps for itself is written into its kubelet configuration
    twice on a node running the static memory manager policy: as the reservations
    every node has, and again per numa node as reservedMemory, which the memory
    manager checkpoints along with its policy and compares against when kubelet
    starts. So on that node the variables those reservations are calculated from
    can not be applied by a restart - kubelet would read the new value, find the
    checkpoint saying the old one and refuse to start - and the change is filed
    under class["kubelet_policy"], whose apply drains the node and takes the
    checkpoints away first. constant-vars.yml says which variables those are.

    Whether the node ran static before or runs it now: a node that is leaving the
    policy still has the checkpoint that disagrees, and a node that is entering it
    is already being drained for the policy itself. What it ran before is what
    the record says, or the fallback where the record predates the variable
    """
    if cls != "kubelet" or name not in memory_reservation_vars:
        return cls

    policy_name = "kubelet_memory_manager_policy"
    ran_before = applied.get(policy_name, fallbacks.get(policy_name))
    if node_hostvars.get(policy_name) == "static" or ran_before == "static":
        return "kubelet_policy"

    return cls


def build_summary(changes: Dict[str, List[dict]]) -> List[str]:
    return [
        f"[{cls}] node[\"{change['ih']}\"] variable[\"{change['name']}\"]"
        f" {fmt_before(change)} -> {fmt(change['current'])}{fmt_compared_with(change)}"
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
                  f" {fmt_before(change)} -> {fmt(change['current'])}", file=sys.stderr)


def fmt_before(change: dict) -> str:
    if change["compared_with"] == "unset":
        return "(unset)"

    return fmt(change["applied"])


def fmt_compared_with(change: dict) -> str:
    """Says when the value on the left is not one the node recorded, so that a
    report of "none -> static" is not read as a record that said none."""
    if change["compared_with"] == "fallback":
        return " (not recorded; compared against the fallback of the release)"
    if change["compared_with"] == "unset":
        return " (not recorded; the release gives it no fallback, so the node held nothing)"

    return ""


def fmt(value: Any) -> str:
    return yaml.safe_dump(value, default_flow_style=True).strip().rstrip("...").strip()


main()
