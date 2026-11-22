<#
.SYNOPSIS
  Keeps DNS to the office internal resolvers working while ExpressVPN is connected.

.DESCRIPTION
  ExpressVPN installs WFP block filters for ALL remote port 53 traffic (IPv4 + IPv6),
  in its own sublayer. Windows Firewall rules and ExpressVPN's bypass lists cannot
  override that. This script adds one narrow PERMIT filter in the same sublayer, at a
  higher weight, scoped to the internal resolvers on port 53 only. The permit filter is
  not persistent, so it is re-applied at startup/logon (and re-checked while running).

  It also makes sure the NRPT rule exists, so only *.office-domain.example goes to the
  internal resolvers.

.USAGE (admin PowerShell, 64-bit)
  .\office-dns-permit.ps1 -Install     # copy to C:\Program Files\office (admin-only ACL), register SYSTEM task, start it
  .\office-dns-permit.ps1 -Uninstall   # remove task, permit filter and NRPT rule
  .\office-dns-permit.ps1 -Status      # show task, permit filter, NRPT rule, test lookup
  .\office-dns-permit.ps1              # apply once now and exit
  .\office-dns-permit.ps1 -Watch       # apply, then re-check every 30 s (what the task runs)
#>
[CmdletBinding()]
param(
  [switch]$Install,
  [switch]$Uninstall,
  [switch]$Status,
  [switch]$Watch
)

# ---------------- configuration ----------------
$Resolvers      = '10.30.63.2', '10.30.63.3'     # internal DNS servers
$PermitNet      = '10.30.63.2'                    # with $PermitPrefix covers .2 and .3
$PermitPrefix   = 31
$DnsSuffix      = '.office-domain.example'
$TestHost       = 'intranet.office-domain.example'
$KnownSublayer  = '1b0346a1-adc6-45a9-8014-8bb2d656c415'   # ExpressVPN sublayer seen on 2026-10-07
$InstallDir     = Join-Path $env:ProgramFiles 'office'   # admin-only; see Protect-InstallDir
$LegacyDir      = Join-Path $env:ProgramData 'office'    # used before 2026-11-22; standard users can create folders there
$ScriptName     = 'office-dns-permit.ps1'
$TaskName       = 'office-dns-permit'
$LogFile        = Join-Path $InstallDir 'dns-permit.log'
$WatchSeconds   = 30
# -----------------------------------------------

$ErrorActionPreference = 'Stop'

function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Log([string]$msg) {
  $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg
  Write-Host $line
  try {
    if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) { Move-Item $LogFile "$LogFile.old" -Force }
    Add-Content -Path $LogFile -Value $line
  } catch { }
}

if (-not (Test-Admin)) { throw 'Run this from an elevated (administrator) PowerShell.' }

# The SYSTEM task runs the script from $InstallDir, so only SYSTEM and Administrators may write there.
# Takes ownership and replaces the ACL even if the folder already existed (someone could have pre-created it).
function Protect-InstallDir {
  if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
  $sys    = New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'       # SYSTEM
  $admins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'   # BUILTIN\Administrators
  $users  = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'   # BUILTIN\Users
  $inh = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
  $acl = New-Object Security.AccessControl.DirectorySecurity
  $acl.SetOwner($admins)
  $acl.SetAccessRuleProtection($true, $false)      # no inherited entries
  foreach ($r in @(
      (New-Object Security.AccessControl.FileSystemAccessRule($sys,    'FullControl',    $inh, 'None', 'Allow')),
      (New-Object Security.AccessControl.FileSystemAccessRule($admins, 'FullControl',    $inh, 'None', 'Allow')),
      (New-Object Security.AccessControl.FileSystemAccessRule($users,  'ReadAndExecute', $inh, 'None', 'Allow')))) {
    $acl.AddAccessRule($r)
  }
  Set-Acl -Path $InstallDir -AclObject $acl
  # files already inside: owner Administrators, explicit entries dropped, inherit the folder ACL
  if (Get-ChildItem $InstallDir -Force) {
    icacls "$InstallDir\*" /setowner '*S-1-5-32-544' /T /C /Q | Out-Null
    icacls "$InstallDir\*" /reset /T /C /Q | Out-Null
  }
}

