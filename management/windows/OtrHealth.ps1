<#
  Health Center of the OpenThinRDP manager: the health of the whole Hyper-V and RDS infrastructure (hosts, failover
  cluster, storage, VMs, domain controllers, DNS, SQL AlwaysOn, the devices around them such as a NAS or the witness, the
  backups). Dot-sourced by OpenThinRDP-Manager.ps1 after OtrVdi.ps1; nothing here draws a window.

  Same three parts as OtrVdi.ps1, so that everything after the probe can be tested without a server:
    the probe     ($script:HealthProbe) runs in a background runspace and returns plain data: one WinRM call per host,
                  per domain controller and per server (in parallel), one per cluster on one of its nodes, SQL through
                  SqlClient, the devices with ping, TCP and SMB from this PC. OTR_MANAGER_HEALTH_DEMO = the same data
                  from a JSON file (tests, screenshots).
    the model     (ConvertTo-HealthModel) makes the tree of the page: cluster -> hosts -> VMs, domain -> DCs and DNS,
                  SQL AlwaysOn -> replicas, the brokers of the Desktops page (its findings, not read twice), devices,
                  backups. Each item has its facts and its checks, each check one sentence of what is wrong and one of
                  what it means, in the language of the window.
    the actions   (Get-HealthActionPlan) say what they do and to whom, refuse what is not safe now, and say whether
                  they are SAFE: only those run by themselves in "diagnosis and repair" mode; the others always ask.
                  The steps run in $script:VdiJobRunner (OtrVdi.ps1), or only say what they would do
                  (OTR_MANAGER_VDI_DRYRUN=1 covers both pages).

  What is safe here: starting a service that should run, ending a service stuck in StopPending with time limits (never
  Restart-Service, which waits for ever), resynchronising a clock, bringing the witness online, OfflineAction 2 for VMs
  with a vTPM, waking a device with Wake-on-LAN. Never: saving a VM, cutting its power, two brokers, two domain
  controllers or two SQL replicas at once, a failover of SQL.
#>

# ---------------------------------------------------------------------------------------------
# A path that may be on a share that does not answer: Test-Path waits for the SMB timeout of Windows (tens of
# seconds); this waits at most $ms.
# ---------------------------------------------------------------------------------------------
if (-not ('OtrHealthNet' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading.Tasks;
public static class OtrHealthNet {
    // 1 = exists, 0 = does not exist, -1 = no answer in time
    public static int PathExists(string path, int ms) {
        Task<bool> t = Task.Factory.StartNew(delegate { return Directory.Exists(path) || File.Exists(path); });
        try { if (!t.Wait(ms)) return -1; } catch { return 0; }
        return t.Result ? 1 : 0;
    }
    // the newest file of a folder (or the file itself), and whether a text is in its last lines; null = none
    public static string[] Newest(string path, string text, int ms) {
        Task<string[]> t = Task.Factory.StartNew(delegate {
            FileInfo best = null;
            if (File.Exists(path)) best = new FileInfo(path);
            else if (Directory.Exists(path)) {
                foreach (FileInfo f in new DirectoryInfo(path).GetFiles()) {
                    if (!string.IsNullOrEmpty(text)) {
                        if (best != null && f.LastWriteTime <= best.LastWriteTime) continue;
                        if (!Contains(f.FullName, text)) continue;
                    }
                    if (best == null || f.LastWriteTime > best.LastWriteTime) best = f;
                }
            }
            if (best == null) return null;
            bool hit = string.IsNullOrEmpty(text) || Contains(best.FullName, text);
            return new string[] { best.FullName, best.LastWriteTime.ToString("yyyy-MM-ddTHH:mm:ss"), hit ? "1" : "0" };
        });
        if (!t.Wait(ms)) throw new TimeoutException(path + ": no answer in " + (ms / 1000) + " s");
        return t.Result;
    }
    // the text in the last 256 KB of the file (a log grows at the end)
    static bool Contains(string file, string text) {
        try {
            using (FileStream s = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                long start = Math.Max(0, s.Length - 262144); s.Seek(start, SeekOrigin.Begin);
                using (StreamReader r = new StreamReader(s, true)) { return r.ReadToEnd().IndexOf(text, StringComparison.OrdinalIgnoreCase) >= 0; }
            }
        } catch { return false; }
    }
}
'@
}

# ---------------------------------------------------------------------------------------------
# Settings of the Health Center: in the manager's own settings (%APPDATA%\OpenThinRDP\manager.json), next to those of
# the Desktops page, for the same reason: they are for the administrator's PC and account, not for the devices.
#   Enabled      $false = nothing is read
#   Mode         diagnose | repair: in repair mode the SAFE repairs run by themselves; Items = the same per item
#   Hosts        physical Hyper-V hosts (besides those the Desktops page and the clusters find)
#   Cluster      auto | yes | no: a failover cluster, single hosts, or as the hosts say
#   Devices      one per line: name address [ports] [\\share] [MAC]   (a NAS, the witness, a switch...)
#   DnsServers   besides the domain controllers
#   BrokerName   the shared name of the brokers (also read by the Desktops page)
#   SqlListener  the AlwaysOn listener, empty = no SQL checks
#   BackupPath   a log file or a folder of logs; BackupText = the text of a successful backup; BackupHours = max age
# ---------------------------------------------------------------------------------------------
$script:HealthRefreshSeconds = 180
# older than this, a repair that was tried is tried again
$script:HealthRetryMinutes = 30
# two actions on servers of the same role (two DCs, two SQL replicas, two brokers) never closer than this
$script:HealthRoleMinutes = 10
# thresholds of the checks (the same for every site: a site with other needs changes them here)
$script:HealthLimits = @{ DiskGB = 5; DiskPct = 8; DiskWarnPct = 15; DiskWarnGB = 50; MemPct = 5; MemWarnPct = 10; SkewWarn = 60; SkewMax = 240
  CheckpointDays = 3; ReverseMs = 1500; DnsMs = 1000; BackupHours = 26; JobDays = 3 }
function Get-HealthDefaults {
  [pscustomobject]@{ Enabled = $true; Mode = 'diagnose'; Items = (New-Object psobject); Hosts = ''; Cluster = 'auto'; Devices = ''; DnsServers = ''; BrokerName = ''
    SqlListener = ''; BackupPath = ''; BackupText = ''; BackupHours = $script:HealthLimits.BackupHours }
}
function Get-HealthSettings {
  $s = Get-HealthDefaults
  $m = Read-ManagerSettings
  if ($m.PSObject.Properties['Health'] -and $m.Health) {
    foreach ($p in $s.PSObject.Properties.Name) { if ($m.Health.PSObject.Properties[$p] -and $null -ne $m.Health.$p) { $s.$p = $m.Health.$p } }
  }
  $s.Enabled = [bool]$s.Enabled
  if ($s.Mode -notin 'diagnose', 'repair') { $s.Mode = 'diagnose' }
  if ($s.Cluster -notin 'auto', 'yes', 'no') { $s.Cluster = 'auto' }
  $h = 0; if (-not [int]::TryParse("$($s.BackupHours)", [ref]$h) -or $h -lt 1) { $h = $script:HealthLimits.BackupHours }; $s.BackupHours = $h
  if (-not ($s.Items -is [psobject]) -or $s.Items -is [string]) { $s.Items = New-Object psobject }
  $s
}
# A device line: name address [ports] [\\share] [MAC]; $null = not a device line
function ConvertFrom-HealthDevice([string]$line) {
  $p = @("$line".Trim() -split '\s+' | Where-Object { $_ })
  if ($p.Count -lt 2) { return $null }
  $d = [pscustomobject]@{ Name = $p[0]; Address = $p[1]; Ports = @(); Share = ''; Mac = ''; Bad = '' }
  foreach ($x in @($p | Select-Object -Skip 2)) {
    if ($x -match '^\d{1,5}(,\d{1,5})*$') { $d.Ports = @($x.Split(',') | ForEach-Object { [int]$_ } | Where-Object { $_ -ge 1 -and $_ -le 65535 }) }
    elseif ($x -match $script:Rx.Share) { $d.Share = $x }
    elseif ($x -match '^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$') { $d.Mac = $x.ToUpper().Replace(':', '-') }
    else { $d.Bad = $x }
  }
  $d
}
function Get-HealthDevices($s) { @(@("$($s.Devices)" -split "`r?`n") | ForEach-Object { ConvertFrom-HealthDevice $_ } | Where-Object { $_ }) }
# $null = good, else the reason
function Test-HealthSettings($s) {
  foreach ($n in @(Split-List $s.Hosts) + @(Split-List $s.DnsServers) + @(Split-List $s.BrokerName)) { if ($n -cnotmatch $script:Rx.Name) { return (Get-Text 'VdiErrName' $n) } }
  if ($s.SqlListener -and ("$($s.SqlListener)" -replace ',\d{1,5}$', '') -cnotmatch $script:Rx.Name) { return (Get-Text 'VdiErrName' $s.SqlListener) }
  foreach ($l in @("$($s.Devices)" -split "`r?`n" | Where-Object { $_.Trim() })) {
    $d = ConvertFrom-HealthDevice $l
    if (-not $d -or $d.Name -cnotmatch $script:Rx.Name -or $d.Address -cnotmatch $script:Rx.Name -or $d.Bad) { return (Get-Text 'HcErrDevice' $l.Trim()) }
  }
  if ($s.BackupPath -and "$($s.BackupPath)" -notmatch '^([A-Za-z]:\\|\\\\[A-Za-z0-9.-]+\\)') { return (Get-Text 'HcErrBackup' $s.BackupPath) }
  $h = 0; if (-not [int]::TryParse("$($s.BackupHours)", [ref]$h) -or $h -lt 1 -or $h -gt 2000) { return (Get-Text 'HcErrHours' $s.BackupHours) }
  $null
}
function Save-HealthSettings($s) {
  $m = Read-ManagerSettings
  $items = if ($s.Items -is [psobject]) { $s.Items } else { New-Object psobject }
  Set-ManagerSetting $m 'Health' ([pscustomobject]@{ Enabled = [bool]$s.Enabled; Mode = $(if ($s.Mode -eq 'repair') { 'repair' } else { 'diagnose' }); Items = $items
    Hosts = ((Split-List $s.Hosts) -join ' '); Cluster = [string]$s.Cluster
    Devices = ((@("$($s.Devices)" -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })) -join "`n"); DnsServers = ((Split-List $s.DnsServers) -join ' ')
    BrokerName = ((Split-List $s.BrokerName) -join ' '); SqlListener = "$($s.SqlListener)".Trim(); BackupPath = "$($s.BackupPath)".Trim(); BackupText = "$($s.BackupText)".Trim(); BackupHours = [int]$s.BackupHours })
  Save-ManagerSettings $m
}
# the mode of one item: its own, else the one of the nearest item above it with its own, else the page's
function Set-HealthItemMode($s, [string]$id, [string]$mode) {
  if (-not ($s.Items -is [psobject])) { $s.Items = New-Object psobject }
  if ($s.Items.PSObject.Properties[$id]) { $s.Items.PSObject.Properties.Remove($id) }
  if ($mode -in 'diagnose', 'repair') { $s.Items | Add-Member -NotePropertyName $id -NotePropertyValue $mode }
}
function Get-HealthItemMode($s, [string]$id) { if ($s.Items -is [psobject] -and $s.Items.PSObject.Properties[$id]) { [string]$s.Items.$id } else { '' } }
function Get-HealthEffectiveMode($model, $s, [string]$id) {
  $n = $model.Index[$id]
  while ($n) { $m = Get-HealthItemMode $s $n.Id; if ($m) { return $m }; $n = if ($n.Parent) { $model.Index[$n.Parent] } else { $null } }
  $s.Mode
}

