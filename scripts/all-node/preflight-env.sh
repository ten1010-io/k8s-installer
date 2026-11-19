#!/usr/bin/env bash
#==============================================================================
# preflight-env.sh — the environment preflight of a node, before anything is
#   installed. kubectl is not used: these are the OS and network things a
#   customer environment often cannot meet, and that stop or slow an install if
#   they are found only midway — DNS, firewall ports, NTP, MTU, disk, kernel
#   modules, sysctl, swap. Read-only: it reports and prints the fix as a
#   suggestion, it changes nothing.
#
#   Run on each node. Options:
#     --peers "ip1 ip2 .."   the other nodes, for node<->node ports / MTU / RTT
#     --names "n1 n2 .."     site names that must resolve (ki-cp.ki.local, ...)
#     --egress "host:port .."  external endpoints that must be reachable
#     --pod-cidr / --svc-cidr  checked for a /16 overlap with the node network
#     --vip <ip>             the keepalived VIP, which must be free before install
#     --html <path>          also writes an HTML report
#
#   The last line is machine-readable for the playbook: "SUMMARY pass=.. warn=.. fail=.."
#   The script always exits 0 (even with FAIL rows); the playbook decides whether
#   a FAIL stops the install, so the whole report is always collected first.
#==============================================================================
set -uo pipefail
PEERS=""; HTML=""; NAMES=""; EGRESS=""; PODCIDR=""; SVCCIDR=""; VIP=""
while [ $# -gt 0 ]; do case "$1" in
  --peers) PEERS=$2; shift 2;; --html) HTML=$2; shift 2;; --names) NAMES=$2; shift 2;;
  --egress) EGRESS=$2; shift 2;; --pod-cidr) PODCIDR=$2; shift 2;; --svc-cidr) SVCCIDR=$2; shift 2;; --vip) VIP=$2; shift 2;;
  *) echo "unknown: $1"; exit 2;; esac; done
ROWS=()
add(){ ROWS+=("$1|$2|$3|$4"); }   # STATUS|id|name|detail
g='\033[32m'; r='\033[31m'; y='\033[33m'; d='\033[2m'; o='\033[0m'
col(){ case $1 in PASS) echo -e "${g}PASS${o}";; FAIL) echo -e "${r}FAIL${o}";; WARN) echo -e "${y}WARN${o}";; *) echo -e "${d}NA${o}";; esac; }
has(){ command -v "$1" >/dev/null 2>&1; }
tcp(){ timeout 2 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

# DNS is mostly UDP, so it is judged by resolving a real name, not by probing a port
ns=$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | head -3 | tr '\n' ' ')
dnsq(){ # $1=name -> the resolved IP, or empty
  if has dig; then dig +short +time=2 +tries=1 "$1" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1
  elif has host; then host -W2 "$1" 2>/dev/null | awk '/has address/{print $NF; exit}'
  elif has nslookup; then nslookup "$1" 2>/dev/null | awk '/^Address/{a=$NF} END{print a}'
  else getent hosts "$1" 2>/dev/null | awk '{print $1; exit}'; fi; }
dnstool="getent"; has dig && dnstool="dig"; has host && dnstool="host"; has nslookup && [ "$dnstool" = getent ] && dnstool="nslookup"
if [ -n "$NAMES" ]; then
  # the names the site requires (internal/external) must actually resolve — the point of this check
  badn=""; okn=""
  for n in $NAMES; do if [ -n "$(dnsq "$n")" ]; then okn="$okn $n"; else badn="$badn $n"; fi; done
  if [ -z "$badn" ]; then add PASS E-DNS "DNS" "all required names resolve ($dnstool):${okn}"
  else add FAIL E-DNS "DNS" "cannot resolve:${badn} — check the customer DNS/resolver (resolved:${okn:- none}, ns ${ns:-none})"; fi
else
  # no required names given: only the resolver is checked, with this host's own name (site names go in --names)
  self=$(dnsq "$(hostname)")
  if [ -n "$self" ]; then add PASS E-DNS "DNS" "resolver works ($dnstool), $(hostname)->$self (ns ${ns:-none}). Pass the site names with --names"
  elif [ -n "$ns" ]; then add WARN E-DNS "DNS" "own name does not resolve ($dnstool) — pass the site names with --names to be sure (ns ${ns})"
  else add WARN E-DNS "DNS" "no nameserver in /etc/resolv.conf"; fi