# True when only SYSTEM / Administrators / TrustedInstaller can write to $InstallDir
function Test-InstallDirSafe {
  if (-not (Test-Path $InstallDir)) { return $false }
  $acl = Get-Acl $InstallDir
  $okSids = 'S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
  if ($okSids -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) { return $false }
  $write = [Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, WriteAttributes, Delete, ChangePermissions, TakeOwnership'
  foreach ($r in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
    if ($r.AccessControlType -ne 'Allow') { continue }
    if ($okSids -contains $r.IdentityReference.Value) { continue }
    if (($r.FileSystemRights -band $write) -ne 0) { return $false }
  }
  return $true
}

# ---------------- WFP helper ----------------
if (-not ('Wfp' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Runtime.InteropServices;
public static class Wfp {
  [StructLayout(LayoutKind.Sequential)] struct DISPLAY { public IntPtr name; public IntPtr description; }
  [StructLayout(LayoutKind.Sequential)] struct BLOB { public uint size; public IntPtr data; }
  [StructLayout(LayoutKind.Sequential)] struct VAL { public uint type; public IntPtr val; }
  [StructLayout(LayoutKind.Sequential)] struct COND { public Guid field; public uint match; public VAL value; }
  [StructLayout(LayoutKind.Sequential)] struct ACTION { public uint type; public Guid key; }
  [StructLayout(LayoutKind.Sequential)] struct CTX { public ulong a; public ulong b; }
  [StructLayout(LayoutKind.Sequential)] struct FILTER {
    public Guid filterKey; public DISPLAY display; public uint flags; public IntPtr providerKey; public BLOB providerData;
    public Guid layerKey; public Guid subLayerKey; public VAL weight; public uint numConds; public IntPtr conds;
    public ACTION action; public CTX ctx; public IntPtr reserved; public ulong filterId; public VAL effWeight; }

  [DllImport("fwpuclnt.dll")] static extern uint FwpmEngineOpen0(IntPtr server, uint authn, IntPtr ident, IntPtr session, out IntPtr h);
  [DllImport("fwpuclnt.dll")] static extern uint FwpmEngineClose0(IntPtr h);
  [DllImport("fwpuclnt.dll")] static extern uint FwpmFilterAdd0(IntPtr h, ref FILTER f, IntPtr sd, out ulong id);
  [DllImport("fwpuclnt.dll")] static extern uint FwpmFilterDeleteByKey0(IntPtr h, ref Guid key);

  static readonly Guid LAYER  = new Guid("c38d57d1-05a7-4c33-904f-7fbceee60e82"); // ALE_AUTH_CONNECT_V4
  static readonly Guid F_ADDR = new Guid("b235ae9a-1d64-49b8-a44c-5ff3d9095045"); // IP_REMOTE_ADDRESS
  static readonly Guid F_PORT = new Guid("c35a604d-d22b-4e1a-91b4-68f674ee674b"); // IP_REMOTE_PORT
  static readonly Guid KEY    = new Guid("7d6e0b34-1f4a-4c8e-9a52-3b0c1d2e4f60"); // our permit filter

  // returns the raw HRESULT (0 = ok)
  public static uint Remove() {
    IntPtr h; uint r = FwpmEngineOpen0(IntPtr.Zero, 0xFFFFFFFF, IntPtr.Zero, IntPtr.Zero, out h);
    if (r != 0) return r;
    Guid k = KEY; r = FwpmFilterDeleteByKey0(h, ref k); FwpmEngineClose0(h);
    return r;
  }

  public static uint Add(Guid sublayer, string ip, int prefix, ushort port, out ulong id) {
    id = 0;
    byte[] b = IPAddress.Parse(ip).GetAddressBytes();
    uint addr = ((uint)b[0] << 24) | ((uint)b[1] << 16) | ((uint)b[2] << 8) | b[3];
    uint mask = prefix == 0 ? 0 : 0xFFFFFFFFu << (32 - prefix);
    IntPtr h; uint r = FwpmEngineOpen0(IntPtr.Zero, 0xFFFFFFFF, IntPtr.Zero, IntPtr.Zero, out h);
    if (r != 0) return r;

    IntPtr name = Marshal.StringToHGlobalUni("Permit DNS to office resolvers");
    IntPtr pw = Marshal.AllocHGlobal(8); Marshal.WriteInt64(pw, unchecked((long)0xF000000000000000UL));
    IntPtr pm = Marshal.AllocHGlobal(8); Marshal.WriteInt32(pm, 0, unchecked((int)addr)); Marshal.WriteInt32(pm, 4, unchecked((int)mask));
    int sz = Marshal.SizeOf(typeof(COND));
    IntPtr pc = Marshal.AllocHGlobal(sz * 2);
    try {
      COND c1 = new COND(); c1.field = F_ADDR; c1.match = 0; c1.value.type = 0x100; c1.value.val = pm;          // FWP_V4_ADDR_MASK
      COND c2 = new COND(); c2.field = F_PORT; c2.match = 0; c2.value.type = 2;     c2.value.val = (IntPtr)port; // FWP_UINT16
      Marshal.StructureToPtr(c1, pc, false);
      Marshal.StructureToPtr(c2, IntPtr.Add(pc, sz), false);

      FILTER f = new FILTER();
      f.filterKey = KEY; f.display.name = name; f.layerKey = LAYER; f.subLayerKey = sublayer;
      f.weight.type = 4; f.weight.val = pw;                 // FWP_UINT64 explicit weight
      f.numConds = 2; f.conds = pc; f.action.type = 0x1002; // FWP_ACTION_PERMIT
      r = FwpmFilterAdd0(h, ref f, IntPtr.Zero, out id);
    } finally {
      FwpmEngineClose0(h);
      Marshal.FreeHGlobal(name); Marshal.FreeHGlobal(pw); Marshal.FreeHGlobal(pm); Marshal.FreeHGlobal(pc);
    }
    return r;
  }
}
'@
}

# HRESULTs as decimal: PowerShell reads 0x8032xxxx hex literals as negative Int32, which will not cast to UInt32
$E_ALREADY_EXISTS   = [uint32]2150760457   # 0x80320009 FWP_E_ALREADY_EXISTS
$E_SUBLAYER_MISSING = [uint32]2150760455   # 0x80320007 FWP_E_SUBLAYER_NOT_FOUND

# Find ExpressVPN's sublayer from its IPv4 "block remote port 53" filter (slow: dumps all filters)
function Find-ExpressVpnSublayer {
  $xmlPath = Join-Path $InstallDir 'wfp.xml'
  if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
  netsh wfp show filters file="$xmlPath" verbose=on | Out-Null
  [xml]$x = Get-Content $xmlPath
  foreach ($f in $x.wfpdiag.filters.item) {
    if ($f.displayData.name -ne 'ExpressVPN Firewall') { continue }
    if ($f.layerKey -ne 'FWPM_LAYER_ALE_AUTH_CONNECT_V4' -or $f.action.type -ne 'FWP_ACTION_BLOCK') { continue }
    foreach ($c in $f.filterCondition.item) {
      $v = $c.conditionValue.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.Name -ne 'type' } | Select-Object -First 1
      if ($c.fieldKey -eq 'FWPM_CONDITION_IP_REMOTE_PORT' -and $v.InnerText -eq '53') {
        $sub = ([string]$f.subLayerKey).Trim('{}')
        if ($sub -eq 'FWPM_SUBLAYER_UNIVERSAL') { $sub = 'eebecc03-ced4-4380-819a-2734397b2b74' }
        return $sub
      }
    }
  }
  return $null
}

function Add-Permit([string]$sublayer) {
  $id = [uint64]0
  [uint32]$r = [Wfp]::Add([guid]$sublayer, $PermitNet, $PermitPrefix, 53, [ref]$id)
  return $r, $id
}

# Ensure the permit exists. Returns $true when it is in place.
$script:Sublayer = $KnownSublayer
$script:LastDiscovery = $null
function Ensure-Permit {
  $r, $id = Add-Permit $script:Sublayer
  if ($r -eq 0) { Write-Log "permit added (filter $id, sublayer $script:Sublayer)"; return $true }
  if ($r -eq $E_ALREADY_EXISTS) { return $true }

  # sublayer unknown/missing: try to discover it from ExpressVPN's block filter.
  # The filter dump is slow, so do it at most every 5 minutes (matters when ExpressVPN is not installed/running).
  if ($script:LastDiscovery -and ((Get-Date) - $script:LastDiscovery).TotalMinutes -lt 5) { return $false }
  $script:LastDiscovery = Get-Date
  Write-Log ('add failed 0x{0:X8}; looking up ExpressVPN sublayer' -f $r)
  $found = Find-ExpressVpnSublayer
  if (-not $found) { Write-Log 'ExpressVPN port 53 block filter not found yet'; return $false }
  $script:Sublayer = $found
  $r, $id = Add-Permit $script:Sublayer
  if ($r -eq 0) { Write-Log "permit added (filter $id, discovered sublayer $found)"; return $true }
  if ($r -eq $E_ALREADY_EXISTS) { return $true }
  Write-Log ('add failed again 0x{0:X8}' -f $r)
  return $false
}

function Ensure-Nrpt {
  $have = Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { $_.Namespace -contains $DnsSuffix }
  if (-not $have) {
    Add-DnsClientNrptRule -Namespace $DnsSuffix -NameServers $Resolvers | Out-Null
    Write-Log "NRPT rule added for $DnsSuffix -> $($Resolvers -join ', ')"
  }
}

# ---------------- modes ----------------
if ($Uninstall) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  [void][Wfp]::Remove()
  Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { $_.Namespace -contains $DnsSuffix } |
    ForEach-Object { Remove-DnsClientNrptRule -Name $_.Name -Force }
  Write-Log "uninstalled: scheduled task, permit filter and NRPT rule removed (script and log left in $InstallDir)"
  return
}

