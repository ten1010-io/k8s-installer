"""What carry-vip.py is for is the part of carrying a vip that no cloud owns:
reading the state keepalived wrote, deciding whether an address that is
elsewhere may be taken now, asking the carrier, and leaving the answer of the
probe where the metrics read it.

Run as the unit runs it, as a process, against a carrier written here that
records what it was asked and answers from a file standing in for the network.
What is asserted is the contract the unit and the metrics depend on: the exit
code, whether carry was called, and what the carried file says.
"""
from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "ki-cp-node" / "keepalived" / "carry-vip.py"
VIP = "192.168.0.10"
NODE_IP = "192.168.0.1"

# A carrier whose network is a file: "here" is the vip delivered to this node,
# anything else is it being elsewhere. carry() writes "here" unless told to fail
# or to do nothing, and every carry is counted
FAKE_CARRIER = '''
import pathlib

FABRIC = pathlib.Path({fabric!r})
CALLS = pathlib.Path({calls!r})


def add_arguments(parser):
    parser.add_argument("--fail-carry", action="store_true")
    parser.add_argument("--carry-does-nothing", action="store_true")
    parser.add_argument("--broken", action="store_true")


def carry(args):
    CALLS.write_text(str(int(CALLS.read_text() or 0) + 1) if CALLS.exists() else "1")
    if args.fail_carry:
        raise RuntimeError("the fabric said no")
    if not args.carry_does_nothing:
        FABRIC.write_text("here")


def probe(args):
    return FABRIC.exists() and FABRIC.read_text() == "here"


def preflight(args):
    return ["This node is broken. Fix it"] if args.broken else []
'''


class Fixture:
    def __init__(self, tmp_path: Path):
        self.tmp_path = tmp_path
        self.fabric = tmp_path / "fabric"
        self.calls = tmp_path / "calls"
        self.carriers_dir = tmp_path / "carriers"
        self.carriers_dir.mkdir()
        (self.carriers_dir / "fake_fabric.py").write_text(
            FAKE_CARRIER.format(fabric=str(self.fabric), calls=str(self.calls)))
        self.state = tmp_path / "vrrp"
        self.carried = tmp_path / "carried"
        self.pending = tmp_path / "pending"

    def vip_is(self, where: str) -> None:
        self.fabric.write_text(where)

    def state_is(self, word: str, age_seconds: float = 0) -> None:
        self.state.write_text(f"{word}\n")
        if age_seconds:
            stamp = time.time() - age_seconds
            os.utime(self.state, (stamp, stamp))

    def carry_calls(self) -> int:
        return int(self.calls.read_text()) if self.calls.exists() else 0

    def carried_says(self) -> str:
        return self.carried.read_text().strip() if self.carried.exists() else "absent"

    def run(self, *args: str, carrier: str = "fake-fabric") -> subprocess.CompletedProcess:
        command = [sys.executable, str(SCRIPT), "--carrier", carrier, "--carriers-dir", str(self.carriers_dir), *args]
        return subprocess.run(command, capture_output=True, text=True, timeout=60)

    def reconcile(self, *extra: str, steal_after: str = "60") -> subprocess.CompletedProcess:
        return self.run("reconcile", "--state-path", str(self.state), "--carried-path", str(self.carried),
                        "--pending-path", str(self.pending), "--vip", VIP, "--node-ip", NODE_IP,
                        "--steal-after", steal_after, "--confirm-seconds", "1", *extra)


@pytest.fixture
def fx(tmp_path):
    return Fixture(tmp_path)


def test_a_node_that_is_not_master_asks_the_carrier_nothing(fx):
    fx.state_is("BACKUP")
    fx.vip_is("elsewhere")

    result = fx.reconcile()

    assert result.returncode == 0, result.stderr
    assert fx.carry_calls() == 0
    assert fx.carried_says() == "0"


def test_a_node_keepalived_has_not_written_for_is_not_master(fx):
    fx.vip_is("elsewhere")

    result = fx.reconcile()

    assert result.returncode == 0, result.stderr
    assert fx.carry_calls() == 0


def test_a_transition_takes_the_vip_right_away(fx):
    fx.state_is("MASTER")
    fx.vip_is("elsewhere")

    result = fx.reconcile()

    assert result.returncode == 0, result.stderr
    assert fx.carry_calls() == 1
    assert fx.carried_says() == "1"
    assert not fx.pending.exists()


def test_a_master_the_vip_is_delivered_to_asks_the_carrier_nothing(fx):
    fx.state_is("MASTER")
    fx.vip_is("here")

    result = fx.reconcile()

    assert result.returncode == 0, result.stderr
    assert fx.carry_calls() == 0
    assert fx.carried_says() == "1"


