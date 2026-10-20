#!/usr/bin/env python3
"""Keeps the vip of the ki cp nodes delivered to the node keepalived made MASTER.

keepalived puts the vip on an interface and says so with gratuitous arp, which
a switch listens to and a cloud ignores: a vpc delivers to the addresses it has
on record for a network interface and to nothing else. What is on record has to
be changed through the api of that cloud, and every cloud has its own api, its
own idea of where an address may go and its own way of handing out credentials.
That part is a carrier, one module under carriers/ named after the way the
address is carried rather than after the cloud, since one cloud can offer two
ways and another needs none. This script is everything around the carrier and
knows nothing a carrier knows.

A carrier answers three questions, as functions of its module:

  carry(args)            make the fabric deliver the vip to this node, and do
                         nothing when it already does. May touch the resources
                         of a previous holder, since that can be what taking an
                         address means. There is no verb for letting go
  probe(args) -> bool    does the fabric deliver the vip to this node now. Asked
                         often and answered without credentials
  preflight(args) -> []  what this node lacks to carry the vip at all, as lines
                         an operator can act on. Empty when nothing is missing

and may add options of its own through add_arguments(parser). It is loaded
from carriers/<name>.py with the dashes of the name turned into underscores.

"reconcile" is what the unit of the host runs, woken by the state file
keepalived writes and by a timer. It reads the state file rather than trusting
the wake: MASTER and the probe saying no is the one case anything is done, and
then the carrier is asked to carry and the probe is watched until it says yes.
Every run leaves what the probe said in the carried file, which is what the
metrics of the node read.

Taking the address is not always right away. At a transition the previous
holder is meant to lose it, and the state file is fresh. Found later, with the
state file old, the address being on another node is either an operator who
moved it from a console or two nodes that both believe they are MASTER because
the vrrp advertisements between them are blocked. Both of those are taken back
too, but only after the address has been away for a while, so that a split
brain moves the address once a minute rather than at every tick - slowly enough
for the metrics to say what is going on and for someone to read them.

"preflight" is what check-node-state.sh asks before a node is built, and
"probe" prints the answer of the probe for anyone asking by hand.
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import pathlib
import sys
import time
from types import ModuleType

CARRIERS_DIR = pathlib.Path(__file__).resolve().parent / "carriers"
# The word keepalived writes when this node holds the address
MASTER = "MASTER"
# How long the address may sit on another node, found there without a
# transition, before it is taken back. Long enough that two nodes which both
# believe they are MASTER take it from each other slowly, and that an operator
# who moved it has a moment to see the metrics disagree. A transition does not
# wait: the state file is newer than this, and the previous holder is the one
# that is meant to lose the address
STEAL_AFTER_SECONDS = 60.0
# How long the probe is given to agree with a carry the carrier reported done.
# The api of a cloud answers before its network does, and an address the probe
# never sees is not carried whatever the api said
CONFIRM_SECONDS = 30.0
CONFIRM_POLL_SECONDS = 1.0


def log(level: str, message: str) -> None:
    print(f"[{level}] {message}", file=sys.stderr, flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--carrier", required=True, help="The carrier module under carriers/, by name")
    # For the tests, which put a carrier of their own somewhere else
    parser.add_argument("--carriers-dir", default=str(CARRIERS_DIR), help=argparse.SUPPRESS)
    subparsers = parser.add_subparsers(dest="command", required=True)

    reconcile_parser = subparsers.add_parser("reconcile", help="Carry the vip when the state file says MASTER and the probe says no")
    add_common_arguments(reconcile_parser)
    reconcile_parser.add_argument("--state-path", required=True, help="The file notify.sh writes the vrrp state to")
    reconcile_parser.add_argument("--carried-path", required=True, help="Where the answer of the probe is left for the metrics")
    reconcile_parser.add_argument("--pending-path", required=True, help="Where the time the address was first found elsewhere is kept")
    reconcile_parser.add_argument("--steal-after", type=float, default=STEAL_AFTER_SECONDS)
    reconcile_parser.add_argument("--confirm-seconds", type=float, default=CONFIRM_SECONDS)

    preflight_parser = subparsers.add_parser("preflight", help="Ask for everything carry needs, without moving anything")
    add_common_arguments(preflight_parser)

    probe_parser = subparsers.add_parser("probe", help="Print 1 when the fabric delivers the vip to this node")
    add_common_arguments(probe_parser)

    # The carrier is known before the rest is parsed, so that its own options
    # can be on every subcommand. Parsed twice on purpose: once to learn the
    # name, once with the carrier's options added
    known, _ = parser.parse_known_args()
    carrier = load_carrier(known.carriers_dir, known.carrier)
    add_arguments = getattr(carrier, "add_arguments", None)
    if add_arguments is not None:
        for subparser in (reconcile_parser, preflight_parser, probe_parser):
            add_arguments(subparser)
    args = parser.parse_args()

    if args.command == "reconcile":
        return reconcile(carrier, args)
    if args.command == "preflight":
        return preflight(carrier, args)
    return probe(carrier, args)


def add_common_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--vip", required=True, help="The address keepalived raises")
    parser.add_argument("--node-ip", required=True, help="The internal address of this node, which names its interface")


def load_carrier(carriers_dir: str, name: str) -> ModuleType:
    path = pathlib.Path(carriers_dir) / f"{name.replace('-', '_')}.py"
    if not path.is_file():
        log("ERROR", f"No carrier named [\"{name}\"]: there is no {path}")
        sys.exit(2)
    spec = importlib.util.spec_from_file_location(f"carrier_{path.stem}", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    for required in ("carry", "probe", "preflight"):
        if not callable(getattr(module, required, None)):
            log("ERROR", f"Carrier[\"{name}\"] at {path} has no {required}()")
            sys.exit(2)
    return module


def reconcile(carrier: ModuleType, args: argparse.Namespace) -> int:
    state = read_text(args.state_path)
    if state != MASTER:
        # Nothing to carry and nothing to wait for. Said in the files too, so
        # that a node which was MASTER a moment ago does not keep the clock of
        # a wait it is no longer in
        write_carried(args, probe_quietly(carrier, args))
        remove(args.pending_path)
        log("INFO", f"Vrrp state is [\"{state}\"], so the vip is not this node's to carry")
        return 0

    if probe_quietly(carrier, args):
        write_carried(args, True)
        remove(args.pending_path)
        log("INFO", f"Vip[\"{args.vip}\"] is delivered to this node")
        return 0

    now = time.time()
    if not may_take_now(args, now):
        write_carried(args, False)
        return 0

    try:
        log("INFO", f"Asking the carrier to bring vip[\"{args.vip}\"] to this node")
        carrier.carry(args)
        confirm(carrier, args)
    except Exception as error:  # noqa: BLE001 - whatever a carrier raises is a reason, and the reason is the log
        log("ERROR", f"Could not carry vip[\"{args.vip}\"] to this node: {error}")
        write_carried(args, False)
        return 1

    write_carried(args, True)
    remove(args.pending_path)
    log("INFO", f"Vip[\"{args.vip}\"] is delivered to this node")
    return 0


def may_take_now(args: argparse.Namespace, now: float) -> bool:
    """Whether an address that is elsewhere may be taken on this run.

    Right away after a transition, which the age of the state file says. Found
    elsewhere later, only once it has been elsewhere for steal_after: the first
    run that sees it writes the time down and waits, and a run that finds the
    time old enough goes ahead. A carry that then fails leaves the time where it
    is, so the next run goes ahead as well - the wait is before the first
    attempt and not between attempts.

    The time is written down at a transition too, although nothing waits on it
    then. It is for the transition whose carry kept failing - an api that was
    down - until the state file was older than steal_after: without a time from
    the transition, the run after that would read the address as newly found
    elsewhere and wait a whole steal_after more, on a node that had been
    MASTER with nothing delivered to it for a minute already. Measured on ec2,
    where that second wait was most of the outage.
    """
    first_seen = read_float(args.pending_path)
    if first_seen is None:
        first_seen = now
        write_text(args.pending_path, f"{now:.0f}\n")

    state_age = now - os.path.getmtime(args.state_path)
    if state_age < args.steal_after:
        return True

    if now - first_seen >= args.steal_after:
        return True
    if first_seen == now:
        log("INFO", f"Vip[\"{args.vip}\"] is not delivered to this node and there was no transition. Taking it in"
                    f" {args.steal_after:g}s unless it comes back")
    else:
        log("INFO", f"Vip[\"{args.vip}\"] has been away for {now - first_seen:.0f}s of {args.steal_after:g}s")
    return False


def confirm(carrier: ModuleType, args: argparse.Namespace) -> None:
    deadline = time.monotonic() + args.confirm_seconds
    while True:
        if carrier.probe(args):
            return
        if time.monotonic() >= deadline:
            raise RuntimeError(
                f"the carrier reported vip[\"{args.vip}\"] carried, and {args.confirm_seconds:g}s later the probe still"
                " says it is not delivered to this node")
        time.sleep(min(CONFIRM_POLL_SECONDS, max(deadline - time.monotonic(), 0)))


def preflight(carrier: ModuleType, args: argparse.Namespace) -> int:
    errors = carrier.preflight(args)
    for error in errors:
        log("ERROR", error)
    if errors:
        return 1
    log("INFO", f"Vip[\"{args.vip}\"] can be carried to this node by carrier[\"{args.carrier}\"]")
    return 0


def probe(carrier: ModuleType, args: argparse.Namespace) -> int:
    print(1 if probe_quietly(carrier, args) else 0)
    return 0


def probe_quietly(carrier: ModuleType, args: argparse.Namespace) -> bool:
    """A probe that could not be made is a no. The carried file is read as a
    gauge, and a series that disappears is the one thing it exists to avoid."""
    try:
        return bool(carrier.probe(args))
    except Exception as error:  # noqa: BLE001 - see reconcile
        log("WARN", f"Could not probe for vip[\"{args.vip}\"]: {error}")
        return False


def write_carried(args: argparse.Namespace, carried: bool) -> None:
    write_text(args.carried_path, "1\n" if carried else "0\n")


def read_text(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read().strip()
    except FileNotFoundError:
        return ""


def read_float(path: str) -> float | None:
    text = read_text(path)
    try:
        return float(text) if text else None
    except ValueError:
        return None


def write_text(path: str, text: str) -> None:
    """Beside and then into place, so that a reader never sees half of it."""
    tmp_path = f"{path}.tmp"
    with open(tmp_path, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(tmp_path, path)


def remove(path: str) -> None:
    try:
        os.remove(path)
    except FileNotFoundError:
        pass


if __name__ == "__main__":
    sys.exit(main())
