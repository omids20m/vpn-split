#!/bin/bash
# Installed to ~/bin/office-vpn-start.sh by install.sh.
# Starts the VPN in the office namespace. office-netns.sh creates the namespace if it is missing
# and rebuilds it if the network changed (no carrier, other LAN/Wi-Fi), so no manual refresh is needed.
# If the VPN is already connected, prints status and exits.
S=@REPO@/scripts/office-netns.sh

echo "== Office VPN =="
sudo -v || exit 1

if sudo ip -n office link show ppp0 >/dev/null 2>&1; then
  echo
  echo "VPN is already connected. Status:"
  echo
  sudo bash "$S" status
  echo
  read -rp "Press Enter to close"
  exit 0
fi

echo
echo "Starting VPN. Enter the VPN password when asked. Keep this window open."
sudo bash "$S" vpn || true

echo
echo "VPN stopped."
read -rp "Press Enter to close"
