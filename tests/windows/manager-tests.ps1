<#
  Tests of the Windows manager, in Windows PowerShell 5.1 as administrators run it (CI: windows-latest):
    - every script of management\windows parses, and the texts of every language have the same keys and placeholders
    - the Desktops page (OtrVdi.ps1): the model and the action plans from recorded data (fixtures\vdi: the answer of a
      probe of two brokers and two Hyper-V hosts, and the folder of ten devices). No server, no network, nothing changed:
      the actions run only in their dry-run mode.
  Start:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows\manager-tests.ps1
  Exit code = the number of failed tests.
#>
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$mw = Join-Path $root 'management\windows'
$fx = Join-Path $PSScriptRoot 'fixtures\vdi'
$script:Passed = 0; $script:Failed = 0
function ok([string]$name, [scriptblock]$test) {
  $why = ''
  try { $r = & $test } catch { $r = $false; $why = " ($($_.Exception.Message) line $($_.InvocationInfo.ScriptLineNumber))" }
  if ($r) { $script:Passed++; Write-Host "ok   $name" } else { $script:Failed++; Write-Host "FAIL $name$why" -ForegroundColor Red }
}
function Get-ParseErrors([string]$file) { $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$e); @($e) }
# the commands a script calls (not its comments)
function Get-Commands($ast) { @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ }) }

# ---- the scripts and the texts
foreach ($f in @(Get-ChildItem -LiteralPath $mw -Recurse -Filter '*.ps1') + @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1')) {
  ok "parses: $($f.FullName.Substring($root.Length + 1))" { (Get-ParseErrors $f.FullName).Count -eq 0 }
}
function Read-Texts([string]$file) {
  $e = $null; $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$e)
  $h = $ast.Find({ param($a) $a -is [System.Management.Automation.Language.HashtableAst] }, $false); $t = @{}
  foreach ($kv in $h.KeyValuePairs) { $t[[string]$kv.Item1.SafeGetValue()] = [string]$kv.Item2.SafeGetValue() }
  $t
}
$en = Read-Texts (Join-Path $mw 'lang\en.psd1')
foreach ($lf in @(Get-ChildItem -LiteralPath (Join-Path $mw 'lang') -Filter '*.psd1' | Where-Object Name -ne 'en.psd1')) {
  $tr = Read-Texts $lf.FullName
  ok "$($lf.Name): every key of en.psd1, no other" { -not @($en.Keys | Where-Object { -not $tr.ContainsKey($_) }).Count -and -not @($tr.Keys | Where-Object { -not $en.ContainsKey($_) }).Count }
  $bad = @($en.Keys | Where-Object { $tr.ContainsKey($_) } | Where-Object {
    (@([regex]::Matches($en[$_], '\{\d+\}') | ForEach-Object Value | Sort-Object -Unique) -join ',') -ne (@([regex]::Matches($tr[$_], '\{\d+\}') | ForEach-Object Value | Sort-Object -Unique) -join ',') })
  ok "$($lf.Name): the same placeholders as en.psd1 $(if ($bad.Count) { "(differ: $($bad -join ', '))" })" { -not $bad.Count }
  $b = [IO.File]::ReadAllBytes($lf.FullName)
  ok "$($lf.Name): UTF-8 with BOM (Windows PowerShell 5.1 reads a file without it as ANSI)" { $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF }
}
ok 'en.psd1: ASCII only' { -not @([IO.File]::ReadAllBytes((Join-Path $mw 'lang\en.psd1')) | Where-Object { $_ -gt 127 }).Count }

# ---- the broker self-repair and the remote scripts: never Restart-Service / Stop-Service (they wait with no limit)
$rep = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $mw 'rds\Broker-SelfRepair.ps1'), [ref]$null, [ref]$null)
ok 'Broker-SelfRepair.ps1: no Restart-Service/Stop-Service/Start-Service' { -not @(Get-Commands $rep | Where-Object { $_ -in 'Restart-Service', 'Stop-Service', 'Start-Service' }).Count }
ok 'Broker-SelfRepair.ps1: checks tssdis.exe and purges the tickets of NETWORK SERVICE (0x3e4)' { $t = [IO.File]::ReadAllText((Join-Path $mw 'rds\Broker-SelfRepair.ps1')); $t -match 'tssdis\.exe' -and $t -match 'klist\.exe -li 0x3e4 purge' -and $t -notmatch '0x3e7 purge' }
ok 'Install-BrokerSelfRepair.ps1: the trigger is 4648 of NETWORK SERVICE with the computer name' { $t = [IO.File]::ReadAllText((Join-Path $mw 'rds\Install-BrokerSelfRepair.ps1')); $t -match "EventID=4648" -and $t -match "S-1-5-20" -and $t -match 'TargetUserName' }

