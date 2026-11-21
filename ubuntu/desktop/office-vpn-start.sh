#!/bin/bash
# Installed to ~/bin/office-vpn-start.sh by install.sh.
# Builds the office namespace if missing, then starts the VPN inside it.
# If the VPN is already connected, prints status and exits.
S=@REPO@/scripts/office-netns.sh

echo "== Office VPN =="
sudo -v || exit 1

if ip netns list | grep -qw office; then
  echo "Namespace already exists, reusing it."
else
  sudo bash "$S" up || { read -rp "up failed, press Enter to close"; exit 1; }
fi

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
sudo bash "$S" vpn

echo
echo "VPN stopped."
read -rp "Press Enter to close"
