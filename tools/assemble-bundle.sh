#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--out-path path] [--write-sha256]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--out-path      Where to write the archive, defaults to bundle-<version>.tgz beside this tree, which
                is where download-bundle.sh would have put it
--write-sha256  Record the sha256 of the archive as bundle_sha256 of release.yml. Only a release
                takes it, since a snapshot leaves the field empty
EOF
  exit
}

parse_params() {
  out_path=""
  write_sha256="false"

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --out-path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      out_path="${2-}"
      shift
      ;;
    --write-sha256) write_sha256="true" ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  return 0
}

setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  [[ -n ${out_path-} ]] && rm -f "$out_path.part"

  return 0
}

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT
setup_colors
parse_params "$@"

# --- End of CLI template ---

# Makes the archive a release publishes out of the bundle/ directory of this
# tree, which is the directory the other build tools fill, and says what its
# sha256 is.
#
# Everything the release declares is looked for first and nothing is packed
# until all of it is there. The node scripts check the same things one node
# at a time, which is the most expensive place to learn that a directory was
# never filled: a bundle short of one operating system installs fine on the
# other four. So what is missing is listed in full and the archive is not
# made.
#
# The archive is made the same way from the same content every time: entries
# sorted, timestamps and ownership fixed, and gzip told to write no name and
# no time. Two runs over one bundle/ therefore give one sha256, which is what
# lets the sha256 written to release.yml be checked against a rebuild of the
# same directory instead of being a number nobody can reproduce. It is the
# same tool that makes the archive and says its sha256 for the same reason:
# the number is of the file this made, not of whatever was lying there
KI_ROOT_PATH=$(cd "$SCRIPT_DIR_PATH/.." &>/dev/null && pwd -P)
BUNDLE_PATH="$KI_ROOT_PATH"/bundle
YQ_CMD="$BUNDLE_PATH"/bin/$(uname -m)/yq
RELEASE_META_PATH="$KI_ROOT_PATH"/release.yml
CONSTANT_VARS_PATH="$KI_ROOT_PATH"/ansible/group_vars/all/constant-vars.yml
SETUP_VENV_PATH="$KI_ROOT_PATH"/scripts/setup-venv.sh

# Kept in sync with ki_release_snapshot_suffix of group_vars/all/constant-vars.yml
SNAPSHOT_SUFFIX="-SNAPSHOT"

K8S_PACKAGE_NAMES=(kubeadm kubelet kubectl cri-tools kubernetes-cni)

# shellcheck source=../scripts/all-node/linux-bin/linux-bin-common.sh
source "$SCRIPT_DIR_PATH/../scripts/all-node/linux-bin/linux-bin-common.sh"
# shellcheck source=arch-common.sh
source "$SCRIPT_DIR_PATH/arch-common.sh"

version=""
missing=()
# What release.yml declares the bundle is built for, read by check_architectures:
# the operating systems with the architectures each is carried for, as uname -m
# names them, and the architectures of the whole bundle, which are every name
# that appears
architectures=()
oses=()
declare -A arches_of_os

main() {
  require_tree

  version=$($YQ_CMD '.version' < "$RELEASE_META_PATH")
  [[ -z $version || $version = "null" ]] && die "[ERROR] File[\"$RELEASE_META_PATH\"] has no version"
  [[ -z $out_path ]] && out_path="$KI_ROOT_PATH/bundle-$version.tgz"
  [[ -e $out_path ]] && die "[ERROR] File[\"$out_path\"] already exists. a bundle is made once, so remove it if it is not the one"
  [[ $write_sha256 = "true" && $(is_snapshot "$version") = "true" ]] &&
    die "[ERROR] Release[\"$version\"] is a snapshot, and a snapshot leaves bundle_sha256 empty: its bundle is republished under the same name, so there is no one value to write"

  check_architectures

  msg "[INFO] Checking \"$BUNDLE_PATH\" against what release[\"$version\"] declares"
  check_linux_packages
  check_binaries
  check_service_images
  check_registry_images
  check_python_packages
  report_missing

  make_archive

  local sha256
  sha256=$(sha256sum "$out_path" | cut -d' ' -f1)
  msg ""
  msg "[INFO] Bundle of release[\"$version\"] written to \"$out_path\" ($(du -h "$out_path" | cut -f1))"
  msg "[INFO] sha256: $sha256"

  record_sha256 "$sha256"

  return 0
}

