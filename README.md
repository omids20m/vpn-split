# office-net

Running a corporate FortiGate SSL VPN alongside ExpressVPN, on Windows and Ubuntu.

| File | Purpose |
|------|---------|
| docs/requirements.md | What the setup must do |
| docs/conversation-summary.md | Summary of the discussion and decisions |
| docs/windows-README.md | Tested Windows procedure: ExpressVPN + FortiClient, DNS, diagnostics, rollback |
| docs/namespace-solutions.md | Windows and Ubuntu solutions (Ubuntu uses a Linux network namespace) |
| scripts/office-netns.sh | Ubuntu: openfortivpn inside a network namespace |

Scope: ExpressVPN, FortiClient, openfortivpn only. No other infrastructure details are recorded here.
