"""A file carried between the control node and a node is not one file on both.

The playbooks move small files with fetch and copy: fetch reads one off a node
as root and writes it on the control node as the user ansible runs as, and copy
reads that as the same user and lays it down on a node as root. Both name two
paths, one on each machine, and the control node is itself a node of the
inventory. So two paths that are spelled the same are the same file whenever the
node being handled is the control node, and each module then does something
other than what its task says.

A fetch onto its own source finds the file already there with the right content
and writes nothing, so it stays root's rather than becoming the user's. A copy
onto its own source rewrites nothing either and applies the mode it was given,
to the file it is still reading for every node after this one. Together they
closed the join credentials to the user ansible runs as on a control node that
is also the first k8s cp node, and whichever node was handled after it failed
with "Permission denied" - only when it was handled after, which made it a
matter of timing and let it through more often than not.

Nothing here runs a playbook. The paths are rendered from group_vars, the way
conftest.py renders them for the validator, and compared: two variables that
resolve to one path are caught the same as one variable written twice.
"""
import yaml
from jinja2 import ChainableUndefined, Environment, TemplateError

from conftest import ANSIBLE

PLAYBOOKS = ANSIBLE / "playbooks"

FETCH = {"fetch", "ansible.builtin.fetch"}
COPY = {"copy", "ansible.builtin.copy"}

# What init-k8s-cluster.yml did with the join credentials before the two paths
# were named apart, kept so that the check below is known to see it
OLD_SHAPE = """
- hosts: localhost
  tasks:
    - name: Copy join-credentials.yml to ansible control node
      fetch:
        src: "{{ ki_tmp_join_credentials_path }}"
        dest: "{{ ki_tmp_join_credentials_path }}"
        flat: yes
      become: yes
      delegate_to: "{{ k8s_cp_nodes | first }}"

- hosts: k8s_node:!broken_node
  tasks:
    - block:
        - name: Copy join-credentials.yml to the node
          copy:
            src: "{{ ki_tmp_join_credentials_path }}"
            dest: "{{ ki_tmp_join_credentials_path }}"
            mode: "0600"
          become: yes
"""


def walk_tasks(tasks):
    """Every task of a list, with the ones a block holds in any of its sections."""
    for task in tasks or []:
        yield task
        for section in ("block", "rescue", "always"):
            yield from walk_tasks(task.get(section))


def transfers(plays):
    """The fetch and copy tasks of a playbook that name a file on both sides.

    A copy that carries its content inline reads nothing on the control node,
    so it is not one of them. The variables a play or a task declares for
    itself come along, since a path is as likely to be spelled with one of
    those as with one of group_vars.
    """
    for play in plays or []:
        for section in ("pre_tasks", "tasks", "post_tasks", "handlers"):
            for task in walk_tasks(play.get(section)):
                for module in FETCH | COPY:
                    args = task.get(module)
                    if isinstance(args, dict) and "src" in args and "dest" in args:
                        yield task, module, args, {**play.get("vars", {}), **task.get("vars", {})}


class Unresolved(ChainableUndefined):
    """What only exists while a play runs, rendered as its own name.

    The item of a loop and a variable given on the command line are not known
    here. Rendered empty, as jinja2 would, two paths made of nothing else would
    come out equal, and a snapshot the operator names would look like it was
    copied onto itself.
    """

    def __str__(self):
        return f"<{self._undefined_name}>"


def render(value, variables):
    """A path as ansible would resolve it, as far as group_vars can say.

    Rendered until it stops changing, since a variable of a play is usually
    written in terms of one of group_vars. A filter jinja2 does not have is one
    of ansible's, and the path is then compared as it is written.
    """
    environment = Environment(undefined=Unresolved)
    rendered = str(value)
    try:
        for _ in range(8):
            if "{{" not in rendered:
                break
            rendered = environment.from_string(rendered).render(**variables)
    except TemplateError:
        pass

    return rendered


def closes_its_source(args):
    """Whether a copy leaves what it wrote unreadable to someone who is not its owner.

    A mode that is itself a template is not known here, and is taken to.
    """
    if "mode" not in args:
        return False

    try:
        return int(str(args["mode"]), 8) & 0o004 == 0
    except ValueError:
        return True


def violations(plays, variables, *, where):
    found = []
    for task, module, args, declared in transfers(plays):
        scope = {**variables, **declared}
        src, dest = render(args["src"], scope), render(args["dest"], scope)
        if src != dest:
            continue

        name = task.get("name", "<unnamed>")
        if module in FETCH:
            found.append(
                f"{where}: task \"{name}\" fetches \"{src}\" onto the path it reads it from. "
                f"On a control node that is also the node it is fetched from that writes nothing, "
                f"and the file stays root's rather than becoming the user's")
        elif closes_its_source(args):
            found.append(
                f"{where}: task \"{name}\" copies \"{src}\" onto the path it reads it from, "
                f"with mode {args['mode']}. On a control node that is also a target that closes "
                f"the source to the user ansible runs as, and the nodes after it can not read it")

    return found


def playbooks():
    paths = sorted(PLAYBOOKS.rglob("*.yml"))
    assert paths, f"No playbook was found under {PLAYBOOKS}"

    return [(path, yaml.safe_load(path.read_text(encoding="utf-8"))) for path in paths]


def test_the_old_shape_is_caught(hostvars):
    found = violations(yaml.safe_load(OLD_SHAPE), hostvars["node1"], where="old")

    assert len(found) == 2, found
    assert "fetches" in found[0] and "copies" in found[1], found


def test_no_transfer_names_one_path_for_both_sides(hostvars):
    found = []
    for path, plays in playbooks():
        found += violations(plays, hostvars["node1"], where=path.relative_to(ANSIBLE).as_posix())

    assert not found, "\n".join(found)


def test_the_join_credentials_are_handed_out_from_a_path_of_their_own(hostvars):
    """The two playbooks that carry them, looked at by name.

    The test above would pass over a playbook it could no longer read the
    transfers of, so this says what they are: read off the node at the path a
    node keeps them at, written on the control node at the other one, and laid
    down on a node from there as root's alone.
    """
    node = hostvars["node1"]
    node_path = node["ki_tmp_join_credentials_path"]
    control_node_path = node["ki_tmp_join_credentials_src_path"]
    assert node_path != control_node_path

    for name in ("init-k8s-cluster.yml", "add-k8s-node.yml"):
        plays = yaml.safe_load((PLAYBOOKS / "tasks" / name).read_text(encoding="utf-8"))
        seen = {
            module: (render(args["src"], node), render(args["dest"], node), str(args.get("mode")))
            for _, module, args, _ in transfers(plays)
        }

        assert seen == {
            "fetch": (node_path, control_node_path, "None"),
            "copy": (control_node_path, node_path, "0600"),
        }, f"{name}: {seen}"