require_tree() {
  [[ ! -d $BUNDLE_PATH ]] && die "[ERROR] Directory[\"$BUNDLE_PATH\"] not exists. this runs on the machine that builds the bundle, where the other tools of this directory have filled it"
  [[ ! -x $YQ_CMD ]] && die "[ERROR] File[\"$YQ_CMD\"] not exists or is not executable. run fetch-bundle-binaries.sh first"
  [[ ! -f $RELEASE_META_PATH ]] && die "[ERROR] No such file or directory of which path is \"$RELEASE_META_PATH\""
  [[ ! -f $CONSTANT_VARS_PATH ]] && die "[ERROR] No such file or directory of which path is \"$CONSTANT_VARS_PATH\""
  [[ ! -f $SETUP_VENV_PATH ]] && die "[ERROR] No such file or directory of which path is \"$SETUP_VENV_PATH\""

  return 0
}

# What release.yml says the bundle is built for, which every check below walks:
# the operating systems with the architectures each is carried for, and the
# architectures of the whole bundle, which are every name that appears. Each
# name has to be one this installer has names for elsewhere (arch-common.sh),
# since a name nothing knows is a directory nothing will have filled
check_architectures() {
  local os arch
  while read -r os; do
    [[ -z $os ]] && continue
    oses+=("$os")
    arches_of_os[$os]=$($YQ_CMD ".architectures[\"$os\"] | join(\" \")" < "$RELEASE_META_PATH")
    [[ -z ${arches_of_os[$os]} ]] && die "[ERROR] Release[\"$version\"] carries os[\"$os\"] for no architecture. architectures lists at least one per os"
    for arch in ${arches_of_os[$os]}; do
      oci_arch_of "$arch" >/dev/null || die "[ERROR] Release[\"$version\"] carries os[\"$os\"] for architecture[\"$arch\"], which this installer does not know. architectures takes x86_64 and aarch64"
      [[ " ${architectures[*]} " = *" $arch "* ]] || architectures+=("$arch")
    done
  done < <($YQ_CMD '.architectures // {} | keys | .[]' < "$RELEASE_META_PATH")
  [[ ${#oses[@]} = 0 ]] && die "[ERROR] File[\"$RELEASE_META_PATH\"] declares no architectures, so nothing says which operating systems the bundle carries for which architecture"

  return 0
}

is_snapshot() {
  if [[ ${1-} == *"$SNAPSHOT_SUFFIX" ]]; then echo "true"; else echo "false"; fi
}

# Every operating system, for every architecture it is carried for: the closure
# directories hold something, the kubernetes packages of every minor of the
# window are there at the pinned patch, and every package release.yml declares
# is there at the declared version. The kernel of rhel 10 besides, since
# setup-kernel.sh reads that directory on a node whose kernel lacks the modules.
#
# Versions are read off the file names rather than out of the files, since
# rpm is not on an ubuntu machine and dpkg-deb not on a rhel one, and the
# names are what the repositories wrote: name-version-release.arch.rpm and
# name_[epoch%3a]version-revision_arch.deb
check_linux_packages() {
  local os arch ext minor patch name version
  for os in "${oses[@]}"; do
    case $os in
    rhel*) ext=rpm ;;
    *) ext=deb ;;
    esac
    for arch in ${arches_of_os[$os]}; do
      local dir="linux-packages/$os/$arch"
      local base="$BUNDLE_PATH/$dir"

      if [[ -z $(find "$base" -maxdepth 2 -name "*.$ext" -print -quit 2>/dev/null) ]]; then
        missing+=("$dir: no $ext at all. run build-bundle-packages.sh --os $os on a machine of its oldest release and of $arch")
        continue
      fi

      for minor in $(k8s_minors); do
        patch=$(k8s_patch_of "$minor")
        for name in "${K8S_PACKAGE_NAMES[@]}"; do
          case $name in
          kubeadm | kubelet | kubectl) version=$patch ;;
          *) version="" ;;
          esac
          has_package "$base/k8s/$minor" "$name" "$version" "$ext" ||
            missing+=("$dir/k8s/$minor: no $name${version:+ $version}")
        done
      done

      while read -r name version; do
        [[ -z $name ]] && continue
        has_package "$base/*" "$name" "$version" "$ext" ||
          missing+=("$dir: no $name $version, which release.yml declares under packages")
      done < <($YQ_CMD '.packages | to_entries | .[] | .key + " " + .value' < "$RELEASE_META_PATH")

      [[ $os = "rhel10" ]] && ! has_package "$base/kernel" kernel-core "" rpm &&
        missing+=("$dir/kernel: no kernel-core, which setup-kernel.sh lays down on a node that can not load the modules")
    done
  done

  return 0
}

# Whether a directory, or a glob of directories, holds a package file of a
# name, at a version when one is given. The version is the upstream one, which
# both file names carry followed by a dash; a deb may carry an epoch before
# it, written as %3a. The packages release.yml declares sit one directory
# down, in whichever directory the closure placed them, which is what the
# glob is for
has_package() {
  local dir=$1 name=$2 version=$3 ext=$4

  if [[ -z $version ]]; then
    compgen -G "$dir/$name"[-_][0-9]"*.$ext" >/dev/null
    return $?
  fi

  compgen -G "$dir/$name"[-_]"$version-*.$ext" >/dev/null && return 0
  compgen -G "$dir/${name}_*%3a$version-*.$ext" >/dev/null && return 0

  return 1
}

