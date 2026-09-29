#!/usr/bin/env bash
# Run openfortivpn inside a network namespace so it cannot alter host routes/DNS.
# Usage: office-netns.sh up | vpn <host:port> <user> | down
set -euo pipefail
NS=office; VH=veth-host; VN=veth-office
HIP=10.200.200.1; NIP=10.200.200.2; NET=10.200.200.0/24
DNS="${OFFICE_DNS:-1.1.1.1}"   # replace with office DNS once known

case "${1:-}" in
up)
  ip netns add "$NS" 2>/dev/null || true
  ip link add "$VH" type veth peer name "$VN" 2>/dev/null || true
  ip link set "$VN" netns "$NS" 2>/dev/null || true
  ip addr add $HIP/24 dev "$VH" 2>/dev/null || true
  ip link set "$VH" up
  ip -n "$NS" addr add $NIP/24 dev "$VN" 2>/dev/null || true
  ip -n "$NS" link set "$VN" up
  ip -n "$NS" link set lo up
  ip -n "$NS" route replace default via $HIP
  sysctl -q net.ipv4.ip_forward=1
  iptables -t nat -C POSTROUTING -s $NET -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s $NET -j MASQUERADE
  mkdir -p /etc/netns/$NS
  echo "nameserver $DNS" > /etc/netns/$NS/resolv.conf
  echo "namespace $NS ready"
  ;;
vpn)
  [ $# -eq 3 ] || { echo "vpn <host:port> <user>"; exit 1; }
  # openfortivpn sets its own routes/DNS, but only inside the namespace
  exec ip netns exec "$NS" openfortivpn "$2" -u "$3" --pppd-use-peerdns=1 --set-dns=1
  ;;
down)
  ip netns exec "$NS" pkill openfortivpn 2>/dev/null || true
  iptables -t nat -D POSTROUTING -s $NET -j MASQUERADE 2>/dev/null || true
  ip link del "$VH" 2>/dev/null || true
  ip netns del "$NS" 2>/dev/null || true
  rm -rf /etc/netns/$NS
  echo "namespace $NS removed"
  ;;
*) echo "Usage: $0 up | vpn <host:port> <user> | down"; exit 1;;
esac
