# ExpressVPN on Windows with access to the office network

ExpressVPN stays connected all the time and carries general internet traffic. Office
resources (the `office-domain.example` names and the `10.30.0.0/16`, `10.31.0.0/16`
ranges) are reached in one of two ways:

| Mode | When | Office traffic leaves through | Status |
|---|---|---|---|
| **Office network** (default) | Your LAN or Wi-Fi already reaches the office IPs (in the office, or on a network routed to it) | The physical NIC (Ethernet / Wi-Fi), using ExpressVPN IP bypass rules for the office ranges | Not yet tested |
| **FortiClient** (optional) | You are on a network that does not reach the office | The FortiClient SSL-VPN tunnel | Tested and working (October 2026) |

Both modes use the same DNS setup (`office-dns-permit.ps1`, section 1). DNS does not
depend on FortiClient: it only needs the office DNS servers to be reachable by some route.
The one ExpressVPN setting that differs between the modes is whether the office ranges are
in its IP bypass list (see [Switching modes](#4-switching-modes)).

---

## Values used in the commands

The commands below use PowerShell variables instead of addresses. Set them once per window; they are read from your own (git-ignored) `windows\office-dns.psd1`, see [expressvpn-windows-dns.md](expressvpn-windows-dns.md):

```powershell
$cfg        = Import-PowerShellDataFile E:\repos\office-net\windows\office-dns.psd1
$Dns        = @($cfg.Resolvers)                 # internal DNS servers
$Domain     = @($cfg.DnsSuffix)[0]              # first internal suffix
$OfficeHost = "git.$Domain"                     # any internal host name
$Lan        = 'Ethernet'                        # your physical adapter: 'Ethernet' or 'Wi-Fi' (Get-NetAdapter shows yours)
$Forti      = 'Ethernet 4 Forti'                # FortiClient adapter, FortiClient mode only
$CorpRoutes = { param($r) $r.DestinationPrefix -like '10.3[01].*' }   # your corporate ranges; adjust the pattern
$ps         = 'powershell -NoProfile -ExecutionPolicy Bypass -File E:\repos\office-net\windows\office-dns-permit.ps1'
```
Addresses that still appear in this doc (`203.0.113.10`, `10.30.x.x`, `198.51.100.x`, `192.168.x.x`) are placeholders in recorded output, not values to type.

## Why ExpressVPN gets in the way

There is no URL/domain-based split tunneling in ExpressVPN on Windows. Splitting is by
**application** or by **IP/CIDR**. With ExpressVPN connected, separate things break
office access, and they are easy to confuse with each other:

| Symptom | Cause | Fix | Mode |
|---|---|---|---|
| Names don't resolve, or resolve to the wrong (public) address | ExpressVPN forces its own DNS (`100.64.100.1`) and blocks port 53 to every other server | `office-dns-permit.ps1` (NRPT rule + WFP permit) | both |
| Office IPs time out | ExpressVPN's default route sends them into its own tunnel | IP bypass for the office ranges | office network |
| Forti tunnel won't establish | ExpressVPN wraps the SSL-VPN handshake | Bypass the Forti apps + gateway IP | FortiClient |
| With Forti up, names resolve but nothing connects | Office-range bypass rules hijack routes away from the Forti tunnel | **Remove** the office ranges from the bypass list | FortiClient |

---

## 1. Common setup (both modes)

### 1.1 ExpressVPN base settings

**Options → General → Split tunneling → on.** `All Other Apps` = **Use VPN**.

Firefox, Git CMD, `mstsc.exe`, `devenv.exe`, `dotnet.exe`, `ssms.exe` and other office
tools stay on **Use VPN**. Routing, not app bypass, decides where their office traffic goes.

> **Outstanding:** Firefox and Git CMD are currently still set to **Bypass VPN**. They were
> only bypassed as a workaround for the DNS problem, which section 1.2 now solves properly.
> Leaving Firefox bypassed means normal browsing has no VPN protection. Set both back to
> **Use VPN**.

### 1.2 Office DNS: `office-dns-permit.ps1`

Two things stop office names resolving while ExpressVPN is connected:

- ExpressVPN's WinTUN adapter carries `100.64.100.1` and wins on interface metric. Since
  `office-domain.example` is a public-looking domain, ExpressVPN's resolver returns *an*
  answer, just the wrong one. That fails without looking like a DNS failure.
- ExpressVPN's leak protection blocks port 53 to every other server with WFP filters. Bypass
  lists and turning Network Lock off do not lift it.

`office-dns-permit.ps1` fixes both: an NRPT rule per office suffix sends only those names to
the office DNS servers, and a WFP permit per server opens port 53 to just those IPs. A SYSTEM
scheduled task re-applies the permits at startup and logon. Install once, from an elevated
64-bit PowerShell:

```powershell
cd E:\repos\office-net\windows
$ps = 'powershell -NoProfile -ExecutionPolicy Bypass -File .\office-dns-permit.ps1'
iex "$ps -Install"     # asks for the DNS servers, suffixes and test host if missing
iex "$ps -Status"      # config, task, permit filters, NRPT rules, test lookup
```

Use the DNS servers of the office network (in the office, the ones DHCP gives your
adapter: `Get-DnsClientServerAddress -InterfaceAlias $Lan`). If they differ from the ones
the Fortigate announces, list both sets. Full details, how the block was found and
troubleshooting: [expressvpn-windows-dns.md](expressvpn-windows-dns.md).

### 1.3 Browser DNS-over-HTTPS must be off

DoH bypasses system DNS, NRPT rules, and the hosts file entirely.

- Firefox → Settings → Privacy & Security → DNS over HTTPS → **Off**
- Chrome → Settings → Privacy and security → Security → Use secure DNS → **off**

### 1.4 Housekeeping

The `Ethernet` adapter lists `8.8.8.8` as a third resolver. Worth removing: it can answer
with the public record when the internal ones are slow.

---

## 2. Office network mode (default)

Use this when your LAN or Wi-Fi already reaches the office IPs. FortiClient stays
disconnected. **Not yet tested**; it follows from how the pieces above work.

### 2.1 ExpressVPN split tunneling

On top of section 1.1:

**IPs to set to Bypass VPN**

- `10.30.0.0/16`
- `10.31.0.0/16`
- any other office range you use

An ExpressVPN "Bypass VPN" IP rule installs a route through the *physical* gateway. On the
office network that is exactly where the office is, so these entries keep office traffic
out of the ExpressVPN tunnel. Addresses on your own subnet are reached directly anyway (the
on-link route is more specific), so overlapping entries are harmless.

The FortiClient bypass entries from section 3.2 (three apps and the gateway `/32`) can stay
in the list; they do nothing while FortiClient is disconnected.

### 2.2 Check it

```powershell
Find-NetRoute -RemoteIPAddress $Dns[0] | Select-Object -First 1 InterfaceAlias, NextHop
Resolve-DnsName $OfficeHost
Test-NetConnection -ComputerName $OfficeHost -Port 443
```

Want: the route on `$Lan` (not the ExpressVPN adapter), the internal address from
`Resolve-DnsName`, and `TcpTestSucceeded : True` with `InterfaceAlias` = your physical
adapter. Check that ExpressVPN still carries everything else: your public IP should be the
ExpressVPN exit.

If the route points at the ExpressVPN adapter, the bypass entry is missing or not applied
yet: reconnect ExpressVPN.

### 2.3 Notes

- **After changing networks** (Ethernet ↔ Wi-Fi, another office network), ExpressVPN
  reconnects and should rebuild the bypass routes on the new gateway. If office IPs time
  out, check the route as above and reconnect ExpressVPN.
- **Away from the office without FortiClient**, office names time out slowly (the NRPT
  rule still points at servers you cannot reach) and office IPs go to your local router and
  fail. Nothing else is affected.

---

## 3. FortiClient mode (optional)

Use this when you are on a network that does not reach the office. ExpressVPN stays
connected; FortiClient carries office traffic. Tested and working (October 2026).

### 3.1 Recorded environment

| Item | Value |
|---|---|
| Fortigate public gateway | `203.0.113.10` (custom port) |
| Forti adapter | `Ethernet 4 Forti`, IP `10.31.254.5/32`, gateway `10.31.254.6` |
| Corporate routes pushed by Forti | `10.30.0.0/16`, `10.31.0.0/16` |
| Internal DNS servers | `10.30.63.3`, `10.30.63.2` |
| Internal DNS suffix | `office-domain.example` |
| Physical NIC | `Ethernet`, `192.168.10.47`, gateway `192.168.10.1` |

### 3.2 ExpressVPN split tunneling for FortiClient

On top of section 1.1:

**Apps to set to Bypass VPN**

- `FortiClient.exe`
- `FortiSSLVPNdaemon.exe`
- `FortiTray.exe`

This stops ExpressVPN double-wrapping the outer tunnel to the concentrator.

**IPs to set to Bypass VPN**

- `203.0.113.10/32`: the Fortigate public gateway. **This is the only IP entry needed.**

**IPs that must NOT be in the list in this mode**

- the office ranges from section 2.1 (`10.30.0.0/16`, `10.31.0.0/16`)
- any narrower internal prefix (`10.30.63.0/24`, `10.31.150.0/24`, …)

**Why this matters more than anything else in this mode:** a "Bypass VPN" IP rule installs a
route pointing at the *physical* gateway (`192.168.10.1`). A narrower entry is more specific
than FortiClient's `/16` routes, so Windows prefers it and dumps intranet traffic onto the
local LAN instead of into the tunnel; an equal `/16` entry competes on metric and is no
better:

```
10.30.0.0/16     → Ethernet 4 Forti (10.31.254.6)   ← FortiClient, correct
10.30.63.0/24    → Ethernet (192.168.10.1)           ← ExpressVPN, hijacks it
```

Bypass means "keep off the ExpressVPN tunnel," not "send into the Forti tunnel."
In this mode intranet traffic should be left alone entirely: FortiClient's own `/16` routes
handle it.

### 3.3 Connection order

1. Connect **ExpressVPN** first
2. Connect **FortiClient** second

Forti's routes then land last and its adapter metric ends up lowest
(recorded: `Ethernet 4 Forti` = 1, ExpressVPN WinTUN = 3).

### 3.4 Check it

```powershell
Get-NetRoute -AddressFamily IPv4 |
  Where-Object { & $CorpRoutes $_ } |
  Sort-Object DestinationPrefix |
  Format-Table DestinationPrefix,InterfaceAlias,NextHop,RouteMetric -AutoSize

Test-NetConnection -ComputerName $OfficeHost -Port 443
```

Every `10.30.*` / `10.31.*` prefix should point at `Ethernet 4 Forti`; any of them pointing
at `192.168.10.1` is an ExpressVPN bypass rule that must be removed. Want
`TcpTestSucceeded : True` and `InterfaceAlias : Ethernet 4 Forti`.

Broken state looks like this (note the physical NIC and its source address):

```
TcpTestSucceeded : False
SourceAddress    : 192.168.10.47
InterfaceAlias   : Ethernet
```

Verified working state, captured with both VPNs connected:

```
DestinationPrefix InterfaceAlias   NextHop      RouteMetric
----------------- --------------   -------      -----------
10.30.0.0/16     Ethernet 4 Forti 10.31.254.6           0
10.31.0.0/16     Ethernet 4 Forti 10.31.254.6           0
10.31.254.5/32   Ethernet 4 Forti 0.0.0.0              256
```

```
ComputerName     : git.office-domain.example
RemoteAddress    : 10.30.63.20
TcpTestSucceeded : True
SourceAddress    : 10.31.254.5
InterfaceAlias   : Ethernet 4 Forti
```

Only FortiClient's two `/16` routes are present, and the git host is reached through the
Forti adapter using its own source address.

### 3.5 If routing is wrong: clearing hijacked routes (admin shell)

Deleting the route is a **diagnostic**, not a fix: ExpressVPN reinstalls it on the next
reconnect. The real fix is removing the entry from the app's IP list.

```powershell
# corporate routes that point anywhere but the Forti adapter (the ExpressVPN bypass routes)
Get-NetRoute -AddressFamily IPv4 | Where-Object { (& $CorpRoutes $_) -and $_.InterfaceAlias -ne $Forti } |
  Remove-NetRoute -Confirm:$false
```

No output and no error means there was nothing to remove (with `route delete`, `The route
deletion failed: Element not found` means the same), which is the healthy state.

### 3.6 Other notes for this mode

- **If the Fortigate were configured full-tunnel** it would claim `0.0.0.0/0` and all
  traffic would go to work regardless. It isn't here: it pushes two `/16`s, so coexistence
  works.
- Check corporate policy on running a concurrent third-party VPN before relying on this.

---

## 4. Switching modes

Only the office ranges in ExpressVPN's IP bypass list change. DNS, the FortiClient bypass
entries and everything in section 1 stay as they are.

| From → to | Steps |
|---|---|
| Office network → FortiClient | 1. ExpressVPN split tunneling: remove the office ranges (`10.30.0.0/16`, `10.31.0.0/16`). 2. Reconnect ExpressVPN. 3. Connect FortiClient. 4. Check with section 3.4. |
| FortiClient → office network | 1. Disconnect FortiClient. 2. ExpressVPN split tunneling: add the office ranges back. 3. Reconnect ExpressVPN. 4. Check with section 2.2. |

---

## 5. Diagnostics (both modes)

### Is DNS working?

```powershell
Resolve-DnsName $OfficeHost -Server $Dns[0]
Resolve-DnsName $OfficeHost
```

Both should return the internal address (recorded: `10.30.63.20`).

- Both work → DNS is fine, move to routing (section 2.2 or 3.4).
- `-Server` works, plain fails → NRPT rule not matching. Check `-Status` and `Get-DnsClientGlobalSetting`.
- Both fail → the DNS servers are unreachable or port 53 is still blocked: run `-Status`
  (permit filters present?), then check the route to `$Dns[0]` for your mode.

> `Test-NetConnection` with no `-ComputerName` just pings Microsoft's default beacon over
> whatever the active route is. It confirms ExpressVPN is up and says nothing about the
> intranet. Always pass the target.

- **Network Lock** (ExpressVPN's kill switch) can block off-tunnel traffic. If everything
  looks right and the intranet still times out, turn it off to test.
- **DNS queries come from `svchost.exe`**, not from Firefox or Git. App-based bypass can
  never reach them, which is why DNS is solved with NRPT and the WFP permit, not with split
  tunneling.

---

## 6. Rollback

Nothing here is destructive, and every change reverses cleanly. Work top-down.

### Fast path: is this setup the cause?

Before undoing anything, just **disconnect ExpressVPN**. Office access (over the LAN or
FortiClient) and normal internet keep working on their own. If the symptom persists with
ExpressVPN down, none of the changes in this document are responsible.

### 1. Remove the DNS fix

Elevated PowerShell, `$ps` as in [Values used in the commands](#values-used-in-the-commands):

```powershell
iex "$ps -Uninstall"   # removes the scheduled task, the permit filters and the NRPT rules
ipconfig /flushdns
```

An NRPT rule made by hand (before the script) is removed the same way, or with
`Get-DnsClientNrptRule | Where-Object Namespace -like "*$Domain" | Remove-DnsClientNrptRule -Force`.
Confirm with `Get-DnsClientNrptRule | Where-Object Namespace -like "*$Domain"`, which should return nothing.

### 2. Revert ExpressVPN split tunneling

**Options → General → Split tunneling.**

- Remove the office ranges and `203.0.113.10/32` from the IP list
- Set `FortiClient.exe`, `FortiSSLVPNdaemon.exe`, `FortiTray.exe` back to **Use VPN**, or
  remove them from the list
- To undo everything at once, toggle **Split tunneling off**: that restores the stock
  "everything through the VPN" behaviour

Apps may need restarting to pick up the change.

### 3. Restore browser DNS-over-HTTPS (optional)

- Firefox → Settings → Privacy & Security → DNS over HTTPS → **Max Protection** / **Default**
- Chrome → Settings → Privacy and security → Security → Use secure DNS → **on**

Turning DoH back on breaks internal name resolution in that browser again.

### 4. Restore the `8.8.8.8` resolver (only if you removed it)

```powershell
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses ($Dns + "8.8.8.8")
# or hand the adapter back to DHCP:
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ResetServerAddresses
```

### 5. Clear any leftover routes

Routes from either client are held in the ActiveStore and do not survive a reboot. If a
stale one is stuck, disconnect both VPNs and reconnect, or:

```powershell
# with both VPNs disconnected: any corporate route left over
Get-NetRoute -AddressFamily IPv4 | Where-Object { & $CorpRoutes $_ } | Remove-NetRoute -Confirm:$false
```

### Confirm you're back to baseline

With both VPNs disconnected, `Get-DnsClientNrptRule` and
`Get-NetRoute -AddressFamily IPv4 | Where-Object { & $CorpRoutes $_ }` should both return
nothing (in the office, a route for your own subnet may remain; that one is DHCP's).

---

## 7. Checklists

**Always**

- [ ] ExpressVPN connected; split tunneling on, `All Other Apps` = Use VPN
- [ ] Firefox / Git CMD on **Use VPN**
- [ ] `office-dns-permit.ps1 -Status`: task running, permit filters present, NRPT rules present
- [ ] DoH off in Firefox and Chrome

**Office network mode (default)**

- [ ] Office ranges (`10.30.0.0/16`, `10.31.0.0/16`) = Bypass VPN
- [ ] FortiClient disconnected
- [ ] `Test-NetConnection $OfficeHost -Port 443` → True via `$Lan`

**FortiClient mode**

- [ ] `FortiClient.exe`, `FortiSSLVPNdaemon.exe`, `FortiTray.exe` = Bypass VPN
- [ ] `203.0.113.10/32` = Bypass VPN
- [ ] **No** office ranges or other internal `10.30.*` / `10.31.*` entries in the IP list
- [ ] ExpressVPN connected first, FortiClient second
- [ ] `Test-NetConnection $OfficeHost -Port 443` → True via `Ethernet 4 Forti`
