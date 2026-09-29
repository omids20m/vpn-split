# Conversation summary

**Problem:** ExpressVPN and the corporate FortiGate VPN conflict when both are connected. Each wants the default route and DNS.

**Approaches considered**
1. Run both clients on the host: routes and DNS collide. Rejected as the default.
2. Windows: keep FortiClient for the office tunnel, use ExpressVPN app split tunneling so the two do not overlap.
3. Ubuntu: run openfortivpn inside a Linux network namespace, so its routes and DNS never touch the host or ExpressVPN.

**Decisions**
- Ubuntu: network namespace with openfortivpn (see namespace-solutions.md).
- Windows: FortiClient plus ExpressVPN split tunneling (app and gateway-IP bypass only), NRPT rule for internal DNS, connect ExpressVPN first. Details in windows-README.md.

**Status:** reported as tested and working on Windows and Ubuntu. Windows steps come from the tested README (windows-README.md). The Ubuntu namespace script was reconstructed and has not been run; verify it against your working setup.
