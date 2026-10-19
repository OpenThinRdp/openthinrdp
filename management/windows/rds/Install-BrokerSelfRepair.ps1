<#
  Installs (or updates, or removes) the broker self-repair on Remote Desktop Connection Brokers, over WinRM.
  Copies Broker-SelfRepair.ps1 (next to this file) to C:\ProgramData\OpenThinRDP on each broker, byte for byte (the
  manager compares its hash to tell an old copy), and registers the task "OpenThinRDP - Broker self-repair" (SYSTEM),
  which starts on event 4648 of NETWORK SERVICE with the computer name without the $ (Broker-SelfRepair.ps1 explains
  the fault). It can be run again at any time.
    Install-BrokerSelfRepair.ps1 -Broker rdcb1.example.com, rdcb2.example.com
    Install-BrokerSelfRepair.ps1 -Broker rdcb1.example.com -Remove
  A broker that already has a self-repair task of its own (a task started by event 4648 of tssdis.exe) is left as it
  is: two repairs would restart the services twice. -Replace disables that task and installs this one.
  One line per broker: Broker, Result (installed, updated, unchanged, removed, other), Other (the task found), State.
#>
param(
  [Parameter(Mandatory = $true)][string[]]$Broker,
  [switch]$Remove,
  [switch]$Replace
)
$ErrorActionPreference = 'Stop'
$file = Join-Path $PSScriptRoot 'Broker-SelfRepair.ps1'
$b64 = if ($Remove) { '' } else { [Convert]::ToBase64String([IO.File]::ReadAllBytes($file)) }
foreach ($b in $Broker) {
  Invoke-Command -ComputerName $b -ArgumentList @($b64, [bool]$Remove, [bool]$Replace) -ScriptBlock {
    param($b64, $remove, $replace)
    $ErrorActionPreference = 'Stop'
    $name = 'OpenThinRDP - Broker self-repair'
    $dir = Join-Path $env:ProgramData 'OpenThinRDP'
    $dest = Join-Path $dir 'Broker-SelfRepair.ps1'
    $out = { param($r, $other = '') $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
      [pscustomobject]@{ Broker = $env:COMPUTERNAME; Result = $r; Other = $other; State = $(if ($t) { "$($t.State)" } else { '' }) } }
    if ($remove) {
      if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $name -Confirm:$false }
      Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
      return (& $out 'removed')
    }
    # another self-repair already there (a task on event 4648 of tssdis.exe): two would restart the services twice
    $others = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -ne $name -and
      @($_.Triggers | Where-Object { "$($_.Subscription)" -match 'tssdis\.exe' -and "$($_.Subscription)" -match '4648' }).Count })
    if ($others.Count) {
      if (-not $replace) { return (& $out 'other' (($others | ForEach-Object TaskName) -join ', ')) }
      foreach ($o in $others) { Disable-ScheduledTask -TaskName $o.TaskName -TaskPath $o.TaskPath | Out-Null }
    }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $bytes = [Convert]::FromBase64String($b64)
    $had = Test-Path -LiteralPath $dest
    $same = $had -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($dest)) -eq $b64
    [IO.File]::WriteAllBytes($dest, $bytes)
    if (-not [Diagnostics.EventLog]::SourceExists('OpenThinRDP-Broker')) { New-EventLog -LogName Application -Source 'OpenThinRDP-Broker' }
    # The process name is not in the trigger: XPath compares it case-sensitively; the script checks it.
    $sub = "<QueryList><Query Id=`"0`" Path=`"Security`"><Select Path=`"Security`">*[System[EventID=4648]] and *[EventData[Data[@Name='SubjectUserSid']='S-1-5-20' and Data[@Name='TargetUserName']='$env:COMPUTERNAME']]</Select></Query></QueryList>"
    $cls = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
    $trg = New-CimInstance -CimClass $cls -ClientOnly
    $trg.Subscription = $sub; $trg.Enabled = $true
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dest`""
    $pri = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $set = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $desc = 'Restarts the broker services (Tssdis, TScPubRPC, RDMS) when tssdis presents itself without the $: from then on every sign-in through this broker fails with event 804, 0x80070005. Log: C:\ProgramData\OpenThinRDP\broker-self-repair.log; Application events OpenThinRDP-Broker 1001-1003.'
    $was = [bool](Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)
    Register-ScheduledTask -TaskName $name -Action $act -Trigger $trg -Principal $pri -Settings $set -Description $desc -Force | Out-Null
    & $out $(if (-not $was) { 'installed' } elseif ($same) { 'unchanged' } else { 'updated' })
  }
}
