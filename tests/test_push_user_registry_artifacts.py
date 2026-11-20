"""What push-user-registry-artifacts.sh promises about a run, kept or cut short.

The script opens the user registry for writing, pushes the artifacts of an
archive several at a time and closes it again. Three things about that are easy
to break and are found late on a node: a push that failed has to be named and
has to fail the run, no more pushes run at once than were asked for, and the
registry is readonly again however the run ends - a failed push, a signal, a
step that could not even start.

The script itself runs here, whole, from the checkout. What it calls is stood
in for: yq reads the one key it is asked for, jinja2 and docker write down that
they were called, curl says the registry is up, and crane sleeps instead of
pushing and fails for an artifact that asks it to. So what is checked is the
shell of the script - the pool, the traps, the order - and not the registry,
which a run against a real one has to show.

Needs gnu find and a bash of 4.3 or later, as the script does.
"""
import os
import signal
import subprocess
import sys
import tarfile
import time

import pytest

from conftest import REPO

pytestmark = pytest.mark.skipif(sys.platform != "linux", reason="the script needs gnu find")

SCRIPT = REPO / "scripts" / "ki-cp-node" / "user-registry" / "push-user-registry-artifacts.sh"

YQ = """#!/usr/bin/env bash
key=${1#.}
value=$(sed -n "s/^$key: //p")
echo "${value:-null}"
"""

JINJA2 = """#!/usr/bin/env bash
for arg in "$@"; do
  case $arg in readonly_enabled=*) echo "${arg#readonly_enabled=}" >> "$STATE/readonly" ;; esac
done
"""

DOCKER = """#!/usr/bin/env bash
echo "$*" >> "$STATE/docker"
"""

CURL = """#!/usr/bin/env bash
exit 0
"""

# push --insecure <layout> <reference>. How many of these are running is written
# down on the way in, which is what the tests read the pool from
CRANE = """#!/usr/bin/env bash
layout=$3
echo "$4" >> "$STATE/pushed"
echo $$ >> "$STATE/pids"
touch "$STATE/running/$$"
ls "$STATE/running" | wc -l >> "$STATE/at-once"
if [[ -e $layout/fail ]]; then
  rm -f "$STATE/running/$$"
  echo "crane says no to $4" >&2
  exit 1
fi
if [[ -e $layout/slow ]]; then
  exec sleep 60
fi
sleep 0.3
rm -f "$STATE/running/$$"
echo "pushed $4" >&2
"""


class Node:
    """A directory laid out the way the script expects a ki cp node to be."""

    def __init__(self, root):
        self.root = root
        self.state = root / "state"
        (self.state / "running").mkdir(parents=True)
        machine = os.uname().machine
        self._stub(root / "opt" / "bundle" / "bin" / machine / "yq", YQ)
        self._stub(root / "opt" / "bundle" / "bin" / machine / "crane", CRANE)
        self._stub(root / "opt" / "venv" / "bin" / "jinja2", JINJA2)
        self._stub(root / "path" / "docker", DOCKER)
        self._stub(root / "path" / "curl", CURL)
        for path in ("opt/scripts", "etc/ki-cp-user-registry", "var/ki-cp-user-registry", "tmp"):
            (root / path).mkdir(parents=True)

    @staticmethod
    def _stub(path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o755)

    def archive(self, artifacts):
        """artifacts: name -> None, "fail" or "slow"."""
        stage = self.root / "stage" / "ki-cp-user-registry-artifacts"
        for name, mark in artifacts.items():
            (stage / name).mkdir(parents=True)
            (stage / name / "oci-layout").write_text("{}")
            if mark:
                (stage / name / mark).write_text("")
        path = self.root / "archive.tgz"
        with tarfile.open(path, "w:gz") as tar:
            tar.add(stage, arcname=stage.name)
        return path

    def command(self, jobs, artifacts):
        vars_path = self.root / "vars.yml"
        vars_path.write_text(
            f"ki_opt_root_path: {self.root}/opt\n"
            f"ki_opt_scripts_path: {self.root}/opt/scripts\n"
            f"ki_opt_bundle_path: {self.root}/opt/bundle\n"
            f"ki_opt_venv_path: {self.root}/opt/venv\n"
            f"ki_var_root_path: {self.root}/var\n"
            f"ki_etc_services_path: {self.root}/etc\n"
            f"ki_tmp_root_path: {self.root}/tmp\n"
            f"ki_cp_user_registry_port: 5001\n"
            f"ki_cp_user_registry_push_jobs: {jobs}\n")
        return ["bash", str(SCRIPT), "--vars-path", str(vars_path),
                "--archive-path", str(self.archive(artifacts))]

    def env(self, **more):
        env = dict(os.environ, STATE=str(self.state),
                   PATH=f"{self.root}/path{os.pathsep}{os.environ['PATH']}")
        env.update(more)
        return env

    def run(self, jobs, artifacts, **env):
        return subprocess.run(self.command(jobs, artifacts), env=self.env(**env),
                              capture_output=True, text=True, check=False, timeout=120)

    def lines(self, name):
        path = self.state / name
        return path.read_text().split() if path.exists() else []

    def pushed(self):
        return [ref.split("/", 1)[1] for ref in self.lines("pushed")]

    def at_once(self):
        return max(int(count) for count in self.lines("at-once"))

    def cranes_alive(self):
        alive = []
        for pid in self.lines("pids"):
            try:
                os.kill(int(pid), 0)
                alive.append(pid)
            except ProcessLookupError:
                pass
        return alive


