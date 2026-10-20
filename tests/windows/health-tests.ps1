<#
  Tests of the Health Center of the manager (OtrHealth.ps1), in Windows PowerShell 5.1 as administrators run it (CI:
  windows-latest): the model, the checks and the action plans from recorded data (fixtures\health: a failover cluster
  of two Hyper-V hosts, two domain controllers, an AlwaysOn availability group, devices and a backup log), variants of
  it (a single host, a lost witness, a paused node, a stopped service...), the choice of the repairs that run by
  themselves, the remote scripts against pretend cmdlets, the settings. No server, no network beyond this PC, nothing
  changed: the actions run only in their dry-run mode.
  Start:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows\health-tests.ps1
  Exit code = the number of failed tests.
#>
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$mw = Join-Path $root 'management\windows'
$fx = Join-Path $PSScriptRoot 'fixtures'
$script:Passed = 0; $script:Failed = 0
function ok([string]$name, [scriptblock]$test) {
  $why = ''
  try { $r = & $test } catch { $r = $false; $why = " ($($_.Exception.Message) line $($_.InvocationInfo.ScriptLineNumber))" }
  if ($r) { $script:Passed++; Write-Host "ok   $name" } else { $script:Failed++; Write-Host "FAIL $name$why" -ForegroundColor Red }
}
function Get-Commands($ast) { @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ }) }
function Copy-Raw { Get-Content -LiteralPath (Join-Path $fx 'health\raw.json') -Raw | ConvertFrom-Json }

# ---- the files: a script without a BOM is read as ANSI by Windows PowerShell 5.1: ASCII only
foreach ($f in 'OtrHealth.ps1', 'OtrVdi.ps1', 'OpenThinRDP-Manager.ps1') {
  ok "$f`: ASCII only" { -not @([IO.File]::ReadAllBytes((Join-Path $mw $f)) | Where-Object { $_ -gt 127 }).Count }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) "otr-health-$(Get-Random)"
