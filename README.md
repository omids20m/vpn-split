# office-net

Running a corporate FortiGate SSL VPN alongside ExpressVPN, on Windows and Ubuntu.

## Ubuntu install

```bash
cd /mnt/e/repos/office-net
bash install.sh            # packages, root-owned scripts, desktop icons, 'office' alias
bash install.sh --configure  # ask for the VPN and namespace settings again, then install
bash install.sh --check    # report only
bash install.sh --uninstall
```

On the first run in a terminal, `install.sh` asks for the Fortigate host, port and username, reads the gateway's certificate and offers to pin it, and asks for the DNS search suffixes (one or more); it writes `/etc/openfortivpn/config` (root, 600) and `/etc/office-net.conf` (root, 644). The VPN password is never stored. On Windows, `office-dns-permit.ps1 -Install` likewise asks for the DNS servers, internal suffixes (one or more) and test host when they are missing (`-Configure` asks again).

The scripts that run with sudo are installed as root-owned copies (`/usr/local/sbin/office-netns`, `/usr/local/bin/office-vpn-start`), because the repo on `/mnt/e` can be edited by any program running as you. After changing `scripts/office-netns.sh`, run `bash install.sh` again to deploy it.

| File | Purpose |
|------|---------|
| docs/requirements.md | What the setup must do |
| docs/conversation-summary.md | Summary of the discussion and decisions |
| docs/windows-README.md | Tested Windows procedure: ExpressVPN + FortiClient, DNS, diagnostics, rollback |
| docs/ubuntu-README.md | Ubuntu: ExpressVPN + openfortivpn in a network namespace (tested by hand), test results, what did not work |
| docs/namespace-solutions.md | Windows and Ubuntu solutions (Ubuntu uses a Linux network namespace) |
| docs/expressvpn-fortigate-windows-dns.md | Windows: ExpressVPN WFP port 53 block and the permit-filter fix for internal DNS |
| docs/expressvpn-openfortivpn-ubuntu.md | Ubuntu: namespace script usage, troubleshooting, host DNS workaround and history |
| scripts/office-netns.sh | Ubuntu: openfortivpn inside a network namespace (macvlan NIC); `up`, `vpn`, `run`, `down` |
| install.sh | Ubuntu: installs openfortivpn/arping, disables the old host DNS hook, copies the root-run scripts to root-owned paths, installs the desktop icons |
| ubuntu/desktop/ | Templates for the Office VPN, Terminal, Firefox and VS Code icons (paths filled in by install.sh); these are the ones install.sh uses |
| scripts/office-dns-permit.ps1 | Windows: adds WFP permits for DNS to the internal resolvers; installs to `C:\Program Files\office-net` with an admin-only ACL; `-Install`, `-Status`, `-Uninstall` |
| scripts/office-dns.example.psd1 | Windows: template for `office-dns.psd1` (resolver IPs, DNS suffix, test host; the real file is git-ignored) |
| ubuntu/office-net.conf.example | Ubuntu: template for `/etc/office-net.conf` (optional overrides such as the DNS search suffixes) |

Scope: ExpressVPN, FortiClient, openfortivpn only. The scripts contain no site addresses or domain names: they come from the git-ignored config files above (or are detected at run time). The docs use placeholders instead of real values: `office-domain.example` for the internal domain, `203.0.113.10` for the Fortigate gateway, `10.30.0.0/16` and `10.31.0.0/16` for the corporate ranges (internal DNS `10.30.63.2`, `10.30.63.3`), and `198.51.100.x` for public addresses seen in tests. LAN addresses (`192.168.x.x`) are examples too.