if ($Status) {
  Write-Host '--- scheduled task ---'
  Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Get-ScheduledTaskInfo |
    Format-List TaskName, LastRunTime, LastTaskResult
  (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue).State
  Write-Host '--- permit filter (expect: ... already exists) ---'
  $r, $id = Add-Permit $script:Sublayer
  if ($r -eq $E_ALREADY_EXISTS) { 'present' }
  elseif ($r -eq 0) { 'was missing, just added' }
  else { 'add failed 0x{0:X8}' -f $r }
  Write-Host "--- install folder ($InstallDir) ---"
  if (Test-InstallDirSafe) { 'only SYSTEM/Administrators can write (ok)' } else { 'NOT locked down: run -Install again' }
  if (Test-Path (Join-Path $LegacyDir $ScriptName)) { "old copy still in $LegacyDir (run -Install to remove it)" }
  Write-Host '--- NRPT ---'
  Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { $_.Namespace -contains $DnsSuffix } |
    Format-List Name, Namespace, NameServers
  Write-Host '--- lookup ---'
  Clear-DnsClientCache
  try { Resolve-DnsName $TestHost -Type A -DnsOnly -ErrorAction Stop | Format-Table Name, Type, IPAddress -AutoSize }
  catch { "lookup failed: $($_.Exception.Message)" }
  Write-Host "--- last log lines ($LogFile) ---"
  if (Test-Path $LogFile) { Get-Content $LogFile -Tail 10 }
  return
}

