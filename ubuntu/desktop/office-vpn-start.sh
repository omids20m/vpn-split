#!/bin/bash
# Installed to /usr/local/bin/office-vpn-start (owner root, mode 755) by install.sh.
# Starts the VPN in the office namespace. office-netns.sh creates the namespace if it is missing
# and rebuilds it if the network changed (no carrier, other LAN/Wi-Fi), so no manual refresh is needed.
# If the VPN is already connected, prints status and exits.
S=@NETNS@      # root-owned copy; the repo copy is user-writable and must not run as root

echo "== Office VPN =="
sudo -v || exit 1

if sudo ip -n office link show ppp0 >/dev/null 2>&1; then
  echo
  echo "VPN is already connected. Status:"
  echo
  sudo "$S" status
  echo
  read -rp "Press Enter to close"
  exit 0
fi

echo
echo "Starting VPN. Enter the VPN password when asked. Keep this window open."
sudo "$S" vpn || true

echo
echo "VPN stopped."
read -rp "Press Enter to close"
