# shellcheck shell=bash
#
# Sourced by the scripts of this directory, after the cli template of each of
# them. The directive above names the shell this is read as, which a file with
# no shebang otherwise leaves unknown: a file that is sourced is not run, so it
# carries none.
#
# What is here is what the setup, the reset and the state report have to agree
# on: where the initiator keeps its files, where this installer keeps what the
# node held before it was touched, and how a node is put back to that. A path
# that drifted between them is a reset that restores nothing and says it did.
#
# The cli template at the top of each script is left duplicated, the way it is in
# every other script of this repository. Only what is particular to the iscsi
# initiator is shared

ISCSID_CONF_PATH=/etc/iscsi/iscsid.conf
INITIATOR_NAME_PATH=/etc/iscsi/initiatorname.iscsi
ISCSID_UNIT=iscsid.service

# The name of the directory under ki_etc_root_path that says this installer set
# the initiator of this node up, and holds what the node was before it did:
#
#   units-before      one line a unit: its name, whether it was enabled and
#                     whether it was active
#   iscsid.conf.orig  the iscsid.conf the node held, which every render starts
#                     from and which turning the initiator off puts back
#
# Its presence is the whole of the answer to "is this node's initiator ours".
# A node the variable was never turned on for has no such directory, and every
# script here leaves such a node exactly as it found it
ISCSI_STATE_DIR_NAME=iscsi-initiator

# The unit that logs in to the targets a node was told to log in to at boot. It
# is the one name that differs between the distributions: open-iscsi.service on
# an ubuntu and iscsi.service on a rhel
iscsi_login_unit_of() {
  local distribution=$1

  if [[ $distribution = "ubuntu" ]]; then
    echo "open-iscsi.service"
  else
    echo "iscsi.service"
  fi

  return 0
}

# Counted from sysfs rather than asked of iscsiadm, so that the answer does not
# depend on the daemon being up or the package being there: a session is held
# by the kernel, and a node with no initiator at all has no such directory
iscsi_session_count() {
  local count=0
  local session
  for session in /sys/class/iscsi_session/session*; do
    [[ -e $session ]] && count=$((count + 1))
  done

  echo "$count"

  return 0
}

# The name this node introduces itself to a target with, or nothing. An ubuntu
# that has never started iscsid holds "GenerateName=yes" in the file instead of
# a name, which is no name
iscsi_initiator_name() {
  [[ -f $INITIATOR_NAME_PATH ]] || return 0
  grep -oP '^InitiatorName=\K\S+' "$INITIATOR_NAME_PATH" | head -n 1 || true

  return 0
}

# Whether a unit is enabled, as one of two words. systemctl has a dozen answers
# - static, indirect, alias, generated - and the only thing asked here is
# whether "systemctl enable" was the last thing said to it
iscsi_unit_enabled_word() {
  local unit=$1

  if [[ $(systemctl is-enabled "$unit" 2>/dev/null) = "enabled" ]]; then
    echo "enabled"
  else
    echo "disabled"
  fi

  return 0
}

iscsi_unit_active_word() {
  local unit=$1

  if systemctl -q is-active "$unit" 2>/dev/null; then
    echo "active"
  else
    echo "inactive"
  fi

  return 0
}

# Puts the node back to what units-before and iscsid.conf.orig say it was, and
# takes the state directory away, which is what makes the node not ours again.
#
# The name of the initiator stays. It is how a storage system knows this node,
# and nothing is gained by forgetting it: a node that is given the initiator
# back introduces itself the way it did before.
#
# A unit is only ever moved back down here. One that was enabled and active
# before this installer came is one this installer never stopped, so there is
# nothing to bring back up
iscsi_restore_node_state() {
  local state_path=$1

  if [[ -f $state_path/iscsid.conf.orig ]]; then
    cp -pf "$state_path/iscsid.conf.orig" "$ISCSID_CONF_PATH"
  fi

  local unit enabled_before active_before
  while read -r unit enabled_before active_before; do
    [[ -z $unit ]] && continue

    if [[ $active_before = "inactive" && $(iscsi_unit_active_word "$unit") = "active" ]]; then
      systemctl stop "$unit"
    fi
    if [[ $enabled_before = "disabled" && $(iscsi_unit_enabled_word "$unit") = "enabled" ]]; then
      systemctl disable "$unit"
    fi
  done < "$state_path/units-before"

  # A daemon that stays up was up before, and goes on with the configuration
  # that was just put back rather than with the one it was started under
  if [[ $(iscsi_unit_active_word "$ISCSID_UNIT") = "active" ]]; then
    systemctl restart "$ISCSID_UNIT"
  fi

  rm -rf "$state_path"

  return 0
}
