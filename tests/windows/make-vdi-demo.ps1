<#
  A demo of the Desktops page for screenshots: the recorded data of the tests (fixtures\vdi) moved to the present, so
  that the devices report "now" and the sign-ins happened this morning. Writes <Out>\thinclients (a management folder)
  and <Out>\vdi-demo.json (the answer of the probe), then, with -Shots, draws the pages into <Out>\*.png with the
  screenshot mode of the manager:
    make-vdi-demo.ps1 -Out C:\Users\Public\OpenThinRDP\demo-vdi -Shots
  By hand: OpenThinRDP-Manager.cmd -Folder <Out>\thinclients, with OTR_MANAGER_VDI_DEMO=<Out>\vdi-demo.json (and
  OTR_MANAGER_VDI_DRYRUN=1: the actions only say what they would do).
#>
param([Parameter(Mandatory = $true)][string]$Out, [switch]$Shots, [string]$Size = '1600x900')
$ErrorActionPreference = 'Stop'
$fx = Join-Path $PSScriptRoot 'fixtures\vdi'
$mw = Join-Path $PSScriptRoot '..\..\management\windows'
$then = [datetime]'2026-10-19T09:30:00'
$delta = (Get-Date) - $then
$delta = [TimeSpan]::FromMinutes([Math]::Floor($delta.TotalMinutes))
# every time of the files, in both forms (2026-10-19 08:02:04 and 2026-10-19T08:02:04)
function Move-Times([string]$text) {
  [regex]::Replace($text, '(\d{4}-\d\d-\d\d)([ T])(\d\d:\d\d:\d\d)', { param($x)
    $t = [datetime]::ParseExact("$($x.Groups[1].Value) $($x.Groups[3].Value)", 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + $delta
    $t.ToString('yyyy-MM-dd') + $x.Groups[2].Value + $t.ToString('HH:mm:ss') })
}
$dest = Join-Path $Out 'thinclients'
if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
New-Item -ItemType Directory -Path $dest | Out-Null
Copy-Item -Path (Join-Path $fx 'folder\*') -Destination $dest -Recurse
foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $dest 'status') -File)) { [IO.File]::WriteAllText($f.FullName, (Move-Times ([IO.File]::ReadAllText($f.FullName)))) }
# counted from midnight (null), not from the midnight of the recorded day moved to the present
$raw = Move-Times (([IO.File]::ReadAllText((Join-Path $fx 'raw.json'))).Replace('"Since":  "2026-10-19T00:00:00"', '"Since":  null'))
# the self-repair of RDCB1 is the one of this manager
$hash = (Get-FileHash -LiteralPath (Join-Path $mw 'rds\Broker-SelfRepair.ps1') -Algorithm SHA256).Hash
$raw = $raw.Replace('"Hash":  "CURRENT"', "`"Hash`":  `"$hash`"")
$json = Join-Path $Out 'vdi-demo.json'
[IO.File]::WriteAllText($json, $raw, (New-Object Text.UTF8Encoding $false))
"demo folder: $dest"; "probe answer: $json"
if (-not $Shots) { return }
$env:OTR_MANAGER_VDI_DEMO = $json; $env:OTR_MANAGER_SIZE = $Size; $env:OTR_MANAGER_VAULT = Join-Path $Out 'no-vault.otr'
$mgr = (Resolve-Path (Join-Path $mw 'OpenThinRDP-Manager.ps1')).Path
foreach ($s in @(@{ Name = 'manager-desktops'; Tab = 6; Row = 'bob'; Lang = 'en' }, @{ Name = 'manager-brokers'; Tab = 3; Row = ''; Lang = 'en' },
  @{ Name = 'manager-desktops-it'; Tab = 6; Row = 'bob'; Lang = 'it' }, @{ Name = 'manager-brokers-it'; Tab = 3; Row = ''; Lang = 'it' })) {
  $env:OTR_MANAGER_SCREENSHOT = Join-Path $Out "$($s.Name).png"; $env:OTR_MANAGER_TAB = "$($s.Tab)"; $env:OTR_MANAGER_VDI_ROW = $s.Row
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $mgr -Folder $dest -Language $s.Lang
  $env:OTR_MANAGER_SCREENSHOT
}
