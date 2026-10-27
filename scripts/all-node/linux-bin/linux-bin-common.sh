# shellcheck shell=bash
#
# Sourced by install-programs.sh, after its cli template, and by
# tools/fetch-bundle-binaries.sh from the source tree. The directive above
# names the shell this is read as, which a file with no shebang otherwise
# leaves unknown.
#
# What lives here has to agree between the two: the tool that puts a binary
# into bundle/bin asks it which version it is, and the node asks the same
# binary the same question before laying it down. Asked two different ways,
# a bundle the tool passed could be one a node refuses, which is the kind of
# disagreement that only shows up on a customer's node.

# What a binary of bundle/bin answers when asked its version.
#
# Each one is asked its own way and answers in its own shape:
#
#   helm     v3.13.1+g3547a4b
#   etcdctl  etcdctl version: 3.5.23
#   crane    0.22.1
#   yq       yq (https://github.com/mikefarah/yq/) version v4.47.1
#   nerdctl  nerdctl version 2.1.5
#
# so the invocation is per tool and what is taken from the output is the first
# thing in it shaped like a version. A name this does not know stops the run
# rather than being passed over: adding a binary to release.yml means saying how
# it is asked, the same way adding a variable means saying what changing it does
binary_version() {
  local bin_dir=$1
  local program=$2

  local output
  case $program in
  helm | crane | etcdctl | etcdutl)
    output=$("$bin_dir/$program" version 2>&1) || true
    ;;
  yq | nerdctl)
    output=$("$bin_dir/$program" --version 2>&1) || true
    ;;
  *)
    die "[ERROR] Binary[\"$program\"] is declared by release.yml and this script does not know how to ask its version. Add it to binary_version of linux-bin-common.sh"
    ;;
  esac

  grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' <<< "$output" | head -1 | sed 's/^v//' || true

  return 0
}
