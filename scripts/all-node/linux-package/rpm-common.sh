# shellcheck shell=bash
#
# Sourced by install-packages.sh and by setup-venv.sh, after the cli template of
# each, which is where msg and die come from. Both lay the rpms of the bundle
# onto a node, and both have to agree on which of them the node keeps instead:
# plan-rpm-install.py says why, and the reasons are printed with the install.
#
# The plan is made once, over every rpm the install is about to lay down, and
# the directories are then installed one by one from it. A plan made per
# directory is a different plan: the packages of one source rpm are kept
# together only when they are planned together, and the library a node holds
# newer sits in an early directory while the devel package built with it sits
# in the last one. Planned alone, that one went in and rpm refused it on the
# version the library of the node no longer has

RPM_COMMON_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
RPM_PLANNER_PATH="$RPM_COMMON_DIR_PATH/plan-rpm-install.py"

# What rpm_plan_install decided for each rpm, by the path it was given as:
# "install", "skip", or "installed" once rpm_install_planned has handed it over
declare -A rpm_plan_action=()
declare -A rpm_plan_reason=()

# How many rpms the last rpm_install_planned handed to rpm. setup scripts read
# it to skip what only matters when something was installed, such as
# re-executing systemd after its own package
rpm_installed_count=0

# The python of the os rather than the one of the venv, which may not exist yet
# and has no rpm module either. dnf is written in python and runs on the rpm
# module, so every rhel this supports has one: platform-python on 8, python3 on
# 9 and 10
rpm_python() {
  local candidate
  for candidate in /usr/libexec/platform-python /usr/bin/python3; do
    [[ -x $candidate ]] || continue
    "$candidate" -c "import rpm" &>/dev/null || continue
    echo "$candidate"
    return 0
  done

  die "[ERROR] No python with the rpm module on this node, which the package plan is made with. dnf needs one, so this node has none of python3-rpm or platform-python"
}

# plan-rpm-install.py over files. Arguments up to "--" go to the planner as they
# are, the files after it
rpm_plan() {
  local planner_args=()
  while [[ $# -gt 0 && $1 != "--" ]]; do
    planner_args+=("$1")
    shift
  done
  shift

  [[ $# -eq 0 ]] && return 0

  "$(rpm_python)" "$RPM_PLANNER_PATH" "${planner_args[@]}" "$@"
}

# Plans an install: every rpm of it at once, whichever directory each is in.
#
#   rpm_plan_install [planner args] -- <rpm files>
#
# Made after the install has erased what it erases, so that what dnf took away
# with them is planned as absent rather than as the node holding it
rpm_plan_install() {
  rpm_plan_action=()
  rpm_plan_reason=()

  local plan
  plan=$(rpm_plan "$@") || die "[ERROR] Failed to plan the rpms of the bundle"

  local action
  local path
  local reason
  while IFS=$'\t' read -r action path reason; do
    [[ -z $action ]] && continue
    rpm_plan_action["$path"]=$action
    rpm_plan_reason["$path"]=$reason
  done <<< "$plan"

  return 0
}

# Installs the rpms of one directory that the plan says go in, after rpm has
# said the transaction holds.
#
#   rpm_install_planned <label> <rpm files>
#
# --force is what --oldpackage and --replacepkgs were before: a package the
# release declares goes in at its version even where the node holds another.
# The dependencies that would have been downgraded by it are no longer in the
# list
rpm_install_planned() {
  local label=$1
  shift

  local to_install=()
  local path
  for path in "$@"; do
    case ${rpm_plan_action["$path"]-} in
      install)
        to_install+=("$path")
        ;;
      skip)
        msg "[INFO] Keeping what the node holds instead of $(basename "$path"): ${rpm_plan_reason["$path"]}"
        ;;
      installed)
        ;;
      *)
        die "[ERROR] rpm[\"$path\"] was not planned. rpm_plan_install is given every rpm before any directory is installed"
        ;;
    esac
  done

  rpm_installed_count=${#to_install[@]}
  [[ $rpm_installed_count = 0 ]] && return 0

  local test_output
  test_output=$(rpm -Uvh --test --force "${to_install[@]}" 2>&1) ||
    die "[ERROR] rpm refuses the packages of [\"$label\"] on this node, and nothing of them was installed:\n$test_output"

  rpm -Uvh --force "${to_install[@]}"

  for path in "${to_install[@]}"; do
    rpm_plan_action["$path"]="installed"
  done

  return 0
}

# Plans and installs one set of rpms that is the whole of an install, which is
# what setup-venv.sh lays down: one directory, planned as itself.
#
#   rpm_install_files <label> [planner args] -- <rpm files>
rpm_install_files() {
  local label=$1
  shift

  rpm_plan_install "$@"

  while [[ $# -gt 0 && $1 != "--" ]]; do
    shift
  done
  shift

  rpm_install_planned "$label" "$@"

  return 0
}

# Plans every directory of an install at once, as the node will be once the
# names given are erased, and has rpm try the result without changing anything.
#
#   rpm_require_installable <erased name>... -- [planner args] -- <rpm files>
#
# The install erases packages before it lays anything down, chrony among them,
# and a refusal that comes after that leaves a node with no time service. So
# the refusal comes first. What rpm reports about a package that is about to be
# erased is left out: that is the erase doing what it is for
rpm_require_installable() {
  local erased=()
  while [[ $# -gt 0 && $1 != "--" ]]; do
    erased+=("$1")
    shift
  done
  shift

  local assume_args=()
  local name
  for name in "${erased[@]}"; do
    assume_args+=(--assume-absent "$name")
  done

  local plan
  plan=$(rpm_plan "${assume_args[@]}" "$@") || die "[ERROR] Failed to plan the rpms of the bundle"

  local to_install=()
  local action
  local path
  local reason
  while IFS=$'\t' read -r action path reason; do
    [[ $action = "install" ]] && to_install+=("$path")
  done <<< "$plan"

  [[ ${#to_install[@]} = 0 ]] && return 0

  local test_output
  test_output=$(rpm -Uvh --test --force "${to_install[@]}" 2>&1) && return 0

  local erased_pattern
  erased_pattern=$(IFS='|'; echo "${erased[*]}")
  local problems
  problems=$(grep -E $'^\t' <<< "$test_output" | grep -Ev "(^|[[:space:](])(${erased_pattern})([-[:space:]]|$)" || true)
  [[ -z $problems ]] && return 0

  die "[ERROR] rpm refuses the packages of the bundle on this node. Nothing was changed:\n$problems\nA package listed as \"needed by (installed)\" is one this node holds that the bundle would break. Remove it if the node does not need it, or install it at the version it asks for"
}
