"""The archive the control node reads in place is the operator's, not a copy.

push-user-registry-artifacts.yml copies the archive to every ki cp node, pushes
it and deletes the copy. The control node skips the copy and reads the archive
where the operator put it, so on that node the path the playbook pushes from is
a file nobody may delete, and the path is only the right file when the node
really is the machine the run was started on.

Nothing here runs the playbook. The tasks are read and three things are held
to: what removes a file is skipped on the node that reads in place, the copy is
skipped there too, and reading in place asks for the same file rather than for
the same path.
"""
import yaml

from conftest import ANSIBLE

TASKS = ANSIBLE / "playbooks" / "tasks" / "push-user-registry-artifacts.yml"
NOT_IN_PLACE = "not (in_place | bool)"


def node_tasks():
    plays = yaml.safe_load(TASKS.read_text())
    (play,) = [play for play in plays if play["hosts"].startswith("ki_cp_node")]
    return play["tasks"]


def conditions(task):
    when = task.get("when", [])
    return when if isinstance(when, list) else [when]


def test_nothing_is_deleted_on_the_node_that_reads_in_place():
    removing = [task for task in node_tasks() if "rm " in str(task.get("shell", ""))]

    assert removing, "the task that deletes the copy was not found"
    for task in removing:
        assert NOT_IN_PLACE in conditions(task), task["name"]


def test_the_node_that_reads_in_place_is_given_no_copy():
    copying = [task for task in node_tasks() if "copy" in task]

    assert copying, "the task that copies the archive was not found"
    for task in copying:
        assert NOT_IN_PLACE in conditions(task), task["name"]


def test_reading_in_place_asks_for_the_same_file_not_the_same_path():
    (deciding,) = [task for task in node_tasks() if "in_place" in task.get("set_fact", {})]
    in_place = deciding["set_fact"]["in_place"]

    assert "inventory_hostname == ki_control_node_ih" in in_place
    assert "shell_result.rc" in in_place
    assert "archive_file_id" in in_place
