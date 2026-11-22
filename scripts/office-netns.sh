#!/usr/bin/env bash
# openfortivpn inside a network namespace with its own NIC on the LAN, so
# ExpressVPN's routes and firewall on the host never see it.
#
# Usage (as root): office-netns.sh up | vpn [openfortivpn args] | run <cmd...> | ensure | status | refresh | down
#
# Everything network-specific is detected automatically:
#   uplink interface   physical interface with the lowest-metric default route (wired wins over Wi-Fi)
#   gateway            that route's gateway
#   link type          macvlan on wired NICs, ipvlan (L2) on Wi-Fi, because an access point only
#                      accepts the MAC address of the associated station
#   office address     unused address near the top of the subnet, checked with arping; reused next
#                      time on the same network
#   office DNS         the servers the Fortigate announces after login (read from openfortivpn's output)
# Overrides: OFFICE_IFACE, OFFICE_GW, OFFICE_ADDR (CIDR, e.g. 192.0.2.200/24), OFFICE_LINK (macvlan|ipvlan),
#            OFFICE_CONFIG, OFFICE_NS, OFFICE_SEARCH (DNS search suffixes, space- or comma-separated), OFFICE_WAIT (seconds to wait for an uplink).
#            Set them in the environment or in /etc/office-net.conf (OFFICE_SITE_CONF); nothing site-specific
#            (addresses, domains) is hard-coded here.
#
# "vpn" creates the namespace if it is missing and rebuilds it if it no longer matches the network
# (no carrier, or the uplink interface or gateway changed, e.g. after switching LAN <-> Wi-Fi), as long
# as no tunnel is running. "ensure" does the same without starting the tunnel.
# OFFICE_NO_AUTO_REFRESH=1 makes both stop with a message instead of rebuilding.
# Status: run on Wi-Fi (ipvlan) with address auto-selection and DNS auto-detection, tunnel stable for about
# 15 minutes. The wired path (macvlan) was also run through this script, with Wi-Fi connected, and the
# Fortigate path stayed stable for about 12 minutes.
set -eEuo pipefail

# Optional site settings. Only read when owned by root and not writable by group/others, because this
# script runs as root; values already in the environment win.
SITE_CONF="${OFFICE_SITE_CONF:-/etc/office-net.conf}"
if [ -f "$SITE_CONF" ]; then
  if [ "$(stat -c %u "$SITE_CONF")" = 0 ] && ! stat -c %A "$SITE_CONF" | cut -c6,9 | grep -q w; then
    while IFS='=' read -r k v; do
      case "$k" in OFFICE_[A-Z_]*) ;; *) continue ;; esac
      v="${v%%#*}"; v="${v%"${v##*[![:space:]]}"}"; v="${v#\"}"; v="${v%\"}"
      [ -n "$v" ] && [ -z "${!k:-}" ] && export "$k=$v"
    done < <(grep -E '^[[:space:]]*OFFICE_[A-Z_]+=' "$SITE_CONF" | sed 's/^[[:space:]]*//')
  else
    echo "office-netns: ignoring $SITE_CONF (must be owned by root and not group/world-writable)" >&2
  fi
fi

NS="${OFFICE_NS:-office}"
CONFIG="${OFFICE_CONFIG:-/etc/openfortivpn/config}"
STATE_DIR="${OFFICE_STATE_DIR:-/var/lib/office-netns}"
RUN_STATE="/run/office-netns.state"
VPN_LOG="/run/office-netns-vpn.log"
LINK="of-$NS"
WATCHER_PID=""      # global on purpose: the EXIT trap runs after vpn() has returned, when a "local" would be gone

die() { echo "office-netns: $*" >&2; exit 1; }
ns_exists() { ip netns list | grep -qw "$NS"; }
is_wifi() { [ -d "/sys/class/net/$1/wireless" ] || [ -d "/sys/class/net/$1/phy80211" ]; }

# "<iface> <gateway>" of the physical default route with the lowest metric
detect_uplink() {
  local dev gw found=0
  while read -r _ dev gw; do
    if [ "$found" -eq 0 ] && [ -e "/sys/class/net/$dev/device" ]; then
      echo "$dev $gw"; found=1
    fi
  done < <(ip -4 route show default | awk '{
      dev=""; gw=""; metric=0
      for (i=1;i<=NF;i++) { if ($i=="dev") dev=$(i+1); if ($i=="via") gw=$(i+1); if ($i=="metric") metric=$(i+1) }
      if (dev!="" && gw!="") print metric, dev, gw }' | sort -n)
}

# candidate addresses from the top of the subnet downwards
candidates() {
  python3 -c '
import ipaddress, sys
i = ipaddress.ip_interface(sys.argv[1]); gw = ipaddress.ip_address(sys.argv[2]); n = i.network
c = 0; k = 1
try:
    while c < 60 and k < n.num_addresses - 1:
        a = n.broadcast_address - k; k += 1
        if a in (i.ip, gw) or a == n.network_address:
            continue
        print(f"{a}/{n.prefixlen}", flush=True); c += 1
except BrokenPipeError:
    pass
' "$1" "$2"
}

addr_free() { arping -D -q -c 2 -w 4 -I "$1" "$2"; }

pick_addr() {
  local iface=$1 cidr=$2 gw=$3 net key saved cand
  command -v arping >/dev/null || die "arping not found (apt install iputils-arping) or set OFFICE_ADDR"
  net=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$cidr")
  key="$STATE_DIR/addr-${net//\//_}"
  mkdir -p "$STATE_DIR"
  if [ -r "$key" ]; then
    saved=$(cat "$key")
    if addr_free "$iface" "${saved%/*}"; then echo "$saved"; return 0; fi
  fi
  while read -r cand; do
    if addr_free "$iface" "${cand%/*}"; then
      echo "$cand" > "$key"; echo "$cand"; return 0
    fi
  done < <(candidates "$cidr" "$gw")
  die "no free address found in $net; set OFFICE_ADDR"
}

write_resolv() {
  local f="/etc/netns/$NS/resolv.conf" ip out=""
  for ip in "$@"; do
    case "$ip" in 0.0.0.0|"") continue ;; esac
    out+="nameserver $ip"$'\n'
  done
  [ -n "$out" ] || return 0
  if [ -n "${OFFICE_SEARCH:-}" ]; then
    local search
    search=$(printf '%s' "$OFFICE_SEARCH" | tr ',' ' ' | xargs)   # "a, b c" -> "a b c"
    [ -n "$search" ] && out+="search $search"$'\n'
  fi
  printf '%s' "$out" > "$f"      # in place, so running processes keep seeing the bind-mounted file
}