Copy-Item -LiteralPath (Join-Path $fx 'vdi\folder') -Destination $tmp -Recurse
try {
  $env:OTR_MANAGER_SETTINGS = Join-Path $tmp 'manager.json'
  . (Join-Path $mw 'OpenThinRDP-Manager.ps1') -Folder $tmp -FunctionsOnly -Language en
  ok 'OtrHealth.ps1 loads with the manager, its settings where the tests say' { $script:HealthLoaded -and $script:SettingsFile -eq (Join-Path $tmp 'manager.json') }

  # ---- the scripts that run on the servers: never what waits for ever, saves, switches off or stops a whole role
  $bad = 'Restart-Service', 'Stop-Service', 'Start-Service', 'Save-VM', 'Suspend-VM', 'Stop-ClusterGroup', 'Stop-ClusterNode', 'Stop-Computer', 'Restart-Computer', 'Move-ClusterGroup', 'Remove-VM'
  foreach ($k in @($script:HealthRemote.Keys | Sort-Object)) {
    $s = $script:HealthRemote[$k].ToString(); $a = [System.Management.Automation.Language.Parser]::ParseInput($s, [ref]$null, [ref]$null)
    ok "remote script $k`: none of $($bad.Count) forbidden commands, never -TurnOff or -Save" { -not @(Get-Commands $a | Where-Object { $bad -contains $_ }).Count -and $s -notmatch '-TurnOff' -and $s -notmatch '-Save\b' }
  }
  $probe = $script:HealthProbe.ToString(); $pa = [System.Management.Automation.Language.Parser]::ParseInput($probe, [ref]$null, [ref]$null)
  $verbs = @(Get-Commands $pa | Where-Object { $_ -match '^(Set|Start|Stop|Restart|Remove|Add|New|Suspend|Resume|Move|Clear|Enable|Disable|Invoke-Sql)-' -and $_ -notin 'New-Object', 'New-PSSessionOption', 'Add-Member' })
  ok "the probe changes nothing: no Set/Start/Stop/Remove/Add... command ($($verbs -join ', '))" { -not $verbs.Count }
  ok 'the probe: SQL only SELECT, the clock over SNTP (not w32tm /stripchart, localised and failing on servers with NTP)' {
    $q = @([regex]::Matches($probe, 'Invoke-Sql \S+ "([^"]+)"') | ForEach-Object { $_.Groups[1].Value }) + @([regex]::Matches($probe, "Invoke-Sql \S+ '([^']+)'") | ForEach-Object { $_.Groups[1].Value }); $q.Count -ge 8 -and -not @($q | Where-Object { ($_ -notmatch '^SELECT ' -and $_ -notmatch '^EXEC master\.dbo\.xp_readerrorlog ') -or ($_ -notmatch '^EXEC master\.dbo\.xp_readerrorlog [0-9, ]+N''\w+''$' -and $_ -match '(?i)\b(ALTER|UPDATE|INSERT|DELETE|DROP|EXEC)\b') }).Count -and $probe -match '0x1B' -and $probe -notmatch '& w32tm.exe /stripchart' }
  ok 'the probe: param() first in the scripts made of the shared functions' { @([regex]::Matches($probe, "\[scriptblock\]::Create\('param\(\`$pdc\)'")).Count -ge 4 }

  $now = [datetime]'2026-10-19T09:30:00'
  $raw = Copy-Raw
  $set = Get-HealthDefaults
  $m = ConvertTo-HealthModel $raw $null $now $set
  $node = { param($id) $m.Index[$id] }
  $chk = { param($id, $cid) @($m.Index[$id].Checks | Where-Object { $_.Id -eq $cid }) }

  # ---- texts: every check has a title, a sentence and an explanation in English and Italian
  $code = [IO.File]::ReadAllText((Join-Path $mw 'OtrHealth.ps1'))
  $ids = @([regex]::Matches($code, "Add-HcCheck \`$\w+(?:\[[^\]]+\])? (?:'\w+'|\`$\(if[^)]*\)[^)]*\)|\`$\w+) (?:\`$\(if \([^)]*\) \{ '(\w+)' \} else \{ '(\w+)' \}\)|'(\w+)')") | ForEach-Object { $_.Groups[1].Value, $_.Groups[2].Value, $_.Groups[3].Value } | Where-Object { $_ } | Sort-Object -Unique)
  $en = $script:Text
  $missing = @($ids | Where-Object { -not $en.ContainsKey("HcT_$_") -or -not $en.ContainsKey("HcX_$_") })
  ok "every check ($($ids.Count)) has HcT_ and HcX_ $(if ($missing.Count) { "(missing: $($missing -join ', '))" })" { $ids.Count -ge 60 -and -not $missing.Count }
  $kinds = 'ServiceStart', 'SqlStartService', 'ServiceUnstick', 'NetlogonRestart', 'TimeSync', 'TimeDomain', 'WitnessOnline', 'ClusterOfflineAction', 'ClusterDrainOnShutdown', 'ClusterGroupStart', 'HostDrain', 'HostResume',
    'VmStart', 'VmRestart', 'VmShutdown', 'VmResume', 'VmRoleOnline', 'VmRemoveCheckpoints', 'VmStopAction', 'DcSyncAll', 'DnsReverseZone', 'SqlResume', 'DeviceWake', 'HostMoveAll', 'CustomRepair', 'ServerRestart', 'ServerShutdown'
  ok 'every action has its title and its plan' { -not @($kinds | Where-Object { -not $en.ContainsKey("HcAct_$_") -or (Get-HealthActionPlan $_ 'x' @{ Model = $m } $now).Blocked -ne (Get-Text 'VdiBlkUnknown' 'x') }).Count }

  # ---- the model of the recorded site
  ok 'the tree: cluster > hosts > VMs, domain > DCs and DNS, SQL > replicas, brokers, devices, backups' {
    (& $node 'cluster:VDICL') -and (& $node 'host:HV1').Parent -eq 'cluster:VDICL' -and (& $node 'vm:VM-ALICE').Parent -eq 'host:HV1' -and (& $node 'dc:DC1').Parent -eq 'domain:EXAMPLE.COM' -and
    (& $node 'dns').Parent -eq 'domain:EXAMPLE.COM' -and (& $node 'replica:SQL2').Parent -eq 'sql:SQLHA.EXAMPLE.COM' -and (& $node 'broker:RDCB1').Parent -eq 'rds' -and (& $node 'device:NAS2').Parent -eq 'devices' -and (& $node 'backup') -and -not (& $node 'hyperv') }
  ok 'the headline: 2 problems, 10 warnings, the error first' { $m.Errors -eq 2 -and $m.Warnings -eq 10 -and $m.HeadlineKind -eq 'error' -and $m.Problems[0].Check.Kind -eq 'error' -and $m.Headline -match '^Problems: 2, warnings: 10:' }
  ok 'VM-CAROL: saved with a vTPM is a problem, Start offered' { $x = @(& $chk 'vm:VM-CAROL' 'SavedTpm'); $x.Count -eq 1 -and $x[0].Kind -eq 'error' -and $x[0].Fix -eq 'VmStart' -and (& $node 'vm:VM-CAROL').Status -eq 'error' }
  ok 'the cluster: VM-CAROL would be saved (OfflineAction 1), fix with its name' { $x = @(& $chk 'cluster:VDICL' 'OfflineAction'); $x.Count -eq 1 -and $x[0].FixArg -eq 'VM-CAROL' }
  ok 'the cluster: if HV1 stops its VMs do not fit on HV2 (70 GB, 22 GB free)' { $x = @(& $chk 'cluster:VDICL' 'Room'); $x.Count -eq 1 -and $x[0].Text -match 'HV1' -and $x[0].Text -match '70 GB' }
  ok 'the cluster: witness, CSV, pool, live migration over Storage (Management excluded)' { $f = @((& $node 'cluster:VDICL').Facts | ForEach-Object { "$($_.Label)=$($_.Value)" }) -join '|'
    $f -match 'Witness=\\\\nas\.example\.com\\VDICL-Witness \(Online' -and $f -match 'Live migration=Storage$' -and $f -match 'Storage pool=S2D' -and -not @(& $chk 'cluster:VDICL' 'Migration').Count }
  ok 'HV2: 9 % free memory, restart pending, time from time.windows.com (fix: from the domain)' {
    @(& $chk 'host:HV2' 'Mem')[0].Kind -eq 'warn' -and @(& $chk 'host:HV2' 'Reboot').Count -eq 1 -and @(& $chk 'host:HV2' 'TimeSource')[0].Fix -eq 'TimeDomain' -and -not @(& $chk 'host:HV1' 'TimeSource').Count }
  ok 'HV1: the System log is a note, not a problem; its state OK with a problem below' { @(& $chk 'host:HV1' 'Errors')[0].Kind -eq 'info' -and (& $node 'host:HV1').Own -eq 'ok' -and (& $node 'host:HV1').Status -eq 'warn' }
  ok 'VM-SPARE: two checkpoints, the oldest 8 days old' { $x = @(& $chk 'vm:VM-SPARE' 'Checkpoints'); $x.Count -eq 1 -and $x[0].Text -match '^2, the oldest from 8 days' -and $x[0].Fix -eq 'VmRemoveCheckpoints' }
  ok 'VM-ERIN: off is not a problem (grey)' { (& $node 'vm:VM-ERIN').Status -eq 'off' -and -not @((& $node 'vm:VM-ERIN').Checks | Where-Object { $_.Kind -in 'error', 'warn' }).Count }
  ok 'DNS: HV2 resolves to its storage address too, the reverse lookup slow, no reverse zone for 198.51.100' {
    @(& $chk 'dns' 'TwoAddresses').Count -eq 1 -and @(& $chk 'dns' 'SlowPtr')[0].Text -match '4810' -and @(& $chk 'dns' 'NoReverseZone')[0].FixArg -eq '198.51.100' -and -not @(@(& $chk 'dns' 'NoReverseZone') | Where-Object { $_.FixArg -eq '192.0.2' }).Count }
  ok 'DCs: healthy, PDC with an NTP source, FSMO roles on DC1' { (& $node 'dc:DC1').Status -eq 'ok' -and (& $node 'dc:DC2').Status -eq 'ok' -and @((& $node 'domain:EXAMPLE.COM').Facts | Where-Object { $_.Value -match 'DC1 \(PDC, RID, Infrastructure, Schema, Naming\)' }).Count }
  ok 'SQL2: the job "Backup - Logs" is missing there; logins alike' { @(& $chk 'replica:SQL2' 'JobsMissing')[0].Text -match 'Backup - Logs' -and -not @(& $chk 'replica:SQL2' 'LoginsMissing').Count -and -not @(& $chk 'replica:SQL1' 'JobsMissing').Count }
  ok 'SQL: the backups of RDCB and AppDB are recent (made on SQL1 only)' { -not @(& $chk 'sql:SQLHA.EXAMPLE.COM' 'SqlBackup').Count -and -not @(& $chk 'sql:SQLHA.EXAMPLE.COM' 'SqlNoBackup').Count }
  ok 'nas2 does not answer, Wake-on-LAN offered; nas is the witness of VDICL' { @(& $chk 'device:NAS2' 'DeviceDown')[0].Fix -eq 'DeviceWake' -and @((& $node 'device:NAS').Facts | Where-Object { $_.Value -eq 'VDICL' }).Count }
  ok 'the backup log: last at 02:41, 6 hours ago' { (& $node 'backup').Status -eq 'ok' -and @((& $node 'backup').Facts | Where-Object { $_.Value -match '02:41, 6 hours ago' }).Count }

  # ---- with the Desktops page: its findings on brokers and hosts, shown where they belong, never twice
  $rawV = Get-Content -LiteralPath (Join-Path $fx 'vdi\raw.json') -Raw | ConvertFrom-Json
  ($rawV.Brokers | Where-Object Name -eq 'RDCB1').Task.Hash = Get-VdiRepairHash
  $devs = @(Get-Devices); foreach ($d in $devs) { $d.Minutes = [int]($now - $d.When).TotalMinutes }
  $vm = ConvertTo-VdiModel $rawV $devs $now
  $mv = ConvertTo-HealthModel (Copy-Raw) $vm $now $set
  $vc = @($mv.Index['host:HV2'].Checks | Where-Object Source -eq 'vdi')
  ok 'HV2: the missing permission of RDCB2, found by the Desktops page, with its fix' { $vc.Count -eq 1 -and $vc[0].Fix -eq 'HostPermissions' -and $vc[0].Title -eq (Get-Text 'HcVdi_HostPermissions') }
  ok 'the vTPM VMs that would be saved: on the cluster only, not again from the Desktops page' { -not @($mv.Nodes | ForEach-Object { $_.Checks } | Where-Object { $_.Fix -eq 'HostOfflineAction' }).Count -and @($mv.Index['cluster:VDICL'].Checks | Where-Object Id -eq 'OfflineAction').Count -eq 1 }
  ok 'RDCB2: fails every sign-in (Desktops page), restart offered; VM-ALICE: the desktop of alice' {
    @($mv.Index['broker:RDCB2'].Checks | Where-Object { $_.Source -eq 'vdi' -and $_.Fix -eq 'BrokerRestart' }).Count -eq 1 -and @($mv.Index['vm:VM-ALICE'].Facts | Where-Object { $_.Value -eq 'alice' }).Count -and $mv.Index['vm:VM-ALICE'].Actions -contains 'OpenDesktops' }

  # ---- every check of an item with its result: the OK rows too, never next to a problem of the same group
  $hv1 = $m.Index['host:HV1']
  ok 'HV1: OK rows for what was checked and found good (memory, services, clock), none for a group with a problem' {
    $okIds = @($hv1.Checks | Where-Object Kind -eq 'ok' | ForEach-Object Id)
    $okIds -contains 'OkHvServices' -and $okIds -contains 'OkMem' -and @($m.Nodes | ForEach-Object { $n = $_; @($n.Checks | Where-Object Kind -eq 'ok' | Where-Object { $g = $_.Id.Substring(2); @($n.Done | Where-Object { $_.Group -eq $g } | ForEach-Object { $_.Ids } | Where-Object { $i = $_; @($n.Checks | Where-Object { $_.Kind -in 'error', 'warn' -and $_.Id -eq $i }).Count }).Count }) }).Count -eq 0 -and -not @($m.Problems | Where-Object { $_.Check.Kind -eq 'ok' }).Count }
  ok 'every OK row has a title in English and Italian' { -not @($m.Nodes | ForEach-Object { $_.Checks } | Where-Object { $_.Kind -eq 'ok' -and ($_.Title -like 'HcC_*' -or -not $_.Title) }).Count }

  # ---- RD Gateway and RD Web on a server: service, certificate, policies, port 443
  $rg = Copy-Raw; $gs = @($rg.Servers | Where-Object { $_.Name -eq 'RDCB1' })[0]
  $gs | Add-Member -NotePropertyName Gateway -NotePropertyValue ([pscustomobject]@{ State = 'Running'; CertFound = $true; Thumbprint = 'AB12'; Subject = 'CN=gw.example.com'; NotAfter = '2026-10-30T00:00:00'; Cap = 1; Rap = 0; Failed = 25; FailedText = 'user refused' }) -Force
  $gs | Add-Member -NotePropertyName Port443 -NotePropertyValue $false -Force
  $mg = ConvertTo-HealthModel $rg $null $now $set; $gc = @($mg.Index['broker:RDCB1'].Checks)
  ok 'RD Gateway: certificate expiring in 10 days, no resource policy, 443 closed, 25 failures (warning)' {
    @($gc | Where-Object Id -eq 'GwCertExpiring').Count -and @($gc | Where-Object Id -eq 'GwPolicies').Count -and @($gc | Where-Object Id -eq 'Gw443').Count -and @($gc | Where-Object { $_.Id -eq 'GwFailed' -and $_.Kind -eq 'warn' }).Count -and -not @($gc | Where-Object Id -eq 'OkGateway').Count }

  # ---- the thresholds of the settings
  ok 'thresholds: a known name with a whole number is taken, an unknown one refused, empty = the defaults' {
    $bad = @(ConvertFrom-HealthLimits 'DiskPct=12; Nope=3' | Where-Object Bad); Set-HealthLimits 'DiskPct=12'; $a = $script:HealthLimits.DiskPct; Set-HealthLimits ''
    $bad.Count -eq 1 -and $bad[0].Key -eq 'Nope' -and $a -eq 12 -and $script:HealthLimits.DiskPct -eq $script:HealthLimitsDefault.DiskPct -and (Test-HealthSettings ([pscustomobject]@{ Hosts = ''; DnsServers = ''; BrokerName = ''; Servers = ''; SqlListener = ''; Devices = ''; CriticalVms = ''; BackupPath = ''; BackupHours = 24; Limits = 'x=1' })) }

  # ---- custom checks: saved in config\health-checks, read back, shown on their server, the repair as risky says
  $script:ConfigDir = Join-Path $tmp 'config'; New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
  ok 'custom check: a name, a valid target and a script that parses are needed' {
    (Test-HealthCustomCheck ([pscustomobject]@{ Name = ''; Where = 'hosts'; Script = 'x' })) -and (Test-HealthCustomCheck ([pscustomobject]@{ Name = 'a'; Where = 'bad name!'; Script = 'x' })) -and (Test-HealthCustomCheck ([pscustomobject]@{ Name = 'a'; Where = 'hosts'; Script = 'if (' })) -and -not (Test-HealthCustomCheck ([pscustomobject]@{ Name = 'a'; Where = 'hosts'; Script = "@{ State = 'ok' }" })) }
  $cid = Save-HealthCustomCheck ([pscustomobject]@{ Name = 'Spooler stopped'; Where = 'hosts'; IntervalMin = 10; Description = 'why'; Script = "@{ State = 'ok'; Text = 'x' }"; Repair = 'Start-Service Spooler'; Risky = $false }) ''
  [void](Save-HealthCustomCheck ([pscustomobject]@{ Name = 'Risky one'; Where = 'HV2'; IntervalMin = 5; Description = ''; Script = "@{ State = 'ok' }"; Repair = 'Restart-Computer'; Risky = $true }) '')
  $defs = @(Get-HealthCustomChecks)
  ok 'custom checks: read back from the folder (json + scripts), the interval at least 3 minutes' { $defs.Count -eq 2 -and @($defs | Where-Object Id -eq $cid)[0].Repair -eq 'Start-Service Spooler' -and @($defs | Where-Object Name -eq 'Risky one')[0].IntervalMin -eq 5 }
  $rc = Copy-Raw; $rc | Add-Member -NotePropertyName Custom -NotePropertyValue @([pscustomobject]@{ Name = 'Spooler stopped'; Target = 'HV1'; State = 'error'; Text = 'stopped' }, [pscustomobject]@{ Name = 'Risky one'; Target = 'HV2'; State = 'warn'; Text = 'odd' }) -Force
  $mc = ConvertTo-HealthModel $rc $null $now $set
  $c1 = @($mc.Index['host:HV1'].Checks | Where-Object Id -eq 'Custom')[0]; $c2 = @($mc.Index['host:HV2'].Checks | Where-Object Id -eq 'Custom')[0]
  $p1 = Get-HealthCheckPlan $c1 @{ Model = $mc; Received = $now } $now; $p2 = Get-HealthCheckPlan $c2 @{ Model = $mc; Received = $now } $now
  ok 'custom checks: on their host like the others, the repair safe when not risky, asking (default No) when risky' {
    $c1.Kind -eq 'error' -and $c1.Title -eq 'Spooler stopped' -and $c1.Fix -eq 'CustomRepair' -and $p1.Safe -and -not $p1.Blocked -and $p1.Steps[0].Computer -eq 'HV1' -and -not $p2.Safe -and $p2.DefaultNo -and $mc.Index['custom'] }
  ok 'custom checks: the group says the interval and how the repair runs' { @($mc.Index['custom'].Facts | Where-Object { $_.Value -match 'every 10 min' }).Count -eq 1 }
  ok 'remote script CustomRun: runs the text given, ok on $true or State ok' { $sb = $script:HealthRemote['CustomRun']; (& $sb '$true' 10).Ok -and -not (& $sb "@{ State = 'error'; Text = 'no' }" 10).Ok -and (& $sb "@{ State = 'error'; Text = 'no' }" 10).Error -eq 'no' }
  Remove-Item -LiteralPath $script:ConfigDir -Recurse -Force

  # ---- move all the VMs of a node, without pausing it
  $pm = Get-HealthActionPlan 'HostMoveAll' 'host:HV1' @{ Model = $m } $now
  ok 'move all VMs of HV1: one live move per running clustered VM to HV2, the node not paused, default No' {
    $run = @($m.Index['host:HV1'].Data.Vms | Where-Object { $_.State -eq 'Running' -and $_.Clustered }).Count
    $pm.DefaultNo -and ($pm.Blocked -or (@($pm.Steps).Count -eq $run -and -not @($pm.Steps | Where-Object { $_.Script -ne 'MoveLive' -or $_.Args[1] -ne 'HV2' }).Count)) }

  ok 'VM-ALICE: the session, the actions on it and the personal desktop, as on the Distribution' { @('SessionShadow', 'SessionMessage', 'SessionDisconnect', 'SessionLogoff', 'AssignDesktop' | Where-Object { $mv.Index['vm:VM-ALICE'].Actions -notcontains $_ }).Count -eq 0 -and $mv.Index['vm:VM-ALICE'].Desktop }
  # ---- variants: a single host, without a cluster
  $rs = Copy-Raw; $rs.Clusters = @(); $rs.Hosts = @($rs.Hosts[0]); $rs.Hosts[0].Cluster = ''
  foreach ($v in $rs.Hosts[0].Vms) { $v.Clustered = $false; $v.OfflineAction = $null; $v.ResourceState = ''; $v.GroupState = '' }
  $ms = ConvertTo-HealthModel $rs $null $now $set
  ok 'a single host: under "Hyper-V hosts", its vTPM VMs saved when the host stops: a warning each, fix offered' {
    $ms.Index['host:HV1'].Parent -eq 'hyperv' -and @($ms.Index['vm:VM-ALICE'].Checks | Where-Object { $_.Id -eq 'StopSave' -and $_.Fix -eq 'VmStopAction' }).Count -and -not @($ms.Index['vm:VM-ALICE'].Checks | Where-Object Id -eq 'NotClustered').Count }
  ok 'a single host: no drain, no witness' { $st = @{ Model = $ms; Received = $now }; (Get-HealthActionPlan 'HostDrain' 'host:HV1' $st $now).Blocked -eq (Get-Text 'HcBlkNoCluster' 'HV1') -and -not $ms.Index['cluster:VDICL'] }
  ok 'a single host: set the stop action of a VM to a shutdown (asks)' { $x = Get-HealthActionPlan 'VmStopAction' 'vm:VM-ALICE' @{ Model = $ms; Received = $now } $now; -not $x.Blocked -and -not $x.Safe -and $x.Steps[0].Computer -eq 'hv1.example.com' }

  $yes = Get-HealthDefaults; $yes.Cluster = 'yes'
  ok 'Cluster = yes: a single host is said not to be in a cluster' { @((ConvertTo-HealthModel $rs $null $now $yes).Index['host:HV1'].Checks | Where-Object Id -eq 'NoCluster').Count -eq 1 -and -not @($ms.Index['host:HV1'].Checks | Where-Object Id -eq 'NoCluster').Count }
  $no = Get-HealthDefaults; $no.Cluster = 'no'; $rc = Copy-Raw; $rc.Clusters = @()
  ok 'Cluster = no: hosts on their own, the stop action of every VM judged' { $mn = ConvertTo-HealthModel $rc $null $now $no; $mn.Index['host:HV1'].Parent -eq 'hyperv' -and @($mn.Index['vm:VM-ALICE'].Checks | Where-Object Id -eq 'StopSave').Count -and -not @($mn.Index['vm:VM-ALICE'].Checks | Where-Object Id -eq 'NotClustered').Count }

  # ---- variants: the cluster
  $rw = Copy-Raw; $rw.Clusters[0].Witness.State = 'Failed'
  $mw2 = ConvertTo-HealthModel $rw $null $now $set; $sw = @{ Model = $mw2; Received = $now }
  ok 'witness failed: a problem; online again is safe; draining a node refused' {
    (@($mw2.Index['cluster:VDICL'].Checks | Where-Object Id -eq 'Witness'))[0].Kind -eq 'error' -and (Get-HealthActionPlan 'WitnessOnline' 'cluster:VDICL' $sw $now).Safe -and
    (Get-HealthActionPlan 'HostDrain' 'host:HV2' $sw $now).Blocked -eq (Get-Text 'HcBlkWitness' 'Failed') }
  $rp = Copy-Raw; $rp.Clusters[0].Nodes[1].State = 'Paused'
  $mp = ConvertTo-HealthModel $rp $null $now $set; $sp = @{ Model = $mp; Received = $now }
  ok 'HV2 paused: a warning, Resume allowed, draining HV1 refused (HV2 not up)' {
    @($mp.Index['host:HV2'].Checks | Where-Object { $_.Id -eq 'NodePaused' -and $_.Fix -eq 'HostResume' }).Count -and -not (Get-HealthActionPlan 'HostResume' 'host:HV2' $sp $now).Blocked -and
    (Get-HealthActionPlan 'HostDrain' 'host:HV1' $sp $now).Blocked -match 'HV2 \(Paused\)' }
  $st = @{ Model = $m; Received = $now }
  ok 'drain HV2: its 6 VMs (62 GB) fit on HV1 (192 GB free): allowed, asks, No by default' { $x = Get-HealthActionPlan 'HostDrain' 'host:HV2' $st $now; -not $x.Blocked -and -not $x.Safe -and $x.DefaultNo -and $x.Steps[0].Computer -eq 'hv2.example.com' -and $x.Text -match '62 GB' }
  ok 'drain HV1: its VMs do not fit on HV2: refused' { (Get-HealthActionPlan 'HostDrain' 'host:HV1' $st $now).Blocked -match 'Not now: its VMs need' }
  $rj = Copy-Raw; $rj.Clusters[0].Jobs = @([pscustomobject]@{ Name = 'Repair'; State = 'Running'; Percent = 40 }); $rj.Clusters[0].Pools[0].Health = 'Warning'
  $mj = ConvertTo-HealthModel $rj $null $now $set
  ok 'a storage repair running: a note, the pool a warning (not an error), no drain' {
    @($mj.Index['cluster:VDICL'].Checks | Where-Object { $_.Id -eq 'Jobs' -and $_.Kind -eq 'info' }).Count -and @($mj.Index['cluster:VDICL'].Checks | Where-Object { $_.Id -eq 'Pool' -and $_.Kind -eq 'warn' }).Count -and
    (Get-HealthActionPlan 'HostDrain' 'host:HV2' @{ Model = $mj; Received = $now } $now).Blocked -eq (Get-Text 'HcBlkJobs' 1) }
  $rg = Copy-Raw; $rg.Hosts[1].Guardians = @($rg.Hosts[1].Guardians | Where-Object { $_.Guardian -ne 'HV1' })
  ok 'the keys of the guardian HV1 missing on HV2: its vTPM VMs could not fail over there' { @((ConvertTo-HealthModel $rg $null $now $set).Index['host:HV2'].Checks | Where-Object { $_.Id -eq 'Guardian' -and $_.Text -match 'HV1' }).Count -eq 1 }
  $rn = Copy-Raw; $rn.Clusters[0].Networks[0].State = 'Down'
  ok 'the only network for live migration down: a problem' { @((ConvertTo-HealthModel $rn $null $now $set).Index['cluster:VDICL'].Checks | Where-Object { $_.Id -in 'Migration', 'Network' }).Count -eq 2 }
  $rh = Copy-Raw; ($rh.Hosts[0].Vms | Where-Object Name -eq 'VM-DAVE').Heartbeat = 'LostCommunication'; ($rh.Hosts[0].Vms | Where-Object Name -eq 'VM-FRANK').ResourceState = 'Offline'
  $mh = ConvertTo-HealthModel $rh $null $now $set
  ok 'a VM not responding: a problem, Restart offered (asks); a running VM whose role is offline: not watched' {
    @($mh.Index['vm:VM-DAVE'].Checks | Where-Object { $_.Id -eq 'Hung' -and $_.Fix -eq 'VmRestart' }).Count -and @($mh.Index['vm:VM-FRANK'].Checks | Where-Object { $_.Id -eq 'RoleOffline' -and $_.Fix -eq 'VmRoleOnline' }).Count }

  # ---- variants: the domain
  $rd = Copy-Raw
  ($rd.Dcs[1].Services | Where-Object Name -eq 'DNS').State = 'Stopped'
  ($rd.Dcs[1].Services | Where-Object Name -eq 'ADWS').State = 'Stopped'; ($rd.Dcs[1].Services | Where-Object Name -eq 'ADWS').StartMode = 'Disabled'
  $rd.Dcs[1].Replication[0].Failures = 4; $rd.Dcs[1].Replication[0].Status = '8453'
  $rd.Dcs[1].DnsOrder = @('127.0.0.1', '192.0.2.5'); $rd.Dcs[1].Skew = 312.5; $rd.Dcs[0].Ports.'389' = $false
  $md = ConvertTo-HealthModel $rd $null $now $set; $sd = @{ Model = $md; Received = $now }
  $dc2 = { param($id) @($md.Index['dc:DC2'].Checks | Where-Object Id -eq $id) }
  ok 'DC2: DNS stopped (start: safe), ADWS disabled (start: asks), replication failing from DC1, loopback first, 312 s off' {
    (Get-HealthCheckPlan @(& $dc2 'SvcStopped')[0] $sd $now).Safe -and -not (Get-HealthCheckPlan @(& $dc2 'SvcDisabled')[0] $sd $now).Safe -and
    @(& $dc2 'SvcDisabled')[0].FixArg -eq 'ADWS' -and @(& $dc2 'Repl')[0].Text -match 'DC1 \(4 failures, status 8453\)' -and @(& $dc2 'DnsLoopback').Count -and @(& $dc2 'Skew')[0].Kind -eq 'error' }
  ok 'DC2 and DC1 not alike: ADWS disabled on DC2' { @($md.Index['dc:DC2'].Checks | Where-Object { $_.Id -eq 'NotAlike' -and $_.Text -match 'ADWS' }).Count -eq 1 }
  ok 'DC1: LDAP closed from here, and with it its five FSMO roles' { @($md.Index['dc:DC1'].Checks | Where-Object { $_.Id -eq 'DcPort' }).Count -eq 1 -and @($md.Index['domain:EXAMPLE.COM'].Checks | Where-Object Id -eq 'Fsmo').Count -eq 5 }
  ok 'the plan to start ADWS on DC2 sets it to automatic first' { $x = Get-HealthCheckPlan @(& $dc2 'SvcDisabled')[0] $sd $now; $x.Steps[0].Args[0] -eq 'ADWS' -and $x.Steps[0].Args[1] -eq '1' -and $x.Text -match 'DISABLED' }
  ok 'unblock NTDS on DC1 while DC2 has problems: refused' {
    $md.Index['dc:DC2'].Own -eq 'error' -and (Get-HealthActionPlan 'ServiceUnstick' 'dc:DC1' $sd $now 'NTDS').Blocked -eq (Get-Text 'HcBlkNoOtherDc' 'DC1') }

  # ---- variants: SQL
  $rq = Copy-Raw
  $db = @($rq.Sql.Databases | Where-Object { $_.Replica -eq 'SQL2' -and $_.Db -eq 'AppDB' })[0]; $db.Suspended = 1; $db.Sync = 'NOT SYNCHRONIZING'; $db.Reason = 'SUSPEND_FROM_USER'
  $rq.Sql.Nodes[1].Logins = @($rq.Sql.Nodes[1].Logins | Where-Object Name -ne 'app_reader')
  ($rq.Sql.Nodes[1].Services | Where-Object Name -eq 'SQLSERVERAGENT').State = 'Stopped'
  $rq.Sql.Nodes[0].LastFull = @([pscustomobject]@{ Db = 'RDCB'; Last = '2026-10-17T01:10:00' })
  $mq = ConvertTo-HealthModel $rq $null $now $set; $sq = @{ Model = $mq; Received = $now }
  $q2 = { param($id) @($mq.Index['replica:SQL2'].Checks | Where-Object Id -eq $id) }
  ok 'SQL2: AppDB suspended (resume asks), app_reader missing, the Agent stopped (start: safe)' {
    @(& $q2 'DbSuspended')[0].Fix -eq 'SqlResume' -and -not (Get-HealthCheckPlan @(& $q2 'DbSuspended')[0] $sq $now).Safe -and @(& $q2 'LoginsMissing')[0].Text -match 'app_reader' -and
    (Get-HealthCheckPlan @(& $q2 'SvcStopped')[0] $sq $now).Safe -and (Get-HealthCheckPlan @(& $q2 'SvcStopped')[0] $sq $now).Steps[0].Computer -eq 'SQL2' }
  ok 'SQL: RDCB backed up 56 hours ago, AppDB never' { $c = @($mq.Index['sql:SQLHA.EXAMPLE.COM'].Checks); @($c | Where-Object { $_.Id -eq 'SqlBackup' -and $_.Text -match '56 hours' }).Count -and @($c | Where-Object { $_.Id -eq 'SqlNoBackup' -and $_.Text -match 'AppDB' }).Count }
  ok 'never two SQL replicas at once: SQL1 acted on 3 minutes ago, SQL2 waits' {
    $s2 = @{ Model = $mq; Received = $now; Recent = @([pscustomobject]@{ Role = 'sql'; Target = 'replica:SQL1'; Name = 'SQL1'; Time = $now.AddMinutes(-3) }) }
    (Get-HealthCheckPlan @(& $q2 'SvcStopped')[0] $s2 $now).Blocked -match 'SQL1' }
  ok 'SQL Server itself is never ended from here' { (Get-HealthActionPlan 'ServiceUnstick' 'replica:SQL2' $sq $now 'MSSQLSERVER').Blocked -eq (Get-Text 'HcBlkSqlKill') }
  ok 'resume AppDB on SQL2: here, through SqlClient, on the replica' { $x = Get-HealthCheckPlan @(& $q2 'DbSuspended')[0] $sq $now; $x.Steps[0].Local -and $x.Steps[0].Args[0] -eq 'SQL2' -and $x.Steps[0].Args[1] -eq 'AppDB' }

  # ---- the plans of the actions
  ok 'WinRM is never ended from here; vmms stuck: unblocking is safe' { (Get-HealthActionPlan 'ServiceUnstick' 'host:HV1' $st $now 'WinRM').Blocked -and (Get-HealthActionPlan 'ServiceUnstick' 'host:HV1' $st $now 'vmms').Safe }
  ok 'shut down VM-ALICE: destructive, never on old data' { $old = @{ Model = $m; Received = $now.AddMinutes(-10) }; $x = Get-HealthActionPlan 'VmShutdown' 'vm:VM-ALICE' $old $now; $x.Destructive -and $x.Blocked -match '09:20' }
  ok 'restart VM-ALICE with the Desktops page: names alice, No by default, the VM resource of its host' {
    $x = Get-HealthActionPlan 'VmRestart' 'vm:VM-ALICE' @{ Model = $mv; Vdi = $vm; Received = $now } $now; -not $x.Blocked -and $x.DefaultNo -and $x.Text -match 'ALICE' -and $x.Steps[0].Key -eq 'VmPower' -and $x.Steps[0].Args[1] -eq 'restart' }
  ok 'another action running: everything waits' { (Get-HealthActionPlan 'TimeSync' 'host:HV1' @{ Model = $m; Received = $now; Running = 'x' } $now).Blocked -match 'x' }
  ok 'the reverse zone on the PDC emulator, asks' { $x = Get-HealthActionPlan 'DnsReverseZone' 'dns' $st $now '198.51.100'; -not $x.Blocked -and -not $x.Safe -and $x.Steps[0].Computer -eq 'dc1.example.com' -and $x.Steps[0].Args[0] -eq '198.51.100' }
  ok 'wake nas2: safe, from here, with its MAC; nas answers already' { $x = Get-HealthActionPlan 'DeviceWake' 'device:NAS2' $st $now; $x.Safe -and $x.Steps[0].Local -and $x.Steps[0].Args[0] -eq '00-11-32-AA-BB-CC' -and (Get-HealthActionPlan 'DeviceWake' 'device:NAS' $st $now).Blocked }
  ok 'the dry run says every step and runs none' { $res = @(& $script:VdiJobRunner (Get-HealthActionPlan 'HostDrain' 'host:HV2' $st $now).Steps $true 1000 1000); $res.Count -eq 1 -and $res[0].DryRun -and $res[0].Ok }

  # ---- the repairs that run by themselves
  $sr = @{ Model = $md; Received = $now; Recent = @() }
  ok 'diagnosis only: nothing runs by itself' { -not @(Get-HealthAutoPlans $sr (Get-HealthDefaults) $now @{}).Count }
  $rep = Get-HealthDefaults; $rep.Mode = 'repair'
  $auto = @(Get-HealthAutoPlans $sr $rep $now @{})
  ok "repair mode: only the safe repairs, one server per role ($(($auto | ForEach-Object { "$($_.Kind) $($_.Target) $($_.Arg)" }) -join '; '))" {
    $auto.Count -ge 1 -and -not @($auto | Where-Object { -not $_.Safe -or $_.Blocked }).Count -and @($auto | Where-Object Role -eq 'dc' | ForEach-Object { $_.Node.Id } | Select-Object -Unique).Count -eq 1 -and @($auto | Where-Object { $_.Kind -eq 'ServiceStart' -and $_.Arg -eq 'DNS' }).Count -eq 1 -and -not @($auto | Where-Object { $_.Kind -eq 'ServiceStart' -and $_.Arg -eq 'ADWS' }).Count }
  ok 'repair mode: what was tried in the last 30 minutes waits' { $tried = @{}; foreach ($p in $auto) { $tried[$p.Key] = $now.AddMinutes(-5) }; $again = @(Get-HealthAutoPlans $sr $rep $now $tried); -not @($again | Where-Object { $tried.ContainsKey($_.Key) }).Count }
  $per = Get-HealthDefaults; Set-HealthItemMode $per 'domain:EXAMPLE.COM' 'repair'
  ok 'an item in repair mode under a page in diagnosis: its DCs too, nothing else' { $x = @(Get-HealthAutoPlans $sr $per $now @{}); $x.Count -ge 1 -and -not @($x | Where-Object { $_.Node.Kind -ne 'dc' -and $_.Node.Id -notlike 'domain:*' }).Count }
  $off = Get-HealthDefaults; $off.Mode = 'repair'; Set-HealthItemMode $off 'dc:DC2' 'diagnose'
  ok 'an item in diagnosis under a page in repair: left alone' { -not @(Get-HealthAutoPlans $sr $off $now @{} | Where-Object { $_.Node.Id -eq 'dc:DC2' }).Count }
  ok 'repair mode on the demo site with the Desktops page: the repair of the permissions of HV2 is safe and runs, restarting a broker too, the reverse zone never' {
    $x = @(Get-HealthAutoPlans @{ Model = $mv; Vdi = $vm; Received = $now; VdiReceived = $now } $rep $now @{})
    @($x | Where-Object { $_.Source -eq 'vdi' -and $_.Kind -eq 'HostPermissions' }).Count -eq 1 -and @($x | Where-Object { $_.Kind -eq 'ClusterOfflineAction' }).Count -eq 1 -and -not @($x | Where-Object { $_.Kind -in 'DnsReverseZone', 'TimeDomain', 'HostDrain' }).Count }

  # ---- the remote scripts against pretend cmdlets of the cluster
  $script:Fake = @{}
  function Suspend-ClusterNode { [CmdletBinding()] param($Name, [switch]$Drain, [switch]$Wait) [void]$script:Fake.Calls.Add("Suspend $Name $Drain"); if ($script:Fake.DrainMoves) { $script:Fake.Owner = 'HV1' }; $script:Fake.Node = 'Paused' }
  function Get-ClusterGroup { [CmdletBinding()] param($Name) @([pscustomobject]@{ Name = 'VM-X'; GroupType = 'VirtualMachine'; OwnerNode = $script:Fake.Owner; State = 'Online' }) }
  function Get-ClusterNode { [CmdletBinding()] param($Name) [pscustomobject]@{ Name = $Name; State = $script:Fake.Node } }
  function Resume-ClusterNode { [CmdletBinding()] param($Name, $Failback) [void]$script:Fake.Calls.Add("Resume $Name $Failback"); $script:Fake.Node = 'Up' }
  function Start-ClusterResource { [CmdletBinding()] param($Name, $Wait) [void]$script:Fake.Calls.Add("Start $Name"); $script:Fake.Res = 'Online' }
  function Get-ClusterResource { [CmdletBinding()] param($Name) [pscustomobject]@{ Name = $Name; State = $script:Fake.Res } }
  $script:Fake = @{ Calls = New-Object Collections.ArrayList; Owner = $env:COMPUTERNAME; Node = 'Up'; DrainMoves = $true; Res = 'Failed' }
  $x = & $script:HealthRemote.Drain
  ok 'drain: Suspend-ClusterNode -Drain on itself, done only when no VM role is left and the node is paused' { $x.Ok -and @($script:Fake.Calls)[0] -eq "Suspend $env:COMPUTERNAME True" -and $x.Lines[1] -match 'none' }
  $script:Fake = @{ Calls = New-Object Collections.ArrayList; Owner = $env:COMPUTERNAME; Node = 'Up'; DrainMoves = $false; Res = 'Failed' }
  $x = & $script:HealthRemote.Drain
  ok 'drain: a VM that stays on the node is a failure, said with its name' { -not $x.Ok -and $x.Error -match 'VM-X' }
  $x = & $script:HealthRemote.Resume
  ok 'resume: with the failback of its VMs' { $x.Ok -and @($script:Fake.Calls)[-1] -eq "Resume $env:COMPUTERNAME Immediate" }
  $x = & $script:HealthRemote.WitnessOnline 'File Share Witness'
  ok 'witness online: started and read back' { $x.Ok -and $x.Lines[0] -eq 'File Share Witness: Online' }
  foreach ($n in 'Suspend-ClusterNode', 'Get-ClusterGroup', 'Get-ClusterNode', 'Resume-ClusterNode', 'Start-ClusterResource', 'Get-ClusterResource') { Remove-Item "function:$n" }
  # a pretend service: ServiceController's Start/WaitForStatus/Refresh, never Start-Service
  function Get-Service { param($Name, $ErrorAction) $o = [pscustomobject]@{ Name = $Name; Status = $script:Svc.Status }
    $o | Add-Member ScriptMethod Start { $script:Svc.Started++; $script:Svc.Status = 'Running' }; $o | Add-Member ScriptMethod WaitForStatus { param($s, $t) }
    $o | Add-Member ScriptMethod Refresh { $this.Status = $script:Svc.Status }; $o }
  function Get-CimInstance { param($ClassName, $Filter, $ErrorAction) [pscustomobject]@{ StartMode = $script:Svc.Mode } }
  function Set-Service { param($Name, $StartupType, $ErrorAction) $script:Svc.Mode = 'Auto' }
  $script:Svc = @{ Status = 'Stopped'; Mode = 'Disabled'; Started = 0 }
  $x = & $script:HealthRemote.ServiceStart 'ADWS' '0' 5
  ok 'start a disabled service without leave: not touched' { -not $x.Ok -and $script:Svc.Started -eq 0 -and $script:Svc.Mode -eq 'Disabled' }
  $x = & $script:HealthRemote.ServiceStart 'ADWS' '1' 5
  ok 'start a disabled service when asked: automatic, started, read back' { $x.Ok -and $script:Svc.Started -eq 1 -and $x.Lines[0] -eq 'ADWS: Stopped (Disabled) -> Running (Auto)' }
  foreach ($n in 'Get-Service', 'Get-CimInstance', 'Set-Service') { Remove-Item "function:$n" }

  # ---- the probe on this PC alone: a device, a share, a backup log (no domain, no host, no SQL)
  $bk = Join-Path $tmp 'backup-logs'; New-Item -ItemType Directory -Path $bk | Out-Null
  Set-Content -LiteralPath (Join-Path $bk 'a.log') -Value 'backup completed successfully'; (Get-Item (Join-Path $bk 'a.log')).LastWriteTime = $now.AddDays(-3)
  Set-Content -LiteralPath (Join-Path $bk 'b.log') -Value 'backup FAILED'
  $cfg = @{ Hosts = @(); Brokers = @(); DnsServers = @(); SqlListener = ''; Devices = @((ConvertFrom-HealthDevice 'here 127.0.0.1 1'), (ConvertFrom-HealthDevice 'loop 127.0.0.1'))
    BackupPath = $bk; BackupText = 'completed successfully'; Cluster = 'auto'; Domain = $false; Guests = $false; OpenMs = 2000; OperationMs = 5000; JobDays = 3; BrokerName = @() }
  $p = & $script:HealthProbe $cfg
  ok 'probe alone: the device answers ping, port 1 closed; the backup: the newest file with the text of a success' {
    @($p.Devices).Count -eq 2 -and $p.Devices[0].Ping -and -not $p.Devices[0].Ports[0].Open -and $p.Backup.File -like '*a.log' -and $p.Backup.Matched -and -not @($p.Hosts).Count }
  $mp2 = ConvertTo-HealthModel $p $null (Get-Date) $set
  ok 'probe alone: the model of it (a closed port, an old backup)' { @($mp2.Index['device:HERE'].Checks | Where-Object Id -eq 'DevicePort').Count -eq 1 -and @($mp2.Index['backup'].Checks | Where-Object Id -eq 'BackupOld').Count -eq 1 }
  ok 'a path that does not exist: 0 (and -1 when it does not answer in time, never a wait)' { [OtrHealthNet]::PathExists((Join-Path $tmp 'nothing-here'), 3000) -eq 0 }

  # ---- settings
  ok 'device lines: name address ports share MAC; a bad line refused' {
    $d = ConvertFrom-HealthDevice 'nas 192.0.2.9 445,5001 \\nas\backup 00:11:32:aa:bb:cc'
    $d.Name -eq 'nas' -and (@($d.Ports) -join ',') -eq '445,5001' -and $d.Share -eq '\\nas\backup' -and $d.Mac -eq '00-11-32-AA-BB-CC' -and -not $d.Bad -and
    (Test-HealthSettings ([pscustomobject]@{ Hosts = ''; DnsServers = ''; BrokerName = ''; SqlListener = ''; Devices = 'nas 192.0.2.9 what?'; BackupPath = ''; BackupHours = 26 })) }
  ok 'settings: saved and read back with the mode of an item; the Desktops settings kept' {
    Save-VdiSettings ([pscustomobject]@{ Enabled = $true; BrokerGroup = 'EXAMPLE\RDS-Brokers'; Brokers = ''; Hosts = '' })
    $s = Get-HealthSettings; $s.Hosts = 'hv1.example.com, hv2.example.com'; $s.Devices = "nas 192.0.2.9 445`r`nups 192.0.2.40 80"; $s.SqlListener = 'sqlha.example.com,1433'; $s.Mode = 'repair'
    Set-HealthItemMode $s 'host:HV1' 'diagnose'
    if (Test-HealthSettings $s) { return $false }
    Save-HealthSettings $s; $r = Get-HealthSettings
    $r.Hosts -eq 'hv1.example.com hv2.example.com' -and @(Get-HealthDevices $r).Count -eq 2 -and $r.Mode -eq 'repair' -and (Get-HealthItemMode $r 'host:HV1') -eq 'diagnose' -and (Get-VdiSettings).BrokerGroup -eq 'EXAMPLE\RDS-Brokers' }
  ok 'the shared broker name of the Health Center reaches the Desktops page' { $s = Get-HealthSettings; $s.BrokerName = 'rdbroker2.example.com'; Save-HealthSettings $s
    @((Get-VdiProbeConfig @() (Get-VdiSettings)).BrokerNames) -contains 'rdbroker2.example.com' }
  ok 'settings: a bad SQL listener, a bad backup path, bad hours refused' {
    $b = Get-HealthDefaults; $b.SqlListener = 'sql ha'; $c = Get-HealthDefaults; $c.BackupPath = 'logs'; $d = Get-HealthDefaults; $d.BackupHours = 'x'
    (Test-HealthSettings $b) -and (Test-HealthSettings $c) -and (Test-HealthSettings $d) }
  ok 'turned off: nothing read, said so' { $o = Get-HealthDefaults; $o.Enabled = $false; (ConvertTo-HealthModel $raw $null $now $o).Access -eq 'off' }

  # ---- Italian
  $script:Text = Read-LanguageTexts $script:LangDir 'it'
  $mi = ConvertTo-HealthModel (Copy-Raw) $null $now $set
  ok 'the model in Italian' { $mi.Headline -match '^Problemi: 2, avvisi: 10:' -and @($mi.Index['vm:VM-CAROL'].Checks)[0].Title -eq 'Salvata con vTPM' -and @($mi.Index['host:HV2'].Facts | Where-Object { $_.Label -eq 'Memoria' }).Count }
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item Env:\OTR_MANAGER_SETTINGS -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host "$($script:Passed) passed, $($script:Failed) failed"
exit $script:Failed
