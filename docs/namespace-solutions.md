# Solutions

## Ubuntu: openfortivpn in a network namespace
The namespace `office` has its own routing table and resolv.conf. openfortivpn runs inside it, so its default route and DNS apply only to processes started in that namespace. The host and ExpressVPN are untouched.

Traffic path: app in `office` -> veth -> host (NAT) -> host default route -> FortiGate gateway -> ppp0 inside `office`.
If ExpressVPN is connected on the host, the FortiGate handshake leaves through ExpressVPN. If the gateway blocks VPN exit IPs, exclude the gateway IP in ExpressVPN or route it via the physical NIC.

Usage:
```
sudo ./scripts/office-netns.sh up
sudo ./scripts/office-netns.sh vpn vpn.example.com:443 your.user   # prompts for password
sudo ip netns exec office sudo -u $USER ssh host.corp.example
sudo ./scripts/office-netns.sh down
```
Install: `sudo apt install openfortivpn`.

## Windows: FortiClient with ExpressVPN (tested and working)
See [windows-README.md](windows-README.md) for the full tested procedure. In short:
- ExpressVPN split tunneling: bypass the three FortiClient executables and the FortiGate gateway IP (/32). Never add internal subnets to the IP list.
- DNS: an NRPT rule sends the internal domain to the internal DNS servers, and browser DNS-over-HTTPS is turned off.
- Connect ExpressVPN first, then FortiClient.

Windows has no equivalent of Linux network namespaces for this, so split tunneling plus NRPT is the working approach.

## Verification checklist
- Host public IP is the ExpressVPN exit (both OSes).
- Office host reachable by name and IP from the office path only.
- Disconnect each VPN in turn; the other keeps working.
