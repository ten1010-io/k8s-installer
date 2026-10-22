# shellcheck shell=bash
#
# Sourced by install-packages.sh and by setup-venv.sh, after the cli template of
# each, which is where msg and die come from. The ubuntu counterpart of
# rpm-common.sh, and it decides the same way plan-rpm-install.py does:
#
#   - a package the release declares, or one of kubernetes, goes in at its
#     version whatever the node holds, downgrade and all
#   - any other deb is a dependency, resolved against the GA image of the
#     ubuntu. A node of a later point release holds most of them newer, and the
#     node keeps those, together with every deb built from the same source
#     package, since those depend on each other at one exact version
#     (libssl-dev on libssl3, for one)
#   - a source is kept the other way round too, where the bundle would upgrade
#     one of its debs and the node holds another of the same source that the
#     bundle does not carry and that depends on a bundled one at exactly its
#     version. One that does not pin it that way holds nothing back
#   - what is installed at the version the bundle holds is not handed over
#
# Written in bash rather than reusing the python planner: an ubuntu node is not
# promised a python until setup-venv.sh has laid one down from these very debs.
#
# The plan is made once, over every deb the install is about to lay down, and
# the directories are then installed one by one from it. A plan made per
# directory is a different plan: the debs of one source package are kept
# together only when they are planned together, and python3.10 sits in one
# directory while python3.10-venv, which wants it at exactly its own version,
# sits in another. Planned alone, that one went in and dpkg refused it on the
# version the python of the node no longer has

# Package names the release declares. A deb under one of deb_principal_dirs is
# declared as well, which is how the packages of kubernetes are
deb_principals=()
deb_principal_dirs=()

# Names planned as if not installed, because the install removes them first
deb_assume_absent=()

# What deb_plan_install decided for each deb, by the path it was given as:
# "install", "skip", or "installed" once deb_install_planned has handed it over
declare -A deb_plan_action=()
declare -A deb_plan_reason=()

# How many debs the last deb_install_planned handed to dpkg
deb_installed_count=0

# The key a deb is planned under: its path made canonical, so that a directory
# may name it another way than the plan was given it and still find it
deb_plan_key() {
  realpath -m "$1"
}