def test_a_vip_found_elsewhere_without_a_transition_is_waited_for_before_it_is_taken(fx):
    """An old state file means no transition: either an operator moved the
    address or two nodes both believe they are MASTER. Taken back, but only
    once it has been away for steal_after, so a split brain moves the address
    slowly rather than at every tick."""
    fx.state_is("MASTER", age_seconds=600)
    fx.vip_is("elsewhere")

    first = fx.reconcile()
    second = fx.reconcile()

    assert first.returncode == 0 and second.returncode == 0
    assert fx.carry_calls() == 0
    assert fx.carried_says() == "0"
    assert fx.pending.exists()
    assert "Taking it in 60s" in first.stderr

    # The wait is over
    fx.pending.write_text(f"{time.time() - 61:.0f}\n")
    third = fx.reconcile()

    assert third.returncode == 0, third.stderr
    assert fx.carry_calls() == 1
    assert fx.carried_says() == "1"
    assert not fx.pending.exists()


def test_a_vip_that_came_back_on_its_own_ends_the_wait(fx):
    fx.state_is("MASTER", age_seconds=600)
    fx.vip_is("elsewhere")
    fx.reconcile()
    assert fx.pending.exists()

    fx.vip_is("here")
    result = fx.reconcile()

    assert result.returncode == 0, result.stderr
    assert fx.carry_calls() == 0
    assert not fx.pending.exists()


def test_a_node_that_stopped_being_master_ends_the_wait(fx):
    fx.state_is("MASTER", age_seconds=600)
    fx.vip_is("elsewhere")
    fx.reconcile()
    assert fx.pending.exists()

    fx.state_is("BACKUP")
    fx.reconcile()

    assert not fx.pending.exists()
    assert fx.carry_calls() == 0


def test_a_transition_whose_carry_kept_failing_does_not_wait_again_once_the_state_file_is_old(fx):
    """Seen on ec2: the api was down through the whole minute after the
    transition, and the first run after that minute read the address as newly
    found elsewhere and waited another minute. The transition is when the
    address was first missing, and that is the time the wait counts from."""
    fx.state_is("MASTER")
    fx.vip_is("elsewhere")
    failed = fx.reconcile("--fail-carry")
    assert failed.returncode == 1
    assert fx.pending.exists(), "the time the address was first found missing is written at a transition too"

    # The minute has passed with the api down the whole time
    fx.state_is("MASTER", age_seconds=120)
    fx.pending.write_text(f"{time.time() - 120:.0f}\n")
    result = fx.reconcile()

    assert result.returncode == 0, result.stderr
    assert fx.carry_calls() == 2
    assert fx.carried_says() == "1"


def test_a_carry_that_fails_exits_1_and_says_why(fx):
    fx.state_is("MASTER")
    fx.vip_is("elsewhere")

    result = fx.reconcile("--fail-carry")

    assert result.returncode == 1
    assert "the fabric said no" in result.stderr
    assert fx.carry_calls() == 1
    assert fx.carried_says() == "0"


def test_a_carry_the_probe_never_agrees_with_is_a_failure(fx):
    fx.state_is("MASTER")
    fx.vip_is("elsewhere")

    result = fx.reconcile("--carry-does-nothing")

    assert result.returncode == 1
    assert "probe still says it is not delivered" in result.stderr
    assert fx.carried_says() == "0"


def test_preflight_passes_on_what_the_carrier_passes(fx):
    result = fx.run("preflight", "--vip", VIP, "--node-ip", NODE_IP)

    assert result.returncode == 0, result.stderr


def test_preflight_reports_what_the_carrier_reports(fx):
    result = fx.run("preflight", "--vip", VIP, "--node-ip", NODE_IP, "--broken")

    assert result.returncode == 1
    assert "This node is broken. Fix it" in result.stderr


def test_probe_prints_what_the_carrier_answers(fx):
    fx.vip_is("elsewhere")
    assert fx.run("probe", "--vip", VIP, "--node-ip", NODE_IP).stdout.strip() == "0"

    fx.vip_is("here")
    assert fx.run("probe", "--vip", VIP, "--node-ip", NODE_IP).stdout.strip() == "1"


def test_a_carrier_nobody_wrote_is_refused_by_name(fx):
    result = fx.run("probe", "--vip", VIP, "--node-ip", NODE_IP, carrier="gcp-alias-ip")

    assert result.returncode == 2
    assert "gcp-alias-ip" in result.stderr


def test_a_carrier_missing_a_verb_is_refused(fx):
    (fx.carriers_dir / "half.py").write_text("def carry(args): pass\ndef probe(args): return False\n")

    result = fx.run("probe", "--vip", VIP, "--node-ip", NODE_IP, carrier="half")

    assert result.returncode == 2
    assert "preflight" in result.stderr


def test_the_arp_carrier_of_the_installer_asks_nothing_of_the_site():
    """arp is the one carrier that is shipped and needs no cloud: its preflight
    has nothing to say, so a site that never heard of carriers sees no change."""
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "--carrier", "arp", "preflight", "--vip", VIP, "--node-ip", NODE_IP],
        capture_output=True, text=True, timeout=60)

    assert result.returncode == 0, result.stderr
