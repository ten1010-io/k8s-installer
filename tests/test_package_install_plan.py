"""rpm-common.sh and deb-common.sh plan an install once, over every directory
of it, and then install each directory from that plan.

What a plan made per directory got wrong is what these exist to stop. The
packages of one source are kept together only when they are planned together,
and a bundle puts them in different directories: libselinux in the first
directory of the rhel 8 bundle and libselinux-devel, pinned to it exactly, in
the last; python3.10 in one directory of setup-venv.sh and python3.10-venv,
pinned the same way, in another. A node holding the library newer kept it
when its directory was planned, and was then handed the headers when theirs
was, which rpm refused after the install had already erased chrony.

Run as the scripts run them: bash sourcing the library after msg and die, the
way the cli template leaves them, with rpm and dpkg standing in as scripts on
PATH that log what they are handed, and the planner reading --facts for what
the node holds. These need a bash; on windows the one of git is named through
KI_TEST_BASH, since the bash on PATH there may be the one of wsl.
"""
import os
import shutil
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest
import yaml

REPO = Path(__file__).resolve().parents[1]
LIB = REPO / "scripts" / "all-node" / "linux-package"

BASH = os.environ.get("KI_TEST_BASH") or (shutil.which("bash") if sys.platform != "win32" else None)

pytestmark = pytest.mark.skipif(BASH is None, reason="needs a bash, named through KI_TEST_BASH on windows")

PRELUDE = """
set -Eeuo pipefail
msg() { echo >&2 -e "${1-}"; }
die() { msg "$1"; exit "${2-1}"; }
"""

# rpm and dpkg, as far as the library asks of them: one line of arguments per
# call, and for dpkg the version comparison the plan is made with
RPM_STUB = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$STUB_LOG"
"""

DPKG_STUB = """#!/usr/bin/env bash
if [[ $1 = --compare-versions ]]; then
  a=$2 op=$3 b=$4
  newest=$(printf '%s\\n%s\\n' "$a" "$b" | sort -V | tail -1)
  case $op in
    eq) [[ $a = "$b" ]] ;;
    gt) [[ $a != "$b" && $newest = "$a" ]] ;;
    lt) [[ $a != "$b" && $newest = "$b" ]] ;;
    *) exit 2 ;;
  esac
  exit $?
fi
printf '%s\\n' "$*" >> "$STUB_LOG"
"""

# A deb is a file beside a .fields file holding what dpkg-deb -W would say of
# it: package, version, architecture and source, tab separated
DPKG_DEB_STUB = """#!/usr/bin/env bash
cat "${@: -1}.fields"
"""

# What the node holds, one installed package per line of STUB_STATUS: source,
# package, version and what it depends on, tab separated. Answers the two
# questions deb_plan asks: every package by its source with its dependencies,
# and the version of one package
DPKG_QUERY_STUB = """#!/usr/bin/env bash
fmt="" name=""
for arg in "$@"; do
  case $arg in
    -W) ;;
    -f=*) fmt=${arg#-f=} ;;
    *) name=$arg ;;
  esac
done
if [[ $fmt = *source:Package* ]]; then
  while IFS=$'\\t' read -r source package version depends; do
    printf '%s\\t%s\\tii \\t%s\\n' "$source" "$package" "$depends"
  done < "$STUB_STATUS"
  exit 0
fi
name=${name%%:*}
while IFS=$'\\t' read -r source package version depends; do
  if [[ $package = "$name" ]]; then
    printf 'ii \\t%s\\n' "$version"
    exit 0
  fi
