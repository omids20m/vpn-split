# office-net

Running a corporate FortiGate SSL VPN alongside ExpressVPN, on Windows and Ubuntu.

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
| scripts/office-dns-permit.ps1 | Windows: adds the WFP permit for DNS to the internal resolvers; `-Install`, `-Status`, `-Uninstall` |

Scope: ExpressVPN, FortiClient, openfortivpn only. No other infrastructure details are recorded here.