# ---- the manager, functions only, on a copy of the fixture folder (the dry runs write config\changes.log there)
$tmp = Join-Path ([IO.Path]::GetTempPath()) "otr-tests-$(Get-Random)"
Copy-Item -LiteralPath (Join-Path $fx 'folder') -Destination $tmp -Recurse
try {
  . (Join-Path $mw 'OpenThinRDP-Manager.ps1') -Folder $tmp -FunctionsOnly -Language en
  $script:SettingsFile = Join-Path $tmp 'manager.json'
  ok 'OtrVdi.ps1 loads with the manager' { $script:VdiLoaded }
  ok 'remote Restart script: no Restart-Service/Stop-Service, time limits, ends a hanging process' {
    $a = [System.Management.Automation.Language.Parser]::ParseInput($script:VdiRemote.Restart.ToString(), [ref]$null, [ref]$null)
    -not @(Get-Commands $a | Where-Object { $_ -in 'Restart-Service', 'Stop-Service', 'Start-Service' }).Count -and $script:VdiRemote.Restart.ToString() -match 'WaitForStatus' -and $script:VdiRemote.Restart.ToString() -match 'Stop-Process' }
  ok 'remote VmPower script: never saves, never switches off, never takes the whole cluster group offline' {
    $s = $script:VdiRemote.VmPower.ToString(); $a = [System.Management.Automation.Language.Parser]::ParseInput($s, [ref]$null, [ref]$null)
    -not @(Get-Commands $a | Where-Object { $_ -in 'Save-VM', 'Suspend-VM', 'Stop-ClusterGroup' }).Count -and $s -notmatch '-Save\b' -and $s -notmatch '-TurnOff' -and @(Get-Commands $a) -contains 'Stop-ClusterResource' -and $s -match 'OfflineAction' }

  # the time of the recorded data; the devices as old as they were then
  $now = [datetime]'2026-10-19T09:30:00'
  $devs = @(Get-Devices)
  foreach ($d in $devs) { $d.Minutes = [int]($now - $d.When).TotalMinutes }
  $raw = Get-Content -LiteralPath (Join-Path $fx 'raw.json') -Raw | ConvertFrom-Json
  ($raw.Brokers | Where-Object Name -eq 'RDCB1').Task.Hash = Get-VdiRepairHash
  $m = ConvertTo-VdiModel $raw $devs $now
  $row = { param($u) @($m.Rows | Where-Object { $_.UserKey -eq $u }) | Select-Object -First 1 }
  $dev = { param($n) @($m.Rows | Where-Object { $_.Device -and $_.Device.Name -eq $n }) | Select-Object -First 1 }

  # ---- small parts
  ok 'user names: DOMAIN\user, user@domain and User are one' { (Get-VdiUserKey 'EXAMPLE\alice') -eq 'ALICE' -and (Get-VdiUserKey 'alice@example.com') -eq 'ALICE' -and (Get-VdiUserKey ' Alice ') -eq 'ALICE' }
  $si = @(Get-VdiDeviceSignIns @('2026-10-19 08:40:00 broker rdbroker.example.com: connecting to rdcb2.example.com (Kerberos)',
    '2026-10-19 08:40:03 attempt 1 for frank on rdbroker.example.com failed after 2s (code 131, broker): x',
    '2026-10-19 08:40:09 broker 192.0.2.11: connecting to rdcb1.example.com (Kerberos)', '2026-10-19 08:40:18 session of frank opened (broker 192.0.2.11)', 'garbage'))
  ok 'device sign-ins: the broker really reached, the attempt, the reason' { $si.Count -eq 2 -and -not $si[0].Ok -and $si[0].Broker -eq 'RDCB2' -and $si[0].Why -eq (Get-WhereLabel 'broker') -and $si[1].Ok -and $si[1].Broker -eq 'RDCB1' -and $si[1].User -eq 'FRANK' }
  $s2 = Get-VdiSignIn $si
  ok 'a success right after a failure is a second try, naming the broker that failed' { $s2.Last.Ok -and $s2.SecondTry -and $s2.FailedOn -eq 'RDCB2' }
  $b = { param($rcv, $fail, $req) [pscustomobject]@{ Reachable = $true; Received = $rcv; Failed = $fail; Requests = @($req) } }
  $q = { param($t, $ok) [pscustomobject]@{ Time = "2026-10-19T$t"; Ok = $ok } }
  ok 'fails everything: 2 failed of 2 received' { Test-VdiFailsAll (& $b 2 2 @()) $now.Date }
  ok 'fails everything: not 1 failed of 10' { -not (Test-VdiFailsAll (& $b 10 1 @((& $q '08:00:00' $true))) $now.Date) }
  ok 'fails everything: not a single failure' { -not (Test-VdiFailsAll (& $b 1 1 @((& $q '08:00:00' $false))) $now.Date) }
  ok 'fails everything: the last requests all failed after a good morning' { Test-VdiFailsAll (& $b 20 3 @((& $q '08:00:00' $true), (& $q '13:00:00' $false), (& $q '13:02:00' $false), (& $q '13:05:00' $false))) $now.Date }

  # ---- the model of the recorded data
  ok 'access ok, two brokers, two hosts, ten devices and a user without a device' { $m.Access -eq 'ok' -and $m.Brokers.Count -eq 2 -and $m.Hosts.Count -eq 2 -and @($m.Rows | Where-Object Device).Count -eq 9 -and (& $row 'GRACE') -and -not (& $row 'GRACE').Device }
  ok 'who cannot sign in now: bob and carol, on top' { $m.CannotSignIn -eq 2 -and $m.Headline -match 'bob' -and $m.Headline -match 'carol' -and $m.Rows[0].Kind -eq 'error' -and $m.Rows[1].Kind -eq 'error' }
  $r = & $row 'BOB'
  ok 'bob: cannot sign in, failed on RDCB2 (the broker behind the shared name)' { $r.Kind -eq 'error' -and $r.State -eq (Get-Text 'VdiStCannot') -and $r.SignIn.Last.Broker -eq 'RDCB2' -and $r.SignInText -match 'FAILED' -and $r.Device.Name -eq 'thinclient2' }
  $r = & $row 'CAROL'
  ok 'carol: VM saved with a vTPM comes before the failed sign-in' { $r.Kind -eq 'error' -and $r.State -eq (Get-Text 'VdiStSavedTpm') -and $r.VmText -eq (Get-Text 'VdiVmSaved') -and $r.Host -eq 'HV2' }
  $r = & $row 'FRANK'
  ok 'frank: signed in at the second try, RDCB2 failed first' { $r.Kind -eq 'warn' -and $r.State -eq (Get-Text 'VdiStSecond') -and $r.SignIn.FailedOn -eq 'RDCB2' -and $r.SignIn.Last.Broker -eq 'RDCB1' }
  $r = & $row 'DAVE'
  ok 'dave: disconnected at 08:51, from the desktop itself' { $r.Kind -eq 'info' -and $r.Session.State -eq 'disconnected' -and $r.Session.Source -eq 'desktop' -and $r.SessionText -match '08:51' }
  $r = & $row 'ERIN'
  ok 'erin: VM off, device off' { $r.State -eq (Get-Text 'VdiStVmOff') -and $r.DeviceText -match '\(off\)' }
  $r = & $row 'ALICE'
  ok 'alice: signed in, idle 1 minute = active' { $r.Kind -eq 'ok' -and $r.SessionText -eq (Get-Text 'VdiSessActive') -and $r.Host -eq 'HV1' -and $r.SignInText -match 'RDCB1' }
  $r = & $row 'GRACE'
  ok 'grace: no device, idle 21 min' { $r.Kind -eq 'ok' -and $r.SessionText -eq (Get-Text 'VdiSessIdle' (Format-Minutes 21)) }
  $r = & $row 'JUDY'
  ok 'judy: a failure 40 minutes before the success is not a second try' { $r.Kind -eq 'ok' -and -not $r.SignIn.SecondTry }
  $r = & $dev 'reception1'
  ok 'a kiosk without a user: no user' { $r.State -eq (Get-Text 'VdiStNoUser') -and -not $r.UserKey }
  ok 'the same sign-in from the device and the broker shows once' { @((& $row 'ALICE').SignIn.Recent).Count -eq 1 }
  $f = { param($where, $fix) @($m.Findings | Where-Object { $_.Where -eq $where -and (-not $fix -or $_.Fix -eq $fix) }) }
  ok 'RDCB2 fails every sign-in, with the 4648 signature, fix = restart' { $x = @(& $f 'RDCB2' 'BrokerRestart'); $x.Count -eq 1 -and $x[0].Kind -eq 'error' -and $x[0].Text -match '5 failed, 5 received' -and $x[0].Text -match '\$' }
  ok 'RDCB2 has no self-repair, fix = install' { @(& $f 'RDCB2' 'BrokerSelfRepair').Count -eq 1 }
  ok 'RDCB1 healthy: one ok line, self-repair, management server' { $x = @(& $f 'RDCB1' $null); $x.Count -eq 1 -and $x[0].Kind -eq 'ok' -and $x[0].Text -match (Get-Text 'VdiFRepairOn') -and $x[0].Text -match (Get-Text 'VdiFActive') }
  ok 'RDCB1 with an old self-repair: a note to update it' { ($raw.Brokers | Where-Object Name -eq 'RDCB1').Task.Hash = 'OLD'; $m2 = ConvertTo-VdiModel $raw $devs $now; ($raw.Brokers | Where-Object Name -eq 'RDCB1').Task.Hash = Get-VdiRepairHash
    @($m2.Findings | Where-Object { $_.Where -eq 'RDCB1' -and $_.Fix -eq 'BrokerSelfRepair' -and $_.Text -eq (Get-Text 'VdiFRepairOld') }).Count -eq 1 }
  ok 'HV2: RDCB2 missing in RDS Endpoint Servers only, fix = repair' { $x = @(& $f 'HV2' 'HostPermissions'); $x.Count -eq 1 -and $x[0].Text -match 'RDCB2' -and $x[0].Text -match (Get-Text 'VdiGroup576') -and $x[0].Text -notmatch (Get-Text 'VdiGroup577') }
  ok 'HV1: the brokers allowed through a domain group (nested), attached to RDCB1' { $x = @(& $f 'HV1' $null); $x.Count -eq 1 -and $x[0].Kind -eq 'ok' -and $x[0].Text -match 'RDCB1' -and $x[0].Text -match 'through RDS-Brokers\)' }
  ok 'HV2: a VM with a vTPM that the cluster would save, fix = shut down instead' { $x = @(& $f 'HV2' 'HostOfflineAction'); $x.Count -eq 1 -and $x[0].Text -match 'VM-CAROL' }
  ok 'rdbroker.example.com: both brokers, both answer' { $x = @(& $f 'rdbroker.example.com' $null); $x.Count -eq 1 -and $x[0].Kind -eq 'ok' }
  ok 'errors first in the findings' { $m.Findings[0].Kind -eq 'error' }
  ok 'healthy brokers: RDCB1 yes, RDCB2 no' { ($m.Brokers | Where-Object Name -eq 'RDCB1').Healthy -and -not ($m.Brokers | Where-Object Name -eq 'RDCB2').Healthy }

  # ---- what the page says without the servers
  $m0 = ConvertTo-VdiModel $null $devs $now
  ok 'no broker known: the rows of the devices, their sign-ins from their own logs' { $m0.Access -eq 'nobroker' -and @($m0.Rows).Count -eq 9 -and -not @($m0.Findings).Count -and (@($m0.Rows | Where-Object { $_.UserKey -eq 'BOB' }) | Select-Object -First 1).Kind -eq 'error' }
  $rawD = [pscustomobject]@{ Taken = $raw.Taken; Names = @(); Brokers = @([pscustomobject]@{ Name = 'RDCB1'; Fqdn = 'rdcb1.example.com'; Reachable = $false; Error = 'denied' }); Hosts = @(); BrokerSids = @(); Group = $null; Wts = @(); Events = @(); Notes = @() }
  $mD = ConvertTo-VdiModel $rawD $devs $now
  ok 'access denied on every broker: said in one sentence' { $mD.Access -eq 'denied' -and $mD.AccessText -eq 'RDCB1' -and (Get-Text "VdiAccess_$($mD.Access)" $mD.AccessText) -match 'RDCB1' }
  ok 'turned off in the settings' { (ConvertTo-VdiModel $raw $devs $now ([pscustomobject]@{ Enabled = $false; BrokerGroup = ''; Brokers = ''; Hosts = '' })).Access -eq 'off' }

  # ---- the action plans
  $st = @{ Model = $m; Received = $now; Running = $null }
  $p = Get-VdiActionPlan 'BrokerRestart' 'RDCB2' $st $now
  ok 'restart RDCB2 while RDCB1 is healthy: allowed, all three services, Tssdis started first, tickets of 0x3e4' {
    -not $p.Blocked -and $p.Destructive -and $p.DefaultNo -and $p.Steps[0].Computer -eq 'rdcb2.example.com' -and $p.Steps[0].Args[0] -eq 'RDMS,TScPubRPC,Tssdis' -and $p.Steps[0].Args[1] -eq 'Tssdis,TScPubRPC,RDMS' -and $p.Steps[0].Args[3] -eq '0x3e4' -and $p.Text -match 'RDCB1' }
  ok 'restart RDCB1 while RDCB2 fails everything: refused (nobody would be left)' { (Get-VdiActionPlan 'BrokerRestart' 'RDCB1' $st $now).Blocked -match 'RDCB2' }
  $s1 = @(($m.Brokers | Where-Object Name -eq 'RDCB1').Services | Where-Object Name -eq 'Tssdis')[0]; $keep = $s1.Since; $s1.Since = $now.AddMinutes(-2).ToString('yyyy-MM-ddTHH:mm:ss')
  ok 'never two brokers at once: refused while the other restarted 2 minutes ago' { (Get-VdiActionPlan 'BrokerRestart' 'RDCB2' $st $now).Blocked -eq (Get-Text 'VdiBlkOtherFresh' 'RDCB1') }
  $s1.Since = $keep
  ok 'stale data: what stops something is refused, starting a VM is not' { $old = @{ Model = $m; Received = $now.AddMinutes(-10); Running = $null }
    (Get-VdiActionPlan 'BrokerRestart' 'RDCB2' $old $now).Blocked -match '09:20' -and -not (Get-VdiActionPlan 'VmStart' (& $row 'CAROL') $old $now).Blocked }
  ok 'another action running: everything waits' { (Get-VdiActionPlan 'VmStart' (& $row 'CAROL') @{ Model = $m; Received = $now; Running = 'x' } $now).Blocked -match 'x' }
  $p = Get-VdiActionPlan 'HostPermissions' 'HV2' $st $now
  ok 'repair HV2 without a group: the computer of RDCB2 into RDS Endpoint Servers, then the tickets of both brokers' {
    -not $p.Blocked -and $p.Steps[0].Computer -eq 'hv2.example.com' -and $p.Steps[0].Args[0] -eq 'S-1-5-32-576' -and $p.Steps[0].Args[1] -eq 'S-1-5-21-1000-2000-3000-1102' -and @($p.Steps | Where-Object { $_.Name -eq 'purge tickets' }).Count -eq 2 }
  $rawG = Get-Content -LiteralPath (Join-Path $fx 'raw.json') -Raw | ConvertFrom-Json
  $rawG.Group = [pscustomobject]@{ Name = 'EXAMPLE\RDS-Brokers'; Sid = 'S-1-5-21-1000-2000-3000-3001' }
  $mG = ConvertTo-VdiModel $rawG $devs $now
  ok 'repair HV2 with the group of the settings: the group, never the computer' { $x = Get-VdiActionPlan 'HostPermissions' 'HV2' @{ Model = $mG; Received = $now; Running = $null } $now; -not $x.Blocked -and $x.Steps[0].Args[1] -eq 'S-1-5-21-1000-2000-3000-3001' }
  ok 'the log of a repair names the groups in English, whatever the language of the window' { (Get-VdiActionPlan 'HostPermissions' 'HV2' $st $now).Log -match 'RDS Endpoint Servers' }
  ok 'repair HV1: nothing to do' { (Get-VdiActionPlan 'HostPermissions' 'HV1' $st $now).Blocked -eq (Get-Text 'VdiBlkNothing') }
  $p = Get-VdiActionPlan 'VmShutdown' (& $row 'ALICE') $st $now
  ok 'shut down VM-ALICE: names alice, No by default, a shutdown on its host' { -not $p.Blocked -and $p.DefaultNo -and $p.Text -match 'ALICE' -and $p.Steps[0].Computer -eq 'hv1.example.com' -and $p.Steps[0].Args[1] -eq 'shutdown' }
  ok 'start a running VM: refused' { (Get-VdiActionPlan 'VmStart' (& $row 'ALICE') $st $now).Blocked }
  ok 'start the saved VM of carol: allowed, with the vTPM note' { $x = Get-VdiActionPlan 'VmStart' (& $row 'CAROL') $st $now; -not $x.Blocked -and $x.Text -match 'vTPM' }
  ok 'restart a VM that is off: refused' { (Get-VdiActionPlan 'VmRestart' (& $row 'ERIN') $st $now).Blocked }
  ok 'log off alice: No by default; disconnect dave (already disconnected): refused' { $x = Get-VdiActionPlan 'SessionLogoff' (& $row 'ALICE') $st $now; -not $x.Blocked -and $x.DefaultNo -and (Get-VdiActionPlan 'SessionDisconnect' (& $row 'DAVE') $st $now).Blocked }
  ok 'shadow grace: reads the policy of VM-GRACE first' { $x = Get-VdiActionPlan 'SessionShadow' (& $row 'GRACE') $st $now; -not $x.Blocked -and $x.Steps[0].Computer -eq 'VM-GRACE' }
  ok 'message: refused when empty, allowed with a text' { (Get-VdiActionPlan 'SessionMessage' (& $row 'GRACE') $st $now '').Blocked -and -not (Get-VdiActionPlan 'SessionMessage' (& $row 'GRACE') $st $now 'Restart at 12:00').Blocked }
  $p = Get-VdiActionPlan 'AssignDesktop' (& $row 'GRACE') $st $now 'VM-SPARE'
  ok 'grace to VM-SPARE: on the management server, old desktop removed first' { -not $p.Blocked -and $p.Steps[0].Computer -eq 'rdcb1.example.com' -and $p.Steps[0].Args[0] -eq 'Personal desktops' -and $p.Steps[0].Args[1] -eq 'EXAMPLE\GRACE' -and $p.Steps[0].Args[3] -eq 'VM-GRACE' }
  ok 'grace to VM-ALICE: refused, it is the desktop of alice' { (Get-VdiActionPlan 'AssignDesktop' (& $row 'GRACE') $st $now 'VM-ALICE').Blocked -match 'ALICE' }
  ok 'self-repair on RDCB2: the install script of the manager' { $x = Get-VdiActionPlan 'BrokerSelfRepair' 'RDCB2' $st $now; -not $x.Blocked -and $x.Steps[0].Local -and (Test-Path -LiteralPath $x.Steps[0].Args[0]) }
  ok 'unblock the agent of HV1 and the vTPM VMs of HV2: allowed' { -not (Get-VdiActionPlan 'HostUnblock' 'HV1' $st $now 'VmHostAgent').Blocked -and (Get-VdiActionPlan 'HostOfflineAction' 'HV2' $st $now).Steps[0].Args[0] -eq 'VM-CAROL' }
  ok 'add RDCB2 to the AD group: only with a group in the settings' { (Get-VdiActionPlan 'BrokerAddToGroup' 'RDCB2' $st $now).Blocked -and -not (Get-VdiActionPlan 'BrokerAddToGroup' 'RDCB2' @{ Model = $mG; Received = $now; Running = $null } $now).Blocked }
  # the runner in dry-run mode: says what it would run, runs nothing
  $res = @(& $script:VdiJobRunner (Get-VdiActionPlan 'HostPermissions' 'HV2' $st $now).Steps $true 1000 1000)
  ok 'dry run: every step said, none run' { $res.Count -eq 3 -and -not @($res | Where-Object { -not $_.DryRun -or -not $_.Ok }).Count }

  # ---- a role of the cluster taken offline whole: Hyper-V forgets the VM, the probe lists it from the cluster
  $rawO = Get-Content -LiteralPath (Join-Path $fx 'raw.json') -Raw | ConvertFrom-Json
  $erin = @(($rawO.Hosts | Where-Object Name -eq 'HV2').Vms | Where-Object Name -eq 'VM-ERIN')[0]
  $erin | Add-Member -NotePropertyName Registered -NotePropertyValue $false -Force; $erin | Add-Member -NotePropertyName ClusterState -NotePropertyValue 'Offline' -Force
  $mO = ConvertTo-VdiModel $rawO $devs $now
  $rO = @($mO.Rows | Where-Object UserKey -eq 'ERIN')[0]
  ok 'a VM whose cluster role is offline: known, "off (cluster role offline)", it can be started' {
    $rO.VmInfo -and $rO.VmText -eq (Get-Text 'VdiVmOffRole') -and -not (Get-VdiActionPlan 'VmStart' $rO @{ Model = $mO; Received = $now; Running = $null } $now).Blocked }

  # ---- VmPower against a pretend cluster: the cmdlets of Hyper-V and of the cluster replaced by functions that keep
  # the state of one VM role (its VM resource and its configuration resource), as the real ones behave
  function New-Fake([string]$group = 'Online', [string]$vmRes = 'Online', [string]$cfg = 'Online', [string]$vm = 'Running', [int]$oa = 2) {
    $script:Fake = @{ Group = $group; VmRes = $vmRes; Cfg = $cfg; Vm = $vm; Oa = $oa; Calls = New-Object Collections.ArrayList } }
  function Get-VM { [CmdletBinding()] param([string]$Name)
    # the configuration resource offline = the VM is not registered in Hyper-V
    if ($script:Fake.Cfg -ne 'Online') { throw "Hyper-V cannot find a virtual machine named $Name" }
    [pscustomobject]@{ Name = 'VM-T'; State = $script:Fake.Vm; Heartbeat = $(if ($script:Fake.Vm -eq 'Running') { 'OkApplicationsHealthy' } else { 'Disabled' }); Id = 'id-1' } }
  function Get-ClusterResource { [CmdletBinding()] param([string]$Name)
    $r = @([pscustomobject]@{ Name = 'Virtual Machine VM-T'; ResourceType = 'Virtual Machine'; OwnerGroup = 'VM-T'; State = $script:Fake.VmRes },
      [pscustomobject]@{ Name = 'Virtual Machine Configuration VM-T'; ResourceType = 'Virtual Machine Configuration'; OwnerGroup = 'VM-T'; State = $script:Fake.Cfg })
    if ($Name) { $r | Where-Object Name -eq $Name } else { $r } }
  function Get-ClusterParameter { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$InputObject, [string]$Name)
    process { [pscustomobject]@{ Value = $(if ($Name -eq 'VmID') { 'id-1' } else { $script:Fake.Oa }) } } }
  function Get-ClusterGroup { [CmdletBinding()] param([string]$Name) [pscustomobject]@{ State = $script:Fake.Group } }
  function Stop-ClusterResource { [CmdletBinding()] param([string]$Name, [int]$Wait) [void]$script:Fake.Calls.Add('Stop-ClusterResource')
    $script:Fake.Vm = $(if ($script:Fake.Oa -eq 1) { 'Saved' } else { 'Off' }); $script:Fake.VmRes = 'Offline'; $script:Fake.Group = 'PartialOnline' }
  function Stop-ClusterGroup { [CmdletBinding()] param([string]$Name, [int]$Wait) [void]$script:Fake.Calls.Add('Stop-ClusterGroup')
    $script:Fake.Vm = 'Off'; $script:Fake.VmRes = 'Offline'; $script:Fake.Cfg = 'Offline'; $script:Fake.Group = 'Offline' }
  function Start-ClusterGroup { [CmdletBinding()] param([string]$Name, [int]$Wait) [void]$script:Fake.Calls.Add('Start-ClusterGroup')
    $script:Fake.Vm = 'Running'; $script:Fake.VmRes = 'Online'; $script:Fake.Cfg = 'Online'; $script:Fake.Group = 'Online' }
  function Start-ClusterResource { [CmdletBinding()] param([string]$Name, [int]$Wait) [void]$script:Fake.Calls.Add('Start-ClusterResource')
    if ($script:Fake.Cfg -ne 'Online') { throw 'the configuration is offline' }; $script:Fake.Vm = 'Running'; $script:Fake.VmRes = 'Online'; $script:Fake.Group = 'Online' }
  function Stop-VM { [CmdletBinding()] param($VM, [switch]$Force, [switch]$AsJob) [void]$script:Fake.Calls.Add('Stop-VM'); $script:Fake.Vm = 'Off'; $script:Fake.VmRes = 'Offline'; 'job' }
  function Start-VM { [CmdletBinding()] param($VM) [void]$script:Fake.Calls.Add('Start-VM'); $script:Fake.Vm = 'Running' }
  function Wait-Job { param($Job, $Timeout) $Job }
  function Remove-Job { param($Job, [switch]$Force) }
  function Stop-Job { param($Job) }
  $power = { param($a) & $script:VdiRemote.VmPower 'VM-T' $a 60 }
  New-Fake; $x = & $power 'shutdown'
  ok 'shut down a cluster VM: only its VM resource (OfflineAction 2), the configuration stays online, Get-VM says Off' {
    $x.Ok -and $x.After -eq 'Off' -and $x.ResourceState -eq 'Offline' -and $script:Fake.Cfg -eq 'Online' -and @($script:Fake.Calls) -contains 'Stop-ClusterResource' -and @($script:Fake.Calls) -notcontains 'Stop-ClusterGroup' }
  $x = & $power 'start'
  ok 'start it again: its VM resource, running with a heartbeat' { $x.Ok -and $x.After -eq 'Running' -and $x.Heartbeat -like 'Ok*' -and @($script:Fake.Calls)[-1] -eq 'Start-ClusterResource' }
  New-Fake 'Offline' 'Offline' 'Offline' 'Off'; $x = & $power 'start'
  ok 'start a VM whose whole role is offline (not registered in Hyper-V): the group' { $x.Ok -and $x.Before -eq 'Off' -and @($script:Fake.Calls) -contains 'Start-ClusterGroup' -and $x.After -eq 'Running' }
  New-Fake; $x = & $power 'restart'
  ok 'restart a cluster VM: VM resource off, then on, configuration always online' { $x.Ok -and (@($script:Fake.Calls) -join ',') -eq 'Stop-ClusterResource,Start-ClusterResource' -and $script:Fake.Cfg -eq 'Online' }
  New-Fake -oa 1; $x = & $power 'shutdown'
  ok 'OfflineAction 1 (save): never through the cluster, a shutdown of Windows (Stop-VM)' { $x.Ok -and @($script:Fake.Calls) -contains 'Stop-VM' -and @($script:Fake.Calls) -notcontains 'Stop-ClusterResource' -and $script:Fake.Vm -eq 'Off' }
  New-Fake 'Offline' 'Offline' 'Offline' 'Off'; $x = & $power 'shutdown'
  ok 'a shutdown that leaves the VM unknown to Hyper-V is a failure, said so' { -not $x.Ok -and $x.Error }
  foreach ($n in 'Get-VM', 'Get-ClusterResource', 'Get-ClusterParameter', 'Get-ClusterGroup', 'Stop-ClusterResource', 'Stop-ClusterGroup', 'Start-ClusterGroup', 'Start-ClusterResource', 'Stop-VM', 'Start-VM', 'Wait-Job', 'Remove-Job', 'Stop-Job') { Remove-Item "function:$n" }

  # ---- the probe without servers (no broker named): only the event logs of the devices
  $cfg = Get-VdiProbeConfig $devs ([pscustomobject]@{ Enabled = $true; BrokerGroup = ''; Brokers = ''; Hosts = '' })
  ok 'probe input: the brokers the devices name (shared name and fallbacks)' { (@($cfg.BrokerNames) -join ' ') -eq '192.0.2.11 192.0.2.12 rdbroker.example.com' }
  $cfg.BrokerNames = @()
  $p0 = & $script:VdiProbe $cfg
  ok 'probe with no broker: the events of every device, nothing else' { @($p0.Events).Count -eq 9 -and -not @($p0.Brokers).Count -and @(($p0.Events | Where-Object Device -eq 'thinclient6').Lines).Count -eq 5 }

  # ---- settings
  ok 'settings: saved and read back, the last folder kept' { Save-LastFolder 'C:\x'; Save-VdiSettings ([pscustomobject]@{ Enabled = $false; BrokerGroup = 'EXAMPLE\RDS-Brokers'; Brokers = 'rdcb3.example.com, rdcb4'; Hosts = '' })
    $s = Get-VdiSettings; Save-LastFolder 'C:\y'; $s2 = Get-VdiSettings
    -not $s.Enabled -and $s.Brokers -eq 'rdcb3.example.com rdcb4' -and $s2.BrokerGroup -eq 'EXAMPLE\RDS-Brokers' -and (Get-LastFolder) -eq 'C:\y' }
  ok 'settings: a bad name refused' { (Test-VdiSettings ([pscustomobject]@{ Enabled = $true; BrokerGroup = ''; Brokers = 'bad_name!'; Hosts = '' })) -and -not (Test-VdiSettings ([pscustomobject]@{ Enabled = $true; BrokerGroup = 'EXAMPLE\RDS-Brokers'; Brokers = 'rdcb1.example.com'; Hosts = 'hv1' })) }

  # ---- Italian
  $script:Text = Read-LanguageTexts $script:LangDir 'it'
  $mi = ConvertTo-VdiModel $raw $devs $now
  ok 'the model in Italian' { $mi.Headline -match '^Non riescono' -and (@($mi.Rows | Where-Object { $_.UserKey -eq 'FRANK' }))[0].State -eq 'Secondo tentativo' }
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host "$($script:Passed) passed, $($script:Failed) failed"
exit $script:Failed
