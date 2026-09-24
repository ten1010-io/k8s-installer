# Sourced by the scripts of this directory, after the cli template of each of
# them, since what is here calls msg.
#
# What lives here is what more than one script needs and, more to the point, what
# has to agree between them. The paths are the first of those: the reset decides
# whether any of this ever ran on a node by looking for these exact files, so a
# path that drifted between the setup and the reset is a reset that quietly does
# nothing and a node that goes on binding its cards for ever. Reading the devices
# out of sysfs is the second: three scripts ask the node what it is holding, and
# an answer that differs between them is worse than no answer.
#
# The cli template at the top of each script is left duplicated, the way it is in
# every other script of this repository. Only what is particular to vfio-pci is
# shared, so that this directory is the only place with a new rule in it

# Everything the installer writes carries its name, so that a file put here is
# never confused with one the site wrote itself and so that the reset knows what
# is its to remove
MODULES_LOAD_PATH=/etc/modules-load.d/ki-vfio-pci.conf
MODPROBE_PATH=/etc/modprobe.d/ki-vfio-pci.conf
INITRAMFS_MODULES_PATH=/etc/initramfs-tools/modules
DRACUT_PATH=/etc/dracut.conf.d/99-ki-vfio-pci.conf
GRUB_DROP_IN_PATH=/etc/default/grub.d/99-ki-vfio-pci.cfg
# The one file here that is not about binding a device. nvidia-cdi-refresh.service
# comes with nvidia-container-toolkit-base, which install-packages.sh puts on
# every node, and its first ExecStart is nvidia-smi -L with no - prefix. On a node
# that handed all of its gpus to guests that command can not succeed, and the unit
# carries Restart=on-failure with RestartSec=1s, so it fails and restarts for as
# long as the node is up. The vendor did bound it - StartLimitBurst=5 over
# StartLimitIntervalSec=10s - but a failing nvidia-smi takes about three seconds
# to give up, so five starts never fit in ten seconds and the limit never trips.
# /lib belongs to the package and /etc to whoever runs the machine, which is why
# this goes here and why the postinst, which unmasks and re-enables the unit on
# every install, leaves it alone
CDI_REFRESH_DROP_IN_PATH=/etc/systemd/system/nvidia-cdi-refresh.service.d/99-ki-vfio-pci.conf
# Under ki_etc_root_path, which is read from the vars file, so the scripts build
# the path rather than holding it
KERNEL_ARGS_FILE_NAME=vfio-pci-kernel-args
# The marker lines the initramfs modules file of ubuntu is edited between. That
# file belongs to the distribution and holds whatever else the site put in it,
# so this owns the block rather than the file
INITRAMFS_BEGIN="# BEGIN ki-vfio-pci"
INITRAMFS_END="# END ki-vfio-pci"
# What has to be in the initramfs for a device to be claimed before the driver
# of its vendor is loaded
VFIO_MODULES=(vfio vfio_iommu_type1 vfio-pci)
# Where the kernel publishes the devices. A constant like the paths above rather
# than written into the loop below, so that the lookups can be pointed at a
# directory of fixtures and checked without a machine that has the cards
PCI_DEVICES_PATH=${PCI_DEVICES_PATH:-/sys/bus/pci/devices}

