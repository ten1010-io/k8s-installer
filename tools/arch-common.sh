# shellcheck shell=bash
#
# What the architectures of release.yml are called elsewhere.
#
# The bundle names an architecture the way uname -m does, x86_64 and aarch64,
# because that is what a node can ask without a table (see release.yml). The
# places the bundle is filled from have their own names for the same thing: the
# debian repositories and the container registries say amd64 and arm64, the rpm
# repositories say what uname -m says, each binary is published under the name
# its project chose, and the manylinux image of each architecture is its own
# image. The table is kept here, once, and sourced by the tools that need it, so
# that adding an architecture is one row in each function rather than a search.
#
# Sourced, so it defines functions and nothing else. A name no row knows is a
# failure of the caller's input rather than of this file, so each function
# returns 1 and prints nothing for one, and the caller says what it was doing

# What debian, docker and kubernetes call the architecture: the arch= of an apt
# source, the platform of an image, the kubernetes.io/arch label of a node
oci_arch_of() {
  case $1 in
  x86_64) echo amd64 ;;
  aarch64) echo arm64 ;;
  *) return 1 ;;
  esac
}

# What dnf's --arch takes, which is what uname -m says
rpm_arch_of() {
  case $1 in
  x86_64 | aarch64) echo "$1" ;;
  *) return 1 ;;
  esac
}

# The manylinux_2_28 image of the architecture, pinned by digest. One tag, one
# digest per architecture: the tag names a build date and each architecture is
# published as an image of its own under it
manylinux_image_of() {
  case $1 in
  x86_64) echo "quay.io/pypa/manylinux_2_28_x86_64:2026.10.26-1@sha256:e0adf18521ad35192df733a6c62d35df7801957d24e0470238aacecfab2188a3" ;;
  aarch64) echo "quay.io/pypa/manylinux_2_28_aarch64:2026.10.26-1@sha256:a3e02308c822fb6ce0d12248b0c941817ba5e1a1bc9e7bb5929f29c50eaa40a9" ;;
  *) return 1 ;;
  esac
}

# Whether this machine can run a binary of the architecture: natively, or
# through a user mode emulator the kernel was told about (binfmt_misc, which
# qemu-user-static registers). Asking a binary its version is the one check the
# release scheme rests on, and a machine that can not run it can not ask
can_run_arch() {
  local arch=$1

  [[ $(uname -m) = "$arch" ]] && return 0

  local binfmt
  case $arch in
  x86_64) binfmt=qemu-x86_64 ;;
  aarch64) binfmt=qemu-aarch64 ;;
  *) return 1 ;;
  esac
  [[ -f /proc/sys/fs/binfmt_misc/$binfmt ]] && grep -q '^enabled' "/proc/sys/fs/binfmt_misc/$binfmt"
}