# reads "Got addresses: [..], ns [a, b]" from openfortivpn's output and applies it
watch_dns() {
  local last="" ns
  while sleep 1; do
    ns=$(tr -d '\r' < "$VPN_LOG" 2>/dev/null \
      | sed -n 's/.*Got addresses: \[[^]]*\], ns \[\([^]]*\)\].*/\1/p' | tail -1 | tr ',' ' ')
    if [ -n "$ns" ] && [ "$ns" != "$last" ]; then
      # shellcheck disable=SC2086
      write_resolv $ns
      last=$ns
      echo "office-netns: DNS for $NS set to: $ns" >&2
    fi
  done
}

up() {
  local iface gw cidr addr mode waited=0 wait_max="${OFFICE_WAIT:-20}"
  ns_exists && die "namespace $NS already exists; run '$0 refresh' or '$0 down'"

  while :; do
    if [ -n "${OFFICE_IFACE:-}" ]; then
      iface=$OFFICE_IFACE
      gw=${OFFICE_GW:-$(ip -4 route show default dev "$iface" | awk '/^default/ {print $3; exit}')}
    else
      read -r iface gw < <(detect_uplink) || true
      gw=${OFFICE_GW:-${gw:-}}
    fi
    cidr=
    [ -n "${iface:-}" ] && cidr=$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4; exit}')
    [ -n "${iface:-}" ] && [ -n "${gw:-}" ] && [ -n "$cidr" ] && break
    [ "$waited" -lt "$wait_max" ] || die "no usable uplink (need a physical interface with an IPv4 address and default gateway)"
    sleep 2; waited=$((waited + 2))
  done

  addr=${OFFICE_ADDR:-$(pick_addr "$iface" "$cidr" "$gw")}
  mode=${OFFICE_LINK:-}
  if [ -z "$mode" ]; then if is_wifi "$iface"; then mode=ipvlan; else mode=macvlan; fi; fi

  trap 'ip netns del "$NS" 2>/dev/null || true; ip link del "$LINK" 2>/dev/null || true' ERR
  ip netns add "$NS"
  case "$mode" in
    macvlan) ip link add link "$iface" name "$LINK" type macvlan mode bridge ;;
    ipvlan)  ip link add link "$iface" name "$LINK" type ipvlan mode l2 ;;
    *) die "OFFICE_LINK must be macvlan or ipvlan" ;;
  esac
  ip link set "$LINK" netns "$NS"
  ip -n "$NS" link set lo up
  ip -n "$NS" link set "$LINK" up
  ip -n "$NS" addr add "$addr" dev "$LINK"
  ip -n "$NS" route add default via "$gw"
  mkdir -p "/etc/netns/$NS"
  : > "/etc/netns/$NS/resolv.conf"       # filled in once the VPN is up; empty fails closed
  trap - ERR
  echo "$iface $mode $addr $gw" > "$RUN_STATE"
  echo "namespace $NS ready: $addr via $gw on $iface ($mode)"
  echo "check: ip netns exec $NS ping -c 5 <fortigate-ip>   # want the same low TTL as from the host without ExpressVPN"
}