k8s_minors() {
  $YQ_CMD '.k8s_versions | keys | .[]' < "$RELEASE_META_PATH"

  return 0
}

k8s_patch_of() {
  local minor=$1

  $YQ_CMD ".k8s_versions[\"$minor\"].kubernetes" < "$RELEASE_META_PATH" | sed 's/^v//'

  return 0
}

# Each binary of each architecture is asked which version it is, with the code
# the node asks it with, since the name of the file says nothing about which
# build it holds. Asking means running it, so a bundle of two architectures is
# assembled on a machine that can run both: natively one, and the other through
# a user mode emulator the kernel knows about. A machine that can run neither
# the binaries of an architecture nor an emulator for them can not check them,
# and says so rather than packing what it could not ask
check_binaries() {
  local arch name version found
  for arch in "${architectures[@]}"; do
    local dir="bin/$arch"
    if ! can_run_arch "$arch"; then
      missing+=("$dir: this machine is $(uname -m) and can not run $arch binaries to ask their versions. assemble on a machine that can, or register qemu-user-static with binfmt_misc")
      continue
    fi
    while read -r name version; do
      [[ -z $name ]] && continue
      if [[ ! -x "$BUNDLE_PATH/$dir/$name" ]]; then
        missing+=("$dir/$name: not there or not executable. run fetch-bundle-binaries.sh --arch $arch")
        continue
      fi
      found=$(binary_version "$BUNDLE_PATH/$dir" "$name")
      [[ $found = "$version" ]] ||
        missing+=("$dir/$name: version[\"${found:-unknown}\"] where release.yml declares version[\"$version\"]")
    done < <($YQ_CMD '.binaries | to_entries | .[] | .key + " " + .value' < "$RELEASE_META_PATH")
  done

  return 0
}

# One tar per service constant-vars.yml declares an image for, per
# architecture, named the way build-bundle-images.sh names them
check_service_images() {
  local arch var svc_name
  for arch in "${architectures[@]}"; do
    for var in $($YQ_CMD 'keys | .[] | select(test("^ki_cp_.+_image$"))' < "$CONSTANT_VARS_PATH"); do
      svc_name=$(sed -e 's/_image$//' -e 's/_/-/g' <<< "$var")
      [[ -f "$BUNDLE_PATH/ki-cp-service-images/$arch/$svc_name.tar" ]] ||
        missing+=("ki-cp-service-images/$arch/$svc_name.tar: not there. run build-bundle-images.sh")
    done
  done

  return 0
}

# One directory per minor holding oci layouts, among them the pause of that
# minor, which is the one image release.yml names and the one a node can not
# start anything without. Each layout holds one entry, an index, and that index
# has to list a manifest for every architecture the bundle is built for: a
# layout pulled for one architecture pushes fine and serves a tag the nodes of
# the other can not pull, which is a node where nothing starts
check_registry_images() {
  local minor pause dir layout
  for minor in $(k8s_minors); do
    dir="$BUNDLE_PATH/ki-cp-k8s-registry-images/$minor"
    if [[ -z $(find "$dir" -name oci-layout -print -quit 2>/dev/null) ]]; then
      missing+=("ki-cp-k8s-registry-images/$minor: no image. run build-bundle-images.sh")
      continue
    fi
    pause=$($YQ_CMD ".k8s_versions[\"$minor\"].pause" < "$RELEASE_META_PATH")
    [[ -n $(find "$dir" -type d -name "pause:$pause" -print -quit) ]] ||
      missing+=("ki-cp-k8s-registry-images/$minor: no pause:$pause, which release.yml names for kubernetes $minor")

    for layout in $(find "$dir" -name oci-layout -printf '%h\n' | sort); do
      check_layout_platforms "$layout"
    done
  done

  return 0
}

