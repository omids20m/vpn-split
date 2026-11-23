# Conversation summary

**Problem:** ExpressVPN and the corporate FortiGate VPN conflict when both are connected. Each wants the default route and DNS.

**Approaches considered**
1. Run both clients on the host: routes and DNS collide. Rejected as the default.
2. Windows: keep FortiClient for the office tunnel, use ExpressVPN app split tunneling so the two do not overlap.
3. Ubuntu: run openfortivpn inside a Linux network namespace, so its routes and DNS never touch the host or ExpressVPN.

**Decisions**
- Ubuntu: network namespace with openfortivpn (see namespace-solutions.md). Chosen 2026-10-03 after route-pinning and DNS workarounds on the host failed to keep the tunnel up. Macvlan uplink tried first and worked; veth + NAT was not needed.
- Windows: FortiClient plus ExpressVPN split tunneling (app and gateway-IP bypass only), NRPT rule for internal DNS, connect ExpressVPN first. Details in windows-README.md.
- Windows, 2026-11-22: ExpressVPN is always connected, and the default is no FortiClient: the office is reached directly over the office LAN/Wi-Fi, with the office ranges in ExpressVPN's IP bypass list. FortiClient mode is kept as an optional, separate setup; switching modes means adding or removing the office ranges in that list. The DNS fix (`office-dns-permit.ps1`, NRPT + WFP port 53 permit) has no FortiClient dependency and is the same in both modes. The DNS doc was renamed from `expressvpn-fortigate-windows-dns.md` to `expressvpn-windows-dns.md`.

**Status:** Windows FortiClient mode is tested and working (windows-README.md); Windows office network mode is not yet tested. Ubuntu works with the namespace. Wired (macvlan, by hand): the tunnel stayed up for about 10 minutes with the Fortigate reached directly (TTL 247). Wired through the script with Wi-Fi also connected: wired was chosen automatically and the Fortigate path stayed stable for about 12 minutes. Wi-Fi (ipvlan, through `ubuntu/office-netns.sh`): the script auto-detected interface, gateway, link type and a free address, the office DNS servers were picked up automatically, and the tunnel stayed up for about 15 minutes; internal DNS and TCP to the git host worked, the host unaffected. Host-side fixes (route-pinning watchdogs, DNS exception) did not keep the tunnel up. Still to verify: multi-hour stability, `git`/`ssh`/browser as the normal user, behaviour after a reboot, and persistence plus a short `office <command>` prefix (designed, not built). Details in ubuntu-README.md.
