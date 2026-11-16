# shellcheck shell=bash
#
# Sourced by the scripts of this directory, after the cli template of each of
# them. The directive above names the shell this is read as, which a file with
# no shebang otherwise leaves unknown: a file that is sourced is not run, so it
# carries none. vfio-pci-common.sh is the same shape for the same reason.
#
# What lives here is what has to agree between the setup, the reset and the
# check: where the two records are and how they are read. The check compares
# the first against the command line and the second against the boot, so a path
# or a format that drifted between the scripts would be a node reported as fine
# while it boots with something else.
#
# The cli template at the top of each script is left duplicated, the way it is
# in every other script of this repository

# The drop in ubuntu reads after its own file. rhel has no such directory and
# grubby edits the boot entries instead, with the record below as the undo.
# Both carry the name of the installer, so a file here is never confused with
# one the site wrote and the reset knows what is its to remove
GRUB_DROP_IN_PATH=/etc/default/grub.d/99-ki-kernel-args.cfg

# What the setup last put on the command line, one argument per line. Absent on
# a node that was never given any, which reads the same as a node given none
RECORD_PATH=/etc/k8s-installer/kernel-args

# What the setup or the reset took off the bootloader and the node has not
# booted without yet: the id of the boot they were taken away in on the first
# line, then one argument per line.
#
# Taking an argument away is writing the bootloader, and the running kernel
# keeps the argument until the next boot exactly as it ignored one that was
# added until then. The record above can not say so, since the argument is not
# in it any more, and /proc/cmdline alone can not either: an argument that is
# still on the line looks the same as one the site put there itself. What
# settles it is whether the node has booted since. The kernel hands out a fresh
# id at every boot, so a file carrying the id of the boot the arguments were
# taken away in is a node that still runs with them, and a file carrying any
# other id is a node that has booted since and is done with them.
# check-kernel-args.sh reports the former and takes the latter away
REMOVED_PATH=/etc/k8s-installer/kernel-args-removed

BOOT_ID_PATH=/proc/sys/kernel/random/boot_id

recorded_args() {
  [[ -f $RECORD_PATH ]] || return 0
  cat "$RECORD_PATH"

  return 0
}

# The arguments taken away in this boot, one per line, and nothing once the
# node has booted since. The file is removed at that point by whichever script
# asks first, so that a record of a boot that is over does not stay behind to
# be explained
removed_args() {
  [[ -f $REMOVED_PATH ]] || return 0

  if [[ $(head -n 1 "$REMOVED_PATH") != "$(< "$BOOT_ID_PATH")" ]]; then
    rm -f "$REMOVED_PATH"
    return 0
  fi

  tail -n +2 "$REMOVED_PATH"

  return 0
}

# Writes down that the arguments of the second list are off the bootloader and
# still on the running kernel. What was written down earlier in this boot is
# kept, and an argument of the first list - what the node names now - is
# dropped from both: an argument taken away and given back before a boot is one
# the node is booted with, which is nothing to report. So is one that is not on
# the command line at all - written and taken away again before the node ever
# booted with it - and it is left out for the same reason: nothing about this
# boot changes when the node boots again. Both lists are one argument per line
record_removed_args() {
  local wanted=$1
  local removed=$2

  local cmdline
  cmdline=$(cat /proc/cmdline)

  # grep returns 1 on no line at all, which under set -e would end the script
  # here with nothing said
  local merged
  merged=$({ removed_args; printf '%s\n' "$removed"; } | grep . | sort -u || true)

  local arg
  local kept=""
  while IFS= read -r arg; do
    [[ -z $arg ]] && continue
    grep -qxF -- "$arg" <<< "$wanted" && continue
    grep -qwF -- "$arg" <<< "$cmdline" || continue
    kept+="$arg"$'\n'
  done <<< "$merged"

  if [[ -z $kept ]]; then
    rm -f "$REMOVED_PATH"
    return 0
  fi

  mkdir -p "$(dirname "$REMOVED_PATH")"
  { cat "$BOOT_ID_PATH"; printf '%s' "$kept"; } > "$REMOVED_PATH".tmp
  mv -f "$REMOVED_PATH".tmp "$REMOVED_PATH"

  return 0
}