done < "$STUB_STATUS"
exit 1
"""


class Host:
    """A bundle directory, a node, and the stubs on PATH."""

    def __init__(self, tmp_path):
        self.bundle = tmp_path / "bundle"
        self.bundle.mkdir()
        self.bin = tmp_path / "bin"
        self.bin.mkdir()
        self.log = tmp_path / "calls.log"
        self.status = tmp_path / "status"
        self.status.write_text("")
        self.facts = tmp_path / "facts.yml"
        for name, body in (("rpm", RPM_STUB), ("dpkg", DPKG_STUB),
                           ("dpkg-deb", DPKG_DEB_STUB), ("dpkg-query", DPKG_QUERY_STUB)):
            stub = self.bin / name
            stub.write_text(body)
            stub.chmod(0o755)

    def rpm(self, path, **facts):
        """An rpm of the bundle at path, and what the planner is told of it."""
        file = self.bundle / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.touch()
        facts.setdefault("name", file.stem)
        facts.setdefault("evr", "0:1.0-1.el8")
        facts.setdefault("srpm", f"{facts['name']}.src.rpm")
        facts["file"] = file.name
        known = yaml.safe_load(self.facts.read_text()) if self.facts.exists() else []
        self.facts.write_text(yaml.safe_dump(known + [facts]))

    def deb(self, path, package, version, source=None, arch="amd64"):
        file = self.bundle / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.touch()
        (self.bundle / f"{path}.fields").write_text(f"{package}\t{version}\t{arch}\t{source or package}\n")

    def installed(self, package, version, source=None, depends=""):
        with self.status.open("a") as f:
            f.write(f"{source or package}\t{package}\t{version}\t{depends}\n")

    def run(self, library, script):
        env = dict(os.environ)
        env["PATH"] = str(self.bin) + os.pathsep + env["PATH"]
        env.update({
            "STUB_LOG": self.log.as_posix(),
            "STUB_STATUS": self.status.as_posix(),
            "FACTS": self.facts.as_posix(),
            "PYTHON": Path(sys.executable).as_posix(),
            "LIB": LIB.as_posix(),
        })
        body = PRELUDE + f'source "$LIB/{library}"\n' + textwrap.dedent(script)
        return subprocess.run([BASH, "-c", body], cwd=self.bundle, env=env,
                              capture_output=True, text=True, check=False)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []


@pytest.fixture
def host(tmp_path):
    return Host(tmp_path)


# The planner is run through the python of the node, which here is the one of
# the tests, and reads the facts rather than rpm
RPM_SCRIPT = """
rpm_python() { printf '%s\\n' "$PYTHON"; }
rpm_plan_install --facts "$FACTS" -- nfs-utils/libselinux.rpm devel/libselinux-devel.rpm
rpm_install_planned nfs-utils nfs-utils/libselinux.rpm
echo "nfs-utils=$rpm_installed_count"
rpm_install_planned devel devel/libselinux-devel.rpm
echo "devel=$rpm_installed_count"
"""


def test_the_headers_of_a_library_the_node_holds_newer_are_kept_out_with_it(host):
    host.rpm("nfs-utils/libselinux.rpm", srpm="libselinux-3.6-1.el8.src.rpm",
             installed="newer", installed_evr="0:3.6-3.el8")
    host.rpm("devel/libselinux-devel.rpm", srpm="libselinux-3.6-1.el8.src.rpm")

    result = host.run("rpm-common.sh", RPM_SCRIPT)

    assert result.returncode == 0, result.stderr
    assert host.calls() == []
    assert result.stdout.split() == ["nfs-utils=0", "devel=0"]
    assert "source libselinux is kept" in result.stderr


def test_each_directory_is_handed_over_in_its_turn_after_rpm_has_tried_it(host):
    host.rpm("nfs-utils/libselinux.rpm", srpm="libselinux-3.6-1.el8.src.rpm",
             installed="older", installed_evr="0:3.5-1.el8")
    host.rpm("devel/libselinux-devel.rpm", srpm="libselinux-3.6-1.el8.src.rpm")

    result = host.run("rpm-common.sh", RPM_SCRIPT)

    assert result.returncode == 0, result.stderr
    assert host.calls() == [
        "-Uvh --test --force nfs-utils/libselinux.rpm",
        "-Uvh --force nfs-utils/libselinux.rpm",
        "-Uvh --test --force devel/libselinux-devel.rpm",
        "-Uvh --force devel/libselinux-devel.rpm",
    ]
    assert result.stdout.split() == ["nfs-utils=1", "devel=1"]


def test_a_directory_is_refused_unless_the_install_was_planned(host):
    host.rpm("devel/libselinux-devel.rpm")

    result = host.run("rpm-common.sh", """
        rpm_python() { printf '%s\\n' "$PYTHON"; }
        rpm_install_planned devel devel/libselinux-devel.rpm
    """)

    assert result.returncode != 0
    assert "was not planned" in result.stderr
    assert host.calls() == []


def test_one_directory_that_is_the_whole_install_is_planned_as_itself(host):
    # setup-venv.sh lays down one directory and nothing else
    host.rpm("python3.12/python3.12.rpm")
    host.rpm("python3.12/python3.12-libs.rpm", srpm="python3.12.src.rpm")

    result = host.run("rpm-common.sh", """
        rpm_python() { printf '%s\\n' "$PYTHON"; }
        rpm_install_files python3.12 --facts "$FACTS" -- python3.12/python3.12.rpm python3.12/python3.12-libs.rpm
        echo "installed=$rpm_installed_count"
    """)

    assert result.returncode == 0, result.stderr
    assert host.calls() == [
        "-Uvh --test --force python3.12/python3.12.rpm python3.12/python3.12-libs.rpm",
        "-Uvh --force python3.12/python3.12.rpm python3.12/python3.12-libs.rpm",
    ]
    assert "installed=2" in result.stdout


DEB_SCRIPT = """
deb_plan_install python3.10/python3.10.deb python3/python3-minimal.deb python3/python3.deb python3.10-venv/python3.10-venv.deb
deb_install_planned python3.10 -- python3.10/python3.10.deb
deb_install_planned python3-minimal -- python3/python3-minimal.deb
deb_install_planned python3 -- python3/python3-minimal.deb python3/python3.deb
deb_install_planned python3.10-venv -- python3.10-venv/python3.10-venv.deb
"""


def lay_python_down(host):
    host.deb("python3.10/python3.10.deb", "python3.10", "3.10.12-2")
    host.deb("python3/python3-minimal.deb", "python3-minimal", "3.10.6-1", source="python3-defaults")
    host.deb("python3/python3.deb", "python3", "3.10.6-1", source="python3-defaults")
    host.deb("python3.10-venv/python3.10-venv.deb", "python3.10-venv", "3.10.12-2", source="python3.10")


def test_the_venv_package_is_kept_out_with_the_python_the_node_holds_newer(host):
    lay_python_down(host)
    host.installed("python3.10", "3.10.12-3")

    result = host.run("deb-common.sh", DEB_SCRIPT)

    assert result.returncode == 0, result.stderr
    assert "source python3.10 is kept" in result.stderr
    assert host.calls() == [
        "-i python3/python3-minimal.deb",
        "-i python3/python3.deb",
    ]


def test_a_deb_installed_by_an_earlier_directory_is_not_handed_over_again(host):
    # python3-minimal goes in before the rest of python3, and its directory
    # then names it again
    lay_python_down(host)
    host.installed("python3.10", "3.10.12-1")

    result = host.run("deb-common.sh", DEB_SCRIPT)

    assert result.returncode == 0, result.stderr
    assert host.calls() == [
        "-i python3.10/python3.10.deb",
        "-i python3/python3-minimal.deb",
        "-i python3/python3.deb",
        "-i python3.10-venv/python3.10-venv.deb",
    ]


def deb_actions(result):
    """The action per deb of a deb_plan printed to stdout."""
    assert result.returncode == 0, result.stderr
    return {path: action for action, path, _ in (line.split("\t") for line in result.stdout.splitlines())}


def test_the_python_of_setup_venv_goes_in_over_a_newer_one_as_a_principal_directory(host):
    # setup-venv.sh names its directories as principal ones: the venv package
    # is not on an ubuntu image and wants the python at exactly its version, so
    # a node holding the python newer gets the bundle's, downgrade and all
    lay_python_down(host)
    host.installed("python3.10", "3.10.12-3")

    result = host.run("deb-common.sh", """
        deb_principal_dirs=(python3.10 python3 python3-distutils python3.10-venv)
    """ + DEB_SCRIPT)

    assert result.returncode == 0, result.stderr
    assert host.calls() == [
        "-i python3.10/python3.10.deb",
        "-i python3/python3-minimal.deb",
        "-i python3/python3.deb",
        "-i python3.10-venv/python3.10-venv.deb",
    ]


def test_a_source_is_kept_for_a_deb_of_the_node_that_pins_the_upgrade(host):
    # python3-nftables of the node depends on nftables at exactly its version
    # and the bundle does not carry it, so nothing would move it along
    host.deb("nftables/nftables.deb", "nftables", "1.0.2-1ubuntu3")
    host.installed("nftables", "1.0.2-1ubuntu2")
    host.installed("python3-nftables", "1.0.2-1ubuntu2", source="nftables",
                   depends="libc6 (>= 2.34), nftables (= 1.0.2-1ubuntu2), python3")

    result = host.run("deb-common.sh", "deb_plan nftables/nftables.deb")

    assert deb_actions(result) == {"nftables/nftables.deb": "skip"}
    assert "source nftables is kept" in result.stdout
    assert "python3-nftables" in result.stdout


def test_a_deb_of_the_node_that_does_not_pin_the_upgrade_does_not_hold_it_back(host):
    # libsystemd-dev comes from systemd and wants libsystemd0 no newer than it
    # is, so a newer systemd leaves it as it is
    host.deb("systemd/systemd.deb", "systemd", "249.11-0ubuntu3.15")
    host.deb("systemd/libsystemd0.deb", "libsystemd0", "249.11-0ubuntu3.15", source="systemd")
    host.installed("systemd", "249.11-0ubuntu3.12")
    host.installed("libsystemd0", "249.11-0ubuntu3.12", source="systemd")
    host.installed("libsystemd-dev", "249.11-0ubuntu3.12", source="systemd",
                   depends="libsystemd0 (>= 249.11-0ubuntu3.12), libsystemd0 (<< 249.12)")

    result = host.run("deb-common.sh", "deb_plan systemd/systemd.deb systemd/libsystemd0.deb")

    assert deb_actions(result) == {"systemd/systemd.deb": "install", "systemd/libsystemd0.deb": "install"}


def test_what_the_release_declares_goes_in_over_a_newer_deb(host):
    host.deb("docker/docker-ce.deb", "docker-ce", "5:29.8.1-1~ubuntu.22.04~jammy")
    host.installed("docker-ce", "5:29.9.0-1~ubuntu.22.04~jammy")

    result = host.run("deb-common.sh", """
        deb_principals=(docker-ce)
        deb_plan docker/docker-ce.deb
    """)

    assert deb_actions(result) == {"docker/docker-ce.deb": "install"}


def test_a_declared_deb_is_not_kept_back_by_its_source(host):
    host.deb("docker/docker-ce.deb", "docker-ce", "5:29.8.1-1~ubuntu.22.04~jammy")
    host.deb("docker/docker-ce-rootless-extras.deb", "docker-ce-rootless-extras",
             "5:29.8.1-1~ubuntu.22.04~jammy", source="docker-ce")
    host.installed("docker-ce", "5:29.7.0-1~ubuntu.22.04~jammy")
    host.installed("docker-ce-rootless-extras", "5:29.9.0-1~ubuntu.22.04~jammy", source="docker-ce")

    result = host.run("deb-common.sh", """
        deb_principals=(docker-ce)
        deb_plan docker/docker-ce.deb docker/docker-ce-rootless-extras.deb
    """)

    assert deb_actions(result) == {"docker/docker-ce.deb": "install",
                                   "docker/docker-ce-rootless-extras.deb": "skip"}


def test_a_deb_in_two_directories_is_planned_once(host):
    host.deb("containerd/libseccomp2.deb", "libseccomp2", "2.5.3-2ubuntu2")
    host.deb("docker/libseccomp2.deb", "libseccomp2", "2.5.3-2ubuntu2")

    result = host.run("deb-common.sh", "deb_plan containerd/libseccomp2.deb docker/libseccomp2.deb")

    assert deb_actions(result) == {"containerd/libseccomp2.deb": "install", "docker/libseccomp2.deb": "skip"}


def test_dpkg_options_go_before_the_debs(host):
    host.deb("systemd/systemd.deb", "systemd", "249.11-1")

    result = host.run("deb-common.sh", """
        deb_install_files systemd --force-confnew -- systemd/systemd.deb
        echo "installed=$deb_installed_count"
    """)

    assert result.returncode == 0, result.stderr
    assert host.calls() == ["-i --force-confnew systemd/systemd.deb"]
    assert "installed=1" in result.stdout
