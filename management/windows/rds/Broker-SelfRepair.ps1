<#
  OpenThinRDP - broker self-repair (Remote Desktop Connection Broker).
  Runs on a broker as SYSTEM, started by the scheduled task "OpenThinRDP - Broker self-repair"
  (Install-BrokerSelfRepair.ps1, or Desktops > Brokers and hosts in the manager) the moment the broker presents itself
  with the wrong identity.

  THE FAULT. At every request tssdis.exe (the broker service) calls the broker itself with the computer account.
  Healthy, it does so with Kerberos as NAME$; broken, it uses DOMAIN\NAME WITHOUT the $, falls back to NTLM and gets
  "unknown user" (event 4625, sub-status 0xC0000064). Every request through this broker then fails with event 804,
  HRESULT 0x80070005 (access denied), until the broker services start again. Most users get in at the second attempt,
  through another broker, so nobody reports it: the broker looks healthy and fails everything it receives. It was seen
  right after the broker left and joined the farm again (an address moved off its network adapter).
  The signal, event 4648 of tssdis.exe with the computer name without $, never appears on a healthy broker.

  WHAT IT DOES. Checks that the signal is really there, then restarts only the broker services (Tssdis, TScPubRPC,
  RDMS) with time limits, and empties the Kerberos tickets of NETWORK SERVICE, the account they run as. Open sessions
  are not touched (users are connected to their desktops, not to the broker); for about 30 seconds new requests are
  served by the other brokers. At most one restart every 15 minutes: when the fault comes straight back it is
  something else, and a person is needed.

  Log: C:\ProgramData\OpenThinRDP\broker-self-repair.log. Events in the Application log, source OpenThinRDP-Broker:
  1001 services restarted, 1002 not restarted (already restarted less than 15 minutes ago), 1003 a service did not start.
    -Test   restart even without the signal (to try the script by hand)
#>
param([switch]$Test)

$ErrorActionPreference = 'Continue'
$dir = Join-Path $env:ProgramData 'OpenThinRDP'
$log = Join-Path $dir 'broker-self-repair.log'
$stamp = Join-Path $dir 'broker-self-repair.last'
$source = 'OpenThinRDP-Broker'
$pauseMinutes = 15

function Write-Log([string]$m) { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $m) -Encoding ASCII }
function Write-Event([int]$id, [string]$type, [string]$m) {
  try { Write-EventLog -LogName Application -Source $source -EventId $id -EntryType $type -Message $m } catch { }
}
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
try { if (-not [Diagnostics.EventLog]::SourceExists($source)) { New-EventLog -LogName Application -Source $source } } catch { }

# The signal: tssdis.exe presenting itself with the computer name WITHOUT the $, in the last 5 minutes. The task
# triggers on any 4648 of NETWORK SERVICE with that target name; the process is checked here, because XPath compares
# the path case-sensitively and Windows does not always write it the same way.
$query = "<QueryList><Query Id='0' Path='Security'><Select Path='Security'>*[System[EventID=4648 and TimeCreated[timediff(@SystemTime) &lt;= 300000]]] and *[EventData[Data[@Name='SubjectUserSid']='S-1-5-20' and Data[@Name='TargetUserName']='$env:COMPUTERNAME']]</Select></Query></QueryList>"
$signals = @(Get-WinEvent -FilterXml $query -ErrorAction SilentlyContinue | Where-Object { $_.Properties.Count -gt 11 -and "$($_.Properties[11].Value)" -like '*\tssdis.exe' })
if (-not $Test -and $signals.Count -eq 0) { Write-Log 'started, but no signal in the last 5 minutes: nothing touched'; exit 0 }

