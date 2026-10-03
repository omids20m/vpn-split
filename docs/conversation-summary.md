# Conversation summary

**Problem:** ExpressVPN and the corporate FortiGate VPN conflict when both are connected. Each wants the default route and DNS.

**Approaches considered**
1. Run both clients on the host: routes and DNS collide. Rejected as the default.
2. Windows: keep FortiClient for the office tunnel, use ExpressVPN app split tunneling so the two do not overlap.
3. Ubuntu: run openfortivpn inside a Linux network namespace, so its routes and DNS never touch the host or ExpressVPN.

**Decisions**
- Ubuntu: network namespace with openfortivpn (see namespace-solutions.md). Chosen 2026-10-03 after route-pinning and DNS workarounds on the host failed to keep the tunnel up. Macvlan uplink tried first and worked; veth + NAT was not needed.
- Windows: FortiClient plus ExpressVPN split tunneling (app and gateway-IP bypass only), NRPT rule for internal DNS, connect ExpressVPN first. Details in windows-README.md.

**Status:** Windows is tested and working (windows-README.md). Ubuntu works with the namespace. Wired (macvlan, by hand): the tunnel stayed up for about 10 minutes with the Fortigate reached directly (TTL 247). Wi-Fi (ipvlan, through `scripts/office-netns.sh`): the script auto-detected interface, gateway, link type and a free address, the office DNS servers were picked up automatically, and the tunnel stayed up for about 15 minutes; internal DNS and TCP to the git host worked, the host unaffected. Host-side fixes (route-pinning watchdogs, DNS exception) did not keep the tunnel up. Still to verify: multi-hour stability, `git`/`ssh`/browser as the normal user, behaviour after a reboot, switching back to wired, and persistence plus a short `office <command>` prefix (designed, not built). Details in ubuntu-README.md.
