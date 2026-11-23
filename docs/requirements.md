# Requirements

## Goal
Keep ExpressVPN connected for general internet traffic and reach office resources at the same time, without ExpressVPN breaking office routes or DNS. On Windows the office is reached directly over the office network by default, or through the corporate FortiGate VPN when away; on Ubuntu through the FortiGate VPN.

## Functional
- R1. Office traffic reaches the office network while ExpressVPN stays connected.
- R2. Non-office traffic keeps going through ExpressVPN.
- R3. Works on Windows (office LAN/Wi-Fi by default, FortiClient optional) and Ubuntu (openfortivpn).
- R4. Office DNS names resolve for office traffic only; ExpressVPN DNS stays in use for everything else.
- R5. The office VPN (FortiClient / openfortivpn) can be connected and disconnected independently of ExpressVPN.

## Ubuntu-specific
- R6. openfortivpn must not replace the host default route or /etc/resolv.conf.
- R7. Office apps are started explicitly inside an isolated network namespace.
- R8. Setup and teardown are scripted and repeatable (ubuntu/office-netns.sh).

## Windows-specific
- R9. ExpressVPN stays connected in both Windows modes and must not break office routes or DNS (see windows-README.md).
- R9a. Office network mode (default): office traffic leaves through the physical NIC; the office ranges are in ExpressVPN's IP bypass list.
- R9b. FortiClient mode: internal subnets must never be in ExpressVPN's IP bypass list, since that hijacks routes away from the Forti tunnel; only the FortiClient apps and the gateway /32 are bypassed.
- R9c. Internal DNS is resolved via NRPT rules plus WFP permits for port 53 to the office DNS servers (windows/office-dns-permit.ps1), the same in both modes; browser DNS-over-HTTPS is off.
- R10. No changes that need a reboot to undo.

## Non-functional
- Uses only vendor clients and openfortivpn, no custom VPN software.
- No credentials or secrets stored in the repo.

## Open items (confirm against what was actually tested)
- Windows office network mode is not yet tested (office ranges bypassed in ExpressVPN, DNS through the permit script).
- Whether the office network's DHCP hands out the same DNS servers as the FortiGate.
- Exact FortiGate gateway/port and auth method (password, SAML, certificate).
- ExpressVPN protocol used (Lightway / WireGuard / OpenVPN).
- Whether the FortiGate gateway is reachable through the ExpressVPN tunnel or must bypass it.
