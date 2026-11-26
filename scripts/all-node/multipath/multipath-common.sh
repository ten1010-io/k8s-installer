# shellcheck shell=bash
#
# Sourced by the scripts of this directory, after the cli template of each of
# them. The directive above names the shell this is read as, which a file with
# no shebang otherwise leaves unknown: a file that is sourced is not run, so it
# carries none.
#
# What is here is what the setup and the reset have to agree on: where
# multipath keeps its configuration, where this installer keeps what the node
# held before it was touched, and how a node is put back to that.
#
# The cli template at the top of each script is left duplicated, the way it is in
# every other script of this repository. Only what is particular to multipath is
# shared

MULTIPATH_CONF_PATH=/etc/multipath.conf
MULTIPATHD_UNIT=multipathd.service

# The name of the directory under ki_etc_root_path that says this installer
# wrote the multipath configuration of this node, and holds what the node was
# before it did:
#
#   units-before         one line a unit: its name, whether it was enabled and
#                        whether it was active
#   multipath.conf.orig  the multipath.conf the node held, when it held one.
#                        Turning multipath off puts it back, and a node that
#                        held none is left with none
#
# Its presence is the whole of the answer to "is the multipath.conf of this
# node ours". A node the variable was never turned on for has no such directory,
# and every script here leaves such a node exactly as it found it - which on an
# ubuntu server image is a multipathd that is already running with the
# configuration the image shipped
MULTIPATH_STATE_DIR_NAME=multipath

# The multipath maps this node holds, one "dm-N name" a line. Read from sysfs
# rather than asked of multipathd, so that the answer does not depend on the
# daemon being up: a map is a device mapper table the kernel holds, and it is
# there whether or not anything is watching it
multipath_maps() {
  local dm uuid
  for dm in /sys/block/dm-*; do
    [[ -r $dm/dm/uuid ]] || continue
    uuid=$(< "$dm/dm/uuid")
    [[ $uuid = mpath-* ]] || continue
    echo "$(basename "$dm") $(< "$dm/dm/name")"
  done

  return 0
}

multipath_map_count() {
  multipath_maps | wc -l

  return 0
}

# Whether a unit is enabled, as one of two words. systemctl has a dozen answers
# - static, indirect, alias, generated - and the only thing asked here is
# whether "systemctl enable" was the last thing said to it
multipath_unit_enabled_word() {
  local unit=$1

  if [[ $(systemctl is-enabled "$unit" 2>/dev/null) = "enabled" ]]; then
    echo "enabled"
  else
    echo "disabled"
  fi

  return 0
}

multipath_unit_active_word() {
  local unit=$1

  if systemctl -q is-active "$unit" 2>/dev/null; then
    echo "active"
  else
    echo "inactive"
  fi

  return 0
}

# Puts the node back to what units-before and multipath.conf.orig say it was,
# and takes the state directory away, which is what makes the node not ours
# again. Called only on a node that holds no map, so a daemon stopped here is a
# daemon that was holding nothing.
#
# A unit is only ever moved back down. One that was enabled and active before
# this installer came is one this installer never stopped, and it is told to
# read the configuration that was just put back
multipath_restore_node_state() {
  local state_path=$1

  if [[ -f $state_path/multipath.conf.orig ]]; then
    cp -pf "$state_path/multipath.conf.orig" "$MULTIPATH_CONF_PATH"
  else
    rm -f "$MULTIPATH_CONF_PATH"
  fi

  local unit enabled_before active_before
  while read -r unit enabled_before active_before; do
    [[ -z $unit ]] && continue

    if [[ $active_before = "inactive" && $(multipath_unit_active_word "$unit") = "active" ]]; then
      systemctl stop "$unit"
    fi
    if [[ $enabled_before = "disabled" && $(multipath_unit_enabled_word "$unit") = "enabled" ]]; then
      systemctl disable "$unit" > /dev/null 2>&1
    fi
  done < "$state_path/units-before"

  if [[ $(multipath_unit_active_word "$MULTIPATHD_UNIT") = "active" ]]; then
    multipathd reconfigure > /dev/null
  fi

  rm -rf "$state_path"

  return 0
}