if ($Install) {
  Protect-InstallDir
  if (-not (Test-InstallDirSafe)) { throw "could not restrict $InstallDir to SYSTEM and Administrators; not installing" }
  $dest = Join-Path $InstallDir $ScriptName
  if ($PSCommandPath -and ((Resolve-Path $PSCommandPath).Path -ne $dest)) { Copy-Item $PSCommandPath $dest -Force }

  $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$dest`" -Watch"
  $triggers = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn))
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)

  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Principal $principal `
    -Settings $settings -Description 'Re-applies the WFP permit for DNS to the office resolvers so ExpressVPN leak protection does not block them.' `
    -Force | Out-Null
  Write-Log "installed scheduled task '$TaskName' (at startup + logon, SYSTEM, watch mode); script: $dest"
  # older versions ran from ProgramData, which standard users can write to; remove that copy
  $old = Join-Path $LegacyDir $ScriptName
  if (Test-Path $old) { Remove-Item $old -Force; Write-Log "removed old copy $old (old logs left in $LegacyDir)" }
  Start-ScheduledTask -TaskName $TaskName
  Write-Log 'task started'
  return
}

# default / -Watch: apply (fresh), optionally keep re-checking
# The task must only ever run a copy nobody but admins can change.
if ($Watch -and $PSCommandPath -and ((Split-Path $PSCommandPath -Parent) -eq $InstallDir) -and -not (Test-InstallDirSafe)) {
  Write-Log "refusing to run: $InstallDir is writable by non-admins (run -Install again)"; exit 1
}
Ensure-Nrpt
[void][Wfp]::Remove()                 # start from a clean state; ignore "not found"
$ok = Ensure-Permit
if (-not $Watch) {
  if ($ok) { Write-Log 'done' } else { Write-Log 'permit NOT applied (is ExpressVPN installed and has it created its filters?)' }
  return
}

Write-Log "watch mode: re-checking every $WatchSeconds s"
while ($true) {
  Start-Sleep -Seconds $WatchSeconds
  try { [void](Ensure-Permit) } catch { Write-Log "check error: $($_.Exception.Message)" }
}
