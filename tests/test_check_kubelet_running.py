"""check-kubelet-running.sh says whether kubelet is running, and is not fooled by a unit that is looping.

A kubelet that refuses its configuration is started again every ten seconds and
is up for a moment each time, so the unit is asked more than once. systemctl is
stood in for by a script that answers from a list, one answer a question. These
need a bash; on windows the one of git is named through KI_TEST_BASH.
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "k8s-node" / "check-kubelet-running.sh"

BASH = os.environ.get("KI_TEST_BASH") or (shutil.which("bash") if sys.platform != "win32" else None)

pytestmark = pytest.mark.skipif(BASH is None, reason="needs a bash, named through KI_TEST_BASH on windows")

SYSTEMCTL = """#!/usr/bin/env bash
# Answers is-active from the first line of the answers file and takes it off
answers=$(dirname "$0")/answers
answer=$(head -n 1 "$answers")
sed -i 1d "$answers"
echo asked >> "$(dirname "$0")"/asked
[[ $answer = active ]]
"""


def ask(tmp_path, answers):
    (tmp_path / "systemctl").write_text(SYSTEMCTL, newline="\n")
    (tmp_path / "systemctl").chmod(0o755)
    (tmp_path / "answers").write_text("".join(f"{answer}\n" for answer in answers), newline="\n")
    env = dict(os.environ, PATH=tmp_path.as_posix() + os.pathsep + os.environ["PATH"],
               KUBELET_QUESTION_INTERVAL="0")
    result = subprocess.run([BASH, SCRIPT.as_posix()], capture_output=True, text=True, env=env, check=False)
    assert result.returncode == 0, result.stderr

    return result.stdout.strip(), len((tmp_path / "asked").read_text().splitlines())


def test_a_kubelet_that_answers_every_time_is_running(tmp_path):
    assert ask(tmp_path, ["active", "active", "active"]) == ("true", 3)


def test_a_kubelet_that_is_down_is_not_asked_again(tmp_path):
    assert ask(tmp_path, ["activating"]) == ("false", 1)


def test_a_looping_kubelet_caught_while_it_is_up_is_still_not_running(tmp_path):
    assert ask(tmp_path, ["active", "activating", "active"]) == ("false", 2)