fi

# NTP / clock
if has chronyc; then
  tr=$(chronyc tracking 2>/dev/null); leap=$(echo "$tr" | awk -F': *' '/Leap status/{print $2}'); off=$(echo "$tr" | awk -F': *' '/System time/{print $2}')
  if echo "$leap" | grep -qi normal; then add PASS E-NTP "NTP/clock" "in sync, $off";
  else add WARN E-NTP "NTP/clock" "chrony not in sync (Leap=$leap) — risks cert/token rejection"; fi
elif has timedatectl; then
  if timedatectl 2>/dev/null | grep -qi 'synchronized: yes'; then add PASS E-NTP "NTP/clock" "systemd-timesyncd in sync"; else add WARN E-NTP "NTP/clock" "clock not in sync"; fi
else add NA E-NTP "NTP/clock" "no chrony/timedatectl"; fi

# swap
if [ -n "$(swapon --show 2>/dev/null)" ]; then add FAIL E-SWAP "swap" "swap on — kubelet refuses it. Fix: swapoff -a && comment it in /etc/fstab";
else add PASS E-SWAP "swap" "off"; fi

# kernel modules
miss=""; for m in br_netfilter overlay nf_conntrack; do lsmod 2>/dev/null | grep -qw "$m" || miss="$miss $m"; done
if [ -z "$miss" ]; then add PASS E-KMOD "kernel modules" "br_netfilter, overlay, nf_conntrack loaded";
else add WARN E-KMOD "kernel modules" "not loaded:$miss. The installer loads these (apply-node-kernel-config); fix by hand: modprobe$miss"; fi

# sysctl
declare -A want=([net.ipv4.ip_forward]=1 [net.bridge.bridge-nf-call-iptables]=1)
bad=""; for k in "${!want[@]}"; do v=$(sysctl -n "$k" 2>/dev/null); [ "$v" = "${want[$k]}" ] || bad="$bad $k=$v(want ${want[$k]})"; done
if [ -z "$bad" ]; then add PASS E-SYSCTL "sysctl" "ip_forward, bridge-nf-call-iptables=1";
else add WARN E-SYSCTL "sysctl" "mismatch:$bad (the installer sets these in apply-node-kernel-config)"; fi

# disk: / and /var/lib (and the containerd root)
for p in / /var/lib; do
  read -r use free mnt < <(df -h "$p" 2>/dev/null | awk 'NR==2{print $5,$4,$6}')
  pct=${use%\%}
  if [ -z "$pct" ]; then add NA E-DISK "disk $p" "cannot read";
  elif [ "$pct" -ge 85 ]; then add FAIL E-DISK "disk $p" "$use used (free $free, $mnt) — risks disk pressure";
  else add PASS E-DISK "disk $p" "$use used (free $free, $mnt)"; fi
done
croot=$(awk -F'"' '/^\s*root\s*=/{print $2}' /etc/containerd/config.toml 2>/dev/null)
[ -n "$croot" ] && add NA E-CROOT "containerd root" "$croot ($(df -h "$croot" 2>/dev/null|awk 'NR==2{print $5" used, free "$4}'))"

# MTU
mtu=$(ip -o link show 2>/dev/null | awk '/state UP/{for(i=1;i<=NF;i++)if($i=="mtu")print $(i+1)}' | sort -u | tr '\n' ' ')
add NA E-MTU "MTU" "MTU of UP interfaces: ${mtu:-?} (VXLAN needs -50; confirm a large packet with a peer)"

