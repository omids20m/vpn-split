# ExpressVPN + openfortivpn coexistence on Ubuntu 24.04

Companion to the Windows docs (`expressvpn-fortigate-coexistence.md`, and `expressvpn-fortigate-windows-dns.md` for the Windows version of the port 53 fix). Same goal: ExpressVPN for general traffic, Fortigate tunnel for the `office-domain.example` intranet.

Status as of 2026-10-13: the tunnel now runs inside a network namespace (`office`) managed by `scripts/office-netns.sh` in the `office-net` repo. On 2026-10-13 the tunnel came up and the Fortigate DNS servers were applied inside the namespace. The script header records the tunnel stable for about 15 minutes on Wi-Fi (ipvlan) and about 12 minutes wired (macvlan). A longer soak, and name resolution from inside the namespace, are not yet recorded here.

## Environment

| Item | Value |
|---|---|
| Fortigate gateway | `203.0.113.10` (custom port) |
| Corporate routes pushed | `10.30.0.0/16`, `10.31.0.0/16` |
| Internal DNS | `10.30.63.3`, `10.30.63.2` |
| Internal suffix | `office-domain.example` |
| Physical NIC | `eno2` (Wi-Fi `wlo1` also present) |
| ExpressVPN | Linux Qt app v14.3 (GUI + CLI) |
| Script | `scripts/office-netns.sh` (repo at `/mnt/e/repos/office-net`); `install.sh` deploys it as `/usr/local/sbin/office-netns` (owner root, mode 755), which is the copy run as root |
| openfortivpn config | `/etc/openfortivpn/config` (host, port, username, pinned `trusted-cert`) |

## Values used in the commands

The commands below use shell variables instead of addresses, so they work on any network. Set them once per terminal; they are read from your own config, nothing here is hard-coded:

```bash
FORTIGATE=$(sudo sed -n 's/^[[:space:]]*host[[:space:]]*=[[:space:]]*//p' /etc/openfortivpn/config)   # Fortigate gateway
read -r DNS1 DNS2 _ < <(awk '/^nameserver/ {printf "%s ", $2}' /etc/netns/office/resolv.conf)            # internal DNS, once the VPN is up
DOMAIN=$(sed -n 's/^[[:space:]]*OFFICE_SEARCH="\{0,1\}\([^ ",]*\).*/\1/p' /etc/office-net.conf)        # first internal suffix
OFFICE_HOST=git.$DOMAIN                  # any internal host name
echo "gateway=$FORTIGATE dns=$DNS1,$DNS2 domain=$DOMAIN host=$OFFICE_HOST"
```
Without the namespace (host workaround) `/etc/netns/office/resolv.conf` does not exist: set `DNS1=... DNS2=...` by hand from openfortivpn's "Got addresses ... ns [...]" line. Addresses that still appear in this doc (`203.0.113.10`, `10.30.x.x`, `198.51.100.x`, `192.168.x.x`) are placeholders in recorded results, not values to type.

## Why a namespace

With openfortivpn in the root namespace, ExpressVPN interferes in two ways:

1. **Tunnel drops (the main problem).** ExpressVPN keeps inserting and deleting a route for the gateway through its `tun0` in the main routing table. Ping to `203.0.113.10` alternated between TTL 247 (~3 ms, direct) and TTL 235 (~450 ms, via `tun0`). During the 235 windows PPP keepalives starve and openfortivpn dies with "No response to 4 echo-requests" / "Modem hangup", usually within 1-3 minutes. Restarting the daemon, turning off Wi-Fi and rebooting did not help.
2. **DNS block.** ExpressVPN's leak protection rejects all port 53 traffic in nft chain `evpn.r.310.blockDNS` (table `ip filter`). See Problem 1 below.

ExpressVPN's routes and firewall rules live in the root namespace. The script gives openfortivpn its own namespace with its own network interface attached to the physical NIC, so its packets go straight out the uplink and ExpressVPN never sees them. There is no forwarding or NAT through the root namespace. (An earlier design used a veth pair with NAT; it was dropped because ExpressVPN's rules might capture forwarded traffic.)

## How the script works

`office-netns.sh up` detects everything it needs:

