# Office namespace desktop icons (Ubuntu)

Launchers for using the `office` network namespace (see `docs/ubuntu-README.md`). User `omid`; repo at `/mnt/e/repos/office-net`.

| File | Install to | Purpose |
|---|---|---|
| `office-vpn-start.sh` | `~/bin/` (chmod +x) | Creates the namespace if missing, starts the VPN; if already connected prints status only |
| `office-vpn-start.desktop` | `~/Desktop/` | Icon for the script above, 90x5 terminal |
| `office-firefox.desktop` | `~/Desktop/` | Firefox (Mozilla tarball in `~/firefox-office`, profile `~/.mozilla-office`) in the namespace |
| `office-terminal.desktop` | `~/Desktop/` | Shell in the namespace, prompt prefixed `[OFFICE]` |
| `office-bashrc` | `~/bin/` | rc file used by the terminal icon |
| `office-vscode.desktop` | `~/Desktop/` | VS Code in the namespace, separate user-data dir `~/.vscode-office` |

## Install

```bash
cd /mnt/e/repos/office-net/scripts/desktop-icons
mkdir -p ~/bin ~/.mozilla-office ~/.vscode-office
cp office-vpn-start.sh office-bashrc ~/bin/
cp *.desktop ~/Desktop/
chmod +x ~/bin/office-vpn-start.sh ~/Desktop/office-*.desktop
```
Right-click each icon on the desktop and choose **Allow Launching**.

## Use

1. Click **Office VPN (start)**, enter the sudo and VPN passwords, keep that window open.
2. Then open **Firefox**, **Terminal** or **VS Code** (Office VPN). Each asks for the sudo password in its own small terminal window; keep it open while the app runs.
3. One-off commands from any terminal: `sudo bash /mnt/e/repos/office-net/scripts/office-netns.sh run git pull`, or add `alias office='sudo bash /mnt/e/repos/office-net/scripts/office-netns.sh run'`.

## Notes

- Firefox and VS Code must not be the snap builds (snap fails with "cannot find tracking cgroup" under `sudo`). Use the Mozilla tarball and the VS Code `.deb`.
- The separate profile / user-data dir stops the app from handing its window to an already-running instance outside the namespace.
- After changing networks, run `office-netns.sh refresh`, then click the VPN icon again.
- Change window height by editing `--geometry=90x5` in the `.desktop` files.