# ---------------------------------------------------------------------------------------------
# The probe. Input ($cfg): Hosts (names), Brokers (servers of the Desktops page), DnsServers, SqlListener, Devices,
# Backup, Cluster (auto/yes/no), Domain ($true = find the DCs in AD), Guests ($true = read the disks inside the VMs),
# OpenMs/OperationMs. Everything that fails leaves a note and the rest goes on.
# ---------------------------------------------------------------------------------------------
$script:HealthProbe = {
  param($cfg)
  $ErrorActionPreference = 'Continue'; $ProgressPreference = 'SilentlyContinue'
  function Iso($d) { if ($d) { ([datetime]$d).ToString('yyyy-MM-ddTHH:mm:ss') } else { $null } }
  function Short($n) { ([string]$n -split '\.')[0].ToUpper() }
  function Test-Tcp([string]$ip, [int]$port, [int]$ms) {
    $c = New-Object Net.Sockets.TcpClient
    try { $a = $c.BeginConnect($ip, $port, $null, $null); if (-not $a.AsyncWaitHandle.WaitOne($ms)) { return $false }; $c.EndConnect($a); $true } catch { $false } finally { $c.Close() }
  }
  $so = New-PSSessionOption -OpenTimeout ([int]$cfg.OpenMs) -OperationTimeout ([int]$cfg.OperationMs) -CancelTimeout 5000
  $notes = New-Object Collections.ArrayList
  function Invoke-Many($computers, $sb, $argList, [int]$openMs = 0) {
    $res = @{}; $fail = @{}
    $computers = @($computers | Where-Object { $_ } | Select-Object -Unique)
    if (-not $computers.Count) { return @{ Res = $res; Fail = $fail } }
    $o2 = if ($openMs) { New-PSSessionOption -OpenTimeout $openMs -OperationTimeout ([int]$cfg.OperationMs) -CancelTimeout 5000 } else { $so }
    $ev = $null
    $out = @(Invoke-Command -ComputerName $computers -ScriptBlock $sb -ArgumentList $argList -SessionOption $o2 -ThrottleLimit 24 -ErrorAction SilentlyContinue -ErrorVariable ev)
    foreach ($o in $out) { if ($o -and $o.PSComputerName) { $res[(Short $o.PSComputerName)] = $o } }
    foreach ($e in @($ev)) {
      $t = [string]$e.TargetObject; if (-not $t) { $t = [string]$e.CategoryInfo.TargetName }; if (-not $t) { continue }
      $why = if ($e.FullyQualifiedErrorId -match 'AccessDenied') { 'denied' } else { (([string]$e.Exception.Message) -split "`n")[0].Trim() }
      if (-not $res.ContainsKey((Short $t))) { $fail[(Short $t)] = $why }
    }
    @{ Res = $res; Fail = $fail }
  }
  function Merge($list, $r, $names) {
    @(foreach ($k in $names.Keys) {
      $o = $r.Res[$k]
      if ($o) { foreach ($p in 'Name', 'Reachable', 'Error') { $o | Add-Member -NotePropertyName $p -NotePropertyValue $(switch ($p) { 'Name' { $k } 'Reachable' { $true } default { $null } }) -Force }; $o }
      else { [pscustomobject]@{ Name = $k; Fqdn = $names[$k]; Reachable = $false; Error = $(if ($r.Fail[$k]) { $r.Fail[$k] } else { 'unreachable' }) } }
    })
  }

  # ---- what every server tells about itself: memory, disks, uptime, stuck and failed services, restart pending,
  # errors of the last day, the clock against the PDC emulator, the secure channel, APIPA addresses
  $basics = @'
function Iso($d) { if ($d) { ([datetime]$d).ToString('yyyy-MM-ddTHH:mm:ss') } else { $null } }
function Get-OtrBasics([string]$pdc, [bool]$isDc) {
  $ErrorActionPreference = 'SilentlyContinue'
  $os = Get-CimInstance Win32_OperatingSystem
  $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Where-Object { $_.Size } | ForEach-Object {
    [pscustomobject]@{ Drive = "$($_.DeviceID)"; FreeGB = [math]::Round($_.FreeSpace / 1GB, 1); SizeGB = [math]::Round($_.Size / 1GB, 1) } })
  $all = @(Get-CimInstance Win32_Service)
  $stuck = @($all | Where-Object { "$($_.State)" -match 'Pending' } | ForEach-Object { [pscustomobject]@{ Name = $_.Name; State = ("$($_.State)" -replace ' ', ''); Display = "$($_.DisplayName)" } })
  # automatic services that are stopped and did not stop by themselves: not delayed, not started by a trigger,
  # an exit code other than 0 (done) and 1077 (never started since the boot)
  $failed = @($all | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -eq 'Stopped' -and -not $_.DelayedAutoStart -and $_.ExitCode -notin 0, 1077 -and
    -not (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($_.Name)\TriggerInfo") } | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Display = "$($_.DisplayName)"; Exit = [int]$_.ExitCode } })
  $reboot = @()
  if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reboot += 'servicing' }
  if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reboot += 'updates' }
  $a = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName; $b = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
  if ($a -and $b -and $a -ne $b) { $reboot += 'rename' }
  $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddHours(-24) } -MaxEvents 400)
  $top = @($ev | Group-Object { "$($_.ProviderName)|$($_.Id)" } | Sort-Object Count -Descending | Select-Object -First 4 | ForEach-Object {
    $e = $_.Group[0]; $m = ("$($e.Message)" -split "`r?`n")[0]; if ($m.Length -gt 220) { $m = $m.Substring(0, 220) }
    [pscustomobject]@{ Source = "$($e.ProviderName)"; Id = [int]$e.Id; Count = $_.Count; Level = [int]$e.Level; Last = Iso $e.TimeCreated; Text = $m.Trim() } })
  # The clock: its source, and its offset from the PDC emulator, asked over SNTP from an ephemeral port. Not with
  # "w32tm /stripchart": on a server whose time service holds port 123 it fails (0x80072733), and its output is in the
  # language of Windows. Offset = ((T2 - T1) + (T3 - T4)) / 2 with the receive and transmit times of the answer.
  $src = ("$(& w32tm.exe /query /source 2>$null)").Trim()
  $skew = $null; $skewErr = $null
  if ($pdc -and ($pdc -split '\.')[0] -ine $env:COMPUTERNAME) {
    $u = New-Object Net.Sockets.UdpClient; $u.Client.ReceiveTimeout = 3000
    try {
      $req = New-Object byte[] 48; $req[0] = 0x1B
      $u.Connect($pdc, 123); $t1 = [DateTime]::UtcNow; [void]$u.Send($req, 48)
      $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0); $nb = $u.Receive([ref]$ep); $t4 = [DateTime]::UtcNow
      $ts = { param($o) $s = ([uint64]$nb[$o] -shl 24) -bor ([uint64]$nb[$o + 1] -shl 16) -bor ([uint64]$nb[$o + 2] -shl 8) -bor [uint64]$nb[$o + 3]
        $f = ([uint64]$nb[$o + 4] -shl 24) -bor ([uint64]$nb[$o + 5] -shl 16) -bor ([uint64]$nb[$o + 6] -shl 8) -bor [uint64]$nb[$o + 7]
        ([datetime]::SpecifyKind([datetime]'1900-01-01', 'Utc')).AddSeconds($s).AddTicks([int64]($f * 10000000 / 4294967296)) }
      $skew = [math]::Round(((((& $ts 32) - $t1).TotalSeconds) + (((& $ts 40) - $t4).TotalSeconds)) / 2, 3)
    } catch { $skewErr = (("$($_.Exception.GetBaseException().Message)") -split "`n")[0] } finally { $u.Close() }
  }
  $sc = $null; if (-not $isDc) { try { $sc = [bool](Test-ComputerSecureChannel -ErrorAction Stop) } catch { $sc = $null } }
  $apipa = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '169.254.*' } | ForEach-Object {
    $ad = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex
    if ($ad -and "$($ad.Status)" -eq 'Up' -and "$($ad.InterfaceDescription)" -notmatch 'Remote NDIS|iDRAC|Failover Cluster') { "$($_.InterfaceAlias) $($_.IPAddress)" } })
  $fqdn = try { [Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName } catch { $env:COMPUTERNAME }
  [pscustomobject]@{ Fqdn = $fqdn; Os = "$($os.Caption)"; Build = "$($os.BuildNumber)"
    Ips = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | ForEach-Object { [pscustomobject]@{ Ip = $_.IPAddress; Skip = [bool]$_.SkipAsSource } })
    MemTotalMB = [int]($os.TotalVisibleMemorySize / 1024); MemFreeMB = [int]($os.FreePhysicalMemory / 1024); Boot = Iso $os.LastBootUpTime
    Disks = $disks; Stuck = $stuck; Failed = $failed; Reboot = $reboot; ErrorCount = $ev.Count; Critical = @($ev | Where-Object { $_.Level -eq 1 }).Count; Errors = $top
    TimeSource = $src; Skew = $skew; SkewError = $skewErr; SecureChannel = $sc; Apipa = $apipa }
}
'@
  # param() must come first in a script block: the functions of $basics after it
  $serverSb = [scriptblock]::Create('param($pdc)' + "`n" + $basics + "`n" + @'
Get-OtrBasics $pdc $false
'@)
  # ---- a Hyper-V host: its services, its VMs (checkpoints, stop action, vTPM, the cluster role), the guardian keys
  $hostSb = [scriptblock]::Create('param($pdc)' + "`n" + $basics + "`n" + @'
$r = Get-OtrBasics $pdc $false
$ErrorActionPreference = 'SilentlyContinue'
$svc = @(foreach ($n in 'vmms', 'VmHostAgent', 'ClusSvc', 'WinRM') { $w = Get-CimInstance Win32_Service -Filter "Name='$n'"
  if ($w) { [pscustomobject]@{ Name = $n; State = ("$($w.State)" -replace ' ', ''); StartMode = "$($w.StartMode)" } } else { [pscustomobject]@{ Name = $n; State = 'Missing'; StartMode = '' } } })
$cluster = ''; $oa = @{}; $rs = @{}; $gs = @{}
if ((Get-Service ClusSvc).Status -eq 'Running') {
  try {
    $cluster = [string](Get-Cluster -ErrorAction Stop).Name
    foreach ($x in @(Get-ClusterResource | Where-Object { "$($_.ResourceType)" -eq 'Virtual Machine' })) {
      $g = "$($x.OwnerGroup)"; $oa[$g] = [int]($x | Get-ClusterParameter -Name OfflineAction).Value; $rs[$g] = "$($x.State)" }
    foreach ($g in @(Get-ClusterGroup | Where-Object { "$($_.GroupType)" -eq 'VirtualMachine' })) { $gs["$($g.Name)"] = "$($g.State)" }
  } catch { }
}
$vms = @()
if (Get-Command Get-VM) {
  $vms = @(Get-VM | ForEach-Object {
    $tpm = $false; try { $tpm = [bool](Get-VMSecurity -VM $_ -ErrorAction Stop).TpmEnabled } catch { }
    $cp = @(Get-VMSnapshot -VM $_); $old = @($cp | Sort-Object CreationTime | Select-Object -First 1)
    [pscustomobject]@{ Name = $_.Name; State = "$($_.State)"; Status = "$($_.Status)"; Heartbeat = "$($_.Heartbeat)"; UptimeMin = [int]$_.Uptime.TotalMinutes; Clustered = [bool]$_.IsClustered; Tpm = $tpm
      MemoryMB = [int]($_.MemoryAssigned / 1MB); StartupMB = [int]($_.MemoryStartup / 1MB); Checkpoints = $cp.Count; CheckpointOldest = $(if ($old) { Iso $old[0].CreationTime })
      StopAction = "$($_.AutomaticStopAction)"; OfflineAction = $(if ($oa.ContainsKey($_.Name)) { $oa[$_.Name] }); ResourceState = $(if ($rs.ContainsKey($_.Name)) { $rs[$_.Name] } else { '' })
      GroupState = $(if ($gs.ContainsKey($_.Name)) { $gs[$_.Name] } else { '' }) } })
}
# the keys of the guardians (vTPM): a VM whose guardian is missing on a node cannot start there
$guard = @(Get-ChildItem 'Cert:\LocalMachine\Shielded VM Local Certificates' | Where-Object { $_.HasPrivateKey } | ForEach-Object {
  [pscustomobject]@{ Thumbprint = $_.Thumbprint; Guardian = $(if ("$($_.Subject)" -match '\(([^()]+)\)\s*$') { $Matches[1] } else { "$($_.Subject)" }) } })
$r | Add-Member -NotePropertyName Services -NotePropertyValue $svc
$r | Add-Member -NotePropertyName Cluster -NotePropertyValue $cluster
$r | Add-Member -NotePropertyName Vms -NotePropertyValue $vms
$r | Add-Member -NotePropertyName Guardians -NotePropertyValue $guard
$r
'@)
  # ---- a cluster, read once on one of its nodes: nodes, quorum and witness, groups and failed resources, CSVs, the
  # storage pool and its disks and repairs, the networks and those live migration may not use
  $clusterSb = {
    $ErrorActionPreference = 'SilentlyContinue'
    $c = Get-Cluster
    $nodes = @(Get-ClusterNode | ForEach-Object { [pscustomobject]@{ Name = "$($_.Name)"; State = "$($_.State)" } })
    $q = Get-ClusterQuorum; $qr = $null
    if ($q -and $q.QuorumResource) { $x = Get-ClusterResource -Name "$($q.QuorumResource)"; if ($x) {
      $path = ''; if ("$($x.ResourceType)" -eq 'File Share Witness') { $path = "$(($x | Get-ClusterParameter -Name SharePath).Value)" }
      $qr = [pscustomobject]@{ Name = "$($x.Name)"; Type = "$($x.ResourceType)"; State = "$($x.State)"; Path = $path } } }
    $groups = @(Get-ClusterGroup | ForEach-Object { [pscustomobject]@{ Name = "$($_.Name)"; State = "$($_.State)"; Owner = "$($_.OwnerNode)"; Type = "$($_.GroupType)" } })
    $failed = @(Get-ClusterResource | Where-Object { "$($_.State)" -eq 'Failed' } | ForEach-Object { [pscustomobject]@{ Name = "$($_.Name)"; Type = "$($_.ResourceType)"; Group = "$($_.OwnerGroup)" } })
    $csv = @(Get-ClusterSharedVolume | ForEach-Object { $i = @($_.SharedVolumeInfo)[0]
      [pscustomobject]@{ Name = "$($_.Name)"; State = "$($_.State)"; Owner = "$($_.OwnerNode)"; Path = "$($i.FriendlyVolumeName)"
        FreeGB = $(if ($i) { [math]::Round($i.Partition.FreeSpace / 1GB, 1) }); SizeGB = $(if ($i) { [math]::Round($i.Partition.Size / 1GB, 1) }) } })
    $nets = @(Get-ClusterNetwork | ForEach-Object { [pscustomobject]@{ Name = "$($_.Name)"; Id = "$($_.Id)"; Role = [int]$_.Role; State = "$($_.State)" } })
    $excl = @("$((Get-ClusterResourceType -Name 'Virtual Machine' | Get-ClusterParameter -Name MigrationExcludeNetworks).Value)".Split(';') | Where-Object { $_ })
    $pools = @(Get-StoragePool -IsPrimordial $false | ForEach-Object { [pscustomobject]@{ Name = "$($_.FriendlyName)"; Health = "$($_.HealthStatus)"; Oper = "$($_.OperationalStatus)"
      FreeGB = [math]::Round(($_.Size - $_.AllocatedSize) / 1GB, 0); SizeGB = [math]::Round($_.Size / 1GB, 0) } })
    $vds = @(); $pds = @(); $pdCount = 0; $jobs = @()
    if ($pools.Count) {
      $vds = @(Get-VirtualDisk | ForEach-Object { [pscustomobject]@{ Name = "$($_.FriendlyName)"; Health = "$($_.HealthStatus)"; Oper = "$($_.OperationalStatus)" } })
      $all = @(Get-StoragePool -IsPrimordial $false | Get-PhysicalDisk); $pdCount = $all.Count
      $pds = @($all | Where-Object { "$($_.HealthStatus)" -ne 'Healthy' -or "$($_.OperationalStatus)" -ne 'OK' } | ForEach-Object { [pscustomobject]@{ Name = "$($_.FriendlyName) $($_.SerialNumber)".Trim(); Health = "$($_.HealthStatus)"; Oper = "$($_.OperationalStatus)" } })
      $jobs = @(Get-StorageJob | Where-Object { "$($_.JobState)" -ne 'Completed' } | ForEach-Object { [pscustomobject]@{ Name = "$($_.Name)"; State = "$($_.JobState)"; Percent = [int]$_.PercentComplete } })
    }
    [pscustomobject]@{ Name = "$($c.Name)"; Node = $env:COMPUTERNAME; DrainOnShutdown = [int]$c.DrainOnShutdown; Nodes = $nodes; QuorumType = "$($q.QuorumType)"; Witness = $qr
      Groups = $groups; Failed = $failed; Csvs = $csv; Networks = $nets; MigrationExcluded = $excl; Pools = $pools; VirtualDisks = $vds; BadDisks = $pds; DiskCount = $pdCount; Jobs = $jobs }
  }
  # ---- a domain controller: its services with their start mode, SYSVOL and NETLOGON, the inbound replication
  # (repadmin's CSV: localised titles, the same columns), its DNS client order and its DNS zones
  $dcSb = [scriptblock]::Create('param($pdc)' + "`n" + $basics + "`n" + @'
$r = Get-OtrBasics $pdc $true
$ErrorActionPreference = 'SilentlyContinue'
$svc = @(foreach ($n in 'NTDS', 'DNS', 'kdc', 'Netlogon', 'ADWS', 'W32Time', 'DFSR') { $w = Get-CimInstance Win32_Service -Filter "Name='$n'"
  if ($w) { [pscustomobject]@{ Name = $n; State = ("$($w.State)" -replace ' ', ''); StartMode = "$($w.StartMode)" } } else { [pscustomobject]@{ Name = $n; State = 'Missing'; StartMode = '' } } })
$shares = @(Get-SmbShare | Where-Object { $_.Name -in 'SYSVOL', 'NETLOGON' } | ForEach-Object Name)
$repl = @(& repadmin.exe /showrepl /csv 2>$null | Select-Object -Skip 1 | ForEach-Object { $c = @(($_ | ConvertFrom-Csv -Header (0..10 | ForEach-Object { "c$_" })))[0]
  if ($c -and $c.c0 -eq 'showrepl_INFO') { [pscustomobject]@{ Context = "$($c.c3)"; Source = "$($c.c5)"; Failures = [int]"0$($c.c7)"; LastFailure = "$($c.c8)"; LastSuccess = "$($c.c9)"; Status = "$($c.c10)" } } })
$ad = Get-NetAdapter | Where-Object { "$($_.Status)" -eq 'Up' } | Where-Object { @(Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '169.254.*' }).Count } | Select-Object -First 1
$order = if ($ad) { @((Get-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4).ServerAddresses) } else { @() }
$zones = @(Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated } | ForEach-Object { [pscustomobject]@{ Name = "$($_.ZoneName)"; Reverse = [bool]$_.IsReverseLookupZone; Ad = [bool]$_.IsDsIntegrated; Type = "$($_.ZoneType)" } })
$r | Add-Member -NotePropertyName Services -NotePropertyValue $svc
$r | Add-Member -NotePropertyName Shares -NotePropertyValue $shares
$r | Add-Member -NotePropertyName Replication -NotePropertyValue $repl
$r | Add-Member -NotePropertyName DnsOrder -NotePropertyValue $order
$r | Add-Member -NotePropertyName Zones -NotePropertyValue $zones
$r
'@)
  # ---- the disks inside a running VM (when it answers WinRM by its name)
  $guestSb = { [pscustomobject]@{ Disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Where-Object { $_.Size } | ForEach-Object {
    [pscustomobject]@{ Drive = "$($_.DeviceID)"; FreeGB = [math]::Round($_.FreeSpace / 1GB, 1); SizeGB = [math]::Round($_.Size / 1GB, 1) } }) } }

  # ---- 1. the domain: its DCs, the owners of the FSMO roles (System.DirectoryServices: no module needed)
  $domain = $null; $dcNames = [ordered]@{}
  if ($cfg.Domain) {
    try {
      $d = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
      $fs = @{}; foreach ($k in 'PdcRoleOwner', 'RidRoleOwner', 'InfrastructureRoleOwner') { try { $fs[$k] = "$($d.$k.Name)" } catch { $fs[$k] = '' } }
      foreach ($k in 'SchemaRoleOwner', 'NamingRoleOwner') { try { $fs[$k] = "$($d.Forest.$k.Name)" } catch { $fs[$k] = '' } }
      $dcs = @(foreach ($x in $d.DomainControllers) { [pscustomobject]@{ Name = "$($x.Name)"; Ip = "$($x.IPAddress)"; Site = "$($x.SiteName)" } })
      $domain = [pscustomobject]@{ Name = "$($d.Name)"; Pdc = $fs.PdcRoleOwner; Rid = $fs.RidRoleOwner; Infra = $fs.InfrastructureRoleOwner; Schema = $fs.SchemaRoleOwner; Naming = $fs.NamingRoleOwner; Dcs = $dcs; Error = $null }
      foreach ($x in $dcs) { $dcNames[(Short $x.Name)] = $x.Name }
    } catch { $domain = [pscustomobject]@{ Name = ''; Pdc = ''; Dcs = @(); Error = $_.Exception.GetBaseException().Message } }
  }
  $pdc = if ($domain) { [string]$domain.Pdc } else { '' }
  # ---- 2. hosts, then the nodes their clusters name
  $hc = [ordered]@{}
  foreach ($h in @($cfg.Hosts)) { if ($h -and -not $hc.Contains((Short $h))) { $hc[(Short $h)] = $h } }
  $hr = Invoke-Many @($hc.Values) $hostSb @($pdc)
  if ($cfg.Cluster -ne 'no') {
    $more = @()
    foreach ($o in @($hr.Res.Values | Where-Object { $_.Cluster })) {
      $nn = Invoke-Command -ComputerName $o.Fqdn -SessionOption $so -ErrorAction SilentlyContinue -ScriptBlock { @(Get-ClusterNode | ForEach-Object { "$($_.Name)" }) }
      foreach ($n in @($nn)) { if ($n -and -not $hc.Contains((Short $n))) { $hc[(Short $n)] = $n; $more += $n } }
    }
    if ($more.Count) { $r2 = Invoke-Many $more $hostSb @($pdc); foreach ($k in $r2.Res.Keys) { $hr.Res[$k] = $r2.Res[$k] }; foreach ($k in $r2.Fail.Keys) { $hr.Fail[$k] = $r2.Fail[$k] } }
  }
  $hosts = @(Merge $null $hr $hc)
  # ---- 3. each cluster once, on its first node that answered
  $clusters = @()
  if ($cfg.Cluster -ne 'no') {
    foreach ($g in @($hosts | Where-Object { $_.Reachable -and $_.Cluster } | Group-Object Cluster)) {
      $node = $g.Group[0]
      try { $c = Invoke-Command -ComputerName $node.Fqdn -ScriptBlock $clusterSb -SessionOption $so -ErrorAction Stop; $c | Add-Member -NotePropertyName Reachable -NotePropertyValue $true -Force; $clusters += $c }
      catch { $clusters += [pscustomobject]@{ Name = $g.Name; Node = $node.Name; Reachable = $false; Error = (($_.Exception.Message) -split "`n")[0] } }
    }
  }
  # ---- 4. domain controllers, then the other servers (brokers, SQL replicas): what every server tells about itself
  $dr = Invoke-Many @($dcNames.Values) $dcSb @($pdc)
  $dcsOut = @(Merge $null $dr $dcNames)
  # the domain ports, from here: what the clients see
  foreach ($x in $dcsOut) {
    $ip = @($domain.Dcs | Where-Object { (Short $_.Name) -eq $x.Name } | ForEach-Object Ip) | Select-Object -First 1
    $ports = [ordered]@{}; foreach ($p in 389, 88, 53, 445, 3268, 9389) { $ports["$p"] = [bool](Test-Tcp $(if ($ip) { $ip } else { $x.Fqdn }) $p 2000) }
    $x | Add-Member -NotePropertyName Ports -NotePropertyValue ([pscustomobject]$ports) -Force; $x | Add-Member -NotePropertyName Ip -NotePropertyValue $ip -Force
  }
  # ---- 5. SQL AlwaysOn through its listener: replicas, databases; then each replica directly (logins, jobs, backups)
  $sql = $null
  if ($cfg.SqlListener) {
    function Invoke-Sql([string]$server, [string]$q, [bool]$listener = $false) {
      $cs = "Server=$server;Database=master;Integrated Security=SSPI;Encrypt=False;Connect Timeout=8;Application Name=OpenThinRDP Manager" + $(if ($listener) { ';MultiSubnetFailover=True' } else { '' })
      $cn = New-Object System.Data.SqlClient.SqlConnection $cs
      try { $cn.Open(); $cmd = $cn.CreateCommand(); $cmd.CommandText = $q; $cmd.CommandTimeout = 20
        $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd; $dt = New-Object System.Data.DataTable; [void]$da.Fill($dt)
        @(foreach ($row in $dt.Rows) { $o = [ordered]@{}; foreach ($col in $dt.Columns) { $v = $row[$col.ColumnName]; $o[$col.ColumnName] = $(if ($v -is [DBNull]) { $null } elseif ($v -is [datetime]) { Iso $v } else { $v }) }; [pscustomobject]$o }) }
      finally { $cn.Close() }
    }
    $sql = [pscustomobject]@{ Listener = [string]$cfg.SqlListener; Reachable = $false; Primary = ''; Error = $null; Replicas = @(); Databases = @(); Nodes = @() }
    try {
      $sql.Primary = [string](@(Invoke-Sql $cfg.SqlListener 'SELECT @@SERVERNAME AS N' $true)[0].N); $sql.Reachable = $true
      $sql.Replicas = @(Invoke-Sql $cfg.SqlListener "SELECT ag.name AS Ag, ar.replica_server_name AS Replica, ar.availability_mode_desc AS Mode, ars.role_desc AS Role, ars.connected_state_desc AS Connected, ars.synchronization_health_desc AS Health FROM sys.availability_groups ag JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id" $true)
      $sql.Databases = @(Invoke-Sql $cfg.SqlListener "SELECT ag.name AS Ag, adc.database_name AS Db, ar.replica_server_name AS Replica, ar.availability_mode_desc AS Mode, drs.synchronization_state_desc AS Sync, CAST(drs.is_suspended AS int) AS Suspended, drs.suspend_reason_desc AS Reason FROM sys.dm_hadr_database_replica_states drs JOIN sys.availability_databases_cluster adc ON drs.group_database_id = adc.group_database_id JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id JOIN sys.availability_groups ag ON ag.group_id = ar.group_id" $true)
    } catch { $sql.Error = $_.Exception.GetBaseException().Message; $sql.Reachable = Test-Tcp (("$($cfg.SqlListener)" -split ',')[0]) $(if ("$($cfg.SqlListener)" -match ',(\d+)$') { [int]$Matches[1] } else { 1433 }) 3000 }
    $sql.Nodes = @(foreach ($rep in @($sql.Replicas | ForEach-Object Replica | Select-Object -Unique)) {
      $n = [pscustomobject]@{ Replica = [string]$rep; Server = ("$rep" -split '\\')[0]; Instance = $(if ("$rep" -match '\\(.+)$') { $Matches[1] } else { '' }); Reachable = $false; Error = $null
        Logins = @(); Jobs = @(); FailedJobs = @(); IntegratedOnly = $null; LastFull = @(); Services = @() }
      try {
        $n.Logins = @(Invoke-Sql $rep "SELECT name AS Name, CAST(is_disabled AS int) AS Disabled, type AS Type FROM sys.server_principals WHERE type IN ('S','U','G') AND name NOT LIKE '##%' AND name NOT LIKE 'NT SERVICE\%' AND name NOT LIKE 'NT AUTHORITY\%' AND name NOT LIKE 'BUILTIN\%'")
        $n.Jobs = @(Invoke-Sql $rep "SELECT name AS Name FROM msdb.dbo.sysjobs WHERE name <> 'syspolicy_purge_history'" | ForEach-Object { [string]$_.Name })
        $n.FailedJobs = @(Invoke-Sql $rep "SELECT DISTINCT j.name AS Name FROM msdb.dbo.sysjobs j JOIN msdb.dbo.sysjobhistory h ON h.job_id = j.job_id AND h.step_id = 0 WHERE h.run_status = 0 AND h.run_date >= CONVERT(int, CONVERT(varchar(8), DATEADD(day, -$([int]$cfg.JobDays), GETDATE()), 112))" | ForEach-Object { [string]$_.Name })
        $n.IntegratedOnly = [int](@(Invoke-Sql $rep "SELECT CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS int) AS V")[0].V)
        $n.LastFull = @(Invoke-Sql $rep "SELECT database_name AS Db, MAX(backup_finish_date) AS Last FROM msdb.dbo.backupset WHERE type = 'D' GROUP BY database_name")
        $n.Reachable = $true
      } catch { $n.Error = $_.Exception.GetBaseException().Message }
      $n })
    # the services of each replica (instance name: MSSQLSERVER, or MSSQL$NAME and SQLAgent$NAME)
    $svcSb = { param($inst)
      foreach ($n in $(if ($inst) { "MSSQL`$$inst", "SQLAgent`$$inst" } else { 'MSSQLSERVER', 'SQLSERVERAGENT' }) + 'ClusSvc') {
        $w = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
        [pscustomobject]@{ Name = $n; State = $(if ($w) { "$($w.State)" -replace ' ', '' } else { 'Missing' }); StartMode = $(if ($w) { "$($w.StartMode)" } else { '' }) } } }
    foreach ($n in $sql.Nodes) {
      try { $n.Services = @(Invoke-Command -ComputerName $n.Server -ScriptBlock $svcSb -ArgumentList $n.Instance -SessionOption $so -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = $_.Name; State = $_.State; StartMode = $_.StartMode } }) } catch { }
    }
  }
  # ---- 6. the other servers: brokers and SQL replicas (those that are not a host or a DC already)
  $sv = [ordered]@{}
  foreach ($n in @($cfg.Brokers) + @($(if ($sql) { $sql.Nodes | ForEach-Object Server }))) { $k = Short $n; if ($n -and -not $sv.Contains($k) -and -not $hc.Contains($k) -and -not $dcNames.Contains($k)) { $sv[$k] = $n } }
  $sr = Invoke-Many @($sv.Values) $serverSb @($pdc)
  $servers = @(Merge $null $sr $sv)
  # ---- 7. DNS: the servers of the settings and the DCs answer; the names of the servers resolve to one address each
  # and back; the time it takes (the system resolver, as the programs use it)
  $dnsServers = @(@($cfg.DnsServers) + @($domain.Dcs | ForEach-Object { $_.Ip }) | Where-Object { $_ } | Select-Object -Unique)
  $zone = if ($domain -and $domain.Name) { $domain.Name } else { '' }
  $dnsOut = @(foreach ($s in $dnsServers) {
    $sw = [Diagnostics.Stopwatch]::StartNew(); $ok = $false; $err = $null
    try { if ($zone) { [void](Resolve-DnsName -Name $zone -Type SOA -Server $s -DnsOnly -QuickTimeout -ErrorAction Stop) } else { $ok = Test-Tcp $s 53 2000 }; if ($zone) { $ok = $true } } catch { $err = (($_.Exception.Message) -split "`n")[0] }
    [pscustomobject]@{ Server = $s; Ok = $ok; Ms = [int]$sw.ElapsedMilliseconds; Error = $err } })
  $names = @()
  $all = @(@($hosts | ForEach-Object { @{ N = $_.Fqdn; K = 'host'; Own = @($_.Ips | Where-Object { -not $_.Skip } | ForEach-Object Ip) } }) + @($dcsOut | ForEach-Object { @{ N = $_.Fqdn; K = 'dc'; Own = @($_.Ips | Where-Object { -not $_.Skip } | ForEach-Object Ip) } }) +
    @($servers | ForEach-Object { @{ N = $_.Fqdn; K = 'server'; Own = @($_.Ips | Where-Object { -not $_.Skip } | ForEach-Object Ip) } }))
  foreach ($x in $all) {
    if (-not $x.N) { continue }
    $sw = [Diagnostics.Stopwatch]::StartNew(); $ips = @()
    try { $ips = @([Net.Dns]::GetHostAddresses($x.N) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString }) } catch { }
    $fwd = [int]$sw.ElapsedMilliseconds
    $rev = @(foreach ($ip in $ips) { $sw.Restart(); $h = try { [Net.Dns]::GetHostEntry($ip).HostName } catch { $null }; [pscustomobject]@{ Ip = $ip; Name = $h; Ms = [int]$sw.ElapsedMilliseconds } })
    $names += [pscustomobject]@{ Name = $x.N; Kind = $x.K; Ips = $ips; Ms = $fwd; Reverse = $rev; Own = @($x.Own) }
  }
  foreach ($bn in @($cfg.BrokerName)) { if ($bn) { $ips = @(); try { $ips = @([Net.Dns]::GetHostAddresses($bn) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString }) } catch { }
    $names += [pscustomobject]@{ Name = $bn; Kind = 'shared'; Ips = $ips; Ms = 0; Reverse = @(); Own = @() } } }
  # ---- 8. the devices (and the host of a file share witness), from here
  $devs = @($cfg.Devices)
  foreach ($c in @($clusters | Where-Object { $_.Witness -and $_.Witness.Path })) {
    $wh = ("$($c.Witness.Path)" -replace '^\\\\', '' -split '\\')[0]
    if (-not @($devs | Where-Object { (Short $_.Address) -eq (Short $wh) -or (Short $_.Name) -eq (Short $wh) }).Count) { $devs += [pscustomobject]@{ Name = (Short $wh).ToLower(); Address = $wh; Ports = @(445); Share = ''; Mac = ''; Auto = $true } }
  }
  $ping = New-Object Net.NetworkInformation.Ping
  $devOut = @(foreach ($d in $devs) {
    $p = $null; $ms = $null; try { $rp = $ping.Send([string]$d.Address, 1500); $p = ($rp.Status -eq 'Success'); if ($p) { $ms = [int]$rp.RoundtripTime } } catch { $p = $false }
    $ports = @(foreach ($n in @($d.Ports)) { [pscustomobject]@{ Port = [int]$n; Open = [bool](Test-Tcp ([string]$d.Address) ([int]$n) 2500) } })
    $share = $null; if ($d.Share) { $share = [OtrHealthNet]::PathExists([string]$d.Share, 6000) }
    [pscustomobject]@{ Name = [string]$d.Name; Address = [string]$d.Address; Ping = $p; Ms = $ms; Ports = $ports; Share = [string]$d.Share; ShareOk = $share; Mac = [string]$d.Mac; Auto = [bool]($d.PSObject.Properties['Auto'] -and $d.Auto) } })
  # ---- 9. the backup log
  $backup = $null
  if ($cfg.BackupPath) {
    $backup = [pscustomobject]@{ Path = [string]$cfg.BackupPath; Text = [string]$cfg.BackupText; File = $null; Time = $null; Matched = $false; Error = $null }
    try { $r = [OtrHealthNet]::Newest([string]$cfg.BackupPath, [string]$cfg.BackupText, 15000); if ($r) { $backup.File = $r[0]; $backup.Time = $r[1]; $backup.Matched = ($r[2] -eq '1') } }
    catch { $backup.Error = $_.Exception.GetBaseException().Message }
  }
  # ---- 10. inside the running VMs that answer by their name: their disks (none answering is normal: desktops,
  # Linux, another domain)
  $guests = @()
  if ($cfg.Guests) {
    $want = @($hosts | Where-Object Reachable | ForEach-Object { @($_.Vms | Where-Object { $_.State -eq 'Running' -and "$($_.Heartbeat)" -like 'Ok*' -and $_.Name -notmatch '\s' } | ForEach-Object Name) } | Select-Object -Unique | Select-Object -First 120)
    $gr = Invoke-Many $want $guestSb @() 4000
    $guests = @(foreach ($k in $gr.Res.Keys) { [pscustomobject]@{ Vm = $k; Disks = @(@($gr.Res[$k].Disks) | ForEach-Object { [pscustomobject]@{ Drive = $_.Drive; FreeGB = $_.FreeGB; SizeGB = $_.SizeGB } }) } })
  }
  [pscustomobject]@{ Taken = Iso (Get-Date); Domain = $domain; Hosts = $hosts; Clusters = $clusters; Dcs = $dcsOut; Servers = $servers; Sql = $sql; Dns = [pscustomobject]@{ Servers = $dnsOut; Names = $names }
    Devices = $devOut; Backup = $backup; Guests = $guests; Notes = @($notes) }
}

