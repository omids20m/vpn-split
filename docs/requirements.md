# Requirements

## Goal
Use ExpressVPN for general internet traffic and a corporate FortiGate VPN for office resources, at the same time, without the two clients breaking each other's routes or DNS.

## Functional
- R1. Office (FortiGate) traffic reaches the office network while ExpressVPN stays connected.
- R2. Non-office traffic keeps going through ExpressVPN.
- R3. Works on Windows (FortiClient) and Ubuntu (openfortivpn).
- R4. Office DNS names resolve for office traffic only; ExpressVPN DNS stays in use for everything else.
- R5. Either VPN can be disconnected and reconnected independently.

## Ubuntu-specific
- R6. openfortivpn must not replace the host default route or /etc/resolv.conf.
- R7. Office apps are started explicitly inside an isolated network namespace.
- R8. Setup and teardown are scripted and repeatable (scripts/office-netns.sh).

## Windows-specific
- R9. FortiClient and ExpressVPN must not fight over routes or DNS (see windows-README.md).
- R9a. Internal subnets must never be added to ExpressVPN's IP bypass list, since that hijacks routes away from the Forti tunnel.
- R9b. Internal DNS is resolved via an NRPT rule; browser DNS-over-HTTPS is off.
- R10. No changes that need a reboot to undo.

## Non-functional
- Uses only vendor clients and openfortivpn, no custom VPN software.
- No credentials or secrets stored in the repo.

## Open items (confirm against what was actually tested)
- Exact FortiGate gateway/port and auth method (password, SAML, certificate).
- ExpressVPN protocol used (Lightway / WireGuard / OpenVPN).
- Whether the FortiGate gateway is reachable through the ExpressVPN tunnel or must bypass it.
