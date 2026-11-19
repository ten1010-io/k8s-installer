"""check-kubelet-policy.sh counts the cpus kubelet keeps for the system on each numa node.

It reads the set off the configuration kubelet runs with, not off the inventory,
and counts it the way check-reserved-cpus.sh does - reserved-cpus-common.sh is
what both source - so the machines are the fixtures of the tests of that script.
"""
import shutil

from test_check_reserved_cpus import SCRIPTS, pytestmark, run, two_sockets, write_machine  # noqa: F401

METRICS = SCRIPTS / "check-kubelet-policy.sh"


def metrics(machine, tmp_path, config_text):
    config = tmp_path / "config.yaml"
    config.write_text(config_text)
    lines = run(METRICS, machine, config=config)

    return [line for line in lines if not line.startswith("#")]


def test_a_kernel_without_numa_sysfs_is_one_numa_node(tmp_path):
    machine = write_machine(tmp_path / "sys", [[0, 1, 2, 3]], lambda cpu: {cpu % 2, cpu % 2 + 2})
    shutil.rmtree(machine / "node")

    assert metrics(machine, tmp_path, 'reservedSystemCPUs: "0,2"\n')[-2:] == [
        'ki_node_kubelet_reserved_system_cpus{numa="0"} 2',
        "ki_node_kubelet_reserved_system_cpus_half_cores 0",
    ]


def test_the_metrics_count_the_set_kubelet_runs_with_on_each_numa_node(two_sockets, tmp_path):
    lines = metrics(two_sockets, tmp_path,
                    "cpuManagerPolicy: static\nreservedSystemCPUs: 0-1,24,48-49,72\ntopologyManagerPolicy: restricted\n")

    assert lines == [
        "ki_node_kubelet_cpu_manager_static 1",
        "ki_node_kubelet_memory_manager_static 0",
        'ki_node_kubelet_topology_manager_policy{policy="restricted"} 1',
        'ki_node_kubelet_reserved_system_cpus{numa="0"} 4',
        'ki_node_kubelet_reserved_system_cpus{numa="1"} 2',
        "ki_node_kubelet_reserved_system_cpus_half_cores 0",
    ]


def test_the_metrics_count_half_reserved_cores_and_write_an_empty_numa_node_as_zero(two_sockets, tmp_path):
    lines = metrics(two_sockets, tmp_path, 'cpuManagerPolicy: static\nreservedSystemCPUs: "0-2,48"\n')

    assert lines[-3:] == [
        'ki_node_kubelet_reserved_system_cpus{numa="0"} 4',
        'ki_node_kubelet_reserved_system_cpus{numa="1"} 0',
        "ki_node_kubelet_reserved_system_cpus_half_cores 2",
    ]


def test_a_node_whose_kubelet_names_no_set_writes_no_reserved_metric(two_sockets, tmp_path):
    lines = metrics(two_sockets, tmp_path, "cpuManagerPolicy: static\n")

    assert lines == [
        "ki_node_kubelet_cpu_manager_static 1",
        "ki_node_kubelet_memory_manager_static 0",
        'ki_node_kubelet_topology_manager_policy{policy="none"} 1',
    ]


def test_the_metrics_file_holds_the_reserved_metrics_too(two_sockets, tmp_path):
    config = tmp_path / "config.yaml"
    config.write_text('reservedSystemCPUs: "0,48"\n')
    path = tmp_path / "metrics" / "kubelet-policy.prom"

    assert run(METRICS, two_sockets, "--metrics-path", path.as_posix(), config=config) == []

    text = path.read_text()
    assert 'ki_node_kubelet_reserved_system_cpus{numa="1"} 0\n' in text
    assert "# TYPE ki_node_kubelet_reserved_system_cpus_half_cores gauge\n" in text