# the input of the probe: the settings, and what the Desktops page already found (its hosts and brokers)
function Get-HealthProbeConfig($settings, $vdiModel) {
  $hosts = @(Split-List $settings.Hosts)
  $brokers = @()
  if ($vdiModel) {
    $hosts += @($vdiModel.Hosts | Where-Object { $_ -and $_.Fqdn } | ForEach-Object Fqdn)
    $brokers = @($vdiModel.Brokers | Where-Object { $_ -and $_.Fqdn } | ForEach-Object Fqdn)
  }
  $vs = Get-VdiSettings
  $hosts += @(Split-List $vs.Hosts)
  @{ Hosts = @($hosts | Where-Object { $_ } | Sort-Object -Unique); Brokers = @($brokers | Sort-Object -Unique); DnsServers = @(Split-List $settings.DnsServers)
     SqlListener = "$($settings.SqlListener)".Trim(); Devices = @(Get-HealthDevices $settings); BackupPath = "$($settings.BackupPath)".Trim(); BackupText = "$($settings.BackupText)".Trim()
     BrokerName = @(Split-List $settings.BrokerName); Cluster = [string]$settings.Cluster; Domain = $true; Guests = $true; OpenMs = 8000; OperationMs = 90000; JobDays = $script:HealthLimits.JobDays }
}

# ---------------------------------------------------------------------------------------------
# The model: the tree of the page. A node: Id, Kind, Name, Parent, Status (error, warn, info, ok, off), Short (a few
# words for the tree), Facts (label, value), Checks, Actions (the kinds of action it offers), Data (what the probe
# read), Desktop (the row of the Desktops page, for a personal desktop). A check: Kind, Title, Text (what is wrong, with
# its numbers), Why (what it means, in plain words), Fix (an action kind, or $null), FixArg, Source (health, vdi).
# ---------------------------------------------------------------------------------------------
$script:HealthOrder = @{ error = 0; warn = 1; info = 2; ok = 3; off = 4 }
function Get-TextIf([string]$key) { if ($script:Text.ContainsKey($key)) { Get-Text $key @args } else { '' } }
function Format-HcSize($gb) {
  if ($null -eq $gb) { return '?' }
  $g = [double]$gb
  if ($g -ge 1024) { return Get-Text 'HcTB' ([math]::Round($g / 1024, 1).ToString([Globalization.CultureInfo]::CurrentCulture)) }
  Get-Text 'HcGB' ([math]::Round($g, $(if ($g -lt 10) { 1 } else { 0 })).ToString([Globalization.CultureInfo]::CurrentCulture))
}
function New-HcNode($m, [string]$id, [string]$kind, [string]$name, [string]$parent) {
  $n = [pscustomobject]@{ Id = $id; Kind = $kind; Name = $name; Parent = $parent; Status = 'ok'; Own = 'ok'; Short = ''; Facts = New-Object Collections.ArrayList
    Checks = New-Object Collections.ArrayList; Actions = New-Object Collections.ArrayList; Children = New-Object Collections.ArrayList; Data = $null; Desktop = $null; Fqdn = ''; Problems = 0 }
  [void]$m.Nodes.Add($n); $m.Index[$id] = $n
  if ($parent -and $m.Index.ContainsKey($parent)) { [void]$m.Index[$parent].Children.Add($id) }
  $n
}
function Add-HcFact($n, [string]$key, $value) { if ($null -ne $value -and "$value" -ne '') { [void]$n.Facts.Add([pscustomobject]@{ Label = (Get-Text $key); Value = [string]$value }) } }
# a check: HcT_<id> = its title, HcX_<id> = what (with the values of $a), HcW_<id> = what it means
function Add-HcCheck($n, [string]$kind, [string]$id, $a = @(), $fix = $null, $fixArg = $null, [string]$why = $null) {
  $a = @($a)
  $c = [pscustomobject]@{ Kind = $kind; Id = $id; Title = (Get-TextIf "HcT_$id" @a); Text = (Get-TextIf "HcX_$id" @a); Why = $(if ($why) { $why } else { Get-TextIf "HcW_$id" @a })
    Fix = $fix; FixArg = $fixArg; Source = 'health'; Node = $n.Id }
  if (-not $c.Title) { $c.Title = $id }
  [void]$n.Checks.Add($c); $c
}
function Add-HcAction($n, [string]$kind) { if (-not $n.Actions.Contains($kind)) { [void]$n.Actions.Add($kind) } }
# the checks errors first, then warnings, notes and the rest, each in the order they were found (Sort-Object of
# Windows PowerShell does not keep the order of equal items)
function Get-HcByKind($checks) { $c = @($checks | Where-Object { $_ }); @($c | Where-Object Kind -eq 'error') + @($c | Where-Object Kind -eq 'warn') + @($c | Where-Object Kind -eq 'info') + @($c | Where-Object { $_.Kind -notin 'error', 'warn', 'info' }) }
function Get-HcWorst($kinds) { $w = 'ok'; foreach ($k in @($kinds)) { if ($k -and $script:HealthOrder[$k] -lt $script:HealthOrder[$w]) { $w = $k } }; $w }
function Get-HcShort([string]$n) { if ($n -match '^\d{1,3}(\.\d{1,3}){3}$') { return $n }; ("$n" -split '\.')[0].ToUpper() }