deb_is_principal() {
  local name=$1
  local path=$2

  local principal
  for principal in "${deb_principals[@]}"; do
    [[ $principal = "$name" ]] && return 0
  done

  local dir
  local real
  real=$(realpath "$path")
  for dir in "${deb_principal_dirs[@]}"; do
    [[ $real = "$(realpath "$dir")"/* ]] && return 0
  done

  return 1
}

deb_is_assumed_absent() {
  local name=$1

  local absent
  for absent in "${deb_assume_absent[@]}"; do
    [[ $absent = "$name" ]] && return 0
  done

  return 1
}

# The package names a Depends or Pre-Depends field pins at exactly one version,
# "python3.10 (= 3.10.12-1~22.04.11)" among "libc6 (>= 2.34), python3.10 (=
# 3.10.12-1~22.04.11) | python3.10-full". Those are what an upgrade of the
# named package breaks; a loose bound survives it
deb_exact_depends() {
  local depends=$1

  local clauses=()
  IFS=',|' read -ra clauses <<< "$depends"

  # The name, an optional :arch, and "(=" after it. A regex in a variable, since
  # bash reads the parentheses of one written in place as its own
  local pin_re='^[[:space:]]*([^[:space:](:]+)(:[^[:space:](]+)?[[:space:]]*\(='
  local clause
  local pinned=""
  for clause in "${clauses[@]}"; do
    if [[ $clause =~ $pin_re ]]; then
      pinned+=" ${BASH_REMATCH[1]}"
    fi
  done

  echo "$pinned"

  return 0
}

# The version of a package the node has installed, or nothing. A package that
# was removed and kept its configuration is not installed
deb_installed_version() {
  local name=$1
  local arch=$2

  local query="$name"
  [[ $arch != "all" ]] && query="$name:$arch"

  local status
  local version
  IFS=$'\t' read -r status version < <(dpkg-query -W -f='${db:Status-Abbrev}\t${Version}\n' "$query" 2>/dev/null || true)
  [[ $status = ii* ]] && echo "$version"

  return 0
}

# One line per deb, tab separated: "install" or "skip", the path, and why.
# Every deb is read first, so that a source package kept for one of its debs is
# kept for all of them whichever order they come in. A path given twice is
# planned once, and the second one is a skip that names the first
deb_plan() {
  local paths=()
  local names=()
  local versions=()
  local sources=()
  local principals=()
  local states=()
  local installed_versions=()
  local again_paths=()
  local again_reasons=()
  local -A kept_sources=()
  local -A seen=()

  local path
  local fields
  local name
  local version
  local arch
  local source
  local installed
  local state
  for path in "$@"; do
    fields=$(dpkg-deb -W --showformat='${Package}\t${Version}\t${Architecture}\t${source:Package}\n' "$path") ||
      die "[ERROR] Failed to read deb[\"$path\"]"
    IFS=$'\t' read -r name version arch source <<< "$fields"
    [[ -z $source ]] && source=$name

    if [[ -n ${seen["$name|$version|$arch"]+x} ]]; then
      again_paths+=("$path")
      again_reasons+=("$name $version is planned as ${seen["$name|$version|$arch"]}")
      continue
    fi
    seen["$name|$version|$arch"]=$path

    installed=""
    deb_is_assumed_absent "$name" || installed=$(deb_installed_version "$name" "$arch")

    if [[ -z $installed ]]; then
      state="absent"
    elif dpkg --compare-versions "$installed" eq "$version"; then
      state="same"
    elif dpkg --compare-versions "$installed" gt "$version"; then
      state="newer"
    else
      state="older"
    fi

    paths+=("$path")
    names+=("$name")
    versions+=("$version")
    sources+=("$source")
    states+=("$state")
    installed_versions+=("$installed")
    if deb_is_principal "$name" "$path"; then
      principals+=("true")
    else
      principals+=("false")
      if [[ $state = "newer" && -z ${kept_sources["$source"]+x} ]]; then
        kept_sources["$source"]="the node holds $name $installed, newer than the bundle"
      fi
    fi
  done

  # The other way a source is kept: the bundle would upgrade one of its debs
  # while the node holds another one of the same source that the bundle does
  # not carry, which depends on one of the bundled names at exactly its old
  # version and which nothing would move along. One that depends on it loosely,
  # or not at all, is not broken by the upgrade and holds nothing back
  local -A in_bundle=()
  local i
  for i in "${!paths[@]}"; do
    in_bundle["${sources[$i]}|${names[$i]}"]=1
  done

  local -A node_by_source=()
  local -A node_pins=()
  local node_source
  local node_name
  local node_status
  local node_depends
  while IFS=$'\t' read -r node_source node_name node_status node_depends; do
    [[ $node_status = ii* ]] || continue
    [[ -z $node_source ]] && node_source=$node_name
    deb_is_assumed_absent "$node_name" && continue
    node_by_source["$node_source"]+=" $node_name"
    node_pins["$node_name"]=$(deb_exact_depends "$node_depends")
  done < <(dpkg-query -W -f='${source:Package}\t${Package}\t${db:Status-Abbrev}\t${Pre-Depends}, ${Depends}\n' 2>/dev/null || true)

  local stranded
  local pinned
  for i in "${!paths[@]}"; do
    [[ ${principals[$i]} = "true" || ${states[$i]} != "older" ]] && continue
    [[ -n ${kept_sources["${sources[$i]}"]+x} ]] && continue
    stranded=""
    for node_name in ${node_by_source["${sources[$i]}"]-}; do
      [[ -n ${in_bundle["${sources[$i]}|$node_name"]+x} ]] && continue
      for pinned in ${node_pins["$node_name"]-}; do
        if [[ -n ${in_bundle["${sources[$i]}|$pinned"]+x} ]]; then
          stranded+=" $node_name"
          break
        fi
      done
    done
    if [[ -n $stranded ]]; then
      kept_sources["${sources[$i]}"]="upgrading ${names[$i]} past ${installed_versions[$i]} would leave${stranded} of the node, which the bundle does not carry, pinned to the old version"
    fi
  done

  for i in "${!paths[@]}"; do
    name=${names[$i]}
    version=${versions[$i]}
    if [[ ${states[$i]} = "same" ]]; then
      printf 'skip\t%s\t%s\n' "${paths[$i]}" "$name $version is installed"
    elif [[ ${principals[$i]} = "true" ]]; then
      printf 'install\t%s\t%s\n' "${paths[$i]}" "declared by the release"
    elif [[ ${states[$i]} = "newer" ]]; then
      printf 'skip\t%s\t%s\n' "${paths[$i]}" "the node holds $name ${installed_versions[$i]}, newer than $version"
    elif [[ -n ${kept_sources["${sources[$i]}"]+x} ]]; then
      printf 'skip\t%s\t%s\n' "${paths[$i]}" "source ${sources[$i]} is kept: ${kept_sources["${sources[$i]}"]}"
    else
      if [[ ${states[$i]} = "absent" ]]; then
        printf 'install\t%s\t%s\n' "${paths[$i]}" "not installed"
      else
        printf 'install\t%s\t%s\n' "${paths[$i]}" "upgrades ${installed_versions[$i]}"
      fi
    fi
  done
  for i in "${!again_paths[@]}"; do
    printf 'skip\t%s\t%s\n' "${again_paths[$i]}" "${again_reasons[$i]}"
  done

  return 0
}

# Every deb under a directory, the way dpkg -R reads it
deb_files_of() {
  local dir=$1

  [[ -d $dir ]] || return 0
  find "$dir" -type f -name '*.deb' | sort
}

# Plans an install: every deb of it at once, whichever directory each is in.
#
#   deb_plan_install <deb files>
#
# Made after the install has removed what it removes, so that the node is
# planned as it is rather than as it was
deb_plan_install() {
  deb_plan_action=()
  deb_plan_reason=()

  [[ $# -eq 0 ]] && return 0

  local plan
  plan=$(deb_plan "$@")

  local action
  local path
  local reason
  local key
  while IFS=$'\t' read -r action path reason; do
    [[ -z $action ]] && continue
    key=$(deb_plan_key "$path")
    deb_plan_action["$key"]=$action
    deb_plan_reason["$key"]=$reason
  done <<< "$plan"

  return 0
}

# What is already installed at the bundled version goes by in silence: an
# update finds most of the bundle that way, and the lines that matter would
# drown among them. A copy of a deb that another directory also holds says
# which directory hands it over. The rest is the node keeping its own, and why
deb_say_skipped() {
  local path=$1
  local reason=$2

  case $reason in
    *" is installed") ;;
    *" is planned as "*) msg "[INFO] $(basename "$path") is handed over with another directory: $reason" ;;
    *) msg "[INFO] Keeping what the node holds instead of $(basename "$path"): $reason" ;;
  esac

  return 0
}

# Installs the debs of one directory that the plan says go in.
#
#   deb_install_planned <label> [dpkg options] -- <deb files>
deb_install_planned() {
  local label=$1
  shift

  local dpkg_opts=()
  while [[ $# -gt 0 && $1 != "--" ]]; do
    dpkg_opts+=("$1")
    shift
  done
  shift

  local to_install=()
  local path
  local key
  for path in "$@"; do
    key=$(deb_plan_key "$path")
    case ${deb_plan_action["$key"]-} in
      install)
        to_install+=("$path")
        ;;
      skip)
        deb_say_skipped "$path" "${deb_plan_reason["$key"]}"
        ;;
      installed)
        ;;
      *)
        die "[ERROR] deb[\"$path\"] was not planned. deb_plan_install is given every deb before any directory is installed"
        ;;
    esac
  done

  deb_installed_count=${#to_install[@]}
  if [[ $deb_installed_count = 0 ]]; then
    msg "[INFO] Nothing of [\"$label\"] to install"
    return 0
  fi

  dpkg -i "${dpkg_opts[@]}" "${to_install[@]}"

  for path in "${to_install[@]}"; do
    deb_plan_action["$(deb_plan_key "$path")"]="installed"
  done

  return 0
}

# Plans and installs one set of debs that is the whole of an install.
#
#   deb_install_files <label> [dpkg options] -- <deb files>
deb_install_files() {
  local label=$1
  shift

  local dpkg_opts=()
  while [[ $# -gt 0 && $1 != "--" ]]; do
    dpkg_opts+=("$1")
    shift
  done
  shift

  deb_plan_install "$@"
  deb_install_planned "$label" "${dpkg_opts[@]}" -- "$@"

  return 0
}

# Plans every directory of an install at once, as the node will be once the
# names given are removed, and has apt simulate it without changing anything.
#
#   deb_require_installable <removed name>... -- <deb files>
#
# apt rather than dpkg, because apt is what says what a transaction would take
# away: handed debs that break a package of the node, it plans to remove that
# package, where dpkg would stop half way. A removal the install did not ask
# for, or a dependency nothing here satisfies, refuses the node while it is
# still untouched
deb_require_installable() {
  local removed=()
  while [[ $# -gt 0 && $1 != "--" ]]; do
    removed+=("$1")
    shift
  done
  shift

  [[ $# -eq 0 ]] && return 0

  local saved_absent=("${deb_assume_absent[@]}")
  deb_assume_absent=("${removed[@]}")
  local plan
  plan=$(deb_plan "$@")
  deb_assume_absent=("${saved_absent[@]}")

  local to_install=()
  local action
  local path
  local reason
  while IFS=$'\t' read -r action path reason; do
    [[ $action = "install" ]] && to_install+=("$(realpath "$path")")
  done <<< "$plan"

  [[ ${#to_install[@]} = 0 ]] && return 0

  # Only what is installed is named for removal. apt fails on a name it can not
  # find, and an air gapped node has no package lists to find the others in
  local removals=()
  local name
  for name in "${removed[@]}"; do
    if [[ $(dpkg-query -W -f='${db:Status-Abbrev}' "$name" 2>/dev/null || true) = ii* ]]; then
      removals+=("$name-")
    fi
  done

  local output
  output=$(apt-get -s -q --allow-downgrades --allow-change-held-packages \
    -o Debug::NoLocking=1 install "${to_install[@]}" "${removals[@]}" 2>&1) ||
    die "[ERROR] apt refuses the packages of the bundle on this node. Nothing was changed:\n$output"

  local removed_pattern
  removed_pattern=$(IFS='|'; echo "${removed[*]}")
  local unexpected
  unexpected=$(grep -E '^Remv ' <<< "$output" | grep -Ev "^Remv (${removed_pattern})[ :]" || true)
  [[ -z $unexpected ]] && return 0

  die "[ERROR] Installing the bundle would remove packages of this node. Nothing was changed:\n$unexpected\nThose depend on a version of something the bundle replaces. Remove them if the node does not need them"
}
