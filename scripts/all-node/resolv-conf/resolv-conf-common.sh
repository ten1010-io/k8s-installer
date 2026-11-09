# shellcheck shell=bash
#
# Sourced by setup-resolv-conf.sh and reset-resolv-conf.sh, after their cli
# template. Both rewrite /etc/resolv.conf and stop whatever else answered for
# the node, so both owe it the one thing that took away. The directive above
# names the shell this is read as, which a file with no shebang otherwise
# leaves unknown.
#
# What it reads of the script that sources it is handed to it, so that this
# file stands on its own under shellcheck

# The file setup-resolv-conf.sh writes names the cluster dns and nothing else: no search
# domain, because the one the node had came from its dhcp lease and names a
# network this installer knows nothing about. What that takes away is the
# node's own name. A cloud image is called ip-172-31-62-61, a name only the
# resolver of that cloud answers for, through the search domain the lease
# carried; with the cluster dns forwarding to a public upstream the name is
# gone, and the first thing to say so is sudo, which looks its own host up on
# every call and warns on every call when it can not. The warning is on stderr
# and nothing here reads it as an answer, but a shell that sees it at every
# sudo is one where every real message is lost among them, and kubeadm and
# kubelet look the name up too.
#
# So the name goes into /etc/hosts, against the address of this node, which is
# what the dhcp resolver would have answered and what kubelet is registered
# under. In the hosts file rather than as a record of the cluster dns, because
# a node has to know its own name while that dns is being handed over between
# ki cp nodes, which is when sudo is being run on it most. Left alone when the
# name is already mapped by a line this installer did not write: that is a
# site that put it there on purpose, with an address of its choosing. Our own
# line is replaced on every run, since the address can change with the
# inventory and the name with the node.
#
# The reset writes it too rather than leaving it where the setup put it. The
# reset does not give the node its old resolver back either: it stops resolved
# and points the file at an upstream, and a node resolving through an upstream
# still needs its own name. Leaving the line was enough for a node the setup
# had been through, and not for one it never reached: a node refused before
# the first script ran, because it came with docker installed, is reset before
# it is set up, and the reset was then what took its name away
HOSTS_PATH=/etc/hosts
HOSTS_LINE_MARK="# k8s-installer-own-hostname"

#   keep_own_hostname_resolvable <yq command> <vars path> <vip of the ha mode>
keep_own_hostname_resolvable() {
  local yq=$1
  local vars=$2
  local vip=$3

  local name
  name=$(hostname)
  [[ -z $name ]] && die "[ERROR] This node has no hostname to keep resolvable"

  local ip
  ip=$($yq "[.internal_network_interfaces[] | select(.ip != \"$vip\")][0].ip" < "$vars")
  [[ -z $ip || $ip = "null" ]] && die "[ERROR] Could not read the internal address of this node from file[\"$vars\"]"

  # Ours from a previous run goes first, so that what is checked below is what
  # somebody else wrote
  sed -i "/ $HOSTS_LINE_MARK\$/d" "$HOSTS_PATH"
  if grep -Eq "^[^#]*[[:space:]]$name([[:space:]]|\$)" "$HOSTS_PATH"; then
    msg "[INFO] Hostname[\"$name\"] is already mapped in $HOSTS_PATH, leaving it as it is"
    return 0
  fi

  # The short name beside the full one on a node whose hostname is qualified,
  # so that the one as well as the other answers. Nothing to add when they are
  # the same word
  local short
  short=${name%%.*}
  [[ $short = "$name" ]] && short=""
  printf '%s %s %s %s\n' "$ip" "$name" "$short" "$HOSTS_LINE_MARK" | tr -s ' ' >> "$HOSTS_PATH"
  msg "[INFO] Hostname[\"$name\"] mapped to address[\"$ip\"] in $HOSTS_PATH"

  return 0
}