# what every server tells about itself (memory, disks, clock, services...): the same checks on hosts, DCs, brokers,
# SQL replicas. $role: host, dc, server (and $pdc: the PDC emulator, $dcs: the short names of the DCs).
function Add-HcBasics($n, $o, [string]$role, [datetime]$now, [string]$pdc, $dcs) {
  $L = $script:HealthLimits
  $short = Get-HcShort $o.Name
  if ($o.Boot) { $b = ConvertFrom-VdiTime $o.Boot; if ($b) { Add-HcFact $n 'HcFUptime' (Get-Text 'HcUptimeSince' (Format-VdiAge $b $now) (Format-VdiClock $b $now)) } }
  if ($o.Os) { Add-HcFact $n 'HcFOs' "$($o.Os) ($($o.Build))" }
  if ([int]$o.MemTotalMB -gt 0) {
    $pct = [int][math]::Round(100 * [double]$o.MemFreeMB / [double]$o.MemTotalMB)
    $free = Format-HcSize ([double]$o.MemFreeMB / 1024); $tot = Format-HcSize ([double]$o.MemTotalMB / 1024)
    Add-HcFact $n 'HcFMemory' (Get-Text 'HcMemFree' $free $tot $pct)
    # SQL Server keeps the memory it may take (max server memory): little free memory on a replica is normal
    if ($role -eq 'sql') { }
    elseif ($pct -lt $L.MemPct) { [void](Add-HcCheck $n 'error' 'Mem' @($pct, $free, $tot) -why (Get-Text "HcW_Mem_$role")) }
    elseif ($pct -lt $L.MemWarnPct) { [void](Add-HcCheck $n 'warn' 'Mem' @($pct, $free, $tot) -why (Get-Text "HcW_Mem_$role")) }
  }
  foreach ($d in @($o.Disks | Where-Object { $_ -and [double]$_.SizeGB -gt 0 })) {
    $pct = [int][math]::Round(100 * [double]$d.FreeGB / [double]$d.SizeGB)
    Add-HcFact $n 'HcFDisk' (Get-Text 'HcDiskFree' $d.Drive (Format-HcSize $d.FreeGB) (Format-HcSize $d.SizeGB) $pct)
    if (([double]$d.FreeGB -lt $L.DiskGB -and [double]$d.SizeGB -ge 4 * $L.DiskGB) -or $pct -lt $L.DiskPct) { [void](Add-HcCheck $n 'error' 'Disk' @($d.Drive, (Format-HcSize $d.FreeGB), (Format-HcSize $d.SizeGB), $pct)) }
    elseif ($pct -lt $L.DiskWarnPct -and [double]$d.FreeGB -lt $L.DiskWarnGB) { [void](Add-HcCheck $n 'warn' 'Disk' @($d.Drive, (Format-HcSize $d.FreeGB), (Format-HcSize $d.SizeGB), $pct)) }
  }
  # services stuck half-way: which ones may be ended without asking is up to the action plan
  foreach ($s in @($o.Stuck | Where-Object { $_ })) { [void](Add-HcCheck $n $(if ($s.Name -in 'VmHostAgent', 'vmms', 'Tssdis', 'NTDS', 'DNS', 'kdc', 'Netlogon', 'ClusSvc' -or $s.Name -like 'MSSQL*') { 'error' } else { 'warn' }) 'Stuck' @($s.Name, $s.State, $s.Display) 'ServiceUnstick' $s.Name) }
  $failed = @($o.Failed | Where-Object { $_ })
  if ($failed.Count) { [void](Add-HcCheck $n 'warn' 'Failed' @((($failed | Select-Object -First 6 | ForEach-Object { "$($_.Display) ($($_.Name))" }) -join ', ')) 'ServiceStart' $failed[0].Name) }
  if (@($o.Reboot).Count) { [void](Add-HcCheck $n 'warn' 'Reboot' @(((@($o.Reboot) | ForEach-Object { Get-Text "HcReboot_$_" }) -join ', ')) -why (Get-Text "HcW_Reboot_$role")) }
  if ([int]$o.Critical -gt 0) { [void](Add-HcCheck $n 'warn' 'Critical' @([int]$o.Critical, ((@($o.Errors | Where-Object { [int]$_.Level -eq 1 } | Select-Object -First 2 | ForEach-Object { "$($_.Source) $($_.Id)" })) -join ', '))) }
  if ([int]$o.ErrorCount -gt 0) {
    $top = @($o.Errors | Select-Object -First 3 | ForEach-Object { "$($_.Source) $($_.Id) x$($_.Count)" }) -join ', '
    Add-HcFact $n 'HcFErrors' (Get-Text 'HcErrorsDay' $o.ErrorCount $top)
    [void](Add-HcCheck $n 'info' 'Errors' @($o.ErrorCount, $top, ((@($o.Errors | Select-Object -First 1 | ForEach-Object Text)) -join '')))
  }
  # the clock: against the PDC emulator, and where it takes its time from
  if ($null -ne $o.Skew -and "$($o.Skew)" -ne '') {
    $sk = [math]::Abs([double]$o.Skew); $sks = [math]::Round($sk, $(if ($sk -lt 10) { 1 } else { 0 })).ToString([Globalization.CultureInfo]::CurrentCulture)
    Add-HcFact $n 'HcFClock' (Get-Text 'HcClockSkew' $sks (Get-HcShort $pdc) $o.TimeSource)
    if ($sk -gt $L.SkewMax) { [void](Add-HcCheck $n 'error' 'Skew' @($sks, (Get-HcShort $pdc)) 'TimeSync') }
    elseif ($sk -gt $L.SkewWarn) { [void](Add-HcCheck $n 'warn' 'Skew' @($sks, (Get-HcShort $pdc)) 'TimeSync') }
  } elseif ($o.SkewError) { [void](Add-HcCheck $n 'warn' 'SkewErr' @((Get-HcShort $pdc), "$($o.SkewError)".Trim())) }
  elseif ($o.TimeSource) { Add-HcFact $n 'HcFClock' (Get-Text 'HcClockSource' $o.TimeSource) }
  $src = "$($o.TimeSource)" -replace ',0x[0-9A-Fa-f]+$', ''
  if ($src -and $pdc) {
    $isPdc = $short -eq (Get-HcShort $pdc)
    $fromDc = @(@($dcs) | Where-Object { $src -match "(^|\b)$([regex]::Escape($_))(\.|\b|$)" }).Count -gt 0
    $local = $src -match 'Local CMOS Clock|Free-running System Clock|Clock CMOS locale|Orologio di sistema'
    if ($isPdc) { if ($local) { [void](Add-HcCheck $n 'warn' 'PdcTime' @($src)) } }
    elseif (-not $fromDc -and $src -notmatch 'VM IC Time') { [void](Add-HcCheck $n 'warn' 'TimeSource' @($src) 'TimeDomain') }
  }
  if ($o.SecureChannel -eq $false) { [void](Add-HcCheck $n 'error' 'Trust' @() 'NetlogonRestart') }
  foreach ($x in @($o.Apipa | Where-Object { $_ })) { [void](Add-HcCheck $n 'warn' 'Apipa' @($x)) }
  $ips = @($o.Ips | Where-Object { $_ -and -not $_.Skip } | ForEach-Object Ip)
  if ($ips.Count) { Add-HcFact $n 'HcFAddress' ($ips -join ', ') }
}
# the state of the services a role needs: stopped = start it (safe unless disabled), stuck = end it
function Add-HcServices($n, $services, $need, [hashtable]$whyKeys) {
  foreach ($s in @($services | Where-Object { $_ -and $need -contains $_.Name })) {
    $why = if ($whyKeys -and $whyKeys.ContainsKey($s.Name)) { Get-Text $whyKeys[$s.Name] } else { $null }
    if ($s.State -eq 'Running') { continue }
    if ($s.State -eq 'Missing') { continue }
    if ($s.State -match 'Pending') { continue }   # the stuck services: Add-HcBasics
    $kind = 'error'
    if ($s.StartMode -eq 'Disabled') { [void](Add-HcCheck $n $kind 'SvcDisabled' @($s.Name) 'ServiceStart' $s.Name $why) }
    else { [void](Add-HcCheck $n $kind 'SvcStopped' @($s.Name, $s.State, $s.StartMode) 'ServiceStart' $s.Name $why) }
  }
}

