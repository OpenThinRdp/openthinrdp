<#
  The Windows side of the VDI for the OpenThinRDP manager: Remote Desktop brokers, Hyper-V hosts, the desktops and
  the sessions of the users, next to the devices they sign in from. Dot-sourced by OpenThinRDP-Manager.ps1; nothing
  here draws a window (the pages are in the manager).

  Three parts:
    the probe     ($script:VdiProbe) runs in a background runspace and reads the servers: one WinRM call per broker
                  and per host (in parallel), the sessions of the desktops through the WTS API, the event logs of the
                  devices. It returns plain data (strings, numbers, arrays): the same shape comes back from a JSON
                  file (OTR_MANAGER_VDI_DEMO, tests), so everything after it can be tested without a server.
    the model     (ConvertTo-VdiModel) joins that data: device -> user -> personal desktop -> host -> VM -> session ->
                  last sign-in, and the findings on brokers and hosts, each in one sentence of the window language.
    the actions   (Get-VdiActionPlan) say exactly what they will do and to whom, and refuse what is not safe now;
                  $script:VdiJobRunner runs them in the background, or only says what it would do
                  (OTR_MANAGER_VDI_DRYRUN=1).

  Why WinRM and CIM rather than the RDS cmdlets: the RemoteDesktop cmdlets answer only on the ACTIVE management server
  and only when run there (a second hop loses the credentials), and on any other broker they report "no deployment".
  What they would read is in WMI on every broker anyway:
    root\cimv2                   Win32_SessionDirectorySessionEx   the sessions (user, VM, host, state), any broker
    root\cimv2\TerminalServices  Win32_RDPersonalDesktopAssignment who owns which personal desktop, any broker
    root\cimv2\rdms              Win32_RDMSEnvironment.GetActiveServer  the active management server, any broker
                                 Win32_RDMSVirtualDesktop, Win32_RDMSJoinedNode, collections, session hosts: only on
                                 the active management server ("privilege not held" elsewhere)
  The session directory has no idle or disconnect time (IdleTime is always 0): those come from the desktop itself,
  through the WTS API (what quser and logoff use), which also logs off, disconnects and sends messages.
#>