# The platforms the index of a layout lists, against the architectures of the
# release, by the names the registries use
check_layout_platforms() {
  local layout=$1
  local ref=${layout#"$BUNDLE_PATH"/}

  local digest
  digest=$($YQ_CMD -p json -o yaml '.manifests[0].digest' < "$layout/index.json")
  [[ $digest = sha256:* ]] || { missing+=("$ref: index.json names no manifest. run build-bundle-images.sh"); return 0; }
  local index="$layout/blobs/sha256/${digest#sha256:}"
  [[ -f $index ]] || { missing+=("$ref: the index it names is not among its blobs. run build-bundle-images.sh"); return 0; }

  local listed
  listed=$($YQ_CMD -p json -o yaml '[.manifests[].platform.architecture] | join(" ")' < "$index")
  local arch oci
  for arch in "${architectures[@]}"; do
    oci=$(oci_arch_of "$arch")
    [[ " $listed " = *" $oci "* ]] ||
      missing+=("$ref: no manifest for $arch ($oci) in its index, which lists [$listed]. run build-bundle-images.sh")
  done

  return 0
}

# The wheel directories setup-venv.sh installs from, read off that script so
# that a python or a project added there is asked for here without a second
# list to keep, with the $ARCH of that script standing for each architecture
# of the release in turn; and in the directories of each python and
# architecture every project release.yml pins for it, as a wheel of that
# version. A wheel is named after the project with dashes turned to
# underscores, in whichever case the project spells itself
check_python_packages() {
  local arch dir python name version
  for arch in "${architectures[@]}"; do
    for dir in $(grep -oP 'python-packages/\K[A-Za-z0-9._-]+/\$ARCH/[A-Za-z0-9._-]+' "$SETUP_VENV_PATH" | sed "s#/\\\$ARCH/#/$arch/#" | sort -u); do
      [[ -n $(find "$BUNDLE_PATH/python-packages/$dir" -name "*.whl" -print -quit 2>/dev/null) ]] ||
        missing+=("python-packages/$dir: no wheel there, and setup-venv.sh installs from it. run fetch-bundle-python-packages.sh --arch $arch")
    done

    for python in $(grep -oP 'python-packages/\K[A-Za-z0-9._-]+' "$SETUP_VENV_PATH" | sort -u); do
      while read -r name version; do
        [[ -z $name ]] && continue
        [[ -n $(find "$BUNDLE_PATH/python-packages/$python/$arch" -iname "${name//-/_}-$version-*.whl" -print -quit 2>/dev/null) ]] ||
          missing+=("python-packages/$python/$arch: no wheel of $name $version, which release.yml declares under python_packages")
      done < <($YQ_CMD ".python_packages[\"$python\"] // {} | to_entries | .[] | .key + \" \" + .value" < "$RELEASE_META_PATH")
    done
  done

  return 0
}

report_missing() {
  [[ ${#missing[@]} = 0 ]] && return 0

  local line
  for line in "${missing[@]}"; do
    msg "[ERROR]   $line"
  done
  die "[ERROR] Directory[\"$BUNDLE_PATH\"] lacks ${#missing[@]} of what release[\"$version\"] declares, listed above. nothing was packed"
}

# Written to a .part first, so that a run that stops half way leaves no file
# of the name the next run would refuse to overwrite
make_archive() {
  msg "[INFO] Packing \"$BUNDLE_PATH\" into \"$out_path\""

  tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -C "$KI_ROOT_PATH" -cf - bundle | gzip -n > "$out_path.part" ||
    die "[ERROR] Fail to pack \"$BUNDLE_PATH\""
  mv "$out_path.part" "$out_path"

  return 0
}

# release.yml is where the sha256 of a release bundle lives, and a release
# bundle is published once, so a value already there that is not this one is
# a bundle being rebuilt and is refused: if this archive is the one to be
# published, the recorded value is the thing to correct, by hand and on
# purpose
record_sha256() {
  local sha256=$1

  local recorded
  recorded=$(grep -oP '^bundle_sha256: "\K[^"]*' < "$RELEASE_META_PATH" || true)

  if [[ $(is_snapshot "$version") = "true" ]]; then
    [[ -n $recorded ]] &&
      msg "[WARN] Release[\"$version\"] is a snapshot and release.yml records a bundle_sha256 for it. a snapshot leaves it empty"
    return 0
  fi

  if [[ -n $recorded && $recorded != "$sha256" ]]; then
    msg "[ERROR] File[\"$RELEASE_META_PATH\"] records bundle_sha256[\"$recorded\"] for release[\"$version\"], and this archive is a different one"
    die "[ERROR] A published release bundle is never rebuilt. if release[\"$version\"] has not been published yet, correct the recorded value by hand"
  fi

  if [[ $write_sha256 != "true" ]]; then
    [[ -z $recorded ]] && msg "[INFO] Record it before publishing: run again with --write-sha256, or write bundle_sha256: \"$sha256\" in release.yml"
    return 0
  fi

  if [[ $recorded = "$sha256" ]]; then
    msg "[INFO] File[\"$RELEASE_META_PATH\"] already records this sha256"
    return 0
  fi

  sed -i "s|^bundle_sha256: \"\"$|bundle_sha256: \"$sha256\"|" "$RELEASE_META_PATH"
  grep -q "^bundle_sha256: \"$sha256\"$" "$RELEASE_META_PATH" ||
    die "[ERROR] Fail to write bundle_sha256 to \"$RELEASE_META_PATH\". it is expected as a line bundle_sha256: \"\""
  msg "[INFO] bundle_sha256 of release[\"$version\"] written to \"$RELEASE_META_PATH\". commit it with the release"

  return 0
}

main