# Everything the page shows. $raw = the probe (or the demo file), $vdi = the model of the Desktops page (or $null),
# $now = the time of the data.
function ConvertTo-HealthModel($raw, $vdi, [datetime]$now, $settings = $null) {
  if (-not $settings) { $settings = Get-HealthDefaults }
  $L = $script:HealthLimits
  $m = [pscustomobject]@{ Nodes = New-Object Collections.ArrayList; Index = @{}; Taken = $now; Headline = ''; HeadlineKind = 'ok'; Problems = @(); Errors = 0; Warnings = 0; Access = 'ok'; Raw = $raw }
  if (-not $settings.Enabled) { $m.Access = 'off'; return $m }
  if (-not $raw) { $m.Access = 'nodata'; return $m }
  $domain = $raw.Domain
  $pdc = if ($domain) { [string]$domain.Pdc } else { '' }
  # the domain controllers by name and by address (a time source is named either way)
  $dcShort = @(@($raw.Dcs) | Where-Object { $_ } | ForEach-Object { $_.Name }) + @(@($domain.Dcs) | Where-Object { $_ -and $_.Ip } | ForEach-Object { $_.Ip })
  $hostsAll = @($raw.Hosts | Where-Object { $_ })
  # Cluster = no in the settings: single hosts, whatever they say (their VMs judged as outside a cluster)
  $useCl = $settings.Cluster -ne 'no'
  # the rows of the Desktops page by VM: who uses it
  $desk = @{}; if ($vdi) { foreach ($r in @($vdi.Rows)) { if ($r -and $r.Vm) { $k = ([string]$r.Vm).ToUpper(); if (-not $desk.ContainsKey($k)) { $desk[$k] = @() }; $desk[$k] += $r } } }
  # the findings of the Desktops page on brokers and hosts: shown where they belong, never read twice
  $vf = if ($vdi -and $vdi.Access -notin 'off', 'nobroker') { @($vdi.Findings) } else { @() }
  $addVdi = { param($node, $where)
    foreach ($f in @($vf | Where-Object { $_.Where -eq $where -and $_.Kind -ne 'ok' })) {
      # the stop action of vTPM VMs is a check of the cluster here
      if ($f.Fix -eq 'HostOfflineAction' -and @($raw.Clusters).Count) { continue }
      $title = if ($f.Fix) { Get-TextIf "HcVdi_$($f.Fix)" } elseif ($node.Kind -eq 'rds') { Get-Text 'HcT_VdiName' $where } else { '' }; if (-not $title) { $title = Get-Text 'HcT_Vdi' }
      [void]$node.Checks.Add([pscustomobject]@{ Kind = $f.Kind; Id = 'Vdi'; Title = $title; Text = $f.Text; Why = (Get-Text 'HcW_Vdi'); Fix = $f.Fix; FixArg = $f.FixArg; Source = 'vdi'; Node = $node.Id; Where = $f.Where }) } }

  # ---- Hyper-V: a cluster with its nodes, or the single hosts
  $clusters = @($raw.Clusters | Where-Object { $_ })
  $clNode = @{}
  foreach ($c in $clusters) {
    $cn = New-HcNode $m "cluster:$($c.Name.ToUpper())" 'cluster' $c.Name ''
    $cn.Data = $c; $clNode[$c.Name.ToUpper()] = $cn
    if (-not $c.Reachable) { [void](Add-HcCheck $cn 'error' 'ClusterUnread' @($c.Node, $c.Error)); continue }
    $up = @($c.Nodes | Where-Object { $_.State -eq 'Up' }).Count
    Add-HcFact $cn 'HcFNodes' (Get-Text 'HcNodesUp' $up @($c.Nodes).Count)
    # quorum and witness
    $w = $c.Witness
    if ($w) {
      Add-HcFact $cn 'HcFWitness' (Get-Text 'HcWitnessIs' $(if ($w.Path) { $w.Path } else { $w.Name }) $w.State $w.Type)
      if ($w.State -ne 'Online') { [void](Add-HcCheck $cn 'error' 'Witness' @($(if ($w.Path) { $w.Path } else { $w.Name }), $w.State) 'WitnessOnline' $w.Name) }
    } elseif (@($c.Nodes).Count % 2 -eq 0) { [void](Add-HcCheck $cn 'warn' 'NoWitness' @(@($c.Nodes).Count)) }
    if ([int]$c.DrainOnShutdown -eq 0) { [void](Add-HcCheck $cn 'warn' 'Drain' @() 'ClusterDrainOnShutdown') }
    # groups and resources that failed (the roles of VMs: on the VM)
    foreach ($g in @($c.Groups | Where-Object { $_ -and $_.Type -ne 'VirtualMachine' })) {
      if ($g.State -eq 'Failed') { [void](Add-HcCheck $cn 'error' 'GroupFailed' @($g.Name, $g.Owner) 'ClusterGroupStart' $g.Name) }
      elseif ($g.State -eq 'PartialOnline') { [void](Add-HcCheck $cn 'warn' 'GroupPartial' @($g.Name, $g.Owner) 'ClusterGroupStart' $g.Name) }
    }
    $vmGroups = @($c.Groups | Where-Object { $_ -and $_.Type -eq 'VirtualMachine' } | ForEach-Object Name)
    foreach ($r in @($c.Failed | Where-Object { $_ -and $vmGroups -notcontains $_.Group })) { [void](Add-HcCheck $cn 'error' 'ResFailed' @($r.Name, $r.Type, $r.Group)) }
    # CSVs and storage
    foreach ($v in @($c.Csvs | Where-Object { $_ })) {
      if ($v.State -ne 'Online') { [void](Add-HcCheck $cn 'error' 'CsvState' @($v.Name, $v.State)) }
      if ($null -ne $v.SizeGB -and [double]$v.SizeGB -gt 0) {
        $pct = [int][math]::Round(100 * [double]$v.FreeGB / [double]$v.SizeGB)
        Add-HcFact $cn 'HcFCsv' (Get-Text 'HcCsvFree' $v.Name (Format-HcSize $v.FreeGB) (Format-HcSize $v.SizeGB) $pct $v.Owner)
        if ($pct -lt $L.DiskPct) { [void](Add-HcCheck $cn 'error' 'CsvFree' @($v.Name, (Format-HcSize $v.FreeGB), (Format-HcSize $v.SizeGB), $pct)) }
        elseif ($pct -lt $L.DiskWarnPct) { [void](Add-HcCheck $cn 'warn' 'CsvFree' @($v.Name, (Format-HcSize $v.FreeGB), (Format-HcSize $v.SizeGB), $pct)) }
      }
    }
    $jobs = @($c.Jobs | Where-Object { $_ })
    $paused = @($c.Nodes | Where-Object { $_.State -eq 'Paused' }).Count
    foreach ($p in @($c.Pools | Where-Object { $_ })) {
      Add-HcFact $cn 'HcFPool' (Get-Text 'HcPoolIs' $p.Name $p.Health (Format-HcSize $p.FreeGB) (Format-HcSize $p.SizeGB))
      if ($p.Health -ne 'Healthy') { [void](Add-HcCheck $cn $(if ($jobs.Count -or $paused) { 'warn' } else { 'error' }) 'Pool' @($p.Name, $p.Health, $p.Oper)) }
    }
    foreach ($v in @($c.VirtualDisks | Where-Object { $_ -and $_.Health -ne 'Healthy' })) { [void](Add-HcCheck $cn $(if ($jobs.Count -or $paused) { 'warn' } else { 'error' }) 'VDisk' @($v.Name, $v.Health, $v.Oper)) }
    $bad = @($c.BadDisks | Where-Object { $_ })
    if ($bad.Count) {
      $maint = @($bad | Where-Object { "$($_.Oper)" -match 'Maintenance' })
      if ($maint.Count -eq $bad.Count) { [void](Add-HcCheck $cn 'warn' 'DisksMaint' @($bad.Count)) }
      else { [void](Add-HcCheck $cn 'error' 'DisksBad' @($bad.Count, (($bad | Select-Object -First 4 | ForEach-Object { "$($_.Name) ($($_.Health), $($_.Oper))" }) -join '; '))) }
    } elseif ([int]$c.DiskCount -gt 0) { Add-HcFact $cn 'HcFDisks' (Get-Text 'HcDisksOk' $c.DiskCount) }
    if ($jobs.Count) {
      $susp = @($jobs | Where-Object { $_.State -eq 'Suspended' })
      [void](Add-HcCheck $cn $(if ($susp.Count) { 'warn' } else { 'info' }) $(if ($susp.Count) { 'JobsSuspended' } else { 'Jobs' }) @($jobs.Count, ((@($jobs | ForEach-Object { "$($_.Name) $($_.Percent) %" })) -join ', ')))
    }
    # networks, and those live migration may use
    $excl = @($c.MigrationExcluded)
    foreach ($x in @($c.Networks | Where-Object { $_ -and $_.State -ne 'Up' })) { [void](Add-HcCheck $cn 'warn' 'Network' @($x.Name, $x.State)) }
    $lm = @($c.Networks | Where-Object { $_ -and $_.State -eq 'Up' -and [int]$_.Role -in 1, 3 -and $excl -notcontains $_.Id } | ForEach-Object Name)
    if (@($c.Networks).Count) { if ($lm.Count) { Add-HcFact $cn 'HcFMigration' ($lm -join ', ') } else { [void](Add-HcCheck $cn 'error' 'Migration' @()) } }
  }
  $hostParent = @{}
  foreach ($h in $hostsAll) { $hostParent[$h.Name] = $(if ($h.Reachable -and $h.Cluster -and $clNode.ContainsKey(([string]$h.Cluster).ToUpper())) { $clNode[([string]$h.Cluster).ToUpper()].Id } else { 'hyperv' }) }
  if (@($hostParent.Values | Where-Object { $_ -eq 'hyperv' }).Count) { [void](New-HcNode $m 'hyperv' 'group' (Get-Text 'HcHyperV') '') }
  # the VM names seen on more than one host (replicas): their ids carry the host
  $dupe = @{}; foreach ($h in $hostsAll) { foreach ($v in @($h.Vms | Where-Object { $_ })) { $k = ([string]$v.Name).ToUpper(); $dupe[$k] = 1 + [int]$dupe[$k] } }
  $guest = @{}; foreach ($g in @($raw.Guests | Where-Object { $_ })) { $guest[([string]$g.Vm).ToUpper()] = $g }
  foreach ($h in $hostsAll) {
    $hn = New-HcNode $m "host:$($h.Name)" 'host' $h.Name $hostParent[$h.Name]
    $hn.Data = $h; $hn.Fqdn = [string]$h.Fqdn
    $cl = if ($h.Cluster) { $clusters | Where-Object { $_.Name -ieq $h.Cluster } | Select-Object -First 1 } else { $null }
    if (-not $h.Reachable) {
      [void](Add-HcCheck $hn 'error' $(if ($h.Error -eq 'denied') { 'Denied' } else { 'Unreach' }) @($h.Name, $h.Error))
      $cnode = if ($cl) { @($cl.Nodes | Where-Object { (Get-HcShort $_.Name) -eq $h.Name }) | Select-Object -First 1 }
      if ($cnode) { Add-HcFact $hn 'HcFNodeState' $cnode.State }
      & $addVdi $hn $h.Name
      continue
    }
    Add-HcBasics $hn $h 'host' $now $pdc $dcShort
    if ($settings.Cluster -eq 'yes' -and -not $h.Cluster) { [void](Add-HcCheck $hn 'warn' 'NoCluster' @($h.Name)) }
    # the services of Hyper-V; the RDVH agent only when the Desktops page does not watch this host already
    $vdiHost = $vdi -and @($vdi.Hosts | Where-Object { $_ -and $_.Name -eq $h.Name -and $_.Reachable }).Count
    $need = @('vmms'); if ($h.Cluster) { $need += 'ClusSvc' }
    if (-not $vdiHost -and @($h.Services | Where-Object { $_.Name -eq 'VmHostAgent' -and $_.State -ne 'Missing' }).Count) { $need += 'VmHostAgent' }
    Add-HcServices $hn $h.Services $need @{ vmms = 'HcW_Svc_vmms'; ClusSvc = 'HcW_Svc_ClusSvc'; VmHostAgent = 'HcW_Svc_VmHostAgent' }
    if ($vdiHost) { foreach ($c in @($hn.Checks | Where-Object { $_.Id -eq 'Stuck' -and $_.FixArg -in 'VmHostAgent', 'vmms' })) { $hn.Checks.Remove($c) } }
    # the node in its cluster
    if ($cl -and $cl.Reachable) {
      $cnode = @($cl.Nodes | Where-Object { (Get-HcShort $_.Name) -eq $h.Name }) | Select-Object -First 1
      if ($cnode) {
        Add-HcFact $hn 'HcFNodeState' $cnode.State
        if ($cnode.State -eq 'Paused') { [void](Add-HcCheck $hn 'warn' 'NodePaused' @($h.Name) 'HostResume') }
        elseif ($cnode.State -ne 'Up') { [void](Add-HcCheck $hn 'error' 'NodeDown' @($h.Name, $cnode.State)) }
        Add-HcAction $hn 'HostDrain'; Add-HcAction $hn 'HostResume'
      }
    }
    $vms = @($h.Vms | Where-Object { $_ })
    $run = @($vms | Where-Object { $_.State -eq 'Running' })
    Add-HcFact $hn 'HcFVms' (Get-Text 'HcVmsCount' $vms.Count $run.Count (Format-HcSize ((@($run | ForEach-Object { [double]$_.MemoryMB }) + 0 | Measure-Object -Sum).Sum / 1024)))
    & $addVdi $hn $h.Name
    foreach ($v in $vms) {
      $vk = ([string]$v.Name).ToUpper()
      $vid = if ([int]$dupe[$vk] -gt 1) { "vm:$vk@$($h.Name)" } else { "vm:$vk" }
      $vn = New-HcNode $m $vid 'vm' $v.Name $hn.Id
      $vn.Data = $v; $vn | Add-Member -NotePropertyName Host -NotePropertyValue $h.Name; $vn | Add-Member -NotePropertyName HostFqdn -NotePropertyValue $h.Fqdn
      $hb = [string]$v.Heartbeat
      $stText = Get-TextIf "HcVm_$($v.State)"; if (-not $stText) { $stText = $v.State }
      Add-HcFact $vn 'HcFVmState' $(if ($v.State -eq 'Running') { (@($stText, $(if ($hb) { Get-Text 'VdiInfoHeartbeat' $(if ($hb -like 'Ok*') { 'OK' } else { $hb }) }), $(if ([int]$v.UptimeMin) { Get-Text 'VdiInfoUptime' (Format-Minutes ([int]$v.UptimeMin)) })) | Where-Object { $_ }) -join "   $([char]0x00B7)   " } else { $stText })
      Add-HcFact $vn 'HcFHost' $h.Name
      if ([int]$v.MemoryMB -gt 0) { Add-HcFact $vn 'HcFMemory' (Format-HcSize ([double]$v.MemoryMB / 1024)) }
      $feat = @($(if ($v.Tpm) { 'vTPM' }), $(if ($v.Clustered) { Get-Text 'HcClustered' $(if ($v.ResourceState) { $v.ResourceState } else { '?' }) } else { Get-Text 'HcNotClustered' }))
      Add-HcFact $vn 'HcFVmRole' (($feat | Where-Object { $_ }) -join "   $([char]0x00B7)   ")
      if ($desk.ContainsKey($vk)) {
        $users = @($desk[$vk] | Where-Object { $_.User } | ForEach-Object User | Select-Object -Unique)
        $vn.Desktop = $desk[$vk][0]
        if ($users.Count) { Add-HcFact $vn 'HcFDesktopOf' ($users -join ', ') }
        Add-HcAction $vn 'OpenDesktops'
      }
      $vn.Short = $stText
      switch ([string]$v.State) {
        'Saved' { [void](Add-HcCheck $vn $(if ($v.Tpm) { 'error' } else { 'warn' }) $(if ($v.Tpm) { 'SavedTpm' } else { 'Saved' }) @($v.Name) 'VmStart') }
        'Paused' { [void](Add-HcCheck $vn 'error' 'Paused' @($v.Status) 'VmResume') }
        'Running' {
          if ($hb -match '^(LostCommunication|NoContact|Error)' -and [int]$v.UptimeMin -ge 5) { [void](Add-HcCheck $vn 'error' 'Hung' @($hb, (Format-Minutes ([int]$v.UptimeMin))) 'VmRestart') }
          if ($v.Clustered -and $v.ResourceState -and $v.ResourceState -ne 'Online') { [void](Add-HcCheck $vn 'warn' 'RoleOffline' @($v.ResourceState) 'VmRoleOnline') }
        }
        default { if ([string]$v.State -notin 'Off', 'Running') { [void](Add-HcCheck $vn 'warn' 'VmState' @($v.State, $v.Status)) } }
      }
      if ($v.Clustered -and $v.GroupState -eq 'Failed') { [void](Add-HcCheck $vn 'error' 'RoleFailed' @() 'VmStart') }
      if ($useCl -and $h.Cluster -and -not $v.Clustered) { [void](Add-HcCheck $vn 'info' 'NotClustered' @($h.Name)) }
      if ([int]$v.Checkpoints -gt 0) {
        $old = ConvertFrom-VdiTime $v.CheckpointOldest; $days = if ($old) { [int][math]::Floor(($now - $old).TotalDays) } else { 0 }
        Add-HcFact $vn 'HcFCheckpoints' (Get-Text 'HcCheckpointsIs' $v.Checkpoints $(if ($old) { Format-VdiClock $old $now } else { '?' }))
        if ($days -ge $L.CheckpointDays) { [void](Add-HcCheck $vn 'warn' 'Checkpoints' @($v.Checkpoints, $days) 'VmRemoveCheckpoints') }
      }
      # how the host stops it when it shuts down (a VM of the cluster is drained instead)
      if (-not $v.Clustered -or -not $useCl) {
        if ($v.StopAction -eq 'Save' -and $v.Tpm) { [void](Add-HcCheck $vn 'warn' 'StopSave' @() 'VmStopAction') }
        elseif ($v.StopAction -eq 'TurnOff') { [void](Add-HcCheck $vn 'warn' 'StopOff' @() 'VmStopAction') }
      }
      if ($guest.ContainsKey($vk)) {
        foreach ($d in @($guest[$vk].Disks | Where-Object { $_ -and [double]$_.SizeGB -gt 0 })) {
          $pct = [int][math]::Round(100 * [double]$d.FreeGB / [double]$d.SizeGB)
          Add-HcFact $vn 'HcFDiskInside' (Get-Text 'HcDiskFree' $d.Drive (Format-HcSize $d.FreeGB) (Format-HcSize $d.SizeGB) $pct)
          if (([double]$d.FreeGB -lt $L.DiskGB -and [double]$d.SizeGB -ge 4 * $L.DiskGB) -or $pct -lt $L.DiskPct) { [void](Add-HcCheck $vn 'error' 'GuestDisk' @($d.Drive, (Format-HcSize $d.FreeGB), (Format-HcSize $d.SizeGB), $pct)) }
          elseif ($pct -lt $L.DiskWarnPct -and [double]$d.FreeGB -lt $L.DiskWarnGB) { [void](Add-HcCheck $vn 'warn' 'GuestDisk' @($d.Drive, (Format-HcSize $d.FreeGB), (Format-HcSize $d.SizeGB), $pct)) }
        }
      }
      foreach ($k in 'VmStart', 'VmRestart', 'VmShutdown') { Add-HcAction $vn $k }
      if ($v.State -eq 'Paused') { Add-HcAction $vn 'VmResume' }
    }
  }
  # ---- what only the whole cluster can tell: vTPM VMs it would save, the guardian keys on every node, room for a failure
  foreach ($c in @($clusters | Where-Object Reachable)) {
    $cn = $clNode[$c.Name.ToUpper()]
    $members = @($hostsAll | Where-Object { $_.Reachable -and $_.Cluster -ieq $c.Name })
    $allVms = @($members | ForEach-Object { @($_.Vms | Where-Object { $_ }) })
    $savers = @($allVms | Where-Object { $_.Tpm -and $_.Clustered -and $null -ne $_.OfflineAction -and "$($_.OfflineAction)" -ne '' -and [int]$_.OfflineAction -eq 1 } | ForEach-Object Name | Sort-Object -Unique)
    if ($savers.Count) { [void](Add-HcCheck $cn 'warn' 'OfflineAction' @($savers.Count, (($savers | Select-Object -First 6) -join ', ')) 'ClusterOfflineAction' ($savers -join ',')) }
    if (@($allVms | Where-Object { $_.Tpm }).Count) {
      $byNode = @{}; foreach ($h in $members) { $byNode[$h.Name] = @($h.Guardians | Where-Object { $_ } | ForEach-Object Thumbprint) }
      $allG = @($members | ForEach-Object { @($_.Guardians | Where-Object { $_ }) })
      foreach ($h in $members) {
        $miss = @($allG | Where-Object { $byNode[$h.Name] -notcontains $_.Thumbprint } | ForEach-Object Guardian | Select-Object -Unique)
        if ($miss.Count) { [void](Add-HcCheck $m.Index["host:$($h.Name)"] 'error' 'Guardian' @(($miss -join ', '))) }
      }
    }
    # room for a failure: the memory of the running VMs of each node against the free memory of the other nodes up
    foreach ($h in $members) {
      $need = (@(@($h.Vms | Where-Object { $_ -and $_.State -eq 'Running' -and $_.Clustered }) | ForEach-Object { [double]$_.MemoryMB }) + 0 | Measure-Object -Sum).Sum / 1024
      $others = @($members | Where-Object { $_.Name -ne $h.Name })
      $up = @($c.Nodes | Where-Object { $_.State -eq 'Up' } | ForEach-Object { Get-HcShort $_.Name })
      $free = (@($others | Where-Object { $up -contains $_.Name } | ForEach-Object { [double]$_.MemFreeMB }) + 0 | Measure-Object -Sum).Sum / 1024
      if ($others.Count -and $need -gt 0 -and $need -gt $free) { [void](Add-HcCheck $cn 'warn' 'Room' @($h.Name, (Format-HcSize $need), (Format-HcSize $free))) }
    }
  }

  # ---- the domain: DCs, FSMO roles, DNS
  if ($domain) {
    $dn = New-HcNode $m "domain:$(([string]$domain.Name).ToUpper())" 'domain' $(if ($domain.Name) { ([string]$domain.Name).ToLower() } else { Get-Text 'HcDomain' }) ''
    $dn.Data = $domain
    if ($domain.Error) { [void](Add-HcCheck $dn 'warn' 'DomainUnread' @($domain.Error)) }
    else {
      $roles = [ordered]@{ PDC = $domain.Pdc; RID = $domain.Rid; Infrastructure = $domain.Infra; Schema = $domain.Schema; Naming = $domain.Naming }
      $byOwner = @{}; foreach ($k in $roles.Keys) { $o = Get-HcShort $roles[$k]; if ($o) { if (-not $byOwner.ContainsKey($o)) { $byOwner[$o] = @() }; $byOwner[$o] += $k } }
      Add-HcFact $dn 'HcFFsmo' ((@($byOwner.Keys | Sort-Object | ForEach-Object { "$_ ($($byOwner[$_] -join ', '))" })) -join '; ')
      Add-HcFact $dn 'HcFDcs' ((@($domain.Dcs | ForEach-Object { "$(Get-HcShort $_.Name) $($_.Ip)" })) -join ', ')
    }
    $dcByName = @{}; foreach ($d in @($raw.Dcs | Where-Object { $_ })) { $dcByName[$d.Name] = $d }
    foreach ($d in @($raw.Dcs | Where-Object { $_ })) {
      $nd = New-HcNode $m "dc:$($d.Name)" 'dc' $d.Name $dn.Id
      $nd.Data = $d; $nd.Fqdn = [string]$d.Fqdn
      $held = @(); if ($byOwner -and $byOwner.ContainsKey($d.Name)) { $held = $byOwner[$d.Name] }
      if ($held.Count) { Add-HcFact $nd 'HcFRoles' ($held -join ', ') }
      if ($d.Ip) { Add-HcFact $nd 'HcFAddress' $d.Ip }
      # the ports, from here: what the clients see
      if ($d.Ports) {
        foreach ($p in '389', '88', '53', '445') { if ($d.Ports.PSObject.Properties[$p] -and -not $d.Ports.$p) { [void](Add-HcCheck $nd 'error' 'DcPort' @($p, (Get-Text "HcPort_$p"))) } }
        if ($d.Ports.PSObject.Properties['9389'] -and -not $d.Ports.'9389') { [void](Add-HcCheck $nd 'warn' 'Adws' @()) }
        if ($d.Ports.PSObject.Properties['3268'] -and -not $d.Ports.'3268') { [void](Add-HcCheck $nd 'info' 'NoGc' @()) }
      }
      foreach ($r in $held) { if ($d.Ports -and $d.Ports.PSObject.Properties['389'] -and -not $d.Ports.'389') { [void](Add-HcCheck $dn 'error' 'Fsmo' @($r, $d.Name) -why (Get-Text "HcW_Fsmo_$r")) } }
      if (-not $d.Reachable) { [void](Add-HcCheck $nd $(if ($d.Error -eq 'denied') { 'warn' } else { 'error' }) $(if ($d.Error -eq 'denied') { 'Denied' } else { 'Unreach' }) @($d.Name, $d.Error)); continue }
      Add-HcBasics $nd $d 'dc' $now $pdc $dcShort
      Add-HcServices $nd $d.Services @('NTDS', 'DNS', 'kdc', 'Netlogon', 'ADWS', 'W32Time', 'DFSR') @{ NTDS = 'HcW_Svc_NTDS'; DNS = 'HcW_Svc_DNS'; kdc = 'HcW_Svc_kdc'; Netlogon = 'HcW_Svc_Netlogon'; ADWS = 'HcW_Svc_ADWS'; W32Time = 'HcW_Svc_W32Time'; DFSR = 'HcW_Svc_DFSR' }
      $miss = @('SYSVOL', 'NETLOGON' | Where-Object { @($d.Shares) -notcontains $_ })
      if ($miss.Count) { [void](Add-HcCheck $nd 'error' 'Sysvol' @(($miss -join ', '))) }
      $rep = @($d.Replication | Where-Object { $_ })
      $bad = @($rep | Where-Object { [int]$_.Failures -gt 0 })
      if ($bad.Count) { [void](Add-HcCheck $nd 'error' 'Repl' @(((@($bad | ForEach-Object { Get-HcShort $_.Source } | Select-Object -Unique)) -join ', '), ([int](($bad | Measure-Object Failures -Maximum).Maximum)), "$(@($bad)[0].Status)") 'DcSyncAll') }
      elseif ($rep.Count) {
        $last = @($rep | ForEach-Object { try { [datetime]::Parse($_.LastSuccess, [Globalization.CultureInfo]::InvariantCulture) } catch { $null } } | Where-Object { $_ } | Sort-Object -Descending) | Select-Object -First 1
        Add-HcFact $nd 'HcFRepl' (Get-Text 'HcReplOk' (@($rep | ForEach-Object Source | Select-Object -Unique)).Count $(if ($last) { Format-VdiClock $last $now } else { '?' }))
      }
      $ord = @($d.DnsOrder | Where-Object { $_ })
      if ($ord.Count) { Add-HcFact $nd 'HcFDnsOrder' ($ord -join ', '); if ($ord[0] -eq '127.0.0.1' -and $ord.Count -gt 1) { [void](Add-HcCheck $nd 'warn' 'DnsLoopback' @($ord[1])) } }
      Add-HcAction $nd 'DcSyncAll'; Add-HcAction $nd 'TimeSync'
    }
    # what the DCs should have alike: services and their start mode, DNS zones
    $read = @($raw.Dcs | Where-Object { $_ -and $_.Reachable -and @($_.Services).Count })
    if ($read.Count -ge 2) {
      foreach ($d in $read) {
        foreach ($s in @($d.Services)) {
          foreach ($o in @($read | Where-Object { $_.Name -ne $d.Name })) {
            $t = @($o.Services | Where-Object { $_.Name -eq $s.Name }) | Select-Object -First 1
            if ($t -and $t.StartMode -ne $s.StartMode -and $s.StartMode -ne 'Auto') { [void](Add-HcCheck $m.Index["dc:$($d.Name)"] 'warn' 'NotAlike' @($o.Name, $s.Name, "$($s.State)/$($s.StartMode)", "$($t.State)/$($t.StartMode)")) }
          }
        }
      }
      $zr = @($read | Where-Object { @($_.Zones).Count })
      if ($zr.Count -ge 2) {
        $allZ = @($zr | ForEach-Object { @($_.Zones | ForEach-Object Name) } | Sort-Object -Unique)
        foreach ($z in $allZ) { $on = @($zr | Where-Object { @($_.Zones | ForEach-Object Name) -contains $z } | ForEach-Object Name); if ($on.Count -lt $zr.Count) { [void](Add-HcCheck $dn 'warn' 'ZoneOnOne' @($z, ($on -join ', '))) } }
      }
    }
    # ---- DNS: the servers answer, the names of the servers resolve to their own address and back, the reverse
    # zones of their networks exist
    $dns = $raw.Dns
    $dsn = New-HcNode $m 'dns' 'dns' (Get-Text 'HcDns') $dn.Id
    $dsn.Data = $dns
    foreach ($s in @($dns.Servers | Where-Object { $_ })) {
      if (-not $s.Ok) { [void](Add-HcCheck $dsn 'error' 'DnsDown' @($s.Server, $s.Error)) }
      elseif ([int]$s.Ms -gt $L.DnsMs) { [void](Add-HcCheck $dsn 'warn' 'DnsSlow' @($s.Server, $s.Ms)) }
      else { Add-HcFact $dsn 'HcFDnsServer' (Get-Text 'HcDnsAnswers' $s.Server $s.Ms) }
    }
    $nets = @{}
    foreach ($x in @($dns.Names | Where-Object { $_ -and $_.Kind -ne 'shared' })) {
      $ips = @($x.Ips | Where-Object { $_ })
      foreach ($ip in @($x.Own) + $ips) { if ($ip -match '^(\d+)\.(\d+)\.(\d+)\.\d+$' -and $ip -notmatch '^169\.254\.') { $nets["$($Matches[1]).$($Matches[2]).$($Matches[3])"] = 1 } }
      if (-not $ips.Count) { [void](Add-HcCheck $dsn 'error' 'NoName' @((Get-HcShort $x.Name), $x.Name)); continue }
      if ($ips.Count -gt 1) {
        [void](Add-HcCheck $dsn 'warn' 'TwoAddresses' @((Get-HcShort $x.Name), $ips.Count, ($ips -join ', ')))
      }
      foreach ($rv in @($x.Reverse | Where-Object { $_ })) {
        if (-not $rv.Name) { [void](Add-HcCheck $dsn 'info' 'NoPtr' @((Get-HcShort $x.Name), $rv.Ip)) }
        if ([int]$rv.Ms -gt $L.ReverseMs) { [void](Add-HcCheck $dsn 'warn' 'SlowPtr' @((Get-HcShort $x.Name), $rv.Ip, $rv.Ms)) }
      }
    }
    $zones = @(@($raw.Dcs | Where-Object { $_ -and $_.Reachable }) | ForEach-Object { @($_.Zones | Where-Object { $_.Reverse } | ForEach-Object Name) } | Sort-Object -Unique)
    if (@($raw.Dcs | Where-Object { $_ -and $_.Reachable -and @($_.Zones).Count }).Count) {
      foreach ($net in @($nets.Keys | Sort-Object)) {
        $p = $net.Split('.'); $want = "$($p[2]).$($p[1]).$($p[0]).in-addr.arpa"
        $has = @($zones | Where-Object { $want -eq $_ -or $want.EndsWith(".$_") }).Count
        if (-not $has) { [void](Add-HcCheck $dsn 'warn' 'NoReverseZone' @("$net.0/24") 'DnsReverseZone' $net) }
      }
      Add-HcFact $dsn 'HcFReverse' $(if ($zones.Count) { $zones -join ', ' } else { Get-Text 'HcNone' })
    }
    foreach ($x in @($dns.Names | Where-Object { $_ -and $_.Kind -eq 'shared' })) { Add-HcFact $dsn 'HcFShared' "$($x.Name): $(@($x.Ips) -join ', ')" }
  }

  # ---- SQL AlwaysOn
  $sql = $raw.Sql
  $srvBy = @{}; foreach ($s in @($raw.Servers | Where-Object { $_ })) { $srvBy[$s.Name] = $s }
  if ($sql) {
    $sn = New-HcNode $m "sql:$(([string]$sql.Listener).ToUpper())" 'sql' $sql.Listener ''
    $sn.Data = $sql
    if (-not $sql.Primary) { [void](Add-HcCheck $sn 'error' 'Listener' @($sql.Listener, $(if ($sql.Error) { $sql.Error } else { '?' }))) }
    else {
      Add-HcFact $sn 'HcFPrimary' $sql.Primary
      Add-HcFact $sn 'HcFAg' ((@($sql.Replicas | ForEach-Object Ag | Select-Object -Unique)) -join ', ')
    }
    $agDbs = @($sql.Databases | Where-Object { $_ } | ForEach-Object Db | Select-Object -Unique)
    if ($agDbs.Count) { Add-HcFact $sn 'HcFDbs' ($agDbs -join ', ') }
    # the last full backup of each database of the group, wherever it was made
    foreach ($db in $agDbs) {
      $last = @($sql.Nodes | ForEach-Object { @($_.LastFull | Where-Object { $_ -and $_.Db -eq $db } | ForEach-Object { ConvertFrom-VdiTime $_.Last }) } | Where-Object { $_ } | Sort-Object -Descending) | Select-Object -First 1
      if (-not $last) { if (@($sql.Nodes | Where-Object Reachable).Count) { [void](Add-HcCheck $sn 'warn' 'SqlNoBackup' @($db)) } }
      else { $hrs = [int][math]::Floor(($now - $last).TotalHours); if ($hrs -gt [int]$settings.BackupHours) { [void](Add-HcCheck $sn 'warn' 'SqlBackup' @($db, $hrs, (Format-VdiClock $last $now))) } }
    }
    $logins = @{}; foreach ($x in @($sql.Nodes | Where-Object { $_ -and $_.Reachable })) { $logins[$x.Replica] = @($x.Logins) }
    $jobsBy = @{}; foreach ($x in @($sql.Nodes | Where-Object { $_ -and $_.Reachable })) { $jobsBy[$x.Replica] = @($x.Jobs) }
    foreach ($rp in @($sql.Replicas | Where-Object { $_ } | Group-Object Replica)) {
      $r = $rp.Group[0]
      $rn = New-HcNode $m "replica:$(([string]$r.Replica).ToUpper())" 'replica' $r.Replica $sn.Id
      $node = @($sql.Nodes | Where-Object { $_.Replica -eq $r.Replica }) | Select-Object -First 1
      $rn.Data = $node; $rn.Fqdn = if ($node) { [string]$node.Server } else { '' }
      Add-HcFact $rn 'HcFRole' (Get-Text 'HcReplicaIs' $r.Role $r.Mode)
      foreach ($x in $rp.Group) { if ($x.Connected -and ($x.Connected -ne 'CONNECTED' -or $x.Health -ne 'HEALTHY')) { [void](Add-HcCheck $rn 'error' 'Replica' @($x.Ag, $x.Connected, $x.Health)) } }
      foreach ($d in @($sql.Databases | Where-Object { $_ -and $_.Replica -eq $r.Replica })) {
        $want = if ($d.Mode -eq 'SYNCHRONOUS_COMMIT') { 'SYNCHRONIZED' } else { 'SYNCHRONIZING' }
        if ([int]$d.Suspended) { [void](Add-HcCheck $rn 'error' 'DbSuspended' @($d.Db, $d.Reason) 'SqlResume' $d.Db) }
        elseif ($d.Sync -ne $want -and -not ($want -eq 'SYNCHRONIZING' -and $d.Sync -eq 'SYNCHRONIZED')) { [void](Add-HcCheck $rn 'error' 'DbSync' @($d.Db, $d.Sync, $want)) }
      }
      if ($node) {
        $svcNeed = @($node.Services | Where-Object { $_.Name -like 'MSSQL*' -or $_.Name -like 'SQL*Agent*' -or $_.Name -eq 'ClusSvc' } | ForEach-Object Name)
        foreach ($s in @($node.Services | Where-Object { $_ -and $svcNeed -contains $_.Name -and $_.State -ne 'Running' -and $_.State -ne 'Missing' -and $_.State -notmatch 'Pending' })) {
          [void](Add-HcCheck $rn 'error' $(if ($s.StartMode -eq 'Disabled') { 'SvcDisabled' } else { 'SvcStopped' }) @($s.Name, $s.State, $s.StartMode) 'SqlStartService' $s.Name (Get-Text $(if ($s.Name -eq 'ClusSvc') { 'HcW_Svc_ClusSvcSql' } elseif ($s.Name -like 'MSSQL*') { 'HcW_Svc_Mssql' } else { 'HcW_Svc_Agent' })))
        }
        if (-not $node.Reachable) { [void](Add-HcCheck $rn 'warn' 'SqlUnread' @($r.Replica, $node.Error)) }
        else {
          # logins: the AG copies the databases, not the logins
          $mine = @($logins[$r.Replica]); $names = @($mine | ForEach-Object Name)
          $missing = @(); $disabled = @()
          foreach ($o in @($logins.Keys | Where-Object { $_ -ne $r.Replica })) {
            foreach ($l in @($logins[$o] | Where-Object { [int]$_.Disabled -eq 0 })) {
              # the computer accounts of the replicas themselves are not expected on each other
              if ($l.Name -match '\$$' -and @($sql.Nodes | Where-Object { $l.Name -match ('\\' + [regex]::Escape((Get-HcShort $_.Server)) + '\$$') }).Count) { continue }
              if ($names -notcontains $l.Name) { $missing += $l.Name }
              elseif ([int](@($mine | Where-Object { $_.Name -eq $l.Name })[0].Disabled)) { $disabled += $l.Name }
            }
          }
          if ($missing.Count) { [void](Add-HcCheck $rn 'error' 'LoginsMissing' @((($missing | Sort-Object -Unique) -join ', '))) }
          if ($disabled.Count) { [void](Add-HcCheck $rn 'error' 'LoginsDisabled' @((($disabled | Sort-Object -Unique) -join ', '))) }
          if (-not $missing.Count -and -not $disabled.Count -and $logins.Count -ge 2) { Add-HcFact $rn 'HcFLogins' (Get-Text 'HcLoginsAlike' $mine.Count) }
          $jm = @(); foreach ($o in @($jobsBy.Keys | Where-Object { $_ -ne $r.Replica })) { $jm += @($jobsBy[$o] | Where-Object { @($jobsBy[$r.Replica]) -notcontains $_ }) }
          if ($jm.Count) { [void](Add-HcCheck $rn 'warn' 'JobsMissing' @((($jm | Sort-Object -Unique) -join ', '))) }
          if (@($node.FailedJobs).Count) { [void](Add-HcCheck $rn 'warn' 'JobsFailed' @(((@($node.FailedJobs)) -join ', '), $L.JobDays)) }
          $other = @($sql.Nodes | Where-Object { $_.Reachable -and $_.Replica -ne $r.Replica -and $null -ne $_.IntegratedOnly -and [int]$_.IntegratedOnly -ne [int]$node.IntegratedOnly }) | Select-Object -First 1
          if ($other -and [int]$node.IntegratedOnly -eq 1) { [void](Add-HcCheck $rn 'error' 'SqlAuth' @($other.Replica)) }
        }
        $bs = $srvBy[(Get-HcShort $node.Server)]
        if ($bs) { if ($bs.Reachable) { Add-HcBasics $rn $bs 'sql' $now $pdc $dcShort } else { [void](Add-HcCheck $rn 'warn' $(if ($bs.Error -eq 'denied') { 'Denied' } else { 'Unreach' }) @($bs.Name, $bs.Error)) } }
      }
    }
  }

  # ---- the brokers of the Desktops page: their findings there, what they tell about themselves here
  $brokers = if ($vdi) { @($vdi.Brokers | Where-Object { $_ }) } else { @() }
  if ($brokers.Count -or @($raw.Servers | Where-Object { $_ }).Count) {
    $bn = New-HcNode $m 'rds' 'rds' (Get-Text 'HcRds') ''
    Add-HcAction $bn 'OpenDesktops'
    if ($vdi) { foreach ($nm in @($vdi.Names | Where-Object { $_ -and -not $_.IsIp })) { & $addVdi $bn $nm.Name } }
    $sqlServers = if ($sql) { @($sql.Nodes | ForEach-Object { Get-HcShort $_.Server }) } else { @() }
    $names = @($brokers | ForEach-Object Name) + @($raw.Servers | Where-Object { $_ -and $sqlServers -notcontains $_.Name } | ForEach-Object Name) | Select-Object -Unique
    foreach ($nm in $names) {
      $b = @($brokers | Where-Object { $_.Name -eq $nm }) | Select-Object -First 1
      $nb = New-HcNode $m "broker:$nm" 'broker' $nm $bn.Id
      $nb.Data = $b; $nb.Fqdn = if ($b) { [string]$b.Fqdn } else { '' }
      Add-HcAction $nb 'OpenDesktops'
      if ($b) {
        Add-HcFact $nb 'HcFBroker' $(if (-not $b.Reachable) { Get-Text 'HcBrokerUnread' } elseif ($b.IsActive) { Get-Text 'HcBrokerActive' $b.Received $b.Failed } else { Get-Text 'HcBrokerIs' $b.Received $b.Failed })
        & $addVdi $nb $nm
      }
      $s = $srvBy[$nm]
      if ($s) {
        if (-not $nb.Fqdn) { $nb.Fqdn = [string]$s.Fqdn }
        if ($s.Reachable) { Add-HcBasics $nb $s 'server' $now $pdc $dcShort }
        elseif (-not $b -or $b.Reachable) { [void](Add-HcCheck $nb 'warn' $(if ($s.Error -eq 'denied') { 'Denied' } else { 'Unreach' }) @($s.Name, $s.Error)) }
      }
      Add-HcAction $nb 'TimeSync'
    }
  }

  # ---- the devices (NAS, witness, others)
  $devs = @($raw.Devices | Where-Object { $_ })
  if ($devs.Count) {
    $gn = New-HcNode $m 'devices' 'group' (Get-Text 'HcDevices') ''
    $witness = @{}; foreach ($c in $clusters) { if ($c.Witness -and $c.Witness.Path) { $witness[(Get-HcShort (("$($c.Witness.Path)" -replace '^\\\\', '' -split '\\')[0]))] = $c.Name } }
    foreach ($d in $devs) {
      $nd = New-HcNode $m "device:$(([string]$d.Name).ToUpper())" 'device' $d.Name $gn.Id
      $nd.Data = $d
      $wFor = if ($witness.ContainsKey((Get-HcShort $d.Address))) { $witness[(Get-HcShort $d.Address)] } elseif ($witness.ContainsKey((Get-HcShort $d.Name))) { $witness[(Get-HcShort $d.Name)] } else { '' }
      Add-HcFact $nd 'HcFAddress' $d.Address
      if ($wFor) { Add-HcFact $nd 'HcFWitnessOf' $wFor }
      $open = @($d.Ports | Where-Object { $_.Open }); $closed = @($d.Ports | Where-Object { -not $_.Open })
      if ($d.Ping) { Add-HcFact $nd 'HcFPing' (Get-Text 'HcPingMs' $d.Ms) }
      if (@($d.Ports).Count) { Add-HcFact $nd 'HcFPorts' ((@($d.Ports | ForEach-Object { "$($_.Port) $(if ($_.Open) { Get-Text 'HcOpen' } else { Get-Text 'HcClosed' })" })) -join ', ') }
      if (-not $d.Ping -and -not $open.Count) {
        $why = if ($wFor) { Get-Text 'HcW_DeviceDownWitness' $wFor } else { $null }
        [void](Add-HcCheck $nd 'error' 'DeviceDown' @($d.Name, $d.Address) $(if ($d.Mac) { 'DeviceWake' }) $null $why)
      } else {
        foreach ($p in $closed) { [void](Add-HcCheck $nd 'error' 'DevicePort' @($p.Port)) }
        if (-not $d.Ping) { [void](Add-HcCheck $nd 'info' 'NoPing' @()) }
      }
      if ($d.Share) {
        if ($null -ne $d.ShareOk -and [int]$d.ShareOk -eq 1) { Add-HcFact $nd 'HcFShare' (Get-Text 'HcShareOk' $d.Share) }
        elseif ($null -ne $d.ShareOk) { [void](Add-HcCheck $nd 'error' 'Share' @($d.Share, $(if ([int]$d.ShareOk -lt 0) { Get-Text 'HcNoAnswer' } else { Get-Text 'HcNotFound' }))) }
      }
      if ($d.Mac) { Add-HcFact $nd 'HcFMac' $d.Mac; Add-HcAction $nd 'DeviceWake' }
    }
  }
  # ---- backups
  if ($raw.Backup) {
    $b = $raw.Backup
    $nb = New-HcNode $m 'backup' 'backup' (Get-Text 'HcBackup') ''
    $nb.Data = $b
    Add-HcFact $nb 'HcFBackupPath' $b.Path
    if ($b.Error) { [void](Add-HcCheck $nb 'error' 'BackupUnread' @($b.Error)) }
    elseif (-not $b.Time -or ($b.Text -and -not $b.Matched)) { [void](Add-HcCheck $nb 'error' 'BackupNone' @($b.Path, $(if ($b.Text) { $b.Text } else { '' }))) }
    else {
      $t = ConvertFrom-VdiTime $b.Time; $hrs = [int][math]::Floor(($now - $t).TotalHours)
      Add-HcFact $nb 'HcFBackupLast' (Get-Text 'HcBackupAt' (Format-VdiClock $t $now) $hrs ([IO.Path]::GetFileName([string]$b.File)))
      if ($hrs -gt [int]$settings.BackupHours) { [void](Add-HcCheck $nb 'error' 'BackupOld' @($hrs, (Format-VdiClock $t $now), $settings.BackupHours)) }
    }
  }
  Complete-HealthModel $m
  $m
}
# The state of every node (its worst check, its subtree), the words of the tree, the headline
function Complete-HealthModel($m) {
  foreach ($n in $m.Nodes) {
    $n.Own = Get-HcWorst @($n.Checks | ForEach-Object Kind)
    if ($n.Own -eq 'info') { $n.Own = 'ok' }
    if ($n.Kind -eq 'vm' -and $n.Own -eq 'ok' -and $n.Data -and $n.Data.State -ne 'Running') { $n.Own = 'off' }
  }
  # bottom up: children come after their parent in the list
  for ($i = $m.Nodes.Count - 1; $i -ge 0; $i--) {
    $n = $m.Nodes[$i]
    $kinds = @($n.Own) + @($n.Children | ForEach-Object { $s = $m.Index[$_].Status; if ($s -eq 'off') { 'ok' } else { $s } })
    $n.Status = Get-HcWorst $kinds
    if ($n.Status -eq 'ok' -and $n.Own -eq 'off') { $n.Status = 'off' }
    $n.Problems = @($n.Checks | Where-Object { $_.Kind -in 'error', 'warn' }).Count + (@($n.Children | ForEach-Object { $m.Index[$_].Problems }) + 0 | Measure-Object -Sum).Sum
    $first = @(Get-HcByKind $n.Checks | Where-Object { $_.Kind -in 'error', 'warn' }) | Select-Object -First 1
    if ($first) { $n.Short = $first.Title }
    elseif ($n.Problems) { $n.Short = Get-Text 'HcProblemsBelow' $n.Problems }
    elseif (-not $n.Short) { $n.Short = Get-Text 'HcStatusOk' }
  }
  $all = @($m.Nodes | ForEach-Object { $n = $_; @($n.Checks | Where-Object { $_.Kind -in 'error', 'warn' } | ForEach-Object { [pscustomobject]@{ Node = $n; Check = $_ } }) })
  $m.Problems = @(@($all | Where-Object { $_.Check.Kind -eq 'error' }) + @($all | Where-Object { $_.Check.Kind -eq 'warn' }))
  $m.Errors = @($all | Where-Object { $_.Check.Kind -eq 'error' }).Count; $m.Warnings = @($all | Where-Object { $_.Check.Kind -eq 'warn' }).Count
  if ($m.Problems.Count) {
    $m.HeadlineKind = if ($m.Errors) { 'error' } else { 'warn' }
    $m.Headline = (Get-Text 'HcHeadProblems' $m.Errors $m.Warnings) + '   ' + ((@($m.Problems | Select-Object -First 3 | ForEach-Object { "$($_.Node.Name): $($_.Check.Title)" })) -join "   $([char]0x00B7)   ") + $(if ($m.Problems.Count -gt 3) { "   $([char]0x00B7)   ..." } else { '' })
  } else {
    $hosts = @($m.Nodes | Where-Object Kind -eq 'host').Count; $vms = @($m.Nodes | Where-Object Kind -eq 'vm').Count; $dcs = @($m.Nodes | Where-Object Kind -eq 'dc').Count
    $m.HeadlineKind = 'ok'; $m.Headline = Get-Text 'HcHeadOk' $hosts $vms $dcs
  }
}

