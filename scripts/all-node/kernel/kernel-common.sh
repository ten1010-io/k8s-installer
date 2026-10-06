# shellcheck shell=bash
#
# Sourced by the scripts of this directory and by check-node-state.sh, after the
# cli template of each of them. The directive above names the shell this is read
# as, which a file with no shebang otherwise leaves unknown.
#
# What lives here has to agree between the scripts: the one that refuses a node
# before anything is built on it, the one that installs a kernel so that the
# node can load these, and the one that confirms it after the reboot all have to
# be asking about the same modules, and comparing kernel versions the same way.

# The kernel modules a node of the cluster loads: overlay for the container
# storage, br_netfilter so that bridged traffic reaches the filter, and the
# netfilter matches that kube-proxy, kubelet and docker write their rules with,
# which the nft backed iptables loads through nft_compat.
#
# A distribution kernel used to have all of these in its base package. rhel 10
# moved br_netfilter and every xt_ module into kernel-modules-extra, which a
# minimal install does not hold. xt_MASQUERADE is not asked for: the 4.18 of
# rhel 8 calls it ipt_MASQUERADE, and the rest of the list already says whether
# the node has that package
KERNEL_MODULES=(overlay br_netfilter nf_conntrack nft_compat xt_conntrack xt_comment xt_addrtype xt_mark xt_nat xt_multiport xt_statistic xt_recent)

# The modules of the list above that the running kernel can not load, one per
# line. Asked with a dry run, since the scripts that ask change nothing by
# asking, and a module that is built in answers the dry run the same way one on
# disk does
missing_kernel_modules() {
  local module
  for module in "${KERNEL_MODULES[@]}"; do
    modprobe -n "$module" &>/dev/null && continue
    echo "$module"
  done

  return 0
}

# The kernel of the bundle for an os, as rpm names it: version-release, which is
# what uname -r says less the architecture. Empty when the bundle carries none
bundle_kernel_version() {
  local kernel_dir=$1

  local rpm_file
  rpm_file=$(find "$kernel_dir" -maxdepth 1 -name 'kernel-core-*.rpm' 2>/dev/null | head -1)
  [[ -z $rpm_file ]] && return 0

  rpm -qp --queryformat '%{VERSION}-%{RELEASE}' "$rpm_file" 2>/dev/null

  return 0
}

running_kernel_version() {
  uname -r | sed 's/\.[^.]*$//'

  return 0
}

# How rpm itself orders two versions: -1, 0 or 1. rpm carries the comparison in
# its lua, and nothing else on a node is guaranteed to agree with it on things
# like 211.62.1 against 211.7.3
compare_kernel_versions() {
  rpm --eval "%{lua: print(rpm.vercmp('$1', '$2'))}"

  return 0
}
