# ExpressVPN + FortiClient coexistence on Windows: DNS for office-domain.example

Companion to the Ubuntu doc (`expressvpn-openfortivpn-ubuntu.md`). Same goal: ExpressVPN for general traffic, Fortigate tunnel for the `office-domain.example` intranet.

Status as of 2026-10-07: DNS fixed by hand and confirmed (`intranet.office-domain.example` -> `10.31.150.61` with both VPNs connected). The scheduled task that re-applies the fix at startup/logon is written but not yet confirmed working: the first install attempts hit an execution-policy block and then a script bug (both fixed, see Troubleshooting); a successful `-Install`, `-Status` and a check after a reboot are still pending.

## Environment

| Item | Value |
|---|---|
| Fortigate adapter | `Ethernet 4 Forti`, tunnel IP `10.31.254.2` |
| Corporate routes | `10.30.0.0/16`, `10.31.0.0/16` |
| Internal DNS | `10.30.63.3`, `10.30.63.2` |
| Internal suffix | `office-domain.example` |
| Script | `office-dns-permit.ps1` (installs to `C:\ProgramData\office\`, log in `dns-permit.log`) |

## Symptom

With ExpressVPN and FortiClient both connected, `*.office-domain.example` does not resolve. `ping 10.30.63.3` works (about 80-100 ms, leaves on the Forti adapter), but `nslookup host 10.30.63.3` and `Test-NetConnection 10.30.63.3 -Port 53` time out (UDP and TCP). With ExpressVPN disconnected the same lookup works, so the Fortigate policy and the DNS servers are fine.

## Cause

ExpressVPN's leak protection installs WFP block filters for all remote port 53 traffic, in its own sublayer (`1b0346a1-adc6-45a9-8014-8bb2d656c415`):

| Filter | Layer | Action | Condition |
|---|---|---|---|
| 332454 | ALE_AUTH_CONNECT_V4 | BLOCK | remote port = 53 |
| 332455 | ALE_AUTH_CONNECT_V6 | BLOCK | remote port = 53 |

No destination, app or interface exceptions. Things that did NOT help: split tunneling bypass lists, turning Network Lock off, an NRPT rule (it only picks the server; the packets are dropped before they leave). Windows Firewall rules cannot override it either: WFP evaluates sublayers separately and a block in any sublayer wins, so a permit has to be in the same sublayer with a higher weight.

How it was found: `netsh wfp show filters file=wfp.xml verbose=on`, then parse the XML for `ExpressVPN Firewall` filters whose condition is `IP_REMOTE_PORT EQUAL 53`.

## Fix

1. NRPT rule so only `.office-domain.example` goes to the internal resolvers:
   `Add-DnsClientNrptRule -Namespace ".office-domain.example" -NameServers "10.30.63.3","10.30.63.2"` (persistent).
2. One WFP permit filter added through `fwpuclnt.dll` in ExpressVPN's sublayer: IPv4, remote `10.30.63.2/31` (exactly `.2` and `.3`), port 53, explicit weight `0xF000000000000000` (the block is about `0xA000...`). It is not persistent, so it is gone after a reboot. All other port 53 traffic stays blocked.
3. `office-dns-permit.ps1` automates both: it uses the known sublayer GUID, falls back to discovering it from the filter dump, and re-checks every 30 s in `-Watch` mode (the filter add returns "already exists" when it is in place).

```powershell
# elevated, 64-bit PowerShell. Use the Bypass form: the execution policy blocks the unsigned script otherwise.
cd C:\ProgramData\office
$ps = 'powershell -NoProfile -ExecutionPolicy Bypass -File .\office-dns-permit.ps1'
iex "$ps -Install"     # register SYSTEM task "office-dns-permit" (startup + logon), start it
iex "$ps -Status"      # task, permit filter, NRPT rule, test lookup, log tail
iex "$ps -Uninstall"   # remove task, permit filter and NRPT rule
iex "$ps"              # apply once now
```

Or type each command in full, e.g. `powershell -NoProfile -ExecutionPolicy Bypass -File .\office-dns-permit.ps1 -Status`. The scheduled task itself already launches the script with `-ExecutionPolicy Bypass`.

## ExpressVPN / browser settings

- Split tunneling on, All Other Apps = Use VPN. Bypass VPN: FortiClient and the gateway IP `203.0.113.10/32`. No `10.30.*` or `10.31.*` entries (they hijack routes).
- Connect ExpressVPN first, FortiClient second.
- Turn off DNS-over-HTTPS in Chrome and Firefox.
- The IPv6 port 53 block (332455) is left alone; the resolvers are IPv4.

## Known limits

- Loosens ExpressVPN's DNS leak protection for two corporate IPs only.
- If ExpressVPN is updated or reinstalled and its sublayer or filters change, re-run `-Install` (or `-Status` to see what failed). If ExpressVPN errors while rebuilding its filters, run `-Uninstall` first.
- The NRPT rule stays when FortiClient is down, so `office-domain.example` lookups then time out slowly instead of failing fast. Only that suffix is affected.
- Unrelated to the Ubuntu tunnel-drop problem, which is a routing issue (see the Ubuntu doc).

## Troubleshooting

- "File ... is not digitally signed" / "cannot be loaded": execution policy. Run it through `powershell -NoProfile -ExecutionPolicy Bypass -File ...`, or `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force` first (affects only that window). `Unblock-File` also clears the downloaded-from-internet flag.
- `Cannot convert value "-2144206839" to type "System.UInt32"`: bug in the first version of the script (PowerShell reads `0x80320009` as a negative Int32). Fixed 2026-10-07 by using decimal constants (`2150760457` and `2150760455`). If an installed copy still has the hex form, replace it or copy the current script over `C:\ProgramData\office\office-dns-permit.ps1`.
- Permit not applied: `-Status` shows it, and `C:\ProgramData\office\dns-permit.log` has the reason. Common cause: ExpressVPN not installed or its filters not created yet (the script retries every 30 s and re-discovers the sublayer at most every 5 minutes).
- WFP error codes seen: `0x80320009` filter already exists (fine), `0x80320007` sublayer not found (script falls back to discovery).

## Fallbacks

- Hosts file entry for the one host you need (no wildcards), e.g. `10.31.150.61  intranet.office-domain.example`.
- Disconnect ExpressVPN while working on the intranet.