# ---------------------------------------------------------------------------------------------
# Actions. A plan says what it does (Title, Text for the confirmation, Log for config\changes.log), whether it can run
# now (Blocked), whether it is SAFE (it may run by itself in repair mode) and how (Steps, run by $script:VdiJobRunner).
# Every remote script reads back what it changed and says so in Lines: never reported done without checking.
# ---------------------------------------------------------------------------------------------
$script:HealthRemote = @{
  # Starts a service, with a time limit (ServiceController.Start returns at once, WaitForStatus has a limit). A
  # disabled service is set to automatic only when asked ($enable = 1).
  ServiceStart = {
    param([string]$svc, [string]$enable, [int]$wait)
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $s) { return [pscustomobject]@{ Ok = $false; Error = "$svc not found"; Lines = @() } }
    $before = "$($s.Status)"; $mode = "$((Get-CimInstance Win32_Service -Filter "Name='$svc'" -ErrorAction SilentlyContinue).StartMode)"
    if ($mode -eq 'Disabled') {
      if ($enable -ne '1') { return [pscustomobject]@{ Ok = $false; Error = "$svc is disabled"; Lines = @() } }
      Set-Service -Name $svc -StartupType Automatic -ErrorAction SilentlyContinue
    }
    if ($s.Status -eq 'Stopped') { try { $s.Start() } catch { } }
    try { $s.WaitForStatus('Running', [TimeSpan]::FromSeconds($wait)) } catch { }
    $s.Refresh(); $after = "$($s.Status)"; $mode2 = "$((Get-CimInstance Win32_Service -Filter "Name='$svc'" -ErrorAction SilentlyContinue).StartMode)"
    [pscustomobject]@{ Ok = ($after -eq 'Running'); Error = $(if ($after -ne 'Running') { "$svc is $after" }); Lines = @("${svc}: $before ($mode) -> $after ($mode2)") }
  }
  TimeSync = {
    $o = @(& w32tm.exe /resync /force 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ }); $code = $LASTEXITCODE
    [pscustomobject]@{ Ok = ($code -eq 0); Error = $(if ($code) { ($o | Select-Object -Last 1) }); Lines = $o }
  }
  # a member of the domain takes its time from the domain hierarchy again
  TimeDomain = {
    $o = @(& w32tm.exe /config /syncfromflags:domhier /update 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ }); $code = $LASTEXITCODE
    if (-not $code) { $o += @(& w32tm.exe /resync /force 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) }
    $src = ("$(& w32tm.exe /query /source 2>$null)").Trim()
    [pscustomobject]@{ Ok = ($code -eq 0); Error = $(if ($code) { ($o | Select-Object -Last 1) }); Lines = @($o) + "source: $src" }
  }
  SecureChannel = { $ok = $false; try { $ok = [bool](Test-ComputerSecureChannel -ErrorAction Stop) } catch { }
    [pscustomobject]@{ Ok = $ok; Error = $(if (-not $ok) { 'the secure channel is still broken' }); Lines = @("secure channel: $(if ($ok) { 'ok' } else { 'broken' })") } }
  WitnessOnline = {
    param([string]$res)
    try { Start-ClusterResource -Name $res -Wait 60 -ErrorAction Stop | Out-Null } catch { }
    $s = "$((Get-ClusterResource -Name $res -ErrorAction SilentlyContinue).State)"
    [pscustomobject]@{ Ok = ($s -eq 'Online'); Error = $(if ($s -ne 'Online') { "$res is $s" }); Lines = @("${res}: $s") }
  }
  GroupStart = {
    param([string]$group)
    $err = $null; try { Start-ClusterGroup -Name $group -Wait 120 -ErrorAction Stop | Out-Null } catch { $err = $_.Exception.Message }
    $s = "$((Get-ClusterGroup -Name $group -ErrorAction SilentlyContinue).State)"
    [pscustomobject]@{ Ok = ($s -eq 'Online'); Error = $(if ($s -ne 'Online') { if ($err) { $err } else { "$group is $s" } }); Lines = @("${group}: $s") }
  }
  DrainOnShutdown = {
    $c = Get-Cluster; $before = [int]$c.DrainOnShutdown; $c.DrainOnShutdown = 1; $after = [int](Get-Cluster).DrainOnShutdown
    [pscustomobject]@{ Ok = ($after -eq 1); Error = $null; Lines = @("DrainOnShutdown: $before -> $after") }
  }
  # Moves every role of this node to the others, live, and pauses it. The VMs keep running; read back: no VM role left
  # on this node, the node Paused.
  Drain = {
    $err = $null
    try { Suspend-ClusterNode -Name $env:COMPUTERNAME -Drain -Wait -ErrorAction Stop | Out-Null } catch { $err = $_.Exception.Message }
    $left = @(Get-ClusterGroup | Where-Object { "$($_.GroupType)" -eq 'VirtualMachine' -and "$($_.OwnerNode)" -ieq $env:COMPUTERNAME } | ForEach-Object Name)
    $st = "$((Get-ClusterNode -Name $env:COMPUTERNAME).State)"
    [pscustomobject]@{ Ok = (-not $left.Count -and $st -eq 'Paused'); Error = $(if ($left.Count) { "VMs still here: $($left -join ', ')" } elseif ($err) { $err } elseif ($st -ne 'Paused') { "node is $st" })
      Lines = @("node: $st", "VM roles left on it: $(if ($left.Count) { $left -join ', ' } else { 'none' })") }
  }
  # Back in service, and its VMs back to it (the failback that a drain does not undo by itself)
  Resume = {
    $err = $null; try { Resume-ClusterNode -Name $env:COMPUTERNAME -Failback Immediate -ErrorAction Stop | Out-Null } catch { $err = $_.Exception.Message }
    $st = "$((Get-ClusterNode -Name $env:COMPUTERNAME).State)"
    [pscustomobject]@{ Ok = ($st -eq 'Up'); Error = $(if ($st -ne 'Up') { if ($err) { $err } else { "node is $st" } }); Lines = @("node: $st") }
  }
  VmResume = {
    param([string]$vm)
    $err = $null; try { Resume-VM -Name $vm -ErrorAction Stop } catch { $err = $_.Exception.Message }
    $s = "$((Get-VM -Name $vm -ErrorAction SilentlyContinue).State)"
    [pscustomobject]@{ Ok = ($s -eq 'Running'); Error = $(if ($s -ne 'Running') { if ($err) { $err } else { "$vm is $s" } }); Lines = @("${vm}: $s") }
  }
  # a running VM whose cluster role is offline: the cluster takes it in charge again (nothing stops)
  RoleOnline = {
    param([string]$vm)
    $err = $null
    try { $r = @(Get-ClusterResource -ErrorAction Stop | Where-Object { "$($_.ResourceType)" -eq 'Virtual Machine' -and "$($_.OwnerGroup)" -eq $vm }) | Select-Object -First 1
          if (-not $r) { throw "no cluster role $vm" }
          Start-ClusterResource -Name $r.Name -Wait 60 -ErrorAction Stop | Out-Null } catch { $err = $_.Exception.Message }
    $s = if ($r) { "$((Get-ClusterResource -Name $r.Name -ErrorAction SilentlyContinue).State)" } else { '' }
    [pscustomobject]@{ Ok = ($s -eq 'Online'); Error = $(if ($s -ne 'Online') { if ($err) { $err } else { "$vm role is $s" } }); Lines = @("${vm}: role $s") }
  }
  # the checkpoints older than $days, oldest first: each one merges into its parent (the VM keeps running)
  RemoveCheckpoints = {
    param([string]$vm, [int]$days)
    $old = @(Get-VMSnapshot -VMName $vm -ErrorAction SilentlyContinue | Where-Object { $_.CreationTime -lt (Get-Date).AddDays(-$days) } | Sort-Object CreationTime)
    $lines = @(); $err = $null
    foreach ($c in $old) { try { Remove-VMSnapshot -VMSnapshot $c -ErrorAction Stop; $lines += "removed: $($c.Name)" } catch { $err = $_.Exception.Message; $lines += "NOT removed: $($c.Name) ($err)" } }
    $left = @(Get-VMSnapshot -VMName $vm -ErrorAction SilentlyContinue | Where-Object { $_.CreationTime -lt (Get-Date).AddDays(-$days) }).Count
    [pscustomobject]@{ Ok = ($left -eq 0); Error = $(if ($left) { if ($err) { $err } else { "$left still there" } }); Lines = $lines }
  }
  StopAction = {
    param([string]$vm)
    $err = $null; try { Set-VM -Name $vm -AutomaticStopAction ShutDown -ErrorAction Stop } catch { $err = $_.Exception.Message }
    $a = "$((Get-VM -Name $vm -ErrorAction SilentlyContinue).AutomaticStopAction)"
    [pscustomobject]@{ Ok = ($a -eq 'ShutDown'); Error = $(if ($a -ne 'ShutDown') { if ($err) { $err } else { "still $a" } }); Lines = @("${vm}: AutomaticStopAction $a") }
  }
  SyncAll = {
    $o = @(& repadmin.exe /syncall /AdeP 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ }); $code = $LASTEXITCODE
    [pscustomobject]@{ Ok = ($code -eq 0); Error = $(if ($code) { ($o | Select-Object -Last 1) }); Lines = @($o | Select-Object -Last 6) }
  }
  ReverseZone = {
    param([string]$net)
    $p = $net.Split('.'); $zone = "$($p[2]).$($p[1]).$($p[0]).in-addr.arpa"; $err = $null
    try { Add-DnsServerPrimaryZone -NetworkId "$net.0/24" -ReplicationScope Domain -DynamicUpdate Secure -ErrorAction Stop } catch { $err = $_.Exception.Message }
    $ok = [bool](Get-DnsServerZone -Name $zone -ErrorAction SilentlyContinue)
    [pscustomobject]@{ Ok = $ok; Error = $(if (-not $ok) { $err }); Lines = @("${zone}: $(if ($ok) { 'present' } else { 'missing' })") }
  }
  # here, through SqlClient: the data movement of a database on a replica (where it was suspended)
  SqlResume = {
    param([string]$server, [string]$db)
    $q = "ALTER DATABASE [" + $db.Replace(']', ']]') + "] SET HADR RESUME"
    $cn = New-Object System.Data.SqlClient.SqlConnection "Server=$server;Database=master;Integrated Security=SSPI;Encrypt=False;Connect Timeout=10;Application Name=OpenThinRDP Manager"
    $err = $null; $susp = $null
    try { $cn.Open(); $c = $cn.CreateCommand(); $c.CommandText = $q; $c.CommandTimeout = 60; [void]$c.ExecuteNonQuery()
      $c.CommandText = "SELECT CAST(drs.is_suspended AS int) FROM sys.dm_hadr_database_replica_states drs WHERE drs.is_local = 1 AND drs.database_id = DB_ID(@d)"; [void]$c.Parameters.AddWithValue('@d', $db)
      $susp = $c.ExecuteScalar() } catch { $err = $_.Exception.GetBaseException().Message } finally { $cn.Close() }
    [pscustomobject]@{ Ok = (-not $err -and "$susp" -eq '0'); Error = $err; Lines = @("${db} on ${server}: suspended = $susp") }
  }
  # Wake-on-LAN, from here: the magic packet (6 x FF, the MAC 16 times) to every address of the network, ports 9 and 7
  Wake = {
    param([string]$mac, [string]$address)
    $hex = $mac -replace '[^0-9A-Fa-f]', ''; $b = New-Object byte[] 102
    for ($i = 0; $i -lt 6; $i++) { $b[$i] = 255 }
    for ($i = 0; $i -lt 16; $i++) { for ($j = 0; $j -lt 6; $j++) { $b[6 + $i * 6 + $j] = [Convert]::ToByte($hex.Substring($j * 2, 2), 16) } }
    $dest = @('255.255.255.255')
    $ip = if ($address -match '^\d{1,3}(\.\d{1,3}){3}$') { $address } else { try { @([Net.Dns]::GetHostAddresses($address) | Where-Object { $_.AddressFamily -eq 'InterNetwork' })[0].IPAddressToString } catch { $null } }
    if ($ip) { $dest += ($ip -replace '\.\d+$', '.255') }
    $u = New-Object Net.Sockets.UdpClient; $u.EnableBroadcast = $true; $sent = 0
    try { foreach ($d in $dest) { foreach ($p in 9, 7) { try { [void]$u.Send($b, $b.Length, $d, $p); $sent++ } catch { } } } } finally { $u.Close() }
    [pscustomobject]@{ Ok = ($sent -gt 0); Error = $(if (-not $sent) { 'not sent' }); Lines = @("magic packet for $mac sent $sent times ($($dest -join ', '))") }
  }
}
function New-HealthStep([string]$name, [string]$computer, [string]$script, $argList, [bool]$stopOnFail = $true) {
  $sb = if ($script:HealthRemote.ContainsKey($script)) { $script:HealthRemote[$script] } else { $script:VdiRemote[$script] }
  $label = Get-TextIf "HcStep_$script"; if (-not $label) { $label = Get-Text "VdiStep_$script" }
  [pscustomobject]@{ Name = $name; Label = $label; Key = $script; Computer = $computer; Script = $sb.ToString(); Args = @($argList); Local = (-not $computer); StopOnFail = $stopOnFail }
}
# the services each role needs (starting them is safe), and those that may be ended when stuck without asking
$script:HealthSafeStart = @{ host = @('vmms', 'VmHostAgent', 'ClusSvc', 'WinRM', 'W32Time'); dc = @('NTDS', 'DNS', 'kdc', 'Netlogon', 'ADWS', 'W32Time', 'DFSR'); server = @('W32Time', 'WinRM'); broker = @('W32Time', 'WinRM'); replica = @('W32Time', 'WinRM') }
$script:HealthSafeUnstick = @('VmHostAgent', 'vmms', 'W32Time')
$script:HealthVdiSafe = @('BrokerRestart', 'HostPermissions', 'HostUnblock', 'HostOfflineAction')
function Get-HealthRole($n) { switch ($n.Kind) { 'dc' { 'dc' } 'replica' { 'sql' } 'broker' { 'broker' } 'host' { 'host' } default { '' } } }
# a node of the cluster to run a cluster action on: the one the probe read the cluster from, else one that answered
function Get-HealthClusterNode($m, $c) {
  $members = @($m.Nodes | Where-Object { $_.Kind -eq 'host' -and $_.Parent -eq "cluster:$(([string]$c.Name).ToUpper())" -and $_.Data -and $_.Data.Reachable })
  $first = @($members | Where-Object { $_.Name -eq (Get-HcShort $c.Node) }) + $members | Select-Object -First 1
  if ($first) { $first.Fqdn } else { '' }
}
function Get-HealthUsersOf($state, [string]$vm) {
  if (-not $state.Vdi) { return @() }
  @(@($state.Vdi.Rows | Where-Object { $_.Vm -ieq $vm -and $_.Session -and $_.User } | ForEach-Object User) | Select-Object -Unique)
}