# The sysfs directory of every device of this node that the id names, as
# vendor:device. Read from sysfs rather than from lspci, because lspci comes from
# pciutils and the bundle does not carry it. sysfs writes the numbers in lower
# case while the inventory is allowed to write them in either
sysfs_paths_of_device_id() {
  local id=${1,,}
  local vendor="0x${id%%:*}"
  local device="0x${id##*:}"
  local path

  for path in "$PCI_DEVICES_PATH"/*; do
    [[ -f $path/vendor && -f $path/device ]] || continue
    if [[ $(< "$path"/vendor) = "$vendor" && $(< "$path"/device) = "$device" ]]; then
      echo "$path"
    fi
  done

  return 0
}

# The same for a comma separated list of them, which is the shape the ids take
# once they have been read out of the vars file
sysfs_paths_of_device_ids() {
  local ids=$1
  local id

  for id in ${ids//,/ }; do
    sysfs_paths_of_device_id "$id"
  done

  return 0
}

# The driver bound to a device now, or an empty string where nothing is driving
# it. This is what says whether the configuration has been taken: a device still
# on the driver of its vendor is a device no guest can be given
driver_of_sysfs_path() {
  local path=$1

  [[ -L $path/driver ]] || return 0
  basename "$(readlink -f "$path"/driver)"

  return 0
}

# The iommu group of a device, or an empty string. Empty for every device of a
# node whose iommu is off, since the group only exists once the iommu is up
iommu_group_of_sysfs_path() {
  local path=$1

  [[ -L $path/iommu_group ]] || return 0
  basename "$(readlink -f "$path"/iommu_group)"

  return 0
}

# The class and subclass of a device, as the four hex digits of 0xCCSSPP that
# name what a card is. Read here rather than in the one script that prints it,
# because the setup has to decide whether a device is a gpu and both have to
# agree on how that question is asked
class_code() {
  local path=$1
  local class

  class=$(< "$path"/class)
  echo "${class:2:4}"

  return 0
}

# Whether a device is a display controller, which is what "gpu" means to the pci
# specification. 0300 is a vga controller and 0302 a 3d controller - a datacentre
# card with no display output reports the latter, an L40S among them - and the
# whole 03 class is taken rather than those two, so that a card reporting 0301 or
# 0380 is not quietly treated as something other than a gpu
is_display_device() {
  local path=$1

  [[ $(class_code "$path") = 03* ]]
}

# Whether the device would be driven by nvidia, asked of the device rather than
# taken from a list of vendor ids, the same way the softdep list is built and for
# the same reason: modalias is what the card says it is and does not change with
# what is bound to it, so this still answers on a node whose cards have been on
# vfio-pci since its last reboot.
#
# Naming nvidia here is not the written down list of cards that
# vendor_drivers_of_device_ids exists to avoid. What is being asked after is not
# "is this a gpu", which is the question nobody can write down, but "is this a
# card the refresh unit needs", and that unit runs nvidia-smi. nouveau counts with
# the rest: the question is whether an nvidia card is there, not which of its
# drivers the node happens to carry
is_nvidia_driven() {
  local path=$1
  local driver

  [[ -f $path/modalias ]] || return 1

  for driver in $(modprobe -R "$(< "$path"/modalias)" 2>/dev/null || true); do
    case $driver in
    nvidia | nvidia_* | nvidiafb | nouveau) return 0 ;;
    esac
  done

  return 1
}

# Whether the iommu of this node is up now. A device bound to vfio-pci on a node
# whose iommu never came up can be given to no guest, so this is half of what
# makes a device usable. It is not the half that says whether the node has taken
# its configuration - booted_with_vfio_pci_config below is that
iommu_state() {
  if compgen -G "/sys/class/iommu/*" > /dev/null; then
    echo "on"
  else
    echo "off"
  fi

  return 0
}

# The device ids this node actually booted with, read off the kernel command
# line. Empty when it booted with none.
#
# This and not the iommu state is what says whether a node is running with what
# the setup wrote. An iommu comes up for whatever reason the site has of its own,
# and a machine worth passing cards out of very often carries intel_iommu=on in
# /etc/default/grub already, set long before this ran - so on exactly the nodes
# this is for, the iommu reads on while the node has never once booted with the
# configuration. vfio-pci.ids= is nobody else's: the setup always writes it,
# nothing else on a node has a use for it, and it reaches /proc/cmdline only
# after a boot that read the regenerated grub configuration
booted_vfio_pci_device_ids() {
  local field

  for field in $(< /proc/cmdline); do
    if [[ $field = vfio-pci.ids=* ]]; then
      echo "${field#vfio-pci.ids=}"
      return 0
    fi
  done

  return 0
}

# The ids the configuration on this node asks for, read from the modprobe file
# rather than from the vars file, so that this asks what the node is carrying
# rather than what the inventory says today. The two differ on a node whose ids
# were changed after it was last set up, and it is the file on the node that its
# last boot was against
configured_vfio_pci_device_ids() {
  [[ -f $MODPROBE_PATH ]] || return 0

  sed -n 's/^options vfio-pci ids=//p' "$MODPROBE_PATH"

  return 0
}

# Whether this node is running with the configuration written for it. Comparing
# the two lists rather than testing that the argument is there also answers for a
# node whose ids were changed since it last booted: it is carrying a
# configuration, it booted with a configuration, and they are not the same one
booted_with_vfio_pci_config() {
  local configured
  configured=$(configured_vfio_pci_device_ids)

  [[ -n $configured ]] || return 1
  [[ $(booted_vfio_pci_device_ids) = "$configured" ]] || return 1

  return 0
}

# Only a pair is a block. A file left holding a begin marker whose end marker
# went missing would otherwise have everything below it taken out by the range
# address, and what is below it belongs to the distribution and to the site
delete_initramfs_modules_block() {
  [[ -f $INITRAMFS_MODULES_PATH ]] || return 0

  if ! grep -q "^$INITRAMFS_END$" "$INITRAMFS_MODULES_PATH"; then
    grep -q "^$INITRAMFS_BEGIN$" "$INITRAMFS_MODULES_PATH" &&
      msg "[WARN] File[\"$INITRAMFS_MODULES_PATH\"] holds a begin marker with no end marker. Leaving it alone"
    return 0
  fi

  sed -i "/^$INITRAMFS_BEGIN$/,/^$INITRAMFS_END$/d" "$INITRAMFS_MODULES_PATH"

  return 0
}

# Whether this node is carrying any of what the setup writes. Every artefact and
# not two of them: on rhel8 the grub drop in is never written at all, so a test
# of the modprobe file and the drop in rested on one file
has_vfio_pci_config() {
  local kernel_args_path=$1
  local path

  for path in "$MODULES_LOAD_PATH" "$MODPROBE_PATH" "$DRACUT_PATH" "$GRUB_DROP_IN_PATH" "$CDI_REFRESH_DROP_IN_PATH" "$kernel_args_path"; do
    if [[ -f $path ]]; then
      return 0
    fi
  done

  if [[ -f $INITRAMFS_MODULES_PATH ]] && grep -q "^$INITRAMFS_BEGIN$" "$INITRAMFS_MODULES_PATH"; then
    return 0
  fi

  return 1
}

# Takes the drop in away and gives the unit its own behaviour back. Shared
# because both scripts do it: the reset removes it with everything else, and the
# setup removes it on a node that still passes devices through but no longer
# passes its gpus, which is the same file and must be the same removal
remove_cdi_refresh_drop_in() {
  [[ -f $CDI_REFRESH_DROP_IN_PATH ]] || return 0

  rm -f "$CDI_REFRESH_DROP_IN_PATH"
  rmdir --ignore-fail-on-non-empty "$(dirname "$CDI_REFRESH_DROP_IN_PATH")"
  systemctl daemon-reload

  return 0
}
