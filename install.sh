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
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETNS="$REPO/scripts/office-netns.sh"
TPL="$REPO/ubuntu/desktop"
BIN="$HOME/bin"
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
render() { sed -e "s|@REPO@|$REPO|g" -e "s|@HOME@|$HOME|g" "$1" > "$2"; }

check() {
  step "Check"
  for p in openfortivpn arping python3 script; do
    if command -v "$p" >/dev/null; then ok "$p"; else warn "$p missing"; fi
  done
  if sudo test -r "$VPN_CONFIG"; then ok "$VPN_CONFIG"; else warn "$VPN_CONFIG missing (host, port, username, trusted-cert)"; fi
  if [ -e "$OLD_DNS_HOOK" ]; then warn "$OLD_DNS_HOOK is enabled (should be .disabled for the namespace)"; else ok "old DNS hook disabled"; fi
  for f in office-vpn-start.sh office-bashrc; do
    if [ -f "$BIN/$f" ]; then ok "$BIN/$f"; else warn "$BIN/$f missing"; fi
  done
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
  sed -i '/# office-net alias/,+1d' "$HOME/.bashrc" 2>/dev/null || true
  ok "icons, ~/bin files and the office alias removed"
  echo "Kept: packages, $VPN_CONFIG, ~/.mozilla-office, ~/.vscode-office. Run 'sudo bash $NETNS down' to remove a running namespace."
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

  step "Scripts in $BIN"
  mkdir -p "$BIN" "$HOME/.mozilla-office" "$HOME/.vscode-office"
  chmod +x "$NETNS" 2>/dev/null || true   # repo may be on a drive without Unix permissions; icons call it with bash anyway
  render "$TPL/office-vpn-start.sh" "$BIN/office-vpn-start.sh"
  chmod +x "$BIN/office-vpn-start.sh"
  render "$TPL/office-bashrc" "$BIN/office-bashrc"
  ok "office-vpn-start.sh, office-bashrc"

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
    sed -i "/# office-net alias/{n;s|.*|alias office='sudo bash $NETNS run'|}" "$HOME/.bashrc"
  else
    printf '\n# office-net alias\nalias office='"'"'sudo bash %s run'"'"'\n' "$NETNS" >> "$HOME/.bashrc"
  fi
  ok "alias office='sudo bash $NETNS run' (new terminals; e.g. 'office git pull')"

  check

  cat <<EOF

Done. Next:
  1. If an icon shows "Untrusted", right-click it and choose "Allow Launching".
  2. Click "Office VPN (start)", enter the sudo and VPN passwords, keep that window open.
  3. Open Firefox, Terminal or VS Code (Office VPN); each asks for sudo in a small window.
  After changing networks: sudo bash $NETNS refresh, then click the VPN icon again.
EOF
}

case "${1:-}" in
  ""|--install) install ;;
  --check)      check ;;
  --uninstall)  uninstall ;;
  *) die "usage: bash install.sh [--check | --uninstall]" ;;
esac
