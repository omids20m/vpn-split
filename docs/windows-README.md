# ExpressVPN + FortiClient Coexistence on Windows

Running ExpressVPN for general internet traffic while reaching the `office-domain.example`
intranet through the FortiClient SSL-VPN tunnel.

**Environment**

| Item | Value |
|---|---|
| Fortigate public gateway | `203.0.113.10` (custom port) |
| Forti adapter | `Ethernet 4 Forti`, IP `10.31.254.5/32`, gateway `10.31.254.6` |
| Corporate routes pushed by Forti | `10.30.0.0/16`, `10.31.0.0/16` |
| Internal DNS servers | `10.30.63.3`, `10.30.63.2` |
| Internal DNS suffix | `office-domain.example` |
| Physical NIC | `Ethernet`, `192.168.10.47`, gateway `192.168.10.1` |

---

## The three problems, and what actually solves each

There is no URL/domain-based split tunneling in ExpressVPN on Windows. Splitting is
by **application** or by **IP/CIDR**. Getting the intranet working is three separate
fixes, and they are easy to confuse with each other.

| Symptom | Real cause | Fix |
|---|---|---|
| Forti tunnel won't establish | ExpressVPN wraps the SSL-VPN handshake | Bypass the Forti apps + gateway IP |
| Names don't resolve | ExpressVPN forces its own DNS (`100.64.100.1`) | NRPT rule for `.office-domain.example` |
| Names resolve, nothing connects | IP bypass rules hijack routes away from the tunnel | **Remove** those IP bypass rules |

---

## 1. ExpressVPN split tunneling config

**Options → General → Split tunneling → on.** `All Other Apps` = **Use VPN**.

### Apps to set to Bypass VPN

- `FortiClient.exe`
- `FortiSSLVPNdaemon.exe`
- `FortiTray.exe`

This stops ExpressVPN double-wrapping the outer tunnel to the concentrator.

### IPs to set to Bypass VPN

- `203.0.113.10/32` — the Fortigate public gateway. **This is the only IP entry needed.**

### IPs that must NOT be in the list

- `10.30.63.0/24`
- `10.31.150.0/24`
- any other internal `10.30.x` / `10.31.x` prefix

**Why this matters more than anything else in this document:** an ExpressVPN "Bypass VPN"
IP rule installs a route pointing at the *physical* gateway (`192.168.10.1`). Those `/24`
entries are more specific than FortiClient's `/16` routes, so Windows prefers them and
dumps intranet traffic onto the local LAN instead of into the tunnel:

```
10.30.0.0/16     → Ethernet 4 Forti (10.31.254.6)   ← FortiClient, correct
10.30.63.0/24    → Ethernet (192.168.10.1)           ← ExpressVPN, hijacks it
```

Bypass means "keep off the ExpressVPN tunnel," not "send into the Forti tunnel."
Intranet traffic should be left alone entirely — FortiClient's own `/16` routes handle it.

### Apps that do NOT need bypassing

Firefox, Git CMD, `mstsc.exe`, `devenv.exe`, `dotnet.exe`, `ssms.exe` — leave all of these
on **Use VPN**. Routing sends their intranet traffic into the Forti adapter on its own.

> **Outstanding:** Firefox and Git CMD are currently still set to **Bypass VPN**. They were
> only bypassed as a workaround for the DNS problem, which the NRPT rule now solves properly.
> Leaving Firefox bypassed means normal browsing has no VPN protection. Set both back to
> **Use VPN** — intranet access will keep working.

---

## 2. DNS

Every adapter already lists `10.30.63.3` / `10.30.63.2`, but ExpressVPN's WinTUN adapter
carries `100.64.100.1` and wins on interface metric. Since `office-domain.example` is a public-looking
domain, ExpressVPN's resolver returns *an* answer — just the wrong one. That fails without
looking like a DNS failure.

### NRPT rule (run in an elevated PowerShell)

```powershell
Add-DnsClientNrptRule -Namespace ".office-domain.example" -NameServers "10.30.63.3","10.30.63.2"
```

The leading dot matches the suffix and everything under it. Elevation is required —
without it you get *"Failed to load the NRPT information."*

Verify:

```powershell
Get-DnsClientNrptRule | Where-Object Namespace -like "*office-domain*"
```

> `Get-DnsClientNrptRule` has no `-Namespace` parameter. Filter with `Where-Object`.

### Browser DNS-over-HTTPS must be off

DoH bypasses system DNS, NRPT rules, and the hosts file entirely.

- Firefox → Settings → Privacy & Security → DNS over HTTPS → **Off**
- Chrome → Settings → Privacy and security → Security → Use secure DNS → **off**

### Housekeeping

The `Ethernet` adapter lists `8.8.8.8` as a third resolver. Worth removing — it can answer
with the public record when the internal ones are slow.

---

## 3. Connection order

1. Connect **ExpressVPN** first
2. Connect **FortiClient** second

Forti's routes then land last and its adapter metric ends up lowest
(currently `Ethernet 4 Forti` = 1, ExpressVPN WinTUN = 3).

---

## Diagnostics

### Is DNS working?

```powershell
Resolve-DnsName git.office-domain.example -Server 10.30.63.3
Resolve-DnsName git.office-domain.example
```

Both should return `10.30.63.20`.

- Both work → DNS is fine, move to routing.
- `-Server` works, plain fails → NRPT rule not matching. Check `Get-DnsClientGlobalSetting`.
- Both fail → internal resolvers unreachable; confirm the Forti tunnel is up.

### Is routing working?

```powershell
Get-NetRoute -AddressFamily IPv4 |
  Where-Object { $_.DestinationPrefix -like "10.3*" } |
  Sort-Object DestinationPrefix |
  Format-Table DestinationPrefix,InterfaceAlias,NextHop,RouteMetric -AutoSize
```

