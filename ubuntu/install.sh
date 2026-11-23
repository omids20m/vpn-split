#!/usr/bin/env bash
# Ubuntu installer for office-net: openfortivpn in the "office" network namespace,
# plus desktop icons for the VPN, a terminal, Firefox and VS Code inside it.
#
# Run as your normal user from the repo (it uses sudo where needed):
#   bash ubuntu/install.sh             install / update everything
#   bash ubuntu/install.sh --check     only report what is installed and what is missing
#   bash ubuntu/install.sh --configure  ask for the VPN and site settings again (current values are the defaults), then install
#   bash ubuntu/install.sh --uninstall remove the icons and ~/bin files (packages and VPN config are kept)
#
# Settings: when /etc/openfortivpn/config or /etc/office-net.conf is missing and the script runs in a terminal,
# it asks for the values (Fortigate host, port, username, certificate pin; DNS search suffixes) and writes the
# files, owned by root. Without a terminal it only prints what to create. The VPN password is never stored.
#
# Safe to run again: every step overwrites or skips what is already there.
#
# Security: everything that runs as root is copied to root-owned locations
# (/usr/local/sbin/office-netns, /usr/local/bin/office-vpn-start). The repo on /mnt/e has no Unix
# permissions, so any program running as you could edit scripts there; running them with sudo would hand
# that program root. After changing ubuntu/office-netns.sh in the repo, run ubuntu/install.sh again to deploy it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # ubuntu/ folder of the repo
REPO="$(dirname "$HERE")"
NETNS="$HERE/office-netns.sh"
TPL="$HERE/desktop"
BIN="$HOME/bin"
SBIN_NETNS=/usr/local/sbin/office-netns          # root-owned copy of ubuntu/office-netns.sh
VPN_START=/usr/local/bin/office-vpn-start        # root-owned launcher used by the "Office VPN" icon
DESKTOP="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
VPN_CONFIG=/etc/openfortivpn/config
OLD_DNS_HOOK="${OFFICE_OLD_DNS_HOOK:-/etc/ppp/ip-up.d/office-dns}"   # host-side DNS hook from the pre-namespace setup
SITE_CONF=/etc/office-net.conf                    # optional site settings read by office-netns
ICONS=(office-vpn-start office-terminal office-firefox office-vscode)