# ---------------------------------------------------------------------------------------------
# WTS API: the sessions of a desktop (state, logon, last input, disconnection), log off, disconnect, message. Over RPC
# to the desktop like quser.exe, with a time limit: a desktop that does not answer must not hold the refresh.
# ---------------------------------------------------------------------------------------------
if (-not ('OtrWts' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
public static class OtrWts {
    public class Session {
        public int Id; public int State; public string User; public string Domain; public string Station;
        public DateTime Logon; public DateTime LastInput; public DateTime Disconnect; public DateTime Now;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WTS_SESSION_INFO { public int SessionId; public IntPtr WinStationName; public int State; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WTSINFO {
        public int State; public int SessionId;
        public int IncomingBytes, OutgoingBytes, IncomingFrames, OutgoingFrames, IncomingCompressedBytes, OutgoingCompressedBytes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string WinStationName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 17)] public string Domain;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 21)] public string UserName;
        public long ConnectTime, DisconnectTime, LastInputTime, LogonTime, CurrentTime;
    }
    [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr WTSOpenServer(string name);
    [DllImport("wtsapi32.dll")] static extern void WTSCloseServer(IntPtr h);
    [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool WTSEnumerateSessions(IntPtr h, int reserved, int version, out IntPtr info, out int count);
    [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool WTSQuerySessionInformation(IntPtr h, int id, int cls, out IntPtr buf, out int bytes);
    [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr p);
    [DllImport("wtsapi32.dll", SetLastError = true)] static extern bool WTSLogoffSession(IntPtr h, int id, bool wait);
    [DllImport("wtsapi32.dll", SetLastError = true)] static extern bool WTSDisconnectSession(IntPtr h, int id, bool wait);
    [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool WTSSendMessage(IntPtr h, int id, string title, int titleBytes, string text, int textBytes, int style, int timeout, out int response, bool wait);
    static DateTime Time(long t) { return t == 0 ? DateTime.MinValue : DateTime.FromFileTimeUtc(t).ToLocalTime(); }
    static T Within<T>(Func<T> f, int ms, string server) {
        Task<T> t = Task.Factory.StartNew(f);
        try { if (!t.Wait(ms)) throw new TimeoutException(server + ": no answer in " + (ms / 1000) + " s"); }
        catch (AggregateException e) { throw e.InnerException; }
        return t.Result;
    }
    // the sessions with a user (not the listeners, services and console without one)
    public static Session[] Query(string server, int ms) {
        return Within(delegate {
            List<Session> o = new List<Session>();
            IntPtr h = WTSOpenServer(server);
            try {
                IntPtr p; int n;
                if (!WTSEnumerateSessions(h, 0, 1, out p, out n)) throw new System.ComponentModel.Win32Exception();
                try {
                    int sz = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
                    for (int i = 0; i < n; i++) {
                        WTS_SESSION_INFO s = (WTS_SESSION_INFO)Marshal.PtrToStructure(new IntPtr(p.ToInt64() + i * sz), typeof(WTS_SESSION_INFO));
                        IntPtr b; int bytes;
                        if (!WTSQuerySessionInformation(h, s.SessionId, 24, out b, out bytes)) continue;
                        WTSINFO w = (WTSINFO)Marshal.PtrToStructure(b, typeof(WTSINFO));
                        WTSFreeMemory(b);
                        if (string.IsNullOrEmpty(w.UserName)) continue;
                        Session x = new Session();
                        x.Id = w.SessionId; x.State = w.State; x.User = w.UserName; x.Domain = w.Domain; x.Station = w.WinStationName;
                        x.Logon = Time(w.LogonTime); x.LastInput = Time(w.LastInputTime); x.Disconnect = Time(w.DisconnectTime); x.Now = Time(w.CurrentTime);
                        o.Add(x);
                    }
                } finally { WTSFreeMemory(p); }
            } finally { WTSCloseServer(h); }
            return o.ToArray();
        }, ms, server);
    }
    static bool Do(string server, int ms, Func<IntPtr, bool> f) {
        return Within(delegate {
            IntPtr h = WTSOpenServer(server);
            try { if (!f(h)) throw new System.ComponentModel.Win32Exception(); return true; } finally { WTSCloseServer(h); }
        }, ms, server);
    }
    public static bool Logoff(string server, int id) { return Do(server, 20000, delegate(IntPtr h) { return WTSLogoffSession(h, id, false); }); }
    public static bool Disconnect(string server, int id) { return Do(server, 20000, delegate(IntPtr h) { return WTSDisconnectSession(h, id, false); }); }
    // a message box in the session; returns at once (does not wait for the user to close it)
    public static bool Message(string server, int id, string title, string text) {
        return Do(server, 20000, delegate(IntPtr h) { int r; return WTSSendMessage(h, id, title, title.Length * 2, text, text.Length * 2, 0x40, 0, out r, false); });
    }
}
'@
}

# ---------------------------------------------------------------------------------------------
# Settings of the Desktops page: in the manager's own settings (%APPDATA%\OpenThinRDP\manager.json), not in the
# management folder: they are for the administrator's PC and account, and the devices have nothing to do with them.
#   Enabled      $false = the page shows only what the devices report, nothing is asked to the servers
#   BrokerGroup  the AD group that holds the brokers (DOMAIN\RDS-Brokers): the host permissions are repaired by
#                adding this group, never single computers, when it is set
#   Brokers      brokers to read besides those found through the devices (BROKER, BROKER_FALLBACK) and the deployment
#   Hosts        Hyper-V hosts to read besides those the deployment and the clusters name
# ---------------------------------------------------------------------------------------------
$script:VdiGroupSids = @('S-1-5-32-576', 'S-1-5-32-577', 'S-1-5-32-578')
# their English names, for config\changes.log (the window says them in its language)
$script:VdiGroupEn = @{ 'S-1-5-32-576' = 'RDS Endpoint Servers'; 'S-1-5-32-577' = 'RDS Management Servers'; 'S-1-5-32-578' = 'Hyper-V Administrators' }
$script:VdiRepairTask = 'OpenThinRDP - Broker self-repair'
$script:VdiRepairFile = 'C:\ProgramData\OpenThinRDP\Broker-SelfRepair.ps1'
$script:VdiRepairScript = Join-Path $PSScriptRoot 'rds\Broker-SelfRepair.ps1'
$script:VdiInstallScript = Join-Path $PSScriptRoot 'rds\Install-BrokerSelfRepair.ps1'
$script:VdiRefreshSeconds = 120
# older data than this = the actions that stop or end something are not offered: they would act on what was true then
$script:VdiStaleMinutes = 5
function Read-ManagerSettings {
  try { if (Test-Path -LiteralPath $script:SettingsFile) { $j = Get-Content -LiteralPath $script:SettingsFile -Raw | ConvertFrom-Json; if ($j) { return $j } } } catch { }
  New-Object psobject
}
function Save-ManagerSettings($obj) {
  $d = Split-Path $script:SettingsFile
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
  [IO.File]::WriteAllText($script:SettingsFile, ($obj | ConvertTo-Json -Depth 5), $script:Utf8)
}
function Set-ManagerSetting($obj, [string]$name, $value) {
  if ($obj.PSObject.Properties[$name]) { $obj.$name = $value } else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}
function Get-VdiSettings {
  $s = [pscustomobject]@{ Enabled = $true; BrokerGroup = ''; Brokers = ''; Hosts = '' }
  $m = Read-ManagerSettings
  if ($m.PSObject.Properties['Desktops'] -and $m.Desktops) {
    foreach ($k in 'Enabled', 'BrokerGroup', 'Brokers', 'Hosts') { if ($m.Desktops.PSObject.Properties[$k]) { $s.$k = $m.Desktops.$k } }
  }
  $s.Enabled = [bool]$s.Enabled
  $s
}
# $null = saved, else the reason (a name the devices could not use would never be found either)
function Test-VdiSettings($s) {
  foreach ($n in (Split-List $s.Brokers) + (Split-List $s.Hosts)) { if ($n -cnotmatch $script:Rx.Name) { return (Get-Text 'VdiErrName' $n) } }
  if ($s.BrokerGroup -and $s.BrokerGroup -notmatch '^([A-Za-z0-9._-]+\\)?[A-Za-z0-9 ._-]{1,64}$') { return (Get-Text 'VdiErrGroup' $s.BrokerGroup) }
  $null
}
function Save-VdiSettings($s) {
  $m = Read-ManagerSettings
  Set-ManagerSetting $m 'Desktops' ([pscustomobject]@{ Enabled = [bool]$s.Enabled; BrokerGroup = [string]$s.BrokerGroup.Trim()
    Brokers = ((Split-List $s.Brokers) -join ' '); Hosts = ((Split-List $s.Hosts) -join ' ') })
  Save-ManagerSettings $m
}

# ---------------------------------------------------------------------------------------------
# The probe. Input ($cfg): BrokerNames (what the devices and the settings name: shared names, addresses, servers),
# Hosts, BrokerGroup, StatusDir and Devices (their event logs), RepairTask/RepairFile, OpenMs/OperationMs.
# Every part that fails leaves a note and the rest goes on: one host switched off must not hide the others.
# ---------------------------------------------------------------------------------------------
$script:VdiProbe = {
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
  # one WinRM call to many servers at once: Res = short name -> answer, Fail = short name -> 'denied' or the reason
  function Invoke-Many($computers, $sb, $argList) {
    $res = @{}; $fail = @{}
    $computers = @($computers | Where-Object { $_ } | Select-Object -Unique)
    if (-not $computers.Count) { return @{ Res = $res; Fail = $fail } }
    $ev = $null
    $out = @(Invoke-Command -ComputerName $computers -ScriptBlock $sb -ArgumentList $argList -SessionOption $so -ThrottleLimit 16 -ErrorAction SilentlyContinue -ErrorVariable ev)
    foreach ($o in $out) { if ($o -and $o.PSComputerName) { $res[(Short $o.PSComputerName)] = $o } }
    foreach ($e in @($ev)) {
      if ($e.FullyQualifiedErrorId -notmatch 'PSSessionStateBroken|ComputerNotFound|AccessDenied|WinRM|RemotingTransport' -and -not ($e.Exception -is [System.Management.Automation.Remoting.PSRemotingTransportException])) { continue }
      $t = [string]$e.TargetObject; if (-not $t) { $t = [string]$e.CategoryInfo.TargetName }; if (-not $t) { continue }
      $why = if ($e.FullyQualifiedErrorId -match 'AccessDenied') { 'denied' } else { (([string]$e.Exception.Message) -split "`n")[0].Trim() }
      if (-not $res.ContainsKey((Short $t))) { $fail[(Short $t)] = $why }
    }
    @{ Res = $res; Fail = $fail }
  }

  # ---- what runs on a broker
  $brokerSb = {
    param($repairTask, $repairFile)
    $ErrorActionPreference = 'SilentlyContinue'
    function Iso($d) { if ($d) { ([datetime]$d).ToString('yyyy-MM-ddTHH:mm:ss') } else { $null } }
    $svc = @(foreach ($n in 'Tssdis', 'RDMS', 'TScPubRPC') {
      $w = Get-CimInstance Win32_Service -Filter "Name='$n'"
      if (-not $w) { [pscustomobject]@{ Name = $n; State = 'Missing'; Since = $null }; continue }
      $st = $null; if ($w.ProcessId) { $p = Get-Process -Id $w.ProcessId; if ($p) { $st = Iso $p.StartTime } }
      [pscustomobject]@{ Name = $n; State = ([string]$w.State -replace ' ', ''); Since = $st }
    })
    # counted from midnight, or from the last start of Tssdis when later: failures before a restart are history
    $since = (Get-Date).Date
    $t = ($svc | Where-Object Name -eq 'Tssdis').Since; if ($t -and [datetime]$t -gt $since) { $since = [datetime]$t }
    $op = 'Microsoft-Windows-TerminalServices-SessionBroker/Operational'; $ad = 'Microsoft-Windows-TerminalServices-SessionBroker/Admin'
    $n800 = @(Get-WinEvent -FilterHashtable @{ LogName = $op; Id = 800; StartTime = $since }).Count
    $e802 = @(Get-WinEvent -FilterHashtable @{ LogName = $ad; Id = 802; StartTime = $since })
    $e804 = @(Get-WinEvent -FilterHashtable @{ LogName = $ad; Id = 804; StartTime = $since })
    $denied = @($e804 | Where-Object { $_.Properties.Count -gt 1 -and "$($_.Properties[1].Value)" -eq '-2147024891' }).Count
    $db = @(Get-WinEvent -FilterHashtable @{ LogName = $ad; Id = 2048, 2072; StartTime = $since }).Count
    # the requests of the last 24 hours with their user: 801 = served (user, desktop), 802 = failed (user, reason)
    $day = (Get-Date).AddHours(-24)
    $req = @(@(Get-WinEvent -FilterHashtable @{ LogName = $op; Id = 801; StartTime = $day } -MaxEvents 300 | ForEach-Object {
          [pscustomobject]@{ Time = Iso $_.TimeCreated; User = "$($_.Properties[0].Value)"; Vm = "$($_.Properties[1].Value)"; Ok = $true; Why = '' } }) +
      @(Get-WinEvent -FilterHashtable @{ LogName = $ad; Id = 802; StartTime = $day } -MaxEvents 300 | ForEach-Object {
          [pscustomobject]@{ Time = Iso $_.TimeCreated; User = "$($_.Properties[0].Value)"; Vm = ''; Ok = $false; Why = ("$($_.Properties[1].Value)").Trim() } }))
    # the signature of the fault that fails everything: tssdis presents itself with the computer name WITHOUT the $
    # (4648 of NETWORK SERVICE), then "unknown user" (4625, 0xC0000064). Never seen on a healthy broker.
    $x = "<QueryList><Query Id='0' Path='Security'><Select Path='Security'>*[System[EventID=4648 and TimeCreated[timediff(@SystemTime) &lt;= 86400000]]] and *[EventData[Data[@Name='SubjectUserSid']='S-1-5-20' and Data[@Name='TargetUserName']='$env:COMPUTERNAME']]</Select></Query></QueryList>"
    $sig = @(Get-WinEvent -FilterXml $x | Where-Object { $_.Properties.Count -gt 11 -and "$($_.Properties[11].Value)" -like '*\tssdis.exe' })
    $x2 = "<QueryList><Query Id='0' Path='Security'><Select Path='Security'>*[System[EventID=4625 and TimeCreated[timediff(@SystemTime) &lt;= 86400000]]] and *[EventData[Data[@Name='SubStatus']='0xc0000064' and Data[@Name='TargetUserName']='$env:COMPUTERNAME']]</Select></Query></QueryList>"
    $unknown = @(Get-WinEvent -FilterXml $x2).Count
    $active = $null
    try { $active = [string](Invoke-CimMethod -Namespace root\cimv2\rdms -ClassName Win32_RDMSEnvironment -MethodName GetActiveServer -ErrorAction Stop).ServerName } catch { }
    $isActive = [bool]($active -and (($active -split '\.')[0] -ieq $env:COMPUTERNAME))
    $sessions = @(Get-CimInstance -Namespace root\cimv2 -ClassName Win32_SessionDirectorySessionEx | ForEach-Object {
      [pscustomobject]@{ User = "$($_.UserName)"; Domain = "$($_.DomainName)"; Vm = "$($_.ServerName)"; Host = "$($_.HostServer)"; Ip = "$($_.ServerIPAddress)"
        State = [int]$_.SessionState; Id = [int]$_.SessionID; Created = Iso $_.CreateTime; Collection = "$($_.CollectionAlias)"; Type = [int]$_.CollectionType } })
    $assign = @(Get-CimInstance -Namespace root\cimv2\TerminalServices -ClassName Win32_RDPersonalDesktopAssignment | ForEach-Object {
      [pscustomobject]@{ User = "$($_.UserName)"; Domain = "$($_.DomainName)"; Vm = "$($_.VMName)"; Collection = "$($_.FarmAlias)" } })
    $desktops = @(); $nodes = @(); $colls = @(); $rdsh = @()
    if ($isActive) {
      $desktops = @(Get-CimInstance -Namespace root\cimv2\rdms -ClassName Win32_RDMSVirtualDesktop | ForEach-Object {
        [pscustomobject]@{ Name = "$($_.Name)"; Host = "$($_.HostName)"; Collection = "$($_.CollectionAlias)"; User = "$($_.UserName)"; Domain = "$($_.UserDomain)" } })
      $nodes = @(Get-CimInstance -Namespace root\cimv2\rdms -ClassName Win32_RDMSJoinedNode | ForEach-Object {
        [pscustomobject]@{ Fqdn = "$($_.FQDN)"; Rdcb = [bool]$_.IsRdcb; Rdvh = [bool]$_.IsRdvh; Rdsh = [bool]$_.IsRdsh } })
      $colls = @(@(Get-CimInstance -Namespace root\cimv2\rdms -ClassName Win32_RDMSVirtualDesktopCollection | ForEach-Object {
          [pscustomobject]@{ Alias = "$($_.Alias)"; Name = "$($_.Name)"; Kind = 'vm' } }) +
        @(Get-CimInstance -Namespace root\cimv2\rdms -ClassName Win32_RDSHCollection | ForEach-Object { [pscustomobject]@{ Alias = "$($_.Alias)"; Name = "$($_.Name)"; Kind = 'rdsh' } }))
      $rdsh = @(Get-CimInstance -Namespace root\cimv2\rdms -ClassName Win32_RDSHServer | ForEach-Object { "$($_.Name)" })
    }
    # the self-repair: ours by name, or any task started by 4648 of tssdis.exe (a site may have one of its own)
    $tasks = @(Get-ScheduledTask | Where-Object { $_.TaskName -eq $repairTask -or @($_.Triggers | Where-Object { "$($_.Subscription)" -match 'tssdis\.exe' -and "$($_.Subscription)" -match '4648' }).Count })
    $ours = @($tasks | Where-Object TaskName -eq $repairTask) | Select-Object -First 1
    $hash = if (Test-Path -LiteralPath $repairFile) { (Get-FileHash -LiteralPath $repairFile -Algorithm SHA256).Hash } else { $null }
    $fqdn = try { [Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName } catch { $env:COMPUTERNAME }
    [pscustomobject]@{
      Fqdn = $fqdn; Ips = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | ForEach-Object IPAddress)
      Services = $svc; Since = Iso $since; Restarted = ($since -gt (Get-Date).Date); Received = $n800; Failed = [Math]::Max($e802.Count, $e804.Count); Denied = $denied; DbErrors = $db
      Requests = $req; Signature = $sig.Count; SignatureLast = $(if ($sig.Count) { Iso ($sig | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated }); Unknown = $unknown
      ActiveServer = $active; IsActive = $isActive; Sessions = $sessions; Assignments = $assign; Desktops = $desktops; Nodes = $nodes; Collections = $colls; Rdsh = $rdsh
      Task = [pscustomobject]@{ Names = @($tasks | ForEach-Object TaskName); Ours = [bool]$ours; State = $(if ($ours) { "$($ours.State)" } else { '' }); Hash = $hash }
    }
  }

  # ---- what runs on a Hyper-V host
  $hostSb = {
    $ErrorActionPreference = 'SilentlyContinue'
    function Iso($d) { if ($d) { ([datetime]$d).ToString('yyyy-MM-ddTHH:mm:ss') } else { $null } }
    $svc = @(foreach ($n in 'VmHostAgent', 'vmms', 'ClusSvc') {
      $w = Get-CimInstance Win32_Service -Filter "Name='$n'"
      if (-not $w) { [pscustomobject]@{ Name = $n; State = 'Missing'; Since = $null }; continue }
      [pscustomobject]@{ Name = $n; State = ([string]$w.State -replace ' ', ''); Since = $null }
    })
    # the brokers the RDVH agent may attach to (empty = it starts, says it is ready, and never attaches)
    $k = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\VmHostAgent\Parameters' -Name Tssdis
    $tss = if ($k) { [string]$k.Tssdis } else { $null }
    # the broker it is attached to NOW: its live connections (the last event can be days old)
    $agentPid = (Get-CimInstance Win32_Service -Filter "Name='VmHostAgent'").ProcessId
    $links = if ($agentPid) { @(Get-NetTCPConnection -State Established -OwningProcess $agentPid | ForEach-Object { "$($_.RemoteAddress)" } | Select-Object -Unique) } else { @() }
    $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-TerminalServices-TSV-VmHostAgent/Operational'; Id = 8451, 8452 } -MaxEvents 1
    $last = if ($ev) { [pscustomobject]@{ Time = Iso $ev.TimeCreated; Attached = ($ev.Id -eq 8451); Broker = "$($ev.Properties[0].Value)" } } else { $null }
    $groups = @(foreach ($sid in 'S-1-5-32-576', 'S-1-5-32-577', 'S-1-5-32-578') {
      $m = $null
      try { $m = @(Get-LocalGroupMember -SID $sid -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Sid = "$($_.SID)"; Name = "$($_.Name)" } }) }
      catch {
        # Get-LocalGroupMember stops at a member whose account is gone: the members through ADSI then
        try {
          $gn = (New-Object Security.Principal.SecurityIdentifier $sid).Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
          $g = [ADSI]"WinNT://$env:COMPUTERNAME/$gn,group"
          $m = @($g.Invoke('Members') | ForEach-Object {
            $b = $_.GetType().InvokeMember('objectSid', 'GetProperty', $null, $_, $null)
            [pscustomobject]@{ Sid = (New-Object Security.Principal.SecurityIdentifier($b, 0)).Value; Name = [string]$_.GetType().InvokeMember('Name', 'GetProperty', $null, $_, $null) } })
        } catch { $m = $null }
      }
      [pscustomobject]@{ Sid = $sid; Read = ($null -ne $m); Members = @($m) }
    })
    $vms = @(); $cluster = ''; $cnodes = @()
    if (Get-Command Get-VM) {
      # the cluster stops a VM role as OfflineAction says: 1 = save, which a VM with a vTPM may not come back from
      $oa = @{}; $cres = @()
      try {
        $cluster = [string](Get-Cluster -ErrorAction Stop).Name
        $cnodes = @(Get-ClusterNode | ForEach-Object { "$($_.Name)" })
        $cres = @(Get-ClusterResource | Where-Object { "$($_.ResourceType)" -eq 'Virtual Machine' })
        foreach ($r in $cres) { $oa["$($r.OwnerGroup)"] = [int]($r | Get-ClusterParameter -Name OfflineAction).Value }
      } catch { }
      $rstate = @{}; foreach ($r in $cres) { $rstate["$($r.OwnerGroup)"] = "$($r.State)" }
      $vms = @(Get-VM | ForEach-Object {
        $tpm = $false; try { $tpm = [bool](Get-VMSecurity -VM $_ -ErrorAction Stop).TpmEnabled } catch { }
        [pscustomobject]@{ Name = $_.Name; State = "$($_.State)"; Heartbeat = "$($_.Heartbeat)"; UptimeMin = [int]$_.Uptime.TotalMinutes; Clustered = [bool]$_.IsClustered; Tpm = $tpm
          OfflineAction = $(if ($oa.ContainsKey($_.Name)) { $oa[$_.Name] } else { $null }); Registered = $true; ClusterState = $(if ($rstate.ContainsKey($_.Name)) { $rstate[$_.Name] } else { '' }) } })
      # A role taken offline whole (group, configuration) is unregistered from Hyper-V: Get-VM lists it on no host. The
      # cluster still knows it, on the node that owns it: listed here as off, so that it can be started again.
      $known = @($vms | ForEach-Object Name)
      foreach ($r in @($cres | Where-Object { "$($_.OwnerNode)" -ieq $env:COMPUTERNAME -and $known -notcontains "$($_.OwnerGroup)" })) {
        $vms += [pscustomobject]@{ Name = "$($r.OwnerGroup)"; State = 'Off'; Heartbeat = ''; UptimeMin = 0; Clustered = $true; Tpm = $null
          OfflineAction = $oa["$($r.OwnerGroup)"]; Registered = $false; ClusterState = "$($r.State)" }
      }
    }
    $fqdn = try { [Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName } catch { $env:COMPUTERNAME }
    [pscustomobject]@{ Fqdn = $fqdn; Services = $svc; AgentBrokers = $tss; AgentLinks = $links; AgentLast = $last; Groups = $groups; Vms = $vms; Cluster = $cluster; ClusterNodes = $cnodes }
  }

  # ---- 1. the names the devices use, their addresses, and the broker behind each address
  $names = @(); $rev = @{}
  foreach ($n in @($cfg.BrokerNames | Where-Object { $_ } | Select-Object -Unique)) {
    $isIp = $n -match '^\d{1,3}(\.\d{1,3}){3}$'
    $ips = @()
    if ($isIp) { $ips = @($n) } else { try { $ips = @([Net.Dns]::GetHostAddresses($n) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString }) } catch { } }
    $addr = @(foreach ($ip in $ips) {
      if (-not $rev.ContainsKey($ip)) { $rev[$ip] = try { [Net.Dns]::GetHostEntry($ip).HostName } catch { $null } }
      [pscustomobject]@{ Ip = $ip; Fqdn = $rev[$ip]; Rdp = (Test-Tcp $ip 3389 1500) }
    })
    $names += [pscustomobject]@{ Name = $n; IsIp = $isIp; Addresses = $addr }
  }
  # ---- 2. the brokers: behind those addresses, in the settings, and (round 2) the brokers of the deployment
  $cand = [ordered]@{}
  $add = { param($n) if (-not $n -or $n -match '^\d{1,3}(\.\d{1,3}){3}$') { return }; $s = Short $n; if (-not $cand.Contains($s)) { $cand[$s] = $n } }
  foreach ($nm in $names) { foreach ($a in $nm.Addresses) { & $add $a.Fqdn } }
  # a listed name that resolves to a single address of its own is a broker itself (BROKER=rdcb1.example.com)
  foreach ($b in @($cfg.Brokers)) { $f = try { [Net.Dns]::GetHostEntry($b).HostName } catch { $b }; & $add $f }
  $args1 = @($cfg.RepairTask, $cfg.RepairFile)
  $br = Invoke-Many @($cand.Values) $brokerSb $args1
  $act = @($br.Res.Values | Where-Object { $_.IsActive }) | Select-Object -First 1
  if (-not $act) {
    # the active management server is named by every broker: it may be one the devices do not use
    $an = @($br.Res.Values | Where-Object { $_.ActiveServer } | ForEach-Object { $_.ActiveServer }) | Select-Object -First 1
    if ($an -and -not $cand.Contains((Short $an))) { & $add $an; $r2 = Invoke-Many @($an) $brokerSb $args1; foreach ($k in $r2.Res.Keys) { $br.Res[$k] = $r2.Res[$k] }; foreach ($k in $r2.Fail.Keys) { $br.Fail[$k] = $r2.Fail[$k] } }
    $act = @($br.Res.Values | Where-Object { $_.IsActive }) | Select-Object -First 1
  }
  if ($act) {
    $more = @($act.Nodes | Where-Object { $_.Rdcb -and -not $cand.Contains((Short $_.Fqdn)) } | ForEach-Object { $_.Fqdn })
    foreach ($m in $more) { & $add $m }
    if ($more.Count) { $r2 = Invoke-Many $more $brokerSb $args1; foreach ($k in $r2.Res.Keys) { $br.Res[$k] = $r2.Res[$k] }; foreach ($k in $r2.Fail.Keys) { $br.Fail[$k] = $r2.Fail[$k] } }
  }
  $brokers = @(foreach ($k in $cand.Keys) {
    $o = $br.Res[$k]
    if ($o) { $o | Add-Member -NotePropertyName Name -NotePropertyValue $k -Force; $o | Add-Member -NotePropertyName Reachable -NotePropertyValue $true -Force
      $o | Add-Member -NotePropertyName Error -NotePropertyValue $null -Force; $o }
    else { [pscustomobject]@{ Name = $k; Fqdn = $cand[$k]; Reachable = $false; Error = $(if ($br.Fail[$k]) { $br.Fail[$k] } else { 'unreachable' }) } }
  })
  # ---- 3. the hosts: settings, the deployment, where the desktops and sessions are, then the nodes of their clusters
  $hc = [ordered]@{}
  $addH = { param($n) if (-not $n) { return }; $s = Short $n; if (-not $hc.Contains($s)) { $hc[$s] = $n } }
  foreach ($h in @($cfg.Hosts)) { & $addH $h }
  if ($act) { foreach ($n in @($act.Nodes | Where-Object Rdvh)) { & $addH $n.Fqdn }; foreach ($d in @($act.Desktops)) { & $addH $d.Host } }
  foreach ($b in @($br.Res.Values)) { foreach ($s in @($b.Sessions)) { if ($s.Type -eq 2) { & $addH $s.Host } } }
  $hr = Invoke-Many @($hc.Values) $hostSb @()
  $more = @(foreach ($o in @($hr.Res.Values)) { foreach ($n in @($o.ClusterNodes)) { if (-not $hc.Contains((Short $n))) { & $addH $n; $n } } })
  if ($more.Count) { $r2 = Invoke-Many $more $hostSb @(); foreach ($k in $r2.Res.Keys) { $hr.Res[$k] = $r2.Res[$k] }; foreach ($k in $r2.Fail.Keys) { $hr.Fail[$k] = $r2.Fail[$k] } }
  $hosts = @(foreach ($k in $hc.Keys) {
    $o = $hr.Res[$k]
    if ($o) { $o | Add-Member -NotePropertyName Name -NotePropertyValue $k -Force; $o | Add-Member -NotePropertyName Reachable -NotePropertyValue $true -Force
      $o | Add-Member -NotePropertyName Error -NotePropertyValue $null -Force; $o }
    else { [pscustomobject]@{ Name = $k; Fqdn = $hc[$k]; Reachable = $false; Error = $(if ($hr.Fail[$k]) { $hr.Fail[$k] } else { 'unreachable' }) } }
  })
  # ---- 4. the SIDs that count for each broker on a host: its computer account and its groups (nested too)
  $bsids = @(foreach ($b in $brokers) {
    $sids = @()
    try {
      $ds = New-Object DirectoryServices.DirectorySearcher; $ds.Filter = "(&(objectCategory=computer)(sAMAccountName=$($b.Name)`$))"
      $r = $ds.FindOne()
      if ($r) {
        $sids += (New-Object Security.Principal.SecurityIdentifier([byte[]]$r.Properties['objectsid'][0], 0)).Value
        $de = $r.GetDirectoryEntry(); $de.RefreshCache([string[]]@('tokenGroups'))
        foreach ($t in $de.Properties['tokenGroups']) { $sids += (New-Object Security.Principal.SecurityIdentifier([byte[]]$t, 0)).Value }
      }
    } catch { [void]$notes.Add("AD $($b.Name): $($_.Exception.Message)") }
    [pscustomobject]@{ Broker = $b.Name; Sids = @($sids) }
  })
  $group = $null
  if ($cfg.BrokerGroup) {
    $gs = try { (New-Object Security.Principal.NTAccount $cfg.BrokerGroup).Translate([Security.Principal.SecurityIdentifier]).Value } catch { $null }
    $group = [pscustomobject]@{ Name = $cfg.BrokerGroup; Sid = $gs }
  }
  # ---- 5. the sessions of the desktops, from the desktops themselves (idle and disconnect times)
  $allVms = @(@($hosts | Where-Object Reachable | ForEach-Object { @($_.Vms | ForEach-Object Name) }))
  $vmNames = @(@($hosts | Where-Object Reachable | ForEach-Object { @($_.Vms | Where-Object { $_.State -eq 'Running' } | ForEach-Object Name) }))
  $wanted = @(@(@($br.Res.Values | ForEach-Object { @($_.Assignments | ForEach-Object Vm) + @($_.Sessions | ForEach-Object Vm) + @($_.Desktops | Where-Object Collection | ForEach-Object Name) })) |
    Where-Object { $_ } | ForEach-Object { $_.ToUpper() } | Select-Object -Unique)
  $wts = @(foreach ($v in $wanted) {
    # a VM the hosts list as not running has no session to read (and would only make us wait)
    if (@($allVms | Where-Object { $_ -ieq $v }).Count -and -not @($vmNames | Where-Object { $_ -ieq $v }).Count) { continue }
    if ($v -match '\s') { continue }
    try { $ss = @([OtrWts]::Query($v, 6000) | ForEach-Object {
          [pscustomobject]@{ Id = $_.Id; State = $_.State; User = $_.User; Domain = $_.Domain; Logon = $(if ($_.Logon -gt [datetime]::MinValue) { Iso $_.Logon })
            LastInput = $(if ($_.LastInput -gt [datetime]::MinValue) { Iso $_.LastInput }); Disconnect = $(if ($_.Disconnect -gt [datetime]::MinValue) { Iso $_.Disconnect }); Now = $(if ($_.Now -gt [datetime]::MinValue) { Iso $_.Now }) } })
          [pscustomobject]@{ Vm = $v; Ok = $true; Error = $null; Sessions = $ss } }
    catch { [pscustomobject]@{ Vm = $v; Ok = $false; Error = $_.Exception.Message; Sessions = @() } }
  })
  # ---- 6. the event logs of the devices (their sign-ins)
  $events = @(foreach ($d in @($cfg.Devices)) {
    $f = Join-Path $cfg.StatusDir "$d-events.log"
    $l = @(); try { if (Test-Path -LiteralPath $f) { $l = @([IO.File]::ReadAllLines($f) | Select-Object -Last 400) } } catch { }
    [pscustomobject]@{ Device = $d; Lines = $l }
  })
  [pscustomobject]@{ Taken = Iso (Get-Date); Names = $names; Brokers = $brokers; Hosts = $hosts; BrokerSids = $bsids; Group = $group; Wts = $wts; Events = $events; Notes = @($notes) }
}

# the input of the probe: the brokers named by the devices and the settings, the hosts of the settings
function Get-VdiProbeConfig($devices, $settings) {
  $names = @(); $devs = @()
  foreach ($d in @($devices | Where-Object { -not $_.OldName })) {
    $devs += $d.Name
    $names += @([string]$d.S['CFG_BROKER']) + @(Split-List ([string]$d.S['CFG_BROKER_FALLBACK']))
  }
  $names += @(Split-List $settings.Brokers)
  # the shared name of the brokers given in the settings of the Health Center, when the devices do not name it
  if (Get-Command Get-HealthSettings -ErrorAction SilentlyContinue) { $names += @(Split-List (Get-HealthSettings).BrokerName) }
  @{ BrokerNames = @($names | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Sort-Object -Unique); Brokers = @(Split-List $settings.Brokers); Hosts = @(Split-List $settings.Hosts)
     BrokerGroup = [string]$settings.BrokerGroup; StatusDir = $script:StatusDir; Devices = $devs; RepairTask = $script:VdiRepairTask; RepairFile = $script:VdiRepairFile
     OpenMs = 8000; OperationMs = 90000 }
}

# ---------------------------------------------------------------------------------------------
# The model
# ---------------------------------------------------------------------------------------------
function ConvertFrom-VdiTime($v) {
  if ($null -eq $v -or "$v" -eq '') { return $null }
  if ($v -is [datetime]) { return $v }
  try { [datetime]::ParseExact(([string]$v).Substring(0, 19), 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) } catch { $null }
}
# DOMAIN\user, user@domain.com and User are the same user
function Get-VdiUserKey([string]$u) {
  $u = "$u".Trim(); if ($u -match '\\') { $u = $u.Split('\')[-1] }; if ($u -match '@') { $u = $u.Split('@')[0] }
  $u.ToUpper()
}
# the user of a device: the one signed in now (SESSION=active (user)), else its default user
function Get-VdiDeviceUser($s) { if ([string]$s['SESSION'] -match '^active \((.+)\)$') { return $Matches[1] }; [string]$s['DEFAULT_USER'] }
function Get-VdiShort([string]$n) { if ($n -match '^\d{1,3}(\.\d{1,3}){3}$') { return $n }; ("$n" -split '\.')[0].ToUpper() }
# "45 min", "3 hours": the words of the window
function Format-VdiAge([datetime]$from, [datetime]$now) { Format-Minutes ([Math]::Max(0, [int]($now - $from).TotalMinutes)) }
function Format-VdiClock([datetime]$t, [datetime]$now) { if ($t.Date -eq $now.Date) { $t.ToString('HH:mm') } else { $t.ToString('dd/MM HH:mm') } }

# The sign-ins a device logged (kiosk.sh), oldest first. The broker is the server the device really reached: the
# "broker X: connecting to Y" line just before (X is the shared name, Y the broker behind it).
function Get-VdiDeviceSignIns($lines) {
  $out = New-Object Collections.ArrayList; $node = ''; $nodeAt = [datetime]::MinValue
  foreach ($l in @($lines)) {
    if ("$l" -notmatch '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (.*)$') { continue }
    $t = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture); $x = $Matches[2]
    if ($x -match '^broker (\S+): connecting to (\S+)') { $node = $Matches[2]; $nodeAt = $t; continue }
    $u = $null; $b = ''; $ok = $false; $att = 1; $kind = ''; $why = ''
    if ($x -match '^session of (\S+) opened \(broker (\S+)\)') { $u = $Matches[1]; $b = $Matches[2]; $ok = $true; $kind = 'opened' }
    elseif ($x -match '^attempt (\d+) for (\S+) on (\S+) failed after \d+s \(code \d+, (\w+)\)') { $att = [int]$Matches[1]; $u = $Matches[2]; $b = $Matches[3]; $kind = 'failed'; $why = Get-WhereLabel $Matches[4] }
    elseif ($x -match '^attempt (\d+) for (\S+) on (\S+) failed') { $att = [int]$Matches[1]; $u = $Matches[2]; $b = $Matches[3]; $kind = 'failed' }
    elseif ($x -match '^desktop not available for (\S+) after \d+ attempts: (\S*)') { $u = $Matches[1]; $kind = 'unavailable'; $why = Get-WhereLabel $Matches[2] }
    elseif ($x -match '^sign-in refused for (\S+)( \(([^)]*)\))?') { $u = $Matches[1]; $kind = 'refused'; $why = "$($Matches[3])" }
    else { continue }
    if ($node -and ($t - $nodeAt).TotalSeconds -le 120 -and $kind -ne 'refused') { $b = $node }
    # "desktop not available after N attempts" closes the attempts just before it: one line, not one more failure
    if ($kind -eq 'unavailable' -and $out.Count) {
      $prev = $out[$out.Count - 1]
      if (-not $prev.Ok -and $prev.User -eq (Get-VdiUserKey $u) -and ($t - $prev.Time).TotalSeconds -le 60) { if (-not $prev.Why) { $prev.Why = $why }; continue }
    }
    [void]$out.Add([pscustomobject]@{ Time = $t; User = (Get-VdiUserKey $u); Ok = $ok; Broker = $(if ($b) { Get-VdiShort $b } else { '' }); Attempt = $att; Kind = $kind; Source = 'device'; Why = $why })
  }
  @($out)
}
# The outcome of the last sign-in of a user from its events (device and broker, merged): Last, LastOk, SecondTry (the
# last success came after a failure of the minutes before: the user got in, a broker did not let him), FailedOn
$script:VdiSecondTryMinutes = 3
$script:VdiCannotMinutes = 120
function Get-VdiSignIn($events) {
  # The same sign-in seen by the device and by the broker (same outcome, same broker, within 90 s) is one: each broker
  # line goes with the nearest device line. The device's names the device; the reason the broker logged is more
  # precise than the class of error the device saw.
  $all = @($events | Where-Object { $_ -and $_.Time })
  $dev = @($all | Where-Object { $_.Source -eq 'device' } | Sort-Object Time)
  $ev = New-Object Collections.ArrayList; foreach ($e in $dev) { [void]$ev.Add($e) }
  $paired = @{}
  foreach ($b in @($all | Where-Object { $_.Source -ne 'device' } | Sort-Object Time)) {
    $best = -1; $bd = 91
    for ($i = 0; $i -lt $dev.Count; $i++) {
      if ($paired.ContainsKey($i) -or $dev[$i].Ok -ne $b.Ok -or $dev[$i].Broker -ne $b.Broker) { continue }
      $dd = [Math]::Abs(($dev[$i].Time - $b.Time).TotalSeconds); if ($dd -lt $bd) { $bd = $dd; $best = $i }
    }
    if ($best -lt 0) { [void]$ev.Add($b); continue }
    $paired[$best] = $true
    if ($b.PSObject.Properties['Why'] -and $b.Why) { $dev[$best] | Add-Member -NotePropertyName Why -NotePropertyValue $b.Why -Force }
  }
  $ev = @($ev | Sort-Object Time)
  $r = [pscustomobject]@{ Last = $null; LastOk = $null; SecondTry = $false; FailedOn = ''; Count = $ev.Count; Recent = @($ev | Select-Object -Last 6) }
  if (-not $ev.Count) { return $r }
  $r.Last = $ev[-1]
  $r.LastOk = @($ev | Where-Object Ok) | Select-Object -Last 1
  if ($r.Last.Ok) {
    $f = @($ev | Where-Object { -not $_.Ok -and $_.Time -le $r.Last.Time -and ($r.Last.Time - $_.Time).TotalMinutes -le $script:VdiSecondTryMinutes }) | Select-Object -Last 1
    if ($f) { $r.SecondTry = $true; $r.FailedOn = $f.Broker }
  }
  $r
}
# index of an array of objects by a property, upper case
function Get-VdiIndex($items, [string]$prop) {
  $h = @{}; foreach ($i in @($items)) { if ($i -and $i.$prop) { $k = ([string]$i.$prop).ToUpper(); if (-not $h.ContainsKey($k)) { $h[$k] = $i } } }; $h
}
function Get-VdiSvcState($obj, [string]$name) { $s = @($obj.Services | Where-Object { $_.Name -eq $name }) | Select-Object -First 1; if ($s) { [string]$s.State } else { '' } }
# a broker that fails every request: since the count started at least two failures and no more successes than
# failures, or its last requests (two or three) all failed after a good morning
function Test-VdiFailsAll($b, [datetime]$since) {
  if (-not $b -or -not $b.Reachable) { return $false }
  if ([int]$b.Failed -ge 2 -and [int]$b.Failed -ge [int]$b.Received) { return $true }
  $last = @(@($b.Requests) | Where-Object { $_ -and (ConvertFrom-VdiTime $_.Time) -ge $since } | Sort-Object { ConvertFrom-VdiTime $_.Time } -Descending | Select-Object -First 3)
  ($last.Count -ge 2 -and @($last | Where-Object { $_.Ok }).Count -eq 0)
}
# healthy = may stand in for another broker while that one restarts
function Test-VdiBrokerHealthy($b, [datetime]$now) {
  if (-not $b -or -not $b.Reachable) { return $false }
  foreach ($n in 'Tssdis', 'RDMS', 'TScPubRPC') { if ((Get-VdiSvcState $b $n) -ne 'Running') { return $false } }
  if ($b.FailsAll) { return $false }
  $sl = ConvertFrom-VdiTime $b.SignatureLast
  -not ($sl -and ($now - $sl).TotalMinutes -le 30)
}

# Everything the pages show. $raw = the probe (or the demo file), $devices = Get-Devices, $now = the time of the data.
# Access: ok, off (turned off in the settings), nobroker (none known), denied, unreachable.
function ConvertTo-VdiModel($raw, $devices, [datetime]$now, $settings = $null) {
  if (-not $settings) { $settings = [pscustomobject]@{ Enabled = $true; BrokerGroup = ''; Brokers = ''; Hosts = '' } }
  $m = [pscustomobject]@{ Access = 'ok'; AccessText = ''; Brokers = @(); Hosts = @(); Names = @(); Rows = @(); Findings = @(); Headline = ''; HeadlineKind = 'ok'
    Taken = $now; Active = $null; Collections = @(); Desktops = @(); Group = $null; CannotSignIn = 0 }
  $brokers = @(); $hosts = @()
  if ($raw) { $brokers = @($raw.Brokers | Where-Object { $_ }); $hosts = @($raw.Hosts | Where-Object { $_ }); $m.Names = @($raw.Names | Where-Object { $_ }); $m.Group = $raw.Group }
  $reach = @($brokers | Where-Object Reachable)
  # ---- brokers
  $bsid = @{}; if ($raw) { foreach ($x in @($raw.BrokerSids)) { if ($x) { $bsid[([string]$x.Broker).ToUpper()] = @($x.Sids) } } }
  foreach ($b in $brokers) {
    $since = ConvertFrom-VdiTime $b.Since; if (-not $since) { $since = $now.Date }
    $b | Add-Member -NotePropertyName SinceTime -NotePropertyValue $since -Force
    $b | Add-Member -NotePropertyName FailsAll -NotePropertyValue (Test-VdiFailsAll $b $since) -Force
    $b | Add-Member -NotePropertyName Healthy -NotePropertyValue $false -Force
    $b | Add-Member -NotePropertyName Sids -NotePropertyValue @($bsid[$b.Name]) -Force
  }
  foreach ($b in $brokers) { $b.Healthy = Test-VdiBrokerHealthy $b $now }
  $m.Brokers = $brokers
  $act = @($reach | Where-Object IsActive) | Select-Object -First 1
  $m.Active = $act
  $sessions = @($reach | ForEach-Object { @($_.Sessions) } | Where-Object { $_ })
  # every broker reads the same session directory: one copy per session
  $sessions = @($sessions | Group-Object { "$($_.Vm)|$($_.Id)|$($_.User)".ToUpper() } | ForEach-Object { $_.Group[0] })
  $assign = @($reach | ForEach-Object { @($_.Assignments) } | Where-Object { $_ } | Group-Object { "$($_.User)|$($_.Vm)".ToUpper() } | ForEach-Object { $_.Group[0] })
  if ($act) { $m.Collections = @($act.Collections | Where-Object { $_ }); $m.Desktops = @($act.Desktops | Where-Object { $_ }) }
  $rdshServers = @(); if ($act) { $rdshServers = @($act.Rdsh | ForEach-Object { Get-VdiShort $_ }) }
  # ---- hosts and VMs
  $vmIndex = @{}
  foreach ($h in $hosts) { if ($h.Reachable) { foreach ($v in @($h.Vms)) { if ($v) { $vmIndex[([string]$v.Name).ToUpper()] = [pscustomobject]@{ Vm = $v; Host = $h.Name } } } } }
  $m.Hosts = $hosts
  $wtsIndex = @{}; if ($raw) { foreach ($w in @($raw.Wts)) { if ($w) { $wtsIndex[([string]$w.Vm).ToUpper()] = $w } } }
  # ---- access
  if (-not $settings.Enabled) { $m.Access = 'off' }
  elseif (-not $brokers.Count) { $m.Access = 'nobroker' }
  elseif (-not $reach.Count) {
    $who = ($brokers | ForEach-Object Name) -join ', '
    $m.Access = if (@($brokers | Where-Object { $_.Error -eq 'denied' }).Count) { 'denied' } else { 'unreachable' }
    $m.AccessText = $who
  }
  # ---- sign-ins by user: the devices' and the brokers'
  $byUser = @{}
  $addEv = { param($e) if (-not $e.User) { return }; if (-not $byUser.ContainsKey($e.User)) { $byUser[$e.User] = New-Object Collections.ArrayList }; [void]$byUser[$e.User].Add($e) }
  foreach ($b in $reach) {
    foreach ($q in @($b.Requests)) { if ($q) { & $addEv ([pscustomobject]@{ Time = (ConvertFrom-VdiTime $q.Time); User = (Get-VdiUserKey $q.User); Ok = [bool]$q.Ok; Broker = $b.Name; Attempt = 1
      Kind = $(if ($q.Ok) { 'served' } else { 'refusedbybroker' }); Source = 'broker'; Why = [string]$q.Why; Device = '' }) } }
  }
  $devEvents = @{}
  if ($raw) { foreach ($e in @($raw.Events)) { if ($e) { $devEvents[[string]$e.Device] = @(Get-VdiDeviceSignIns $e.Lines | ForEach-Object { $_ | Add-Member -NotePropertyName Device -NotePropertyValue $e.Device -PassThru -Force }) } } }
  # without the probe (turned off, no broker known) the logs are read here: the sign-ins of the devices still show
  foreach ($d in @($devices | Where-Object { -not $_.OldName -and -not $devEvents.ContainsKey($_.Name) })) {
    $lf = if ($script:StatusDir) { Join-Path $script:StatusDir "$($d.Name)-events.log" } else { '' }
    if (-not $lf -or -not (Test-Path -LiteralPath $lf)) { continue }
    $lines = @(Read-Lines $lf | Select-Object -Last 400)
    $devEvents[$d.Name] = @(Get-VdiDeviceSignIns $lines | ForEach-Object { $_ | Add-Member -NotePropertyName Device -NotePropertyValue $d.Name -PassThru -Force })
  }
  # ---- rows: a personal desktop and its owner, a session, a device
  $rows = New-Object Collections.ArrayList
  $byKey = @{}
  $newRow = { param($user, $vm, $coll)
    $r = [pscustomobject]@{ Key = ''; User = $user; UserKey = (Get-VdiUserKey $user); Domain = ''; Device = $null; Vm = $vm; Collection = $coll; Host = ''; VmInfo = $null; Session = $null; SignIn = $null
      Rdsh = $false; Kind = 'ok'; State = ''; Why = ''; Order = 9; DeviceText = ''; VmText = ''; SessionText = ''; SignInText = ''; CannotSignIn = $false; Wts = $null }
    [void]$rows.Add($r); $r }
  foreach ($a in $assign) {
    $r = & $newRow $a.User $a.Vm $a.Collection; $r.Domain = [string]$a.Domain
    if (-not $byKey.ContainsKey($r.UserKey)) { $byKey[$r.UserKey] = $r }
  }
  foreach ($s in $sessions) {
    $k = Get-VdiUserKey $s.User
    if ($byKey.ContainsKey($k)) { continue }
    $r = & $newRow $s.User $s.Vm $s.Collection; $r.Domain = [string]$s.Domain
    $r.Rdsh = ($s.Type -ne 2) -or ($rdshServers -contains (Get-VdiShort $s.Vm))
    $byKey[$k] = $r
  }
  # a user known only from a device signs in to the domain of the desktops
  $defDom = [string](@($assign + $sessions | Where-Object { $_.Domain }) | Select-Object -First 1).Domain
  foreach ($d in @($devices | Where-Object { -not $_.OldName })) {
    $u = Get-VdiDeviceUser $d.S
    $k = if ($u) { Get-VdiUserKey $u } else { '' }
    if ($k -and $byKey.ContainsKey($k) -and -not $byKey[$k].Device) { $byKey[$k].Device = $d; continue }
    $r = & $newRow $u $(if ($k -and $byKey.ContainsKey($k)) { $byKey[$k].Vm } else { '' }) ''
    $r.Device = $d; $r.Domain = $defDom
    if ($k -and -not $byKey.ContainsKey($k)) { $byKey[$k] = $r }
  }
  # ---- each row: VM, host, session, sign-in, state
  $cannot = @()
  # a user with several devices: the brokers' events cannot tell which device they came from
  $perUser = @{}; foreach ($r in $rows) { if ($r.UserKey) { $perUser[$r.UserKey] = 1 + [int]$perUser[$r.UserKey] } }
  foreach ($r in $rows) {
    $r.Key = "$($r.UserKey)|$(if ($r.Device) { $r.Device.Name })|$($r.Vm)"
    $vi = if ($r.Vm) { $vmIndex[([string]$r.Vm).ToUpper()] } else { $null }
    if ($vi) { $r.VmInfo = $vi.Vm; $r.Host = $vi.Host }
    elseif ($r.Vm) {
      $dk = @($m.Desktops | Where-Object { $_.Name -ieq $r.Vm }) | Select-Object -First 1
      if ($dk) { $r.Host = Get-VdiShort $dk.Host }
    }
    # the session: the session directory, then the desktop itself (fresher: a session it calls disconnected is)
    $sd = @($sessions | Where-Object { (Get-VdiUserKey $_.User) -eq $r.UserKey -and $r.UserKey } | Sort-Object { $(if ($_.Vm -ieq $r.Vm) { 0 } else { 1 }) }) | Select-Object -First 1
    if ($sd -and -not $r.Vm) { $r.Vm = $sd.Vm }
    if ($sd -and -not $r.Host -and $sd.Host) { $r.Host = Get-VdiShort $sd.Host }
    $w = if ($r.Vm) { $wtsIndex[([string]$r.Vm).ToUpper()] } else { $null }
    $r.Wts = $w
    $ws = if ($w -and $w.Ok) { @($w.Sessions | Where-Object { $_ -and (Get-VdiUserKey $_.User) -eq $r.UserKey }) | Select-Object -First 1 } else { $null }
    if ($ws) {
      $st = switch ([int]$ws.State) { 0 { 'active' } 4 { 'disconnected' } default { 'other' } }
      $wnow = ConvertFrom-VdiTime $ws.Now; if (-not $wnow) { $wnow = $now }
      $li = ConvertFrom-VdiTime $ws.LastInput
      $r.Session = [pscustomobject]@{ State = $st; Id = [int]$ws.Id; Vm = $r.Vm; Logon = (ConvertFrom-VdiTime $ws.Logon); Disconnect = (ConvertFrom-VdiTime $ws.Disconnect)
        IdleMin = $(if ($li -and $st -eq 'active') { [Math]::Max(0, [int][Math]::Floor(($wnow - $li).TotalMinutes)) } else { $null }); Source = 'desktop' }
    } elseif ($sd) {
      $st = switch ([int]$sd.State) { 0 { 'active' } 1 { 'disconnected' } 4 { 'disconnected' } default { 'other' } }
      $r.Session = [pscustomobject]@{ State = $st; Id = [int]$sd.Id; Vm = $sd.Vm; Logon = (ConvertFrom-VdiTime $sd.Created); Disconnect = $null; IdleMin = $null; Source = 'broker' }
    }
    # the sign-ins: of this device for this user, and of the brokers for this user
    $ev = @()
    if ($r.UserKey -and $byUser.ContainsKey($r.UserKey) -and -not ($r.Device -and $perUser[$r.UserKey] -gt 1)) { $ev += @($byUser[$r.UserKey]) }
    if ($r.Device -and $devEvents.ContainsKey($r.Device.Name)) { $ev += @($devEvents[$r.Device.Name] | Where-Object { -not $r.UserKey -or $_.User -eq $r.UserKey }) }
    $r.SignIn = Get-VdiSignIn $ev
    Set-VdiRowState $r $m $now $hosts
    if ($r.CannotSignIn) { $cannot += $r }
  }
  $m.Rows = @($rows | Sort-Object Order, @{ Expression = { $_.User } }, @{ Expression = { if ($_.Device) { $_.Device.Name } else { '' } } })
  $m.CannotSignIn = $cannot.Count
  # ---- the headline: who cannot sign in right now
  if ($cannot.Count) {
    $m.HeadlineKind = 'error'
    # each one with what stops him, in a few words
    $m.Headline = Get-Text 'VdiHeadCannot' $cannot.Count ((@($cannot | Select-Object -First 4 | ForEach-Object {
      $why = if ($_.State -eq (Get-Text 'VdiStCannot') -and $_.SignIn.Last.Broker) { Get-Text 'VdiHeadFailedOn' $_.SignIn.Last.Broker } else { $_.State }
      "$(if ($_.User) { $_.User } else { $_.Device.Name }): $why" }) -join "   $([char]0x00B7)   ") + $(if ($cannot.Count -gt 4) { "   $([char]0x00B7)   ..." } else { '' }))
  } else {
    $warn = @($m.Rows | Where-Object { $_.Kind -in 'warn', 'error' })
    if ($warn.Count) { $m.HeadlineKind = 'warn'; $m.Headline = Get-Text 'VdiHeadWarn' $warn.Count }
    else { $m.HeadlineKind = 'ok'; $m.Headline = Get-Text 'VdiHeadOk' }
  }
  $m.Findings = @(Get-VdiFindings $m $now $settings)
  $m
}

# State of a row: Kind (colour), State (short text for the list), Why (the sentence for the details), Order (the
# rows that matter most on top). The first rule that matches wins.
function Set-VdiRowState($r, $m, [datetime]$now, $hosts) {
  $vi = $r.VmInfo; $s = $r.Session; $si = $r.SignIn
  $h = if ($r.Host) { @($hosts | Where-Object { $_.Name -eq $r.Host }) | Select-Object -First 1 } else { $null }
  $hb = if ($vi) { [string]$vi.Heartbeat } else { '' }
  $hung = $vi -and $vi.State -eq 'Running' -and $hb -match '^(LostCommunication|NoContact|Error)' -and [int]$vi.UptimeMin -ge 5
  $agentStuck = $h -and $h.Reachable -and ((Get-VdiSvcState $h 'VmHostAgent') -match 'Pending|Stopped' -or (Get-VdiSvcState $h 'vmms') -match 'Pending')
  $lastFail = $si.Last -and -not $si.Last.Ok -and ($now - $si.Last.Time).TotalMinutes -le $script:VdiCannotMinutes
  $active = $s -and $s.State -eq 'active'
  $online = $r.Device -and $r.Device.Minutes -le $script:StaleMinutes
  # texts of the columns
  $r.DeviceText = if ($r.Device) { if ($online) { $r.Device.Name } else { Get-Text 'VdiDeviceOff' $r.Device.Name } } else { '' }
  $r.VmText = if ($vi) {
      switch ([string]$vi.State) {
        'Running' { if ($hung) { Get-Text 'VdiVmHung' } else { Get-Text 'VdiVmRunning' } }
        'Off' { if ($vi.PSObject.Properties['Registered'] -and $vi.Registered -eq $false) { Get-Text 'VdiVmOffRole' } else { Get-Text 'VdiVmOff' } }
        'Saved' { Get-Text 'VdiVmSaved' }
        'Paused' { Get-Text 'VdiVmPaused' }
        default { [string]$vi.State }
      }
    } elseif ($r.Vm -and $h -and -not $h.Reachable) { Get-Text 'VdiVmUnknown' } elseif ($r.Vm) { '' } else { '' }
  $r.SessionText = if ($s) {
      switch ($s.State) {
        'active' { if ($null -ne $s.IdleMin -and $s.IdleMin -ge 5) { Get-Text 'VdiSessIdle' (Format-Minutes $s.IdleMin) } else { Get-Text 'VdiSessActive' } }
        'disconnected' { if ($s.Disconnect) { Get-Text 'VdiSessDiscSince' (Format-VdiClock $s.Disconnect $now) } else { Get-Text 'VdiSessDisc' } }
        default { Get-Text 'VdiSessOther' }
      }
    } else { '' }
  $r.SignInText = if ($si.Last) {
      $b = if ($si.Last.Broker) { $si.Last.Broker } else { '?' }
      if ($si.Last.Ok) { if ($si.SecondTry) { Get-Text 'VdiSignOkSecond' (Format-VdiClock $si.Last.Time $now) $b } else { Get-Text 'VdiSignOk' (Format-VdiClock $si.Last.Time $now) $b } }
      else { Get-Text 'VdiSignFail' (Format-VdiClock $si.Last.Time $now) $b }
    } else { '' }
  $set = { param($kind, $order, $stateKey, $whyKey) $r.Kind = $kind; $r.Order = $order; $r.State = Get-Text $stateKey; $r.Why = $whyKey }
  if ($agentStuck -and -not $active) { & $set 'error' 0 'VdiStHostStuck' (Get-Text 'VdiWhyHostStuck' $r.Host); $r.CannotSignIn = [bool]$r.UserKey; return }
  if ($vi -and $vi.State -eq 'Saved' -and $vi.Tpm) { & $set 'error' 0 'VdiStSavedTpm' (Get-Text 'VdiWhySavedTpm' $r.Vm); $r.CannotSignIn = $true; return }
  if ($lastFail -and -not $active) {
    $why = Get-Text 'VdiWhyCannot' (Format-VdiClock $si.Last.Time $now) $(if ($si.Last.Broker) { $si.Last.Broker } else { '?' }) $(if ($si.Last.Why) { " ($(([string]$si.Last.Why).TrimEnd('.')))" } else { '' })
    & $set 'error' 0 'VdiStCannot' $why; $r.CannotSignIn = $true; return
  }
  if ($hung) { & $set 'error' 1 'VdiStHung' (Get-Text 'VdiWhyHung' $r.Vm $hb); $r.CannotSignIn = -not $active; return }
  if ($h -and -not $h.Reachable -and -not $active) { & $set 'warn' 2 'VdiStHostUnknown' (Get-Text 'VdiWhyHostUnknown' $r.Host); return }
  if ($r.Device -and $r.UserKey -and -not $r.Vm -and -not $s -and $m.Access -eq 'ok' -and @($m.Collections | Where-Object { $_.Kind -eq 'vm' }).Count -and -not $r.Rdsh) {
    & $set 'warn' 2 'VdiStNoDesktop' (Get-Text 'VdiWhyNoDesktop' $r.User); return }
  if ($si.Last -and $si.Last.Ok -and $si.SecondTry -and ($now - $si.Last.Time).TotalMinutes -le 1440) {
    & $set 'warn' 3 'VdiStSecond' (Get-Text 'VdiWhySecond' (Format-VdiClock $si.Last.Time $now) $si.FailedOn $si.Last.Broker); return }
  if ($vi -and $vi.State -eq 'Saved') { & $set 'warn' 3 'VdiStSaved' (Get-Text 'VdiWhySaved' $r.Vm); return }
  if ($s -and $s.State -eq 'disconnected') { & $set 'info' 4 'VdiStDisc' (Get-Text 'VdiWhyDisc' $(if ($s.Disconnect) { Format-VdiAge $s.Disconnect $now } else { '?' })); return }
  if ($active) { & $set 'ok' 5 'VdiStActive' $(if ($null -ne $s.IdleMin -and $s.IdleMin -ge 5) { Get-Text 'VdiWhyIdle' (Format-Minutes $s.IdleMin) } else { Get-Text 'VdiWhyActive' }); return }
  if ($vi -and $vi.State -eq 'Off') { & $set 'info' 6 'VdiStVmOff' (Get-Text 'VdiWhyVmOff'); return }
  if ($r.Device -and -not $online) { & $set 'off' 8 'VdiStDeviceOff' (Get-Text 'VdiWhyDeviceOff'); return }
  if (-not $r.UserKey) { & $set $(if ($online) { 'info' } else { 'off' }) 8 'VdiStNoUser' (Get-Text 'VdiWhyNoUser'); return }
  & $set 'ok' 7 'VdiStReady' $(if ($r.Vm) { Get-Text 'VdiWhyReady' } else { Get-Text 'VdiWhyNoVm' })
}

# The findings on brokers, shared names and hosts: Kind (error, warn, info, ok), Where, Text (one
# sentence), Fix (an action kind, or $null), FixArg, Order. A healthy broker or host is one ok line that says so.
function Get-VdiFindings($m, [datetime]$now, $settings) {
  $out = New-Object Collections.ArrayList
  $add = { param($kind, $where, $text, $fix = $null, $arg = $null)
    $o = switch ($kind) { 'error' { 0 } 'warn' { 1 } 'info' { 2 } default { 3 } }
    [void]$out.Add([pscustomobject]@{ Kind = $kind; Where = $where; Text = $text; Fix = $fix; FixArg = $arg; Order = $o }) }
  if ($m.Access -in 'off', 'nobroker') { return @() }
  $gname = @{ 'S-1-5-32-576' = (Get-Text 'VdiGroup576'); 'S-1-5-32-577' = (Get-Text 'VdiGroup577'); 'S-1-5-32-578' = (Get-Text 'VdiGroup578') }
  # ---- brokers
  foreach ($b in $m.Brokers) {
    if (-not $b.Reachable) { & $add 'warn' $b.Name $(if ($b.Error -eq 'denied') { Get-Text 'VdiFBrokerDenied' } else { Get-Text 'VdiFUnreachable' $b.Error }); continue }
    $since = Format-VdiClock $b.SinceTime $now
    $bad = @($b.Services | Where-Object { $_.State -ne 'Running' })
    foreach ($s in $bad) {
      if ($s.State -match 'Pending') { & $add 'error' $b.Name (Get-Text 'VdiFSvcStuck' $s.Name $s.State) 'BrokerRestart' $b.Name }
      else { & $add 'error' $b.Name (Get-Text 'VdiFSvcStopped' $s.Name $s.State) 'BrokerRestart' $b.Name }
    }
    $sl = ConvertFrom-VdiTime $b.SignatureLast
    if ($b.FailsAll) {
      $t = Get-Text 'VdiFFailsAll' $b.Failed $b.Received $since
      if ([int]$b.Signature -gt 0) { $t += ' ' + (Get-Text 'VdiFSignature' (Format-VdiClock $sl $now)) }
      elseif ([int]$b.Denied -gt 0) { $t += ' ' + (Get-Text 'VdiFDenied') }
      & $add 'error' $b.Name $t 'BrokerRestart' $b.Name
    } elseif ($sl -and ($now - $sl).TotalMinutes -le 30) {
      & $add 'error' $b.Name (Get-Text 'VdiFSignatureNow' (Format-VdiClock $sl $now)) 'BrokerRestart' $b.Name
    } elseif ([int]$b.Failed -gt 0) {
      & $add 'warn' $b.Name (Get-Text 'VdiFSomeFail' $b.Failed $b.Received $since)
    }
    if ([int]$b.DbErrors -gt 0) { & $add 'error' $b.Name (Get-Text 'VdiFDb' $b.DbErrors $since) }
    # the self-repair task
    $tk = $b.Task
    $repo = Get-VdiRepairHash
    if (-not $tk -or -not @($tk.Names).Count) { & $add 'info' $b.Name (Get-Text 'VdiFNoRepair') 'BrokerSelfRepair' $b.Name }
    elseif ($tk.Ours -and $repo -and $tk.Hash -and $tk.Hash -ne $repo) { & $add 'info' $b.Name (Get-Text 'VdiFRepairOld') 'BrokerSelfRepair' $b.Name }
    elseif ($tk.Ours -and $tk.State -eq 'Disabled') { & $add 'warn' $b.Name (Get-Text 'VdiFRepairOff') 'BrokerSelfRepair' $b.Name }
    # in the AD group of the settings (the host permissions are given to that group)
    if ($m.Group -and $m.Group.Sid -and @($b.Sids).Count -and @($b.Sids) -notcontains $m.Group.Sid) {
      & $add 'error' $b.Name (Get-Text 'VdiFNotInGroup' $m.Group.Name) 'BrokerAddToGroup' $b.Name }
    if (-not @($out | Where-Object { $_.Where -eq $b.Name -and $_.Kind -in 'error', 'warn' }).Count) {
      $parts = @(Get-Text 'VdiFBrokerOk' $b.Received $since)
      if ($tk -and @($tk.Names).Count) { $parts += Get-Text 'VdiFRepairOn' }
      if ($b.IsActive) { $parts += Get-Text 'VdiFActive' }
      & $add 'ok' $b.Name ($parts -join ' ')
    }
  }
  if ($m.Group -and -not $m.Group.Sid) { & $add 'warn' $m.Group.Name (Get-Text 'VdiFGroupMissing' $m.Group.Name) }
  # ---- the shared names: every broker behind them, every address answering
  foreach ($n in @($m.Names | Where-Object { -not $_.IsIp })) {
    if (-not @($n.Addresses).Count) { & $add 'error' $n.Name (Get-Text 'VdiFNameNone'); continue }
    $dead = @($n.Addresses | Where-Object { -not $_.Rdp })
    foreach ($a in $dead) { & $add 'error' $n.Name (Get-Text 'VdiFNameDead' $a.Ip $(if ($a.Fqdn) { Get-VdiShort $a.Fqdn } else { '?' })) }
    $behind = @($n.Addresses | ForEach-Object { if ($_.Fqdn) { Get-VdiShort $_.Fqdn } })
    if (@($n.Addresses).Count -gt 1) {
      # a broker of the farm that the shared name leaves out never gets a device through it
      $farm = @($m.Brokers | Where-Object { $_.Reachable } | ForEach-Object Name)
      foreach ($x in @($farm | Where-Object { $behind -notcontains $_ })) { & $add 'warn' $n.Name (Get-Text 'VdiFNameMissing' $x) }
    }
    if (-not $dead.Count) { & $add 'ok' $n.Name (Get-Text 'VdiFNameOk' @($n.Addresses).Count (($behind | Select-Object -Unique) -join ', ')) }
  }
  # ---- hosts
  $brokerIps = @{}; foreach ($b in $m.Brokers) { foreach ($ip in @($b.Ips | Where-Object { $_ })) { $brokerIps[$ip] = $b.Name } }
  foreach ($n in $m.Names) { foreach ($a in @($n.Addresses)) { if ($a.Fqdn -and -not $brokerIps.ContainsKey($a.Ip)) { $brokerIps[$a.Ip] = Get-VdiShort $a.Fqdn } } }
  foreach ($h in $m.Hosts) {
    if (-not $h.Reachable) { & $add 'warn' $h.Name $(if ($h.Error -eq 'denied') { Get-Text 'VdiFHostDenied' } else { Get-Text 'VdiFUnreachable' $h.Error }); continue }
    $agent = Get-VdiSvcState $h 'VmHostAgent'
    $rdvh = $agent -and $agent -ne 'Missing'
    foreach ($svc in 'VmHostAgent', 'vmms', 'ClusSvc') {
      $st = Get-VdiSvcState $h $svc
      if ($st -match 'Pending') { & $add 'error' $h.Name (Get-Text $(if ($svc -eq 'ClusSvc') { 'VdiFClusStuck' } else { 'VdiFHostStuck' }) $svc $st) $(if ($svc -ne 'ClusSvc') { 'HostUnblock' }) $(if ($svc -ne 'ClusSvc') { $svc }) }
      elseif ($svc -eq 'VmHostAgent' -and $st -eq 'Stopped') { & $add 'error' $h.Name (Get-Text 'VdiFAgentStopped') 'HostUnblock' 'VmHostAgent' }
    }
    $attached = @(@($h.AgentLinks) | Where-Object { $brokerIps.ContainsKey($_) } | ForEach-Object { $brokerIps[$_] } | Select-Object -Unique)
    if ($rdvh) {
      if ($null -eq $h.AgentBrokers -or -not ([string]$h.AgentBrokers).Trim()) { & $add 'error' $h.Name (Get-Text 'VdiFAgentNoList') }
      elseif ($agent -eq 'Running' -and -not $attached.Count -and $brokerIps.Count) { & $add 'error' $h.Name (Get-Text 'VdiFAgentAlone') 'HostUnblock' 'VmHostAgent' }
    }
    # the brokers in the three local groups: each broker must be in each, directly or through a group
    $missing = @{}; $via = @()
    if ($rdvh) {
      foreach ($g in @($h.Groups)) {
        if (-not $g.Read) { & $add 'warn' $h.Name (Get-Text 'VdiFGroupUnread' $gname[$g.Sid]); continue }
        $mem = @($g.Members | ForEach-Object { $_.Sid })
        foreach ($b in @($m.Brokers | Where-Object { @($_.Sids).Count })) {
          $hit = @($g.Members | Where-Object { @($b.Sids) -contains $_.Sid })
          if (-not $hit.Count) { if (-not $missing.ContainsKey($b.Name)) { $missing[$b.Name] = @() }; $missing[$b.Name] += $gname[$g.Sid] }
          else { $via += @($hit | ForEach-Object { ([string]$_.Name).Split('\')[-1] }) }
        }
      }
      foreach ($bn in @($missing.Keys | Sort-Object)) { & $add 'error' $h.Name (Get-Text 'VdiFPerm' $bn ($missing[$bn] -join ', ')) 'HostPermissions' $h.Name }
    }
    # VMs with a vTPM that the cluster would SAVE when it stops them
    $savers = @(@($h.Vms) | Where-Object { $_ -and $_.Tpm -and $_.Clustered -and $null -ne $_.OfflineAction -and [int]$_.OfflineAction -eq 1 })
    if ($savers.Count) { & $add 'warn' $h.Name (Get-Text 'VdiFSaveTpm' (($savers | Select-Object -First 5 | ForEach-Object Name) -join ', ')) 'HostOfflineAction' $h.Name }
    if (-not @($out | Where-Object { $_.Where -eq $h.Name -and $_.Kind -in 'error', 'warn' }).Count) {
      $vms = @(@($h.Vms) | Where-Object { $_ }); $run = @($vms | Where-Object { $_.State -eq 'Running' }).Count
      $parts = @()
      if ($rdvh) { $parts += $(if ($attached.Count) { Get-Text 'VdiFAgentOn' ($attached -join ', ') } else { Get-Text 'VdiFAgentRunning' }) }
      # how: through a group, or each broker by its computer account
      if ($rdvh -and @($m.Brokers | Where-Object { @($_.Sids).Count }).Count) { $parts += Get-Text 'VdiFPermOk' ((@($via | Select-Object -Unique)) -join ', ') }
      $parts += Get-Text 'VdiFVms' $vms.Count $run
      & $add 'ok' $h.Name ($parts -join ' ')
    }
  }
  @($out | Sort-Object Order, Where)
}
# the hash of the self-repair script of this manager: a broker with another one has an old copy
function Get-VdiRepairHash {
  if (-not $script:VdiRepairHashCache) { if (Test-Path -LiteralPath $script:VdiRepairScript) { $script:VdiRepairHashCache = (Get-FileHash -LiteralPath $script:VdiRepairScript -Algorithm SHA256).Hash } }
  $script:VdiRepairHashCache
}
$script:VdiRepairHashCache = $null

# ---------------------------------------------------------------------------------------------
# Actions. Get-VdiActionPlan says what an action does (Title, Text for the confirmation, Log for config\changes.log),
# whether it can run now (Blocked = the reason, $null = it can) and how (Steps, run by $script:VdiJobRunner: each step a
# script, on a server over WinRM or here, with its arguments as plain strings: an array passed to Invoke-Command lands
# in several parameters).
# ---------------------------------------------------------------------------------------------
$script:VdiRemote = @{
  # Services stopped in the given order and started in the other. NEVER Restart-Service/Stop-Service: they wait with
  # no limit, and a service stuck in StopPending would hang the manager forever. ServiceController.Stop() returns at
  # once, WaitForStatus has a limit, a service still hanging is ended by ending the process that hosts it (the only way
  # out of StopPending); the other services of that process and the ones that depend on it are started again after.
  # $purge: the Kerberos tickets of that logon session (0x3e4 = NETWORK SERVICE, the account of the broker services).
  Restart = {
    param([string]$stopCsv, [string]$startCsv, [int]$wait, [string]$purge)
    $stop = @($stopCsv.Split(',') | Where-Object { $_ }); $start = @($startCsv.Split(',') | Where-Object { $_ })
    $steps = @(); $again = @()
    foreach ($n in $stop) {
      $s = Get-Service -Name $n -ErrorAction SilentlyContinue
      if (-not $s) { $steps += [pscustomobject]@{ Name = $n; Before = 'Missing'; Killed = 0; Stopped = 'Missing' }; continue }
      $before = "$($s.Status)"
      $w = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
      if ($w -and $w.ProcessId -gt 0) {
        $again += @(Get-CimInstance Win32_Service -Filter "ProcessId=$($w.ProcessId)" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $n -and $_.State -eq 'Running' -and $stop -notcontains $_.Name } | ForEach-Object Name)
      }
      $again += @($s.DependentServices | Where-Object { $_.Status -eq 'Running' -and $stop -notcontains $_.Name } | ForEach-Object Name)
      if ($before -notmatch 'Pending') {
        if ($s.Status -eq 'Running') { try { $s.Stop() } catch { } }
        try { $s.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($wait)) } catch { }
      }
      $s.Refresh(); $killed = 0
      if ($s.Status -ne 'Stopped') {
        $w = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
        if ($w -and $w.ProcessId -gt 0) { $killed = [int]$w.ProcessId; Stop-Process -Id $killed -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 4 }
      }
      $s.Refresh()
      $steps += [pscustomobject]@{ Name = $n; Before = $before; Killed = $killed; Stopped = "$($s.Status)" }
    }
    foreach ($n in @($start + $again | Select-Object -Unique)) {
      $s = Get-Service -Name $n -ErrorAction SilentlyContinue; if (-not $s) { continue }
      for ($i = 0; $i -lt 6; $i++) {
        $s.Refresh(); if ($s.Status -eq 'Running') { break }
        if ($s.Status -eq 'Stopped') { try { $s.Start() } catch { } }
        try { $s.WaitForStatus('Running', [TimeSpan]::FromSeconds(10)) } catch { }
      }
    }
    $code = $null; if ($purge) { & klist.exe -li $purge purge | Out-Null; $code = $LASTEXITCODE }
    $after = @(foreach ($n in @($start + $again | Select-Object -Unique)) { $s = Get-Service -Name $n -ErrorAction SilentlyContinue; [pscustomobject]@{ Name = $n; State = $(if ($s) { "$($s.Status)" } else { 'Missing' }) } })
    [pscustomobject]@{ Ok = (@($after | Where-Object { $_.State -ne 'Running' }).Count -eq 0); Steps = $steps; After = $after; Again = @($again | Select-Object -Unique); Purge = $code }
  }
  Purge = {
    param([string]$sessions)
    $r = @(foreach ($x in $sessions.Split(',')) { & klist.exe -li $x purge | Out-Null; [pscustomobject]@{ Session = $x; Code = $LASTEXITCODE } })
    [pscustomobject]@{ Ok = (@($r | Where-Object { $_.Code -ne 0 }).Count -eq 0); Results = $r }
  }
  # members (SIDs) into local groups (SIDs), then read back: never reported done without checking
  AddLocal = {
    param([string]$groupsCsv, [string]$membersCsv)
    $res = @(foreach ($g in $groupsCsv.Split(',')) { foreach ($m in $membersCsv.Split(',')) {
      $r = 'added'
      try { Add-LocalGroupMember -SID $g -Member $m -ErrorAction Stop } catch { if ($_.FullyQualifiedErrorId -match 'MemberExists') { $r = 'already' } else { $r = $_.Exception.Message } }
      $now = @(); try { $now = @(Get-LocalGroupMember -SID $g -ErrorAction Stop | ForEach-Object { "$($_.SID)" }) } catch { }
      [pscustomobject]@{ Group = $g; Member = $m; Result = $r; In = ($now -contains $m) } } })
    [pscustomobject]@{ Ok = (@($res | Where-Object { -not $_.In }).Count -eq 0); Results = $res }
  }
  # OfflineAction of the VM roles: 2 = shut down (1 = save, which a VM with a vTPM may not come back from)
  OfflineAction = {
    param([string]$vmsCsv)
    $res = @(foreach ($v in $vmsCsv.Split(',')) {
      try { $r = @(Get-ClusterResource -ErrorAction Stop | Where-Object { "$($_.ResourceType)" -eq 'Virtual Machine' -and "$($_.OwnerGroup)" -eq $v })
            foreach ($x in $r) { $x | Set-ClusterParameter -Name OfflineAction -Value 2 -ErrorAction Stop }
            [pscustomobject]@{ Vm = $v; Value = [int](@($r)[0] | Get-ClusterParameter -Name OfflineAction).Value; Error = $null } }
      catch { [pscustomobject]@{ Vm = $v; Value = $null; Error = $_.Exception.Message } } })
    [pscustomobject]@{ Ok = (@($res | Where-Object { $_.Value -ne 2 }).Count -eq 0); Results = $res }
  }
  # Start, shut down, restart a VM, NEVER saved. A VM of the cluster is driven through its cluster resource of type
  # "Virtual Machine", never through the whole group: taking the group offline also takes the configuration resource
  # offline, and then Hyper-V unregisters the VM (Get-VM no longer finds it, on any host). Shut down: Stop-ClusterResource
  # when its OfflineAction is a shutdown (2, 3), else Stop-VM (a shutdown of Windows inside, never -Save nor -TurnOff).
  # Start: the group when it (or its configuration) is offline, else the VM resource; Start-VM only for a VM outside
  # the cluster (Start-VM would leave a cluster role offline: running, but not watched nor moved if the host fails).
  # A VM that does not shut down in time is left running and said so: power is never cut from here. Started = running
  # with a heartbeat.
  VmPower = {
    param([string]$vm, [string]$action, [int]$wait)
    $ErrorActionPreference = 'Stop'
    $hv = { try { Get-VM -Name $vm -ErrorAction Stop } catch { $null } }
    $v = & $hv
    # the cluster resource: by the VM id when Hyper-V knows the VM, by its group otherwise (a role taken offline whole)
    $res = $null; $grp = $null; $oa = $null
    try {
      $all = @(Get-ClusterResource -ErrorAction Stop | Where-Object { "$($_.ResourceType)" -eq 'Virtual Machine' })
      if ($v) { $res = @($all | Where-Object { "$(($_ | Get-ClusterParameter -Name VmID).Value)" -eq "$($v.Id)" }) | Select-Object -First 1 }
      if (-not $res) { $res = @($all | Where-Object { "$($_.OwnerGroup)" -eq $vm }) | Select-Object -First 1 }
      if ($res) { $grp = "$($res.OwnerGroup)"; $oa = [int]($res | Get-ClusterParameter -Name OfflineAction).Value }
    } catch { }
    $resState = { if ($res) { "$((Get-ClusterResource -Name $res.Name).State)" } else { '' } }
    $cfgOff = { if ($grp) { @(Get-ClusterResource | Where-Object { "$($_.OwnerGroup)" -eq $grp -and $_.Name -ne $res.Name -and "$($_.State)" -ne 'Online' }).Count } else { 0 } }
    $before = if ($v) { "$($v.State)" } else { 'Off' }
    $stopIt = {
      if ($res -and $oa -in 2, 3) { Stop-ClusterResource -Name $res.Name -Wait $wait | Out-Null }
      else { $x = & $hv; $j = Stop-VM -VM $x -Force -AsJob; if (-not (Wait-Job $j -Timeout $wait)) { Stop-Job $j }; Remove-Job $j -Force -ErrorAction SilentlyContinue }
    }
    $startIt = {
      if ($res) {
        if ("$((Get-ClusterGroup -Name $grp).State)" -eq 'Offline' -or (& $cfgOff)) { Start-ClusterGroup -Name $grp -Wait 120 | Out-Null }
        else { Start-ClusterResource -Name $res.Name -Wait 120 | Out-Null }
      } else { Start-VM -VM (& $hv) }
      # running is not enough: Windows answers its heartbeat once it has started
      $t0 = Get-Date
      do { $x = & $hv; if ($x -and "$($x.State)" -eq 'Running' -and "$($x.Heartbeat)" -like 'Ok*') { return }; Start-Sleep -Seconds 3 } while (((Get-Date) - $t0).TotalSeconds -lt 240)
    }
    $err = $null
    try {
      if (-not $v -and -not $res) { throw "$vm not found on this host nor in its cluster" }
      switch ($action) {
        'start' { & $startIt }
        'shutdown' { & $stopIt }
        'restart' {
          & $stopIt
          $x = & $hv
          if (-not $x -or "$($x.State)" -ne 'Off') { throw "$(if ($x) { "still $($x.State)" } else { 'not registered' }) after the shutdown: not started again" }
          & $startIt
        }
      }
    } catch { $err = $_.Exception.Message }
    $v = & $hv
    $after = if ($v) { "$($v.State)" } else { 'NotRegistered' }
    $hb = if ($v) { "$($v.Heartbeat)" } else { '' }
    $rs = & $resState
    $ok = switch ($action) {
      # off, still known to Hyper-V, and (in the cluster) only its VM resource offline
      'shutdown' { $after -eq 'Off' -and (-not $res -or ($rs -eq 'Offline' -and -not (& $cfgOff))) }
      default { $after -eq 'Running' -and $hb -like 'Ok*' -and (-not $res -or $rs -eq 'Online') }
    }
    if (-not $ok -and -not $err) { $err = "now $after$(if ($hb) { ", heartbeat $hb" })$(if ($res) { ", cluster resource $rs" })" }
    [pscustomobject]@{ Ok = [bool]$ok; Vm = $vm; Before = $before; After = $after; Heartbeat = $hb; Cluster = [bool]$res; Resource = $(if ($res) { $res.Name }); ResourceState = $rs; OfflineAction = $oa; Error = $err }
  }
  # the shadow policy of a desktop: 0 none, 1 control with consent, 2 control without, 3 view with consent, 4 view without
  ShadowPolicy = {
    $p = $null
    try { $p = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name Shadow -ErrorAction Stop).Shadow } catch { }
    if ($null -eq $p) { try { $p = (Get-CimInstance -Namespace root\cimv2\TerminalServices -ClassName Win32_TSRemoteControlSetting -Filter "TerminalName='RDP-Tcp'" -ErrorAction Stop).RemoteControlPolicy } catch { } }
    if ($null -eq $p) { $p = 1 }
    [pscustomobject]@{ Ok = $true; Policy = [int]$p }
  }
  # the personal desktop of a user, on the active management server and as the RemoteDesktop cmdlets want it: run there,
  # pointing at itself
  Assign = {
    param([string]$collection, [string]$user, [string]$vm, [string]$oldVm)
    $ErrorActionPreference = 'Stop'
    Import-Module RemoteDesktop
    $cb = [Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
    $err = $null
    try {
      if ($oldVm) { Remove-RDPersonalVirtualDesktopAssignment -CollectionName $collection -User $user -ConnectionBroker $cb -Force }
      if ($vm) { Set-RDPersonalVirtualDesktopAssignment -CollectionName $collection -User $user -VirtualDesktopName $vm -ConnectionBroker $cb }
    } catch { $err = $_.Exception.Message }
    $now = @(Get-RDPersonalVirtualDesktopAssignment -CollectionName $collection -User $user -ConnectionBroker $cb -ErrorAction SilentlyContinue | ForEach-Object { "$($_.VirtualDesktopName)" })
    [pscustomobject]@{ Ok = (-not $err -and ((-not $vm -and -not $now.Count) -or ($now -contains $vm))); Now = $now; Error = $err }
  }
  # Here, through the WTS API, as logoff.exe and msg.exe do. A Windows client refuses those calls unless remote RPC is
  # allowed on it (AllowRemoteRPC): then the same on the desktop itself, over WinRM.
  Logoff = { param([string]$vm, [int]$id)
    try { [void][OtrWts]::Logoff($vm, $id); [pscustomobject]@{ Ok = $true } }
    catch { $e1 = $_.Exception.Message
      try { Invoke-Command -ComputerName $vm -ArgumentList $id -ErrorAction Stop -ScriptBlock { param($i) & logoff.exe $i } | Out-Null; [pscustomobject]@{ Ok = $true } }
      catch { [pscustomobject]@{ Ok = $false; Error = "$e1 / $($_.Exception.Message)" } } } }
  Disconnect = { param([string]$vm, [int]$id)
    try { [void][OtrWts]::Disconnect($vm, $id); [pscustomobject]@{ Ok = $true } }
    catch { $e1 = $_.Exception.Message
      try { Invoke-Command -ComputerName $vm -ArgumentList $id -ErrorAction Stop -ScriptBlock { param($i) & tsdiscon.exe $i } | Out-Null; [pscustomobject]@{ Ok = $true } }
      catch { [pscustomobject]@{ Ok = $false; Error = "$e1 / $($_.Exception.Message)" } } } }
  Message = { param([string]$vm, [int]$id, [string]$title, [string]$text)
    try { [void][OtrWts]::Message($vm, $id, $title, $text); [pscustomobject]@{ Ok = $true } }
    catch { $e1 = $_.Exception.Message
      try { Invoke-Command -ComputerName $vm -ArgumentList $id, $text -ErrorAction Stop -ScriptBlock { param($i, $x) & msg.exe $i $x } | Out-Null; [pscustomobject]@{ Ok = $true } }
      catch { [pscustomobject]@{ Ok = $false; Error = "$e1 / $($_.Exception.Message)" } } } }
  # the broker into the AD group, then its tickets: the group counts from its next Kerberos ticket
  AddToGroup = {
    param([string]$groupSid, [string]$memberSid)
    $g = [ADSI]"LDAP://<SID=$groupSid>"
    $g.Add("LDAP://<SID=$memberSid>")
    [pscustomobject]@{ Ok = $true }
  }
  InstallRepair = {
    param([string]$script, [string]$broker)
    $r = @(& $script -Broker $broker)
    [pscustomobject]@{ Ok = (@($r | Where-Object { $_.Result -in 'installed', 'updated', 'unchanged' }).Count -gt 0); Results = $r }
  }
}

# A step of an action: Name (for the log), Computer ('' = here), Script (the text of a $script:VdiRemote entry), Args
function New-VdiStep([string]$name, [string]$computer, [string]$script, $argList, [bool]$stopOnFail = $true) {
  [pscustomobject]@{ Name = $name; Label = (Get-Text "VdiStep_$script"); Key = $script; Computer = $computer; Script = $script:VdiRemote[$script].ToString(); Args = @($argList); Local = (-not $computer); StopOnFail = $stopOnFail }
}
# Runs the steps of a plan in a runspace of its own. $dry: only says what it would run.
$script:VdiJobRunner = {
  param($steps, [bool]$dry, [int]$openMs, [int]$opMs)
  $so = New-PSSessionOption -OpenTimeout $openMs -OperationTimeout $opMs -CancelTimeout 5000
  foreach ($s in @($steps)) {
    if ($dry) { [pscustomobject]@{ Name = $s.Name; Label = $s.Label; Computer = $s.Computer; Ok = $true; DryRun = $true; Data = $null; Error = $null }; continue }
    $a = @($s.Args)
    try {
      $sb = [scriptblock]::Create($s.Script)
      $d = if ($s.Local) { & $sb @a } else { Invoke-Command -ComputerName $s.Computer -ScriptBlock $sb -ArgumentList $a -SessionOption $so -ErrorAction Stop }
      $d = @($d) | Select-Object -Last 1
      $ok = [bool]($d -and $d.Ok)
      [pscustomobject]@{ Name = $s.Name; Label = $s.Label; Computer = $s.Computer; Ok = $ok; DryRun = $false; Data = $d; Error = $(if ($d -and $d.PSObject.Properties['Error']) { $d.Error }) }
      if (-not $ok -and $s.StopOnFail) { break }
    } catch {
      [pscustomobject]@{ Name = $s.Name; Label = $s.Label; Computer = $s.Computer; Ok = $false; DryRun = $false; Data = $null; Error = $_.Exception.Message }
      if ($s.StopOnFail) { break }
    }
  }
}
function Test-VdiDryRun { $env:OTR_MANAGER_VDI_DRYRUN -eq '1' }
function Test-VdiStale([datetime]$received, [datetime]$now) { (-not $received) -or ($now - $received).TotalMinutes -gt $script:VdiStaleMinutes }

# Kind: BrokerRestart, BrokerPurge, BrokerSelfRepair, BrokerAddToGroup, HostPermissions, HostUnblock, HostOfflineAction
# (Target = the broker or host name, Arg = the service for HostUnblock); VmStart, VmRestart, VmShutdown, SessionLogoff,
# SessionDisconnect, SessionMessage, SessionShadow, AssignDesktop (Target = a row; Arg = the message, or the new VM).
# $state: @{ Model; Received (when the data arrived); Running (an action running now, its kind and target) }
function Get-VdiActionPlan([string]$kind, $target, $state, [datetime]$now, $arg = $null) {
  $m = $state.Model
  $p = [pscustomobject]@{ Kind = $kind; Title = (Get-Text "VdiAct_$kind"); Text = ''; Blocked = $null; Destructive = $false; DefaultNo = $false; Steps = @(); Log = ''; Target = $target; Arg = $arg }
  $stale = Test-VdiStale $state.Received $now
  $b = $null; $h = $null; $r = $null
  if ($kind -like 'Broker*') { $b = @($m.Brokers | Where-Object { $_.Name -eq $target }) | Select-Object -First 1; if (-not $b) { $p.Blocked = Get-Text 'VdiBlkUnknown' $target; return $p } }
  if ($kind -like 'Host*') { $h = @($m.Hosts | Where-Object { $_.Name -eq $target }) | Select-Object -First 1; if (-not $h) { $p.Blocked = Get-Text 'VdiBlkUnknown' $target; return $p } }
  if ($kind -like 'Vm*' -or $kind -like 'Session*' -or $kind -eq 'AssignDesktop') { $r = $target }
  if ($state.Running) { $p.Blocked = Get-Text 'VdiBlkRunning' $state.Running; return $p }
  switch ($kind) {
    'BrokerRestart' {
      $p.Destructive = $true; $p.DefaultNo = $true
      # never two brokers at once, and only while another one serves the sign-ins
      $others = @($m.Brokers | Where-Object { $_.Name -ne $b.Name })
      $good = @($others | Where-Object { $_.Healthy })
      $fresh = @($others | Where-Object { $t = ConvertFrom-VdiTime (@($_.Services | Where-Object Name -eq 'Tssdis') | Select-Object -First 1).Since; $t -and ($now - $t).TotalMinutes -lt 5 })
      if (-not $b.Reachable) { $p.Blocked = Get-Text 'VdiBlkUnreachable' $b.Name }
      elseif (-not $others.Count) { $p.Blocked = Get-Text 'VdiBlkOnlyBroker' $b.Name }
      elseif (-not $good.Count) { $p.Blocked = Get-Text 'VdiBlkNoOther' $b.Name (($others | ForEach-Object Name) -join ', ') }
      elseif ($fresh.Count) { $p.Blocked = Get-Text 'VdiBlkOtherFresh' (($fresh | ForEach-Object Name) -join ', ') }
      $p.Text = Get-Text 'VdiConfBrokerRestart' $b.Name (($good | ForEach-Object Name) -join ', ')
      $p.Steps = @(New-VdiStep 'restart broker services' $b.Fqdn 'Restart' @('RDMS,TScPubRPC,Tssdis', 'Tssdis,TScPubRPC,RDMS', 25, '0x3e4'))
      $p.Log = "restart the broker services (Tssdis, TScPubRPC, RDMS) on $($b.Name), tickets of NETWORK SERVICE purged"
    }
    'BrokerPurge' {
      if (-not $b.Reachable) { $p.Blocked = Get-Text 'VdiBlkUnreachable' $b.Name }
      $p.Text = Get-Text 'VdiConfPurge' $b.Name
      $p.Steps = @(New-VdiStep 'purge tickets' $b.Fqdn 'Purge' @('0x3e4'))
      $p.Log = "purge the Kerberos tickets of NETWORK SERVICE (0x3e4) on $($b.Name)"
    }
    'BrokerSelfRepair' {
      if (-not $b.Reachable) { $p.Blocked = Get-Text 'VdiBlkUnreachable' $b.Name }
      elseif (-not (Test-Path -LiteralPath $script:VdiInstallScript)) { $p.Blocked = Get-Text 'VdiBlkNoScript' $script:VdiInstallScript }
      elseif ($b.Task -and @($b.Task.Names).Count -and -not $b.Task.Ours) { $p.Blocked = Get-Text 'VdiBlkOtherTask' (@($b.Task.Names) -join ', ') }
      $p.Text = Get-Text 'VdiConfRepair' $b.Name $script:VdiRepairTask
      $p.Steps = @(New-VdiStep 'install self-repair' '' 'InstallRepair' @($script:VdiInstallScript, $b.Fqdn))
      $p.Log = "install or update the task '$($script:VdiRepairTask)' on $($b.Name)"
    }
    'BrokerAddToGroup' {
      $sid = @($b.Sids) | Select-Object -First 1
      if (-not $m.Group -or -not $m.Group.Sid) { $p.Blocked = Get-Text 'VdiBlkNoGroup' }
      elseif (-not $sid) { $p.Blocked = Get-Text 'VdiBlkNoAccount' $b.Name }
      elseif (-not $b.Reachable) { $p.Blocked = Get-Text 'VdiBlkUnreachable' $b.Name }
      $p.Text = Get-Text 'VdiConfAddToGroup' $b.Name $(if ($m.Group) { $m.Group.Name })
      $p.Steps = @((New-VdiStep 'add to AD group' '' 'AddToGroup' @($(if ($m.Group) { $m.Group.Sid }), $sid)), (New-VdiStep 'purge tickets' $b.Fqdn 'Purge' @('0x3e4,0x3e7') $false))
      $p.Log = "add $($b.Name) to the AD group $(if ($m.Group) { $m.Group.Name }), tickets of the broker purged"
    }
    'HostPermissions' {
      # the group of the settings when there is one (permissions to groups, not to computers), else each broker
      $need = @()
      foreach ($g in @($h.Groups | Where-Object Read)) {
        $mem = @($g.Members | ForEach-Object Sid)
        foreach ($x in @($m.Brokers | Where-Object { @($_.Sids).Count })) { if (-not @($x.Sids | Where-Object { $mem -contains $_ }).Count) { $need += [pscustomobject]@{ Group = $g.Sid; Broker = $x } } }
      }
      $groups = @($need | ForEach-Object Group | Select-Object -Unique)
      $useGroup = $m.Group -and $m.Group.Sid
      $members = if ($useGroup) { @($m.Group.Sid) } else { @($need | ForEach-Object { @($_.Broker.Sids)[0] } | Select-Object -Unique) }
      $who = if ($useGroup) { $m.Group.Name } else { (@($need | ForEach-Object { $_.Broker.Name } | Select-Object -Unique)) -join ', ' }
      if (-not $h.Reachable) { $p.Blocked = Get-Text 'VdiBlkUnreachable' $h.Name }
      elseif (-not $need.Count) { $p.Blocked = Get-Text 'VdiBlkNothing' }
      elseif ($useGroup) {
        # the group helps only the brokers that are in it
        $out = @($need | Where-Object { @($_.Broker.Sids) -notcontains $m.Group.Sid } | ForEach-Object { $_.Broker.Name } | Select-Object -Unique)
        if ($out.Count) { $p.Blocked = Get-Text 'VdiBlkNotInGroup' ($out -join ', ') $m.Group.Name }
      }
      $gn = @{ 'S-1-5-32-576' = (Get-Text 'VdiGroup576'); 'S-1-5-32-577' = (Get-Text 'VdiGroup577'); 'S-1-5-32-578' = (Get-Text 'VdiGroup578') }
      $p.Text = Get-Text 'VdiConfPerm' $h.Name $who ((@($groups | ForEach-Object { $gn[$_] })) -join ', ') ((@($m.Brokers | Where-Object Reachable | ForEach-Object Name)) -join ', ')
      $brokerFqdns = @($m.Brokers | Where-Object Reachable | ForEach-Object Fqdn)
      $p.Steps = @(New-VdiStep 'add to local groups' $h.Fqdn 'AddLocal' @(($groups -join ','), ($members -join ',')))
      foreach ($f in $brokerFqdns) { $p.Steps += New-VdiStep 'purge tickets' $f 'Purge' @('0x3e4') $false }
      $p.Log = "add $who to $(($groups | ForEach-Object { $script:VdiGroupEn[$_] }) -join ', ') on $($h.Name), tickets of the brokers purged"
    }
    'HostUnblock' {
      $svc = if ($arg) { [string]$arg } else { 'VmHostAgent' }
      $p.Destructive = $true
      if (-not $h.Reachable) { $p.Blocked = Get-Text 'VdiBlkUnreachable' $h.Name }
      elseif ($svc -notin 'VmHostAgent', 'vmms') { $p.Blocked = Get-Text 'VdiBlkUnknown' $svc }
      $p.Text = Get-Text $(if ($svc -eq 'vmms') { 'VdiConfUnblockVmms' } else { 'VdiConfUnblock' }) $h.Name
      $p.Steps = @(New-VdiStep "unblock $svc" $h.Fqdn 'Restart' @($svc, $svc, 20, ''))
      $p.Log = "unblock $svc on $($h.Name) (stopped with a time limit, its process ended if stuck, started)"
    }
    'HostOfflineAction' {
      $vms = @(@($h.Vms) | Where-Object { $_ -and $_.Tpm -and $_.Clustered -and $null -ne $_.OfflineAction -and [int]$_.OfflineAction -eq 1 } | ForEach-Object Name)
      if (-not $h.Reachable) { $p.Blocked = Get-Text 'VdiBlkUnreachable' $h.Name } elseif (-not $vms.Count) { $p.Blocked = Get-Text 'VdiBlkNothing' }
      $p.Text = Get-Text 'VdiConfOfflineAction' ($vms -join ', ')
      $p.Steps = @(New-VdiStep 'cluster OfflineAction 2' $h.Fqdn 'OfflineAction' @($vms -join ','))
      $p.Log = "cluster OfflineAction 2 (shut down, never save) for $($vms -join ', ')"
    }
    { $_ -in 'VmStart', 'VmRestart', 'VmShutdown' } {
      $hh = @($m.Hosts | Where-Object { $_.Name -eq $r.Host }) | Select-Object -First 1
      $vi = $r.VmInfo
      $p.Destructive = $kind -ne 'VmStart'
      if (-not $r.Vm -or -not $vi) { $p.Blocked = Get-Text 'VdiBlkNoVm' }
      elseif (-not $hh -or -not $hh.Reachable) { $p.Blocked = Get-Text 'VdiBlkUnreachable' $r.Host }
      elseif ($r.Rdsh) { $p.Blocked = Get-Text 'VdiBlkRdsh' $r.Vm }
      elseif ($kind -eq 'VmStart' -and $vi.State -eq 'Running') { $p.Blocked = Get-Text 'VdiBlkRunningVm' $r.Vm }
      elseif ($kind -ne 'VmStart' -and $vi.State -ne 'Running') { $p.Blocked = Get-Text 'VdiBlkNotRunning' $r.Vm }
      $users = @(@($m.Rows | Where-Object { $_.Vm -ieq $r.Vm -and $_.Session } | ForEach-Object User) | Select-Object -Unique)
      $who = if ($users.Count) { Get-Text 'VdiConfVmUsers' ($users -join ', ') } else { Get-Text 'VdiConfVmNoUsers' }
      $p.DefaultNo = [bool]$users.Count
      $p.Text = switch ($kind) {
        'VmStart' { Get-Text 'VdiConfVmStart' $r.Vm $r.Host $(if ($vi.State -eq 'Saved' -and $vi.Tpm) { Get-Text 'VdiConfSavedTpm' } else { '' }) }
        'VmRestart' { Get-Text 'VdiConfVmRestart' $r.Vm $r.Host $who }
        default { Get-Text 'VdiConfVmShutdown' $r.Vm $r.Host $who }
      }
      $act = switch ($kind) { 'VmStart' { 'start' } 'VmRestart' { 'restart' } default { 'shutdown' } }
      $p.Steps = @(New-VdiStep "VM $act" $(if ($hh) { $hh.Fqdn } else { '' }) 'VmPower' @($r.Vm, $act, 300))
      $p.Log = "VM $($r.Vm) on $($r.Host): $act$(if ($act -ne 'start') { ' (a shutdown of Windows, never saved)' })$(if ($users.Count) { "; signed in: $($users -join ', ')" })"
    }
    { $_ -in 'SessionLogoff', 'SessionDisconnect', 'SessionMessage', 'SessionShadow' } {
      $s = $r.Session
      $p.Destructive = $kind -in 'SessionLogoff', 'SessionDisconnect'
      $p.DefaultNo = $kind -eq 'SessionLogoff'
      if (-not $s) { $p.Blocked = Get-Text 'VdiBlkNoSession' $r.User }
      elseif ($kind -eq 'SessionDisconnect' -and $s.State -ne 'active') { $p.Blocked = Get-Text 'VdiBlkNotActive' $r.User }
      elseif ($kind -eq 'SessionShadow' -and $s.State -ne 'active') { $p.Blocked = Get-Text 'VdiBlkNotActive' $r.User }
      elseif ($kind -eq 'SessionMessage' -and -not "$arg".Trim()) { $p.Blocked = Get-Text 'VdiBlkNoText' }
      $vm = if ($s) { $s.Vm } else { $r.Vm }; $id = if ($s) { $s.Id } else { 0 }
      switch ($kind) {
        'SessionLogoff' { $p.Text = Get-Text 'VdiConfLogoff' $r.User $vm; $p.Steps = @(New-VdiStep 'log off' '' 'Logoff' @($vm, $id)); $p.Log = "log off $($r.User) on $vm (session $id)" }
        'SessionDisconnect' { $p.Text = Get-Text 'VdiConfDisconnect' $r.User $vm; $p.Steps = @(New-VdiStep 'disconnect' '' 'Disconnect' @($vm, $id)); $p.Log = "disconnect $($r.User) on $vm (session $id)" }
        'SessionMessage' { $p.Text = Get-Text 'VdiConfMessage' $r.User $vm "$arg"; $p.Steps = @(New-VdiStep 'message' '' 'Message' @($vm, $id, (Get-Text 'VdiMessageTitle'), "$arg")); $p.Log = "message to $($r.User) on ${vm}: $arg" }
        'SessionShadow' { $p.Text = Get-Text 'VdiConfShadow' $r.User $vm; $p.Steps = @(New-VdiStep 'shadow policy' $vm 'ShadowPolicy' @() $false); $p.Log = "shadow the session of $($r.User) on $vm (session $id)" }
      }
    }
    'AssignDesktop' {
      $act = $m.Active
      $coll = @($m.Collections | Where-Object { $_.Kind -eq 'vm' -and ($_.Alias -ieq $r.Collection -or -not $r.Collection) }) | Select-Object -First 1
      # '*' = the desktop is still to be chosen (whether the button can be offered at all)
      $choose = "$arg" -eq '*'
      $new = if ($choose) { '' } else { "$arg" }; $old = if ($r.Vm -and $r.Collection) { $r.Vm } else { '' }
      $owner = if ($new) { @($m.Rows | Where-Object { $_.Vm -ieq $new -and $_.Collection -and $_.UserKey -ne $r.UserKey -and $_.UserKey } | ForEach-Object User) | Select-Object -First 1 } else { $null }
      if (-not $act) { $p.Blocked = Get-Text 'VdiBlkNoActive' }
      elseif (-not $coll) { $p.Blocked = Get-Text 'VdiBlkNoCollection' }
      elseif (-not $r.UserKey) { $p.Blocked = Get-Text 'VdiBlkNoUser' }
      elseif ($owner) { $p.Blocked = Get-Text 'VdiBlkOwned' $new $owner }
      elseif (-not $choose -and $new -ieq $old) { $p.Blocked = Get-Text 'VdiBlkNothing' }
      $user = if ($r.Domain) { "$($r.Domain)\$($r.User)" } else { $r.User }
      $p.Text = if ($new -and $old) { Get-Text 'VdiConfAssignChange' $r.User $old $new } elseif ($new) { Get-Text 'VdiConfAssign' $r.User $new } else { Get-Text 'VdiConfUnassign' $r.User $old }
      $p.Steps = @(New-VdiStep 'assign desktop' $(if ($act) { $act.Fqdn } else { '' }) 'Assign' @($(if ($coll) { $coll.Name } else { '' }), $user, $new, $old))
      $p.Log = "personal desktop of $($r.User): $(if ($old) { $old } else { 'none' }) -> $(if ($new) { $new } else { 'none' })"
    }
    default { $p.Blocked = Get-Text 'VdiBlkUnknown' $kind }
  }
  if (-not $p.Blocked -and $p.Destructive -and $stale) { $p.Blocked = Get-Text 'VdiBlkStale' (Format-VdiClock $state.Received $now) }
  # a single step is the action itself: its title says it in the language of the window
  if (@($p.Steps).Count -eq 1) { $p.Steps[0].Label = $p.Title }
  $p
}