# peers: node<->node ports + MTU
if [ -n "$PEERS" ]; then
  for ip in $PEERS; do
    for pp in 6443:apiserver 2379:etcd 2380:etcd-peer 10250:kubelet 16443:cp-lb-HA; do
      pn=${pp%%:*}; lb=${pp#*:}
      if tcp "$ip" "$pn"; then add PASS E-PORT "port->$ip" "$lb($pn) open"; else add WARN E-PORT "port->$ip" "$lb($pn) closed (fine when not installed yet)"; fi
    done
    if ping -c1 -W2 -M do -s 1472 "$ip" >/dev/null 2>&1; then add PASS E-PMTU "MTU->$ip" "a 1500 packet passes (MTU ok)";
    elif ping -c1 -W2 "$ip" >/dev/null 2>&1; then add WARN E-PMTU "MTU->$ip" "ping reaches it but a 1500 packet does not — suspect MTU/fragmentation (VXLAN is ~1450)";
    else add WARN E-PMTU "MTU->$ip" "no ping reply (host down or ICMP blocked) — cannot judge MTU. Compare with E-PORT (TCP)"; fi
  done
fi

# proxy / external reachability (--egress "host:port ..."): a customer firewall/proxy blocking a needed endpoint
pxy="http_proxy=${http_proxy:-none} https_proxy=${https_proxy:-none} no_proxy=${no_proxy:-none}"
if [ -n "$EGRESS" ]; then
  for hp in $EGRESS; do h=${hp%:*}; p=${hp##*:}
    if tcp "$h" "$p"; then add PASS E-EGRESS "external->$hp" "reachable"; else add FAIL E-EGRESS "external->$hp" "unreachable — check the firewall/proxy ($pxy)"; fi
  done
else add NA E-PROXY "proxy/external" "proxy env[$pxy]. Pass the needed endpoints with --egress \"host:port ...\""; fi

# CIDR overlap (--pod-cidr / --svc-cidr): a pod/svc range overlapping the customer node network tangles routing
locnets=$(ip -o -f inet addr show 2>/dev/null | awk '{print $4}' | grep -v '^127\.' | tr '\n' ' ')
chkcidr(){ local c=$1 lbl=$2 b hit="" n; [ -z "$c" ] && return
  b=$(echo "$c" | cut -d. -f1-2)
  for n in $locnets; do [ "$(echo "$n" | cut -d. -f1-2)" = "$b" ] && hit="$n"; done
  if [ -n "$hit" ]; then add WARN E-CIDR "$lbl CIDR" "$c may overlap the node network $hit at /16 — check by hand"
  else add PASS E-CIDR "$lbl CIDR" "$c, no /16 overlap with the node network ($locnets)"; fi; }
if [ -n "$PODCIDR$SVCCIDR" ]; then chkcidr "$PODCIDR" pod; chkcidr "$SVCCIDR" svc
else add NA E-CIDR "CIDR overlap" "pass --pod-cidr/--svc-cidr to check (node network: $locnets)"; fi

# VIP (--vip): the keepalived/VRRP VIP — must be free before install, and on the same L2 (subnet) as the nodes
if [ -n "$VIP" ]; then
  insub=""; v3=$(echo "$VIP" | cut -d. -f1-3)
  for n in $locnets; do [ "$(echo "$n" | cut -d. -f1-3)" = "$v3" ] && insub="$n"; done
  if ping -c1 -W2 "$VIP" >/dev/null 2>&1; then add WARN E-VIP "VIP $VIP" "already answers — before install this is an address clash (another host holds it)"
  else add PASS E-VIP "VIP $VIP" "free (fine before install)${insub:+, within the node network $insub}"; fi
  [ -z "$insub" ] && add WARN E-VIP "VIP $VIP" "a different subnet from the nodes — L2 VRRP/ARP may be impossible (on cloud use an aws-eni carrier)"
else add NA E-VIP "VIP" "pass --vip <ip> to check (VRRP/keepalived L2 reach)"; fi

# own load: loadavg vs CPU, iowait (what makes an install/deploy slow)
ncpu=$(nproc 2>/dev/null || echo 1); la1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)
iowait="?"; has vmstat && iowait=$(vmstat 1 2 2>/dev/null | tail -1 | awk '{print $16}')
ratio=$(awk -v l="${la1:-0}" -v n="$ncpu" 'BEGIN{printf "%.2f",(n>0?l/n:l)}')
if awk -v r="$ratio" 'BEGIN{exit !(r>1.5)}'; then add WARN E-LOAD "own load" "load1=${la1} / ${ncpu}cpu = ${ratio}x (high), iowait=${iowait}% -> ease it: lower install concurrency (aipub_install_dag_jobs=1), a quieter time"
else add PASS E-LOAD "own load" "load1=${la1} / ${ncpu}cpu = ${ratio}x, iowait=${iowait}%"; fi

# disk IO latency: small synchronous writes ms/op — when slow, pods deploy one slow at a time and the next deploy times out
f="$HOME/.pfenv_io.$$"; t=$( { TIMEFORMAT='%R'; time dd if=/dev/zero of="$f" bs=4k count=500 oflag=dsync 2>/dev/null; } 2>&1 ); rm -f "$f"
if [[ "$t" =~ ^[0-9.]+$ ]]; then perop=$(awk -v tt="$t" 'BEGIN{printf "%.2f", tt*1000/500}')
  if awk -v p="$perop" 'BEGIN{exit !(p>10)}'; then add WARN E-DISKIO "disk IO latency" "sync write ${perop}ms/op (slow — deploy timeouts) -> ease it: lower concurrency, raise helm timeout, retries; a faster disk/path"
  else add PASS E-DISKIO "disk IO latency" "sync write ${perop}ms/op (500x4k dsync ${t}s)"; fi
else add NA E-DISKIO "disk IO latency" "cannot measure (dd result: ${t:-none})"; fi

# network latency: peer RTT (high RTT slows node-to-node traffic and etcd)
if [ -n "$PEERS" ]; then for ip in $PEERS; do
  rtt=$(ping -c3 -W2 "$ip" 2>/dev/null | awk -F'/' '/rtt|round-trip/{print $5}')
  if [ -n "$rtt" ]; then
    if awk -v r="$rtt" 'BEGIN{exit !(r>5)}'; then add WARN E-NETLAT "latency->$ip" "mean ${rtt}ms (high) -> ease it: check MTU, raise etcd heartbeat/election timeout; closer nodes/switch"; else add PASS E-NETLAT "latency->$ip" "mean ${rtt}ms"; fi
  else add WARN E-NETLAT "latency->$ip" "no reply"; fi
done; fi

# counts (always, so the summary line is there with or without --html)
pf=0; wf=0; ff=0
for e in "${ROWS[@]}"; do st=${e%%|*}; case $st in PASS)pf=$((pf+1));;WARN)wf=$((wf+1));;FAIL)ff=$((ff+1));;esac; done