ok()   { printf '  \e[32mok\e[0m    %s\n' "$*"; }
warn() { printf '  \e[33mwarn\e[0m  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "run as your normal user, not with sudo (it calls sudo itself)"
[ -f "$NETNS" ] || die "office-netns.sh not found next to install.sh"
[ -d "$TPL" ]   || die "desktop/ templates not found next to install.sh"

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

# ---------- interactive settings ----------
INTERACTIVE=0; [ -t 0 ] && [ -t 1 ] && INTERACTIVE=1
RECONFIGURE=0

# ask "<prompt>" "<default>" "<regex>" -> echoes the answer; "-" clears an optional value
ask() {
  local prompt=$1 def=$2 re=$3 ans
  while :; do
    if [ -n "$def" ]; then read -rp "  $prompt [$def]: " ans </dev/tty; else read -rp "  $prompt: " ans </dev/tty; fi
    ans=${ans:-$def}
    [ "$ans" = "-" ] && ans=""
    if [ -z "$ans" ] || [[ "$ans" =~ $re ]]; then printf '%s' "$ans"; return 0; fi
    echo "    not valid, try again" >/dev/tty
  done
}

# value of "key = value" in the openfortivpn config (empty if missing)
vpn_get() { { sudo cat "$VPN_CONFIG" 2>/dev/null || true; } | sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" | tail -1; }

# sha256 of the gateway certificate, as openfortivpn's trusted-cert wants it
fetch_cert_pin() {
  command -v openssl >/dev/null || return 1
  timeout 15 openssl s_client -connect "$1:$2" -servername "$1" </dev/null 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f'
}

configure_vpn() {
  local host port user pin fetched tmp
  echo "  openfortivpn settings (the VPN password is not stored; you type it when connecting)"
  host=$(ask "Fortigate host name or IP" "$(vpn_get host)" '^[A-Za-z0-9.-]+$')
  [ -n "$host" ] || die "a Fortigate host is required"
  port=$(ask "Port" "$(vpn_get port)" '^[0-9]{1,5}$'); port=${port:-443}
  user=$(ask "VPN username" "$(vpn_get username)" '^[^[:space:]=#]+$')
  [ -n "$user" ] || die "a VPN username is required"
  pin=$(vpn_get trusted-cert)
  echo "  Reading the gateway certificate from $host:$port ..."
  if fetched=$(fetch_cert_pin "$host" "$port") && [ ${#fetched} -eq 64 ]; then
    echo "    sha256: $fetched"
    [ -n "$pin" ] && [ "$pin" != "$fetched" ] && echo "    (differs from the pin in the current config: $pin)"
    echo "    Compare it with the value from IT or from openfortivpn's own error message if you can."
    case "$(ask "Pin this certificate? (y/n)" "y" '^[yYnN]$')" in [yY]) pin=$fetched ;; esac
  else
    echo "    could not read it (gateway unreachable or openssl missing)."
  fi
  pin=$(ask "trusted-cert sha256 (64 hex chars; '-' = leave out, openfortivpn then prints it on first connect)" "$pin" '^[0-9a-f]{64}$')

  tmp=$(mktemp)
  {
    echo "# written by office-net install.sh; edit with 'bash ubuntu/install.sh --configure'"
    echo "host = $host"
    echo "port = $port"
    echo "username = $user"
    [ -n "$pin" ] && echo "trusted-cert = $pin"
    # keep any other options that were already in the file
    sudo cat "$VPN_CONFIG" 2>/dev/null | grep -vE '^[[:space:]]*(host|port|username|trusted-cert|password)[[:space:]]*=|^# written by office-net' || true
  } > "$tmp"
  sudo install -d -o root -g root -m 0755 "$(dirname "$VPN_CONFIG")"
  sudo install -o root -g root -m 0600 "$tmp" "$VPN_CONFIG"
  rm -f "$tmp"
  ok "$VPN_CONFIG written (owner root, mode 600)"
}

configure_site() {
  local cur search tmp src
  cur=$({ sed -n 's/^[[:space:]]*OFFICE_SEARCH=//p' "$SITE_CONF" 2>/dev/null || true; } | sed 's/[[:space:]]*#.*//; s/"//g' | tail -1)
  echo "  Namespace settings (everything else is detected automatically)"
  search=$(ask "DNS search suffixes inside the namespace, space- or comma-separated ('-' = none)" "$cur" '^[A-Za-z0-9.-]+([ ,]+[A-Za-z0-9.-]+)*$')
  search=$(printf '%s' "$search" | tr ',' ' ' | xargs)
  src="$SITE_CONF"; [ -f "$src" ] || src="$HERE/office-net.conf.example"
  tmp=$(mktemp)
  if [ -n "$search" ]; then
    sed -E "s|^[[:space:]]*#?[[:space:]]*OFFICE_SEARCH=.*|OFFICE_SEARCH=\"$search\"|" "$src" > "$tmp"
  else
    sed -E "s|^[[:space:]]*OFFICE_SEARCH=.*|#OFFICE_SEARCH=|" "$src" > "$tmp"
  fi
  sudo install -o root -g root -m 0644 "$tmp" "$SITE_CONF"
  rm -f "$tmp"
  ok "$SITE_CONF written (owner root, mode 644)"
}

check() {
  step "Check"
  for p in openfortivpn arping python3 script; do
    if command -v "$p" >/dev/null; then ok "$p"; else warn "$p missing"; fi
  done
  if sudo test -r "$VPN_CONFIG"; then ok "$VPN_CONFIG"; else warn "$VPN_CONFIG missing (host, port, username, trusted-cert)"; fi
  if [ -f "$SITE_CONF" ]; then ok "$SITE_CONF"; else warn "$SITE_CONF missing (optional; install.sh creates it)"; fi
  if [ -e "$OLD_DNS_HOOK" ]; then warn "$OLD_DNS_HOOK is enabled (should be .disabled for the namespace)"; else ok "old DNS hook disabled"; fi
  for f in "$SBIN_NETNS" "$VPN_START"; do
    if root_only "$f"; then ok "$f (root-owned)"; else warn "$f missing or writable by non-root"; fi
  done
  if root_only "$SBIN_NETNS" && ! cmp -s "$NETNS" "$SBIN_NETNS"; then
    warn "$SBIN_NETNS differs from the repo copy (run ubuntu/install.sh again to deploy repo changes)"
  fi
  if [ -f "$BIN/office-bashrc" ]; then ok "$BIN/office-bashrc"; else warn "$BIN/office-bashrc missing"; fi
  if [ -e "$BIN/office-vpn-start.sh" ]; then warn "$BIN/office-vpn-start.sh is left over from an older install (run ubuntu/install.sh to remove it)"; fi
  if grep -q "office-netns.sh run" "$HOME/.bashrc" 2>/dev/null; then warn "'office' alias still points at the repo script (run ubuntu/install.sh)"; fi
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
  echo "Kept: packages, $VPN_CONFIG, $SITE_CONF, ~/.mozilla-office, ~/.vscode-office. Run 'sudo $SBIN_NETNS down' (before uninstalling) to remove a running namespace."
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
  if sudo test -r "$VPN_CONFIG" && [ "$RECONFIGURE" -eq 0 ]; then
    ok "$VPN_CONFIG exists (change it with: bash ubuntu/install.sh --configure)"
  elif [ "$INTERACTIVE" -eq 1 ]; then
    configure_vpn
  else
    warn "$VPN_CONFIG is missing. Run 'bash ubuntu/install.sh --configure' in a terminal, or create it (no password in it):"
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

  step "Site settings"
  if [ -f "$SITE_CONF" ] && [ "$RECONFIGURE" -eq 0 ]; then
    ok "$SITE_CONF exists (change it with: bash ubuntu/install.sh --configure)"
  elif [ "$INTERACTIVE" -eq 1 ]; then
    configure_site
  else
    sudo install -o root -g root -m 0644 "$HERE/office-net.conf.example" "$SITE_CONF"
    ok "$SITE_CONF created from ubuntu/office-net.conf.example (all values commented out = auto-detect)"
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
  After editing ubuntu/office-netns.sh in the repo: run 'bash ubuntu/install.sh' again to deploy it.
EOF
}

case "${1:-}" in
  ""|--install) install ;;
  --configure)  [ "$INTERACTIVE" -eq 1 ] || die "--configure needs a terminal"; RECONFIGURE=1; install ;;
  --check)      check ;;
  --uninstall)  uninstall ;;
  *) die "usage: bash ubuntu/install.sh [--configure | --check | --uninstall]" ;;
esac