cleanup_watcher() {
  if [ -n "${WATCHER_PID:-}" ]; then kill "$WATCHER_PID" 2>/dev/null || true; fi
}

# Prints why the namespace no longer matches the network the host is on (moved to another LAN or
# Wi-Fi, uplink changed, or the link has no carrier) and returns 0; returns 1 when it still matches.
# Starting the tunnel in a stale namespace fails with "connect: No route to host".
uplink_problem() {
  local s_iface="" s_gw="" c_iface="" c_gw="" link_info
  link_info=$(ip -n "$NS" link show "$LINK" 2>/dev/null || true)
  case "$link_info" in
    "") echo "$LINK is missing in namespace $NS"; return 0 ;;
    *NO-CARRIER*) echo "$LINK in namespace $NS has no carrier (the uplink went away or changed)"; return 0 ;;
  esac
  if [ -z "${OFFICE_IFACE:-}" ] && [ -r "$RUN_STATE" ]; then
    read -r s_iface _ _ s_gw < "$RUN_STATE" || true
    read -r c_iface c_gw < <(detect_uplink) || true
    c_gw=${OFFICE_GW:-$c_gw}
    if [ -n "$c_iface" ] && { [ "$c_iface" != "$s_iface" ] || [ "$c_gw" != "$s_gw" ]; }; then
      echo "the host uplink changed ($s_iface via $s_gw is now $c_iface via $c_gw)"; return 0
    fi
  fi
  return 1
}

# Make sure the namespace exists and matches the current network: create it if missing, rebuild it
# if stale. A running tunnel is left alone. Set OFFICE_NO_AUTO_REFRESH=1 to stop instead of rebuilding.
ensure() {
  local why
  if ! ns_exists; then
    echo "office-netns: namespace $NS is not up, creating it"
    up; return
  fi
  if ip -n "$NS" link show ppp0 >/dev/null 2>&1; then
    echo "office-netns: tunnel is already up in $NS"; return
  fi
  if why=$(uplink_problem); then
    [ -z "${OFFICE_NO_AUTO_REFRESH:-}" ] || die "$why; run '$0 refresh' and try again"
    echo "office-netns: $why; rebuilding namespace $NS (programs still running in it are stopped)"
    down; up
  else
    echo "office-netns: namespace $NS matches the current network, reusing it"
  fi
}

vpn() {
  command -v script >/dev/null || die "'script' (util-linux) not found"
  ensure
  if ip -n "$NS" link show ppp0 >/dev/null 2>&1; then
    die "the tunnel is already running in $NS (see '$0 status'); stop it first to start another"
  fi
  : > "$VPN_LOG"; chmod 600 "$VPN_LOG"
  watch_dns & WATCHER_PID=$!
  trap cleanup_watcher EXIT
  local cmd
  cmd=$(printf '%q ' ip netns exec "$NS" openfortivpn -c "$CONFIG" --set-dns=0 --pppd-use-peerdns=0 "$@")
  script -q -e -f -c "$cmd" "$VPN_LOG"
}

run() {
  [ $# -ge 1 ] || die "run <command...>"
  exec ip netns exec "$NS" sudo -u "${SUDO_USER:-root}" -H -- "$@"
}

status() {
  if ! ns_exists; then echo "namespace $NS: not up"; return 0; fi
  echo "namespace $NS: up"
  [ -r "$RUN_STATE" ] && echo "uplink/mode/address/gateway: $(cat "$RUN_STATE")"
  echo "--- addresses"; ip -n "$NS" -br addr
  echo "--- routes";    ip -n "$NS" route
  echo "--- dns";       cat "/etc/netns/$NS/resolv.conf" 2>/dev/null || true
  if ip -n "$NS" link show ppp0 >/dev/null 2>&1; then echo "tunnel: ppp0 present"; else echo "tunnel: not up"; fi
}

down() {
  if ns_exists; then
    ip netns pids "$NS" | xargs -r kill 2>/dev/null || true
    sleep 1
    ip netns del "$NS"
  fi
  rm -rf "/etc/netns/$NS" "$RUN_STATE"
  echo "namespace $NS removed"
}

main() {
  [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
  case "${1:-}" in
    up) up ;;
    vpn) shift; vpn "$@" ;;
    run) shift; run "$@" ;;
    ensure) ensure ;;
    status) status ;;
    refresh) down; up; echo "restart the tunnel with: $0 vpn" ;;
    down) down ;;
    *) echo "Usage: $0 up | vpn [args] | run <cmd...> | ensure | status | refresh | down" >&2; exit 1 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