Every `10.30.*` / `10.31.*` prefix should point at `Ethernet 4 Forti`.
Any of them pointing at `192.168.10.1` is an ExpressVPN bypass rule that must be removed.

```powershell
Find-NetRoute -RemoteIPAddress 10.30.63.20
```

### Does it actually connect?

```powershell
Test-NetConnection -ComputerName git.office-domain.example -Port 443
```

Want: `TcpTestSucceeded : True` and `InterfaceAlias : Ethernet 4 Forti`.

Broken state looks like this — note the physical NIC and its source address:

```
TcpTestSucceeded : False
SourceAddress    : 192.168.10.47
InterfaceAlias   : Ethernet
```

> `Test-NetConnection` with no `-ComputerName` just pings Microsoft's default beacon over
> whatever the active route is. It confirms ExpressVPN is up and says nothing about the
> intranet. Always pass the target.

### If routing is wrong: clearing hijacked routes (admin shell)

Only relevant if the route check above shows a `10.30.*` / `10.31.*` prefix pointing at
`192.168.10.1`. Deleting the route is a **diagnostic**, not a fix — ExpressVPN reinstalls it
on the next reconnect. The real fix is removing the entry from the app's IP list.

```powershell
route delete 10.30.63.0 mask 255.255.255.0
route delete 10.31.150.0 mask 255.255.255.0
```

`The route deletion failed: Element not found` means the route isn't there — which is the
healthy state, not an error.

---

## Verified working state

Captured after the fix, with both VPNs connected:

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
Forti adapter using its own source address. No ExpressVPN `/24` entries competing.

---

## Rollback

Nothing here is destructive, and every change reverses cleanly. Work top-down — the first
step alone resolves most "did this break my machine?" moments.

### Fast path: is this setup the cause?

Before undoing anything, just **disconnect ExpressVPN**. FortiClient and normal internet
both keep working on their own. If the symptom persists with ExpressVPN down, none of the
changes in this document are responsible.

### 1. Remove the NRPT rule

Removes the DNS override for `.office-domain.example`. This is the only change that touches
Windows itself.

```powershell
Get-DnsClientNrptRule | Where-Object Namespace -like "*office-domain*" | Remove-DnsClientNrptRule -Force
```

Or by GUID, if you prefer to be explicit:

```powershell
Remove-DnsClientNrptRule -Name "{EB25B542-3323-4B6E-BAC3-25FD0B470563}"
```

Requires elevation. Then clear cached answers:

```powershell
ipconfig /flushdns
```

Confirm it's gone — this should return nothing:

```powershell
Get-DnsClientNrptRule | Where-Object Namespace -like "*office-domain*"
```

### 2. Revert ExpressVPN split tunneling

**Options → General → Split tunneling.**

- Remove the IP entry `203.0.113.10/32`
- Set `FortiClient.exe`, `FortiSSLVPNdaemon.exe`, `FortiTray.exe`, `FortiClient VPN` back to
  **Use VPN**, or remove them from the list
- To undo everything at once, toggle **Split tunneling off** — that restores the stock
  "everything through the VPN" behaviour without editing entries one by one

Apps may need restarting to pick up the change.

### 3. Restore browser DNS-over-HTTPS (optional)

Only if you want it back:

- Firefox → Settings → Privacy & Security → DNS over HTTPS → **Max Protection** / **Default**
- Chrome → Settings → Privacy and security → Security → Use secure DNS → **on**

Note that turning DoH back on will break internal name resolution in that browser again,
whether or not the NRPT rule is present.

### 4. Restore the `8.8.8.8` resolver (only if you removed it)

```powershell
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses "10.30.63.3","10.30.63.2","8.8.8.8"
```

To hand the adapter back to DHCP entirely:

```powershell
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ResetServerAddresses
```

### 5. Clear any leftover routes

Routes from either client are held in the ActiveStore and do not survive a reboot. If a
stale one is stuck, disconnect both VPNs and reconnect, or:

```powershell
route delete 10.30.63.0 mask 255.255.255.0
route delete 10.31.150.0 mask 255.255.255.0
```

`Element not found` means there was nothing to remove.

### Confirm you're back to baseline

With both VPNs disconnected:

```powershell
Get-DnsClientNrptRule
Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.DestinationPrefix -like "10.3*" }
```

Both should return nothing. Anything left over is from a client that is still running.

---

## Other notes

- **Network Lock** (ExpressVPN's kill switch) can block off-tunnel traffic. If everything
  above looks right and the intranet still times out, turn it off to test.
- **DNS queries come from `svchost.exe`**, not from Firefox or Git. App-based bypass can
  never reach them — which is why DNS is solved with NRPT, not with split tunneling.
- **If the Fortigate were configured full-tunnel** it would claim `0.0.0.0/0` and all
  traffic would go to work regardless. It isn't here — it pushes two `/16`s — so
  coexistence works.
- Check corporate policy on running a concurrent third-party VPN before relying on this.

---

## Quick checklist

- [ ] Split tunneling on, `All Other Apps` = Use VPN
- [ ] `FortiClient.exe`, `FortiSSLVPNdaemon.exe`, `FortiTray.exe` = Bypass VPN
- [ ] `203.0.113.10/32` = Bypass VPN
- [ ] **No** internal `10.30.*` / `10.31.*` entries in the IP list
- [ ] Firefox / Git CMD returned to **Use VPN**
- [ ] NRPT rule for `.office-domain.example` present
- [ ] DoH off in Firefox and Chrome
- [ ] ExpressVPN connected first, FortiClient second
- [ ] `Test-NetConnection git.office-domain.example -Port 443` → True via `Ethernet 4 Forti`