if (Test-Path -LiteralPath $stamp) {
  $last = (Get-Item -LiteralPath $stamp).LastWriteTime
  if (((Get-Date) - $last).TotalMinutes -lt $pauseMinutes) {
    $m = "The broker presents itself with the wrong identity again, but its services were restarted at $($last.ToString('HH:mm:ss')): not again before $pauseMinutes minutes. If it goes on, a person is needed (manager: Desktops > Brokers and hosts)."
    Write-Log $m; Write-Event 1002 'Error' $m; exit 0
  }
}
Set-Content -Path $stamp -Value (Get-Date -Format s) -Encoding ASCII

$why = if ($Test) { 'test by hand (-Test)' } else { "tssdis presents itself as $env:USERDOMAIN\$env:COMPUTERNAME without the `$ ($($signals.Count) times in the last 5 minutes, first at $(($signals | Sort-Object TimeCreated | Select-Object -First 1).TimeCreated.ToString('HH:mm:ss')))" }
Write-Log "RESTART of the broker services: $why"

# NEVER Restart-Service or Stop-Service here: they wait with no limit, and a broker service that does not stop would
# hang this task forever. ServiceController.Stop() returns at once; WaitForStatus has a time limit; a service still
# hanging is ended by ending its process (the only way out of StopPending).
function Stop-Broker([string]$name, [int]$wait = 25) {
  $s = Get-Service -Name $name -ErrorAction SilentlyContinue
  if (-not $s) { return "$name missing" }
  $note = @("$name was $($s.Status)")
  if ($s.Status -eq 'Running') { try { $s.Stop() } catch { $note += "stop: $($_.Exception.Message)" } }
  if ("$($s.Status)" -notmatch 'Pending') { try { $s.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($wait)) } catch { $note += "not stopped in $wait s" } }
  $s.Refresh()
  if ($s.Status -ne 'Stopped') {
    $w = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
    # only a process of its own: ending a shared svchost would take other services down with no one to start them
    $together = if ($w -and $w.ProcessId -gt 0) { @(Get-CimInstance Win32_Service -Filter "ProcessId=$($w.ProcessId)") } else { @() }
    if ($together.Count -eq 1) { $note += "hanging: ending PID $($w.ProcessId)"; Stop-Process -Id $w.ProcessId -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 5 }
    else { $note += 'hanging in a shared process: not ended' }
  }
  $s.Refresh(); $note += "now $($s.Status)"
  $note -join ', '
}
function Start-Broker([string]$name) {
  $s = Get-Service -Name $name -ErrorAction SilentlyContinue
  if (-not $s) { return }
  for ($i = 0; $i -lt 6; $i++) {
    $s.Refresh(); if ($s.Status -eq 'Running') { break }
    if ($s.Status -eq 'Stopped') { try { $s.Start() } catch { } }
    try { $s.WaitForStatus('Running', [TimeSpan]::FromSeconds(10)) } catch { }
  }
}

# all three stopped, then started in the reverse order (Tssdis first): the order that worked by hand
$notes = foreach ($n in 'RDMS', 'TScPubRPC', 'Tssdis') { Stop-Broker $n }
foreach ($n in 'Tssdis', 'TScPubRPC', 'RDMS') { Start-Broker $n }
# the services run as NETWORK SERVICE (logon session 0x3e4): its tickets, not those of SYSTEM (0x3e7)
& klist.exe -li 0x3e4 purge | Out-Null
$state = (Get-Service Tssdis, TScPubRPC, RDMS -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ' '
foreach ($x in $notes) { Write-Log "  $x" }
Write-Log "  after: $state"

$ok = $state -notmatch '=(Stopped|StartPending|StopPending)'
$m = "Broker self-repair on ${env:COMPUTERNAME}: $why. Services restarted: $state. " +
  $(if ($ok) { 'The real test is the next sign-in through this broker (event 801 in the SessionBroker Operational log).' } else { 'A service did not start: a person is needed (manager: Desktops > Brokers and hosts).' })
Write-Event $(if ($ok) { 1001 } else { 1003 }) $(if ($ok) { 'Warning' } else { 'Error' }) $m
