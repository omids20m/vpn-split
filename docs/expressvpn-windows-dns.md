# ExpressVPN on Windows: DNS for office-domain.example

ExpressVPN stays connected all the time; office names under `office-domain.example` must still resolve through the office DNS servers. This doc covers why that fails and the permit-filter fix (`office-dns-permit.ps1`). The fix does not depend on FortiClient: it works the same whether the office DNS servers are reached over the office LAN/Wi-Fi (the default) or through the FortiClient tunnel. How office traffic is routed in each mode is in [windows-README.md](windows-README.md). Ubuntu counterpart: `expressvpn-openfortivpn-ubuntu.md`.

(Renamed on 2026-11-22 from `expressvpn-fortigate-windows-dns.md`.)

Status as of 2026-10-07: DNS fixed by hand and confirmed in FortiClient mode (`intranet.office-domain.example` -> `10.31.150.61` with ExpressVPN and FortiClient connected). Office network mode (no FortiClient) is not yet tested. The scheduled task that re-applies the fix at startup/logon is written but not yet confirmed working: the first install attempts hit an execution-policy block and then a script bug (both fixed, see Troubleshooting); a successful `-Install`, `-Status` and a check after a reboot are still pending.

## Environment (recorded in FortiClient mode)

| Item | Value |
|---|---|
| Fortigate adapter | `Ethernet 4 Forti`, tunnel IP `10.31.254.2` |
| Corporate routes | `10.30.0.0/16`, `10.31.0.0/16` |
| Internal DNS | `10.30.63.3`, `10.30.63.2` |
| Internal suffix | `office-domain.example` |
| Script | `office-dns-permit.ps1` (installs to `C:\Program Files\office-net\` with an admin-only ACL, log in `dns-permit.log`; before 2026-11-22 it used `C:\ProgramData\<old folder>\`) |

## Symptom

Recorded with ExpressVPN and FortiClient both connected: `*.office-domain.example` does not resolve. `ping 10.30.63.3` works (about 80-100 ms, leaves on the Forti adapter), but `nslookup host 10.30.63.3` and `Test-NetConnection 10.30.63.3 -Port 53` time out (UDP and TCP). With ExpressVPN disconnected the same lookup works, so the Fortigate policy and the DNS servers are fine.

The block is in ExpressVPN, not in the path, so the same happens on the office network: the office DNS servers answer ping but not port 53 while ExpressVPN is connected.

## Cause

ExpressVPN's leak protection installs WFP block filters for all remote port 53 traffic, in its own sublayer (`1b0346a1-adc6-45a9-8014-8bb2d656c415`):

| Filter | Layer | Action | Condition |
|---|---|---|---|
| 332454 | ALE_AUTH_CONNECT_V4 | BLOCK | remote port = 53 |
| 332455 | ALE_AUTH_CONNECT_V6 | BLOCK | remote port = 53 |

No destination, app or interface exceptions. Things that did NOT help: split tunneling bypass lists (app or IP), turning Network Lock off, an NRPT rule (it only picks the server; the packets are dropped before they leave). Windows Firewall rules cannot override it either: WFP evaluates sublayers separately and a block in any sublayer wins, so a permit has to be in the same sublayer with a higher weight.

How it was found: `netsh wfp show filters file=wfp.xml verbose=on`, then parse the XML for `ExpressVPN Firewall` filters whose condition is `IP_REMOTE_PORT EQUAL 53`.

## Fix

1. NRPT rule so only `.office-domain.example` goes to the internal resolvers:
   `Add-DnsClientNrptRule -Namespace ".office-domain.example" -NameServers "10.30.63.3","10.30.63.2"` (persistent).
2. WFP permit filters added through `fwpuclnt.dll` in ExpressVPN's sublayer, one per resolver: IPv4, remote `<resolver>/32`, port 53, explicit weight `0xF000000000000000` (the block is about `0xA000...`). It is not persistent, so it is gone after a reboot. All other port 53 traffic stays blocked.
3. `office-dns-permit.ps1` automates both: it uses the known sublayer GUID, falls back to discovering it from the filter dump, and re-checks every 30 s in `-Watch` mode (the filter add returns "already exists" when it is in place).

What the fix needs: ExpressVPN installed (its filters are what the permits attach to) and a route to the resolver IPs. It does not look at FortiClient or any adapter. The route comes from the office network plus ExpressVPN's IP bypass for the office ranges (office network mode), or from FortiClient's routes (FortiClient mode); see [windows-README.md](windows-README.md).

### Configuration

The script has no addresses or domain names in it. It takes them from parameters or from `office-dns.psd1` next to the script; parameters win. `office-dns.psd1` is git-ignored; copy `windows\office-dns.example.psd1` to start:

| Setting | Parameter | Meaning |
|---|---|---|
| `Resolvers` | `-Resolvers 10.0.0.2,10.0.0.3` | internal DNS servers (IPv4, up to 16); one permit filter each |
| `DnsSuffix` | `-DnsSuffix office-domain.example,lab.office-domain.example` | one or more internal suffixes; one NRPT rule each (leading dot optional). In the file: `DnsSuffix = @('a.example', 'b.example')` (a single string also works) |
| `TestHost` | `-TestHost intranet.office-domain.example` | optional; looked up by `-Status` |

Which resolvers: the office network's DNS servers (in the office, `Get-DnsClientServerAddress` on your Ethernet or Wi-Fi adapter shows what DHCP gave you) or the ones the Fortigate announces. If the two sets differ, list both, the ones you use most first. Servers that are unreachable in your usual mode slow lookups down.

You do not have to edit the file by hand: when `-Install` runs in a console and a value is missing, it asks for it and saves the answers to `office-dns.psd1`. `-Configure` asks for all of them again (the current values are the defaults; `-` clears the test host) and then installs. The scheduled task never prompts.

`-Install` writes the values it used to `C:\Program Files\office-net\office-dns.psd1` (admin-only, like the script), which is what the scheduled task reads. To change them, run `-Install` again with the new values. Changing the resolvers also updates the NRPT rules' servers. The rules the script creates are tagged with the comment `office-dns-permit`; when you remove a suffix from the list, its rule is removed on the next run, and `-Uninstall` removes all of them. Rules you made by hand for the same suffixes are reused (and their servers updated), not duplicated.

```powershell
# elevated, 64-bit PowerShell. Use the Bypass form: the execution policy blocks the unsigned script otherwise.
cd E:\repos\office-net\windows      # -Install copies the script and config to C:\Program Files\office-net
$ps = 'powershell -NoProfile -ExecutionPolicy Bypass -File .\office-dns-permit.ps1'
iex "$ps -Install"     # asks for missing values; registers SYSTEM task "office-dns-permit" (startup + logon), starts it
iex "$ps -Configure"   # change the DNS servers / suffix / test host, then reinstall
iex "$ps -Status"      # config, install folder, task, permit filters, NRPT rules, test lookup, log tail
iex "$ps -Uninstall"   # remove task, permit filters and NRPT rules
iex "$ps"              # apply once now
```

Run `-Status` later from either folder; it also reports whether the install folder is locked down.

Or type each command in full, e.g. `powershell -NoProfile -ExecutionPolicy Bypass -File .\office-dns-permit.ps1 -Status`. The scheduled task itself already launches the script with `-ExecutionPolicy Bypass`.

## Install folder security

The scheduled task runs the script as SYSTEM, so whoever can write to the install folder can run code as SYSTEM. The first version installed to `C:\ProgramData\<old folder>`; standard users can create folders under ProgramData, so another account (or malware) that created that folder there first would own it and could replace the script. Since 2026-11-22:

- `-Install` uses `C:\Program Files\office-net`, takes ownership for Administrators and replaces the ACL even if the folder already existed: SYSTEM and Administrators full control, Users read and execute, no inherited entries. It refuses to install if the result still lets non-admins write.
- In `-Watch` mode (what the task runs) the script exits without doing anything if the install folder has become writable by non-admins.
- `-Status` shows whether the folder is locked down.

To move an install made by an older version (different script, task and folder name): run that version's `-Uninstall`, delete its folder under `C:\ProgramData`, then run `-Install` from the repo as above and check with `-Status`.

## ExpressVPN / browser settings

- ExpressVPN connected all the time; split tunneling on, All Other Apps = Use VPN.
- The IP bypass list depends on the mode (details in [windows-README.md](windows-README.md)):
  - Office network (default): the office ranges (`10.30.0.0/16`, `10.31.0.0/16`) = Bypass VPN, so the resolvers are reached over the LAN.
  - FortiClient: FortiClient apps and the gateway IP `203.0.113.10/32` = Bypass VPN, and **no** `10.30.*` or `10.31.*` entries (they hijack routes away from the tunnel). Connect ExpressVPN first, FortiClient second.
- Neither bypass list lifts the port 53 block; the permit filters are needed in both modes.
- Turn off DNS-over-HTTPS in Chrome and Firefox.
- The IPv6 port 53 block (332455) is left alone; the resolvers are IPv4.

## Known limits

- Loosens ExpressVPN's DNS leak protection for the listed office DNS servers only.
- If ExpressVPN is updated or reinstalled and its sublayer or filters change, re-run `-Install` (or `-Status` to see what failed). If ExpressVPN errors while rebuilding its filters, run `-Uninstall` first.
- The NRPT rules stay when the office DNS servers are unreachable (away from the office network with FortiClient disconnected), so lookups under the office suffixes then time out slowly instead of failing fast. Only those suffixes are affected.
- With ExpressVPN not running there is nothing to permit: the NRPT rules still work, and the task logs that it cannot find ExpressVPN's filters and re-checks (with a slow filter dump at most every 5 minutes).
- Unrelated to the Ubuntu tunnel-drop problem, which is a routing issue (see the Ubuntu doc).

## Troubleshooting

- "File ... is not digitally signed" / "cannot be loaded": execution policy. Run it through `powershell -NoProfile -ExecutionPolicy Bypass -File ...`, or `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force` first (affects only that window). `Unblock-File` also clears the downloaded-from-internet flag.
- `Cannot convert value "-2144206839" to type "System.UInt32"`: bug in the first version of the script (PowerShell reads `0x80320009` as a negative Int32). Fixed 2026-10-07 by using decimal constants (`2150760457` and `2150760455`). If an installed copy still has the hex form, run `-Install` again from the repo.
- Permit not applied: `-Status` shows it, and `C:\Program Files\office-net\dns-permit.log` has the reason. Common cause: ExpressVPN not installed or its filters not created yet (the script retries every 30 s and re-discovers the sublayer at most every 5 minutes).
- Permits present but lookups still time out: the resolvers are not reachable. Check the route with `Find-NetRoute -RemoteIPAddress <resolver>`: in office network mode it should be your Ethernet/Wi-Fi adapter (if it is the ExpressVPN adapter, the office ranges are missing from the bypass list); in FortiClient mode it should be the Forti adapter.
- WFP error codes seen: `0x80320009` filter already exists (fine), `0x80320007` sublayer not found (script falls back to discovery).

## Fallbacks

- Hosts file entry for the one host you need (no wildcards), e.g. `10.31.150.61  intranet.office-domain.example`.
- Disconnect ExpressVPN while working on the intranet.