| Item | How it is chosen |
|---|---|
| Uplink interface | physical interface (has a `device` entry in sysfs, so `tun0` is ignored) with the lowest-metric IPv4 default route; wired wins over Wi-Fi |
| Gateway | that route's gateway |
| Link type | `macvlan` (bridge mode) on wired NICs, `ipvlan` (L2) on Wi-Fi, because an access point only accepts the associated station's MAC |
| Address in the namespace | unused address near the top of the subnet, checked with `arping`; remembered per network in `/var/lib/office-netns/` |
| DNS | the servers the Fortigate announces after login ("Got addresses: [...], ns [...]"), read from openfortivpn's output and written to `/etc/netns/office/resolv.conf` by a background watcher; the file is empty until the VPN is up, so lookups fail closed |

The interface inside the namespace is `of-office`. State files: `/run/office-netns.state`, `/run/office-netns-vpn.log`.

Example from 2026-10-13: `office ready: 192.168.10.254/24 via 192.168.10.1 on eno2 (macvlan)`; the Fortigate then assigned `10.31.254.17` and DNS `10.30.63.3`, `10.30.63.2`.

## Usage

```bash
cd /mnt/e/repos/office-net && bash install.sh   # deploys /usr/local/sbin/office-netns (again after every change to the script)
sudo office-netns up          # create the namespace
sudo office-netns vpn         # start openfortivpn inside it; asks for the VPN password; keep this terminal open
sudo office-netns run <cmd>   # run a command inside the namespace as your user (e.g. run ping -c 3 "$DNS1")
sudo office-netns status      # addresses, routes, DNS, whether ppp0 exists
sudo office-netns refresh     # down + up; then start the tunnel again with "vpn"
sudo office-netns down        # remove the namespace
```

**Do not run the repo copy with sudo** (`sudo bash scripts/office-netns.sh ...`) except to test a change before deploying it. The repo is on `/mnt/e`, which has no Unix permissions, so any program running as your user could edit it; whatever it put there would run as root the next time you typed your sudo password. The desktop icons and the `office` alias use the root-owned copy. `bash install.sh --check` warns when the deployed copy differs from the repo or is writable by non-root.

- **Only commands started with `run` reach `10.30.*` and `10.31.*`.** Everything else keeps using ExpressVPN as normal.
- **After changing networks** (another LAN, LAN to Wi-Fi or back, new DHCP network), run `refresh` and then `vpn` again. The namespace keeps the address and gateway it was built with.
- Settings: on the first run in a terminal, `bash install.sh` asks for the Fortigate host, port, username and certificate pin (it reads the certificate from the gateway and asks before pinning it) and writes `/etc/openfortivpn/config` (root, mode 600; other options already in the file are kept, a `password =` line is dropped). It also asks for the DNS search suffixes (space- or comma-separated) and writes `/etc/office-net.conf`. `bash install.sh --configure` asks again, with the current values as defaults.
- Site settings: `/etc/office-net.conf` (created by `install.sh` from `ubuntu/office-net.conf.example`; unset values = auto-detect). It is only read when owned by root and not writable by others. Set `OFFICE_SEARCH="office-domain.example lab.office-domain.example"` there to get one or more DNS search suffixes in the namespace (written as one `search` line; spaces or commas both work).
- Overrides (environment variables or `/etc/office-net.conf`; the environment wins): `OFFICE_IFACE`, `OFFICE_GW`, `OFFICE_ADDR` (e.g. `192.168.0.200/24`), `OFFICE_LINK` (`macvlan` or `ipvlan`), `OFFICE_CONFIG`, `OFFICE_NS`, `OFFICE_SEARCH` (DNS search suffixes, space- or comma-separated), `OFFICE_WAIT` (seconds to wait for an uplink, default 20).

## How to verify

