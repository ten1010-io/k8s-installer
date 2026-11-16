"""list-pci-devices.sh adds up the memory bars of every device it lists.

The bar column is what sizes the memory a guest handed a card needs on top of
its own: the vmm and the kernel keep page tables over those windows a page at a
time. So the number has to be the sum of the six bars and nothing else - not the
expansion rom, not the bars of the virtual functions that follow it in the
resource file, not an io port bar - and it has to come out as a quantity that can
be copied as it is.

Run as the playbook runs it, against a directory of fixtures standing in for
sysfs: PCI_DEVICES_PATH and NUMA_NODES_PATH are overridable for exactly this.
The slots are written with dashes rather than the colons sysfs uses, which
windows does not allow in a file name; the script prints the name it finds.
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
SCRIPT = REPO / "scripts" / "k8s-node" / "vfio-pci" / "list-pci-devices.sh"

BASH = os.environ.get("KI_TEST_BASH") or (shutil.which("bash") if sys.platform != "win32" else None)

pytestmark = pytest.mark.skipif(BASH is None, reason="needs a bash, named through KI_TEST_BASH on windows")

MEM_64_PREFETCH = 0x14220C
MEM_32 = 0x40200
IO = 0x40101
EMPTY = (0, 0, 0)

KI = 1 << 10
MI = 1 << 20
GI = 1 << 30


def region(start, size, flags):
    return (start, start + size - 1, flags)


# An L40S as the rig's GPU node reports it: bar0 16M (32 bit), bar1 64G and
# bar3 32M (64 bit, each taking two slots), the rom and the sr-iov bars empty
L40S = [
    region(0xB4000000, 16 * MI, MEM_32),
    region(0x240000000000, 64 * GI, MEM_64_PREFETCH),
    EMPTY,
    region(0x242000000000, 32 * MI, MEM_64_PREFETCH),
    EMPTY,
    EMPTY,
    EMPTY,
    EMPTY,
    EMPTY,
    EMPTY,
    EMPTY,
    EMPTY,
    EMPTY,
]


def write_device(root, slot, vendor, device, klass, regions, numa="0"):
    path = root / slot
    path.mkdir(parents=True)
    # sysfs ends its lines with a bare newline, and so must the fixtures on windows
    (path / "vendor").write_text(f"0x{vendor}\n", newline="\n")
    (path / "device").write_text(f"0x{device}\n", newline="\n")
    (path / "class").write_text(f"0x{klass}\n", newline="\n")
    (path / "numa_node").write_text(f"{numa}\n", newline="\n")
    if regions is not None:
        lines = "".join(f"0x{s:016x} 0x{e:016x} 0x{f:016x}\n" for s, e, f in regions)
        (path / "resource").write_text(lines, newline="\n")
    return path


def run(tmp_path):
    env = dict(os.environ, PCI_DEVICES_PATH=str(tmp_path / "pci"), NUMA_NODES_PATH=str(tmp_path / "numa"))
    result = subprocess.run([BASH, str(SCRIPT), "--node", "node1"], capture_output=True, text=True, env=env,
                            timeout=60)
    assert result.returncode == 0, result.stderr
    return {line.split()[1]: line for line in result.stdout.splitlines() if line.startswith("group[")}


def bar_of(line):
    return next(field for field in line.split() if field.startswith("bar["))


def test_a_gpu_is_the_sum_of_its_memory_bars_in_the_largest_exact_unit(tmp_path):
    write_device(tmp_path / "pci", "0000-4a-00.0", "10de", "26b9", "030200", L40S)

    assert bar_of(run(tmp_path)["0000-4a-00.0"]) == 'bar["65584Mi"]'


def test_a_single_bar_comes_out_in_its_own_unit(tmp_path):
    write_device(tmp_path / "pci", "0000-61-00.0", "10de", "2330", "030200",
                 [region(0x200000000000, 128 * GI, MEM_64_PREFETCH), EMPTY] + [EMPTY] * 11)

    assert bar_of(run(tmp_path)["0000-61-00.0"]) == 'bar["128Gi"]'


def test_the_rom_and_the_virtual_function_bars_are_not_counted(tmp_path):
    regions = [region(0xB4000000, 16 * MI, MEM_32)] + [EMPTY] * 5
    regions.append(region(0xB5000000, 512 * KI, 0x4E200))
    regions += [region(0x300000000000, 1 * GI, MEM_64_PREFETCH)] + [EMPTY] * 5
    write_device(tmp_path / "pci", "0000-37-00.0", "15b3", "101d", "020000", regions)

    assert bar_of(run(tmp_path)["0000-37-00.0"]) == 'bar["16Mi"]'


def test_an_io_port_bar_is_not_counted(tmp_path):
    regions = [region(0x3000, 0x20, IO), region(0xA0000000, 8 * KI, MEM_32)] + [EMPTY] * 11
    write_device(tmp_path / "pci", "0000-00-18.0", "8086", "1bf2", "010601", regions)

    assert bar_of(run(tmp_path)["0000-00-18.0"]) == 'bar["8Ki"]'


def test_a_sum_no_unit_divides_comes_out_in_bytes(tmp_path):
    regions = [region(0xA0000000, 8 * KI, MEM_32), region(0xA0002000, 0x100, MEM_32)] + [EMPTY] * 11
    write_device(tmp_path / "pci", "0000-00-19.0", "8086", "1bd2", "010601", regions)

    assert bar_of(run(tmp_path)["0000-00-19.0"]) == f'bar["{8 * KI + 0x100}"]'


def test_a_device_without_a_memory_bar_or_a_resource_file_is_unknown(tmp_path):
    write_device(tmp_path / "pci", "0000-00-00.0", "8086", "09a2", "088000", [EMPTY] * 13)
    write_device(tmp_path / "pci", "0000-00-00.1", "8086", "09a4", "088000", None)

    lines = run(tmp_path)

    assert bar_of(lines["0000-00-00.0"]) == 'bar["-"]'
    assert bar_of(lines["0000-00-00.1"]) == 'bar["-"]'


def test_the_driver_stays_the_last_column(tmp_path):
    write_device(tmp_path / "pci", "0000-4a-00.0", "10de", "26b9", "030200", L40S)

    assert run(tmp_path)["0000-4a-00.0"].split()[-1] == 'driver[""]'
