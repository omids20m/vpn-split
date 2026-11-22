#!/usr/bin/env bash
# Ubuntu installer for office-net: openfortivpn in the "office" network namespace,
# plus desktop icons for the VPN, a terminal, Firefox and VS Code inside it.
#
# Run as your normal user from the repo (it uses sudo where needed):
#   bash install.sh             install / update everything
#   bash install.sh --check     only report what is installed and what is missing
#   bash install.sh --uninstall remove the icons and ~/bin files (packages and VPN config are kept)
#
# Safe to run again: every step overwrites or skips what is already there.
#
# Security: everything that runs as root is copied to root-owned locations
# (/usr/local/sbin/office-netns, /usr/local/bin/office-vpn-start). The repo on /mnt/e has no Unix
# permissions, so any program running as you could edit scripts there; running them with sudo would hand
# that program root. After changing scripts/office-netns.sh in the repo, run install.sh again to deploy it.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETNS="$REPO/scripts/office-netns.sh"
TPL="$REPO/ubuntu/desktop"
BIN="$HOME/bin"
SBIN_NETNS=/usr/local/sbin/office-netns          # root-owned copy of scripts/office-netns.sh
VPN_START=/usr/local/bin/office-vpn-start        # root-owned launcher used by the "Office VPN" icon
DESKTOP="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
VPN_CONFIG=/etc/openfortivpn/config
OLD_DNS_HOOK=/etc/ppp/ip-up.d/office-dns
ICONS=(office-vpn-start office-terminal office-firefox office-vscode)