@pytest.fixture
def node(tmp_path):
    return Node(tmp_path)


SIX = dict.fromkeys(["a", "b", "c", "d", "e", "f"])


def test_every_artifact_is_pushed_and_the_registry_ends_readonly(node):
    result = node.run(3, SIX)

    assert result.returncode == 0, result.stderr
    assert sorted(node.pushed()) == sorted(SIX)
    assert node.lines("readonly") == ["false", "true"]
    assert 2 <= node.at_once() <= 3


def test_one_job_pushes_one_at_a_time_in_order(node):
    result = node.run(1, SIX)

    assert result.returncode == 0, result.stderr
    assert node.pushed() == sorted(SIX)
    assert node.at_once() == 1


def test_a_count_left_null_is_between_two_and_four(node):
    result = node.run("null", SIX)

    assert result.returncode == 0, result.stderr
    assert 2 <= node.at_once() <= 4
    assert "cpus)" in result.stderr


@pytest.mark.parametrize("jobs", ["0", "-1", "four", "1.5"])
def test_a_count_that_is_not_one_or_more_is_refused_before_anything_is_touched(node, jobs):
    result = node.run(jobs, SIX)

    assert result.returncode == 1
    assert "ki_cp_user_registry_push_jobs" in result.stderr
    assert node.pushed() == []
    assert node.lines("readonly") == []


def test_a_failed_push_is_named_fails_the_run_and_starts_no_more(node):
    result = node.run(2, dict(SIX, a="fail"))

    assert result.returncode == 1
    assert 'Failed to push artifact["a"]' in result.stderr
    assert "crane says no" in result.stderr
    # c to f were never started: the pool was full with a and b when a failed
    assert set(node.pushed()) <= {"a", "b"}
    assert node.lines("readonly") == ["false", "true"]


def test_every_failed_push_of_those_running_is_named(node):
    result = node.run(4, dict(SIX, a="fail", b="fail"))

    assert result.returncode == 1
    assert 'Failed to push artifact["a"]' in result.stderr
    assert 'Failed to push artifact["b"]' in result.stderr
    assert node.lines("readonly") == ["false", "true"]


@pytest.mark.parametrize("sent, status", [
    (signal.SIGTERM, 143),
    (signal.SIGINT, 130),
    (signal.SIGHUP, 129),
])
def test_a_signal_stops_the_pushes_and_puts_the_registry_back(node, sent, status):
    process = subprocess.Popen(node.command(2, dict.fromkeys(SIX, "slow")), env=node.env(),
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + 60
    while len(node.lines("pids")) < 2 and time.monotonic() < deadline:
        time.sleep(0.05)
    process.send_signal(sent)

    assert process.wait(timeout=60) in (status, -sent)
    assert node.cranes_alive() == []
    assert node.lines("readonly") == ["false", "true"]


def test_a_step_that_fails_in_a_subshell_closes_the_registry_once(node):
    # mktemp fails inside a $(...), where the ERR trap runs as well
    result = node.run(2, SIX, TMPDIR=str(node.root / "nowhere"))

    assert result.returncode == 1
    assert node.pushed() == []
    assert node.lines("readonly") == ["false", "true"]
