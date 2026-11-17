"""find-containers-refused-on-restart.py names what a restart of kubelet would kill.

The numbers of the main case are the ones measured: a 16 cpu node whose sibling
threads are n and n+8, reservedSystemCPUs 0,8, a Guaranteed pod holding 8 cpus and
another holding 2. kubernetes 1.36.4 refused the first after a restart with
"available physical CPUs = 4, requested CPUs = 8" and kept the second, and 1.37.2
kept both. What is asserted is that the script names exactly the ones kubelet
refused, and stays quiet wherever kubelet would not refuse anything - a script that
cries wolf turns into a flag everybody passes.

Run as a process, the way check-kubelet-restart.sh runs it, against fixtures
standing in for the kubelet configuration, the checkpoint and sysfs.
"""
import json
import subprocess
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "k8s-node" / "kubelet-policy" / "find-containers-refused-on-restart.py"

BIG_UID = "93225601-e9b8-444c-890b-df59d8216aaa"
SMALL_UID = "bd093fbc-f4b1-41a1-856c-0f5654eb8c92"

STATIC_FULL_PCPUS = {
    "cpuManagerPolicy": "static",
    "cpuManagerPolicyOptions": {"full-pcpus-only": "true"},
    "reservedSystemCPUs": "0,8",
    "systemReserved": {"cpu": "100m", "memory": "1Gi"},
    "kubeReserved": {"cpu": "100m", "memory": "1Gi"},
}

MEASURED_STATE = {
    "policyName": "static",
    "defaultCpuSet": "0,6-8,14-15",
    "entries": {
        BIG_UID: {"c": "1-4,9-12"},
        SMALL_UID: {"c": "5,13"},
    },
    "checksum": 455257821,
}


def write_sysfs(root, cpus=16, threads=2):
    cores = cpus // threads
    for cpu in range(cpus):
        topology = root / f"cpu{cpu}" / "topology"
        topology.mkdir(parents=True)
        siblings = ",".join(str(cpu % cores + cores * t) for t in range(threads))
        (topology / "thread_siblings_list").write_text(f"{siblings}\n", newline="\n")
    return root


def run(tmp_path, config, state, version="Kubernetes v1.36.4", pods=None):
    config_path = tmp_path / "config.yaml"
    config_path.write_text(yaml.safe_dump(config), newline="\n")
    state_path = tmp_path / "cpu_manager_state"
    if state is not None:
        state_path.write_text(json.dumps(state), newline="\n")
    sysfs = tmp_path / "sys"
    if not sysfs.exists():
        write_sysfs(sysfs)
    command = [sys.executable, str(SCRIPT), "--node", "node2", "--kubelet-version", version,
               "--kubelet-config-path", str(config_path), "--cpu-manager-state-path", str(state_path),
               "--cpu-sysfs-path", str(sysfs)]
    if pods is not None:
        pods_path = tmp_path / "pods.json"
        pods_path.write_text(pods, newline="\n")
        command += ["--pods-json-path", str(pods_path)]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout.splitlines()


def test_names_the_container_that_holds_more_than_is_free(tmp_path):
    lines = run(tmp_path, STATIC_FULL_PCPUS, MEASURED_STATE)

    assert len(lines) == 1
    assert BIG_UID in lines[0]
    assert "holds 8 exclusive cpus" in lines[0]
    assert "find 4 free" in lines[0]
    assert 'Node["node2"]' in lines[0]


def test_names_the_pod_when_the_runtime_said_which_it_is(tmp_path):
    pods = json.dumps({"items": [
        {"metadata": {"uid": BIG_UID, "name": "big-c459b46d4-mtzzs", "namespace": "default"}},
        {"metadata": {"uid": SMALL_UID, "name": "small-6f7867c5f5-v45pt", "namespace": "default"}},
    ]})

    lines = run(tmp_path, STATIC_FULL_PCPUS, MEASURED_STATE, pods=pods)

    assert lines == [line for line in lines if 'pod["default/big-c459b46d4-mtzzs"]' in line]
    assert len(lines) == 1


def test_a_runtime_that_did_not_answer_leaves_the_uid(tmp_path):
    lines = run(tmp_path, STATIC_FULL_PCPUS, MEASURED_STATE, pods="")

    assert len(lines) == 1
    assert BIG_UID in lines[0]


def test_quiet_from_1_37_on(tmp_path):
    assert run(tmp_path, STATIC_FULL_PCPUS, MEASURED_STATE, version="Kubernetes v1.37.2") == []


def test_quiet_without_full_pcpus_only(tmp_path):
    config = dict(STATIC_FULL_PCPUS, cpuManagerPolicyOptions={})

    assert run(tmp_path, config, MEASURED_STATE) == []


def test_quiet_without_the_static_policy(tmp_path):
    config = {"cpuManagerPolicy": "none"}

    assert run(tmp_path, config, {"policyName": "none", "defaultCpuSet": "", "checksum": 1}) == []


def test_quiet_when_nothing_was_handed_out(tmp_path):
    assert run(tmp_path, STATIC_FULL_PCPUS, None) == []


def test_quiet_when_everything_held_still_fits(tmp_path):
    # Only the 2 cpu pod is running: 12 are free less the reserved core
    state = dict(MEASURED_STATE, defaultCpuSet="0-4,6-12,14-15", entries={SMALL_UID: {"c": "5,13"}})

    assert run(tmp_path, STATIC_FULL_PCPUS, state) == []


def test_a_container_that_holds_exactly_what_is_free_is_kept(tmp_path):
    # 4 free after the reserved core, and a container holding 4
    state = dict(MEASURED_STATE, defaultCpuSet="0,6-8,14-15",
                 entries={BIG_UID: {"c": "1-2,9-10"}, SMALL_UID: {"c": "3-5,11-13"}})

    lines = run(tmp_path, STATIC_FULL_PCPUS, state)

    assert len(lines) == 1
    assert SMALL_UID in lines[0]


def test_the_siblings_of_a_reserved_cpu_are_not_free(tmp_path):
    # Reserving the thread 0 alone takes its sibling 8 too, as kubelet counts it
    config = dict(STATIC_FULL_PCPUS, reservedSystemCPUs="0")
    state = dict(MEASURED_STATE, defaultCpuSet="0,5-8,13-15", entries={BIG_UID: {"c": "1-4,9-12"}})

    lines = run(tmp_path, config, state)

    assert len(lines) == 1
    assert "find 6 free" in lines[0]


def test_without_named_reserved_cpus_counts_the_most_they_can_take(tmp_path):
    # systemReserved and kubeReserved add up to 1.5 cpus, so 2 reserved cpus that
    # may sit on 2 cores of 2 threads each
    config = dict(STATIC_FULL_PCPUS, systemReserved={"cpu": "1"}, kubeReserved={"cpu": "500m"})
    del config["reservedSystemCPUs"]
    state = dict(MEASURED_STATE, defaultCpuSet="0-3,8-11", entries={BIG_UID: {"c": "4-7,12-15"}})

    lines = run(tmp_path, config, state)

    assert len(lines) == 1
    assert "find 4 free" in lines[0]


def test_a_checkpoint_of_another_policy_is_not_a_restart(tmp_path):
    state = dict(MEASURED_STATE, policyName="none")

    assert run(tmp_path, STATIC_FULL_PCPUS, state) == []