```bash
sudo ip netns exec office ping -c 5 "$FORTIGATE"    # TTL should stay high (~247), not ~235 via ExpressVPN
sudo ip netns exec office ping -c 3 "$DNS1"
sudo ip netns exec office getent hosts "$OFFICE_HOST"
sudo ip netns exec office ping -c 600 "$DNS1" | tail -3    # ~10 min soak: want 0% loss and the vpn terminal still connected
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| openfortivpn: `connect: No route to host`; `ip -n office link show of-office` shows `NO-CARRIER`; pings from the namespace say "Destination Host Unreachable" from the namespace's own address | The namespace was built for a different network than the host is on now. Seen 2026-10-13: namespace had `192.168.20.254/24` via `192.168.20.35` while `eno2` was on `192.168.10.0/24` | `refresh`, then `vpn`. Since 2026-10-13 `vpn` checks this first and stops with a message if the link has no carrier or the uplink interface or gateway changed |
| `scripts/office-netns.sh: line 1: watcher: unbound variable` after the tunnel exits | Bug in the original script: `watcher` was a `local` variable used by an EXIT trap that runs after the function returned. It also left the background DNS watcher running every time | Fixed 2026-10-13 (global `WATCHER_PID`, cleanup function). Clear old strays with the tunnel stopped: `sudo pkill -f '[o]ffice-netns.sh vpn'` (or reboot) |
| `namespace office already exists` | `up` run twice | `refresh` or `down` |
| `no usable uplink` | no physical interface with an IPv4 address and a default gateway within `OFFICE_WAIT` | connect the network, or set `OFFICE_IFACE` / `OFFICE_GW` |
| `no free address found in <net>` | `arping` found no free address | set `OFFICE_ADDR` |
| `arping not found` | package missing | `sudo apt install iputils-arping` |

## Open items

- Longer soak test with ExpressVPN connected (tunnel staying up for well over 15 minutes) is not recorded yet.
- The 2026-10-13 `watcher` fix and the new `vpn` pre-check were tested with stubs only; the first real run after copying the new script has not been reported.
- `/etc/ppp/ip-up.d/office-dns` (see Problem 1) is also triggered by the namespace's `ppp0`, because pppd runs inside the namespace. Check it does nothing harmful there (`resolvectl` talks to the host's resolver, and `evpn.r.310.blockDNS` does not exist inside the namespace). It is not needed for the namespace path and can be disabled if it causes trouble.

## Problem 1: DNS in the root namespace (solved, only needed outside the namespace)

Symptom: `dig @10.30.63.3 ...` fails instantly with "connection refused", nothing appears on `ppp0` in tcpdump, and it works with ExpressVPN closed.

Cause: ExpressVPN's leak protection installs a reject for all port 53 traffic in nft chain `evpn.r.310.blockDNS` (table `ip filter`). Neither the kill switch toggle nor app or IP bypass exempts DNS from it. (Windows has the same block as WFP filters; see `expressvpn-fortigate-windows-dns.md`.) Packets sent from inside the `office` namespace do not pass through that chain.

Fix for use without the namespace: insert one narrow accept above the reject, scoped to the internal resolvers and `ppp*` only:

```bash
sudo nft insert rule ip filter evpn.r.310.blockDNS oifname "ppp*" ip daddr { $DNS1, $DNS2 } accept
sudo resolvectl dns ppp0 "$DNS1" "$DNS2"
sudo resolvectl domain ppp0 "$DOMAIN"
```

ExpressVPN rebuilds its rules on reconnect, so this is automated in `/etc/ppp/ip-up.d/office-dns` (no dot in the filename; retries `resolvectl` up to 10 times, adds the nft rule only if missing). It runs each time `ppp0` comes up. If ExpressVPN reconnects while `ppp0` stays up, re-run `sudo /etc/ppp/ip-up.d/office-dns ppp0`.

Dead ends: `/etc/hosts` works but has no wildcards; a dnsmasq forwarder marked Bypass VPN is rejected too (bypassed apps are not exempt from the DNS block); `resolvectl ... lo` is refused (loopback link).

## Problem 2 history: things tried before the namespace

- 1 s unconditional `ip route replace` watchdog: hijack windows of ~40 s persisted.
- 0.5 s check-before-write wrapper around openfortivpn: corrections fired about every second and the tunnel died faster (0.7 min). Fighting the route table makes it worse.
- Loosened pppd keepalive (`lcp-echo-interval 20`, `lcp-echo-failure 6` appended to `/etc/ppp/options`): kept as a margin, not sufficient. `--pppd-call` with a minimal peers file breaks authentication.

## Cleanup state

Removed: watchdog scripts, dnsmasq and its config. Kept: nft DNS exception, `ip-up.d/office-dns`, the `/etc/ppp/options` keepalive lines. With the namespace in use, the ExpressVPN split-tunneling entries for `openfortivpn` and `203.0.113.10/32` should no longer matter, since that traffic does not enter the root namespace; do not add any `10.30.*` or `10.31.*` entries. Re-enable the ExpressVPN kill switch if it was turned off for testing. Turn off DNS-over-HTTPS in Firefox and Chrome.

## Fallback

Disconnect ExpressVPN while working on the intranet: openfortivpn and the `resolvectl` settings then work as-is without the namespace.
