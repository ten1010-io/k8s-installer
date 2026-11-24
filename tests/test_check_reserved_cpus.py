"""check-reserved-cpus.sh lays the reserved cpu set of a node over its machine.

It is given the set the inventory names and says what is wrong with it before it
is applied. It answers from three things the kernel publishes - the cpus online,
the threads of each core and the cpus of each numa node - so it is run here
against a directory of fixtures standing in for sysfs, which CPU_SYSFS_PATH and
NUMA_NODES_PATH are overridable for.

The machine is the shape of a two socket server with hyperthreading: two numa
nodes, the threads of a core n and n + half the cpus apart, numa node 0 holding
the first half of each range. With 96 cpus that is 0-23,48-71 and 24-47,72-95,
and the sets below read the way they would on that machine.

These need a bash; on windows the one of git is named through KI_TEST_BASH,
since the bash on PATH there may be the one of wsl.
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
SCRIPTS = REPO / "scripts" / "k8s-node" / "kubelet-policy"
CHECK = SCRIPTS / "check-reserved-cpus.sh"

BASH = os.environ.get("KI_TEST_BASH") or (shutil.which("bash") if sys.platform != "win32" else None)

pytestmark = pytest.mark.skipif(BASH is None, reason="needs a bash, named through KI_TEST_BASH on windows")


def cpu_list(cpus):
    return ",".join(str(cpu) for cpu in sorted(cpus))


def write_machine(root, numa_nodes, threads_of, online=None):
    """Writes the sysfs of a machine: the cpus of each numa node and the threads of the core of each cpu."""
    cpus = sorted(cpu for node in numa_nodes for cpu in node)
    cpu_path = root / "cpu"
    cpu_path.mkdir(parents=True)
    (cpu_path / "online").write_text(cpu_list(cpus if online is None else online) + "\n")
    for cpu in cpus:
        topology = cpu_path / f"cpu{cpu}" / "topology"
        topology.mkdir(parents=True)
        (topology / "thread_siblings_list").write_text(cpu_list(threads_of(cpu)) + "\n")

    node_path = root / "node"
    node_path.mkdir()
    for index, node in enumerate(numa_nodes):
        (node_path / f"node{index}").mkdir()
        (node_path / f"node{index}" / "cpulist").write_text(cpu_list(node) + "\n")

    return root


@pytest.fixture
def two_sockets(tmp_path):
    numa_nodes = [list(range(0, 24)) + list(range(48, 72)), list(range(24, 48)) + list(range(72, 96))]

    return write_machine(tmp_path / "sys", numa_nodes, lambda cpu: {cpu % 48, cpu % 48 + 48})


def run(script, machine, *args, config=None):
    env = dict(os.environ,
               CPU_SYSFS_PATH=(machine / "cpu").as_posix(),
               NUMA_NODES_PATH=(machine / "node").as_posix(),
               KUBELET_CONFIG_PATH=(config or machine / "no-config.yaml").as_posix(),
               LC_ALL="C.UTF-8")
    result = subprocess.run([BASH, script.as_posix(), "--node", "node1", *args],
                            capture_output=True, text=True, env=env, check=False)
    assert result.returncode == 0, result.stderr

    return result.stdout.splitlines()


def check(machine, reserved, policy="static", full_pcpus_only=False):
    return run(CHECK, machine,
               "--reserved-cpus", reserved,
               "--cpu-manager-policy", policy,
               "--full-pcpus-only", str(full_pcpus_only).lower())


def test_a_core_of_each_numa_node_with_its_threads_says_nothing(two_sockets):
    assert check(two_sockets, "0,24,48,72", full_pcpus_only=True) == []


def test_a_node_that_names_no_set_says_nothing(two_sockets):
    assert check(two_sockets, "") == []


def test_a_cpu_the_node_does_not_have_is_refused_under_any_policy(two_sockets):
    for policy in ("none", "static"):
        lines = check(two_sockets, "0,48,96-97", policy=policy)

        errors = [line for line in lines if line.startswith("[ERROR]")]
        assert len(errors) == 1
        assert 'names cpus["96,97"]' in errors[0]
        assert 'it has cpus["0,1,2' in errors[0]


def test_a_cpu_that_is_offline_is_one_the_node_does_not_have(tmp_path):
    machine = write_machine(tmp_path / "sys", [[0, 1, 2, 3]], lambda cpu: {cpu}, online=[0, 1, 2])

    lines = check(machine, "0,3", policy="none")

    assert len(lines) == 1
    assert lines[0].startswith("[ERROR]")
    assert 'names cpus["3"]' in lines[0]


def test_half_a_core_is_refused_with_full_pcpus_only(two_sockets):
    lines = check(two_sockets, "0-1,24-25", full_pcpus_only=True)

    errors = [line for line in lines if line.startswith("[ERROR]")]
    assert len(errors) == 4
    assert 'reserves cpus["0"] of the core whose threads are cpus["0,48"] and not cpus["48"]' in errors[0]
    assert 'cpus["25"] of the core whose threads are cpus["25,73"] and not cpus["73"]' in errors[3]


def test_half_a_core_is_reported_without_full_pcpus_only(two_sockets):
    lines = check(two_sockets, "0-1,24-25")

    assert not [line for line in lines if line.startswith("[ERROR]")]
    halves = [line for line in lines if "of the core whose threads are" in line]
    assert len(halves) == 4
    assert all(line.startswith("[WARN]") for line in halves)
    # Two threads on each numa node and not one core between them
    assert any('less than one whole core on numa["0,1"]' in line for line in lines)


def test_the_layout_is_not_asked_about_without_the_static_policy(two_sockets):
    assert check(two_sockets, "0-1", policy="none") == []


def test_a_numa_node_with_nothing_reserved_is_reported(two_sockets):
    lines = check(two_sockets, "0-1,48-49", full_pcpus_only=True)

    assert not [line for line in lines if line.startswith("[ERROR]")]
    assert any(line.startswith("[WARN]") and 'reserves no cpu on numa["1"]' in line for line in lines)
    assert any('numa["0"] 4, numa["1"] 0' in line for line in lines)


def test_numa_nodes_reserved_unevenly_are_reported(two_sockets):
    lines = check(two_sockets, "0-1,48-49,24,72", full_pcpus_only=True)

    assert len(lines) == 1
    assert lines[0].startswith("[WARN]")
    assert 'does not reserve the same number of cpus on every numa node: numa["0"] 4, numa["1"] 2' in lines[0]


def test_a_machine_without_hyperthreading_has_no_half_cores(tmp_path):
    machine = write_machine(tmp_path / "sys", [[0, 1, 2, 3], [4, 5, 6, 7]], lambda cpu: {cpu})

    assert check(machine, "0,4", full_pcpus_only=True) == []


def test_a_memory_only_numa_node_is_not_one_that_lacks_a_reservation(tmp_path):
    machine = write_machine(tmp_path / "sys", [[0, 1, 2, 3], []], lambda cpu: {cpu % 2, cpu % 2 + 2})

    assert check(machine, "0,2", full_pcpus_only=True) == []


def test_a_kernel_without_numa_sysfs_is_one_numa_node(tmp_path):
    machine = write_machine(tmp_path / "sys", [[0, 1, 2, 3]], lambda cpu: {cpu % 2, cpu % 2 + 2})
    shutil.rmtree(machine / "node")

    assert check(machine, "0,2", full_pcpus_only=True) == []
    assert any('less than one whole core on numa["0"]' in line for line in check(machine, "0"))