# output
echo "== environment preflight: $(hostname) =="
for e in "${ROWS[@]}"; do IFS='|' read -r st id nm dt <<<"$e"; printf "  %-9s [%s] %-16s %s\n" "$id" "$(col "$st")" "$nm" "$dt"; done

if [ -n "$HTML" ]; then
  { echo "<!doctype html><meta charset=utf-8><title>environment preflight</title><style>body{font:14px system-ui;background:#f6f7f9;color:#1b2026;margin:0}@media(prefers-color-scheme:dark){body{background:#12151a;color:#e7ebf0}}.w{max-width:820px;margin:0 auto;padding:24px 16px}table{width:100%;border-collapse:collapse;background:#fff;border:1px solid #dfe4ea;border-radius:10px;overflow:hidden}@media(prefers-color-scheme:dark){table{background:#1b2027;border-color:#2c343e}}th,td{text-align:left;padding:9px 11px;border-bottom:1px solid #dfe4ea;font-size:.88rem}@media(prefers-color-scheme:dark){th,td{border-color:#2c343e}}th{font-size:.7rem;text-transform:uppercase;color:#5b6673}.b{font-size:.68rem;font-weight:700;padding:2px 8px;border-radius:99px}.PASS{background:#e4f4ec;color:#1a9e6a}.WARN{background:#fbf2db;color:#c98a00}.FAIL{background:#fbeadf;color:#c2410c}.NA{color:#5b6673}</style>"
    echo "<div class=w><h1>environment preflight</h1><p>$(hostname) &middot; $(date '+%Y-%m-%d %H:%M') &middot; PASS $pf / WARN $wf / FAIL $ff</p><table><tr><th>ID</th><th>result</th><th>item</th><th>detail</th></tr>"
    for e in "${ROWS[@]}"; do IFS='|' read -r st id nm dt <<<"$e"; echo "<tr><td>$id</td><td><span class='b $st'>$st</span></td><td>$nm</td><td>$dt</td></tr>"; done
    echo "</table></div>"; } > "$HTML"
  echo "HTML report: $HTML"
fi

echo "SUMMARY pass=$pf warn=$wf fail=$ff"