# Kind: an action of the Health Center (Target = the id of a node, Arg = what the check gave). $state: @{ Model; Vdi
# (the model of the Desktops page); Received; Running (an action running now); Recent (the actions of the last
# minutes: Role, Target, Time) }.
function Get-HealthActionPlan([string]$kind, [string]$target, $state, [datetime]$now, $arg = $null) {
  $m = $state.Model
  $p = [pscustomobject]@{ Kind = $kind; Title = (Get-Text "HcAct_$kind"); Text = ''; Blocked = $null; Destructive = $false; DefaultNo = $false; Safe = $false; Steps = @(); Log = ''
    Target = $target; Arg = $arg; Source = 'health'; Role = ''; Node = $null }
  $n = if ($m) { $m.Index[$target] } else { $null }
  if (-not $n) { $p.Blocked = Get-Text 'VdiBlkUnknown' $target; return $p }
  $p.Node = $n; $p.Role = Get-HealthRole $n
  if ($state.Running) { $p.Blocked = Get-Text 'VdiBlkRunning' $state.Running; return $p }
  $d = $n.Data
  $where = $n.Name
  $fq = $n.Fqdn
  switch ($kind) {
    { $_ -in 'ServiceStart', 'SqlStartService' } {
      $svc = [string]$arg
      $list = if ($kind -eq 'SqlStartService') { @($d.Services) } else { @($d.Services) + @($d.Failed) }
      $s = @($list | Where-Object { $_ -and $_.Name -eq $svc }) | Select-Object -First 1
      $disabled = $s -and $s.PSObject.Properties['StartMode'] -and $s.StartMode -eq 'Disabled'
      if ($kind -eq 'SqlStartService') { $fq = [string]$d.Server }
      $role = if ($n.Kind -eq 'replica') { 'replica' } else { $n.Kind }
      $p.Safe = -not $disabled -and ($kind -eq 'SqlStartService' -or @($script:HealthSafeStart[$role]) -contains $svc)
      if (-not $svc) { $p.Blocked = Get-Text 'VdiBlkNothing' }
      elseif (-not $fq) { $p.Blocked = Get-Text 'VdiBlkUnreachable' $where }
      elseif ($s -and $s.PSObject.Properties['State'] -and $s.State -eq 'Running') { $p.Blocked = Get-Text 'HcBlkRunningSvc' $svc }
      $p.Text = Get-Text $(if ($disabled) { 'HcConfStartDisabled' } else { 'HcConfStart' }) $svc $where
      $p.Steps = @(New-HealthStep "start $svc" $fq 'ServiceStart' @($svc, $(if ($disabled) { '1' } else { '0' }), 40))
      $p.Log = "start the service $svc on $where$(if ($disabled) { ' (it was disabled: set to automatic)' })"
    }
    'ServiceUnstick' {
      $svc = [string]$arg
      $p.Destructive = $true
      $p.Safe = @($script:HealthSafeUnstick) -contains $svc -and $n.Kind -in 'host', 'broker', 'replica', 'server'
      if ($svc -like 'MSSQL*' -or $svc -like 'SQLAgent*' -or $svc -eq 'SQLSERVERAGENT') { $p.Blocked = Get-Text 'HcBlkSqlKill' }
      elseif ($svc -eq 'WinRM') { $p.Blocked = Get-Text 'HcBlkWinRm' }
      elseif (-not $fq) { $p.Blocked = Get-Text 'VdiBlkUnreachable' $where }
      elseif ($n.Kind -eq 'dc') {
        # a service of a DC is ended only while another DC serves the sign-ins
        $other = @($m.Nodes | Where-Object { $_.Kind -eq 'dc' -and $_.Id -ne $n.Id -and $_.Data.Reachable -and $_.Own -ne 'error' })
        if (-not $other.Count) { $p.Blocked = Get-Text 'HcBlkNoOtherDc' $where }
      }
      $p.Text = Get-Text 'HcConfUnstick' $svc $where
      $p.Steps = @(New-HealthStep "unblock $svc" $fq 'Restart' @($svc, $svc, 20, ''))
      $p.Log = "unblock $svc on $where (stopped with a time limit, its process ended if stuck, started)"
    }
    'NetlogonRestart' {
      $p.Safe = $true
      if (-not $fq) { $p.Blocked = Get-Text 'VdiBlkUnreachable' $where }
      $p.Text = Get-Text 'HcConfNetlogon' $where
      $p.Steps = @((New-HealthStep 'restart Netlogon' $fq 'Restart' @('Netlogon', 'Netlogon', 30, '')), (New-HealthStep 'secure channel' $fq 'SecureChannel' @() $false))
      $p.Log = "restart Netlogon on $where (secure channel with the domain broken)"
    }
    'TimeSync' {
      $p.Safe = $true
      if (-not $fq) { $p.Blocked = Get-Text 'VdiBlkUnreachable' $where }
      $p.Text = Get-Text 'HcConfTime' $where
      $p.Steps = @(New-HealthStep 'resync clock' $fq 'TimeSync' @())
      $p.Log = "resynchronise the clock of $where (w32tm /resync)"
    }
    'TimeDomain' {
      if (-not $fq) { $p.Blocked = Get-Text 'VdiBlkUnreachable' $where }
      $p.Text = Get-Text 'HcConfTimeDomain' $where
      $p.Steps = @(New-HealthStep 'time from the domain' $fq 'TimeDomain' @())
      $p.Log = "take the time of $where from the domain hierarchy (w32tm /config /syncfromflags:domhier)"
    }
    { $_ -in 'WitnessOnline', 'ClusterOfflineAction', 'ClusterDrainOnShutdown', 'ClusterGroupStart' } {
      $c = $d; $node = if ($c) { Get-HealthClusterNode $m $c } else { '' }
      if (-not $node) { $p.Blocked = Get-Text 'VdiBlkUnreachable' $where }
      switch ($kind) {
        'WitnessOnline' {
          $p.Safe = $true; $w = if ($c) { $c.Witness } else { $null }
          if (-not $p.Blocked -and (-not $w -or $w.State -eq 'Online')) { $p.Blocked = Get-Text 'VdiBlkNothing' }
          $p.Text = Get-Text 'HcConfWitness' $(if ($w) { $w.Name }) $where
          $p.Steps = @(New-HealthStep 'witness online' $node 'WitnessOnline' @($(if ($w) { $w.Name } else { '' })))
          $p.Log = "bring the witness of $where online"
        }
        'ClusterOfflineAction' {
          $p.Safe = $true
          $vms = @("$arg".Split(',') | Where-Object { $_ })
          if (-not $vms.Count) { $chk = @($n.Checks | Where-Object { $_.Fix -eq 'ClusterOfflineAction' }) | Select-Object -First 1; if ($chk) { $vms = @("$($chk.FixArg)".Split(',') | Where-Object { $_ }) } }
          if (-not $p.Blocked -and -not $vms.Count) { $p.Blocked = Get-Text 'VdiBlkNothing' }
          $p.Text = Get-Text 'VdiConfOfflineAction' ($vms -join ', ')
          $p.Steps = @(New-HealthStep 'cluster OfflineAction 2' $node 'OfflineAction' @($vms -join ','))
          $p.Log = "cluster OfflineAction 2 (shut down, never save) for $($vms -join ', ')"
        }
        'ClusterDrainOnShutdown' {
          if (-not $p.Blocked -and $c -and [int]$c.DrainOnShutdown -eq 1) { $p.Blocked = Get-Text 'VdiBlkNothing' }
          $p.Text = Get-Text 'HcConfDrainShutdown' $where
          $p.Steps = @(New-HealthStep 'DrainOnShutdown 1' $node 'DrainOnShutdown' @())
          $p.Log = "cluster $where`: DrainOnShutdown = 1"
        }
        'ClusterGroupStart' {
          if (-not $arg) { $p.Blocked = Get-Text 'VdiBlkNothing' }
          $p.Text = Get-Text 'HcConfGroupStart' $arg $where
          $p.Steps = @(New-HealthStep "start role $arg" $node 'GroupStart' @([string]$arg))
          $p.Log = "start the cluster role $arg of $where"
        }
      }
    }
    { $_ -in 'HostDrain', 'HostResume' } {
      $c = if ($n.Parent -like 'cluster:*') { $m.Index[$n.Parent].Data } else { $null }
      $me = if ($c) { @($c.Nodes | Where-Object { (Get-HcShort $_.Name) -eq $n.Name }) | Select-Object -First 1 } else { $null }
      if (-not $c -or -not $me) { $p.Blocked = Get-Text 'HcBlkNoCluster' $where }
      elseif (-not $d.Reachable) { $p.Blocked = Get-Text 'VdiBlkUnreachable' $where }
      elseif ($kind -eq 'HostResume') {
        if ($me.State -ne 'Paused') { $p.Blocked = Get-Text 'HcBlkNotPaused' $where $me.State }
        $p.Text = Get-Text 'HcConfResume' $where
        $p.Steps = @(New-HealthStep 'resume node' $fq 'Resume' @())
        $p.Log = "resume the cluster node $where, its VMs back (failback)"
      } else {
        # the checks of a node to be emptied: the others up, the witness online, no storage repair, room for its VMs
        $p.DefaultNo = $true
        $others = @($c.Nodes | Where-Object { (Get-HcShort $_.Name) -ne $n.Name })
        $down = @($others | Where-Object { $_.State -ne 'Up' })
        $need = (@(@($d.Vms | Where-Object { $_ -and $_.State -eq 'Running' -and $_.Clustered }) | ForEach-Object { [double]$_.MemoryMB }) + 0 | Measure-Object -Sum).Sum / 1024
        $free = (@($m.Nodes | Where-Object { $_.Kind -eq 'host' -and $_.Parent -eq $n.Parent -and $_.Id -ne $n.Id -and $_.Data.Reachable } | ForEach-Object { [double]$_.Data.MemFreeMB }) + 0 | Measure-Object -Sum).Sum / 1024
        if ($me.State -ne 'Up') { $p.Blocked = Get-Text 'HcBlkNodeNotUp' $where $me.State }
        elseif (-not $others.Count) { $p.Blocked = Get-Text 'HcBlkOnlyNode' $where }
        elseif ($down.Count) { $p.Blocked = Get-Text 'HcBlkOtherDown' (($down | ForEach-Object { "$(Get-HcShort $_.Name) ($($_.State))" }) -join ', ') }
        elseif ($c.Witness -and $c.Witness.State -ne 'Online') { $p.Blocked = Get-Text 'HcBlkWitness' $c.Witness.State }
        elseif (-not $c.Witness -and @($c.Nodes).Count -eq 2) { $p.Blocked = Get-Text 'HcBlkNoWitness' }
        elseif (@($c.Jobs | Where-Object { $_ }).Count) { $p.Blocked = Get-Text 'HcBlkJobs' @($c.Jobs).Count }
        elseif ($need -gt $free) { $p.Blocked = Get-Text 'HcBlkRoom' (Format-HcSize $need) (Format-HcSize $free) }
        $vmn = @(@($d.Vms | Where-Object { $_ -and $_.State -eq 'Running' -and $_.Clustered })).Count
        $p.Text = Get-Text 'HcConfDrain' $where $vmn (Format-HcSize $need) (Format-HcSize $free)
        $p.Steps = @(New-HealthStep 'drain node' $fq 'Drain' @())
        $p.Log = "drain the cluster node $where ($vmn running VMs moved live, the node paused)"
      }
    }
    { $_ -in 'VmStart', 'VmRestart', 'VmShutdown', 'VmResume', 'VmRoleOnline', 'VmRemoveCheckpoints', 'VmStopAction' } {
      $v = $d; $hf = [string]$n.HostFqdn; $h = $n.Host
      $users = @(Get-HealthUsersOf $state $n.Name)
      $who = if ($users.Count) { Get-Text 'VdiConfVmUsers' ($users -join ', ') } else { Get-Text 'VdiConfVmNoUsers' }
      if (-not $hf) { $p.Blocked = Get-Text 'VdiBlkUnreachable' $h }
      switch ($kind) {
        'VmStart' {
          if (-not $p.Blocked -and $v.State -eq 'Running') { $p.Blocked = Get-Text 'VdiBlkRunningVm' $n.Name }
          $p.Text = Get-Text 'VdiConfVmStart' $n.Name $h $(if ($v.State -eq 'Saved' -and $v.Tpm) { Get-Text 'VdiConfSavedTpm' } else { '' })
          $p.Steps = @(New-HealthStep 'VM start' $hf 'VmPower' @($n.Name, 'start', 300)); $p.Log = "VM $($n.Name) on ${h}: start"
        }
        { $_ -in 'VmRestart', 'VmShutdown' } {
          $p.Destructive = $true; $p.DefaultNo = [bool]$users.Count
          if (-not $p.Blocked -and $v.State -ne 'Running') { $p.Blocked = Get-Text 'VdiBlkNotRunning' $n.Name }
          $act = if ($kind -eq 'VmRestart') { 'restart' } else { 'shutdown' }
          $p.Text = Get-Text $(if ($kind -eq 'VmRestart') { 'VdiConfVmRestart' } else { 'VdiConfVmShutdown' }) $n.Name $h $who
          $p.Steps = @(New-HealthStep "VM $act" $hf 'VmPower' @($n.Name, $act, 300))
          $p.Log = "VM $($n.Name) on ${h}: $act (a shutdown of Windows, never saved)$(if ($users.Count) { "; signed in: $($users -join ', ')" })"
        }
        'VmResume' {
          if (-not $p.Blocked -and $v.State -ne 'Paused') { $p.Blocked = Get-Text 'HcBlkNotPausedVm' $n.Name }
          $p.Text = Get-Text 'HcConfVmResume' $n.Name $h
          $p.Steps = @(New-HealthStep 'VM resume' $hf 'VmResume' @($n.Name)); $p.Log = "VM $($n.Name) on ${h}: resume"
        }
        'VmRoleOnline' {
          if (-not $p.Blocked -and -not ($v.Clustered -and $v.State -eq 'Running' -and $v.ResourceState -ne 'Online')) { $p.Blocked = Get-Text 'VdiBlkNothing' }
          $p.Text = Get-Text 'HcConfRoleOnline' $n.Name
          $p.Steps = @(New-HealthStep 'cluster role online' $hf 'RoleOnline' @($n.Name)); $p.Log = "VM $($n.Name): its cluster role online again"
        }
        'VmRemoveCheckpoints' {
          if (-not $p.Blocked -and [int]$v.Checkpoints -lt 1) { $p.Blocked = Get-Text 'VdiBlkNothing' }
          $p.DefaultNo = $true
          $p.Text = Get-Text 'HcConfCheckpoints' $n.Name $script:HealthLimits.CheckpointDays
          $p.Steps = @(New-HealthStep 'remove checkpoints' $hf 'RemoveCheckpoints' @($n.Name, $script:HealthLimits.CheckpointDays))
          $p.Log = "VM $($n.Name): remove the checkpoints older than $($script:HealthLimits.CheckpointDays) days (merged into the disks)"
        }
        'VmStopAction' {
          if (-not $p.Blocked -and $v.Clustered) { $p.Blocked = Get-Text 'HcBlkClustered' $n.Name }
          $p.Text = Get-Text 'HcConfStopAction' $n.Name
          $p.Steps = @(New-HealthStep 'automatic stop action' $hf 'StopAction' @($n.Name)); $p.Log = "VM $($n.Name): AutomaticStopAction ShutDown"
        }
      }
    }
    'DcSyncAll' {
      if (-not $fq) { $p.Blocked = Get-Text 'VdiBlkUnreachable' $where }
      $p.Text = Get-Text 'HcConfSyncAll' $where
      $p.Steps = @(New-HealthStep 'replicate now' $fq 'SyncAll' @()); $p.Log = "replicate AD now from $where (repadmin /syncall /AdeP)"
    }
    'DnsReverseZone' {
      $dc = @($m.Nodes | Where-Object { $_.Kind -eq 'dc' -and $_.Data.Reachable } | Sort-Object { if (@($_.Facts | Where-Object { $_.Value -match 'PDC' }).Count) { 0 } else { 1 } }) | Select-Object -First 1
      if (-not $dc) { $p.Blocked = Get-Text 'HcBlkNoDc' }
      elseif ("$arg" -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}$') { $p.Blocked = Get-Text 'VdiBlkNothing' }
      $p.Text = Get-Text 'HcConfReverse' "$arg.0/24" $(if ($dc) { $dc.Name })
      $p.Steps = @(New-HealthStep 'reverse zone' $(if ($dc) { $dc.Fqdn } else { '' }) 'ReverseZone' @([string]$arg)); $p.Log = "create the reverse DNS zone of $arg.0/24 (AD-integrated, secure updates)"
    }
    'SqlResume' {
      $srv = [string]$n.Name
      $p.Text = Get-Text 'HcConfSqlResume' $arg $srv
      $p.Steps = @(New-HealthStep 'resume data movement' '' 'SqlResume' @($srv, [string]$arg)); $p.Log = "resume the data movement of $arg on $srv (ALTER DATABASE ... SET HADR RESUME)"
    }
    'DeviceWake' {
      $p.Safe = $true
      if (-not $d.Mac) { $p.Blocked = Get-Text 'HcBlkNoMac' $where }
      elseif ($d.Ping -or @($d.Ports | Where-Object { $_.Open }).Count) { $p.Blocked = Get-Text 'HcBlkAnswers' $where }
      $p.Text = Get-Text 'HcConfWake' $where $d.Mac
      $p.Steps = @(New-HealthStep 'Wake-on-LAN' '' 'Wake' @([string]$d.Mac, [string]$d.Address)); $p.Log = "Wake-on-LAN for $where ($($d.Mac))"
    }
    default { $p.Blocked = Get-Text 'VdiBlkUnknown' $kind }
  }
  # never two servers of the same role at once: two DCs, two SQL replicas, two brokers, two nodes
  if (-not $p.Blocked -and $p.Role) {
    $busy = @($state.Recent | Where-Object { $_ -and $_.Role -eq $p.Role -and $_.Target -ne $target -and ($now - $_.Time).TotalMinutes -lt $script:HealthRoleMinutes }) | Select-Object -First 1
    if ($busy) { $p.Blocked = Get-Text 'HcBlkRole' $busy.Name (Format-VdiClock $busy.Time $now) }
  }
  if (-not $p.Blocked -and $p.Destructive -and (Test-VdiStale $state.Received $now)) { $p.Blocked = Get-Text 'VdiBlkStale' (Format-VdiClock $state.Received $now) }
  if (@($p.Steps).Count -eq 1) { $p.Steps[0].Label = $p.Title }
  $p
}
# the plan of the fix of a check: the Health Center's, or the one of the Desktops page for its findings
function Get-HealthCheckPlan($check, $state, [datetime]$now) {
  if ($check.Source -eq 'vdi') {
    $vs = @{ Model = $state.Vdi; Received = $state.VdiReceived; Running = $state.Running }
    $p = Get-VdiActionPlan $check.Fix $check.Where $vs $now $check.FixArg
    $p | Add-Member -NotePropertyName Safe -NotePropertyValue (@($script:HealthVdiSafe) -contains $check.Fix) -Force
    $p | Add-Member -NotePropertyName Source -NotePropertyValue 'vdi' -Force
    $p | Add-Member -NotePropertyName Role -NotePropertyValue $(if ($check.Fix -like 'Broker*') { 'broker' } else { 'host' }) -Force
    if (-not $p.Blocked -and $p.Role -eq 'broker') {
      $busy = @($state.Recent | Where-Object { $_ -and $_.Role -eq 'broker' -and $_.Name -ne $check.Where -and ($now - $_.Time).TotalMinutes -lt $script:HealthRoleMinutes }) | Select-Object -First 1
      if ($busy) { $p.Blocked = Get-Text 'HcBlkRole' $busy.Name (Format-VdiClock $busy.Time $now) }
    }
    return $p
  }
  Get-HealthActionPlan $check.Fix $check.Node $state $now $check.FixArg
}
# The repairs that run by themselves now: the safe fixes of the problems of the items in repair mode, not tried in the
# last $script:HealthRetryMinutes, one server per role (two DCs, two SQL replicas, two brokers never in the same round).
# $tried: key -> time of the last try.
function Get-HealthAutoPlans($state, $settings, [datetime]$now, [hashtable]$tried) {
  $m = $state.Model; $out = New-Object Collections.ArrayList; $roles = @{}; $keys = @{}
  if (-not $m -or $m.Access -ne 'ok' -or $state.Running) { return @() }
  foreach ($pr in @($m.Problems)) {
    $c = $pr.Check; $n = $pr.Node
    if (-not $c.Fix) { continue }
    if ((Get-HealthEffectiveMode $m $settings $n.Id) -ne 'repair') { continue }
    $p = Get-HealthCheckPlan $c $state $now
    if (-not $p.Safe -or $p.Blocked) { continue }
    $key = "$($c.Fix)|$($n.Id)|$($c.FixArg)"
    if ($keys.ContainsKey($key)) { continue }
    if ($tried -and $tried.ContainsKey($key) -and ($now - $tried[$key]).TotalMinutes -lt $script:HealthRetryMinutes) { continue }
    # one server per role in a round (several repairs of the same server are fine)
    if ($p.Role -and $p.Role -ne 'host' -and $roles.ContainsKey($p.Role) -and $roles[$p.Role] -ne $n.Id) { continue }
    $p | Add-Member -NotePropertyName Key -NotePropertyValue $key -Force
    $p | Add-Member -NotePropertyName RoleName -NotePropertyValue $n.Name -Force
    $keys[$key] = 1; if ($p.Role) { $roles[$p.Role] = $n.Id }
    [void]$out.Add($p)
  }
  @($out)
}
# a step in words, with what the server answered
function Format-HealthStepResult($r) {
  if ($r.Data -and $r.Data.PSObject.Properties['Lines']) {
    $where = if ($r.Computer) { Get-VdiShort $r.Computer } else { Get-Text 'VdiHere' }
    $n = if ($r.Label) { $r.Label } else { $r.Name }
    $l = @($(if ($r.Ok) { Get-Text 'VdiResOk' $n $where } else { Get-Text 'VdiResFail' $n $where $(if ($r.Error) { $r.Error } else { '?' }) }))
    foreach ($x in @($r.Data.Lines | Where-Object { $_ })) { $l += "   $x" }
    return $l
  }
  Format-VdiStepResult $r
}