ok()   { printf '  \e[32mok\e[0m    %s\n' "$*"; }
warn() { printf '  \e[33mwarn\e[0m  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "run as your normal user, not with sudo (it calls sudo itself)"
[ -f "$NETNS" ] || die "scripts/office-netns.sh not found next to install.sh"
[ -d "$TPL" ]   || die "ubuntu/desktop/ templates not found next to install.sh"

# copy a template, filling in the repo and home paths
render() {
  sed -e "s|@REPO@|$REPO|g" -e "s|@HOME@|$HOME|g" \
      -e "s|@NETNS@|$SBIN_NETNS|g" -e "s|@VPNSTART@|$VPN_START|g" "$1" > "$2"
}

# copy a file to a root-owned path, mode 755 (install(1) sets owner, group and mode in one step)
install_root() { sudo install -o root -g root -m 0755 "$1" "$2"; }

# ok when the file exists, is owned by root and is not writable by group or others
root_only() {
  [ -f "$1" ] && [ "$(stat -c %u "$1")" = 0 ] && ! stat -c %A "$1" | cut -c6,9 | grep -q w
}

check() {
  step "Check"
  for p in openfortivpn arping python3 script; do
    if command -v "$p" >/dev/null; then ok "$p"; else warn "$p missing"; fi
  done
  if sudo test -r "$VPN_CONFIG"; then ok "$VPN_CONFIG"; else warn "$VPN_CONFIG missing (host, port, username, trusted-cert)"; fi
  if [ -e "$OLD_DNS_HOOK" ]; then warn "$OLD_DNS_HOOK is enabled (should be .disabled for the namespace)"; else ok "old DNS hook disabled"; fi
  for f in "$SBIN_NETNS" "$VPN_START"; do
    if root_only "$f"; then ok "$f (root-owned)"; else warn "$f missing or writable by non-root"; fi
  done
  if root_only "$SBIN_NETNS" && ! cmp -s "$NETNS" "$SBIN_NETNS"; then
    warn "$SBIN_NETNS differs from the repo copy (run install.sh again to deploy repo changes)"
  fi
  if [ -f "$BIN/office-bashrc" ]; then ok "$BIN/office-bashrc"; else warn "$BIN/office-bashrc missing"; fi
  if [ -e "$BIN/office-vpn-start.sh" ]; then warn "$BIN/office-vpn-start.sh is left over from an older install (run install.sh to remove it)"; fi
  if grep -q "office-netns.sh run" "$HOME/.bashrc" 2>/dev/null; then warn "'office' alias still points at the repo script (run install.sh)"; fi
  for i in "${ICONS[@]}"; do
    if [ -f "$DESKTOP/$i.desktop" ]; then ok "$DESKTOP/$i.desktop"; else warn "$DESKTOP/$i.desktop missing"; fi
  done
  if [ -x "$HOME/firefox-office/firefox" ]; then ok "Firefox tarball in ~/firefox-office"; else warn "~/firefox-office/firefox missing (Firefox icon will not work)"; fi
  if command -v code >/dev/null && [ "$(command -v code)" != /snap/bin/code ]; then ok "VS Code (.deb)"; else warn "VS Code .deb not found (snap build does not work under sudo)"; fi
  if ip netns list 2>/dev/null | grep -qw office; then ok "namespace office is up"; else ok "namespace office is not up (start it with the Office VPN icon)"; fi
}

uninstall() {
  step "Uninstall"
  for i in "${ICONS[@]}"; do rm -f "$DESKTOP/$i.desktop"; done
  rm -f "$BIN/office-vpn-start.sh" "$BIN/office-bashrc"
  sudo rm -f "$SBIN_NETNS" "$VPN_START"
  sed -i '/# office-net alias/,+1d' "$HOME/.bashrc" 2>/dev/null || true
  ok "icons, $SBIN_NETNS, $VPN_START, ~/bin files and the office alias removed"
  echo "Kept: packages, $VPN_CONFIG, ~/.mozilla-office, ~/.vscode-office. Run 'sudo $SBIN_NETNS down' (before uninstalling) to remove a running namespace."
}

install() {
  step "Packages (openfortivpn, arping, python3, util-linux)"
  local need=()
  command -v openfortivpn >/dev/null || need+=(openfortivpn)
  command -v arping >/dev/null       || need+=(iputils-arping)
  command -v python3 >/dev/null      || need+=(python3)
  command -v script >/dev/null       || need+=(util-linux)
  if [ ${#need[@]} -gt 0 ]; then
    sudo apt-get update -qq
    sudo apt-get install -y "${need[@]}"
  fi
  ok "packages present"

  step "openfortivpn config"
  if sudo test -r "$VPN_CONFIG"; then
    ok "$VPN_CONFIG exists"
  else
    warn "$VPN_CONFIG is missing. Create it (no password in it; the VPN asks for it):"
    echo "        host = <fortigate-host>"
    echo "        port = <port>"
    echo "        username = <user>"
    echo "        trusted-cert = <sha256 from the first connection attempt>"
  fi

  step "Old host DNS hook"
  if [ -e "$OLD_DNS_HOOK" ]; then
    sudo mv "$OLD_DNS_HOOK" "$OLD_DNS_HOOK.disabled"
    ok "renamed to $OLD_DNS_HOOK.disabled (not used inside the namespace)"
  else
    ok "not enabled"
  fi

  step "Root-owned scripts"
  local tmp
  tmp=$(mktemp)
  install_root "$NETNS" "$SBIN_NETNS"
  render "$TPL/office-vpn-start.sh" "$tmp"
  install_root "$tmp" "$VPN_START"
  rm -f "$tmp"
  ok "$SBIN_NETNS, $VPN_START (owner root, mode 755)"

  step "Files in $BIN"
  mkdir -p "$BIN" "$HOME/.mozilla-office" "$HOME/.vscode-office"
  rm -f "$BIN/office-vpn-start.sh"       # older installs ran this user-writable copy; now $VPN_START
  render "$TPL/office-bashrc" "$BIN/office-bashrc"   # sourced by your own shell, never as root
  ok "office-bashrc"

  step "Desktop icons in $DESKTOP"
  mkdir -p "$DESKTOP"
  for i in "${ICONS[@]}"; do
    render "$TPL/$i.desktop" "$DESKTOP/$i.desktop"
    chmod +x "$DESKTOP/$i.desktop"
    # mark as trusted so GNOME launches it without "Allow Launching" (works when a desktop session is running)
    gio set "$DESKTOP/$i.desktop" metadata::trusted true 2>/dev/null || true
    ok "$i.desktop"
  done

  step "Shell alias"
  if grep -q '# office-net alias' "$HOME/.bashrc" 2>/dev/null; then
    sed -i "/# office-net alias/{n;s|.*|alias office='sudo $SBIN_NETNS run'|}" "$HOME/.bashrc"
  else
    printf '\n# office-net alias\nalias office='"'"'sudo %s run'"'"'\n' "$SBIN_NETNS" >> "$HOME/.bashrc"
  fi
  ok "alias office='sudo $SBIN_NETNS run' (new terminals; e.g. 'office git pull')"

  check

  cat <<EOF

Done. Next:
  1. If an icon shows "Untrusted", right-click it and choose "Allow Launching".
  2. Click "Office VPN (start)", enter the sudo and VPN passwords, keep that window open.
  3. Open Firefox, Terminal or VS Code (Office VPN); each asks for sudo in a small window.
  After changing networks: sudo office-netns refresh, then click the VPN icon again.
  After editing scripts/office-netns.sh in the repo: run 'bash install.sh' again to deploy it.
EOF
}

case "${1:-}" in
  ""|--install) install ;;
  --check)      check ;;
  --uninstall)  uninstall ;;
  *) die "usage: bash install.sh [--check | --uninstall]" ;;
esac
