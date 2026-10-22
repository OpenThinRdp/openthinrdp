<#
  OpenThinRDP Manager - central management of OpenThinRDP thin clients (Windows PowerShell 5.1, WinForms).
  Reads the management folder where the devices report every 5 minutes and at every event:
    status\<hostname>.txt, status\<hostname>-events.log
  and writes the central configuration the devices read back every 5 minutes and at boot:
    config\common.conf        = EVERY device (an active key wins over the settings dialog of the device)
    config\<hostname>.conf    = exceptions for one device (wins over common.conf; also hostname, user, address)
    config\authorized_keys    = SSH public keys of the administrators (used by devices with SSH=on)
  The devices check everything again with save-config.sh and reject the WHOLE configuration if a single value
  is wrong: here the same rules run BEFORE writing. Every overwritten file is copied to config\backup\ first,
  every change goes to config\changes.log.
  Start:  OpenThinRDP-Manager.cmd [-Folder \\fileserver\thinclients]   (no -Folder = choose it, the last one is remembered)
                                  [-Language en|it]                    (no -Language = the Windows display language
                                                                        when lang\ has a file for it, else English)
  Texts:  every text of the window is in lang\en.psd1, translated in lang\<language>.psd1 (UTF-8 with BOM);
          a key missing from a translation shows the English text. Setting keys, values, the files written
          and config\changes.log stay in English: the devices and other tools read them.
  Sign:   OpenThinRDP-Manager.cmd -Sign <folder>\LATEST.txt   (an update package made by make-update.sh without -k:
                                  asks the access code of the vault, writes LATEST.txt.sig next to it)
  Vault:  vault.otr next to this file: the SSH key of the remote screen and the key that signs the updates,
          encrypted with the access code asked at the first start (OtrVault.cs)
  Update: OpenThinRDP-Manager.cmd -UpdateManager   (no window: the manager of the latest GitHub release replaces this
                                  one when it is newer; exit code 0 = updated, 1 = error, 2 = nothing to do)
          VERSION next to this file = the release it came from; without it (the repository) it never updates itself
  Tests:  . .\OpenThinRDP-Manager.ps1 -Folder <path> -FunctionsOnly [-Language en]   (loads the functions, no window)
          $env:OTR_MANAGER_SCREENSHOT = <file.png> (+ $env:OTR_MANAGER_TAB = 0, 1 or 2): draws the window into
          the PNG instead of showing it, then exits
          $env:OTR_MANAGER_RELEASES = <folder or URL>: where the manager looks for its own updates (instead of the
          latest GitHub release)
          $env:OTR_MANAGER_VDI_DEMO = <file.json>: the Desktops page and Brokers and hosts from that answer of the probe
          instead of the servers (tests\windows\make-vdi-demo.ps1); $env:OTR_MANAGER_VDI_DRYRUN = 1: their actions
          say what they would do and change nothing; $env:OTR_MANAGER_VDI_ROW = the user selected in a screenshot
          $env:OTR_MANAGER_HEALTH_DEMO = <file.json>: the Health Center from that answer of its probe;
          $env:OTR_MANAGER_HEALTH_ITEM = the item selected in a screenshot (host:HV1, vm:VM-ALICE...)
          $env:OTR_MANAGER_SETTINGS = <manager.json>: settings of their own instead of those of the account
          tests\windows\manager-tests.ps1, health-tests.ps1: the tests of the manager in Windows PowerShell 5.1 (CI)
  Desktops: OtrVdi.ps1 next to this file (brokers, Hyper-V hosts, desktops, sessions; rds\ = the broker self-repair)
  Health Center: OtrHealth.ps1 next to this file (hosts, cluster, storage, VMs, DCs, DNS, SQL AlwaysOn, devices, backups)
#>
param(
  [string]$Folder,
  [string]$Language,       # en, it, ... (a file in lang\); empty = the Windows display language
  [switch]$FunctionsOnly,  # for tests: load the functions without opening the window
  [string]$Sign,           # LATEST.txt of an update package to sign with the key of the vault (no window)
  [switch]$UpdateManager   # the manager of the latest release in place of this one (no window)
)
$script:T0 = [Diagnostics.Stopwatch]::StartNew(); function Write-Trace($w) { if ($env:OTR_MANAGER_TRACE) { [IO.File]::AppendAllText($env:OTR_MANAGER_TRACE, ("{0,6} ms  {1}`r`n" -f $script:T0.ElapsedMilliseconds, $w)) } }
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# The C# of the manager compiled once per user and version, then loaded from %LOCALAPPDATA%\OpenThinRDP\types: five
# compilations at every start cost one to two seconds (more with a cold compiler). The name of the DLL is a hash of
# the source, so a changed source is compiled again; anything wrong with the cache = compiled in memory as before.
function Add-OtrType([string]$TypeDefinition, [string]$Path, [string[]]$ReferencedAssemblies = @()) {
  $src = if ($Path) { [IO.File]::ReadAllText($Path) } else { $TypeDefinition }
  $p = @{ TypeDefinition = $src }; if ($ReferencedAssemblies) { $p.ReferencedAssemblies = $ReferencedAssemblies }
  try {
    $sha = [Security.Cryptography.SHA256]::Create()
    $h = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($src + '|' + ($ReferencedAssemblies -join ',') + '|' + $PSVersionTable.CLRVersion))).Replace('-', '').Substring(0, 20)
    $dir = Join-Path $env:LOCALAPPDATA 'OpenThinRDP\types'; $dll = Join-Path $dir "otr-$h.dll"
    if (-not (Test-Path -LiteralPath $dll)) {
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      Add-Type @p -OutputAssembly "$dll.part" -OutputType Library; Move-Item -LiteralPath "$dll.part" -Destination $dll -Force
    }
    Add-Type -Path $dll; return
  } catch { }
  Add-Type @p
}
# "natural" sort of the list columns: numbers inside the text compare as numbers (thinclient2 before
# thinclient10, 192.0.2.22 before 192.0.2.165), the rest ignoring case.
# WPA key in C#: the PowerShell loop takes seconds for 8192 HMAC rounds.
if (-not ('OtrColumnSorter' -as [type])) {
  Add-OtrType -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Text;
using System.Windows.Forms;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
public class OtrColumnSorter : System.Collections.IComparer {
    public int Column = 0;
    public int NameColumn = 0;   // equal values: by name
    public bool Descending = false;
    public int Compare(object x, object y) {
        ListViewItem a = (ListViewItem)x, b = (ListViewItem)y;
        string sa = Column < a.SubItems.Count ? a.SubItems[Column].Text : "";
        string sb = Column < b.SubItems.Count ? b.SubItems[Column].Text : "";
        int r = Natural(Durations(sa), Durations(sb));
        if (r == 0 && Column != NameColumn) { return Natural(a.SubItems.Count > NameColumn ? a.SubItems[NameColumn].Text : "", b.SubItems.Count > NameColumn ? b.SubItems[NameColumn].Text : ""); }
        return Descending ? -r : r;
    }
    // durations in minutes, so "45 min" sorts before "3 hours": uptime -p ("1 week, 3 days, 5 minutes") in
    // the Uptime column, and "N min/hours/days" in the state of the devices that stopped reporting
    static readonly Regex RxDuration = new Regex(@"\d+\s+(year|week|day|hour|minute)s?(\s*,\s*\d+\s+(year|week|day|hour|minute)s?)*");
    static readonly Regex RxPart = new Regex(@"(\d+)\s+(year|week|day|hour|minute)");
    // units in the language of the window (the state column: "3 ore", "2 giorni"), added with AddUnit
    static readonly System.Collections.Generic.Dictionary<string, long> Units = new System.Collections.Generic.Dictionary<string, long>();
    static Regex RxUnits = null;
    public static void AddUnit(string word, long minutes) {
        Units[word] = minutes;
        string[] w = new string[Units.Count]; Units.Keys.CopyTo(w, 0);
        for (int i = 0; i < w.Length; i++) w[i] = Regex.Escape(w[i]);
        RxUnits = new Regex(@"\b(\d+)\s+(" + string.Join("|", w) + @")\b");
    }
    public static string Durations(string s) {
        string r = RxDuration.Replace(s, delegate(Match u) {
            long m = 0;
            foreach (Match p in RxPart.Matches(u.Value)) {
                long n = long.Parse(p.Groups[1].Value);
                switch (p.Groups[2].Value) {
                    case "year": m += n * 525600; break; case "week": m += n * 10080; break;
                    case "day": m += n * 1440; break; case "hour": m += n * 60; break; default: m += n; break;
                }
            }
            return m + " min";
        });
        if (RxUnits != null) { r = RxUnits.Replace(r, delegate(Match u) { return (long.Parse(u.Groups[1].Value) * Units[u.Groups[2].Value]) + " min"; }); }
        return r;
    }
    public static int Natural(string a, string b) {
        int i = 0, j = 0;
        while (i < a.Length && j < b.Length) {
            if (char.IsDigit(a[i]) && char.IsDigit(b[j])) {
                int si = i, sj = j;
                while (i < a.Length && char.IsDigit(a[i])) i++;
                while (j < b.Length && char.IsDigit(b[j])) j++;
                string na = a.Substring(si, i - si).TrimStart('0'), nb = b.Substring(sj, j - sj).TrimStart('0');
                if (na.Length != nb.Length) return na.Length.CompareTo(nb.Length);
                int c = string.CompareOrdinal(na, nb); if (c != 0) return c;
            } else {
                int c = char.ToLowerInvariant(a[i]).CompareTo(char.ToLowerInvariant(b[j]));
                if (c != 0) return c; i++; j++;
            }
        }
        return (a.Length - i).CompareTo(b.Length - j);
    }
}
public static class OtrCrypto {
    // WPA key from the passphrase, as wpa_passphrase: PBKDF2-HMAC-SHA1(passphrase, SSID, 4096 rounds, 32 bytes).
    // Written by hand: Rfc2898DeriveBytes of .NET refuses salts (here the SSID) shorter than 8 bytes.
    public static string WpaPsk(string passphrase, string ssid) {
        HMACSHA1 h = new HMACSHA1(Encoding.UTF8.GetBytes(passphrase));
        byte[] salt = Encoding.UTF8.GetBytes(ssid);
        byte[] key = new byte[40];
        for (int block = 1; block <= 2; block++) {
            byte[] s = new byte[salt.Length + 4];
            Buffer.BlockCopy(salt, 0, s, 0, salt.Length);
            s[salt.Length + 3] = (byte)block;
            byte[] u = h.ComputeHash(s), t = (byte[])u.Clone();
            for (int j = 1; j < 4096; j++) { u = h.ComputeHash(u); for (int b = 0; b < 20; b++) t[b] ^= u[b]; }
            Buffer.BlockCopy(t, 0, key, (block - 1) * 20, 20);
        }
        return Hex(key, 32);
    }
    // the settings PIN as kiosk.sh checks it (pin_match): pbkdf2-sha256:<iterations>:<salt>:<key>, salted and slow
    public static string Pin(string pin) {
        byte[] salt = new byte[16];
        using (RandomNumberGenerator r = RandomNumberGenerator.Create()) { r.GetBytes(salt); }
        using (Rfc2898DeriveBytes k = new Rfc2898DeriveBytes(Encoding.UTF8.GetBytes(pin), salt, 600000, HashAlgorithmName.SHA256)) {
            return "pbkdf2-sha256:600000:" + Hex(salt, salt.Length) + ":" + Hex(k.GetBytes(32), 32);
        }
    }
    // the settings PIN of 0.1.4 and earlier: printf '%s' "$pin" | sha256sum
    public static string Sha256(string text) {
        using (SHA256 s = SHA256.Create()) { byte[] d = s.ComputeHash(Encoding.UTF8.GetBytes(text)); return Hex(d, d.Length); }
    }
    static string Hex(byte[] d, int n) { StringBuilder sb = new StringBuilder(); for (int i = 0; i < n; i++) sb.Append(d[i].ToString("x2")); return sb.ToString(); }
}
'@
}
# Ed25519, OpenPGP signatures and the vault (.NET Framework has no Ed25519): OtrVault.cs next to this file
if (-not ('OtrVault' -as [type])) { Add-OtrType -ReferencedAssemblies System.Numerics -Path (Join-Path $PSScriptRoot 'OtrVault.cs') }
# the OpenThinRDP icon of every window (title bar, taskbar, Alt+Tab): openthinrdp.ico next to this file
$script:AppIcon = $null
$icoFile = Join-Path $PSScriptRoot 'openthinrdp.ico'
if (Test-Path -LiteralPath $icoFile) { try { $script:AppIcon = New-Object System.Drawing.Icon($icoFile) } catch { } }
function Set-WindowIcon($w) { if ($script:AppIcon) { $w.Icon = $script:AppIcon } }

# ---------------------------------------------------------------------------------------------
# Language: lang\en.psd1 has every text of the window, lang\<xx>.psd1 replaces the ones it translates
# (a key missing or empty there keeps the English text, never an empty label)
# ---------------------------------------------------------------------------------------------
$script:LangDir = Join-Path $PSScriptRoot 'lang'
# A language file: one table of constant texts. Read entry by entry (constants only, nothing runs): Import-PowerShellDataFile
# refuses a table with more than 500 entries.
function Import-TextTable([string]$file) {
  $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errs)
  if ($errs.Count) { throw "$file, line $($errs[0].Extent.StartLineNumber): $($errs[0].Message)" }
  $h = $ast.Find({ param($a) $a -is [System.Management.Automation.Language.HashtableAst] }, $false)
  if (-not $h) { throw "$file holds no table of texts" }
  $t = @{}
  foreach ($kv in $h.KeyValuePairs) { $t[[string]$kv.Item1.SafeGetValue()] = [string]$kv.Item2.SafeGetValue() }
  $t
}
function Read-LanguageTexts([string]$dir, [string]$lang) {
  $t = @{}
  $en = Import-TextTable (Join-Path $dir 'en.psd1')
  foreach ($k in $en.Keys) { $t[$k] = $en[$k] }
  $f = Join-Path $dir "$lang.psd1"
  if ($lang -and $lang -ne 'en' -and (Test-Path -LiteralPath $f)) {
    try { $tr = Import-TextTable $f } catch { Write-Warning "$f not readable, English texts used: $($_.Exception.Message)"; $tr = @{} }
    foreach ($k in $tr.Keys) { if ($tr[$k]) { $t[$k] = $tr[$k] } }
  }
  $t
}
# -Language when given, else the Windows display language; English when lang\ has no file for it
function Select-Language([string]$wanted) {
  $lang = if ($wanted) { $wanted.ToLower() } else { (Get-UICulture).TwoLetterISOLanguageName.ToLower() }
  if ($lang -cmatch '^[a-z]{2,3}$' -and (Test-Path -LiteralPath (Join-Path $script:LangDir "$lang.psd1"))) { return $lang }
  if ($wanted -and $wanted -ne 'en') { Write-Warning "No language file lang\$wanted.psd1: English texts used" }
  'en'
}
# a text of the window; with values after the key it is a format string ({0}, {1}...). An unknown key
# shows the key itself.
function Get-Text([string]$Key) {
  $t = $script:Text[$Key]
  if (-not $t) { $t = $Key }
  if ($args.Count) { $t -f $args } else { $t }
}
try {
  if (-not $Language) {
    try { $sf = if ($env:OTR_MANAGER_SETTINGS) { $env:OTR_MANAGER_SETTINGS } else { Join-Path $env:APPDATA 'OpenThinRDP\manager.json' }; if (Test-Path -LiteralPath $sf) { $Language = [string](Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json).Language } } catch { }
  }
  $script:Language = Select-Language $Language
  $script:Text = Read-LanguageTexts $script:LangDir $script:Language
} catch {
  # the window is started hidden (OpenThinRDP-Manager.cmd): without a message box nobody would see why
  $m = "Cannot read the texts of the window in $($script:LangDir): $($_.Exception.Message)"
  if (-not $FunctionsOnly) { [void][System.Windows.Forms.MessageBox]::Show($m, 'OpenThinRDP Manager', 'OK', 'Error') }
  throw $m
}
# the state column sorts "45 min" before "3 hours" also in the words of the language
foreach ($u in @(@('DurMinutes', 1), @('DurHours', 60), @('DurDays', 1440))) {
  $w = ((Get-Text $u[0]) -replace '\{0\}', '').Trim(); if ($w) { [OtrColumnSorter]::AddUnit($w, $u[1]) }
}
# typed in a secret cell, these keep the saved Wi-Fi key / settings PIN ("(saved)" / "(set)" in English)
$script:MarkSaved = Get-Text 'MarkSaved'
$script:MarkSet = Get-Text 'MarkSet'

$script:Utf8 = New-Object System.Text.UTF8Encoding $false
$script:StaleMinutes = 15     # same threshold as SUMMARY.csv written by the devices: over it = off or offline
# keys that identify a device: central-apply.sh ignores them in common.conf
$script:HostOnly = @('HOSTNAME', 'DEFAULT_USER', 'NETMODE', 'IPADDR', 'VPN_ADDRESS')
$script:SettingsFile = Join-Path $env:APPDATA 'OpenThinRDP\manager.json'
# tests and screenshots: settings of their own, never those of the account
if ($env:OTR_MANAGER_SETTINGS) { $script:SettingsFile = $env:OTR_MANAGER_SETTINGS }

function Set-ManagementFolder([string]$path) {
  if ($path.Length -gt 3) { $path = $path.TrimEnd('\', '/') }
  $script:Folder = $path
  $script:StatusDir = Join-Path $path 'status'
  $script:ConfigDir = Join-Path $path 'config'
  $script:BackupDir = Join-Path $script:ConfigDir 'backup'
  $script:ChangeLog = Join-Path $script:ConfigDir 'changes.log'
  $script:CommonFile = Join-Path $script:ConfigDir 'common.conf'
  $script:KeysFile = Join-Path $script:ConfigDir 'authorized_keys'
}
# Groups are folders: config\groups\<group>\_group.conf (the settings of the group) and the files of its devices,
# config\groups\<group>\<hostname>.conf; a device in no group has its file in config\. Get-GroupFiles refreshes the
# map name -> file of the devices in a group (once per refresh: hundreds of devices, one directory read).
$script:GroupFiles = @{}
function Get-GroupsDir { Join-Path $script:ConfigDir 'groups' }
function Get-GroupFiles {
  $m = @{}
  foreach ($x in @(Get-ChildItem -Path (Join-Path (Get-GroupsDir) '*\*.conf') -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '_group.conf' -and $_.Extension -eq '.conf' })) {
    $m[$x.BaseName.ToLower()] = [pscustomobject]@{ File = $x.FullName; Group = $x.Directory.Name } }
  $script:GroupFiles = $m; $m
}
# the name of the site, at the top of the device list: the domain of this PC (FINCO-AGRI), else the folder's name
function Get-SiteName { $d = [string]$env:USERDOMAIN; if ($d -and $d -ne $env:COMPUTERNAME) { $d.ToUpper() } else { Split-Path $script:Folder -Leaf } }
function Get-Groups {@(Get-ChildItem -LiteralPath (Get-GroupsDir) -Directory -ErrorAction SilentlyContinue | ForEach-Object Name | Sort-Object) }
function New-DeviceGroup([string]$name) {
  if ($name -notmatch '^[A-Za-z0-9._-]{1,64}$') { throw (Get-Text 'ErrGroupName') }
  $d = Join-Path (Get-GroupsDir) $name; if (Test-Path -LiteralPath $d) { throw (Get-Text 'ErrGroupExists' $name) }
  New-Item -ItemType Directory -Path $d -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $d '_group.conf'), "# Settings for the devices of the group $name (written by the OpenThinRDP manager).`r`n# They win over common.conf; the file of each device wins over them.`r`n", $script:Utf8)
  Add-ChangeLog "group $name created"
}
# the file of a device moves to the folder of the group ('' = no group): the device follows at its next report
# the first version of the devices that reads config\groups\<group>\<device>.conf
$script:GroupsMinVersion = '0.2.9'
function Move-DeviceToGroup([string]$device, [string]$group) {
  $from = Get-HostFile $device
  $dir = if ($group) { Join-Path (Get-GroupsDir) $group } else { $script:ConfigDir }
  if (-not (Test-Path -LiteralPath $dir)) { throw (Get-Text 'ErrGroupMissing' $group) }
  # a device before 0.2.9 looks for its file only in config\: in a group it would lose every setting of its own
  # (a device that never reported is let through: it is installed with a version that knows groups)
  if ($group) { $d = @($script:Devices | Where-Object Name -eq $device) | Select-Object -First 1
    $v = if ($d) { (([string]$d.S['SOFTWARE']).Trim() -split '\s+')[-1] } else { '' }
    if ($v -match '^\d+\.\d+' -and (Compare-Version $v $script:GroupsMinVersion) -lt 0) { throw (Get-Text 'ErrGroupOldVersion' $device $v) } }
  $to = Join-Path $dir "$device.conf"
  if ($from -ieq $to) { return }
  if (Test-Path -LiteralPath $from) { Move-Item -LiteralPath $from -Destination $to }
  elseif ($group) { [IO.File]::WriteAllText($to, (($script:HostHeader -join "`r`n") + "`r`n"), $script:Utf8) }
  # out of every group and nothing of its own: no file
  if (-not $group -and (Test-Path -LiteralPath $to) -and -not (Read-ConfFile $to).Count) { Move-Item -LiteralPath $to -Destination (Get-BackupPath $to) }
  Add-ChangeLog ("{0}: group {1}" -f $device, $(if ($group) { $group } else { '(none)' }))
  [void](Get-GroupFiles)
}
function Remove-DeviceGroup([string]$group) {
  $d = Join-Path (Get-GroupsDir) $group
  if (@(Get-ChildItem -LiteralPath $d -Filter '*.conf' -File | Where-Object Name -ne '_group.conf').Count) { throw (Get-Text 'ErrGroupNotEmpty' $group) }
  $g = Join-Path $d '_group.conf'
  if (Test-Path -LiteralPath $g) { Move-Item -LiteralPath $g -Destination (Get-BackupPath (Join-Path $script:ConfigDir "group-$group.conf")) }
  Remove-Item -LiteralPath $d -Recurse -Force
  Add-ChangeLog "group $group removed"
}
function Get-HostFile($name) {
  $g = $script:GroupFiles["$name".ToLower()]; if ($g -and (Test-Path -LiteralPath $g.File)) { return $g.File }
  Join-Path $script:ConfigDir "$name.conf"
}

# ---------------------------------------------------------------------------------------------
# Settings: the keys of defaults.conf on the device (+ HOSTNAME, + WIFI_PSK which never leaves this tool
# as a password). Type = which save-config.sh rule applies. Default = project default (defaults.conf),
# proposed in common.conf when no device reports the key yet (a value: never translated).
# Name and description of each setting: Label_<KEY> and Help_<KEY> in lang\*.psd1; groups: Section*.
# ---------------------------------------------------------------------------------------------
$script:Section = ''
function Set-Section($textKey) { $script:Section = Get-Text $textKey }
function New-Setting($key, $type, $default, $choices = $null) {
  [pscustomobject]@{ Key = $key; Label = (Get-Text "Label_$key"); Type = $type; Default = $default; Help = (Get-Text "Help_$key"); Choices = $choices
                     HostOnly = ($script:HostOnly -contains $key); Section = $script:Section }
}
$script:Settings = @(
  (Set-Section 'SectionRemoteDesktop')
  (New-Setting 'HOSTNAME'            'host'       '')
  (New-Setting 'DEFAULT_USER'        'user'       '')
  (New-Setting 'BROKER'              'name'       '')
  (New-Setting 'BROKER_FALLBACK'     'names'      '')
  (New-Setting 'DOMAIN'              'name'       '')
  (New-Setting 'LOAD_BALANCE_INFO'   'collection' '')
  (New-Setting 'TRANSPORT'           'choice'     'auto' @('auto', 'udp', 'tcp'))
  (New-Setting 'RDP_AUTH'            'choice'     'negotiate' @('negotiate', 'kerberos', 'ntlm'))
  (New-Setting 'RDP_CERT'            'choice'     'tofu' @('tofu', 'ignore', 'verify'))
  (New-Setting 'RDP_GATEWAY'         'hostport'   '')
  (New-Setting 'RDP_GATEWAY_USE'     'choice'     'always' @('always', 'detect'))
  (New-Setting 'RDP_GFX'             'gfx'        'progressive,AVC420:off,AVC444:off')
  (New-Setting 'RDP_KEYBOARD'        'rdpkbd'     '')
  (New-Setting 'MULTIMON'            'choice'     'auto' @('auto', 'off'))
  (New-Setting 'RDP_EXTRA'           'extra'      '')
  (New-Setting 'SESSION_THRESHOLD'   'threshold'  '10')
  (New-Setting 'SHUTDOWN_SECS'       'shutdown'   '10')
  (Set-Section 'SectionUsb')
  (New-Setting 'USB_MODE'            'choice'     'all' @('all', 'auto', 'disks'))
  (New-Setting 'USB_REDIRECT'        'usb'        '')
  (Set-Section 'SectionNetwork')
  (New-Setting 'NETMODE'             'choice'     'dhcp' @('dhcp', 'static'))
  (New-Setting 'IPADDR'              'ip'         '')
  (New-Setting 'NETMASK'             'mask'       '255.255.255.0')
  (New-Setting 'GATEWAY'             'ip'         '')
  (New-Setting 'DNS1'                'ip'         '')
  (New-Setting 'DNS2'                'ip'         '')
  (New-Setting 'NTP'                 'names'      '')
  (New-Setting 'VPN'                 'choice'     'off' @('off', 'wireguard', 'openvpn'))
  (New-Setting 'VPN_SERVER'          'hostport'   '')
  (New-Setting 'VPN_SERVER_KEY'      'wgkey'      '')
  (New-Setting 'VPN_ADDRESS'         'cidr'       '')
  (New-Setting 'VPN_ROUTES'          'cidrs'      '')
  (New-Setting 'VPN_DNS'             'ips'        '')
  (New-Setting 'WIFI'                'choice'     'off' @('off', 'on'))
  (New-Setting 'WIFI_SSID'           'ssid'       '')
  (New-Setting 'WIFI_COUNTRY'        'country'    '')
  (New-Setting 'WIFI_SECURITY'       'choice'     'psk' @('psk', 'peap', 'tls'))
  (New-Setting 'WIFI_PSK'            'psk'        '')
  (New-Setting 'DOT1X'               'choice'     'off' @('off', 'peap', 'tls'))
  (New-Setting 'EAP_IDENTITY'        'eapid'      '')
  (New-Setting 'EAP_ANONYMOUS'       'eapid'      '')
  (New-Setting 'EAP_CA'              'eapca'      'system')
  (New-Setting 'EAP_SERVER_NAME'     'dnsnames'   '')
  (Set-Section 'SectionManagement')
  (New-Setting 'MGMT_SHARE'          'share'      '')
  (New-Setting 'MGMT_USER'           'user'       '')
  (New-Setting 'SECURITY_UPDATES'    'choice'     'on' @('off', 'on'))
  (New-Setting 'TPM_SECRETS'         'choice'     'on' @('on', 'off'))
  (New-Setting 'UPDATE_FROM'         'choice'     'github' @('github', 'share', 'off'))
  (New-Setting 'UPDATE_GITHUB'       'repo'       'OpenThinRdp/openthinrdp')
  (New-Setting 'UPDATE_KEY'          'choice'     'any' @('any', 'site'))
  (New-Setting 'UPDATE_TO'           'updateto'   'latest')
  (New-Setting 'SSH'                 'choice'     'off' @('off', 'on'))
  (New-Setting 'REMOTE_SCREEN'       'choice'     'on' @('on', 'off'))
  (Set-Section 'SectionWeb')
  (New-Setting 'WEB_BUTTON'          'choice'     'none' @('none', 'app', 'browser', 'kiosk'))
  (New-Setting 'WEB_LABEL'           'text'       'Web')
  (New-Setting 'WEB_URL'             'url'        '')
  (New-Setting 'WEB_ALLOW'           'urls'       '')
  (New-Setting 'KIOSK_URL'           'url'        '')
  (New-Setting 'KIOSK_RELOAD_MIN'    'reload'     '10')
  (Set-Section 'SectionPower')
  (New-Setting 'POWER_ON_TIME'       'time'       '')
  (New-Setting 'POWER_OFF_TIME'      'time'       '')
  (New-Setting 'POWER_ON_DAYS'       'days'       '1234567')
  (Set-Section 'SectionLook')
  (New-Setting 'LANGUAGE'            'lang'       'en')
  (New-Setting 'KEYBOARD'            'kbd'        'us')
  (New-Setting 'TITLE'               'text'       'Remote desktop')
  (New-Setting 'LOGO'                'logo'       '/opt/openthinrdp/branding/logo.png')
  (New-Setting 'BG_TOP'              'color'      '#1b2733')
  (New-Setting 'BG_BOTTOM'           'color'      '#000000')
  (New-Setting 'SUPPORT_TEXT'        'text'       '')
  (New-Setting 'SETTINGS_PIN_SHA256' 'pin'        '')
)
function Get-Setting($key) { $script:Settings | Where-Object Key -eq $key | Select-Object -First 1 }

# ---------------------------------------------------------------------------------------------
# Checks: the rules of save-config.sh, with case-sensitive regexes as bash uses them
# ---------------------------------------------------------------------------------------------
$script:Rx = @{
  Host       = '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
  Name       = '^[A-Za-z0-9]([A-Za-z0-9.-]{0,252})$'
  User       = '^[A-Za-z0-9._@\\-]{1,104}$'
  Url        = '^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~:/?#@!$&()*+,;=%-]*)?$'
  BadText    = '[<>&|"`$\\]'
  Share      = '^(\\\\|//)[A-Za-z0-9.-]+[\\/][A-Za-z0-9 ._$\\/-]+$'
  Extra      = '^[A-Za-z0-9 /:+,._=#-]*$'
  Time       = '^([01][0-9]|2[0-3]):[0-5][0-9]$'
  Collection = '^[A-Za-z0-9._:/#=-]*$'
  Gfx        = '^[A-Za-z0-9:,]*$'
  RdpKbd     = '^(0x[0-9a-fA-F]{8})?$'
  Usb        = '^([0-9a-f]{4}:[0-9a-f]{4}( [0-9a-f]{4}:[0-9a-f]{4})*)?$'
  Kbd        = '^[a-z][a-z0-9_-]{1,15}$'
  Logo       = '^(/[A-Za-z0-9._/-]+\.png)?$'
  Color      = '^#[0-9a-fA-F]{6}$'
  Hex64      = '^[0-9a-fA-F]{64}$'
  Version    = '^[0-9A-Za-z._-]{1,64}$'
  WgKey      = '^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$'
  # 802.1X: an identity (EXAMPLE\user, user@example.com, host/pc1.example.com, PC1$) and a CA file of the site folder
  EapId      = '^[A-Za-z0-9._@\\/$ +-]{1,253}$'
  EapCa      = '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}\.crt$'
  SshKey     = '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com) [A-Za-z0-9+/=]+( .*)?$'
}
function Test-Ip([string]$s) {
  if ($s -cnotmatch '^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$') { return $false }
  foreach ($i in 1..4) { if ([int]$Matches[$i] -gt 255) { return $false } }
  $true
}
# a network or an address with its prefix: 192.168.0.0/23 (as cidrok in save-config.sh)
function Test-Cidr([string]$s) { ($s -cmatch '^([0-9.]+)/([0-9]{1,2})$') -and (Test-Ip $Matches[1]) -and [int]$Matches[2] -le 32 }
function ConvertTo-IpNumber([string]$s) { $p = $s.Split('.'); [uint64]$p[0] * 16777216 + [uint64]$p[1] * 65536 + [uint64]$p[2] * 256 + [uint64]$p[3] }
function Test-Mask([string]$s) {
  if (-not (Test-Ip $s)) { return $false }
  $m = ConvertTo-IpNumber $s; $inv = [uint64]4294967295 - $m
  ($m -ne 0) -and (($inv -band ($inv + 1)) -eq 0)
}
# lists: the device squeezes spaces, commas and semicolons into single spaces (tr -s ' ,;' ' ')
function Split-List([string]$v) { @($v -split '[ ,;]+' | Where-Object { $_ }) }
function Test-Text([string]$v) { ($v -cnotmatch $script:Rx.BadText) -and $v.Length -le 200 }

# error for a single value, or $null when it is good
function Test-SettingValue([string]$key, [string]$v) {
  $s = Get-Setting $key
  if (-not $s) { return (Get-Text 'ErrUnknownSetting' $key) }
  $L = $s.Label
  # a line break would put a second KEY= line in the file, read by the device as a separate setting
  if ($v -match '[\x00-\x1f\x7f]') { return (Get-Text 'ErrControlChars' $L) }
  switch ($s.Type) {
    'host'       { if ($v -cnotmatch $script:Rx.Host -or $v -cmatch '^[0-9]+$') { return (Get-Text 'ErrHostname') } }
    'user'       { if ($v -ne '' -and $v -cnotmatch $script:Rx.User) { return (Get-Text 'ErrUser') } }
    'name'       { if ($v -ne '' -and $v -cnotmatch $script:Rx.Name) { return (Get-Text 'ErrNotValid' $L) } }
    # a name or an address, optionally :port (as save-config.sh on the device)
    'hostport'   { if ($v -ne '') { $h = $v; $p = 443; if ($v -match '^(.+):(\d{1,5})$') { $h = $Matches[1]; $p = [int]$Matches[2] }
                   if ((-not (Test-Ip $h) -and $h -cnotmatch $script:Rx.Name) -or $p -lt 1 -or $p -gt 65535) { return (Get-Text 'ErrHostPort' $L) } } }
    'wgkey'      { if ($v -ne '' -and $v -cnotmatch $script:Rx.WgKey) { return (Get-Text 'ErrWgKey' $L) } }
    'cidr'       { if ($v -ne '' -and -not (Test-Cidr $v)) { return (Get-Text 'ErrCidr' $L) } }
    'cidrs'      { foreach ($t in (Split-List $v)) { if (-not (Test-Cidr $t)) { return (Get-Text 'ErrCidrValue' $L $t) } } }
    'ips'        { foreach ($t in (Split-List $v)) { if (-not (Test-Ip $t)) { return (Get-Text 'ErrListValue' $L $t) } } }
    'names'      { foreach ($t in (Split-List $v)) { if (-not (Test-Ip $t) -and $t -cnotmatch $script:Rx.Name) { return (Get-Text 'ErrListValue' $L $t) } } }
    # names only (the certificate of a RADIUS server is for a name): EAP_SERVER_NAME
    'dnsnames'   { foreach ($t in (Split-List $v)) { if ($t -cnotmatch $script:Rx.Name) { return (Get-Text 'ErrListValue' $L $t) } } }
    'eapid'      { if ($v.Trim() -ne '' -and $v.Trim() -cnotmatch $script:Rx.EapId) { return (Get-Text 'ErrEapId' $L) } }
    'eapca'      { $c = $v.Trim(); if ($c -ne '' -and $c -ine 'system' -and $c -cnotmatch $script:Rx.EapCa) { return (Get-Text 'ErrEapCa' $L) } }
    'collection' { if ($v -cnotmatch $script:Rx.Collection) { return (Get-Text 'ErrCollection') } }
    'repo'       { if ($v -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { return (Get-Text 'ErrRepo') } }
    # latest, or a version as the index files name it: v0.2.0 is the GitHub tag, and updates\versions\v0.2.0.txt never exists
    'updateto'   { if ($v -ne '' -and ($v -cnotmatch $script:Rx.Version -or $v -cmatch '^[vV][0-9]')) { return (Get-Text 'ErrUpdateTo') } }
    'choice'     { if ($s.Choices -notcontains $v) { return (Get-Text 'ErrChoice' $L ($s.Choices -join ', ')) } }
    'gfx'        { if ($v -cnotmatch $script:Rx.Gfx) { return (Get-Text 'ErrGfx' $L) } }
    'rdpkbd'     { if ($v -cnotmatch $script:Rx.RdpKbd) { return (Get-Text 'ErrRdpKbd' $L) } }
    'extra'      { if ($v -cnotmatch $script:Rx.Extra) { return (Get-Text 'ErrExtra' $L) } }
    'threshold'  { if ($v -cnotmatch '^[0-9]{1,3}$' -or [int]$v -lt 5 -or [int]$v -gt 120) { return (Get-Text 'ErrThreshold') } }
    'shutdown'   { if ($v -cnotmatch '^[0-9]{1,4}$' -or [int]$v -gt 3600) { return (Get-Text 'ErrShutdown') } }
    'usb'        { if (((Split-List $v) -join ' ').ToLower() -cnotmatch $script:Rx.Usb) { return (Get-Text 'ErrUsb') } }
    'ip'         { if ($v -ne '' -and -not (Test-Ip $v)) { return (Get-Text 'ErrNotValid' $L) } }
    'mask'       { if ($v -ne '' -and -not (Test-Mask $v)) { return (Get-Text 'ErrNetmask') } }
    'ssid'       { if ($v.Length -gt 32 -or $v -match '["|\\]') { return (Get-Text 'ErrSsid') } }
    'country'    { if ($v.ToUpper() -cnotmatch '^([A-Z]{2})?$') { return (Get-Text 'ErrCountry') } }
    'psk'        { if ($v -ne $script:MarkSaved -and $v -cnotmatch $script:Rx.Hex64 -and ($v.Length -lt 8 -or $v.Length -gt 63)) { return (Get-Text 'ErrPsk') } }
    'share'      { if ($v -ne '' -and $v -cnotmatch $script:Rx.Share) { return (Get-Text 'ErrShare') } }
    'text'       { if (-not (Test-Text $v)) { return (Get-Text 'ErrText' $L) } }
    'url'        { if ($v -ne '' -and $v -cnotmatch $script:Rx.Url) { return (Get-Text 'ErrUrl' $L) } }
    'urls'       { foreach ($t in (Split-List $v)) { if ($t -cnotmatch $script:Rx.Url) { return (Get-Text 'ErrAllowedSite' $t) } } }
    'reload'     { if ($v -cnotmatch '^[0-9]{1,4}$' -or [int]$v -gt 1440) { return (Get-Text 'ErrReload') } }
    'time'       { if ($v -ne '' -and $v -cnotmatch $script:Rx.Time) { return (Get-Text 'ErrTime' $L) } }
    'days'       { if ($v -cnotmatch '^[1-7 ,;]*$') { return (Get-Text 'ErrDays') } }
    'lang'       { if ($v.ToLower() -cnotmatch '^[a-z]{2}$') { return (Get-Text 'ErrLanguage') } }
    'kbd'        { if ($v -cnotmatch $script:Rx.Kbd) { return (Get-Text 'ErrKeyboard') } }
    'logo'       { if ($v -cnotmatch $script:Rx.Logo) { return (Get-Text 'ErrLogo') } }
    'color'      { if ($v -cnotmatch $script:Rx.Color) { return (Get-Text 'ErrColor' $L) } }
    'pin'        { if ($v.Length -gt 64) { return (Get-Text 'ErrPin') } }
  }
  $null
}

# the value exactly as save-config.sh stores it. Writing anything else makes the device see a difference
# against its own (normalized) copy at every read, and apply the configuration again every 5 minutes.
function ConvertTo-Canonical([string]$key, [string]$v) {
  $s = Get-Setting $key; $v = $v.Trim()
  if ($s.Type -eq 'choice') {
    # aliases accepted by the device (older files, other languages); anything else = what the device falls back to
    $l = $v.ToLower()
    if ($s.Choices -contains $l) { return $l }
    $alias = @{ NETMODE = @{ statico = 'static' }; USB_MODE = @{ dischi = 'disks' }; WEB_BUTTON = @{ portale = 'app'; portal = 'app'; chrome = 'browser'; chromium = 'browser' }
      RDP_GATEWAY_USE = @{ rileva = 'detect'; auto = 'detect' }; VPN = @{ wg = 'wireguard'; ovpn = 'openvpn' }
      DOT1X = @{ 'eap-tls' = 'tls' }; WIFI_SECURITY = @{ 'eap-tls' = 'tls' } }
    if ($key -in 'WIFI', 'SSH', 'REMOTE_SCREEN', 'SECURITY_UPDATES', 'TPM_SECRETS') { if ($l -in 'yes', 'true', '1', 'si') { return 'on' }; return 'off' }
    if ($alias.ContainsKey($key) -and $alias[$key].ContainsKey($l)) { return $alias[$key][$l] }
    return $s.Choices[0]
  }
  switch ($s.Type) {
    'names'     { return (Split-List $v) -join ' ' }
    'urls'      { return (Split-List $v) -join ' ' }
    'cidrs'     { return (Split-List $v) -join ' ' }
    'dnsnames'  { return (Split-List $v) -join ' ' }
    'eapca'     { if ($v -eq '' -or $v -ieq 'system') { return 'system' }; return $v }
    'ips'       { return (Split-List $v) -join ' ' }
    'wgkey'     { return $v -replace '\s', '' }
    'cidr'      { return $v -replace '\s', '' }
    'usb'       { return ((Split-List $v) -join ' ').ToLower() }
    'country'   { return $v.ToUpper() }
    'lang'      { return $v.ToLower() }
    'pin'       { return $v.ToLower() }
    'updateto'  { if ($v -eq '' -or $v -ieq 'latest') { return 'latest' }; return $v }
    'days'      { $d = -join (@($v.ToCharArray() | Where-Object { $_ -match '[1-7]' } | Sort-Object -Unique)); if ($d) { return $d }; return '1234567' }
    { $_ -in 'threshold', 'shutdown', 'reload' } { if ($v -cmatch '^[0-9]{1,6}$') { return [string][int]$v }; return $v }
  }
  $v
}

# cross checks on the RESULTING configuration of a device (as save-config.sh will see it)
function Test-EffectiveConfig($r, $status) {
  $e = @()
  if ($r['NETMODE'] -eq 'static') {
    if (-not (Test-Ip $r['IPADDR'])) { $e += Get-Text 'ErrStaticIp' }
    if (-not (Test-Mask $r['NETMASK'])) { $e += Get-Text 'ErrStaticMask' }
    if (-not (Test-Ip $r['GATEWAY'])) { $e += Get-Text 'ErrStaticGateway' }
    if ((Test-Ip $r['IPADDR']) -and (Test-Mask $r['NETMASK']) -and (Test-Ip $r['GATEWAY'])) {
      $m = ConvertTo-IpNumber $r['NETMASK']
      if (((ConvertTo-IpNumber $r['IPADDR']) -band $m) -ne ((ConvertTo-IpNumber $r['GATEWAY']) -band $m)) { $e += Get-Text 'ErrSubnet' $r['GATEWAY'] $r['IPADDR'] }
    }
    if (-not (Test-Ip $r['DNS1'])) { $e += Get-Text 'ErrStaticDns' }
  }
  if ($r['WEB_BUTTON'] -in 'app', 'browser' -and -not $r['WEB_URL']) { $e += Get-Text 'ErrWebNeedsUrl' $r['WEB_BUTTON'] }
  if ($r['WEB_BUTTON'] -eq 'kiosk' -and -not $r['KIOSK_URL']) { $e += Get-Text 'ErrKioskNeedsUrl' }
  if ($r['UPDATE_FROM'] -eq 'share' -and -not $r['MGMT_SHARE']) { $e += Get-Text 'ErrUpdateNeedsShare' }
  if ($r['WIFI'] -eq 'on') {
    if (-not $r['WIFI_SSID'] -or (Test-SettingValue 'WIFI_SSID' $r['WIFI_SSID'])) { $e += Get-Text 'ErrWifiNeedsSsid' }
    if ($status -and $status['WIFI_STATUS'] -eq 'no adapter') { $e += Get-Text 'ErrWifiNoAdapter' }
  }
  $e
}

function Get-WpaKey([string]$passphrase, [string]$ssid) { [OtrCrypto]::WpaPsk($passphrase, $ssid) }
function Get-PinHash([string]$pin) { [OtrCrypto]::Pin($pin) }
# what the user typed in a secret cell -> what goes to the file (MarkSaved/MarkSet = keep the previous one)
function ConvertTo-WpaKey($v, $ssid) { if ($v -cmatch $script:Rx.Hex64) { $v.ToLower() } else { Get-WpaKey $v $ssid } }
function ConvertTo-PinHash($v) { if ($v -eq '') { '' } elseif ($v -cmatch $script:Rx.Hex64 -or $v -cmatch '^pbkdf2-sha256:[0-9]{4,7}:[0-9a-f]{32}:[0-9a-f]{64}$') { $v.ToLower() } else { Get-PinHash $v } }
function Format-Value($k, $v) {
  if ($null -eq $v) { Get-Text 'ValNotManaged' }
  elseif ($k -eq 'WIFI_PSK') { Get-Text 'ValWpaKey' }
  elseif ($k -eq 'SETTINGS_PIN_SHA256') { if ($v) { Get-Text 'ValPinSet' } else { Get-Text 'ValNoPin' } }
  else { "'$v'" }
}

# ---------------------------------------------------------------------------------------------
# Reading the files
# ---------------------------------------------------------------------------------------------
function Read-Lines($f) {
  for ($i = 0; $i -lt 3; $i++) {    # the device may be rewriting the file right now
    try { $t = [IO.File]::ReadAllText($f); return @($t.TrimStart([char]0xFEFF) -split "`r?`n") } catch { Start-Sleep -Milliseconds 300 }
  }
  @()
}
# ACTIVE keys of a .conf file, as central-apply.sh reads them (last one wins, # and ; lines ignored)
function Read-ConfFile($f) {
  $h = [ordered]@{}
  if (Test-Path -LiteralPath $f) {
    foreach ($l in (Read-Lines $f)) { if ($l -cmatch '^\s*([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*$') { $h[$Matches[1]] = $Matches[2] } }
  }
  $h
}
# status\<hostname>.txt: the KEY=value lines at the top (up to the first "---" section)
function Read-StatusFile($f) {
  $h = @{}
  foreach ($l in (Read-Lines $f)) { if ($l -like '---*') { break }; if ($l -cmatch '^([A-Z][A-Z0-9_]*)=(.*)$') { $h[$Matches[1]] = $Matches[2].Trim() } }
  $h
}
# the IPv4 of a device for the actions over SSH: the one of its report, else its name in the DNS (as DHCP registers
# it), for a report without an address (IP=none); '' when neither
function Get-DeviceIp($d) {
  $ip = ([string]$d.S['IP']) -replace '/.*$', ''
  if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') { return $ip }
  try { $a = @([Net.Dns]::GetHostAddresses([string]$d.Name) | Where-Object { $_.AddressFamily -eq 'InterNetwork' }); if ($a.Count) { return $a[0].IPAddressToString } } catch { }
  ''
}
function Get-ReportTime($s) {
  # UTC when the device writes it (0.2.10 and later): its age is right whatever the time zones of device and manager
  if ($s['UPDATED_UTC'] -match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$') {
    try { return [datetime]::ParseExact($s['UPDATED_UTC'], "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal').ToLocalTime() } catch { } }
  try { [datetime]::ParseExact($s['UPDATED'], 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) } catch { $null }
}
function Format-Minutes($m) { if ($m -lt 120) { Get-Text 'DurMinutes' $m } elseif ($m -lt 2880) { Get-Text 'DurHours' ([int]($m / 60)) } else { Get-Text 'DurDays' ([int]($m / 1440)) } }

function Get-Devices {
  $list = @()
  if (-not (Test-Path -LiteralPath $script:StatusDir)) { return @() }
  # Extension check: "*.txt" alone also matches longer extensions on Windows
  foreach ($f in @(Get-ChildItem -LiteralPath $script:StatusDir -Filter '*.txt' -File -ErrorAction SilentlyContinue | Where-Object Extension -eq '.txt')) {
    $s = Read-StatusFile $f.FullName
    if (-not $s['HOSTNAME']) { continue }
    # its group: the folder its file is in, else the group the device reports (its DEVICE_GROUP or its account)
    $grp = $script:GroupFiles[$s['HOSTNAME'].ToLower()]; $grp = if ($grp) { $grp.Group } else { [string]$s['GROUP'] }
    $when = Get-ReportTime $s; if (-not $when) { $when = $f.LastWriteTime }
    $min = [int]((Get-Date) - $when).TotalMinutes
    # Kind = the colour of the state: ok, off, error, warn, info
    $state = Get-Text 'StateOk'; $kind = 'ok'
    if ($min -gt $script:StaleMinutes) { $state = Get-Text 'StateOffline' (Format-Minutes $min); $kind = 'off' }
    elseif ($s['FAILED_UNITS'] -and $s['FAILED_UNITS'] -ne 'none') { $state = Get-Text 'StateFailedUnits'; $kind = 'error' }
    elseif ($s['CENTRAL_CONFIG'] -like 'REJECTED*') { $state = Get-Text 'StateRejected'; $kind = 'warn' }
    elseif ($s['SHARE_UPDATE'] -like 'ERROR*' -or $s['SHARE_UPDATE'] -like 'IGNORED*') { $state = Get-Text 'StateUpdateError'; $kind = 'warn' }
    elseif ($s['REBOOT_REQUIRED'] -eq 'yes') { $state = Get-Text 'StateReboot'; $kind = 'info' }
    $list += [pscustomobject]@{ Name = $s['HOSTNAME']; File = $f.BaseName; State = $state; Kind = $kind; OldName = $false; Minutes = $min; When = $when; S = $s; Group = $grp }
  }
  # same MAC under two names = the old name left behind by a rename (normally the device removes it itself)
  foreach ($g in @($list | Where-Object { $_.S['MAC'] } | Group-Object { $_.S['MAC'] } | Where-Object Count -gt 1)) {
    $sorted = @($g.Group | Sort-Object When -Descending)
    $sorted | Select-Object -Skip 1 | ForEach-Object { $_.State = Get-Text 'StateOldName' $sorted[0].Name; $_.Kind = 'off'; $_.OldName = $true }
  }
  @($list | Sort-Object Name)
}

# updates\LATEST.txt, read only: the devices install only what is signed (management/publish)
function Get-PublishedUpdate {
  $f = Join-Path $script:Folder 'updates\LATEST.txt'
  if (-not (Test-Path -LiteralPath $f)) { return (Get-Text 'UpdNone') }
  $v = (Read-Lines $f | Where-Object { $_ -match '^version=' } | Select-Object -First 1) -replace '^version=', ''
  if (-not $v) { return (Get-Text 'UpdNoVersion') }
  if (Test-Path -LiteralPath "$f.sig") { "$v" } else { Get-Text 'UpdNotSigned' $v }
}

# ---------------------------------------------------------------------------------------------
# A GitHub release into updates\: the latest release (pre-releases excluded) of UPDATE_GITHUB (common.conf,
# else the project default), for the devices with UPDATE_FROM=share. Here the package hash and the project signature
# are checked (OtrVault.cs: no gpg needed), against the project key that comes with this tool
# (openthinrdp-release.asc next to it, or rootfs/opt/openthinrdp/keys in the repository). With the site key in the
# vault the release is then signed again with it: devices with UPDATE_KEY=site accept only that signature.
# ---------------------------------------------------------------------------------------------
$script:ReleaseKey = @((Join-Path $PSScriptRoot 'openthinrdp-release.asc'), (Join-Path $PSScriptRoot '..\..\rootfs\opt\openthinrdp\keys\openthinrdp-release.asc')) |
  Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$script:ReleaseFileRx = '^openthinrdp-update-[0-9A-Za-z._-]+\.tar\.gz$'
function Get-ReleaseRepo {
  # -UpdateManager without -Folder: no common.conf to read
  $r = if ($script:CommonFile) { (Read-ConfFile $script:CommonFile)['UPDATE_GITHUB'] } else { $null }
  if ($r -and $r -cmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { $r } else { (Get-Setting 'UPDATE_GITHUB').Default }
}
# one file of a release: from GitHub, or from a local folder (tests)
function Get-ReleaseFile([string]$base, [string]$name, [string]$dest) {
  if ($base -match '^https?://') { Invoke-WebRequest -UseBasicParsing -Uri "$base/$name" -OutFile $dest -TimeoutSec 300 -ErrorAction Stop }
  else { Copy-Item -LiteralPath (Join-Path $base $name) -Destination $dest -ErrorAction Stop }
}
# What changed between two versions: the notes of every release after $from up to $to, newest first, as plain text
# (the Markdown of GitHub without its marks). $json = the answer of the GitHub API already read (tests,
# OTR_MANAGER_NOTES = a file with it). '' when GitHub does not answer: the update goes on without them.
function ConvertFrom-ReleaseMarkdown([string]$md) {
  @("$md" -split "`r?`n" | ForEach-Object {
    $l = $_ -replace '\[([^\]]+)\]\([^)]+\)', '$1' -replace '\*\*', '' -replace '`', '' -replace '^#+\s*', ''
    $b = $l -match '^(\s*)[-*] (.*)$'; if ($b) { $l = "$($Matches[1])$([char]0x2022) $($Matches[2])" }
    $l -replace '(?<![\w*])\*([^*\s][^*]*)\*(?![\w*])', '$1' }) -join "`r`n" -replace '(\r\n){3,}', "`r`n`r`n" -replace '^(\r\n)+|(\r\n)+$', ''
}
function Get-ReleaseNotes([string]$from, [string]$to, $json = $null) {
  try {
    if ($null -eq $json -and $env:OTR_MANAGER_NOTES) { $json = Get-Content -LiteralPath $env:OTR_MANAGER_NOTES -Raw | ConvertFrom-Json }
    if ($null -eq $json) {
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
      $json = Invoke-RestMethod -Uri "https://api.github.com/repos/$(Get-ReleaseRepo)/releases?per_page=40" -Headers @{ 'User-Agent' = 'OpenThinRDP-Manager' } -TimeoutSec 20 -ErrorAction Stop
    }
    $sel = @(@($json) | Where-Object { -not $_.draft -and -not $_.prerelease } | ForEach-Object { [pscustomobject]@{ V = ([string]$_.tag_name) -replace '^v', ''; Body = [string]$_.body } } |
      Where-Object { $_.V -match '^\d+\.\d+' -and (-not $from -or $from -notmatch '^\d' -or (Compare-Version $_.V $from) -gt 0) -and (-not $to -or (Compare-Version $_.V $to) -le 0) })
    (@(Get-NewestFirst @($sel | ForEach-Object { [pscustomobject]@{ Version = $_.V; Body = $_.Body } }) | ForEach-Object { "$(Get-Text 'NotesVersion' $_.Version)`r`n`r`n$(ConvertFrom-ReleaseMarkdown $_.Body)" })) -join "`r`n`r`n"
  } catch { '' }
}
# The notes in a window before an update: what it is (the question), what changes (scrolling), go on or not
function Show-NotesDialog([string]$title, [string]$intro, [string]$notes, [string]$okKey) {
  $dlg = New-Object System.Windows.Forms.Form; Set-WindowIcon $dlg
  $dlg.Text = $title; $dlg.Font = $fontBase; $dlg.StartPosition = 'CenterParent'; $dlg.MinimizeBox = $false; $dlg.BackColor = $Theme.Card
  $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
  $dlg.Size = New-Object System.Drawing.Size([Math]::Min(860, $wa.Width - 24), [Math]::Min(680, $wa.Height - 24))
  $top = New-Panel 'Top' $Theme.Card 60; $top.Padding = New-Object System.Windows.Forms.Padding(18, 14, 18, 6)
  $lb = New-Label $intro $fontBase $Theme.Text; $lb.AutoSize = $false; $lb.Dock = 'Fill'; $top.Controls.Add($lb)
  $hd = New-Label (Get-Text 'NotesHeading') $fontSmallBold $Theme.Muted; $hd.AutoSize = $false; $hd.Dock = 'Top'; $hd.Height = 24; $hd.Padding = New-Object System.Windows.Forms.Padding(18, 4, 18, 0)
  $tb = New-Object System.Windows.Forms.TextBox; $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Vertical'; $tb.WordWrap = $true; $tb.Dock = 'Fill'
  $tb.Font = $fontBase; $tb.BackColor = $Theme.Page; $tb.BorderStyle = 'None'; $tb.Text = $(if ("$notes".Trim()) { $notes } else { Get-Text 'NotesNone' })
  $mid = New-Panel 'Fill' $Theme.Card; $mid.Padding = New-Object System.Windows.Forms.Padding(18, 0, 18, 8); $mid.Controls.Add($tb)
  $bottom = New-Panel 'Bottom' $Theme.Card 58; Add-Line $bottom 'Top'
  $ok = New-ActionButton $okKey 'Download' 'primary'; $no = New-ActionButton 'BtnCancel'
  $ok.DialogResult = 'OK'; $no.DialogResult = 'Cancel'; $dlg.AcceptButton = $ok; $dlg.CancelButton = $no; $bottom.Controls.AddRange(@($ok, $no))
  $bottom.add_Resize({ param($p, $e) $no.Location = New-Object System.Drawing.Point(($p.ClientSize.Width - 18 - $no.Width), 13); $ok.Location = New-Object System.Drawing.Point(($no.Left - 8 - $ok.Width), 13) })
  $top.add_Resize({ param($p, $e) $h = (Measure-Note $lb.Text ($p.ClientSize.Width - $p.Padding.Horizontal)) + $p.Padding.Vertical + 6; if ($p.Height -ne $h) { $p.Height = $h } })
  $dlg.Controls.Add($mid); $dlg.Controls.Add($hd); $dlg.Controls.Add($top); $dlg.Controls.Add($bottom)
  $dlg.add_Shown({ $tb.SelectionStart = 0; $tb.SelectionLength = 0; $ok.Focus() })
  # test: the window drawn into OTR_MANAGER_NOTES_SHOT, then closed (answer: no)
  if ($env:OTR_MANAGER_NOTES_SHOT) { $dlg.add_Shown({ $dlg.Refresh(); $bm = New-Object System.Drawing.Bitmap($dlg.Width, $dlg.Height); $dlg.DrawToBitmap($bm, (New-Object System.Drawing.Rectangle(0, 0, $dlg.Width, $dlg.Height))); $bm.Save($env:OTR_MANAGER_NOTES_SHOT); $dlg.Close() }) }
  try { $dlg.ShowDialog($form) -eq 'OK' } finally { $dlg.Dispose() }
}
# $true = good signature of a key of the key file, $false = bad, $null = not checked here (no key file)
function Test-ReleaseSignature([string]$sig, [string]$file, [string]$keyFile) {
  if (-not $keyFile -or -not (Test-Path -LiteralPath $keyFile)) { return $null }
  try { [OtrVault]::VerifyWithKeyFile([IO.File]::ReadAllBytes($keyFile), [IO.File]::ReadAllBytes($file), [IO.File]::ReadAllText($sig)) } catch { $false }
}# version order as "sort -V" on the devices: the numbers inside compare as numbers
function Compare-Version([string]$a, [string]$b) {
  $pa = @($a -split '[^0-9A-Za-z]+'); $pb = @($b -split '[^0-9A-Za-z]+')
  for ($i = 0; $i -lt [Math]::Max($pa.Count, $pb.Count); $i++) {
    $x = if ($i -lt $pa.Count) { $pa[$i] } else { '' }; $y = if ($i -lt $pb.Count) { $pb[$i] } else { '' }
    if ($x -match '^[0-9]+$' -and $y -match '^[0-9]+$') { $c = ([long]$x).CompareTo([long]$y) } else { $c = [string]::CompareOrdinal($x, $y) }
    if ($c) { return [Math]::Sign($c) }
  }
  0
}
# the index of an update package: version, package file, its SHA-256; Ok = all three in the format the devices accept.
# Manager, ManagerHash: the zip of the manager of the same release (since 0.2.0, under the same signature);
# ManagerOk = both there and named after the version
function Read-LatestFile([string]$file) {
  $l = Read-Lines $file
  $field = { param($k) ([string]($l | Where-Object { $_ -match "^$k=" } | Select-Object -First 1) -replace "^$k=", '').Trim() }
  $v = & $field 'version'; $f = & $field 'file'; $h = & $field 'sha256'; $m = & $field 'manager'; $mh = & $field 'manager_sha256'
  $ok = ($v -cmatch '^[0-9A-Za-z._-]+$' -and $f -cmatch $script:ReleaseFileRx -and $h -cmatch '^[0-9a-f]{64}$')
  [pscustomobject]@{ Version = $v; File = $f; Hash = $h; Ok = $ok; Manager = $m; ManagerHash = $mh
    ManagerOk = ($ok -and $m -ceq "openthinrdp-manager-$v.zip" -and $mh -cmatch '^[0-9a-f]{64}$') }
}
# Downloads and checks the release into a temporary folder. Ok = $false with Message, or the release:
# Version, File, Signature ($true / $null = not checked here), Dir (temporary folder for Publish-Release).
# $version: that release (tag v<version>), also older than the one published, to keep devices on it or to go back;
# without it the latest release, only when newer than the one published.
function Get-Release([string]$base = '', [string]$keyFile = $script:ReleaseKey, [string]$version = '') {
  if ($version -and ($version -cnotmatch $script:Rx.Version -or $version -ceq 'latest')) { return [pscustomobject]@{ Ok = $false; Message = (Get-Text 'ErrUpdateTo') } }
  if (-not $base) {
    $base = if ($version) { "https://github.com/$(Get-ReleaseRepo)/releases/download/v$version" } else { "https://github.com/$(Get-ReleaseRepo)/releases/latest/download" }
  }
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $tmp = Join-Path $env:TEMP "otr-release-$(Get-Random)"; New-Item -ItemType Directory $tmp | Out-Null
  $fail = { param($m) Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue; [pscustomobject]@{ Ok = $false; Message = $m } }
  try { Get-ReleaseFile $base 'LATEST.txt' "$tmp\LATEST.txt"; Get-ReleaseFile $base 'LATEST.txt.sig' "$tmp\LATEST.txt.sig" }
  catch { return (& $fail (Get-Text 'RelNotFound' $base $_.Exception.Message)) }
  $i = Read-LatestFile "$tmp\LATEST.txt"; $v = $i.Version; $f = $i.File; $h = $i.Hash
  if (-not $i.Ok) { return (& $fail (Get-Text 'RelNotValid')) }
  $sig = Test-ReleaseSignature "$tmp\LATEST.txt.sig" "$tmp\LATEST.txt" $keyFile
  if ($sig -eq $false) { return (& $fail (Get-Text 'RelBadSignature' $v)) }
  if ($version) { if ($v -cne $version) { return (& $fail (Get-Text 'RelWrongVersion' $version $v)) } }
  else {
    $cv = Get-CurrentVersion
    if ($cv -and (Compare-Version $v $cv) -le 0) { return (& $fail (Get-Text 'RelNotNewer' $v $cv)) }
  }
  try { Get-ReleaseFile $base $f "$tmp\$f" } catch { return (& $fail (Get-Text 'RelNotFound' "$base/$f" $_.Exception.Message)) }
  if ((Get-FileHash -LiteralPath "$tmp\$f" -Algorithm SHA256).Hash.ToLower() -ne $h) { return (& $fail (Get-Text 'RelBadHash' $f)) }
  [pscustomobject]@{ Ok = $true; Version = $v; File = $f; Hash = $h; Signature = $sig; Dir = $tmp; Source = $base }
}
# Copies a checked release into updates\: package first, then signature and index (a device never sees an
# index that points to a missing package). The index goes to updates\versions\<version>.txt for the devices kept on
# that version (UPDATE_TO), and to updates\LATEST.txt only when the release is newer than the one published there:
# an older release fetched to go back never moves the devices that install the newest. Removes the temporary folder.
# $siteKey (Get-VaultSigningKey): LATEST.txt is signed again with it first, only over a project signature checked
# here; the new signature replaces the project one. Returns Latest ($true = updates\LATEST.txt is this release now)
# and Previous (the version published before).
function Publish-Release($rel, $siteKey = $null) {
  try {
    if ($siteKey) {
      if ($rel.Signature -ne $true) { throw (Get-Text 'RelResignUnchecked') }
      $l = Join-Path $rel.Dir 'LATEST.txt'; $data = [IO.File]::ReadAllBytes($l)
      $sig = [OtrVault]::SignDetached($siteKey, $data, [uint32][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
      if (-not [OtrVault]::VerifyDetached($siteKey.Public, $data, $sig)) { throw (Get-Text 'SignCheckFailed') }
      [IO.File]::WriteAllText((Join-Path $rel.Dir 'LATEST.txt.sig'), $sig, [Text.Encoding]::ASCII)
    }
    $u = Get-UpdatesDir; $vd = Get-VersionsDir
    foreach ($d in $u, $vd) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }
    Copy-Item -LiteralPath (Join-Path $rel.Dir $rel.File) -Destination (Join-Path $u $rel.File) -Force -ErrorAction Stop
    if ((Get-FileHash -LiteralPath (Join-Path $u $rel.File) -Algorithm SHA256).Hash.ToLower() -ne $rel.Hash) { throw (Get-Text 'RelBadHash' $rel.File) }
    $cur = Get-CurrentVersion
    $toLatest = -not $cur -or (Compare-Version $rel.Version $cur) -gt 0
    $put = { param($dir, $name, $as)
      Copy-Item -LiteralPath (Join-Path $rel.Dir $name) -Destination (Join-Path $dir "$as.new") -Force -ErrorAction Stop
      Move-Item -LiteralPath (Join-Path $dir "$as.new") -Destination (Join-Path $dir $as) -Force -ErrorAction Stop }
    # the same bytes as LATEST.txt and its signature: a pinned device checks them as it checks LATEST.txt
    foreach ($n in 'LATEST.txt.sig', 'LATEST.txt') { & $put $vd $n ($n -replace '^LATEST', $rel.Version) }
    if ($toLatest) { foreach ($n in 'LATEST.txt.sig', 'LATEST.txt') { & $put $u $n $n } }
    Remove-OldPackages @($rel.File)
    Add-ChangeLog ("release {0} copied into updates\ from {1} (project signature {2}{3}){4}" -f $rel.Version, $rel.Source,
      $(if ($rel.Signature) { 'checked here' } else { 'not checked here: the devices check it' }), $(if ($siteKey) { ", signed again with the site key $($siteKey.Hex())" } else { '' }),
      $(if ($toLatest) { '' } else { "; only into updates\versions\, updates\LATEST.txt stays on $cur" }))
    [pscustomobject]@{ Latest = $toLatest; Previous = $cur }
  } finally { Remove-Item -LiteralPath $rel.Dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------------------------
# Versions of the fleet: UPDATE_TO in common.conf keeps every device on one version (latest = the newest), UPDATE_TO in
# <hostname>.conf one device. A pilot device has UPDATE_TO=latest of its own: it takes a new release while the others
# stay where common.conf keeps them. A device kept on a version reads updates\versions\<version>.txt (+ .sig), the
# same index as LATEST.txt of that release, and installs its package even when older than its own (to go back).
# ---------------------------------------------------------------------------------------------
function Get-UpdatesDir { Join-Path $script:Folder 'updates' }
function Get-VersionsDir { Join-Path (Get-UpdatesDir) 'versions' }
# the newest published version (updates\LATEST.txt); $null = none
function Get-CurrentVersion {
  $f = Join-Path (Get-UpdatesDir) 'LATEST.txt'
  if (Test-Path -LiteralPath $f) { $i = Read-LatestFile $f; if ($i.Ok) { return $i.Version } }
  $null
}
# newest first, in the order of Compare-Version (Sort-Object knows no version order); $property = '' for strings
function Get-NewestFirst($items, [string]$property = 'Version') {
  $out = New-Object System.Collections.ArrayList
  $key = { param($x) if ($property) { [string]$x.$property } else { [string]$x } }
  foreach ($i in @($items)) {
    if ($null -eq $i) { continue }
    $v = & $key $i; $k = 0
    while ($k -lt $out.Count -and (Compare-Version (& $key $out[$k]) $v) -ge 0) { $k++ }
    $out.Insert($k, $i)
  }
  $out
}
# the versions in updates\versions\ (newest first): Usable = signed and with its package in updates\, so a device kept
# on it can install it
function Get-PublishedVersions {
  $d = Get-VersionsDir
  if (-not $script:Folder -or -not (Test-Path -LiteralPath $d)) { return @() }
  $out = foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter '*.txt' -File -ErrorAction SilentlyContinue | Where-Object Extension -eq '.txt')) {
    $i = Read-LatestFile $f.FullName
    if (-not $i.Ok -or $i.Version -cne $f.BaseName) { continue }
    $signed = Test-Path -LiteralPath "$($f.FullName).sig"; $pkg = Test-Path -LiteralPath (Join-Path (Get-UpdatesDir) $i.File)
    [pscustomobject]@{ Version = $i.Version; File = $i.File; Signed = $signed; Package = $pkg; Usable = ($signed -and $pkg) }
  }
  Get-NewestFirst $out
}
# updates\versions\<version>.txt of the version published now, copied from updates\LATEST.txt and its signature as they
# are: a folder published before versions\ existed has none, and the devices kept on that version would find nothing.
# Returns that version; $null = no signed LATEST.txt to take it from.
function Initialize-VersionIndex {
  $u = Get-UpdatesDir; $l = Join-Path $u 'LATEST.txt'
  if (-not (Test-Path -LiteralPath $l) -or -not (Test-Path -LiteralPath "$l.sig")) { return $null }
  $i = Read-LatestFile $l; if (-not $i.Ok) { return $null }
  $vd = Get-VersionsDir; if (-not (Test-Path -LiteralPath $vd)) { New-Item -ItemType Directory -Path $vd | Out-Null }
  $t = Join-Path $vd "$($i.Version).txt"
  if (-not (Test-Path -LiteralPath $t) -or -not (Test-Path -LiteralPath "$t.sig")) {
    foreach ($n in @(@("$l.sig", "$t.sig"), @($l, $t))) {
      Copy-Item -LiteralPath $n[0] -Destination "$($n[1]).new" -Force -ErrorAction Stop
      Move-Item -LiteralPath "$($n[1]).new" -Destination $n[1] -Force -ErrorAction Stop
    }
    Add-ChangeLog "updates\versions\$($i.Version).txt created from updates\LATEST.txt"
  }
  $i.Version
}
# UPDATE_TO of the .conf files: Common = what every device installs ('latest' when common.conf has none), Hosts = the
# devices with one of their own (name -> value)
function Get-UpdatePins {
  $c = Read-ConfFile $script:CommonFile
  $common = if ($c.Contains('UPDATE_TO')) { ConvertTo-Canonical 'UPDATE_TO' $c['UPDATE_TO'] } else { 'latest' }
  $hosts = [ordered]@{}
  if (Test-Path -LiteralPath $script:ConfigDir) {
    foreach ($f in @(Get-ChildItem -LiteralPath $script:ConfigDir -Filter '*.conf' -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.conf' -and $_.BaseName -ne 'common' })) {
      $h = Read-ConfFile $f.FullName; if ($h.Contains('UPDATE_TO')) { $hosts[$f.BaseName] = ConvertTo-Canonical 'UPDATE_TO' $h['UPDATE_TO'] }
    }
  }
  [pscustomobject]@{ Common = $common; Hosts = $hosts }
}
# where the fleet stands: Latest (updates\LATEST.txt), Fleet (UPDATE_TO of common.conf), Pinned (the fleet kept on a
# version), Behind (kept on an older version than the newest), Pilots (devices with UPDATE_TO=latest of their own), Own
# (devices on a version of their own: name -> version), Pins (Get-UpdatePins)
function Get-RolloutState {
  $p = Get-UpdatePins; $latest = Get-CurrentVersion
  $pilots = @($p.Hosts.Keys | Where-Object { $p.Hosts[$_] -eq 'latest' } | Sort-Object)
  $own = [ordered]@{}; foreach ($k in @($p.Hosts.Keys | Sort-Object)) { if ($p.Hosts[$k] -ne 'latest') { $own[$k] = $p.Hosts[$k] } }
  $pinned = $p.Common -ne 'latest'
  [pscustomobject]@{ Latest = $latest; Fleet = $p.Common; Pinned = $pinned; Behind = ($pinned -and $latest -and (Compare-Version $p.Common $latest) -lt 0)
    Pilots = $pilots; Own = $own; Pins = $p }
}
# what one device installs: Kind = pilot (UPDATE_TO=latest of its own), own (a version of its own) or fleet (common.conf);
# Target = that version, or 'latest'
function Get-DeviceTrack([string]$name, $state) {
  $h = $state.Pins.Hosts
  $k = @($h.Keys | Where-Object { $_ -eq $name }) | Select-Object -First 1
  if ($k) { if ($h[$k] -eq 'latest') { return [pscustomobject]@{ Kind = 'pilot'; Target = 'latest' } }; return [pscustomobject]@{ Kind = 'own'; Target = $h[$k] } }
  [pscustomobject]@{ Kind = 'fleet'; Target = $state.Fleet }
}
# The packages in updates\: the newest 3 stay, and whatever a device may still need: the package of LATEST.txt and of
# every version a .conf file keeps devices on (UPDATE_TO). A removed package takes its index in versions\ with it: a
# version listed there can always be installed.
function Remove-OldPackages([string[]]$keep = @()) {
  $u = Get-UpdatesDir; $vd = Get-VersionsDir
  $index = @{}
  if (Test-Path -LiteralPath $vd) {
    foreach ($f in @(Get-ChildItem -LiteralPath $vd -Filter '*.txt' -File -ErrorAction SilentlyContinue | Where-Object Extension -eq '.txt')) { $index[$f.FullName] = (Read-LatestFile $f.FullName).File }
  }
  $need = @($keep)
  $l = Join-Path $u 'LATEST.txt'; if (Test-Path -LiteralPath $l) { $need += (Read-LatestFile $l).File }
  $pins = Get-UpdatePins
  foreach ($v in @(@($pins.Common) + @($pins.Hosts.Values) | Where-Object { $_ -and $_ -ne 'latest' })) {
    $need += "openthinrdp-update-$v.tar.gz"
    $x = Join-Path $vd "$v.txt"; if ($index.ContainsKey($x)) { $need += $index[$x] }
  }
  $pk = @(Get-ChildItem -LiteralPath $u -Filter 'openthinrdp-update-*.tar.gz' -File -ErrorAction SilentlyContinue |
    ForEach-Object { [pscustomobject]@{ Version = ($_.Name -replace '^openthinrdp-update-|\.tar\.gz$', ''); Item = $_ } })
  foreach ($p in @(Get-NewestFirst $pk | Select-Object -Skip 3 | Where-Object { $need -notcontains $_.Item.Name })) {
    Remove-Item -LiteralPath $p.Item.FullName -Force
    foreach ($x in @($index.Keys | Where-Object { $index[$_] -ceq $p.Item.Name })) {
      Remove-Item -LiteralPath $x, "$x.sig" -Force -ErrorAction SilentlyContinue
    }
  }
}
# a note for a save plan: a device kept on a version the folder does not have stays where it is (for the devices that
# update from the folder; from GitHub the device fetches the release itself)
function Get-UpdateToNote($value) {
  if (-not $value -or $value -eq 'latest' -or -not $script:Folder -or -not (Test-Path -LiteralPath (Get-UpdatesDir))) { return }
  if (-not @(Get-PublishedVersions | Where-Object { $_.Version -ceq $value -and $_.Usable }).Count) { Get-Text 'NoteUpdateToMissing' $value }
}
# UPDATE_TO for every device (common.conf, $dev = $null) or for one device ($value $null = its own line off: it follows
# common.conf), through the save plans as any setting: checked, the file copied to config\backup\, the change logged
function Set-UpdateTo($value, $dev = $null) {
  $m = [ordered]@{ UPDATE_TO = $value }
  $plan = if ($dev) { Get-DeviceSavePlan $dev $m } else { Get-CommonSavePlan $m $script:Devices }
  if ($plan.Errors.Count) { throw ($plan.Errors -join "`r`n") }
  if ($plan.Changes.Count) { [void](Write-ConfFile $plan.File $plan.Values $(if ($dev) { $script:HostHeader } else { $script:CommonHeader })) }
  $plan
}

# ---------------------------------------------------------------------------------------------
# The manager updates itself: openthinrdp-manager-<version>.zip of a release (management\windows without the
# launcher .exe, plus VERSION), named with its SHA-256 in the LATEST.txt the project key signs. The files of the zip
# replace these; the ones they replace go to previous\ first. Nothing else is touched: vault.otr, the .args and .script
# files of the launchers, the launcher .exe built here (build-launcher.ps1), previous\.
# ---------------------------------------------------------------------------------------------
$script:ManagerDir = $PSScriptRoot
$script:ManagerKeep = '^(vault\.otr(\..*)?|.*\.(args|script|old|exe))$'
# VERSION next to the manager = the release it came from; $null = a development copy (the repository): never updated
function Get-ManagerVersion {
  $f = Join-Path $script:ManagerDir 'VERSION'
  if (Test-Path -LiteralPath $f) { $v = ([IO.File]::ReadAllText($f)).Trim(); if ($v -cmatch $script:Rx.Version) { return $v } }
  $null
}
$script:ManagerVersion = Get-ManagerVersion
function Get-ManagerReleaseBase { if ($env:OTR_MANAGER_RELEASES) { $env:OTR_MANAGER_RELEASES } else { "https://github.com/$(Get-ReleaseRepo)/releases/latest/download" } }
# The LATEST.txt + .sig of a release, downloaded into $dir, as an offer for this manager. Status: Available (Version,
# File, Hash of the zip), UpToDate, NoManager (a release without the zip), BadSignature, NoKey (no project key here to
# check it: nothing is offered unchecked), Development (this copy has no VERSION)
function Test-ManagerOffer([string]$dir, [string]$keyFile = $script:ReleaseKey) {
  $r = { param($s, $i = $null) [pscustomobject]@{ Status = $s; Version = $(if ($i) { $i.Version }); File = $(if ($i) { $i.Manager }); Hash = $(if ($i) { $i.ManagerHash }) } }
  if (-not $script:ManagerVersion) { return (& $r 'Development') }
  if (-not $keyFile -or -not (Test-Path -LiteralPath $keyFile)) { return (& $r 'NoKey') }
  if ((Test-ReleaseSignature "$dir\LATEST.txt.sig" "$dir\LATEST.txt" $keyFile) -ne $true) { return (& $r 'BadSignature') }
  $i = Read-LatestFile "$dir\LATEST.txt"
  if (-not $i.Ok) { return (& $r 'BadSignature') }
  if ((Compare-Version $i.Version $script:ManagerVersion) -le 0) { return (& $r 'UpToDate' $i) }
  if (-not $i.ManagerOk) { return (& $r 'NoManager' $i) }
  & $r 'Available' $i
}
# the offer of the latest release (Test-ManagerOffer); throws when it cannot be downloaded
function Get-ManagerOffer([string]$base = (Get-ManagerReleaseBase), [string]$keyFile = $script:ReleaseKey) {
  if (-not $script:ManagerVersion) { return (Test-ManagerOffer '' $keyFile) }
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $tmp = Join-Path $env:TEMP "otr-manager-$(Get-Random)"; New-Item -ItemType Directory $tmp | Out-Null
  try {
    try { Get-ReleaseFile $base 'LATEST.txt' "$tmp\LATEST.txt"; Get-ReleaseFile $base 'LATEST.txt.sig' "$tmp\LATEST.txt.sig" }
    catch { throw (Get-Text 'MgrNotFound' $base $_.Exception.Message) }
    Test-ManagerOffer $tmp $keyFile
  } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
# the zip into $dest, entry by entry: an entry that would land outside $dest (.., a drive, a rooted path) stops it
function Expand-ManagerZip([string]$zip, [string]$dest) {
  Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
  $z = [IO.Compression.ZipFile]::OpenRead($zip)
  try {
    foreach ($e in $z.Entries) {
      $n = $e.FullName -replace '/', '\'
      if ($n -match '(^|\\)\.\.(\\|$)' -or $n -match ':' -or $n.StartsWith('\')) { throw (Get-Text 'MgrBadZip' $e.FullName) }
      if (-not $e.Name) { continue }     # a folder
      $t = Join-Path $dest $n; $pd = Split-Path $t
      if (-not (Test-Path -LiteralPath $pd)) { New-Item -ItemType Directory -Path $pd -Force | Out-Null }
      [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $t, $true)
    }
  } finally { $z.Dispose() }
}
# One file in place. Windows lets a file in use (a running program) be renamed but not overwritten: such a file
# becomes <name>.old, removed at the next start (Remove-OldManagerFiles).
function Install-ManagerFile([string]$src, [string]$dest) {
  $pd = Split-Path $dest; if (-not (Test-Path -LiteralPath $pd)) { New-Item -ItemType Directory -Path $pd -Force | Out-Null }
  try { Copy-Item -LiteralPath $src -Destination $dest -Force -ErrorAction Stop }
  catch {
    if (-not (Test-Path -LiteralPath $dest)) { throw }
    $old = "$dest.old"
    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $old) { $old = "$dest.$(Get-Random).old" }
    Move-Item -LiteralPath $dest -Destination $old -ErrorAction Stop
    Copy-Item -LiteralPath $src -Destination $dest -Force -ErrorAction Stop
  }
}
# *.old left by an update: removed at the next start, once nothing runs them (silent: another administrator may
# still be running one)
function Remove-OldManagerFiles {
  $prev = Join-Path $script:ManagerDir 'previous'
  Get-ChildItem -LiteralPath $script:ManagerDir -Filter '*.old' -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { -not $_.FullName.StartsWith("$prev\", [StringComparison]::OrdinalIgnoreCase) } | Remove-Item -Force -ErrorAction SilentlyContinue
}
# Downloads the zip of $offer, checks it (signed hash, OpenThinRDP-Manager.ps1 and VERSION of that version inside),
# copies the files it replaces into previous\ (the copy of the previous update goes), then puts the new ones in place.
# On any error the files of previous\ come back and the ones the zip added go. Returns Dir and LauncherChanged ($true =
# a launcher .exe is here and Launcher.cs changed: it must be built again with build-launcher.ps1).
function Update-Manager($offer, [string]$base = (Get-ManagerReleaseBase), [string]$dir = $script:ManagerDir) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  # paths as Get-ChildItem gives them back (TEMP may be in the short 8.3 form): the relative names are cut from them
  $tmp = (New-Item -ItemType Directory (Join-Path $env:TEMP "otr-manager-$(Get-Random)")).FullName
  $dir = (Get-Item -LiteralPath $dir).FullName.TrimEnd('\')
  try {
    $zip = Join-Path $tmp $offer.File
    try { Get-ReleaseFile $base $offer.File $zip } catch { throw (Get-Text 'MgrNotFound' "$base/$($offer.File)" $_.Exception.Message) }
    if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower() -ne $offer.Hash) { throw (Get-Text 'MgrBadHash' $offer.File) }
    $x = Join-Path $tmp 'x'; New-Item -ItemType Directory $x | Out-Null
    Expand-ManagerZip $zip $x
    $vf = Join-Path $x 'VERSION'
    if (-not (Test-Path -LiteralPath (Join-Path $x 'OpenThinRDP-Manager.ps1')) -or -not (Test-Path -LiteralPath $vf) -or ([IO.File]::ReadAllText($vf)).Trim() -cne $offer.Version) {
      throw (Get-Text 'MgrNotManager' $offer.Version) }
    # the copy on a share may be read-only for this account: found out before anything changes
    $probe = Join-Path $dir ".otr-write-$(Get-Random)"
    try { [IO.File]::WriteAllText($probe, ''); Remove-Item -LiteralPath $probe -Force } catch { throw (Get-Text 'MgrNotWritable' $dir) }
    $files = @(Get-ChildItem -LiteralPath $x -Recurse -File | ForEach-Object { $_.FullName.Substring($x.Length + 1) } |
      Where-Object { (Split-Path -Leaf $_) -notmatch $script:ManagerKeep -and $_ -notmatch '^previous(\\|$)' })
    $launcher = @(Get-ChildItem -LiteralPath $dir -Filter '*.exe' -File -ErrorAction SilentlyContinue).Count -gt 0
    $lc = Join-Path $dir 'Launcher.cs'; $nlc = Join-Path $x 'Launcher.cs'
    $launcherChanged = $launcher -and (Test-Path -LiteralPath $nlc) -and (-not (Test-Path -LiteralPath $lc) -or
      (Get-FileHash -LiteralPath $lc -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $nlc -Algorithm SHA256).Hash)
    $prev = Join-Path $dir 'previous'
    if (Test-Path -LiteralPath $prev) { Remove-Item -LiteralPath $prev -Recurse -Force -ErrorAction Stop }
    $prev = (New-Item -ItemType Directory $prev).FullName
    $added = @()
    try {
      foreach ($r in $files) {
        $d = Join-Path $dir $r
        if (Test-Path -LiteralPath $d) { $p = Join-Path $prev $r; $pd = Split-Path $p; if (-not (Test-Path -LiteralPath $pd)) { New-Item -ItemType Directory $pd -Force | Out-Null }
          Copy-Item -LiteralPath $d -Destination $p -ErrorAction Stop } else { $added += $r }
      }
    } catch { throw (Get-Text 'MgrBackupFailed' $_.Exception.Message) }
    try {
      foreach ($r in $files) { Install-ManagerFile (Join-Path $x $r) (Join-Path $dir $r) }
      foreach ($r in $files) {
        if ((Get-FileHash -LiteralPath (Join-Path $dir $r) -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath (Join-Path $x $r) -Algorithm SHA256).Hash) { throw (Get-Text 'MgrBadCopy' $r) }
      }
    } catch {
      $why = $_.Exception.Message; $bad = @()
      foreach ($f in @(Get-ChildItem -LiteralPath $prev -Recurse -File)) {
        $r = $f.FullName.Substring($prev.Length + 1); $d = Join-Path $dir $r
        # not replaced yet (or a file in use that could not be): nothing to put back
        if ((Test-Path -LiteralPath $d) -and (Get-FileHash -LiteralPath $d -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash) { continue }
        try { Install-ManagerFile $f.FullName $d } catch { $bad += $r }
      }
      foreach ($r in $added) { Remove-Item -LiteralPath (Join-Path $dir $r) -Force -ErrorAction SilentlyContinue }
      if ($bad.Count) { throw (Get-Text 'MgrRestoreFailed' $why ($bad -join ', ')) }
      throw (Get-Text 'MgrRestored' $why)
    }
    [pscustomobject]@{ Dir = $dir; Version = $offer.Version; LauncherChanged = $launcherChanged }
  } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------------------------
# Vault: the secrets of the administrators in vault.otr next to this tool, encrypted with an access code
# (OtrVault.cs: PBKDF2-HMAC-SHA256 600000 rounds, AES-256-CBC + HMAC-SHA256). Every administrator who starts the
# same copy of the tool opens it with the same code; without the code there is no remote screen and no signing.
#   ssh_private, ssh_public   the SSH key of the manager (remote screen; its public half in config\authorized_keys)
#   sign_*                    the OpenPGP key that signs the update packages (Ed25519, as gpg exports it)
# Open, the secrets stay in memory until the window closes. ssh.exe needs the private key in a file: a folder
# that only this account and SYSTEM can read, removed when the vault closes.
# ---------------------------------------------------------------------------------------------
$script:VaultFile = if ($env:OTR_MANAGER_VAULT) { $env:OTR_MANAGER_VAULT } else { Join-Path $PSScriptRoot 'vault.otr' }
$script:VaultKeysDir = Join-Path $env:LOCALAPPDATA 'OpenThinRDP\vault-keys'
$script:VaultMinCode = 8
$script:Vault = $null; $script:VaultCode = $null; $script:VaultKeyFile = $null
function Test-VaultFile { Test-Path -LiteralPath $script:VaultFile }
function Test-VaultOpen { $null -ne $script:Vault }
# $false = wrong code
function Open-Vault([string]$code) {
  $plain = [OtrVault]::Open($code, [IO.File]::ReadAllText($script:VaultFile))
  if ($null -eq $plain) { return $false }
  $h = @{}; ([Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
  $script:Vault = $h; $script:VaultCode = $code
  $true
}
# written next to it first, then moved over it: a vault cut in half would lose every key
function Save-Vault {
  $sealed = [OtrVault]::Seal($script:VaultCode, [Text.Encoding]::UTF8.GetBytes(($script:Vault | ConvertTo-Json -Compress)))
  $tmp = "$($script:VaultFile).new"
  [IO.File]::WriteAllText($tmp, "$sealed`r`n", [Text.Encoding]::ASCII)
  Move-Item -LiteralPath $tmp -Destination $script:VaultFile -Force
}
function New-Vault([string]$code) { $script:Vault = @{ format = 1 }; $script:VaultCode = $code; Save-Vault }
function Set-VaultCode([string]$code) { $script:VaultCode = $code; Save-Vault }
function Close-Vault { Remove-VaultKeyFile; $script:Vault = $null; $script:VaultCode = $null }
function Test-CodeStrength([string]$code) { $code.Length -ge $script:VaultMinCode }
# The access code at the start. A copy of the manager with a vault opens only with its code: the dialog comes before
# the folder and the window, so nothing of the fleet shows behind it; Cancel ends the manager. After 3 wrong codes each
# try waits longer (2, 4, 8, 16, then 30 s). Without a vault there is nothing to ask (the vault is offered later, as
# before). Returns open, none or cancel. $answers (tests, OTR_MANAGER_GATE_ANSWERS): the codes typed, in order; cancel
# or an empty one = Cancel.
$script:GateFailures = 0
function Get-GateDelay([int]$failures) { if ($failures -lt 3) { 0 } else { [int][Math]::Min(30, 2 * [Math]::Pow(2, $failures - 3)) } }
function Invoke-StartGate($answers = $null) {
  if (-not (Test-VaultFile)) { return 'none' }
  if (Test-VaultOpen) { return 'open' }
  if ($null -ne $answers) {
    foreach ($a in @($answers)) {
      if (-not $a -or $a -eq 'cancel') { return 'cancel' }
      if (Open-Vault $a) { return 'open' }
      $script:GateFailures++
    }
    return 'cancel'
  }
  if (Show-AccessGate) { 'open' } else { 'cancel' }
}

# a new folder that only this account and SYSTEM can read (ssh.exe refuses a private key others can read)
function New-PrivateDir {
  $d = Join-Path $script:VaultKeysDir ([guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $d -Force | Out-Null
  $acl = New-Object System.Security.AccessControl.DirectorySecurity
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($sid in @([System.Security.Principal.WindowsIdentity]::GetCurrent().User, (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')))) {
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
  }
  Set-Acl -LiteralPath $d -AclObject $acl
  $d
}
# the private SSH key of the vault in a file for ssh.exe -i; $null = vault closed or no key
function Get-VaultKeyFile {
  if (-not (Test-VaultOpen) -or -not $script:Vault['ssh_private']) { return $null }
  if ($script:VaultKeyFile -and (Test-Path -LiteralPath $script:VaultKeyFile)) { return $script:VaultKeyFile }
  $f = Join-Path (New-PrivateDir) 'id_manager'
  [IO.File]::WriteAllText($f, (([string]$script:Vault['ssh_private']) -replace "`r`n", "`n").TrimEnd("`n") + "`n", $script:Utf8)
  $script:VaultKeyFile = $f
  $f
}
function Remove-VaultKeyFile {
  if ($script:VaultKeyFile) { Remove-Item -LiteralPath (Split-Path $script:VaultKeyFile) -Recurse -Force -ErrorAction SilentlyContinue; $script:VaultKeyFile = $null }
  # left by a window that did not close normally
  Get-ChildItem -LiteralPath $script:VaultKeysDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
# ---- Power and commands of a device. Wake-on-LAN from here (no SSH: the device is off), to the broadcast of its own
# network as it last reported it and to 255.255.255.255; the rest over SSH as otradmin with the key of the vault.
function Get-WolPacket([string]$mac) {
  $hex = $mac -replace '[^0-9A-Fa-f]', ''; if ($hex.Length -ne 12) { return $null }
  $b = New-Object byte[] 102; for ($i = 0; $i -lt 6; $i++) { $b[$i] = 255 }
  for ($i = 0; $i -lt 16; $i++) { for ($j = 0; $j -lt 6; $j++) { $b[6 + $i * 6 + $j] = [Convert]::ToByte($hex.Substring($j * 2, 2), 16) } }
  $b
}
# 192.168.0.37/23 -> 192.168.1.255
function Get-Broadcast([string]$cidr) {
  if ($cidr -notmatch '^(\d{1,3}(\.\d{1,3}){3})/(\d{1,2})$') { return $null }
  $ip = [Net.IPAddress]::Parse($Matches[1]).GetAddressBytes(); [Array]::Reverse($ip)
  $n = [BitConverter]::ToUInt32($ip, 0); $hm = [uint32]([Math]::Pow(2, 32 - [int]$Matches[3]) - 1)
  $bb = [BitConverter]::GetBytes([uint32]($n -bor $hm)); [Array]::Reverse($bb); ([Net.IPAddress]$bb).ToString()
}
function Send-DeviceWake($d) {
  $p = Get-WolPacket ([string]$d.S['MAC']); if (-not $p) { return $false }
  $dest = @('255.255.255.255') + @(Get-Broadcast ([string]$d.S['IP']) | Where-Object { $_ })
  $u = New-Object Net.Sockets.UdpClient; $u.EnableBroadcast = $true
  try { foreach ($x in $dest) { foreach ($port in 9, 7) { [void]$u.Send($p, $p.Length, $x, $port) } } } finally { $u.Close() }
  Add-ChangeLog "$($d.Name): Wake-on-LAN sent ($($d.S['MAC']) to $($dest -join ', '))"
  $true
}
# a command on a device as otradmin with the key of the vault ($key = Get-VaultKeyFile) and no other: the keys in
# the profile of this account are not offered (IdentitiesOnly)
function Invoke-DeviceSsh([string]$ip, [string]$command, [string]$key, [string]$name) {
  $ErrorActionPreference = 'Continue'
  $out = & ssh.exe -i $key -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 @(Get-HostKeyArgs $name) "otradmin@$ip" $command 2>&1
  @{ Code = $LASTEXITCODE; Text = (@($out) -join "`n") }
}
# the same with $data on its standard input: secrets (a VPN profile with its private key, a password) never go on a
# command line, which every account of the device can read (ps) while it runs
function Invoke-DeviceSshInput([string]$ip, [string]$command, [string]$key, [string]$name, [string]$data) {
  $q = { param($a) if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a } }
  $psi = New-Object System.Diagnostics.ProcessStartInfo 'ssh.exe'
  $psi.Arguments = (@('-i', $key, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8') + @(Get-HostKeyArgs $name) + @("otradmin@$ip", $command) |
    ForEach-Object { & $q $_ }) -join ' '
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  # the input of ssh.exe in the encoding of the console: without the UTF-8 mark .NET would otherwise write first
  $ie = $null; try { $ie = [Console]::InputEncoding; [Console]::InputEncoding = $script:Utf8 } catch { }
  try { $pr = [System.Diagnostics.Process]::Start($psi) } finally { if ($ie) { try { [Console]::InputEncoding = $ie } catch { } } }
  $o = $pr.StandardOutput.ReadToEndAsync(); $e = $pr.StandardError.ReadToEndAsync()
  $b = $script:Utf8.GetBytes($data); $pr.StandardInput.BaseStream.Write($b, 0, $b.Length); $pr.StandardInput.Close()
  if (-not $pr.WaitForExit(60000)) { try { $pr.Kill() } catch { } }
  $pr.WaitForExit()
  @{ Code = $pr.ExitCode; Text = (($o.Result + "`n" + $e.Result).Trim()) }
}
# An OpenVPN profile as vpn.sh will take it ($null = good, else the reason): a client profile, and nothing in it that
# runs commands or writes files on the device
function Test-OvpnProfile([string]$text) {
  if ($text.Length -gt 262144) { return (Get-Text 'VpnErrTooBig') }
  if ($text -notmatch '(?m)^[ \t]*(remote|client)([ \t]|\r?$)') { return (Get-Text 'VpnErrNotProfile') }
  if ($text -match '(?mi)^[ \t]*(script-security|up|down|route-up|route-pre-down|ipchange|tls-verify|auth-user-pass-verify|client-connect|client-disconnect|learn-address|plugin|management|daemon|log|log-append|writepid|cd|chroot|status)([ \t]|\r?$)') {
    return (Get-Text 'VpnErrCommands' $Matches[1]) }
  $null
}
# Profile and/or user and password to one device over SSH (vpn.sh profile / auth); $null = done, else the reason
function Send-VpnFiles($d, [string]$sshKey, [string]$profileText, [string]$user, [string]$password) {
  $ip = Get-DeviceIp $d
  if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return (Get-Text 'ErrRemoteNoIp') }
  if ($d.S['CFG_SSH'] -ne 'on') { return (Get-Text 'SendKeyNoSsh') }
  $jobs = @()
  if ($profileText) { $jobs += ,@('profile', $profileText) }
  if ($user) { $jobs += ,@('auth', "$user`n$password`n") }
  foreach ($j in $jobs) {
    $r = Invoke-DeviceSshInput $ip "test -x /opt/openthinrdp/vpn.sh || { echo ERROR=old; exit 1; }; sudo /opt/openthinrdp/vpn.sh $($j[0])" $sshKey $d.Name $j[1]
    if ($r.Text -match "(?m)^OK=$($j[0])") { continue }
    if (Test-HostKeyChanged $r.Text) { return (Get-Text 'SendKeyHostChanged') }
    if ($r.Text -match '(?m)^ERROR=old') { return (Get-Text 'VpnErrOldVersion') }
    if ($r.Text -match '(?m)^ERROR=(.+)$') { return $Matches[1] }
    $x = $r.Text.Trim(); if ($x) { return $x } else { return "ssh $($r.Code)" }
  }
  $null
}
# The 802.1X client certificate of a device as dot1x.sh client takes it: a PKCS#12 file (.pfx/.p12, as Windows and
# AD CS export it) sent whole, or a PEM certificate with its PEM key (in the same file or in a second one), with the
# password of the file or of the key. Checked here as far as .NET Framework can (the password of a .pfx, its key,
# the dates, the use of the certificate); the device checks again with openssl, also that a PEM key belongs to the
# certificate, and keeps the key decrypted as a secret. Result: Data (what goes on standard input), Subject,
# NotAfter, Warning (a certificate not meant for client authentication), or Error.
function Read-Dot1xClient([string]$certFile, [string]$keyFile, [string]$password) {
  $res = [pscustomobject]@{ Data = $null; Subject = ''; NotAfter = $null; Warning = $null; Error = $null }
  if ($password -match '[\r\n]') { $res.Error = Get-Text 'Dot1xErrPasswordLine'; return $res }
  try { $bytes = [IO.File]::ReadAllBytes($certFile) } catch { $res.Error = $_.Exception.Message; return $res }
  if ($bytes.Length -gt 196608) { $res.Error = Get-Text 'Dot1xErrTooBig'; return $res }
  $text = [Text.Encoding]::ASCII.GetString($bytes)
  if ($text -notmatch '-----BEGIN CERTIFICATE-----') {
    # PKCS#12: opened here only to check the password, the key and the dates; the key stays in memory only
    # (EphemeralKeySet, .NET Framework 4.7.2 and later: no copy in the key store of this account)
    $X2 = [Security.Cryptography.X509Certificates.X509Certificate2]
    $c = $null
    try {
      try { $c = $X2::new($bytes, $password, [Security.Cryptography.X509Certificates.X509KeyStorageFlags]32) }
      catch [ArgumentException] { $c = $X2::new($bytes, $password) }    # an older .NET without EphemeralKeySet
    } catch {
      $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
      $res.Error = Get-Text 'Dot1xErrPfx' $e.Message.Trim(); return $res
    }
    try {
      if (-not $c.HasPrivateKey) { $res.Error = Get-Text 'Dot1xErrPfxNoKey'; return $res }
      $res.Subject = $c.Subject; $res.NotAfter = $c.NotAfter
      $res.Warning = Get-Dot1xEkuWarning $c
    } finally { $c.Reset() }
    $res.Data = "PASSWORD=$password`nPKCS12=$([Convert]::ToBase64String($bytes))`n"
  } else {
    $certs = @([regex]::Matches($text, '-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----') | ForEach-Object { $_.Value })
    $keyText = $text
    if ($keyFile) { try { $keyText = [IO.File]::ReadAllText($keyFile) } catch { $res.Error = $_.Exception.Message; return $res } }
    $key = [regex]::Match($keyText, '-----BEGIN ([A-Z ]*)PRIVATE KEY-----[\s\S]+?-----END \1PRIVATE KEY-----')
    if (-not $key.Success) { $res.Error = Get-Text 'Dot1xErrNoKey'; return $res }
    if (($key.Value -match 'ENCRYPTED') -and -not $password) { $res.Error = Get-Text 'Dot1xErrKeyPassword'; return $res }
    try {
      $der = [Convert]::FromBase64String(($certs[0] -replace '-----[A-Z ]+-----', '' -replace '\s', ''))
      $c = [Security.Cryptography.X509Certificates.X509Certificate2]::new($der)
    } catch { $res.Error = Get-Text 'Dot1xErrNoCert'; return $res }
    $res.Subject = $c.Subject; $res.NotAfter = $c.NotAfter; $res.Warning = Get-Dot1xEkuWarning $c; $c.Reset()
    $res.Data = "PASSWORD=$password`n" + (($certs + @($key.Value)) -join "`n") + "`n"
  }
  if ($res.NotAfter -lt (Get-Date)) { $res.Error = Get-Text 'Dot1xErrExpired' $res.NotAfter; $res.Data = $null }
  $res
}
# a certificate with an extended key usage that does not include client authentication (1.3.6.1.5.5.7.3.2)
function Get-Dot1xEkuWarning($c) {
  $eku = $c.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' } | Select-Object -First 1
  if (-not $eku) { return $null }
  $u = @(([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]$eku).EnhancedKeyUsages | ForEach-Object { $_.Value })
  if ($u -contains '1.3.6.1.5.5.7.3.2' -or $u -contains '2.5.29.37.0') { return $null }
  Get-Text 'Dot1xWarnEku'
}
# Client certificate and/or PEAP password to one device over SSH (dot1x.sh client / password); $null = done, else why
function Send-Dot1xFiles($d, [string]$sshKey, [string]$clientData, [string]$eapPassword) {
  $ip = Get-DeviceIp $d
  if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return (Get-Text 'ErrRemoteNoIp') }
  if ($d.S['CFG_SSH'] -ne 'on') { return (Get-Text 'SendKeyNoSsh') }
  $jobs = @()
  if ($clientData) { $jobs += ,@('client', $clientData) }
  if ($eapPassword) { $jobs += ,@('password', "$eapPassword`n") }
  foreach ($j in $jobs) {
    $r = Invoke-DeviceSshInput $ip "test -x /opt/openthinrdp/dot1x.sh || { echo ERROR=old; exit 1; }; sudo /opt/openthinrdp/dot1x.sh $($j[0])" $sshKey $d.Name $j[1]
    if ($r.Text -match "(?m)^OK=$($j[0])") { continue }
    if (Test-HostKeyChanged $r.Text) { return (Get-Text 'SendKeyHostChanged') }
    if ($r.Text -match '(?m)^ERROR=old') { return (Get-Text 'Dot1xErrOldVersion') }
    if ($r.Text -match '(?m)^ERROR=(.+)$') { return $Matches[1] }
    $x = $r.Text.Trim(); if ($x) { return $x } else { return "ssh $($r.Code)" }
  }
  $null
}
# The SSH host keys of the devices are kept by device NAME (HostKeyAlias), in a file of this tool: DHCP may give a
# device the address another device had, and a key stored by address would then belong to the wrong one.
$script:KnownHosts = Join-Path $env:LOCALAPPDATA 'OpenThinRDP\known_hosts'
function Get-HostKeyArgs([string]$name) {
  if (-not (Test-Path -LiteralPath $script:KnownHosts)) {
    New-Item -ItemType Directory -Path (Split-Path $script:KnownHosts) -Force | Out-Null
    [IO.File]::WriteAllText($script:KnownHosts, '')
  }
  # ssh reads the value of UserKnownHostsFile as a list split at spaces: the short 8.3 form of a path with spaces
  $f = $script:KnownHosts
  if ($f -match ' ') { $f = (New-Object -ComObject Scripting.FileSystemObject).GetFile($f).ShortPath }
  @('-o', "UserKnownHostsFile=$($f -replace '\\', '/')", '-o', "HostKeyAlias=otr-$($name.ToLower())", '-o', 'StrictHostKeyChecking=accept-new')
}
# the device answered with another host key than the one known for its name (reinstalled, or not the same device)
function Test-HostKeyChanged([string]$text) { $text -match 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed' }
function Remove-HostKey([string]$name) {
  $ErrorActionPreference = 'Continue'
  & ssh-keygen.exe -R "otr-$($name.ToLower())" -f $script:KnownHosts 2>&1 | Out-Null
}
# the public half of a private key file, from ssh-keygen -y: fails on a key protected by a passphrase (ssh.exe could
# not use it without asking) and on anything that is not a private key
function Get-SshPublicOf([string]$keyFile) {
  $kg = (Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue).Source
  if (-not $kg) { throw (Get-Text 'ErrRemoteNoSshExe') }
  $ErrorActionPreference = 'Continue'
  $out = & $kg -y -P '' -f $keyFile 2>$null
  @($out) | Where-Object { "$_" -cmatch $script:Rx.SshKey } | Select-Object -First 1
}
# a new SSH key for the manager, made by ssh-keygen in a private folder and kept only in the vault
function New-VaultSshKey {
  $kg = (Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue).Source
  if (-not $kg) { throw (Get-Text 'ErrRemoteNoSshExe') }
  $d = New-PrivateDir; $f = Join-Path $d 'new'
  try {
    $p = Start-Process $kg -ArgumentList "-q -t ed25519 -N `"`" -C openthinrdp-manager -f `"$f`"" -WindowStyle Hidden -Wait -PassThru
    if ($p.ExitCode -ne 0 -or -not (Test-Path -LiteralPath "$f.pub")) { throw (Get-Text 'KeyCreateFailed' $p.ExitCode) }
    $script:Vault['ssh_private'] = [IO.File]::ReadAllText($f); $script:Vault['ssh_public'] = ([IO.File]::ReadAllText("$f.pub")).Trim()
  } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
  Remove-VaultKeyFile; Save-Vault
  $script:Vault['ssh_public']
}
# an existing private key (e.g. the one an administrator used so far), copied into the vault
function Import-VaultSshKey([string]$file) {
  $d = New-PrivateDir; $f = Join-Path $d 'import'
  try {
    Copy-Item -LiteralPath $file -Destination $f
    $pub = Get-SshPublicOf $f
    if (-not $pub) { throw (Get-Text 'VaultSshNotUsable' $file) }
    $script:Vault['ssh_private'] = [IO.File]::ReadAllText($f); $script:Vault['ssh_public'] = "$pub".Trim()
  } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
  Remove-VaultKeyFile; Save-Vault
  $script:Vault['ssh_public']
}
# the key that signs: the file of gpg --export-secret-keys (armored or binary, without a passphrase)
function Import-VaultSigningKey([string]$file) {
  $k = [OtrVault]::ReadSecretKey([IO.File]::ReadAllBytes($file))
  $script:Vault['sign_seed'] = [OtrVault]::ToHex($k.Seed); $script:Vault['sign_public'] = [OtrVault]::ToHex($k.Public)
  $script:Vault['sign_fingerprint'] = $k.Hex(); $script:Vault['sign_created'] = [long]$k.Created; $script:Vault['sign_user'] = [string]$k.User
  Save-Vault
  $k
}
# a new key of the site, made here (random, Ed25519) and kept only in the vault; its public half is Export-VaultPublicKey
function New-VaultSiteKey([string]$user) {
  $k = [OtrVault]::NewSigningKey($user, [uint32][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
  $script:Vault['sign_seed'] = [OtrVault]::ToHex($k.Seed); $script:Vault['sign_public'] = [OtrVault]::ToHex($k.Public)
  $script:Vault['sign_fingerprint'] = $k.Hex(); $script:Vault['sign_created'] = [long]$k.Created; $script:Vault['sign_user'] = $user
  Save-Vault
  $k
}
# update-key.asc for the devices: the public key with its self-signature (the same file every time)
function Export-VaultPublicKey([string]$file) {
  $k = Get-VaultSigningKey; if (-not $k) { throw (Get-Text 'VaultNoSigningKey') }
  [IO.File]::WriteAllText($file, [OtrVault]::ExportPublic($k), [Text.Encoding]::ASCII)
  $k
}
# The public site key to one device over SSH (the key of the vault), checked and installed there by site-key.sh:
# the first time it cannot come through the folder (whoever may write there would choose the key) nor, outside
# the project, signed by the project key. $null = done, else the reason.
function Send-SiteKey($d, [string]$sshKey, [string]$armored) {
  $ip = Get-DeviceIp $d
  if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return (Get-Text 'ErrRemoteNoIp') }
  if ($d.S['CFG_SSH'] -ne 'on') { return (Get-Text 'SendKeyNoSsh') }
  $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($armored))
  $r = Invoke-DeviceSsh $ip "test -x /opt/openthinrdp/site-key.sh || { echo ERROR=old; exit 1; }; echo $b64 | base64 -d | sudo /opt/openthinrdp/site-key.sh install" $sshKey $d.Name
  if ($r.Text -match '(?m)^OK=([0-9A-F]{40})') { return $null }
  if (Test-HostKeyChanged $r.Text) { return (Get-Text 'SendKeyHostChanged') }
  if ($r.Text -match '(?m)^ERROR=old') { return (Get-Text 'SendKeyOldVersion') }
  if ($r.Text -match '(?m)^ERROR=(.+)$') { return $Matches[1] }
  $t = $r.Text.Trim(); if ($t) { $t } else { "ssh $($r.Code)" }
}
# the key that signs the releases again before they go into updates\: the site key of the vault (not the project key,
# whose signature the release already has); $null = vault closed or no site key
function Get-ResignKey {
  $k = Get-VaultSigningKey
  if ($k -and (Get-SigningKeyRole $k.Hex()) -eq 'own') { $k } else { $null }
}
function Get-VaultSigningKey {
  if (-not (Test-VaultOpen) -or -not $script:Vault['sign_seed']) { return $null }
  $k = New-Object 'OtrVault+SigningKey'
  $k.Seed = [OtrVault]::FromHex($script:Vault['sign_seed']); $k.Public = [OtrVault]::FromHex($script:Vault['sign_public'])
  $k.Fingerprint = [OtrVault]::FromHex($script:Vault['sign_fingerprint']); $k.Created = [uint32]$script:Vault['sign_created']; $k.User = $script:Vault['sign_user']
  $k
}
# project = the key of the GitHub releases (rootfs/opt/openthinrdp/keys next to this tool), own = any other: the
# devices accept it only as update-key.asc of their image
function Get-SigningKeyRole([string]$fingerprint) {
  try { if ((Test-Path -LiteralPath $script:ReleaseKey) -and ([OtrVault]::Fingerprints([IO.File]::ReadAllBytes($script:ReleaseKey)) -contains $fingerprint)) { return 'project' } } catch { }
  'own'
}
# Signs the LATEST.txt of an update package (make-update.sh without -k): its format is checked, and the package
# next to it against its hash when it is there; the signature is checked again before LATEST.txt.sig is written.
function Invoke-SignUpdate([string]$file) {
  $k = Get-VaultSigningKey
  if (-not $k) { throw (Get-Text 'VaultNoSigningKey') }
  $i = Read-LatestFile $file
  if (-not $i.Ok) { throw (Get-Text 'SignNotValid' $file) }
  $pkg = Join-Path (Split-Path -LiteralPath $file) $i.File
  $has = Test-Path -LiteralPath $pkg
  if ($has -and (Get-FileHash -LiteralPath $pkg -Algorithm SHA256).Hash.ToLower() -ne $i.Hash) { throw (Get-Text 'SignBadHash' $i.File) }
  $data = [IO.File]::ReadAllBytes($file)
  $sig = [OtrVault]::SignDetached($k, $data, [uint32][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
  if (-not [OtrVault]::VerifyDetached($k.Public, $data, $sig)) { throw (Get-Text 'SignCheckFailed') }
  [IO.File]::WriteAllText("$file.sig", $sig, [Text.Encoding]::ASCII)
  [pscustomobject]@{ Version = $i.Version; Fingerprint = $k.Hex(); Role = (Get-SigningKeyRole $k.Hex()); PackageChecked = $has; Signature = "$file.sig" }
}

# ---------------------------------------------------------------------------------------------
# Writing the .conf files: replaces the existing lines (also commented ones) and keeps the comments
#   $managed = KEY -> value (active line) or $null (commented line: not managed from here)
#   $renameMac = MAC of a device being renamed ('' = remove the mark, $null = leave it as it is)
# ---------------------------------------------------------------------------------------------
$script:RenameRx = '^#\s*rename-mac:\s*([0-9A-Fa-f:]{17})'
function Write-ConfFile($f, $managed, [string[]]$header, $renameMac = $null) {
  if (-not (Test-Path -LiteralPath $script:ConfigDir)) { New-Item -ItemType Directory -Path $script:ConfigDir | Out-Null }
  $lines = New-Object System.Collections.Generic.List[string]
  if (Test-Path -LiteralPath $f) { foreach ($l in (Read-Lines $f)) { $lines.Add($l) } } else { foreach ($l in $header) { $lines.Add($l) } }
  while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
  $before = Read-ConfFile $f
  $added = @()
  foreach ($k in @($managed.Keys)) {
    $v = $managed[$k]
    $idx = @(); for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -cmatch "^\s*#?\s*$k\s*=") { $idx += $i } }
    $active = @($idx | Where-Object { $lines[$_] -notmatch '^\s*#' })
    if ($null -ne $v) {
      $at = if ($active.Count) { $active[0] } elseif ($idx.Count) { $idx[0] } else { -1 }
      if ($at -ge 0) { $lines[$at] = "$k=$v" } else { $added += "$k=$v" }
      foreach ($i in ($active | Where-Object { $_ -ne $at } | Sort-Object -Descending)) { $lines.RemoveAt($i) }
    } else {
      foreach ($i in $active) { $lines[$i] = '#' + $lines[$i].Trim() }
    }
  }
  if ($added.Count) { $lines.Add(''); $lines.Add("# added by the OpenThinRDP manager on $(Get-Date -Format 'yyyy-MM-dd HH:mm')"); foreach ($a in $added) { $lines.Add($a) } }
  # the MAC mark lets the rename completion recognize the device: the device deletes its status files
  # under the old name, so the old status cannot be compared any more
  if ($null -ne $renameMac) {
    for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match $script:RenameRx) { $lines.RemoveAt($i) } }
    if ($renameMac) { $lines.Add("# rename-mac: $renameMac   (rename pending: identifies the device under its new name)") }
  }
  # backup copy and change log
  if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination (Get-BackupPath $f) }
  [IO.File]::WriteAllText($f, (($lines -join "`r`n") + "`r`n"), $script:Utf8)
  $after = Read-ConfFile $f
  $diff = @()
  foreach ($k in (@($before.Keys) + @($after.Keys) | Select-Object -Unique)) {
    $a = if ($before.Contains($k)) { $before[$k] } else { '(not managed)' }
    $b = if ($after.Contains($k)) { $after[$k] } else { '(not managed)' }
    if ($a -cne $b) {
      if ($k -in 'WIFI_PSK', 'SETTINGS_PIN_SHA256') { $a = $a -replace '^([0-9a-f]{64}|pbkdf2-sha256:.*)$', '(hash)'; $b = $b -replace '^([0-9a-f]{64}|pbkdf2-sha256:.*)$', '(new hash)' }
      $diff += "$k`: $a -> $b"
    }
  }
  if ($diff.Count) { Add-ChangeLog ("{0}: {1}" -f [IO.Path]::GetFileName($f), ($diff -join '; ')) }
  $diff
}
# config\backup\<name>-<time><ext>; a second save within the same second gets -2, -3... instead of
# overwriting the first copy
function Get-BackupPath($file) {
  if (-not (Test-Path -LiteralPath $script:BackupDir)) { New-Item -ItemType Directory -Path $script:BackupDir | Out-Null }
  $base = Join-Path $script:BackupDir ("{0}-{1:yyyyMMdd-HHmmss}" -f [IO.Path]::GetFileNameWithoutExtension($file), (Get-Date))
  $ext = [IO.Path]::GetExtension($file); $p = "$base$ext"; $n = 1
  while (Test-Path -LiteralPath $p) { $n++; $p = "$base-$n$ext" }
  $p
}
function Add-ChangeLog($text) {
  $line = "{0:yyyy-MM-dd HH:mm:ss} {1} {2}" -f (Get-Date), $env:USERNAME, $text
  [IO.File]::AppendAllText($script:ChangeLog, $line + "`r`n", $script:Utf8)
}
$script:HostHeader = @(
  '# Exceptions for ONE device (written by the OpenThinRDP manager).',
  '# They win over common.conf. Lines starting with # are not managed from here (common.conf or the device decide).',
  '')
$script:CommonHeader = @(
  '# Settings for EVERY device (written by the OpenThinRDP manager).',
  '# An active key wins over the settings dialog of each device. Lines starting with # are not managed from here.',
  '')

# ---------------------------------------------------------------------------------------------
# Save plans: checks and final values, without the window (the window only asks and shows)
# ---------------------------------------------------------------------------------------------
# configuration of a device after the save: what it reports now + common.conf + its own file
function Get-EffectiveConfig($status, $common, $hostConf) {
  $r = @{}
  foreach ($s in $script:Settings) {
    $k = $s.Key; if ($k -eq 'WIFI_PSK') { continue }
    $r[$k] = if ($k -eq 'HOSTNAME') { $status['HOSTNAME'] } else { $status["CFG_$k"] }
    if (-not $s.HostOnly -and $common.Contains($k) -and $null -ne $common[$k]) { $r[$k] = ConvertTo-Canonical $k $common[$k] }
    if ($hostConf.Contains($k) -and $null -ne $hostConf[$k]) { $r[$k] = ConvertTo-Canonical $k $hostConf[$k] }
  }
  $r
}

function Get-DeviceSavePlan($dev, $managed) {
  $err = @(); $notes = @()
  foreach ($k in @($managed.Keys)) { if ($null -ne $managed[$k]) { $e = Test-SettingValue $k $managed[$k]; if ($e) { $err += $e } } }
  $common = Read-ConfFile $script:CommonFile
  $hostVals = @{}; foreach ($k in @($managed.Keys)) { if ($null -ne $managed[$k] -and $k -ne 'WIFI_PSK') { $hostVals[$k] = $managed[$k] } }
  if (-not $err.Count) { $r = Get-EffectiveConfig $dev.S $common $hostVals; $err += @(Test-EffectiveConfig $r $dev.S) }
  $f = Get-HostFile $dev.Name
  $before = Read-ConfFile $f
  $final = [ordered]@{}
  foreach ($k in @($managed.Keys)) {
    $v = $managed[$k]
    if ($null -eq $v) { $final[$k] = $null }
    elseif ($k -eq 'WIFI_PSK') {
      # the WPA key depends on the SSID: computed here for the network the device will use
      $ssid = if ($err.Count) { $null } else { $r['WIFI_SSID'] }
      if ($err.Count) { }
      elseif (-not $ssid) { $err += Get-Text 'ErrPskNeedsSsid' }
      elseif ($v -eq $script:MarkSaved) {
        # the saved key was computed for the SSID in force when it was written: this file, else common.conf,
        # else the device's own
        $oldSsid = if ($before.Contains('WIFI_SSID')) { $before['WIFI_SSID'] } elseif ($common.Contains('WIFI_SSID')) { $common['WIFI_SSID'] } else { $dev.S['CFG_WIFI_SSID'] }
        if (-not $before['WIFI_PSK']) { $err += Get-Text 'ErrPskNoKeyDevice' }
        elseif ($oldSsid -cne $ssid) { $err += Get-Text 'ErrPskOtherNetwork' $oldSsid }
        else { $final[$k] = $before['WIFI_PSK'] }
      } else { $final[$k] = ConvertTo-WpaKey $v $ssid }
    }
    elseif ($k -eq 'SETTINGS_PIN_SHA256') {
      if ($v -eq $script:MarkSet) { if ($before.Contains($k)) { $final[$k] = $before[$k] } else { $err += Get-Text 'ErrPinNoneDevice' } }
      else { $final[$k] = ConvertTo-PinHash $v }
    }
    else { $final[$k] = ConvertTo-Canonical $k $v }
  }
  $changes = @(); foreach ($k in @($final.Keys)) {
    $a = if ($before.Contains($k)) { $before[$k] } else { $null }
    if ($a -cne $final[$k]) { $changes += "$((Get-Setting $k).Label): $(Format-Value $k $a) -> $(Format-Value $k $final[$k])" }
  }
  $mac = ''
  if ($null -ne $final['HOSTNAME'] -and $final['HOSTNAME'] -ne $dev.Name) {
    $mac = [string]$dev.S['MAC']
    $notes += Get-Text 'NoteRename' $final['HOSTNAME']
  }
  if ($null -ne $final['NETMODE'] -or $null -ne $final['IPADDR']) { $notes += Get-Text 'NoteNetwork' }
  $notes += @(Get-UpdateToNote $final['UPDATE_TO'])
  if (-not $err.Count) { $notes += @(Get-EapNotes $r $before $final) }
  [pscustomobject]@{ File = $f; Errors = $err; Values = $final; Changes = $changes; Notes = $notes; RenameMac = $mac }
}

function Get-CommonSavePlan($managed, $devices) {
  $err = @(); $warn = @(); $notes = @()
  foreach ($k in @($managed.Keys)) {
    if ($script:HostOnly -contains $k -and $null -ne $managed[$k]) { $err += Get-Text 'ErrHostOnlyInCommon' $k; continue }
    if ($null -ne $managed[$k]) { $e = Test-SettingValue $k $managed[$k]; if ($e) { $err += $e } }
  }
  $before = Read-ConfFile $script:CommonFile
  $final = [ordered]@{}
  foreach ($k in @($managed.Keys)) {
    $v = $managed[$k]
    if ($null -eq $v) { $final[$k] = $null }
    elseif ($k -eq 'WIFI_PSK') {
      # every device computes nothing: the key in common.conf is valid only for the SSID managed here too
      $ssid = $managed['WIFI_SSID']
      if (-not $ssid) { $err += Get-Text 'ErrPskNeedsSsidCommon' }
      elseif ($v -eq $script:MarkSaved) {
        if (-not $before['WIFI_PSK']) { $err += Get-Text 'ErrPskNoKeyCommon' }
        elseif ($before['WIFI_SSID'] -cne $ssid) { $err += Get-Text 'ErrPskOtherNetwork' $before['WIFI_SSID'] }
        else { $final[$k] = $before['WIFI_PSK'] }
      } else { $final[$k] = ConvertTo-WpaKey $v $ssid }
    }
    elseif ($k -eq 'SETTINGS_PIN_SHA256') {
      if ($v -eq $script:MarkSet) { if ($before.Contains($k)) { $final[$k] = $before[$k] } else { $err += Get-Text 'ErrPinNoneCommon' } }
      else { $final[$k] = ConvertTo-PinHash $v }
    }
    else { $final[$k] = ConvertTo-Canonical $k $v }
  }
  # combinations that every device would reject, whatever it has of its own
  if ($final['WEB_BUTTON'] -in 'app', 'browser' -and $final['WEB_URL'] -eq '') { $err += Get-Text 'ErrWebEmptyAll' $final['WEB_BUTTON'] }
  if ($final['WEB_BUTTON'] -eq 'kiosk' -and $final['KIOSK_URL'] -eq '') { $err += Get-Text 'ErrKioskEmptyAll' }
  if ($final['WIFI'] -eq 'on' -and $final['WIFI_SSID'] -eq '') { $err += Get-Text 'ErrWifiEmptyAll' }
  if ($final['UPDATE_FROM'] -eq 'share' -and $final['MGMT_SHARE'] -eq '') { $err += Get-Text 'ErrUpdateNeedsShare' }
  if (-not $err.Count) {
    # each known device as it will be: a device that rejects keeps its previous configuration (all of it)
    $commonVals = @{}; foreach ($k in @($final.Keys)) { if ($null -ne $final[$k]) { $commonVals[$k] = $final[$k] } }
    foreach ($d in @($devices | Where-Object { -not $_.OldName })) {
      $hc = Read-ConfFile (Get-HostFile $d.Name)
      foreach ($e in @(Test-EffectiveConfig (Get-EffectiveConfig $d.S $commonVals $hc) $d.S)) { $warn += "$($d.Name): $e" }
      # a key of its own computed with the SSID of common.conf goes wrong when that SSID changes
      if ($hc.Contains('WIFI_PSK') -and -not $hc.Contains('WIFI_SSID') -and $null -ne $final['WIFI_SSID'] -and $final['WIFI_SSID'] -cne $before['WIFI_SSID']) {
        $warn += Get-Text 'WarnOwnWifiKey' $d.Name $before['WIFI_SSID']
      }
    }
  }
  $changes = @(); foreach ($k in @($final.Keys)) {
    $a = if ($before.Contains($k)) { $before[$k] } else { $null }
    if ($a -cne $final[$k]) { $changes += "$((Get-Setting $k).Label): $(Format-Value $k $a) -> $(Format-Value $k $final[$k])" }
  }
  $risky = @($final.Keys | Where-Object { $_ -in 'BROKER', 'DOMAIN', 'LOAD_BALANCE_INFO', 'MGMT_SHARE', 'NETMASK', 'GATEWAY', 'DNS1', 'WIFI', 'SSH', 'SETTINGS_PIN_SHA256',
               'DOT1X', 'WIFI_SECURITY', 'EAP_IDENTITY', 'EAP_CA', 'EAP_SERVER_NAME' } |
             Where-Object { $(if ($before.Contains($_)) { $before[$_] } else { $null }) -cne $final[$_] })
  if ($risky.Count) { $notes += Get-Text 'NoteRisky' ($risky -join ', ') }
  $notes += @(Get-UpdateToNote $final['UPDATE_TO'])
  if (-not $err.Count) { $notes += @(Get-EapNotes $final $before $final) }
  [pscustomobject]@{ File = $script:CommonFile; Errors = $err; Warnings = $warn; Values = $final; Changes = $changes; Notes = $notes }
}

# keys in a .conf that the devices ignore: unknown, or device-only keys in common.conf. MGMT_PASSWORD and EAP_PASSWORD
# are used by the devices although this tool does not edit them (a password is written in the file by hand, set on the
# device, or for 802.1X sent over SSH with 802.1X...)
function Get-IgnoredKeys($conf, [switch]$Common) {
  @($conf.Keys | Where-Object { (-not (Get-Setting $_) -and $_ -notin 'MGMT_PASSWORD', 'EAP_PASSWORD') -or ($Common -and $script:HostOnly -contains $_) })
}
# What to remember when a save changes the 802.1X settings ($r: the configuration as the device will have it, as far as
# known): the server not checked by name, and where the password or the certificate come from
function Get-EapNotes($r, $before, $final) {
  $keys = 'DOT1X', 'WIFI', 'WIFI_SECURITY', 'EAP_IDENTITY', 'EAP_ANONYMOUS', 'EAP_CA', 'EAP_SERVER_NAME'
  $changed = @($final.Keys | Where-Object { $_ -in $keys } | Where-Object { $(if ($before.Contains($_)) { $before[$_] } else { $null }) -cne $final[$_] })
  if (-not $changed.Count) { return @() }
  $modes = @(@($r['DOT1X']) + @($(if ($r['WIFI'] -eq 'on') { $r['WIFI_SECURITY'] })) | Where-Object { $_ -in 'peap', 'tls' } | Select-Object -Unique)
  if (-not $modes.Count) { return @() }
  $n = @()
  if (-not $r['EAP_SERVER_NAME']) { $n += Get-Text 'NoteEapNoServer' }
  if ($modes -contains 'peap') { $n += Get-Text 'NoteEapPeap' }
  if ($modes -contains 'tls') { $n += Get-Text 'NoteEapTls' }
  $n
}

# ---------------------------------------------------------------------------------------------
# A .conf as text (#82): the file as it is, comments included, checked by the same save plans as the pages and
# normalized by them on save. Secrets never show: the WPA key and the PIN as their marks (the plans keep the saved
# ones), the passwords as ******** (put back on save; anything else typed there is the new password).
# ---------------------------------------------------------------------------------------------
$script:TextPwRx = '^(\s*)(MGMT_PASSWORD|EAP_PASSWORD)(\s*=\s*)(.*?)\s*$'
$script:TextMask = '********'
function ConvertTo-MaskedConf([string[]]$lines) {
  foreach ($l in $lines) {
    if ($l -cmatch '^\s*WIFI_PSK\s*=\s*\S') { "WIFI_PSK=$($script:MarkSaved)" }
    elseif ($l -cmatch '^\s*SETTINGS_PIN_SHA256\s*=\s*\S') { "SETTINGS_PIN_SHA256=$($script:MarkSet)" }
    elseif ($l -cmatch $script:TextPwRx -and $Matches[4]) { "$($Matches[1])$($Matches[2])$($Matches[3])$($script:TextMask)" }
    else { $l }
  }
}
# $dev = $null: common.conf. Returns the plan of the page (Errors, Warnings, Notes, Changes) plus the Lines to write.
function Get-ConfTextPlan($dev, [string]$text) {
  $f = if ($dev) { Get-HostFile $dev.Name } else { $script:CommonFile }
  $before = Read-ConfFile $f
  $lines = [System.Collections.Generic.List[string]]@($text.TrimEnd() -split "`r?`n")
  $err = @(); $warn = @(); $extra = @()
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if ($l -cmatch $script:TextPwRx -and $Matches[4] -eq $script:TextMask) {
      $k = $Matches[2]
      if ($before[$k]) { $lines[$i] = "$($Matches[1])$k$($Matches[3])$($before[$k])" } else { $err += Get-Text 'ErrTextNoPassword' $k }
    }
    # neither a setting nor a comment: the device skips the line without a word
    elseif ($l.Trim() -and $l -notmatch '^\s*[#;]' -and $l -cnotmatch '^\s*[A-Z][A-Z0-9_]*\s*=') { $err += Get-Text 'ErrTextLine' ($i + 1) $l.Trim() }
  }
  $now = [ordered]@{}
  foreach ($l in $lines) { if ($l -cmatch '^\s*([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*$') { $now[$Matches[1]] = $Matches[2] } }
  $managed = [ordered]@{}
  foreach ($k in @(@($before.Keys) + @($now.Keys) | Select-Object -Unique)) {
    if (Get-Setting $k) { $managed[$k] = if ($now.Contains($k)) { $now[$k] } else { $null } }
    elseif ($before[$k] -cne $now[$k]) { $extra += $(if ($k -in 'MGMT_PASSWORD', 'EAP_PASSWORD') { Get-Text 'TextPwChanged' $k } else { "${k}: '$($before[$k])' -> '$($now[$k])'" }) }
  }
  $ign = @(Get-IgnoredKeys $now -Common:(-not $dev) | Where-Object { $_ -notin 'MGMT_PASSWORD', 'EAP_PASSWORD' })
  if ($ign.Count) { $warn += Get-Text 'WarnTextIgnored' ($ign -join ', ') }
  $plan = if ($dev) { Get-DeviceSavePlan $dev $managed } else { Get-CommonSavePlan $managed $script:Devices }
  # the stored form, as the pages write it (a WPA passphrase becomes its key, a PIN its hash)
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -cmatch '^\s*([A-Z][A-Z0-9_]*)\s*=' -and $plan.Values.Contains($Matches[1]) -and $null -ne $plan.Values[$Matches[1]]) { $lines[$i] = "$($Matches[1])=$($plan.Values[$Matches[1]])" }
  }
  if ($plan.RenameMac) {
    for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match $script:RenameRx) { $lines.RemoveAt($i) } }
    $lines.Add("# rename-mac: $($plan.RenameMac)   (rename pending: identifies the device under its new name)")
  }
  [pscustomobject]@{ File = $f; Errors = @($err + $plan.Errors); Warnings = @($warn + @($plan.PSObject.Properties['Warnings'] | ForEach-Object Value))
    Notes = $plan.Notes; Changes = @($plan.Changes + $extra); Lines = $lines }
}
# ---------------------------------------------------------------------------------------------
# The folder named in the domain (#82): \\<domain>\NETLOGON\OpenThinRDP\folders.conf, lines <account>=<folder>. A device
# with a domain account and no folder of its own reads it at every report (report.sh): a new device needs only domain,
# account and password, and a moved folder is followed. NETLOGON is on every DC and every domain account reads it
# (no LDAP on the device: signing or a missing LDAPS certificate would refuse it); writing needs a domain admin.
# ---------------------------------------------------------------------------------------------
$script:UncRx = '^\\\\[A-Za-z0-9.-]+\\[A-Za-z0-9 ._$\\-]+$'
function Get-DomainFolderFile {
  $d = try { [DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().Name } catch { $null }
  if ($d) { "\\$d\NETLOGON\OpenThinRDP\folders.conf" }
}
# the account of the devices: MGMT_USER of common.conf, without its domain
# (else the one the devices report: the account is often set on each device, not in common.conf)
function Get-DeviceAccount {
  $u = [string](Read-ConfFile $script:CommonFile)['MGMT_USER']
  if (-not $u) { $u = [string]@(Get-MgmtAccounts $script:Devices)[0] }
  (($u -replace '^.*\\', '') -replace '@.*$', '').ToLower()
}
function Get-DomainFolderMap($file) {
  $h = [ordered]@{}
  if ($file -and (Test-Path -LiteralPath $file)) { foreach ($l in (Read-Lines $file)) { if ($l -notmatch '^\s*[#;]' -and $l -match '^\s*([^=]+?)\s*=\s*(.*?)\s*$') { $h[$Matches[1].ToLower()] = $Matches[2] } } }
  $h
}
function Set-DomainFolder([string]$account, [string]$folder) {
  $f = Get-DomainFolderFile; if (-not $f) { throw (Get-Text 'FolderNoDomain') }
  if ($account -notmatch '^[A-Za-z0-9._-]+$') { throw (Get-Text 'FolderNoAccount') }
  $dir = Split-Path $f; if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  # a List: with one line, $lines += would join two strings into one line instead of adding one
  $lines = New-Object Collections.Generic.List[string]
  if (Test-Path -LiteralPath $f) { foreach ($l in (Read-Lines $f)) { if ($l -and $l -notmatch "^\s*$([regex]::Escape($account))\s*=" -and $l -notmatch '^\s*=') { $lines.Add($l) } } }
  if (-not @($lines | Where-Object { $_ -match '^\s*#' }).Count) { $lines.Insert(0, '# OpenThinRDP: the management folder of each device account (<account>=<folder>), written by the manager.') }
  # an older manager glued the first entry to this comment: the comment alone
  for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^(#.*?written by the manager\.)=') { $lines[$i] = $Matches[1] } }
  if ($folder) { $lines.Add("$account=$folder") }
  [IO.File]::WriteAllText($f, (($lines -join "`r`n") + "`r`n"), $script:Utf8)
  Add-ChangeLog "domain folder: $account=$folder ($f)"
}
# The whole folder copied to $to; every device follows: those with a folder of their own through MGMT_SHARE (in every
# .conf of both copies, and added to the old common.conf), those on the domain through folders.conf. The old folder
# stays until every device reports in the new one. Returns what was done, one line each.
function Move-ManagementFolder([string]$to) {
  $from = $script:Folder; $to = $to.TrimEnd('\')
  if ($to -notmatch $script:UncRx) { throw (Get-Text 'FolderMoveBadPath') }
  if ($to -ieq $from.TrimEnd('\')) { throw (Get-Text 'FolderMoveSame') }
  if (-not (Test-Path -LiteralPath $to)) { New-Item -ItemType Directory -Path $to | Out-Null }
  $out = @()
  $rc = & robocopy.exe $from $to /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP 2>&1; $code = $LASTEXITCODE
  if ($code -ge 8) { throw "robocopy $code`: $(@($rc) -join ' ')" }
  $out += Get-Text 'FolderMoveCopied' $from $to
  foreach ($cd in @((Join-Path $from 'config'), (Join-Path $to 'config'))) {
    foreach ($c in @(Get-ChildItem -LiteralPath $cd -Filter '*.conf' -File -ErrorAction SilentlyContinue | Where-Object Extension -eq '.conf')) {
      $ls = @(Read-Lines $c.FullName); $ch = $false
      for ($i = 0; $i -lt $ls.Count; $i++) { if ($ls[$i] -cmatch '^\s*MGMT_SHARE\s*=' -and $ls[$i] -cne "MGMT_SHARE=$to") { $ls[$i] = "MGMT_SHARE=$to"; $ch = $true } }
      if ($ch) { [IO.File]::WriteAllText($c.FullName, (($ls -join "`r`n") + "`r`n"), $script:Utf8) }
    }
  }
  if (-not (Read-ConfFile $script:CommonFile).Contains('MGMT_SHARE')) {
    [IO.File]::AppendAllText($script:CommonFile, "`r`n# moved by the OpenThinRDP manager on $(Get-Date -Format 'yyyy-MM-dd HH:mm')`r`nMGMT_SHARE=$to`r`n", $script:Utf8)
  }
  $out += Get-Text 'FolderMoveConf'
  Add-ChangeLog "management folder moved to $to"
  $acc = Get-DeviceAccount; $map = Get-DomainFolderMap (Get-DomainFolderFile)
  if ($acc -and $map.Contains($acc)) { Set-DomainFolder $acc $to; $out += Get-Text 'FolderMoveDomain' $acc }
  Set-ManagementFolder $to; Save-LastFolder $to
  Add-ChangeLog "management folder moved here from $from"
  $out
}

function Save-ConfText($plan) {
  if (-not (Test-Path -LiteralPath $script:ConfigDir)) { New-Item -ItemType Directory -Path $script:ConfigDir | Out-Null }
  if (Test-Path -LiteralPath $plan.File) { Copy-Item -LiteralPath $plan.File -Destination (Get-BackupPath $plan.File) }
  [IO.File]::WriteAllText($plan.File, (($plan.Lines -join "`r`n") + "`r`n"), $script:Utf8)
  Add-ChangeLog ("{0} (as text): {1}" -f [IO.Path]::GetFileName($plan.File), ($plan.Changes -join '; '))
}

# ---------------------------------------------------------------------------------------------
# SSH keys: config\authorized_keys. The device keeps only the lines in this format (comments and
# anything else are dropped), and an EMPTY file removes every key, while a MISSING file leaves the
# last keys in place: so this tool never deletes the file.
# ---------------------------------------------------------------------------------------------
function Test-AuthorizedKeys([string]$text) {
  $err = @(); $n = 0
  foreach ($l in ($text -split "`r?`n")) {
    $n++; $t = $l.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    if ($t -cnotmatch $script:Rx.SshKey) { $err += Get-Text 'ErrKeyLine' $n }
  }
  $err
}
function Get-KeyLines([string]$text) { @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -cmatch $script:Rx.SshKey }) }
function Get-KeyLabel([string]$line) { $p = $line -split ' ', 3; if ($p.Count -ge 3 -and $p[2]) { $p[2] } else { "$($p[0]) ...$($p[1].Substring([Math]::Max(0, $p[1].Length - 12)))" } }
function Save-AuthorizedKeys([string]$text) {
  if (-not (Test-Path -LiteralPath $script:ConfigDir)) { New-Item -ItemType Directory -Path $script:ConfigDir | Out-Null }
  $old = if (Test-Path -LiteralPath $script:KeysFile) { Get-KeyLines ((Read-Lines $script:KeysFile) -join "`n") } else { @() }
  $new = Get-KeyLines $text
  $out = @($text -split "`r?`n" | ForEach-Object { $_.TrimEnd() })
  while ($out.Count -gt 0 -and $out[$out.Count - 1] -eq '') { $out = @($out | Select-Object -First ($out.Count - 1)) }
  if (Test-Path -LiteralPath $script:KeysFile) { Copy-Item -LiteralPath $script:KeysFile -Destination (Get-BackupPath $script:KeysFile) }
  [IO.File]::WriteAllText($script:KeysFile, $(if ($out.Count) { ($out -join "`r`n") + "`r`n" } else { '' }), $script:Utf8)
  $plus = @($new | Where-Object { $old -cnotcontains $_ } | ForEach-Object { Get-KeyLabel $_ })
  $minus = @($old | Where-Object { $new -cnotcontains $_ } | ForEach-Object { Get-KeyLabel $_ })
  if ($plus.Count -or $minus.Count) {
    Add-ChangeLog ("authorized_keys: {0} -> {1} keys{2}{3}" -f $old.Count, $new.Count, $(if ($plus.Count) { "; added: $($plus -join ', ')" } else { '' }), $(if ($minus.Count) { "; removed: $($minus -join ', ')" } else { '' }))
  }
  [pscustomobject]@{ Before = $old.Count; After = $new.Count; Added = $plus; Removed = $minus }
}

# ---------------------------------------------------------------------------------------------
# Rename: <old>.conf with HOSTNAME=<new> stays until the device reports with the new name (same MAC);
# then it becomes <new>.conf, otherwise the device would lose its exceptions under the new name
# ---------------------------------------------------------------------------------------------
function Complete-Renames {
  $done = @()
  if (-not (Test-Path -LiteralPath $script:ConfigDir)) { return @() }
  $files = @(Get-ChildItem -LiteralPath $script:ConfigDir -Filter '*.conf' -File -ErrorAction SilentlyContinue) +
    @(Get-ChildItem -Path (Join-Path (Get-GroupsDir) '*\*.conf') -File -ErrorAction SilentlyContinue | Where-Object Name -ne '_group.conf')
  foreach ($f in @($files | Where-Object Extension -eq '.conf')) {
    $old = $f.BaseName; if ($old -eq 'common') { continue }
    $c = Read-ConfFile $f.FullName; $new = $c['HOSTNAME']
    if (-not $new -or $new -eq $old) { continue }
    $newStatus = Join-Path $script:StatusDir "$new.txt"; $oldStatus = Join-Path $script:StatusDir "$old.txt"
    if (-not (Test-Path -LiteralPath $newStatus)) { continue }
    $sn = Read-StatusFile $newStatus
    $mark = @(Read-Lines $f.FullName | Where-Object { $_ -match $script:RenameRx } | ForEach-Object { [regex]::Match($_, $script:RenameRx).Groups[1].Value }) | Select-Object -First 1
    if ($mark) {
      if ($sn['MAC'] -ne $mark) { continue }                                   # another device with that name
    } else {
      # file written by hand, no MAC mark: the report must come after the file, and the old status (if
      # still there) must be the same device
      $when = Get-ReportTime $sn; if (-not $when -or $when -le $f.LastWriteTime) { continue }
      if ((Test-Path -LiteralPath $oldStatus) -and (Read-StatusFile $oldStatus)['MAC'] -ne $sn['MAC']) { continue }
    }
    $dest = Join-Path $f.DirectoryName "$new.conf"                             # the same folder: the same group
    if (Test-Path -LiteralPath $dest) { continue }                             # never overwritten
    $lines = @(Read-Lines $f.FullName | Where-Object { $_ -cnotmatch '^\s*#?\s*HOSTNAME\s*=' -and $_ -notmatch $script:RenameRx })
    # the removed lines can leave an "# added by..." line with nothing under it at the end
    $n = $lines.Count; while ($n -gt 0 -and ($lines[$n - 1] -eq '' -or $lines[$n - 1] -like '# added by the OpenThinRDP manager*')) { $n-- }
    $lines = @($lines | Select-Object -First $n)
    # nothing of its own left: no file at all, the device just has its new name (in a group folder the file stays:
    # it is what puts the device in that group)
    $active = @($lines | Where-Object { $_ -cmatch '^\s*[A-Z][A-Z0-9_]*\s*=' })
    if ($active.Count -or $f.DirectoryName -ne $script:ConfigDir.TrimEnd('\')) { [IO.File]::WriteAllText($dest, (($lines -join "`r`n").TrimEnd() + "`r`n"), $script:Utf8) }
    Move-Item -LiteralPath $f.FullName -Destination (Get-BackupPath $f.FullName)
    # status under the old name: the device removes it itself; one left behind (folder unreachable at that
    # moment) would stay in the list forever
    $prev = Join-Path $script:StatusDir 'previous-names'
    foreach ($s in @("$old.txt", "$old-events.log")) {
      $p = Join-Path $script:StatusDir $s
      if (Test-Path -LiteralPath $p) { if (-not (Test-Path -LiteralPath $prev)) { New-Item -ItemType Directory -Path $prev | Out-Null }; Move-Item -LiteralPath $p -Destination (Join-Path $prev $s) -Force }
    }
    # logo and background picture of the device follow it
    $bo = Get-BrandingDir $old; $bn = Get-BrandingDir $new
    if ((Test-Path -LiteralPath $bo) -and -not (Test-Path -LiteralPath $bn)) { Move-Item -LiteralPath $bo -Destination $bn }
    Add-ChangeLog ("rename completed: {0} -> {1} ({0}.conf becomes {1}.conf)" -f $old, $new)
    $done += "$old -> $new"
  }
  $done
}

# ---------------------------------------------------------------------------------------------
# Logo and background picture: config\branding\<kind>.png for every device, config\branding\<hostname>\<kind>.png for
# one (branding.sh on the device; the device file wins). Any picture is scaled down to fit and saved as PNG:
# the devices accept only PNG files up to 2 MB, logo up to 400 x 240, background up to 1024 x 640.
# ---------------------------------------------------------------------------------------------
$script:BrandingSize = @{ logo = @(300, 120); splash = @(640, 400) }
function Get-BrandingDir([string]$hostName = '') {
  $d = Join-Path $script:ConfigDir 'branding'; if ($hostName) { Join-Path $d $hostName } else { $d }
}
function Get-BrandingFile([string]$kind, [string]$hostName = '') { Join-Path (Get-BrandingDir $hostName) "$kind.png" }
# the picture a device shows: its own, else the common one, else the image's own (File = $null)
function Get-BrandingSource([string]$kind, [string]$hostName = '') {
  if ($hostName) { $f = Get-BrandingFile $kind $hostName; if (Test-Path -LiteralPath $f) { return [pscustomobject]@{ From = 'device'; File = $f } } }
  $f = Get-BrandingFile $kind; if (Test-Path -LiteralPath $f) { return [pscustomobject]@{ From = 'common'; File = $f } }
  [pscustomobject]@{ From = 'image'; File = $null }
}
# a copy in memory: Image.FromFile would keep the file locked until the window closes
function Read-Picture([string]$file) {
  $ms = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($file))
  try { $i = [System.Drawing.Image]::FromStream($ms); try { New-Object System.Drawing.Bitmap($i) } finally { $i.Dispose() } } finally { $ms.Dispose() }
}
function Save-BrandingImage([string]$source, [string]$kind, [string]$hostName = '') {
  $max = $script:BrandingSize[$kind]
  try { $img = Read-Picture $source } catch { throw (Get-Text 'BrandLoadFailed' $_.Exception.Message) }
  try {
    # [double]: 640 / 640 is an Int32 in PowerShell, and Min(Int32, Double) would round the other ratio to 1
    $k = [Math]::Min(1.0, [Math]::Min([double]$max[0] / $img.Width, [double]$max[1] / $img.Height))
    $w = [Math]::Max(1, [int][Math]::Round($img.Width * $k)); $h = [Math]::Max(1, [int][Math]::Round($img.Height * $k))
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
      $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'; $g.CompositingQuality = 'HighQuality'
      $g.Clear([System.Drawing.Color]::Transparent)
      # TileFlipXY: no half transparent frame along the edges when scaling down
      $ia = New-Object System.Drawing.Imaging.ImageAttributes; $ia.SetWrapMode('TileFlipXY')
      $g.DrawImage($img, (New-Object System.Drawing.Rectangle(0, 0, $w, $h)), 0, 0, $img.Width, $img.Height, 'Pixel', $ia)
    } finally { $g.Dispose() }
  } finally { $img.Dispose() }
  $dest = Get-BrandingFile $kind $hostName
  $dir = Split-Path $dest; if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  # written aside first: a device never reads half a file (it reads only <kind>.png)
  $tmp = "$dest.new"
  try { $bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $bmp.Dispose() }
  if ((Get-Item -LiteralPath $tmp).Length -gt 2MB) { Remove-Item -LiteralPath $tmp; throw (Get-Text 'BrandTooBig') }
  $rel = if ($hostName) { "branding\$hostName\$kind.png" } else { "branding\$kind.png" }
  if (Test-Path -LiteralPath $dest) { Move-Item -LiteralPath $dest -Destination (Get-BackupPath ($rel -replace '\\', '-')) }
  Move-Item -LiteralPath $tmp -Destination $dest
  Add-ChangeLog ("{0}: new picture {1} x {2} px (from {3})" -f $rel, $w, $h, [IO.Path]::GetFileName($source))
  [pscustomobject]@{ File = $dest; Width = $w; Height = $h }
}
function Remove-BrandingImage([string]$kind, [string]$hostName = '') {
  $dest = Get-BrandingFile $kind $hostName
  if (-not (Test-Path -LiteralPath $dest)) { return $false }
  $rel = if ($hostName) { "branding\$hostName\$kind.png" } else { "branding\$kind.png" }
  Move-Item -LiteralPath $dest -Destination (Get-BackupPath ($rel -replace '\\', '-'))
  # an empty device folder would stay forever after the device is gone
  if ($hostName -and -not @(Get-ChildItem -LiteralPath (Get-BrandingDir $hostName) -Force).Count) { Remove-Item -LiteralPath (Get-BrandingDir $hostName) }
  Add-ChangeLog "${rel}: removed"
  $true
}

# ---------------------------------------------------------------------------------------------
# Permissions of the management folder (docs/management.md#account). Every device can read the password of
# its account, so that account must be able to write in status\ only: settings, logos and updates read-only.
# Read from the NTFS permissions; the permissions of the share can only take rights away.
# ---------------------------------------------------------------------------------------------
# rights that change something: write/create, append/create folders, extended attributes, delete children,
# attributes, delete, permissions, owner
$script:WriteMask = 0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000
# Administrators, SYSTEM, CREATOR OWNER, and (any domain) Domain Admins, Enterprise Admins: expected to write
$script:AdminSid = '^(S-1-5-32-544|S-1-5-18|S-1-3-0|S-1-5-21-.+-(512|519))$'
# groups that mean "every user": Everyone, Authenticated Users, NETWORK, Users, Domain Users
$script:EveryoneSid = '^(S-1-1-0|S-1-5-11|S-1-5-2|S-1-5-32-545|S-1-5-21-.+-513)$'

# the account the devices use: what they report (MGMT_ACCOUNT, since 0.1.6), else MGMT_USER of common.conf
function Get-MgmtAccounts($devices) {
  $a = @($devices | ForEach-Object { $_.S['MGMT_ACCOUNT'] } | Where-Object { $_ -and $_ -ne 'none' })
  if (-not $a.Count) {
    $c = Read-ConfFile $script:CommonFile
    if ($c['MGMT_USER']) { $a = @(if ($c['MGMT_USER'] -match '[\\@]' -or -not $c['DOMAIN']) { $c['MGMT_USER'] } else { "$($c['DOMAIN'])\$($c['MGMT_USER'])" }) }
  }
  @($a | Sort-Object -Unique)
}
function Get-SidName([string]$sid) {
  try { (New-Object Security.Principal.SecurityIdentifier $sid).Translate([Security.Principal.NTAccount]).Value } catch { $sid }
}
# the SIDs that count for an account: itself, its domain groups (nested too) and the groups every signed-in
# account is in on a file server
function Get-AccountSids([string]$account) {
  $sid = (New-Object Security.Principal.NTAccount $account).Translate([Security.Principal.SecurityIdentifier]).Value
  $sids = @($sid, 'S-1-1-0', 'S-1-5-11', 'S-1-5-2', 'S-1-5-32-545')
  try {
    $de = New-Object DirectoryServices.DirectoryEntry "LDAP://<SID=$sid>"
    $de.RefreshCache([string[]]@('tokenGroups'))
    foreach ($b in $de.Properties['tokenGroups']) { $sids += (New-Object Security.Principal.SecurityIdentifier ([byte[]]$b), 0).Value }
  } catch { }   # local account or no domain controller: the account and the groups of everybody
  @($sids | Sort-Object -Unique)
}
# rights of an access rule as plain file rights (generic rights mapped the way NTFS maps them)
function Get-RuleMask($rule) {
  $m = [int64]([int]$rule.FileSystemRights) -band 0xFFFFFFFFL
  if ($m -band 0x10000000) { $m = $m -bor 0x1F01FF }   # GENERIC_ALL
  if ($m -band 0x40000000) { $m = $m -bor 0x116 }      # GENERIC_WRITE
  if ($m -band 0x80000000) { $m = $m -bor 0x120089 }   # GENERIC_READ
  $m -band 0x1F01FF
}
# what $sids may do on $path, and who gives write rights: to them, and to anybody else who is not an
# administrator. Windows reads the rules in their order and the first one that allows or denies a right
# decides it: a Deny after an Allow of the same right changes nothing (an inherited Deny comes after an
# explicit Allow, and the rules of the parent folder before those of the grandparent).
function Get-PathAccess([string]$path, [string[]]$sids) {
  $granted = 0L; $denied = 0L; $via = @(); $others = @()
  $rules = (Get-Acl -LiteralPath $path).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
  foreach ($r in $rules) {
    if ($r.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
    $id = $r.IdentityReference.Value; $m = Get-RuleMask $r
    if ($sids -contains $id) {
      $new = $m -band (-bnot ($granted -bor $denied))
      if ($r.AccessControlType -eq 'Deny') { $denied = $denied -bor $new }
      else { $granted = $granted -bor $new; if ($new -band $script:WriteMask) { $via += $id } }
    }
    elseif ($r.AccessControlType -eq 'Allow' -and ($m -band $script:WriteMask) -and $id -notmatch $script:AdminSid) { $others += $id }
  }
  [pscustomobject]@{ Mask = $granted; Via = @($via | Sort-Object -Unique); Others = @($others | Sort-Object -Unique) }
}
# the check: one line per finding, Problem = something to correct
function Test-FolderPermissions([string]$account) {
  $out = New-Object Collections.ArrayList
  $add = { param($problem, $text) [void]$out.Add([pscustomobject]@{ Problem = $problem; Text = $text }) }
  try { $sids = Get-AccountSids $account } catch { & $add $true (Get-Text 'PermUnknownAccount' $account); return $out }
  $names = { param($l) (@($l | ForEach-Object { Get-SidName $_ }) -join ', ') }
  $st = Get-PathAccess $script:StatusDir $sids
  if (($st.Mask -band 0x7) -eq 0x7) { & $add $false (Get-Text 'PermStatusOk') } else { & $add $true (Get-Text 'PermStatusNoWrite') }
  # read-only places: the folder itself, config\ with logos (not backup\: only the manager uses it), updates\
  $ro = @($script:Folder, $script:ConfigDir)
  $bd = Join-Path $script:ConfigDir 'branding'
  if (Test-Path -LiteralPath $bd) { $ro += @($bd) + @(Get-ChildItem -LiteralPath $bd -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object FullName) }
  $ro += @(Get-ChildItem -LiteralPath $script:ConfigDir -File -Force -ErrorAction SilentlyContinue | ForEach-Object FullName)
  $ud = Join-Path $script:Folder 'updates'
  if (Test-Path -LiteralPath $ud) { $ro += @($ud) + @(Get-ChildItem -LiteralPath $ud -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object FullName) }
  # the same finding on many files = one line: text key + who, with the places
  $found = [ordered]@{}
  $note = { param($key, $who, $rel) $k = "$key|$who"; if (-not $found.Contains($k)) { $found[$k] = New-Object Collections.ArrayList }; [void]$found[$k].Add($rel) }
  $root = $script:Folder.TrimEnd('\') + '\'
  foreach ($p in $ro) {
    $a = Get-PathAccess $p $sids
    $dir = (Get-Item -LiteralPath $p -Force).PSIsContainer
    $rel = if ($p -eq $script:Folder) { Get-Text 'PermTheFolder' } else { $p.Substring($root.Length) + $(if ($dir) { '\' } else { '' }) }
    if ($a.Mask -band $script:WriteMask) { & $note 'PermDevicesWrite' (& $names $a.Via) $rel }
    $every = @($a.Others | Where-Object { $_ -match $script:EveryoneSid })
    if ($every.Count) { & $note 'PermEveryoneWrites' (& $names $every) $rel }
    if ($dir -and -not ($a.Mask -band 0x1)) { & $note 'PermNoRead' '' $rel }
  }
  foreach ($k in $found.Keys) {
    $key, $who = $k -split '\|', 2; $l = $found[$k]
    $where = (@($l | Select-Object -First 4) -join ', ') + $(if ($l.Count -gt 4) { ' ' + (Get-Text 'PermMore' ($l.Count - 4)) } else { '' })
    & $add $true (Get-Text $key $where $who)
  }
  if (-not @($out | Where-Object Problem).Count) { & $add $false (Get-Text 'PermReadOnlyOk') }
  $out
}
# The rights the account needs and no more (docs/management.md#account): read on the folder and below, modify on
# status\. Write rights given to the account itself outside status\ (its own explicit rules) become read; rights
# through groups (Everyone, Domain Users...) are only reported: other people may need them. Returns the changes.
function Repair-FolderPermissions([string]$account) {
  $sid = (New-Object Security.Principal.NTAccount $account).Translate([Security.Principal.SecurityIdentifier])
  $inh = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'; $none = [Security.AccessControl.PropagationFlags]::None
  $rx = [Security.AccessControl.FileSystemRights]::ReadAndExecute; $mod = [Security.AccessControl.FileSystemRights]::Modify
  $done = @()
  foreach ($p in @($script:Folder, $script:ConfigDir, (Join-Path $script:Folder 'updates'))) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $acl = Get-Acl -LiteralPath $p; $ch = $false
    foreach ($r in @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference -eq $sid -and $_.AccessControlType -eq 'Allow' -and ((Get-RuleMask $_) -band $script:WriteMask) })) {
      [void]$acl.RemoveAccessRuleSpecific($r); $ch = $true; $done += Get-Text 'PermFixNoWrite' $p
    }
    if ($p -eq $script:Folder) { $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, $rx, $inh, $none, 'Allow'))); $ch = $true }
    if ($ch) { Set-Acl -LiteralPath $p -AclObject $acl }
  }
  $done += Get-Text 'PermFixRead' $script:Folder
  if (-not (Test-Path -LiteralPath $script:StatusDir)) { New-Item -ItemType Directory -Path $script:StatusDir | Out-Null }
  $acl = Get-Acl -LiteralPath $script:StatusDir
  $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, $mod, $inh, $none, 'Allow'))); Set-Acl -LiteralPath $script:StatusDir -AclObject $acl
  $done += Get-Text 'PermFixStatus' $script:StatusDir
  Add-ChangeLog "permissions of $account corrected: $($done -join '; ')"
  $done
}

# ---------------------------------------------------------------------------------------------
# Problems: the event logs of all devices (status\<hostname>-events.log) read together, so that a broker refusing
# sign-ins on six devices this morning shows as one line, not as six files nobody opens.
# Each rule: the kind (text Prob_<kind> in lang\*.psd1) and the event it recognizes; named groups user, broker,
# code, where (what the line is grouped by besides the kind).
# ---------------------------------------------------------------------------------------------
$script:ProblemRules = @(
  @{ K = 'AttemptFailed'; R = '^attempt \d+ for (?<user>\S+) on (?<broker>\S+) failed after \d+s \(code (?<code>\d+), (?<where>\w+)\)' }
  @{ K = 'DesktopUnavailable'; R = '^desktop not available for (?<user>\S+) after \d+ attempts: (?<where>\S*)' }
  @{ K = 'SignInRefused'; R = '^sign-in refused for (?<user>\S+) \(code (?<code>\d+)\)' }
  @{ K = 'NoNetwork'; R = '^attempt \d+ for (?<user>\S+): no network' }
  @{ K = 'Dropped'; R = '^session of (?<user>\S+) DROPPED after [^(]*\((?<where>.+), code (?<code>\d+)\)' }
  @{ K = 'TooManyDrops'; R = '^too many drops in a row for (?<user>\S+)' }
  @{ K = 'TakenOver'; R = '^session of (?<user>\S+) (disconnected after .* while its VM still runs|taken over by another device)' }
  @{ K = 'Watchdog'; R = '^watchdog: ' }
  @{ K = 'UdpBlocked'; R = '^UDP only: the session of (?<user>\S+)' }
  @{ K = 'UpdateFailed'; R = '^software update (?<where>\S+) FAILED' }
  @{ K = 'ConfigRejected'; R = '^(central configuration REJECTED|settings rejected)' }
  @{ K = 'WrongPin'; R = '^settings: wrong PIN' }
)
# causes as the devices log them (kiosk.sh reason/err_class) -> texts of the manager; brokers stay as they are
$script:CauseText = @{ 'network lost' = 'CauseNetLost'; 'killed (watchdog or kill -9)' = 'CauseKilled'; 'net' = 'CauseNet'; 'dns' = 'CauseDns'
  'broker' = 'CauseBroker'; 'vm' = 'CauseVm'; 'udp' = 'CauseUdp'; 'other' = 'CauseOther' }
function Get-WhereLabel([string]$w) {
  if ($script:CauseText.ContainsKey($w)) { return (Get-Text $script:CauseText[$w]) }
  if ($w -match '^error (\d+)$') { return (Get-Text 'CauseError' $Matches[1]) }
  $w
}
$script:HostNames = @{}
# a broker given as an address shown with its name (cached: one lookup per address)
function Get-HostLabel([string]$h) {
  if ($h -notmatch '^\d+\.\d+\.\d+\.\d+$') { return ($h -split '\.')[0].ToLower() }
  if (-not $script:HostNames.ContainsKey($h)) { $script:HostNames[$h] = try { ([Net.Dns]::GetHostEntry($h).HostName -split '\.')[0].ToLower() } catch { $h } }
  $script:HostNames[$h]
}
# every problem event since $since: time, device, kind, user, broker (the server really contacted when the device
# logged it: "broker X: connecting to Y (Kerberos)"), code, where, the line itself
function Get-ProblemEvents([datetime]$since) {
  $out = New-Object Collections.ArrayList
  if (-not (Test-Path -LiteralPath $script:StatusDir)) { return @() }
  foreach ($f in @(Get-ChildItem -LiteralPath $script:StatusDir -Filter '*-events.log' -File -ErrorAction SilentlyContinue)) {
    $dev = $f.BaseName -replace '-events$', ''; $node = ''; $nodeAt = [datetime]::MinValue
    foreach ($l in (Read-Lines $f.FullName)) {
      if ($l -notmatch '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (.*)$') { continue }
      $t = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture); $txt = $Matches[2]
      if ($txt -match '^broker \S+: connecting to (\S+)') { $node = $Matches[1]; $nodeAt = $t; continue }
      if ($t -lt $since) { continue }
      foreach ($r in $script:ProblemRules) {
        if ($txt -notmatch $r.R) { continue }
        $b = "$($Matches['broker'])"; if ($b -and $node -and ($t - $nodeAt).TotalSeconds -le 120) { $b = $node }
        [void]$out.Add([pscustomobject]@{ Time = $t; Device = $dev; Kind = $r.K; User = "$($Matches['user'])"; Broker = $(if ($b) { Get-HostLabel $b } else { '' })
          Code = "$($Matches['code'])"; Where = "$($Matches['where'])"; Text = $txt })
        break
      }
    }
  }
  @($out | Sort-Object Time)
}
# one line per kind and place (broker for sign-in failures, cause for drops): how many times, how many devices
# and users, when last. Wide = the same problem on 3 or more devices: rather the server or the network than a device.
function Get-ProblemSummary($events) {
  @($events | Group-Object { "$($_.Kind)|$(if ($_.Broker) { $_.Broker } else { $_.Where })" } | ForEach-Object {
    $k, $w = $_.Name -split '\|', 2; $g = $_.Group
    $devs = @($g.Device | Sort-Object -Unique); $users = @($g.User | Where-Object { $_ } | Sort-Object -Unique)
    [pscustomobject]@{ Kind = $k; Where = $w; Count = $g.Count; Devices = $devs; Users = $users; First = ($g | Select-Object -First 1).Time
      Last = ($g | Select-Object -Last 1).Time; Wide = ($devs.Count -ge 3); Events = $g }
  } | Sort-Object @{ Expression = 'Wide'; Descending = $true }, @{ Expression = 'Count'; Descending = $true })
}
# the headline: the problems that touched most devices, in one sentence each
function Get-ProblemHeadline($summary) {
  # an empty summary comes as $null, and @($null) has one element
  if (-not @($summary | Where-Object { $_ }).Count) { return (Get-Text 'ProbNone') }
  (@($summary | Sort-Object @{ Expression = { $_.Devices.Count }; Descending = $true }, @{ Expression = 'Count'; Descending = $true } | Select-Object -First 3 | ForEach-Object {
    Get-Text 'ProbHeadline' (Get-Text "Prob_$($_.Kind)") $(if ($_.Where) { " ($(Get-WhereLabel $_.Where))" } else { '' }) $_.Count $_.Devices.Count
  }) -join "   $([char]0x00B7)   ")
}

function Get-LastFolder {
  try { if (Test-Path -LiteralPath $script:SettingsFile) { return [string](Get-Content -LiteralPath $script:SettingsFile -Raw | ConvertFrom-Json).Folder } } catch { }
  $null
}
function Save-LastFolder($path) {
  try {
    # the other settings of the file (the Desktops page) stay
    $s = New-Object psobject
    try { if (Test-Path -LiteralPath $script:SettingsFile) { $j = Get-Content -LiteralPath $script:SettingsFile -Raw | ConvertFrom-Json; if ($j) { $s = $j } } } catch { }
    if ($s.PSObject.Properties['Folder']) { $s.Folder = $path } else { $s | Add-Member -NotePropertyName Folder -NotePropertyValue $path }
    $d = Split-Path $script:SettingsFile
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
    [IO.File]::WriteAllText($script:SettingsFile, ($s | ConvertTo-Json -Depth 5), $script:Utf8)
  } catch { }
}

# ---- The local copy of the management folder (Settings > Manager): the manager works from it when the file server is
# down. A mirror made in the background at every start and by hand, without the packages of the old versions (large,
# and only the file server publishes them). What is changed in the copy stays in the copy.
function Get-LocalCopyPath { try { $s = Read-ManagerSettings; if ($s.PSObject.Properties['LocalCopy']) { return [string]$s.LocalCopy } } catch { }; '' }
function Get-LocalCopyAge([string]$dir) { if (-not $dir) { return '' }; $f = Join-Path $dir 'local-copy.txt'; if (Test-Path -LiteralPath $f) { [string](Get-Content -LiteralPath $f -TotalCount 1) } else { '' } }
$script:LocalSync = $null
function Get-LocalCopyArgs([string]$from, [string]$to) { @($from, $to, '/MIR', '/R:1', '/W:1', '/NP', '/NFL', '/NDL', '/NJH', '/XD', (Join-Path $from 'updates\versions'), (Join-Path $from 'previous')) }
function Start-LocalCopySync([string]$from, [string]$to) {
  if (-not $from -or -not $to -or $from.TrimEnd('\') -ieq $to.TrimEnd('\') -or $script:LocalMode) { return $false }
  if ($script:LocalSync -and -not $script:LocalSync.Handle.IsCompleted) { return $false }
  $ps = [powershell]::Create().AddScript({ param($a, $to, $from)
    if (-not (Test-Path -LiteralPath $to)) { New-Item -ItemType Directory -Path $to -Force | Out-Null }
    $null = & robocopy.exe @a 2>&1
    if ($LASTEXITCODE -lt 8) { [IO.File]::WriteAllText((Join-Path $to 'local-copy.txt'), "$((Get-Date).ToString('yyyy-MM-dd HH:mm')) <- $from") }
    $LASTEXITCODE }).AddArgument((Get-LocalCopyArgs $from $to)).AddArgument($to).AddArgument($from)
  $script:LocalSync = @{ Ps = $ps; Handle = $ps.BeginInvoke() }
  $true
}
if ($Folder) { Set-ManagementFolder $Folder }
# what an update of the manager says for the administrator: the folder, and the launchers to build again
function Get-ManagerDoneText($r) {
  $m = Get-Text 'MgrDone' $r.Version $r.Dir
  if ($r.LauncherChanged) { $m += "`r`n`r`n" + (Get-Text 'MgrLauncherChanged' (Join-Path $r.Dir 'build-launcher.ps1')) }
  $m
}
function Add-ManagerChangeLog($r) {
  # the change log of the management folder, when one is open and has a config\ (the manager itself is not in it)
  if ($script:ChangeLog -and (Test-Path -LiteralPath $script:ConfigDir)) { Add-ChangeLog "manager updated from $($script:ManagerVersion) to $($r.Version) in $($r.Dir)" }
}
# -UpdateManager: no window, the result on the console (OpenThinRDP-Manager.cmd runs it in the foreground).
# Exit code 0 = updated, 1 = error, 2 = nothing to do (up to date, a release without the manager, a development copy).
if ($UpdateManager) {
  $rc = 2
  try {
    Remove-OldManagerFiles
    $o = Get-ManagerOffer
    if ($o.Status -eq 'Available') {
      $r = Update-Manager $o
      Add-ManagerChangeLog $r
      [Console]::Out.WriteLine((Get-ManagerDoneText $r)); $rc = 0
    } elseif ($o.Status -eq 'BadSignature') { throw (Get-Text 'MgrStatus_BadSignature') }
    else { [Console]::Out.WriteLine((Get-Text "MgrStatus_$($o.Status)" $o.Version)) }
  } catch { $rc = 1; [Console]::Error.WriteLine($_.Exception.Message) }
  exit $rc
}
# The Windows side of the VDI (Desktops page: brokers, hosts, desktops, sessions): OtrVdi.ps1 next to this file. Loaded after
# -UpdateManager, so that a broken copy of it can still be replaced by an update; without it the rest works as before.
$script:VdiLoaded = $false
try { . (Join-Path $PSScriptRoot 'OtrVdi.ps1'); $script:VdiLoaded = $true } catch { Write-Warning "OtrVdi.ps1: $($_.Exception.Message)" }
# The Health Center (hosts, cluster, storage, DCs, DNS, SQL, devices, backups): OtrHealth.ps1, on top of OtrVdi.ps1
$script:HealthLoaded = $false
if ($script:VdiLoaded) { try { . (Join-Path $PSScriptRoot 'OtrHealth.ps1'); $script:HealthLoaded = $true } catch { Write-Warning "OtrHealth.ps1: $($_.Exception.Message)" } }
Write-Trace 'functions loaded'
if ($FunctionsOnly) { return }
# files of an update of the manager that were in use (Install-ManagerFile)
try { Remove-OldManagerFiles } catch { }

# =============================================================================================
# Window
#   left: the pages (Devices, Desktops, Common settings, Updates, SSH keys, Vault, History); top: the actions on the folder.
#   Devices: the list on the left, the selected device on the right (header with its actions, then Settings,
#   Summary, Events and the full report). The settings grids show the help of the selected setting in full
#   under the grid instead of a column cut after a few words.
# =============================================================================================
[System.Windows.Forms.Application]::EnableVisualStyles()
function Show-Message($title, $text, $icon = 'Warning') { [void][System.Windows.Forms.MessageBox]::Show($text, $title, 'OK', $icon) }
function Confirm-Action($title, $text, $default = 'Button1') {
  [System.Windows.Forms.MessageBox]::Show($text, $title, 'YesNo', 'Question', $default) -eq 'Yes'
}
# A choice in a small dialog: $text on top, one radio button per option (a text, or @(text, $false) when it cannot be
# chosen now). With $versions (a list, also empty) the last option chooses one of them in a list under it, and $fetch
# (a script block returning a version, or $null) adds From GitHub... next to the list, which fills it again from
# updates\versions\. Returns @{ Option = index; Version = the chosen version } or $null (Cancel).
function Show-PickDialog([string]$title, [string]$text, $options, [int]$selected = 0, $versions = $null, [string]$version = '', $fetch = $null, [string]$okKey = 'BtnApply') {
  $W = 620
  $dlg = New-Object System.Windows.Forms.Form; Set-WindowIcon $dlg
  $dlg.Text = $title; $dlg.Font = $fontBase; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.StartPosition = 'CenterParent'
  $note = New-Object System.Windows.Forms.Label; $note.Text = $text; $note.MaximumSize = New-Object System.Drawing.Size(($W - 28), 0); $note.AutoSize = $true
  $note.Location = New-Object System.Drawing.Point(14, 12); $dlg.Controls.Add($note)
  $y = 12 + $note.GetPreferredSize((New-Object System.Drawing.Size(($W - 28), 0))).Height + 14
  $radios = @()
  for ($i = 0; $i -lt @($options).Count; $i++) {
    $o = @($options)[$i]; $t = if ($o -is [array]) { [string]$o[0] } else { [string]$o }; $can = -not ($o -is [array] -and $o.Count -gt 1 -and -not $o[1])
    $rb = New-Object System.Windows.Forms.RadioButton; $rb.Text = $t; $rb.Enabled = $can; $rb.AutoSize = $true
    $rb.MaximumSize = New-Object System.Drawing.Size(($W - 44), 0); $rb.Location = New-Object System.Drawing.Point(20, $y)
    $dlg.Controls.Add($rb); $radios += $rb; $y += $rb.GetPreferredSize((New-Object System.Drawing.Size(($W - 44), 0))).Height + 8
  }
  $cmb = $null
  if ($null -ne $versions) {
    $cmb = New-Object System.Windows.Forms.ComboBox; $cmb.DropDownStyle = 'DropDownList'; $cmb.Font = $fontBase; $cmb.SetBounds(40, $y, 200, 26)
    $fill = { param($list, $want) $cmb.Items.Clear(); foreach ($v in @($list)) { [void]$cmb.Items.Add($v) }
      if ($cmb.Items.Count) { $k = $cmb.Items.IndexOf($want); $cmb.SelectedIndex = [Math]::Max(0, $k) }
      $cmb.Enabled = $cmb.Items.Count -gt 0; $radios[-1].Enabled = $cmb.Items.Count -gt 0 }
    & $fill $versions $version
    $cmb.add_SelectionChangeCommitted({ $radios[-1].Checked = $true })
    $dlg.Controls.Add($cmb)
    if ($fetch) {
      $bf = New-Button 'BtnFromGitHub' 120 28; $bf.Location = New-Object System.Drawing.Point(($cmb.Right + 10), ($y - 1)); $dlg.Controls.Add($bf)
      $bf.add_Click({ $v = & $fetch; if ($v) { & $fill @(Get-PublishedVersions | Where-Object Usable | ForEach-Object Version) $v; if ($cmb.Items.Count) { $radios[-1].Checked = $true } } })
    }
    $y += 40
  }
  if ($selected -ge 0 -and $selected -lt $radios.Count -and $radios[$selected].Enabled) { $radios[$selected].Checked = $true }
  else { $first = @($radios | Where-Object Enabled) | Select-Object -First 1; if ($first) { $first.Checked = $true } }
  $y += 6
  $ok = New-Button $okKey 110 28; $cancel = New-Button 'BtnCancel' 100 28
  $cancel.Location = New-Object System.Drawing.Point(($W - 14 - $cancel.Width), $y); $ok.Location = New-Object System.Drawing.Point(($cancel.Left - 8 - $ok.Width), $y)
  $ok.DialogResult = 'OK'; $cancel.DialogResult = 'Cancel'; $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
  $dlg.Controls.AddRange(@($ok, $cancel)); $dlg.ClientSize = New-Object System.Drawing.Size($W, ($y + 42))
  try {
    if ($dlg.ShowDialog($form) -ne 'OK') { return $null }
    $k = -1; for ($i = 0; $i -lt $radios.Count; $i++) { if ($radios[$i].Checked) { $k = $i } }
    if ($k -lt 0) { return $null }
    @{ Option = $k; Version = $(if ($cmb -and $cmb.SelectedItem) { [string]$cmb.SelectedItem } else { '' }) }
  } finally { $dlg.Dispose() }
}

# The access code of the vault. Open: one box; Create and Change: the code twice. $true = the vault is open (or
# created, or has the new code); $false = the administrator went on without it. Opening takes a couple of seconds
# (600000 rounds): the window says so meanwhile.
function Show-CodeDialog([ValidateSet('Open', 'Create', 'Change')][string]$mode, $owner = $null) {
  $font = New-Object System.Drawing.Font('Segoe UI', 9.75); $Width = 500
  $w = New-Object System.Windows.Forms.Form; Set-WindowIcon $w
  $w.Text = Get-Text "Vault${mode}Title"; $w.Font = $font; $w.FormBorderStyle = 'FixedDialog'; $w.MaximizeBox = $false; $w.MinimizeBox = $false
  $w.StartPosition = if ($owner) { 'CenterParent' } else { 'CenterScreen' }; $w.ShowInTaskbar = -not $owner; $w.TopMost = -not $owner
  $note = New-Object System.Windows.Forms.Label; $note.Text = Get-Text "Vault${mode}Text" $script:VaultFile $script:VaultMinCode
  # the height as the label itself wraps the text (a long path breaks inside, unlike a measure by words)
  $note.Font = $font; $nh = $note.GetPreferredSize((New-Object System.Drawing.Size(($Width - 32), 0))).Height
  $note.SetBounds(16, 14, $Width - 32, $nh + 4); $y = $note.Bottom + 12
  $l1 = New-Object System.Windows.Forms.Label; $l1.Text = Get-Text 'VaultCode'; $l1.AutoSize = $true; $l1.Location = New-Object System.Drawing.Point(16, ($y + 4))
  $t1 = New-Object System.Windows.Forms.TextBox; $t1.UseSystemPasswordChar = $true; $t1.SetBounds(180, $y, $Width - 196, 26); $y += 36
  $w.Controls.AddRange(@($note, $l1, $t1))
  $t2 = $null
  if ($mode -ne 'Open') {
    $l2 = New-Object System.Windows.Forms.Label; $l2.Text = Get-Text 'VaultCodeAgain'; $l2.AutoSize = $true; $l2.Location = New-Object System.Drawing.Point(16, ($y + 4))
    $t2 = New-Object System.Windows.Forms.TextBox; $t2.UseSystemPasswordChar = $true; $t2.SetBounds(180, $y, $Width - 196, 26); $y += 36
    $w.Controls.AddRange(@($l2, $t2))
  }
  $err = New-Object System.Windows.Forms.Label; $err.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#dc2626'); $err.SetBounds(16, $y, $Width - 32, 40); $y += 44
  $ok = New-Object System.Windows.Forms.Button; $ok.Text = Get-Text "Vault${mode}Ok"
  $no = New-Object System.Windows.Forms.Button; $no.Text = Get-Text $(if ($mode -eq 'Change' -or -not $owner) { 'BtnCancel' } else { 'VaultWithout' })
  foreach ($b in @($ok, $no)) { $b.Height = 30; $b.Width = [Math]::Max(110, [System.Windows.Forms.TextRenderer]::MeasureText($b.Text, $font).Width + 28) }
  $no.Location = New-Object System.Drawing.Point(($Width - 16 - $no.Width), $y); $ok.Location = New-Object System.Drawing.Point(($no.Left - 8 - $ok.Width), $y)
  $no.DialogResult = 'Cancel'; $w.AcceptButton = $ok; $w.CancelButton = $no
  $w.Controls.AddRange(@($err, $ok, $no)); $w.ClientSize = New-Object System.Drawing.Size($Width, ($y + 46))
  $ok.add_Click({
    $code = $t1.Text; $err.Text = ''; $why = $null
    if ($mode -eq 'Open') {
      $err.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#6b7280'); $err.Text = Get-Text 'VaultOpening'; $w.Cursor = 'WaitCursor'; $w.Refresh()
      try { $good = Open-Vault $code } catch { $good = $false; $why = $_.Exception.Message } finally { $w.Cursor = 'Default' }
      $err.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#dc2626')
      if ($good) { $w.DialogResult = 'OK'; $w.Close(); return }
      $err.Text = if ($why) { Get-Text 'VaultNotReadable' $why } else { Get-Text 'VaultWrongCode' }
      $t1.SelectAll(); $t1.Focus(); return
    }
    if (-not (Test-CodeStrength $code)) { $err.Text = Get-Text 'VaultCodeShort' $script:VaultMinCode; $t1.Focus(); return }
    if ($code -cne $t2.Text) { $err.Text = Get-Text 'VaultCodeDiffer'; $t2.Text = ''; $t2.Focus(); return }
    $w.Cursor = 'WaitCursor'; $w.Refresh()
    try { if ($mode -eq 'Create') { New-Vault $code } else { Set-VaultCode $code } }
    catch { $err.Text = Get-Text 'VaultSaveFailed' $_.Exception.Message; return } finally { $w.Cursor = 'Default' }
    $w.DialogResult = 'OK'; $w.Close()
  })
  $w.add_Shown({ $t1.Focus() })
  $r = if ($owner) { $w.ShowDialog($owner) } else { $w.ShowDialog() }
  $r -eq 'OK'
}

# The access code at the start: a window of its own, with the name and the icon of the product and nothing else of the
# manager. A wrong code says so and lets the administrator try again (after 3, each try waits longer); Exit or the
# close box ends the manager. $true = the vault is open.
function Show-AccessGate {
  $font = New-Object System.Drawing.Font('Segoe UI', 9.75); $fontName = New-Object System.Drawing.Font('Segoe UI Semibold', 13); $GW = 460
  $shell = [System.Drawing.ColorTranslator]::FromHtml('#1b2733'); $red = [System.Drawing.ColorTranslator]::FromHtml('#dc2626'); $muted = [System.Drawing.ColorTranslator]::FromHtml('#6b7280')
  $w = New-Object System.Windows.Forms.Form; Set-WindowIcon $w
  $w.Text = Get-Text 'GateTitle'; $w.Font = $font; $w.FormBorderStyle = 'FixedDialog'; $w.MaximizeBox = $false; $w.MinimizeBox = $false
  $w.StartPosition = 'CenterScreen'; $w.ShowInTaskbar = $true; $w.BackColor = [System.Drawing.Color]::White
  # the band with the logo and the name, in the colour of the manager
  $band = New-Object System.Windows.Forms.Panel; $band.SetBounds(0, 0, $GW, 64); $band.BackColor = $shell
  $logo = New-Object System.Windows.Forms.PictureBox; $logo.SetBounds(18, 16, 32, 32); $logo.SizeMode = 'Zoom'
  if ($script:AppIcon) { $logo.Image = (New-Object System.Drawing.Icon($script:AppIcon, 32, 32)).ToBitmap() }
  $name = New-Object System.Windows.Forms.Label; $name.Text = Get-Text 'AppName'; $name.Font = $fontName; $name.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#e8eef4')
  $name.AutoSize = $true; $name.Location = New-Object System.Drawing.Point($(if ($script:AppIcon) { 60 } else { 18 }), 19)
  $band.Controls.AddRange(@($logo, $name))
  $note = New-Object System.Windows.Forms.Label; $note.Text = Get-Text 'GateText'; $note.ForeColor = $muted
  $nh = $note.GetPreferredSize((New-Object System.Drawing.Size(($GW - 40), 0))).Height; $note.SetBounds(20, 80, $GW - 40, $nh + 4)
  $y = $note.Bottom + 12
  $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = Get-Text 'VaultCode'; $lbl.AutoSize = $true; $lbl.Location = New-Object System.Drawing.Point(20, ($y + 4))
  $box = New-Object System.Windows.Forms.TextBox; $box.UseSystemPasswordChar = $true; $box.SetBounds(170, $y, $GW - 190, 26); $y += 36
  $err = New-Object System.Windows.Forms.Label; $err.ForeColor = $red; $err.SetBounds(20, $y, $GW - 40, 40); $y += 44
  $ok = New-Object System.Windows.Forms.Button; $ok.Text = Get-Text 'VaultOpenOk'
  $no = New-Object System.Windows.Forms.Button; $no.Text = Get-Text 'GateExit'
  foreach ($b in @($ok, $no)) { $b.Height = 30; $b.Width = [Math]::Max(110, [System.Windows.Forms.TextRenderer]::MeasureText($b.Text, $font).Width + 28) }
  $no.Location = New-Object System.Drawing.Point(($GW - 20 - $no.Width), $y); $ok.Location = New-Object System.Drawing.Point(($no.Left - 8 - $ok.Width), $y)
  $no.DialogResult = 'Cancel'; $w.AcceptButton = $ok; $w.CancelButton = $no
  $w.Controls.AddRange(@($band, $note, $lbl, $box, $err, $ok, $no)); $w.ClientSize = New-Object System.Drawing.Size($GW, ($y + 48))
  # the wait after repeated wrong codes: the box and Open come back when it is over
  $wait = New-Object System.Windows.Forms.Timer; $wait.Interval = 1000
  $wait.Tag = @{ Left = 0 }
  $wait.add_Tick({ $wait.Tag.Left--; if ($wait.Tag.Left -le 0) { $wait.Stop(); $box.Enabled = $true; $ok.Enabled = $true; $err.Text = Get-Text 'GateWrong' $script:GateFailures; $box.Focus() }
    else { $err.Text = Get-Text 'GateWait' $script:GateFailures $wait.Tag.Left } })
  $ok.add_Click({
    $code = $box.Text; if (-not $code) { $box.Focus(); return }
    $err.ForeColor = $muted; $err.Text = Get-Text 'VaultOpening'; $w.Cursor = 'WaitCursor'; $w.Refresh()
    $good = $false; $why = $null
    try { $good = Open-Vault $code } catch { $why = $_.Exception.Message } finally { $w.Cursor = 'Default' }
    $err.ForeColor = $red
    if ($good) { $w.DialogResult = 'OK'; $w.Close(); return }
    if ($why) { $err.Text = Get-Text 'VaultNotReadable' $why; return }
    $script:GateFailures++; $box.Text = ''
    $d = Get-GateDelay $script:GateFailures
    if ($d) { $box.Enabled = $false; $ok.Enabled = $false; $wait.Tag.Left = $d; $err.Text = Get-Text 'GateWait' $script:GateFailures $d; $wait.Start() }
    else { $err.Text = Get-Text 'GateWrong' $script:GateFailures; $box.Focus() }
  })
  $w.add_Shown({ $w.Activate(); $box.Focus() })
  # docs: OTR_MANAGER_GATE_SHOT = <file.png>: the dialog drawn into the PNG (one wrong code typed), then closed
  if ($env:OTR_MANAGER_GATE_SHOT) { $w.add_Shown({ $err.Text = Get-Text 'GateWrong' 1; $w.Refresh()
    $bmp = New-Object System.Drawing.Bitmap($w.Width, $w.Height); $w.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $w.Width, $w.Height)))
    $bmp.Save($env:OTR_MANAGER_GATE_SHOT, [System.Drawing.Imaging.ImageFormat]::Png); $w.Close() }) }
  try { $w.ShowDialog() -eq 'OK' } finally { $wait.Stop(); $wait.Dispose(); $w.Dispose() }
}

# -Sign: only the access code, then LATEST.txt.sig next to the LATEST.txt given (the .cmd starts this hidden: the
# result in a message box too). Exit code 0 = signed, 1 = error, 2 = no code given.
if ($Sign) {
  $rc = 0
  try {
    if (-not (Test-Path -LiteralPath $Sign -PathType Leaf)) { throw (Get-Text 'SignNoFile' $Sign) }
    if (-not (Test-VaultFile)) { throw (Get-Text 'VaultMissing' $script:VaultFile) }
    if (-not (Show-CodeDialog 'Open')) { $rc = 2 }
    else {
      $r = Invoke-SignUpdate (Resolve-Path -LiteralPath $Sign).ProviderPath
      $m = Get-Text 'SignDone' $r.Version $r.Fingerprint (Get-Text "SignRole_$($r.Role)") $r.Signature
      if (-not $r.PackageChecked) { $m += "`r`n`r`n" + (Get-Text 'SignNoPackage') }
      [Console]::Out.WriteLine($m); Show-Message (Get-Text 'SignTitle') $m 'Information'
    }
  } catch {
    $rc = 1; [Console]::Error.WriteLine($_.Exception.Message); Show-Message (Get-Text 'SignTitle') $_.Exception.Message 'Error'
  } finally { Close-Vault }
  exit $rc
}

# The access code before anything else (Invoke-StartGate): no folder, no device, no window behind it. A screenshot opens
# the vault with OTR_MANAGER_VAULT_CODE instead, unless the tests give the codes to type (OTR_MANAGER_GATE_ANSWERS).
# Exit code 3 = closed at the access code.
Write-Trace 'access code asked'
$gateAnswers = if ($env:OTR_MANAGER_GATE_ANSWERS) { @($env:OTR_MANAGER_GATE_ANSWERS -split ';') } else { $null }
if (-not $env:OTR_MANAGER_SCREENSHOT -or $gateAnswers) {
  $gate = try { Invoke-StartGate $gateAnswers } catch { Show-Message (Get-Text 'GateTitle') (Get-Text 'VaultNotReadable' $_.Exception.Message) 'Error'; 'cancel' }
  if ($gateAnswers) { [Console]::Out.WriteLine("access code: $gate, $($script:GateFailures) wrong") }
  if ($gate -eq 'cancel') { Close-Vault; exit 3 }
}

# no default path: every installation has its own folder; the last one chosen is proposed
if (-not $Folder) {
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = Get-Text 'FolderDialog'
  $dlg.ShowNewFolderButton = $false
  $last = Get-LastFolder; if ($last) { $dlg.SelectedPath = $last }
  if ($dlg.ShowDialog() -ne 'OK' -or -not $dlg.SelectedPath) { return }
  $Folder = $dlg.SelectedPath
  Set-ManagementFolder $Folder
}
# the management folder not reachable (the file server down): the local copy, when there is one, after asking
$script:LocalMode = $false
$lcPath = Get-LocalCopyPath
if (-not (Test-Path -LiteralPath $script:Folder) -and $lcPath -and (Test-Path -LiteralPath (Join-Path $lcPath 'config')) -and $lcPath.TrimEnd('\') -ine $script:Folder.TrimEnd('\')) {
  if (Confirm-Action (Get-Text 'LocalTitle') (Get-Text 'LocalUseAsk' $script:Folder $lcPath (Get-LocalCopyAge $lcPath))) { Set-ManagementFolder $lcPath }
}
if ($lcPath -and $script:Folder.TrimEnd('\') -ieq $lcPath.TrimEnd('\')) { $script:LocalMode = $true }
Write-Trace 'folder chosen'
if (-not (Test-Path -LiteralPath $script:Folder)) {
  Show-Message (Get-Text 'FolderNotFoundTitle') (Get-Text 'FolderNotFoundText' $script:Folder) 'Error'
  return
}
if (-not (Test-Path -LiteralPath $script:StatusDir) -and -not (Test-Path -LiteralPath $script:ConfigDir)) {
  if (-not (Confirm-Action (Get-Text 'EmptyFolderTitle') (Get-Text 'EmptyFolderText' $script:Folder) 'Button2')) { return }
}
if (-not $env:OTR_MANAGER_SCREENSHOT) { Save-LastFolder $script:Folder }

# ---------------------------------------------------------------------------------------------
# Look: fonts, colours (the shell in the default top colour of the devices' sign-in screen), icons
# ---------------------------------------------------------------------------------------------
$fontBase = New-Object System.Drawing.Font('Segoe UI', 9.75)
$fontSmall = New-Object System.Drawing.Font('Segoe UI', 9)
$fontMono = New-Object System.Drawing.Font('Consolas', 9.75)
$fontBold = New-Object System.Drawing.Font('Segoe UI', 9.75, [System.Drawing.FontStyle]::Bold)
$fontSmallBold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$fontNav = New-Object System.Drawing.Font('Segoe UI', 10.5)
$fontApp = New-Object System.Drawing.Font('Segoe UI Semibold', 12.5)
$fontTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
$fontPageTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 13)

function New-Color([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
$script:Theme = @{
  Shell = New-Color '#1b2733'; ShellHover = New-Color '#25384a'; ShellSelected = New-Color '#2b4156'; ShellText = New-Color '#e8eef4'; ShellMuted = New-Color '#93a4b5'
  Accent = New-Color '#2563eb'; AccentDark = New-Color '#1d4ed8'; AccentSoft = New-Color '#dbeafe'
  Page = New-Color '#f3f5f8'; Card = New-Color '#ffffff'; Line = New-Color '#e2e6ec'; Text = New-Color '#1f2937'; Muted = New-Color '#6b7280'; Hover = New-Color '#f1f3f6'
  Section = New-Color '#eef2f7'; Own = New-Color '#fff7d6'; Managed = New-Color '#eaf1ff'
}
# state colours: strong (dot, text) and soft (background of the state label)
$script:KindColor = @{ ok = New-Color '#16a34a'; off = New-Color '#9ca3af'; error = New-Color '#dc2626'; warn = New-Color '#d97706'; info = New-Color '#2563eb' }
$script:KindSoft = @{ ok = New-Color '#dcfce7'; off = New-Color '#f1f2f4'; error = New-Color '#fee2e2'; warn = New-Color '#fef3c7'; info = New-Color '#dbeafe' }

# icons from the symbol font of Windows 10/11 (Segoe Fluent Icons on 11, Segoe MDL2 Assets on 10); without
# either the buttons show their text only
$script:IconFont = @('Segoe Fluent Icons', 'Segoe MDL2 Assets') | Where-Object { $n = $_; @([System.Drawing.FontFamily]::Families | Where-Object Name -eq $n).Count } | Select-Object -First 1
$script:Glyph = @{ Refresh = 'E72C'; Folder = 'E838'; Download = 'E896'; Shield = 'EA18'; Devices = 'E977'; Settings = 'E713'; Key = 'E8D7'; Warning = 'E7BA'
  Screen = 'E7F4'; Picture = 'E91B'; Save = 'E74E'; Undo = 'E7A7'; Delete = 'E74D'; Add = 'E710'; Search = 'E721'; Document = 'E8A5'
  Lock = 'E72E'; Unlock = 'E785'; Certificate = 'EB95'; Vpn = 'E705'
  History = 'E81C'; Desktop = 'E770'; Play = 'E768'; Power = 'E7E8'; Message = 'E8BD'; Contact = 'E77B'; Repair = 'E90F'; Unplug = 'E8CD'; Cancel = 'E711'
  Health = 'E95E'; Sync = 'E895'; Clock = 'E917'; Forward = 'E72A' }
function New-Glyph([string]$name, $color, [int]$size = 16) {
  if (-not $script:IconFont -or -not $script:Glyph.ContainsKey($name)) { return $null }
  $bmp = New-Object System.Drawing.Bitmap($size, $size)
  $g = [System.Drawing.Graphics]::FromImage($bmp); $g.TextRenderingHint = 'AntiAliasGridFit'
  $f = New-Object System.Drawing.Font($script:IconFont, [single]($size * 0.75), [System.Drawing.GraphicsUnit]::Pixel)
  $sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $br = New-Object System.Drawing.SolidBrush($color)
  $g.DrawString([string][char][Convert]::ToInt32($script:Glyph[$name], 16), $f, $br, (New-Object System.Drawing.RectangleF(0, 0, $size, $size)), $sf)
  $br.Dispose(); $sf.Dispose(); $f.Dispose(); $g.Dispose()
  $bmp
}
# the state dot of the device list; the height of the picture sets the height of the rows
function New-Dot($color, [int]$w = 16, [int]$h = 26) {
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'
  $br = New-Object System.Drawing.SolidBrush($color); $d = 10
  $g.FillEllipse($br, [single](($w - $d) / 2), [single](($h - $d) / 2), $d, $d)
  $br.Dispose(); $g.Dispose()
  $bmp
}

# Sizes from the texts, so that longer translations fit: a column is never narrower than its title or
# than the samples given (labels, placeholders), a button never narrower than its text.
function Get-TextWidth($text, $font = $fontBase) { [System.Windows.Forms.TextRenderer]::MeasureText([string]$text, $font).Width }
function Get-FitWidth($width, $texts, $font = $fontBase, $pad = 16) {
  foreach ($t in @($texts)) { $width = [Math]::Max($width, (Get-TextWidth $t $font) + $pad) }
  $width
}
function Measure-Note($text, $width, $font = $fontBase) {
  [System.Windows.Forms.TextRenderer]::MeasureText([string]$text, $font, (New-Object System.Drawing.Size([Math]::Max(50, $width), 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak).Height
}
# plain buttons of the small dialogs (logo, remote screen)
function New-Button($textKey, $minWidth, $height) {
  $b = New-Object System.Windows.Forms.Button; $b.Text = Get-Text $textKey; $b.Font = $fontBase
  $b.Size = New-Object System.Drawing.Size((Get-FitWidth $minWidth $b.Text -pad 20), $height)
  $b
}
# flat buttons of the window: primary (the one action of a page), secondary, danger (removes something),
# toolbar (on the dark top bar)
function New-ActionButton([string]$textKey, [string]$glyph = '', [string]$style = 'secondary') {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = Get-Text $textKey; $b.Font = $fontBase; $b.FlatStyle = 'Flat'; $b.Cursor = 'Hand'; $b.Height = 32; $b.UseVisualStyleBackColor = $false
  $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
  switch ($style) {
    'primary' { $b.BackColor = $Theme.Accent; $fg = [System.Drawing.Color]::White; $b.FlatAppearance.BorderColor = $Theme.Accent; $b.FlatAppearance.MouseOverBackColor = $Theme.AccentDark; $b.FlatAppearance.MouseDownBackColor = $Theme.AccentDark }
    'danger' { $b.BackColor = $Theme.Card; $fg = $script:KindColor.error; $b.FlatAppearance.BorderColor = New-Color '#f3c4c4'; $b.FlatAppearance.MouseOverBackColor = $script:KindSoft.error }
    'toolbar' { $b.BackColor = $Theme.Shell; $fg = $Theme.ShellText; $b.FlatAppearance.BorderSize = 0; $b.FlatAppearance.MouseOverBackColor = $Theme.ShellHover; $b.FlatAppearance.MouseDownBackColor = $Theme.ShellSelected }
    default { $b.BackColor = $Theme.Card; $fg = $Theme.Text; $b.FlatAppearance.BorderColor = New-Color '#cfd5dd'; $b.FlatAppearance.MouseOverBackColor = $Theme.Hover }
  }
  $b.ForeColor = $fg
  $img = if ($glyph) { New-Glyph $glyph $fg 16 } else { $null }
  if ($img) { $b.Image = $img; $b.ImageAlign = 'MiddleLeft'; $b.TextImageRelation = 'ImageBeforeText'; $b.Padding = New-Object System.Windows.Forms.Padding(8, 0, 6, 0) }
  $b.Width = (Get-TextWidth $b.Text) + $(if ($img) { 50 } else { 30 })
  $b
}
function New-Panel($dock, $back, [int]$height = 0, [int]$width = 0) {
  $p = New-Object System.Windows.Forms.Panel; $p.Dock = $dock; if ($back) { $p.BackColor = $back }
  if ($height) { $p.Height = $height }; if ($width) { $p.Width = $width }
  $p
}
function New-Label([string]$text, $font = $fontBase, $color = $null) {
  $l = New-Object System.Windows.Forms.Label; $l.Text = $text; $l.Font = $font; $l.AutoSize = $true
  $l.ForeColor = if ($color) { $color } else { $Theme.Text }; $l.BackColor = [System.Drawing.Color]::Transparent
  $l
}
# a thin line on one side of a panel
function Add-Line($p, [string]$side = 'Top') {
  $p.Tag = @{ Line = $side }
  $p.add_Paint({ param($s, $e)
    $pen = New-Object System.Drawing.Pen($Theme.Line)
    switch ($s.Tag.Line) {
      'Top' { $e.Graphics.DrawLine($pen, 0, 0, $s.Width, 0) }
      'Bottom' { $e.Graphics.DrawLine($pen, 0, $s.Height - 1, $s.Width, $s.Height - 1) }
      'Box' { $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width - 1, $s.Height - 1) }
    }
    $pen.Dispose() })
}
# search boxes with a grey hint inside (EM_SETCUEBANNER)
if (-not ('OtrNative' -as [type])) {
  Add-OtrType -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class OtrNative { [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, string l);
  [StructLayout(LayoutKind.Sequential)] public struct LVGROUP { public int cbSize; public int mask; public IntPtr pszHeader; public int cchHeader; public IntPtr pszFooter; public int cchFooter; public int iGroupId; public int stateMask; public int state; public int uAlign; }
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, ref LVGROUP l);
  /* a group of a ListView that the user can collapse (LVM_SETGROUPINFO, LVGS_COLLAPSIBLE) */
  public static void Collapsible(IntPtr lv, int id) { LVGROUP g = new LVGROUP(); g.cbSize = Marshal.SizeOf(g); g.mask = 4; g.iGroupId = id; g.stateMask = 8; g.state = 8; SendMessage(lv, 0x1093, (IntPtr)id, ref g); } }'
}
function New-SearchBox([string]$cueKey, [int]$width) {
  $t = New-Object System.Windows.Forms.TextBox; $t.Font = $fontBase; $t.Width = $width; $t.Tag = Get-Text $cueKey
  $t.add_HandleCreated({ param($s, $e) [void][OtrNative]::SendMessage($s.Handle, 0x1501, [IntPtr]1, [string]$s.Tag) })
  $t
}
# a bar of buttons: left = the actions of the page, right = the one that removes something. On a narrow window the
# buttons wrap to a second line and the bar grows, instead of running out of the window.
function New-ActionBar($left, $right = @()) {
  $p = New-Panel 'Bottom' $Theme.Card 56; Add-Line $p 'Top'
  $p.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 10)
  # placed by Set-FlowHeight (not docked): docked, a tab page left it at the old height when the bar grew
  $fl = New-Object System.Windows.Forms.FlowLayoutPanel; $fl.WrapContents = $true; $fl.BackColor = $Theme.Card
  foreach ($b in $left) { if ($b -is [System.Windows.Forms.Button]) { $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 8) }; $fl.Controls.Add($b) }
  $p.Controls.Add($fl)
  if (@($right).Count) {
    $fr = New-Object System.Windows.Forms.FlowLayoutPanel; $fr.Dock = 'Right'; $fr.AutoSize = $true; $fr.WrapContents = $false; $fr.FlowDirection = 'RightToLeft'; $fr.BackColor = $Theme.Card
    foreach ($b in $right) { $b.Margin = New-Object System.Windows.Forms.Padding(8, 0, 0, 0); $fr.Controls.Add($b) }
    $p.Controls.Add($fr)
  }
  $p.Tag = @{ Line = 'Top'; Flow = $fl; Right = $fr }
  # The buttons are placed when the bar lays itself out; its height is changed only once the window has finished
  # laying itself out (Request-BarFit): changed in the middle, the container keeps the bar where the old height put
  # it and the second row ends up out of the window.
  [void]$script:Bars.Add($p)
  $p.add_Layout({ param($s, $e) [void](Set-FlowHeight $s); Request-BarFit })
  $p
}
# the height the controls of a wrapping flow need at a width: counted here, row by row, as the flow places them
function Get-FlowHeight($fl, [int]$width) {
  $x = 0; $rows = 0; $row = 0; $total = 0
  foreach ($c in $fl.Controls) {
    if (-not $c.Visible -and $c.Parent.Visible) { continue }
    $w = $c.Width + $c.Margin.Horizontal; $h = $c.Height + $c.Margin.Vertical
    if ($rows -eq 0) { $rows = 1 }
    elseif ($x + $w -gt $width -and $x -gt 0) { $total += $row; $row = 0; $x = 0; $rows++ }
    $x += $w; $row = [Math]::Max($row, $h)
  }
  $total + $row
}
# A bar of buttons: its left buttons placed in the room the right ones leave, on as many rows as they need, and
# the bar as high as those rows
# places the buttons of a bar; $true = the bar needs another height (Request-BarFit sets it)
function Set-FlowHeight($bar) {
  $fl = $bar.Tag.Flow; if (-not $fl) { return $false }
  $pad = $bar.Padding
  # the button on the right keeps only its icon when, with its text, the widest button on the left would not fit
  if ($bar.Tag.Right) {
    $rb = @($bar.Tag.Right.Controls)
    $widest = (@($fl.Controls | ForEach-Object { $_.Width + $_.Margin.Horizontal }) + 0 | Measure-Object -Maximum).Maximum
    $compact = ($bar.ClientSize.Width - $pad.Horizontal - (Get-FullWidth $rb) - 8) -lt $widest
    if ($compact -ne [bool]$bar.Tag.RightCompact) { $bar.Tag.RightCompact = $compact; Set-CompactButtons $rb $compact; $bar.Tag.Right.PerformLayout() }
  }
  $right = if ($bar.Tag.Right) { $bar.Tag.Right.Width + 8 } else { 0 }
  $w = $bar.ClientSize.Width - $pad.Horizontal - $right; if ($w -lt 50) { return $false }
  $h = Get-FlowHeight $fl $w
  $fl.SetBounds($pad.Left, $pad.Top, $w, [Math]::Max(34, $h))
  $bar.Tag.Need = [Math]::Max(56, $h + $pad.Vertical - 8)
  $bar.Height -ne $bar.Tag.Need
}
$script:Bars = New-Object System.Collections.ArrayList
$script:BarFitPending = $false
function Request-BarFit {
  if ($script:BarFitPending -or -not $form.IsHandleCreated) { return }
  $script:BarFitPending = $true
  [void]$form.BeginInvoke([System.Windows.Forms.MethodInvoker]{
    $script:BarFitPending = $false
    foreach ($b in $script:Bars) {
      if ($b.Tag.Need -and $b.Height -ne $b.Tag.Need) { $b.Height = $b.Tag.Need; if ($b.Parent) { $b.Parent.PerformLayout() } }
    }
  })
}
# Buttons that keep only their icon when the room is short (their text becomes the tooltip): the top bar and the
# actions of a device. Buttons without an icon (no symbol font) keep their text.
function Set-CompactButtons($buttons, [bool]$compact) {
  foreach ($b in $buttons) {
    if (-not ($b.Tag -is [hashtable]) -or -not $b.Tag.ContainsKey('Full')) { $b.Tag = @{ Full = $b.Text; Width = $b.Width; Tip = $tips.GetToolTip($b); Pad = $b.Padding } }
    if (-not $b.Image) { continue }
    if ($compact) { $b.Text = ''; $b.Width = 40; $b.Padding = New-Object System.Windows.Forms.Padding(12, 0, 0, 0); $tips.SetToolTip($b, $(if ($b.Tag.Tip) { "$($b.Tag.Full): $($b.Tag.Tip)" } else { $b.Tag.Full })) }
    else { $b.Text = $b.Tag.Full; $b.Width = $b.Tag.Width; $b.Padding = $b.Tag.Pad; $tips.SetToolTip($b, $b.Tag.Tip) }
  }
}
function Get-FullWidth($buttons) { $w = 0; foreach ($b in $buttons) { $w += $(if ($b.Tag -is [hashtable] -and $b.Tag.ContainsKey('Width')) { $b.Tag.Width } else { $b.Width }) + $b.Margin.Horizontal }; $w }
# title and explanation on top of a page; the explanation wraps and the header grows with it
function New-PageHeader([string]$title, [string]$text) {
  $p = New-Panel 'Top' $Theme.Page 80
  $p.Padding = New-Object System.Windows.Forms.Padding(16, 12, 16, 10)
  $t = New-Label $title $fontPageTitle; $t.AutoSize = $false; $t.Dock = 'Top'; $t.Height = 32
  $n = New-Label $text $fontBase $Theme.Muted; $n.AutoSize = $false; $n.Dock = 'Fill'
  $p.Controls.Add($n); $p.Controls.Add($t)
  $p.Tag = @{ Note = $n }
  # the height from the Layout event of the page: it runs before the page arranges its docked children
  $p.add_ParentChanged({ param($q, $e)
    if ($q.Parent) { $q.Parent.add_Layout({ param($c, $e)
      foreach ($h in $c.Controls) { if ($h.Tag -is [hashtable] -and $h.Tag.ContainsKey('Note')) {
        $need = 12 + 32 + (Measure-Note $h.Tag.Note.Text ($c.DisplayRectangle.Width - 32)) + 12
        if ($h.Height -ne $need) { $h.Height = $need } } } }) } })
  $p
}
# the help of the selected setting, under a settings grid
function New-HelpPanel([string]$default) {
  $p = New-Panel 'Bottom' $Theme.Page 104; Add-Line $p 'Top'
  $p.Padding = New-Object System.Windows.Forms.Padding(14, 8, 14, 6)
  $t = New-Label '' $fontBold; $t.AutoSize = $false; $t.Dock = 'Top'; $t.Height = 22; $t.Visible = $false
  $b = New-Label $default $fontBase $Theme.Muted; $b.AutoSize = $false; $b.Dock = 'Fill'
  $p.Controls.Add($b); $p.Controls.Add($t)
  $p.Tag = @{ Line = 'Top'; Title = $t; Body = $b; Default = $default }
  # on a low window the help gives its room to the list: at most a fifth of the page, from 60 to 104 points
  $p.add_ParentChanged({ param($q, $e)
    if ($q.Parent) { $q.Parent.add_SizeChanged({ param($c, $e)
      foreach ($h in $c.Controls) { if ($h.Tag -is [hashtable] -and $h.Tag.ContainsKey('Body')) {
        $need = [Math]::Max(60, [Math]::Min(104, [int]($c.ClientSize.Height / 5)))
        if ($h.Height -ne $need) { $h.Height = $need } } } }) } })
  $p
}
function Show-Help($panel, $s) {
  # nothing selected: no empty title line, the whole room to the text
  $panel.Tag.Title.Visible = [bool]$s
  if ($s) { $panel.Tag.Title.Text = "$($s.Label)   $([char]0x00B7)   $($s.Key)"; $panel.Tag.Body.Text = $s.Help; $panel.Tag.Body.ForeColor = $Theme.Text }
  else { $panel.Tag.Title.Text = ''; $panel.Tag.Body.Text = $panel.Tag.Default; $panel.Tag.Body.ForeColor = $Theme.Muted }
}

# ---------------------------------------------------------------------------------------------
# The window: dark bar on top (folder actions), pages on the left, status bar
# ---------------------------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form; Set-WindowIcon $form
$form.Text = (Get-Text 'WindowTitle' $script:Folder) + $(if ($script:LocalMode) { ' ' + (Get-Text 'LocalModeTitle') } else { '' })
# small enough for a laptop with display scaling: the bars wrap and the buttons keep only their icons
$form.MinimumSize = New-Object System.Drawing.Size(860, 560)
$form.StartPosition = 'CenterScreen'
$form.Font = $fontBase; $form.BackColor = $Theme.Page
# 85% of the screen it opens on, at least 1440x880: a large screen gives the lists their room; a screen smaller than
# that gets the window maximized
$wa = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
$form.Size = New-Object System.Drawing.Size([Math]::Max(1440, [int]($wa.Width * 0.85)), [Math]::Max(880, [int]($wa.Height * 0.85)))
if ($wa.Width -lt $form.Width -or $wa.Height -lt $form.Height) { $form.WindowState = 'Maximized' }
# The columns of a list share its width: each as wide as its title and samples need while there is room, all of
# them narrower in proportion when there is not (never behind a horizontal scroll bar); the last takes the rest.
# The first column (the name) keeps its width as long as it can: the others give up their room first.
function Set-ListFit($lv) {
  $ideal = @($lv.Tag.Ideal); if ($ideal.Count -ne $lv.Columns.Count -or $lv.ClientSize.Width -lt 100) { return }
  $avail = $lv.ClientSize.Width - 8; $total = ($ideal | Measure-Object -Sum).Sum
  $first = [Math]::Min($ideal[0], [int]($avail * 0.4)); $rest = $total - $ideal[0]
  $scale = if ($total -gt $avail) { [Math]::Max(0.1, ($avail - $first) / $rest) } else { 1 }
  if ($scale -eq 1) { $first = $ideal[0] }
  # inside Begin/EndUpdate: the list works out its scroll bar again (it keeps a stale horizontal one otherwise)
  $lv.BeginUpdate()
  try {
    $lv.Columns[0].Width = $first; $used = $first
    for ($k = 1; $k -lt $ideal.Count - 1; $k++) { $w = [Math]::Max(30, [int]($ideal[$k] * $scale)); $lv.Columns[$k].Width = $w; $used += $w }
    $lv.Columns[$ideal.Count - 1].Width = [Math]::Max(30, $avail - $used)
  } finally { $lv.EndUpdate() }
}

$root = New-Panel 'Fill' $Theme.Page
$bar = New-Object System.Windows.Forms.StatusStrip
$bar.BackColor = $Theme.Card; $bar.SizingGrip = $false; $bar.Font = $fontSmall
$barText = New-Object System.Windows.Forms.ToolStripStatusLabel
$barText.Spring = $true; $barText.TextAlign = 'MiddleLeft'; $barText.ForeColor = $Theme.Muted
[void]$bar.Items.Add($barText)

# top bar: name, folder, actions on the folder
$header = New-Panel 'Top' $Theme.Shell 56
# the logo before the name (the same icon, 32 pixels)
$picLogo = New-Object System.Windows.Forms.PictureBox; $picLogo.SetBounds(16, 12, 32, 32); $picLogo.SizeMode = 'Zoom'; $picLogo.BackColor = $Theme.Shell
if ($script:AppIcon) { $picLogo.Image = (New-Object System.Drawing.Icon($script:AppIcon, 32, 32)).ToBitmap() } else { $picLogo.Visible = $false }
$lblApp = New-Label (Get-Text 'AppName') $fontApp $Theme.ShellText; $lblApp.Location = New-Object System.Drawing.Point($(if ($picLogo.Visible) { 56 } else { 18 }), 15)
$lblFolder = New-Label $script:Folder $fontSmall $Theme.ShellMuted; $lblFolder.Location = New-Object System.Drawing.Point(($lblApp.Left + (Get-TextWidth $lblApp.Text $fontApp) + 14), 21)
$tools = New-Object System.Windows.Forms.FlowLayoutPanel; $tools.Dock = 'Right'; $tools.AutoSize = $true; $tools.WrapContents = $false
$tools.FlowDirection = 'RightToLeft'; $tools.BackColor = $Theme.Shell; $tools.Padding = New-Object System.Windows.Forms.Padding(0, 12, 10, 0)
$btnPerm = New-ActionButton 'BtnCheckPermissions' 'Shield' 'toolbar'
$btnRelease = New-ActionButton 'BtnImportRelease' 'Download' 'toolbar'
$btnOpen = New-ActionButton 'BtnOpenFolder' 'Folder' 'toolbar'
$btnRefresh = New-ActionButton 'BtnRefresh' 'Refresh' 'toolbar'
$btnVaultTool = New-ActionButton 'VaultToolClosed' 'Lock' 'toolbar'
$btnVaultTool.Width = (@('VaultToolClosed', 'VaultToolOpen', 'VaultToolNone') | ForEach-Object { Get-TextWidth (Get-Text $_) } | Measure-Object -Maximum).Maximum + 50
# a newer manager in the latest release (checked in the background at the start): shown only then
$btnMgrNotice = New-ActionButton 'MgrAvailable' 'Download' 'toolbar'; $btnMgrNotice.Visible = $false; $btnMgrNotice.ForeColor = New-Color '#fcd34d'
$btnMgrNotice.Image = New-Glyph 'Download' (New-Color '#fcd34d') 16
foreach ($b in @($btnMgrNotice, $btnVaultTool, $btnPerm, $btnRelease, $btnOpen, $btnRefresh)) { $b.Margin = New-Object System.Windows.Forms.Padding(4, 0, 0, 0); $tools.Controls.Add($b) }
$tips = New-Object System.Windows.Forms.ToolTip
$tips.SetToolTip($btnRefresh, (Get-Text 'NoteDevices')); $tips.SetToolTip($lblFolder, $script:Folder)
$header.Controls.AddRange(@($picLogo, $lblApp, $lblFolder, $tools))
# a long folder path ends with ... before the actions
$lblFolder.AutoSize = $false; $lblFolder.AutoEllipsis = $true; $lblFolder.Height = 20
# the actions on the folder keep only their icons when the window is too narrow for their text
$script:ToolbarCompact = $false
function Set-ToolbarFit {
  $buttons = @($btnMgrNotice, $btnVaultTool, $btnPerm, $btnRelease, $btnOpen, $btnRefresh | Where-Object Visible)
  $compact = (Get-FullWidth $buttons) + 10 -gt ($header.ClientSize.Width - $lblApp.Right - 24 - 120)
  if ($compact -ne $script:ToolbarCompact) { $script:ToolbarCompact = $compact; Set-CompactButtons $buttons $compact }
  $lblFolder.Width = [Math]::Max(40, $header.ClientSize.Width - $tools.Width - $lblFolder.Left - 16)
}
$header.add_Resize({ Set-ToolbarFit })

# pages on the left: a dark column, the selected page marked by a line in the accent colour
$nav = New-Panel 'Left' $Theme.Shell 0 210
$nav.Padding = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
$content = New-Panel 'Fill' $Theme.Page
$script:Page = 0; $script:NavButtons = @(); $script:Pages = @()
function New-NavButton([string]$textKey, [string]$glyph, [int]$index) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = '  ' + (Get-Text $textKey); $b.Font = $fontNav; $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0; $b.Cursor = 'Hand'
  $b.Dock = 'Top'; $b.Height = 46; $b.TextAlign = 'MiddleLeft'; $b.ForeColor = $Theme.ShellText; $b.BackColor = $Theme.Shell; $b.UseVisualStyleBackColor = $false
  $b.FlatAppearance.MouseOverBackColor = $Theme.ShellHover; $b.FlatAppearance.MouseDownBackColor = $Theme.ShellSelected
  $b.Padding = New-Object System.Windows.Forms.Padding(18, 0, 0, 0)
  $img = New-Glyph $glyph $Theme.ShellText 18
  if ($img) { $b.Image = $img; $b.ImageAlign = 'MiddleLeft'; $b.TextImageRelation = 'ImageBeforeText' }
  $b.Tag = @{ Index = $index; Count = '' }
  $b.add_Paint({ param($s, $e)
    if ($s.Tag.Index -eq $script:Page) { $br = New-Object System.Drawing.SolidBrush($Theme.Accent); $e.Graphics.FillRectangle($br, 0, 8, 4, $s.Height - 16); $br.Dispose() }
    if ($s.Tag.Count) {
      # only icons: the count small in the top right corner, off the icon
      $r = if ($script:NavCompact) { New-Object System.Drawing.Rectangle(0, 3, ($s.Width - 5), 18) } else { New-Object System.Drawing.Rectangle(0, 0, ($s.Width - 16), $s.Height) }
      # a count in a colour of its own: who cannot sign in now, problems of the servers
      $cc = if ($s.Tag.ContainsKey('CountColor') -and $s.Tag.CountColor) { $s.Tag.CountColor } else { $Theme.ShellMuted }
      [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$s.Tag.Count, $fontSmall, $r, $cc, [System.Windows.Forms.TextFormatFlags]$(if ($script:NavCompact) { 'Right, Top' } else { 'Right, VerticalCenter' }))
    } })
  $b.add_Click({ param($s, $e) Select-Page $s.Tag.Index })
  $b
}
$navDevices = New-NavButton 'NavDevices' 'Devices' 0
$navCommon = New-NavButton 'NavCommon' 'Settings' 1
$navKeys = New-NavButton 'NavKeys' 'Key' 2
$navProblems = New-NavButton 'NavProblems' 'History' 3
$navVault = New-NavButton 'NavVault' 'Lock' 4
$navUpdates = New-NavButton 'NavUpdates' 'Download' 5
# the Windows side of the desktops: index 6, so the other pages keep theirs (OTR_MANAGER_TAB of the screenshots)
$navDesktops = New-NavButton 'NavDesktops' 'Desktop' 6
# the Health Center (the servers behind the desktops): index 7
$navHealth = New-NavButton 'NavHealth' 'Health' 7
$script:NavButtons = @($navDevices, $navCommon, $navKeys, $navProblems, $navVault, $navUpdates, $navDesktops, $navHealth)
# Dock Top stacks the last added on top; the desktops under the devices and the Health Center under them, the vault next
# to the SSH keys, the versions after the settings
# the SSH keys of the devices are on the Vault page: their button stays out of the menu (index 2 leads there)
foreach ($b in @($navProblems, $navVault, $navUpdates, $navCommon, $navHealth, $navDevices)) { $nav.Controls.Add($b) }
# on a narrow window (a small laptop, a foldable) the column keeps only its icons, the names in the tooltips
$script:NavCompact = $false
function Set-NavFit([int]$width) {
  $c = $width -gt 0 -and $width -lt 1200
  if ($c -eq $script:NavCompact) { return }
  $script:NavCompact = $c; $nav.Width = $(if ($c) { 64 } else { 210 })
  foreach ($b in $script:NavButtons) {
    if (-not $b.Tag.ContainsKey('Label')) { $b.Tag.Label = $b.Text }
    $b.Text = $(if ($c) { '' } else { $b.Tag.Label }); $b.Padding = New-Object System.Windows.Forms.Padding($(if ($c) { 22 } else { 18 }), 0, 0, 0)
    $tips.SetToolTip($b, $(if ($c) { $b.Tag.Label.Trim() } else { '' }))
  }
}

# ---------------- Devices page: list | selected device ----------------
$pageDevices = New-Panel 'Fill' $Theme.Page
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'; $split.Orientation = 'Vertical'; $split.BackColor = $Theme.Page; $split.SplitterWidth = 10
$split.Panel1.Padding = New-Object System.Windows.Forms.Padding(12, 12, 0, 12); $split.Panel2.Padding = New-Object System.Windows.Forms.Padding(0, 12, 12, 12)
$split.FixedPanel = 'Panel1'
# the list takes about 40% of the width, between 260 and 500 points: on a narrow window the device keeps its room
function Set-SplitFit {
  $w = $split.Width; if ($w -lt 300) { return }
  $d = [Math]::Min(500, [Math]::Max(260, [int]($w * 0.4)))
  if ($w - $d -lt 360) { $d = [Math]::Max(220, $w - 360) }
  if ($split.SplitterDistance -ne $d) { $split.SplitterDistance = $d }
}
$split.add_SizeChanged({ Set-SplitFit })

# list card: search, counts, the list, a note on how often it changes
$listCard = New-Panel 'Fill' $Theme.Card; Add-Line $listCard 'Box'; $listCard.Padding = New-Object System.Windows.Forms.Padding(1)
$listTop = New-Panel 'Top' $Theme.Card 98
$txtDevSearch = New-SearchBox 'SearchDevices' 200; $txtDevSearch.Location = New-Object System.Drawing.Point(12, 12); $txtDevSearch.Anchor = 'Top, Left, Right'
$lblDevCount = New-Label '' $fontSmall $Theme.Muted; $lblDevCount.Location = New-Object System.Drawing.Point(12, 46)
# the groups in sight, on a line of their own under the count: a new group, and the groups (the same as the right click on the list)
$lnkNewGroup = New-Object System.Windows.Forms.LinkLabel; $lnkNewGroup.Text = '+ ' + (Get-Text 'GroupsNew'); $lnkNewGroup.AutoSize = $true; $lnkNewGroup.Font = $fontSmallBold; $lnkNewGroup.Anchor = 'Top, Left'
$lnkGroups = New-Object System.Windows.Forms.LinkLabel; $lnkGroups.Text = Get-Text 'GroupsManage'; $lnkGroups.AutoSize = $true; $lnkGroups.Font = $fontSmall; $lnkGroups.Anchor = 'Top, Left'
foreach ($l in $lnkNewGroup, $lnkGroups) { $l.LinkColor = $Theme.Accent; $l.ActiveLinkColor = $Theme.Accent; $l.LinkBehavior = 'HoverUnderline' }
$listTop.Controls.AddRange(@($txtDevSearch, $lblDevCount, $lnkNewGroup, $lnkGroups))
$listTop.add_Resize({ param($s, $e) $txtDevSearch.Width = [Math]::Max(80, $s.ClientSize.Width - 24)
  $lnkNewGroup.Location = New-Object System.Drawing.Point(12, 72)
  $lnkGroups.Location = New-Object System.Drawing.Point(($lnkNewGroup.Left + $lnkNewGroup.PreferredWidth + 18), 72) })
$lnkNewGroup.add_LinkClicked({ $miNewGroup.PerformClick() })
$lnkGroups.add_LinkClicked({ Show-GroupsDialog })

$imgDots = New-Object System.Windows.Forms.ImageList; $imgDots.ColorDepth = 'Depth32Bit'; $imgDots.ImageSize = New-Object System.Drawing.Size(16, 26)
foreach ($k in @('ok', 'off', 'error', 'warn', 'info')) { $imgDots.Images.Add($k, (New-Dot $script:KindColor[$k])) }
$list = New-Object System.Windows.Forms.ListView
$list.Dock = 'Fill'; $list.View = 'Details'; $list.FullRowSelect = $true; $list.MultiSelect = $false; $list.HideSelection = $false
$list.BorderStyle = 'None'; $list.SmallImageList = $imgDots; $list.ShowItemToolTips = $true; $list.Font = $fontBase
# the last column takes the rest of the width: no horizontal scroll bar for a few pixels
$list.add_Resize({ param($s, $e) Set-ListFit $s })
$list.Tag = @{ Ideal = @() }
foreach ($c in @(@('ColDevice', 105), @('ColState', 110), @('ColUser', 80), @('ColVersion', 52), @('ColLastReport', 64))) {
  # room for the sort arrow too
  $title = Get-Text $c[0]; $w = Get-FitWidth $c[1] "$title $([char]0x25B2)" -pad 14
  # a pilot device says so after its version
  if ($c[0] -eq 'ColVersion') { $w = Get-FitWidth $w (Get-Text 'ListPilot' '0.2.0') -pad 14 }
  [void]$list.Columns.Add($title, $w); $list.Tag.Ideal += $w
}
# click on a header = sort by that column, second click = reverse; the arrow shows which.
# The chosen order stays when the list refreshes by itself.
$script:Sorter = New-Object OtrColumnSorter
$script:Sorter.Column = 0; $script:Sorter.NameColumn = 0
$script:Titles = @($list.Columns | ForEach-Object { $_.Text })
function Show-SortMark {
  for ($k = 0; $k -lt $list.Columns.Count; $k++) {
    $list.Columns[$k].Text = if ($k -eq $script:Sorter.Column) { $script:Titles[$k] + ' ' + $(if ($script:Sorter.Descending) { [char]0x25BC } else { [char]0x25B2 }) } else { $script:Titles[$k] }
  }
}
$list.ListViewItemSorter = $script:Sorter
$list.add_ColumnClick({ param($s, $e)
  if ($script:Sorter.Column -eq $e.Column) { $script:Sorter.Descending = -not $script:Sorter.Descending } else { $script:Sorter.Column = $e.Column; $script:Sorter.Descending = $false }
  $list.Sort(); Show-SortMark
  if ($list.SelectedItems.Count) { $list.SelectedItems[0].EnsureVisible() } })
Show-SortMark
$lblListNote = New-Label (Get-Text 'NoteDevices') $fontSmall $Theme.Muted; $lblListNote.AutoSize = $false; $lblListNote.Dock = 'Bottom'; $lblListNote.Height = 46
$lblListNote.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 4); $lblListNote.BackColor = $Theme.Card
# The devices as a tree, as in the Health Center: the site, its groups, the devices, each with the dot of its state (a
# group: the worst of its devices). $list stays behind it, unseen: search, order and the refresh work on it as before.
$tvDev = New-Object System.Windows.Forms.TreeView
$tvDev.Dock = 'Fill'; $tvDev.BorderStyle = 'None'; $tvDev.Font = $fontBase; $tvDev.HideSelection = $false; $tvDev.FullRowSelect = $true; $tvDev.ShowLines = $false
$tvDev.ItemHeight = 26; $tvDev.ShowNodeToolTips = $true; $tvDev.BackColor = $Theme.Card; $tvDev.ForeColor = $Theme.Text
$imgDevDots = New-Object System.Windows.Forms.ImageList; $imgDevDots.ColorDepth = 'Depth32Bit'; $imgDevDots.ImageSize = New-Object System.Drawing.Size(16, 22)
foreach ($k in @('ok', 'off', 'error', 'warn', 'info')) { $imgDevDots.Images.Add($k, (New-Dot $script:KindColor[$k] 16 22)) }
$tvDev.ImageList = $imgDevDots
$tvDev.add_AfterSelect({ param($s, $e) if (-not $script:Listing) { Show-TreeNode $e.Node } })
# the site (Tag '') or a group (its name): its settings in place of the device; a device: its settings as before
function Show-TreeNode($node) {
  if (-not $node) { return }
  if ($node.Tag -is [string]) {
    $script:ScopeGroup = $node.Tag
    $lblScope.Text = if ($node.Tag) { Get-Text 'ScopeGroup' $node.Tag (Get-SiteName) } else { Get-Text 'ScopeSite' (Get-SiteName) }
    $lblComNote.Text = if ($node.Tag) { Get-Text 'ScopeGroupNote' (Get-SiteName) } else { Get-Text 'PageCommonNote' (Get-Text 'ColManagedHere') }
    $gridCom.Columns[1].HeaderText = if ($node.Tag) { Get-Text 'ColValueGroup' } else { Get-Text 'ColValueAll' }
    $btnBrandCom.Visible = -not $node.Tag
    Update-CommonGrid; $devCard.Visible = $false; $scopeWrap.Visible = $true; $scopeWrap.BringToFront()
  } else {
    $script:ScopeGroup = ''; $scopeWrap.Visible = $false; $devCard.Visible = $true; $devCard.BringToFront(); Show-Device $node.Tag
  }
}
$tvDev.add_NodeMouseClick({ param($s, $e) if ($e.Button -eq 'Right') { $tvDev.SelectedNode = $e.Node } })
function Get-WorstKind($kinds) { foreach ($k in 'error', 'warn', 'ok', 'info') { if (@($kinds) -contains $k) { return $k } }; 'off' }
$listCard.Controls.Add($tvDev); $listCard.Controls.Add($lblListNote); $listCard.Controls.Add($listTop)
$split.Panel1.Controls.Add($listCard)

# selected device: header (name, state, address, version, last report, session) with its actions
$devCard = New-Panel 'Fill' $Theme.Card; Add-Line $devCard 'Box'; $devCard.Padding = New-Object System.Windows.Forms.Padding(1)
$devHead = New-Panel 'Top' $Theme.Card 136; Add-Line $devHead 'Bottom'
$lblDevName = New-Label '' $fontTitle; $lblDevName.Location = New-Object System.Drawing.Point(18, 12)
$lblDevState = New-Label '' $fontSmallBold; $lblDevState.Padding = New-Object System.Windows.Forms.Padding(8, 3, 8, 3); $lblDevState.Visible = $false
$lblDevInfo = New-Label '' $fontBase $Theme.Muted; $lblDevInfo.Location = New-Object System.Drawing.Point(20, 56)
# the actions on a line of their own under the address, always with their text: on a narrow window they wrap, they
# never cover the name or the state
$devActions = New-Object System.Windows.Forms.FlowLayoutPanel; $devActions.AutoSize = $true; $devActions.AutoSizeMode = 'GrowAndShrink'; $devActions.WrapContents = $true
$devActions.FlowDirection = 'LeftToRight'; $devActions.BackColor = $Theme.Card
$btnRemoteDev = New-ActionButton 'BtnRemoteScreen' 'Screen' 'primary'
$btnBrandDev = New-ActionButton 'BtnBranding' 'Picture' 'secondary'
# only on a device with VPN=openvpn: its profile does not go through the folder
$btnVpnDev = New-ActionButton 'BtnVpnProfile' 'Vpn' 'secondary'; $btnVpnDev.Visible = $false
# only on a device with 802.1X (cable, or Wi-Fi Enterprise): its certificate and password do not go through the folder
$btnDot1xDev = New-ActionButton 'BtnDot1x' 'Certificate' 'secondary'; $btnDot1xDev.Visible = $false
# which version it installs: like all devices, pilot, or one of its own
$btnTrackDev = New-ActionButton 'BtnDeviceVersion' 'Download' 'secondary'
# power on (Wake-on-LAN), restart, switch off, report now, a command: one button with its menu
$btnPowerDev = New-ActionButton 'BtnDevicePower' 'Power' 'secondary'
$mnuPower = New-Object System.Windows.Forms.ContextMenuStrip; $mnuPower.Font = $fontBase
foreach ($k in 'wake', 'reboot', 'poweroff', 'report', 'command') { $it = $mnuPower.Items.Add((Get-Text "PwrMenu_$k")); $it.Tag = $k; $it.add_Click({ param($s, $e) if ($script:Selected) { Invoke-DeviceAction $script:Selected $s.Tag } }) }
$btnPowerDev.add_Click({ $mnuPower.Show($btnPowerDev, (New-Object System.Drawing.Point(0, $btnPowerDev.Height))) })
# its group: which one it is in, and moving it to another
$btnGroupDev = New-ActionButton 'BtnDeviceGroup' 'Folder' 'secondary'
foreach ($b in @($btnRemoteDev, $btnPowerDev, $btnTrackDev, $btnGroupDev, $btnBrandDev, $btnVpnDev, $btnDot1xDev)) { $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 8); $devActions.Controls.Add($b) }
$tips.SetToolTip($btnRemoteDev, (Get-Text 'TipRemoteScreen')); $tips.SetToolTip($btnVpnDev, (Get-Text 'TipVpnProfile')); $tips.SetToolTip($btnTrackDev, (Get-Text 'TipDeviceVersion'))
$tips.SetToolTip($btnDot1xDev, (Get-Text 'TipDot1x'))
$devHead.Controls.AddRange(@($lblDevName, $lblDevState, $lblDevInfo, $devActions))
# the header grows with the lines of the actions; past two lines the secondary ones keep only their icon (the name
# in the tooltip), the remote screen and the power actions keep their text
$script:DevActionsCompact = $false
function Get-FlowRows($buttons, [int]$w) { $rows = 1; $x = 0; foreach ($b in $buttons) { $bw = Get-FullWidth @($b); if ($x -gt 0 -and $x + $bw -gt $w) { $rows++; $x = 0 }; $x += $bw }; $rows }
function Set-DeviceActionsFit {
  $w = $devHead.ClientSize.Width - 34; if ($w -lt 60) { return }
  $compact = (Get-FlowRows @($devActions.Controls | Where-Object { $_.Visible }) $w) -gt 2
  if ($compact -ne $script:DevActionsCompact) { $script:DevActionsCompact = $compact; Set-CompactButtons @($btnTrackDev, $btnGroupDev, $btnBrandDev, $btnVpnDev, $btnDot1xDev) $compact }
  $devActions.MaximumSize = New-Object System.Drawing.Size($w, 0)
  $devActions.Location = New-Object System.Drawing.Point(18, 90)
  $h = 90 + $devActions.GetPreferredSize((New-Object System.Drawing.Size($w, 0))).Height + 6
  if ($devHead.Height -ne $h) { $devHead.Height = $h }
  # the line under the name ends with ... when it does not fit; the whole of it in the tooltip
  $lblDevInfo.AutoSize = $false; $lblDevInfo.AutoEllipsis = $true; $lblDevInfo.Height = 24
  $lblDevInfo.Width = [Math]::Max(100, $devHead.ClientSize.Width - $lblDevInfo.Left - 16); $tips.SetToolTip($lblDevInfo, $lblDevInfo.Text)
}
$devHead.add_Resize({ Set-DeviceActionsFit })

$detail = New-Object System.Windows.Forms.TabControl
$detail.Dock = 'Fill'; $detail.Padding = New-Object System.Drawing.Point(16, 6); $detail.Font = $fontBase
$tabDevSettings = New-Object System.Windows.Forms.TabPage (Get-Text 'TabSettings')
$tabSummary = New-Object System.Windows.Forms.TabPage (Get-Text 'TabSummary')
$tabEvents = New-Object System.Windows.Forms.TabPage (Get-Text 'TabEvents')
$tabStatus = New-Object System.Windows.Forms.TabPage (Get-Text 'TabReport')
$detail.TabPages.AddRange(@($tabDevSettings, $tabSummary, $tabEvents, $tabStatus))
foreach ($t in $detail.TabPages) { $t.BackColor = $Theme.Card }
function New-TextView { $t = New-Object System.Windows.Forms.TextBox; $t.Multiline = $true; $t.ReadOnly = $true; $t.ScrollBars = 'Both'; $t.WordWrap = $false; $t.Dock = 'Fill'; $t.Font = $fontMono; $t.BackColor = $Theme.Card; $t.BorderStyle = 'None'; $t }
$txtStatus = New-TextView; $tabStatus.Controls.Add($txtStatus); $tabStatus.Padding = New-Object System.Windows.Forms.Padding(8)
$txtEvents = New-TextView; $tabEvents.Controls.Add($txtEvents); $tabEvents.Padding = New-Object System.Windows.Forms.Padding(8)
# summary: what the device reports, in groups, readable
$lvSummary = New-Object System.Windows.Forms.ListView
$lvSummary.Dock = 'Fill'; $lvSummary.View = 'Details'; $lvSummary.HeaderStyle = 'None'; $lvSummary.BorderStyle = 'None'; $lvSummary.FullRowSelect = $true
$lvSummary.ShowGroups = $true; $lvSummary.Font = $fontBase
[void]$lvSummary.Columns.Add('', 230); [void]$lvSummary.Columns.Add('', 600)
$script:CopySummary = { if ($lvSummary.SelectedItems.Count -eq 1 -and $lvSummary.SelectedItems[0].Tag) {
  [System.Windows.Forms.Clipboard]::SetText([string]$lvSummary.SelectedItems[0].Tag); $barText.Text = Get-Text 'SumCopied' $lvSummary.SelectedItems[0].Text } }
$lvSummary.add_KeyDown({ param($s, $e) if ($e.Control -and $e.KeyCode -eq 'C') { & $script:CopySummary; $e.Handled = $true } })
$lvSummary.add_DoubleClick({ & $script:CopySummary })
$lvSummary.add_Resize({ param($s, $e) $s.Columns[1].Width = [Math]::Max(200, $s.ClientSize.Width - $s.Columns[0].Width - 4) })
$tabSummary.Controls.Add($lvSummary); $tabSummary.Padding = New-Object System.Windows.Forms.Padding(8)

function New-Grid {
  $g = New-Object System.Windows.Forms.DataGridView
  $g.Dock = 'Fill'; $g.AllowUserToAddRows = $false; $g.AllowUserToDeleteRows = $false; $g.AllowUserToResizeRows = $false; $g.RowHeadersVisible = $false
  $g.SelectionMode = 'CellSelect'; $g.AutoSizeRowsMode = 'None'; $g.EditMode = 'EditOnEnter'; $g.BackgroundColor = $Theme.Card; $g.BorderStyle = 'None'
  $g.CellBorderStyle = 'SingleHorizontal'; $g.GridColor = $Theme.Line; $g.EnableHeadersVisualStyles = $false
  $g.ColumnHeadersBorderStyle = 'None'; $g.ColumnHeadersHeightSizeMode = 'DisableResizing'; $g.ColumnHeadersHeight = 34
  $hs = $g.ColumnHeadersDefaultCellStyle; $hs.BackColor = $Theme.Card; $hs.ForeColor = $Theme.Muted; $hs.Font = $fontSmallBold; $hs.SelectionBackColor = $Theme.Card; $hs.SelectionForeColor = $Theme.Muted
  $hs.Padding = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)
  $ds = $g.DefaultCellStyle; $ds.SelectionBackColor = $Theme.AccentSoft; $ds.SelectionForeColor = $Theme.Text; $ds.ForeColor = $Theme.Text; $ds.Font = $fontBase
  $ds.Padding = New-Object System.Windows.Forms.Padding(6, 0, 6, 0)
  $g.RowTemplate.Height = 30
  # no flicker when scrolling
  $g.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic, Instance').SetValue($g, $true, $null)
  $g.add_DataError({ param($s, $e) $e.ThrowException = $false })
  $g
}
# Every text column shares the width of the grid (Fill), in proportion to the width its title and samples would need:
# on any screen all the columns stay in view, narrower when the window is, never behind a horizontal scroll bar
function Add-TextColumn($g, $titleKey, $width, $readOnly, $samples = @(), $boldSamples = @()) {
  $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $col.HeaderText = Get-Text $titleKey; $col.ReadOnly = $readOnly; $col.SortMode = 'NotSortable'
  $col.AutoSizeMode = 'Fill'
  if ($width) {
    $ideal = Get-FitWidth (Get-FitWidth (Get-FitWidth $width $col.HeaderText $fontSmallBold 20) $samples $fontBase 18) $boldSamples $fontBold 18
    $col.FillWeight = $ideal; $col.MinimumWidth = [Math]::Min($ideal, 60)
  } else { $col.FillWeight = 220; $col.MinimumWidth = 80 }
  [void]$g.Columns.Add($col)
}
function Add-CheckColumn($g, $titleKey, $width) {
  $col = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn; $col.HeaderText = Get-Text $titleKey
  $col.Width = Get-FitWidth $width $col.HeaderText $fontSmallBold 18; [void]$g.Columns.Add($col)
}
# a search box over a grid: hides the settings that do not match (name, key or help) and the groups left empty
function Set-GridFilter($g, [string]$text) {
  $g.CurrentCell = $null
  $t = [System.Management.Automation.WildcardPattern]::Escape($text.Trim())
  $section = $null; $any = $false
  foreach ($r in $g.Rows) {
    if ($null -eq $r.Tag) { if ($section) { $section.Visible = $any -or -not $t }; $section = $r; $any = $false; continue }
    $s = $r.Tag
    $show = (-not $t) -or ($s.Label -like "*$t*") -or ($s.Key -like "*$t*") -or ($s.Help -like "*$t*")
    $r.Visible = $show; if ($show) { $any = $true }
  }
  if ($section) { $section.Visible = $any -or -not $t }
}
function New-FilterBar($grid) {
  $p = New-Panel 'Top' $Theme.Card 48
  $t = New-SearchBox 'SearchSettings' 280; $t.Location = New-Object System.Drawing.Point(10, 11)
  $t.Tag = Get-Text 'SearchSettings'
  $t.add_TextChanged({ param($s, $e) Set-GridFilter $s.Parent.Tag.Grid $s.Text })
  $p.Controls.Add($t); $p.Tag = @{ Grid = $grid; Box = $t }
  $p
}
# the first column holds the setting names and the group titles (bold)
$labels = @($script:Settings | ForEach-Object { $_.Label })
$sections = @($script:Settings | ForEach-Object { $_.Section } | Select-Object -Unique)

# settings of the selected device: in use | comes from | value for this device | exception
$gridDev = New-Grid
Add-TextColumn $gridDev 'ColSetting' 150 $true $labels $sections
Add-TextColumn $gridDev 'ColInUse' 130 $true
Add-TextColumn $gridDev 'ColSource' 110 $true @((Get-Text 'SrcThis'), (Get-Text 'SrcCommon'), (Get-Text 'SrcDevice'), (Get-Text 'SrcPending'))
Add-TextColumn $gridDev 'ColThisDevice' $null $false
Add-CheckColumn $gridDev 'ColExceptionTick' 78
$helpDev = New-HelpPanel (Get-Text 'HelpDevice' (Get-Text 'ColExceptionTick'))
$gridDev.Tag = $helpDev
$btnSaveDev = New-ActionButton 'BtnSave' 'Save' 'primary'
$btnReloadDev = New-ActionButton 'BtnUndo' 'Undo' 'secondary'
$btnClearDev = New-ActionButton 'BtnRemoveExceptions' 'Delete' 'danger'
$lblDirtyDev = New-Label (Get-Text 'Unsaved') $fontSmallBold $script:KindColor.warn; $lblDirtyDev.Margin = New-Object System.Windows.Forms.Padding(6, 8, 0, 0); $lblDirtyDev.Visible = $false
$btnTextDev = New-ActionButton 'BtnAsText' 'Document' 'secondary'
$barDev = New-ActionBar @($btnSaveDev, $btnReloadDev, $btnTextDev, $lblDirtyDev) @($btnClearDev)
$filterDev = New-FilterBar $gridDev
$tabDevSettings.Controls.Add($gridDev); $tabDevSettings.Controls.Add($filterDev); $tabDevSettings.Controls.Add($helpDev); $tabDevSettings.Controls.Add($barDev)

$devCard.Controls.Add($detail); $devCard.Controls.Add($devHead)
$split.Panel2.Controls.Add($devCard)
$pageDevices.Controls.Add($split)

# ---------------- Common settings page ----------------
$pageCommon = New-Panel 'Fill' $Theme.Page
$comCard = New-Panel 'Fill' $Theme.Card; Add-Line $comCard 'Box'; $comCard.Padding = New-Object System.Windows.Forms.Padding(1)
$comWrap = New-Panel 'Fill' $Theme.Page; $comWrap.Padding = New-Object System.Windows.Forms.Padding(12, 0, 12, 12)
$gridCom = New-Grid
Add-TextColumn $gridCom 'ColSetting' 190 $true $labels $sections
Add-TextColumn $gridCom 'ColValueAll' $null $false
Add-CheckColumn $gridCom 'ColManagedHere' 110
$helpCom = New-HelpPanel (Get-Text 'HelpCommon' (Get-Text 'ColManagedHere'))
$gridCom.Tag = $helpCom
$btnSaveCom = New-ActionButton 'BtnSave' 'Save' 'primary'
$btnReloadCom = New-ActionButton 'BtnUndo' 'Undo' 'secondary'
$btnBrandCom = New-ActionButton 'BtnBranding' 'Picture' 'secondary'
$lblDirtyCom = New-Label (Get-Text 'Unsaved') $fontSmallBold $script:KindColor.warn; $lblDirtyCom.Margin = New-Object System.Windows.Forms.Padding(6, 8, 0, 0); $lblDirtyCom.Visible = $false
$btnTextCom = New-ActionButton 'BtnAsText' 'Document' 'secondary'
$btnGroupsCom = New-ActionButton 'BtnGroups' 'Folder' 'secondary'
$barCom = New-ActionBar @($btnSaveCom, $btnReloadCom, $btnTextCom, $btnGroupsCom, $btnBrandCom, $lblDirtyCom)
$filterCom = New-FilterBar $gridCom
$comCard.Controls.Add($gridCom); $comCard.Controls.Add($filterCom); $comCard.Controls.Add($helpCom); $comCard.Controls.Add($barCom)
$comWrap.Controls.Add($comCard)
$setTabs = New-Object System.Windows.Forms.TabControl
$setTabs.Dock = 'Fill'; $setTabs.Padding = New-Object System.Drawing.Point(16, 6); $setTabs.Font = $fontBase
$tabSetHealth = New-Object System.Windows.Forms.TabPage (Get-Text 'SetTabHealth')
$tabSetManager = New-Object System.Windows.Forms.TabPage (Get-Text 'SetTabManager'); $tabSetCustom = New-Object System.Windows.Forms.TabPage (Get-Text 'SetTabCustom')
foreach ($tp in @($tabSetHealth, $tabSetManager, $tabSetCustom)) { $tp.BackColor = $Theme.Page; $tp.Padding = New-Object System.Windows.Forms.Padding(0, 10, 0, 0); [void]$setTabs.TabPages.Add($tp) }
$comWrap.Padding = New-Object System.Windows.Forms.Padding(0)
$lblComNote = New-Label (Get-Text 'PageCommonNote' (Get-Text 'ColManagedHere')) $fontBase $Theme.Muted; $lblComNote.AutoSize = $false; $lblComNote.Dock = 'Top'; $lblComNote.Height = 48
# the settings of the site and of each group: in the devices page, when the site or a group is selected in the tree
$lblScope = New-Label '' $fontBold $Theme.Text; $lblScope.AutoSize = $false; $lblScope.Dock = 'Top'; $lblScope.Height = 34; $lblScope.Padding = New-Object System.Windows.Forms.Padding(14, 10, 14, 0)
$lblComNote.Padding = New-Object System.Windows.Forms.Padding(14, 2, 14, 0)
$scopeWrap = New-Panel 'Fill' $Theme.Card; Add-Line $scopeWrap 'Box'; $scopeWrap.Padding = New-Object System.Windows.Forms.Padding(1); $scopeWrap.Visible = $false
$scopeWrap.Controls.Add($comWrap); $scopeWrap.Controls.Add($lblComNote); $scopeWrap.Controls.Add($lblScope)
# the note as tall as its text: never cut in the middle of a sentence
function Set-ComNoteFit {
  $w = $lblComNote.ClientSize.Width - $lblComNote.Padding.Horizontal; if ($w -lt 60) { return }
  $h = [System.Windows.Forms.TextRenderer]::MeasureText($lblComNote.Text, $lblComNote.Font, (New-Object System.Drawing.Size($w, 0)), [System.Windows.Forms.TextFormatFlags]'WordBreak').Height + $lblComNote.Padding.Vertical + 8
  if ($lblComNote.Height -ne $h) { $lblComNote.Height = $h }
}
$lblComNote.add_SizeChanged({ Set-ComNoteFit }); $lblComNote.add_TextChanged({ Set-ComNoteFit })
$split.Panel2.Controls.Add($scopeWrap)
$setWrap = New-Panel 'Fill' $Theme.Page; $setWrap.Padding = New-Object System.Windows.Forms.Padding(12, 0, 12, 12); $setWrap.Controls.Add($setTabs)
$pageCommon.Controls.Add($setWrap); $pageCommon.Controls.Add((New-PageHeader (Get-Text 'NavCommon') (Get-Text 'PageSettingsNote')))

# ---------------- SSH keys page ----------------
$pageKeys = New-Panel 'Fill' $Theme.Page
$keysWrap = New-Panel 'Fill' $Theme.Page; $keysWrap.Padding = New-Object System.Windows.Forms.Padding(12, 0, 12, 12)
$keysCard = New-Panel 'Fill' $Theme.Card; Add-Line $keysCard 'Box'; $keysCard.Padding = New-Object System.Windows.Forms.Padding(1)
$txtKeys = New-Object System.Windows.Forms.TextBox
$txtKeys.Multiline = $true; $txtKeys.ScrollBars = 'Both'; $txtKeys.WordWrap = $false; $txtKeys.Dock = 'Fill'; $txtKeys.Font = $fontMono; $txtKeys.AcceptsReturn = $true; $txtKeys.BorderStyle = 'None'
$keysPad = New-Panel 'Fill' $Theme.Card; $keysPad.Padding = New-Object System.Windows.Forms.Padding(10, 8, 6, 6); $keysPad.Controls.Add($txtKeys)
$btnSaveKeys = New-ActionButton 'BtnSave' 'Save' 'primary'
$btnReloadKeys = New-ActionButton 'BtnUndo' 'Undo' 'secondary'
$btnMyKey = New-ActionButton 'BtnAddMyKey' 'Add' 'secondary'
$btnKeyFile = New-ActionButton 'BtnAddKeyFile' 'Document' 'secondary'
$lblDirtyKeys = New-Label (Get-Text 'Unsaved') $fontSmallBold $script:KindColor.warn; $lblDirtyKeys.Margin = New-Object System.Windows.Forms.Padding(6, 8, 0, 0); $lblDirtyKeys.Visible = $false
$tips.SetToolTip($btnMyKey, (Get-Text 'TipAddMyKey'))
$barKeys = New-ActionBar @($btnSaveKeys, $btnReloadKeys, $btnMyKey, $btnKeyFile, $lblDirtyKeys)
$keysCard.Controls.Add($keysPad); $keysCard.Controls.Add($barKeys)
$keysWrap.Controls.Add($keysCard)
$pageKeys.Controls.Add($keysWrap); $pageKeys.Controls.Add((New-PageHeader (Get-Text 'PageKeysTitle') (Get-Text 'NoteKeys')))

# ---------------- History page (the past problems of the devices; the code calls it Problems) ----------------
$pageProblems = New-Panel 'Fill' $Theme.Page
$probWrap = New-Panel 'Fill' $Theme.Page; $probWrap.Padding = New-Object System.Windows.Forms.Padding(12, 0, 12, 12)
$probCard = New-Panel 'Fill' $Theme.Card; Add-Line $probCard 'Box'; $probCard.Padding = New-Object System.Windows.Forms.Padding(1)
$probTop = New-Panel 'Top' $Theme.Card 82; Add-Line $probTop 'Bottom'
$lblPeriod = New-Label (Get-Text 'ProbPeriod'); $lblPeriod.Location = New-Object System.Drawing.Point(14, 16)
$cmbPeriod = New-Object System.Windows.Forms.ComboBox; $cmbPeriod.DropDownStyle = 'DropDownList'; $cmbPeriod.Width = 160; $cmbPeriod.Font = $fontBase
[void]$cmbPeriod.Items.AddRange(@((Get-Text 'ProbToday'), (Get-Text 'Prob24h'), (Get-Text 'Prob7d'), (Get-Text 'Prob30d'))); $cmbPeriod.SelectedIndex = 1
$cmbPeriod.Location = New-Object System.Drawing.Point((22 + (Get-TextWidth $lblPeriod.Text)), 12)
$btnProbRefresh = New-ActionButton 'BtnRefresh' 'Refresh' 'secondary'; $btnProbRefresh.Location = New-Object System.Drawing.Point(($cmbPeriod.Right + 10), 10)
$lblHeadline = New-Label '' $fontBold; $lblHeadline.AutoSize = $false; $lblHeadline.Location = New-Object System.Drawing.Point(14, 50); $lblHeadline.Height = 24
$lblHeadline.Anchor = 'Top, Left, Right'; $lblHeadline.Width = 1000
$probTop.Controls.AddRange(@($lblPeriod, $cmbPeriod, $btnProbRefresh, $lblHeadline))
$probTop.add_Resize({ param($s, $e) $lblHeadline.Width = [Math]::Max(100, $s.ClientSize.Width - 28) })
$probSplit = New-Object System.Windows.Forms.SplitContainer; $probSplit.Dock = 'Fill'; $probSplit.Orientation = 'Horizontal'; $probSplit.BackColor = $Theme.Line; $probSplit.SplitterWidth = 1
$probSplit.Panel1.BackColor = $Theme.Card; $probSplit.Panel2.BackColor = $Theme.Card
$probList = New-Object System.Windows.Forms.ListView
$probList.Dock = 'Fill'; $probList.View = 'Details'; $probList.FullRowSelect = $true; $probList.MultiSelect = $false; $probList.HideSelection = $false; $probList.BorderStyle = 'None'
$probList.SmallImageList = $imgDots; $probList.Font = $fontBase
$probList.Tag = @{ Ideal = @() }
foreach ($c in @(@('ColProblem', 330), @('ColWhere', 180), @('ColTimes', 60), @('ColDevicesN', 230), @('ColUsers', 200), @('ColFirstTime', 100), @('ColLastTime', 100))) {
  $w = Get-FitWidth $c[1] (Get-Text $c[0]) -pad 14; [void]$probList.Columns.Add((Get-Text $c[0]), $w); $probList.Tag.Ideal += $w }
$probList.add_Resize({ param($s, $e) Set-ListFit $s })
$probText = New-TextView
$probPad = New-Panel 'Fill' $Theme.Card; $probPad.Padding = New-Object System.Windows.Forms.Padding(10, 8, 6, 6); $probPad.Controls.Add($probText)
$probSplit.Panel1.Controls.Add($probList); $probSplit.Panel2.Controls.Add($probPad)
$probCard.Controls.Add($probSplit); $probCard.Controls.Add($probTop)
$probWrap.Controls.Add($probCard)
$pageProblems.Controls.Add($probWrap); $pageProblems.Controls.Add((New-PageHeader (Get-Text 'NavProblems') (Get-Text 'ProbNote')))

# Brokers and hosts, on top of the Desktops page: the problems of now with their Fix buttons. One green line when all is
# well (the lines of each broker and host one click away); hidden when the page is turned off or no broker is known.
$vdiPWrap = New-Panel 'Fill' $Theme.Page; $vdiPWrap.Padding = New-Object System.Windows.Forms.Padding(12, 0, 12, 0)
$vdiPCard = New-Panel 'Fill' $Theme.Card; Add-Line $vdiPCard 'Box'; $vdiPCard.Padding = New-Object System.Windows.Forms.Padding(1)
$vdiPTop = New-Panel 'Top' $Theme.Card 42; Add-Line $vdiPTop 'Bottom'
$lblVdiPTitle = New-Label (Get-Text 'VdiProbTitle') $fontBold; $lblVdiPTitle.Location = New-Object System.Drawing.Point(14, 11)
# what the lines say in a few words (green: all OK), and the button that shows every line or only the problems
$lblVdiPSum = New-Label '' $fontBold; $lblVdiPSum.AutoSize = $false; $lblVdiPSum.AutoEllipsis = $true; $lblVdiPSum.Height = 22
$btnVdiPAll = New-ActionButton 'VdiBrokHide' '' 'secondary'; $btnVdiPAll.Height = 28
$btnVdiPAll.Width = (@((Get-Text 'VdiBrokShowAll' 99), (Get-Text 'VdiBrokShowProblems'), (Get-Text 'VdiBrokShow' 99), (Get-Text 'VdiBrokHide')) | ForEach-Object { Get-TextWidth $_ } | Measure-Object -Maximum).Maximum + 30
$vdiPTop.Controls.AddRange(@($lblVdiPTitle, $lblVdiPSum, $btnVdiPAll))
$vdiPTop.add_Resize({ param($s, $e) $btnVdiPAll.Location = New-Object System.Drawing.Point(($s.ClientSize.Width - $btnVdiPAll.Width - 10), 7)
  $lblVdiPSum.SetBounds(($lblVdiPTitle.Right + 10), 11, [Math]::Max(60, $btnVdiPAll.Left - $lblVdiPTitle.Right - 20), 22) })
$gridVdi = New-Grid
$gridVdi.ReadOnly = $true; $gridVdi.SelectionMode = 'FullRowSelect'; $gridVdi.MultiSelect = $false; $gridVdi.EditMode = 'EditProgrammatically'; $gridVdi.ShowCellToolTips = $true
$gridVdi.RowTemplate.Height = 30
# no titles: a state, a place, a sentence and a button say themselves, and the room goes to the users below
$gridVdi.ColumnHeadersVisible = $false
$vdiKindTexts = @('VdiKind_error', 'VdiKind_warn', 'VdiKind_info', 'VdiKind_ok') | ForEach-Object { Get-Text $_ }
Add-TextColumn $gridVdi 'VdiColKind' 70 $true @() $vdiKindTexts
Add-TextColumn $gridVdi 'VdiColWhere' 120 $true @('RDS-BROKER-02')
Add-TextColumn $gridVdi 'VdiColFinding' $null $true
$gridVdi.Columns[2].FillWeight = 520
# the shares of the width: the grid changes them by itself when a column reaches its minimum on a narrow window, and
# Set-VdiBrokFit puts them back
$script:VdiGridWeights = @($gridVdi.Columns[0].FillWeight, $gridVdi.Columns[1].FillWeight, $gridVdi.Columns[2].FillWeight)
$gridVdi.Columns[0].MinimumWidth = Get-FitWidth 50 $vdiKindTexts $fontSmallBold 18
# a long finding wraps on two lines instead of ending with ...
$gridVdi.Columns[2].DefaultCellStyle.WrapMode = 'True'; $gridVdi.Columns[2].DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(6, 6, 6, 6)
$gridVdi.AutoSizeRowsMode = 'AllCells'
$vdiFixCol = New-Object System.Windows.Forms.DataGridViewButtonColumn; $vdiFixCol.HeaderText = ''; $vdiFixCol.FlatStyle = 'Flat'; $vdiFixCol.AutoSizeMode = 'None'
$vdiFixCol.Width = Get-FitWidth 90 (@('BrokerRestart', 'BrokerSelfRepair', 'BrokerAddToGroup', 'HostPermissions', 'HostUnblock', 'HostOfflineAction') | ForEach-Object { Get-Text "VdiFix_$_" }) $fontBase 26
[void]$gridVdi.Columns.Add($vdiFixCol)
# right click (or the menu key) on a broker or a host: all its actions, not only the fix of the line
$vdiMenu = New-Object System.Windows.Forms.ContextMenuStrip; $vdiMenu.Font = $fontBase
foreach ($k in 'BrokerRestart', 'BrokerPurge', 'BrokerSelfRepair', 'HostUnblock', 'HostPermissions') {
  $mi = New-Object System.Windows.Forms.ToolStripMenuItem (Get-Text "VdiAct_$k"); $mi.Tag = $k; [void]$vdiMenu.Items.Add($mi) }
$gridVdi.ContextMenuStrip = $vdiMenu
$vdiPCard.Controls.Add($gridVdi); $vdiPCard.Controls.Add($vdiPTop)
$vdiPWrap.Controls.Add($vdiPCard)

# ---------------- Desktops page: device -> user -> desktop -> host -> VM -> session -> last sign-in ----------------
# top: search, filter, refresh, settings, then who cannot sign in now and when the data was read; the list; under it
# the selected row: what is wrong in one sentence, its desktop and session, its last sign-ins, and its actions
$pageDesktops = New-Panel 'Fill' $Theme.Page
$dskWrap = New-Panel 'Fill' $Theme.Page; $dskWrap.Padding = New-Object System.Windows.Forms.Padding(12, 0, 12, 12)
$dskCard = New-Panel 'Fill' $Theme.Card; Add-Line $dskCard 'Box'; $dskCard.Padding = New-Object System.Windows.Forms.Padding(1)
$dskTop = New-Panel 'Top' $Theme.Card 84; Add-Line $dskTop 'Bottom'
$script:DskSearchWidth = Get-FitWidth 230 (Get-Text 'VdiSearch') $fontBase 16; $script:DskTopCompact = $false
$txtDskSearch = New-SearchBox 'VdiSearch' $script:DskSearchWidth; $txtDskSearch.Location = New-Object System.Drawing.Point(14, 13)
$cmbDskFilter = New-Object System.Windows.Forms.ComboBox; $cmbDskFilter.DropDownStyle = 'DropDownList'; $cmbDskFilter.Font = $fontBase
$dskFilterTexts = @('VdiFilterAll', 'VdiFilterProblems', 'VdiFilterActive', 'VdiFilterDisc', 'VdiFilterVmOff') | ForEach-Object { Get-Text $_ }
[void]$cmbDskFilter.Items.AddRange($dskFilterTexts); $cmbDskFilter.SelectedIndex = 0
$cmbDskFilter.Width = Get-FitWidth 140 $dskFilterTexts $fontBase 40; $cmbDskFilter.Location = New-Object System.Drawing.Point(($txtDskSearch.Right + 10), 12)
$btnDskRefresh = New-ActionButton 'BtnRefresh' 'Refresh' 'secondary'; $btnDskRefresh.Location = New-Object System.Drawing.Point(($cmbDskFilter.Right + 10), 9)
$btnDskSettings = New-ActionButton 'HcBtnTree' 'Health' 'secondary'; $btnDskSettings.Location = New-Object System.Drawing.Point(($btnDskRefresh.Right + 8), 9)
$lblDskHead = New-Label '' $fontBold; $lblDskHead.AutoSize = $false; $lblDskHead.AutoEllipsis = $true; $lblDskHead.Height = 24; $lblDskHead.Location = New-Object System.Drawing.Point(14, 52)
$lblDskUpdated = New-Label '' $fontSmall $Theme.Muted; $lblDskUpdated.AutoSize = $false; $lblDskUpdated.TextAlign = 'MiddleRight'; $lblDskUpdated.Height = 24
$dskTop.Controls.AddRange(@($txtDskSearch, $cmbDskFilter, $btnDskRefresh, $btnDskSettings, $lblDskHead, $lblDskUpdated))
$dskTop.add_Resize({ param($s, $e)
  $w = $s.ClientSize.Width
  # on a narrow window the search box gives up its room first, then the buttons keep only their icons
  $full = (Get-FullWidth @($btnDskRefresh, $btnDskSettings)) + 10
  $txtDskSearch.Width = [Math]::Max(140, [Math]::Min($script:DskSearchWidth, $w - 28 - $cmbDskFilter.Width - 10 - $full - 10))
  $cmbDskFilter.Left = $txtDskSearch.Right + 10
  $compact = ($cmbDskFilter.Right + 10 + $full) -gt ($w - 14)
  if ($compact -ne [bool]$script:DskTopCompact) { $script:DskTopCompact = $compact; Set-CompactButtons @($btnDskRefresh, $btnDskSettings) $compact }
  $btnDskRefresh.Left = $cmbDskFilter.Right + 10; $btnDskSettings.Left = $btnDskRefresh.Right + 8
  $uw = [Math]::Min(300, [Math]::Max(120, (Get-TextWidth $lblDskUpdated.Text $fontSmall) + 10))
  $lblDskUpdated.SetBounds(($w - $uw - 14), 52, $uw, 24); $lblDskHead.Width = [Math]::Max(80, $w - $uw - 40) })
$tips.SetToolTip($btnDskRefresh, (Get-Text 'VdiTipRefresh'))

$dskSplit = New-Object System.Windows.Forms.SplitContainer; $dskSplit.Dock = 'Fill'; $dskSplit.Orientation = 'Horizontal'; $dskSplit.BackColor = $Theme.Line
$dskSplit.SplitterWidth = 4; $dskSplit.FixedPanel = 'Panel2'; $dskSplit.Panel1.BackColor = $Theme.Card; $dskSplit.Panel2.BackColor = $Theme.Card
$dskList = New-Object System.Windows.Forms.ListView
$dskList.Dock = 'Fill'; $dskList.View = 'Details'; $dskList.FullRowSelect = $true; $dskList.MultiSelect = $false; $dskList.HideSelection = $false
$dskList.BorderStyle = 'None'; $dskList.SmallImageList = $imgDots; $dskList.ShowItemToolTips = $true; $dskList.Font = $fontBase
$dskList.Tag = @{ Ideal = @() }
foreach ($c in @(@('VdiColUser', 100, @('ALEXANDRA.K')), @('VdiColState', 120, @((Get-Text 'VdiStCannot'), (Get-Text 'VdiStSavedTpm'))), @('VdiColDevice', 100, @('thinclient12')),
  @('VdiColDesktop', 110, @('VM-ALEXANDRA')), @('VdiColHost', 90, @('HYPERV-02')), @('VdiColVm', 80, @((Get-Text 'VdiVmRunning'))), @('VdiColSession', 110, @((Get-Text 'VdiSessIdle' (Get-Text 'DurMinutes' 118)), (Get-Text 'VdiSessDiscSince' '18:45'))),
  @('VdiColSignIn', 150, @((Get-Text 'VdiSignOk' '08:41' 'RDS-BROKER-02'))))) {
  $title = Get-Text $c[0]; $w = Get-FitWidth (Get-FitWidth $c[1] "$title $([char]0x25B2)" -pad 14) $c[2] -pad 14
  [void]$dskList.Columns.Add($title, $w); $dskList.Tag.Ideal += $w
}
$dskList.add_Resize({ param($s, $e) Set-ListFit $s })
# no sorter until a title is clicked: the rows come with whoever cannot sign in on top
$script:DskSorter = New-Object OtrColumnSorter; $script:DskSorter.Column = -1; $script:DskSorter.NameColumn = 0
$script:DskTitles = @($dskList.Columns | ForEach-Object { $_.Text })
$dskList.add_ColumnClick({ param($s, $e)
  if ($script:DskSorter.Column -eq $e.Column) { $script:DskSorter.Descending = -not $script:DskSorter.Descending } else { $script:DskSorter.Column = $e.Column; $script:DskSorter.Descending = $false }
  if (-not $dskList.ListViewItemSorter) { $dskList.ListViewItemSorter = $script:DskSorter }
  $dskList.Sort()
  for ($k = 0; $k -lt $dskList.Columns.Count; $k++) { $dskList.Columns[$k].Text = if ($k -eq $script:DskSorter.Column) { $script:DskTitles[$k] + ' ' + $(if ($script:DskSorter.Descending) { [char]0x25BC } else { [char]0x25B2 }) } else { $script:DskTitles[$k] } }
  if ($dskList.SelectedItems.Count) { $dskList.SelectedItems[0].EnsureVisible() } })
$dskSplit.Panel1.Controls.Add($dskList)

# the selected row
$dskDetail = New-Panel 'Fill' $Theme.Card
$dskHead = New-Panel 'Top' $Theme.Card 58; Add-Line $dskHead 'Bottom'
$lblDskName = New-Label '' $fontPageTitle; $lblDskName.Location = New-Object System.Drawing.Point(16, 6)
$lblDskState = New-Label '' $fontSmallBold; $lblDskState.Padding = New-Object System.Windows.Forms.Padding(8, 3, 8, 3); $lblDskState.Visible = $false
$lblDskWhy = New-Label '' $fontBase $Theme.Muted; $lblDskWhy.AutoSize = $false; $lblDskWhy.AutoEllipsis = $true; $lblDskWhy.Height = 22; $lblDskWhy.Location = New-Object System.Drawing.Point(18, 33)
$dskHead.Controls.AddRange(@($lblDskName, $lblDskState, $lblDskWhy))
$dskHead.add_Resize({ param($s, $e) $lblDskWhy.Width = [Math]::Max(80, $s.ClientSize.Width - 34) })
# left: the desktop, the session, the device; right: the last sign-ins
$dskInfoTable = New-Object System.Windows.Forms.TableLayoutPanel; $dskInfoTable.Dock = 'Fill'; $dskInfoTable.ColumnCount = 2; $dskInfoTable.RowCount = 1; $dskInfoTable.BackColor = $Theme.Card
[void]$dskInfoTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 55))); [void]$dskInfoTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 45)))
[void]$dskInfoTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
$lvDskInfo = New-Object System.Windows.Forms.ListView; $lvDskInfo.Dock = 'Fill'; $lvDskInfo.View = 'Details'; $lvDskInfo.HeaderStyle = 'None'; $lvDskInfo.BorderStyle = 'None'
$lvDskInfo.FullRowSelect = $true; $lvDskInfo.Font = $fontBase; $lvDskInfo.ShowItemToolTips = $true
[void]$lvDskInfo.Columns.Add('', (Get-FitWidth 120 (@('VdiInfoDesktop', 'VdiInfoHost', 'VdiInfoVm', 'VdiInfoSession', 'VdiInfoDevice') | ForEach-Object { Get-Text $_ }) $fontBase 18)); [void]$lvDskInfo.Columns.Add('', 300)
$lvDskInfo.add_Resize({ param($s, $e) $s.Columns[1].Width = [Math]::Max(120, $s.ClientSize.Width - $s.Columns[0].Width - 4) })
$lvDskSign = New-Object System.Windows.Forms.ListView; $lvDskSign.Dock = 'Fill'; $lvDskSign.View = 'Details'; $lvDskSign.BorderStyle = 'None'; $lvDskSign.FullRowSelect = $true
$lvDskSign.Font = $fontBase; $lvDskSign.SmallImageList = $imgDots; $lvDskSign.ShowItemToolTips = $true; $lvDskSign.HeaderStyle = 'Nonclickable'
foreach ($c in @(@('VdiColWhen', 90, '18/10 08:41'), @('VdiColOutcome', 70, (Get-Text 'VdiOutFail')), @('VdiColBroker', 120, ''))) { [void]$lvDskSign.Columns.Add((Get-Text $c[0]), (Get-FitWidth $c[1] @((Get-Text $c[0]), $c[2]) -pad 34)) }
$lvDskSign.add_Resize({ param($s, $e) $s.Columns[2].Width = [Math]::Max(80, $s.ClientSize.Width - $s.Columns[0].Width - $s.Columns[1].Width - 4) })
$dskInfoPad = New-Panel 'Fill' $Theme.Card; $dskInfoPad.Padding = New-Object System.Windows.Forms.Padding(10, 6, 6, 0); $dskInfoPad.Controls.Add($lvDskInfo)
$dskSignPad = New-Panel 'Fill' $Theme.Card; $dskSignPad.Padding = New-Object System.Windows.Forms.Padding(6, 6, 10, 0); $dskSignPad.Controls.Add($lvDskSign)
$dskInfoTable.Controls.Add($dskInfoPad, 0, 0); $dskInfoTable.Controls.Add($dskSignPad, 1, 0)
# the actions of the row; the two that end something on the right, in red
$btnDskShadow = New-ActionButton 'VdiBtnShadow' 'Screen' 'primary'
$btnDskMessage = New-ActionButton 'VdiBtnMessage' 'Message' 'secondary'
$btnDskDisconnect = New-ActionButton 'VdiBtnDisconnect' 'Unplug' 'secondary'
$btnDskStart = New-ActionButton 'VdiBtnStart' 'Play' 'secondary'
$btnDskRestart = New-ActionButton 'VdiBtnRestart' 'Refresh' 'secondary'
$btnDskAssign = New-ActionButton 'VdiBtnAssign' 'Contact' 'secondary'
$btnDskLogoff = New-ActionButton 'VdiBtnLogoff' 'Cancel' 'danger'
$btnDskShutdown = New-ActionButton 'VdiBtnShutdown' 'Power' 'danger'
$script:DskButtons = @($btnDskShadow, $btnDskMessage, $btnDskDisconnect, $btnDskStart, $btnDskRestart, $btnDskAssign, $btnDskLogoff, $btnDskShutdown)
$barDsk = New-ActionBar @($btnDskShadow, $btnDskMessage, $btnDskDisconnect, $btnDskStart, $btnDskRestart, $btnDskAssign) @($btnDskShutdown, $btnDskLogoff)
# the actions keep only their icons (their words in the tooltip) rather than taking a second row from the details
$script:DskCompact = $false
$barDsk.add_Resize({ param($s, $e)
  $left = @($btnDskShadow, $btnDskMessage, $btnDskDisconnect, $btnDskStart, $btnDskRestart, $btnDskAssign)
  $compact = (Get-FullWidth $left) + (Get-FullWidth @($btnDskShutdown, $btnDskLogoff)) + 40 -gt $s.ClientSize.Width
  if ($compact -ne $script:DskCompact) { $script:DskCompact = $compact; Set-CompactButtons $left $compact } })
$dskDetail.Controls.Add($dskInfoTable); $dskDetail.Controls.Add($dskHead); $dskDetail.Controls.Add($barDsk)
$dskSplit.Panel2.Controls.Add($dskDetail)
# the same actions on the row itself: right click, or the menu key
$dskMenu = New-Object System.Windows.Forms.ContextMenuStrip; $dskMenu.Font = $fontBase
foreach ($k in 'SessionShadow', 'SessionMessage', 'SessionDisconnect', 'SessionLogoff', '-', 'VmStart', 'VmRestart', 'VmShutdown', '-', 'AssignDesktop') {
  if ($k -eq '-') { [void]$dskMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)); continue }
  $mi = New-Object System.Windows.Forms.ToolStripMenuItem (Get-Text "VdiAct_$k"); $mi.Tag = $k; [void]$dskMenu.Items.Add($mi) }
$dskList.ContextMenuStrip = $dskMenu
$dskCard.Controls.Add($dskSplit); $dskCard.Controls.Add($dskTop)
$dskWrap.Controls.Add($dskCard)
# brokers and hosts on top, the users under them
$dskOuter = New-Object System.Windows.Forms.SplitContainer; $dskOuter.Dock = 'Fill'; $dskOuter.Orientation = 'Horizontal'
$dskOuter.BackColor = $Theme.Page; $dskOuter.SplitterWidth = 8; $dskOuter.FixedPanel = 'Panel1'; $dskOuter.Panel1MinSize = 40
$dskOuter.Panel1.Controls.Add($vdiPWrap); $dskOuter.Panel2.Controls.Add($dskWrap)
$pageDesktops.Controls.Add($dskOuter); $pageDesktops.Controls.Add((New-PageHeader (Get-Text 'HcDistTitle') (Get-Text 'HcDistNote')))
# the details keep about 250 points (less on a low window), the list the rest
function Set-DskSplitFit {
  $h = $dskSplit.Height; if ($h -lt 200) { return }
  $want = [Math]::Max(90, $h - [Math]::Max(165, [Math]::Min(290, [int]($h * 0.45))))
  if ([Math]::Abs($dskSplit.SplitterDistance - $want) -gt 2) { try { $dskSplit.SplitterDistance = $want } catch { } }
}
$dskSplit.add_SizeChanged({ Set-DskSplitFit })

# ---------------- Health Center page: the tree of the infrastructure | the selected item ----------------
# top: the mode (diagnosis only, or diagnosis and repair), refresh, settings, the headline and when it was read;
# left: cluster -> hosts -> VMs, domain -> DCs and DNS, SQL -> replicas, brokers, devices, backups, each with its dot;
# right: the selected item: what is wrong in one sentence, its mode, its facts, its checks with their Fix, its actions
$pageHealth = New-Panel 'Fill' $Theme.Page
$hcWrap = New-Panel 'Fill' $Theme.Page; $hcWrap.Padding = New-Object System.Windows.Forms.Padding(12, 0, 12, 12)
$hcCard = New-Panel 'Fill' $Theme.Card; Add-Line $hcCard 'Box'; $hcCard.Padding = New-Object System.Windows.Forms.Padding(1)
$hcTop = New-Panel 'Top' $Theme.Card 84; Add-Line $hcTop 'Bottom'
$lblHcMode = New-Label (Get-Text 'HcModeLabel'); $lblHcMode.Location = New-Object System.Drawing.Point(14, 16)
$cmbHcMode = New-Object System.Windows.Forms.ComboBox; $cmbHcMode.DropDownStyle = 'DropDownList'; $cmbHcMode.Font = $fontBase
$hcModeTexts = @((Get-Text 'HcModeDiagnose'), (Get-Text 'HcModeRepair'))
[void]$cmbHcMode.Items.AddRange($hcModeTexts); $cmbHcMode.Width = Get-FitWidth 160 $hcModeTexts $fontBase 40
$cmbHcMode.Location = New-Object System.Drawing.Point(($lblHcMode.Left + (Get-TextWidth $lblHcMode.Text) + 8), 12)
$btnHcRefresh = New-ActionButton 'BtnRefresh' 'Refresh' 'secondary'; $btnHcRefresh.Location = New-Object System.Drawing.Point(($cmbHcMode.Right + 10), 9)
$btnHcSettings = New-ActionButton 'HcBtnDist' 'Desktop' 'secondary'; $btnHcSettings.Location = New-Object System.Drawing.Point(($btnHcRefresh.Right + 8), 9)
$pbHc = New-Object System.Windows.Forms.ProgressBar; $pbHc.Style = 'Continuous'; $pbHc.Visible = $false; $pbHc.SetBounds(($btnHcSettings.Right + 14), 22, 180, 10)
$lblHcHead = New-Label '' $fontBold; $lblHcHead.AutoSize = $false; $lblHcHead.AutoEllipsis = $true; $lblHcHead.Height = 24; $lblHcHead.Location = New-Object System.Drawing.Point(14, 52)
$lblHcUpdated = New-Label '' $fontSmall $Theme.Muted; $lblHcUpdated.AutoSize = $false; $lblHcUpdated.TextAlign = 'MiddleRight'; $lblHcUpdated.Height = 24
$hcTop.Controls.AddRange(@($lblHcMode, $cmbHcMode, $btnHcRefresh, $btnHcSettings, $pbHc, $lblHcHead, $lblHcUpdated))
$script:HcTopCompact = $false
$hcTop.add_Resize({ param($s, $e)
  $w = $s.ClientSize.Width
  $compact = ($cmbHcMode.Right + 10 + (Get-FullWidth @($btnHcRefresh, $btnHcSettings)) + 10) -gt ($w - 14)
  if ($compact -ne [bool]$script:HcTopCompact) { $script:HcTopCompact = $compact; Set-CompactButtons @($btnHcRefresh, $btnHcSettings) $compact }
  $btnHcRefresh.Left = $cmbHcMode.Right + 10; $btnHcSettings.Left = $btnHcRefresh.Right + 8; $pbHc.Left = $btnHcSettings.Right + 14
  $uw = [Math]::Min(320, [Math]::Max(120, (Get-TextWidth $lblHcUpdated.Text $fontSmall) + 10))
  $lblHcUpdated.SetBounds(($w - $uw - 14), 52, $uw, 24); $lblHcHead.Width = [Math]::Max(80, $w - $uw - 40) })
$tips.SetToolTip($btnHcRefresh, (Get-Text 'HcTipRefresh')); $tips.SetToolTip($cmbHcMode, (Get-Text 'HcTipMode')); $tips.SetToolTip($lblHcMode, (Get-Text 'HcTipMode'))

$hcSplit = New-Object System.Windows.Forms.SplitContainer; $hcSplit.Dock = 'Fill'; $hcSplit.Orientation = 'Vertical'; $hcSplit.BackColor = $Theme.Line
$hcSplit.SplitterWidth = 4; $hcSplit.FixedPanel = 'Panel1'; $hcSplit.Panel1.BackColor = $Theme.Card; $hcSplit.Panel2.BackColor = $Theme.Card
$tvHc = New-Object System.Windows.Forms.TreeView
$tvHc.Dock = 'Fill'; $tvHc.BorderStyle = 'None'; $tvHc.Font = $fontBase; $tvHc.HideSelection = $false; $tvHc.FullRowSelect = $true; $tvHc.ShowLines = $false
$tvHc.ItemHeight = 26; $tvHc.ShowNodeToolTips = $true; $tvHc.BackColor = $Theme.Card; $tvHc.ForeColor = $Theme.Text
$imgHcDots = New-Object System.Windows.Forms.ImageList; $imgHcDots.ColorDepth = 'Depth32Bit'; $imgHcDots.ImageSize = New-Object System.Drawing.Size(16, 22)
foreach ($k in @('ok', 'off', 'error', 'warn', 'info')) { $imgHcDots.Images.Add($k, (New-Dot $script:KindColor[$k] 16 22)) }
$tvHc.ImageList = $imgHcDots
$hcTreePad = New-Panel 'Fill' $Theme.Card; $hcTreePad.Padding = New-Object System.Windows.Forms.Padding(6, 6, 0, 6); $hcTreePad.Controls.Add($tvHc)
$hcSplit.Panel1.Controls.Add($hcTreePad)
# the tree takes about a third of the width, between 240 and 380 points
function Set-HcSplitFit {
  $w = $hcSplit.Width; if ($w -lt 300) { return }
  $d = [Math]::Min(380, [Math]::Max(240, [int]($w * 0.32)))
  if ($w - $d -lt 380) { $d = [Math]::Max(200, $w - 380) }
  if ($hcSplit.SplitterDistance -ne $d) { try { $hcSplit.SplitterDistance = $d } catch { } }
}
$hcSplit.add_SizeChanged({ Set-HcSplitFit })

# the selected item
$hcDetail = New-Panel 'Fill' $Theme.Card
$hcHead = New-Panel 'Top' $Theme.Card 92; Add-Line $hcHead 'Bottom'
$lblHcName = New-Label '' $fontPageTitle; $lblHcName.Location = New-Object System.Drawing.Point(16, 6)
$lblHcState = New-Label '' $fontSmallBold; $lblHcState.Padding = New-Object System.Windows.Forms.Padding(8, 3, 8, 3); $lblHcState.Visible = $false
$lblHcWhy = New-Label '' $fontBase $Theme.Muted; $lblHcWhy.AutoSize = $false; $lblHcWhy.AutoEllipsis = $true; $lblHcWhy.Height = 22; $lblHcWhy.Location = New-Object System.Drawing.Point(18, 33)
$lblHcItemMode = New-Label (Get-Text 'HcItemMode') $fontBase $Theme.Muted; $lblHcItemMode.Location = New-Object System.Drawing.Point(18, 63)
$cmbHcItem = New-Object System.Windows.Forms.ComboBox; $cmbHcItem.DropDownStyle = 'DropDownList'; $cmbHcItem.Font = $fontBase
$cmbHcItem.Width = Get-FitWidth 200 (@((Get-Text 'HcItemInherit' (Get-Text 'HcModeRepair'))) + $hcModeTexts) $fontBase 40
$cmbHcItem.Location = New-Object System.Drawing.Point(($lblHcItemMode.Left + (Get-TextWidth $lblHcItemMode.Text) + 6), 59)
$hcHead.Controls.AddRange(@($lblHcName, $lblHcState, $lblHcWhy, $lblHcItemMode, $cmbHcItem))
$hcHead.add_Resize({ param($s, $e) $lblHcWhy.Width = [Math]::Max(80, $s.ClientSize.Width - 34) })
$tips.SetToolTip($cmbHcItem, (Get-Text 'HcTipMode'))
$hcInner = New-Object System.Windows.Forms.SplitContainer; $hcInner.Dock = 'Fill'; $hcInner.Orientation = 'Horizontal'; $hcInner.BackColor = $Theme.Line
$hcInner.SplitterWidth = 4; $hcInner.Panel1.BackColor = $Theme.Card; $hcInner.Panel2.BackColor = $Theme.Card
# its facts: a label and a value per line
$lvHcFacts = New-Object System.Windows.Forms.ListView; $lvHcFacts.Dock = 'Fill'; $lvHcFacts.View = 'Details'; $lvHcFacts.HeaderStyle = 'None'; $lvHcFacts.BorderStyle = 'None'
$lvHcFacts.FullRowSelect = $true; $lvHcFacts.Font = $fontBase; $lvHcFacts.ShowItemToolTips = $true
[void]$lvHcFacts.Columns.Add('', 160); [void]$lvHcFacts.Columns.Add('', 400)
$lvHcFacts.add_Resize({ param($s, $e) $s.Columns[1].Width = [Math]::Max(120, $s.ClientSize.Width - $s.Columns[0].Width - 4) })
$hcFactsPad = New-Panel 'Fill' $Theme.Card; $hcFactsPad.Padding = New-Object System.Windows.Forms.Padding(10, 6, 6, 0); $hcFactsPad.Controls.Add($lvHcFacts)
$hcInner.Panel1.Controls.Add($hcFactsPad)
# its checks: state, what, what it means, the fix
$gridHc = New-Grid
$gridHc.ReadOnly = $true; $gridHc.SelectionMode = 'FullRowSelect'; $gridHc.MultiSelect = $false; $gridHc.EditMode = 'EditProgrammatically'; $gridHc.ShowCellToolTips = $true
$hcKindTexts = @('HcStatus_error', 'HcStatus_warn', 'HcStatus_info', 'HcStatus_ok') | ForEach-Object { Get-Text $_ }
Add-TextColumn $gridHc 'HcColState' 70 $true @() $hcKindTexts
Add-TextColumn $gridHc 'HcColCheck' 120 $true @('Free memory')
Add-TextColumn $gridHc 'HcColMeaning' $null $true
$gridHc.Columns[2].FillWeight = 520
$script:HcGridWeights = @($gridHc.Columns[0].FillWeight, $gridHc.Columns[1].FillWeight, $gridHc.Columns[2].FillWeight)
$gridHc.Columns[0].MinimumWidth = Get-FitWidth 50 $hcKindTexts $fontSmallBold 18
$gridHc.Columns[1].DefaultCellStyle.WrapMode = 'True'
$gridHc.Columns[2].DefaultCellStyle.WrapMode = 'True'; $gridHc.Columns[2].DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(6, 6, 6, 6)
$gridHc.AutoSizeRowsMode = 'AllCells'
$hcFixCol = New-Object System.Windows.Forms.DataGridViewButtonColumn; $hcFixCol.HeaderText = ''; $hcFixCol.FlatStyle = 'Flat'; $hcFixCol.AutoSizeMode = 'None'
$hcFixCol.Width = Get-FitWidth 90 @((Get-Text 'HcFix'), (Get-Text 'HcFixSafe')) $fontBase 26
[void]$gridHc.Columns.Add($hcFixCol)
$hcInner.Panel2.Controls.Add($gridHc)
# the actions of the item; the one that ends something on the right, in red
$script:HcBarKinds = [ordered]@{ OpenDesktops = 'Desktop'; SessionShadow = 'Screen'; SessionMessage = 'Message'; SessionDisconnect = 'Unplug'; AssignDesktop = 'Contact'
  HostDrain = 'Forward'; HostResume = 'Play'; HostMoveAll = 'Forward'; VmStart = 'Play'; VmRestart = 'Refresh'; VmResume = 'Play'; VmRoleOnline = 'Shield'; VmMoveLive = 'Forward'
  VmRemoveCheckpoints = 'Delete'; VmRemoveSavedState = 'Delete'; VmStopAction = 'Settings'; TimeSync = 'Clock'; DcSyncAll = 'Sync'; DcRestartServices = 'Refresh'
  RdsUnblockChain = 'Sync'; SqlFailover = 'Sync'; SqlCopyOnly = 'Save'; Laps = 'Key'; DeviceWake = 'Power'; ServerRestart = 'Refresh'; OpenSettings = 'Settings'
  BrokerRestart = 'Refresh'; BrokerPurge = 'Delete'; BrokerSelfRepair = 'Repair'; HostUnblock = 'Repair'; HostPermissions = 'Shield' }
# the actions of the brokers and hosts that the Desktops part plans (by the name of the broker or host)
$script:HcVdiKinds = @('BrokerRestart', 'BrokerPurge', 'BrokerSelfRepair', 'HostUnblock', 'HostPermissions')

$script:HcButtons = [ordered]@{}
foreach ($k in $script:HcBarKinds.Keys) { $b = New-ActionButton "HcAct_$k" $script:HcBarKinds[$k] $(if ($k -eq 'OpenDesktops') { 'primary' } else { 'secondary' }); $b.Name = $k; $script:HcButtons[$k] = $b }
# the ones that end something on the right, in red
foreach ($k in 'SessionLogoff', 'ServerShutdown', 'VmShutdown') { $b = New-ActionButton "HcAct_$k" $(if ($k -eq 'SessionLogoff') { 'Cancel' } else { 'Power' }) 'danger'; $b.Name = $k; $script:HcButtons[$k] = $b }
$btnHcShutdown = $script:HcButtons['VmShutdown']; $hcDanger = @($script:HcButtons['SessionLogoff'], $script:HcButtons['ServerShutdown'], $btnHcShutdown)
$barHc = New-ActionBar @($script:HcButtons.Values | Where-Object { $hcDanger -notcontains $_ }) $hcDanger
$hcDetail.Controls.Add($hcInner); $hcDetail.Controls.Add($hcHead); $hcDetail.Controls.Add($barHc)
$hcSplit.Panel2.Controls.Add($hcDetail)
$hcCard.Controls.Add($hcSplit); $hcCard.Controls.Add($hcTop)
$hcWrap.Controls.Add($hcCard)
$pageHealth.Controls.Add($hcWrap); $pageHealth.Controls.Add((New-PageHeader (Get-Text 'NavHealth') (Get-Text 'HcPageNote')))
# the facts keep about 40% of the height of the item, its checks the rest
function Set-HcInnerFit {
  $h = $hcInner.Height; if ($h -lt 160) { return }
  $rh = if ($lvHcFacts.Items.Count) { $lvHcFacts.GetItemRect(0).Height } else { 21 }
  $want = [Math]::Max(80, [Math]::Min([int]($h * 0.45), $rh * ([Math]::Max(3, $lvHcFacts.Items.Count)) + 14))
  if ([Math]::Abs($hcInner.SplitterDistance - $want) -gt 2) { try { $hcInner.SplitterDistance = $want } catch { } }
  for ($k = 0; $k -lt 3; $k++) { if ($gridHc.Columns[$k].FillWeight -ne $script:HcGridWeights[$k]) { $gridHc.Columns[$k].FillWeight = $script:HcGridWeights[$k] } }
}
$hcInner.add_SizeChanged({ Set-HcInnerFit })

# ---------------- Vault page ----------------
# three blocks: the vault (open, close, code), the SSH key of the manager, the key that signs the updates
$pageVault = New-Panel 'Fill' $Theme.Page
$vaultWrap = New-Panel 'Fill' $Theme.Page; $vaultWrap.Padding = New-Object System.Windows.Forms.Padding(12, 0, 12, 12)
$vaultCard = New-Panel 'Fill' $Theme.Card; Add-Line $vaultCard 'Box'; $vaultCard.Padding = New-Object System.Windows.Forms.Padding(1); $vaultCard.AutoScroll = $true
function New-VaultBlock([string]$titleKey, [string]$glyph, $buttons) {
  $p = New-Panel 'Top' $Theme.Card 150; $p.Padding = New-Object System.Windows.Forms.Padding(18, 14, 18, 14)
  $t = New-Label ('  ' + (Get-Text $titleKey)) $fontBold; $t.AutoSize = $false; $t.Dock = 'Top'; $t.Height = 28
  $img = New-Glyph $glyph $Theme.Accent 18; if ($img) { $t.Image = $img; $t.ImageAlign = 'MiddleLeft'; $t.Text = '      ' + (Get-Text $titleKey) }
  $t.TextAlign = 'MiddleLeft'
  $n = New-Label '' $fontBase $Theme.Muted; $n.AutoSize = $false; $n.Dock = 'Fill'; $n.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
  # the buttons wrap on a narrow window: Set-VaultHeights gives the block the rows they need
  $fl = New-Object System.Windows.Forms.FlowLayoutPanel; $fl.Dock = 'Bottom'; $fl.Height = 34; $fl.WrapContents = $true; $fl.BackColor = $Theme.Card
  foreach ($b in $buttons) { $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 8); $fl.Controls.Add($b) }
  $p.Controls.Add($n); $p.Controls.Add($fl); $p.Controls.Add($t)
  $p.Tag = @{ Line = 'Bottom'; Note = $n; Flow = $fl }
  $p.add_Paint({ param($s, $e) $pen = New-Object System.Drawing.Pen($Theme.Line); $e.Graphics.DrawLine($pen, 0, $s.Height - 1, $s.Width, $s.Height - 1); $pen.Dispose() })
  $p
}
$btnVaultOpen = New-ActionButton 'BtnVaultOpen' 'Unlock' 'primary'
$btnVaultCode = New-ActionButton 'BtnVaultCode' 'Key' 'secondary'
$btnVaultSshAdd = New-ActionButton 'BtnVaultSshAdd' 'Add' 'primary'
$btnVaultSshNew = New-ActionButton 'BtnVaultSshNew' 'Refresh' 'secondary'
$btnVaultSshImport = New-ActionButton 'BtnVaultSshImport' 'Document' 'secondary'
$btnVaultSign = New-ActionButton 'BtnVaultSign' 'Certificate' 'primary'
$btnVaultSignImport = New-ActionButton 'BtnVaultSignImport' 'Document' 'secondary'
$btnVaultSignNew = New-ActionButton 'BtnVaultSignNew' 'Add' 'secondary'
$btnVaultSignExport = New-ActionButton 'BtnVaultSignExport' 'Save' 'secondary'
$btnVaultSignSend = New-ActionButton 'BtnVaultSignSend' 'Devices' 'secondary'
# the open/create/close button changes its text: wide enough for the longest
$btnVaultOpen.Width = (@('BtnVaultOpen', 'BtnVaultCreate', 'BtnVaultClose') | ForEach-Object { Get-TextWidth (Get-Text $_) } | Measure-Object -Maximum).Maximum + 50
$blkVault = New-VaultBlock 'VaultBlockTitle' 'Lock' @($btnVaultOpen, $btnVaultCode)
$blkSsh = New-VaultBlock 'VaultSshTitle' 'Screen' @($btnVaultSshAdd, $btnVaultSshNew, $btnVaultSshImport)
$blkSign = New-VaultBlock 'VaultSignTitle' 'Certificate' @($btnVaultSign, $btnVaultSignSend, $btnVaultSignExport, $btnVaultSignNew, $btnVaultSignImport)
# Dock Top stacks the last added on top: the vault, the key that signs, the SSH key of the manager; under them the SSH
# keys of the devices (config\authorized_keys, the manager's key is one of them), the list that was a page of its own
foreach ($b in @($blkSsh, $blkSign, $blkVault)) { $vaultCard.Controls.Add($b) }
$vaultCard.Dock = 'Top'
$keysHead = New-Panel 'Top' $Theme.Card 80; $keysHead.Padding = New-Object System.Windows.Forms.Padding(18, 14, 18, 4)
$keysTitle = New-Label ('  ' + (Get-Text 'VaultKeysTitle')) $fontBold; $keysTitle.AutoSize = $false; $keysTitle.Dock = 'Top'; $keysTitle.Height = 28; $keysTitle.TextAlign = 'MiddleLeft'
$img = New-Glyph 'Key' $Theme.Accent 18; if ($img) { $keysTitle.Image = $img; $keysTitle.ImageAlign = 'MiddleLeft'; $keysTitle.Text = '      ' + (Get-Text 'VaultKeysTitle') }
$keysNote = New-Label (Get-Text 'NoteKeys') $fontBase $Theme.Muted; $keysNote.AutoSize = $false; $keysNote.Dock = 'Fill'; $keysNote.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
$keysHead.Controls.Add($keysNote); $keysHead.Controls.Add($keysTitle)
$keysCard.Controls.Add($keysHead)
$vaultGap = New-Panel 'Top' $Theme.Page 12
# Fill first, then the edges: the vault on top, the SSH keys of the devices under it
$vaultWrap.Controls.Add($keysCard); $vaultWrap.Controls.Add($vaultGap); $vaultWrap.Controls.Add($vaultCard)
$pageVault.Controls.Add($vaultWrap); $pageVault.Controls.Add((New-PageHeader (Get-Text 'NavVault') (Get-Text 'PageVaultNote')))
# each block as high as its text; the blocks of the vault take at most 60% of the page (they scroll), the list the rest
function Set-VaultHeights {
  Set-BlockHeights $vaultCard @($blkVault, $blkSsh, $blkSign)
  $sum = $blkVault.Height + $blkSsh.Height + $blkSign.Height + 2
  $h = [Math]::Min($sum, [Math]::Max(180, [int]($vaultWrap.ClientSize.Height * 0.6)))
  if ($vaultCard.Height -ne $h) { $vaultCard.Height = $h }
  $kh = 14 + 28 + (Measure-Note $keysNote.Text ([Math]::Max(100, $keysCard.ClientSize.Width - 38))) + 10
  if ($keysHead.Height -ne $kh) { $keysHead.Height = $kh }
}
$vaultWrap.add_Resize({ Set-VaultHeights })
function Set-BlockHeights($card, $blocks) {
  $inner = $card.ClientSize.Width - 2 - 36
  if ($inner -lt 100) { return }
  foreach ($b in $blocks) {
    $fh = Get-FlowHeight $b.Tag.Flow $inner
    if ($b.Tag.Flow.Height -ne $fh) { $b.Tag.Flow.Height = $fh }
    $need = 14 + 28 + 4 + (Measure-Note $b.Tag.Note.Text $inner) + 10 + $fh + 6
    if ($b.Height -ne $need) { $b.Height = $need }
  }
}
$vaultCard.add_Resize({ Set-VaultHeights })

# ---------------- Updates page ----------------
# two blocks, as the vault: the versions the devices install (published, all devices, pilots, going back) and this manager
$pageUpdates = New-Panel 'Fill' $Theme.Page
$updWrap = New-Panel 'Fill' $Theme.Page; $updWrap.Padding = New-Object System.Windows.Forms.Padding(12, 0, 12, 12)
$updCard = New-Panel 'Fill' $Theme.Card; Add-Line $updCard 'Box'; $updCard.Padding = New-Object System.Windows.Forms.Padding(1); $updCard.AutoScroll = $true
$btnUpdRelease = New-ActionButton 'BtnImportRelease' 'Download' 'primary'
$btnUpdAll = New-ActionButton 'BtnReleaseAll' 'Devices' 'secondary'
$btnUpdFleet = New-ActionButton 'BtnFleetVersion' 'Undo' 'secondary'
$btnUpdFetch = New-ActionButton 'BtnFetchVersion' 'Add' 'secondary'
$btnMgrUpdate = New-ActionButton 'BtnUpdateManager' 'Download' 'primary'
$btnMgrCheck = New-ActionButton 'BtnCheckManager' 'Refresh' 'secondary'
$blkFleet = New-VaultBlock 'UpdBlockTitle' 'Devices' @($btnUpdRelease, $btnUpdAll, $btnUpdFleet, $btnUpdFetch)
$blkManager = New-VaultBlock 'MgrBlockTitle' 'Settings' @($btnMgrUpdate, $btnMgrCheck)
# the updates of the manager itself on the Updates page too, under those of the devices: every update in one place
$updCard.Controls.Add($blkManager)
$updCard.Controls.Add($blkFleet)
$updWrap.Controls.Add($updCard)
$pageUpdates.Controls.Add($updWrap); $pageUpdates.Controls.Add((New-PageHeader (Get-Text 'NavUpdates') (Get-Text 'PageUpdatesNote')))
$updCard.add_Resize({ Set-BlockHeights $updCard @($blkFleet) })
function New-SetCard($tab) {
  $c = New-Panel 'Fill' $Theme.Card; Add-Line $c 'Box'; $c.Padding = New-Object System.Windows.Forms.Padding(1); $c.AutoScroll = $true
  $tab.Controls.Add($c); $c
}
# Health Center: what it checks and how (the inventory, the modes, the thresholds) and the desktops (brokers, collections)
$btnSetHc = New-ActionButton 'HcBtnSettings' 'Health' 'primary'; $btnSetVdi = New-ActionButton 'VdiBtnSettings' 'Desktop' 'primary'
$blkSetHc = New-VaultBlock 'SetHcBlock' 'Health' @($btnSetHc); $blkSetVdi = New-VaultBlock 'SetVdiBlock' 'Desktop' @($btnSetVdi)
$setHcCard = New-SetCard $tabSetHealth; $setHcCard.Controls.Add($blkSetVdi); $setHcCard.Controls.Add($blkSetHc)
$btnSetHc.add_Click({ Show-HealthSettingsDialog }); $btnSetVdi.add_Click({ Show-VdiSettingsDialog; Update-SettingsTabs })
# this manager: its updates, its language, its local copy
$cmbLang = New-Object System.Windows.Forms.ComboBox; $cmbLang.DropDownStyle = 'DropDownList'; $cmbLang.Font = $fontBase; $cmbLang.Width = 220
$script:LangCodes = @('') + @(Get-ChildItem -LiteralPath $script:LangDir -Filter '*.psd1' -File -ErrorAction SilentlyContinue | ForEach-Object BaseName | Sort-Object)
foreach ($c in $script:LangCodes) { [void]$cmbLang.Items.Add($(if ($c) { $c } else { Get-Text 'LangAuto' })) }
$btnLangSave = New-ActionButton 'BtnSave' 'Save' 'secondary'
$blkLang = New-VaultBlock 'LangBlock' 'Settings' @($cmbLang, $btnLangSave)
$btnLocalChoose = New-ActionButton 'BtnLocalChoose' 'Folder' 'secondary'; $btnLocalSync = New-ActionButton 'BtnLocalSync' 'Sync' 'primary'; $btnLocalOpen = New-ActionButton 'BtnLocalOpen' 'Desktop' 'secondary'
$blkLocal = New-VaultBlock 'LocalBlock' 'Folder' @($btnLocalSync, $btnLocalChoose, $btnLocalOpen)
$btnFolderDom = New-ActionButton 'BtnFolderDomain' 'Shield' 'secondary'; $btnFolderMove = New-ActionButton 'BtnFolderMove' 'Forward' 'secondary'
$blkFolder = New-VaultBlock 'FolderBlock' 'Folder' @($btnFolderDom, $btnFolderMove)
$setMgrCard = New-SetCard $tabSetManager; foreach ($b in @($blkFolder, $blkLocal, $blkLang)) { $setMgrCard.Controls.Add($b) }
$btnFolderDom.add_Click({
  $acc = Get-DeviceAccount; $f = Get-DomainFolderFile
  if (-not $acc) { Show-Message (Get-Text 'FolderBlock') (Get-Text 'FolderNoAccount'); return }
  if (-not $f) { Show-Message (Get-Text 'FolderBlock') (Get-Text 'FolderNoDomain'); return }
  if ($script:Folder -notmatch $script:UncRx) { Show-Message (Get-Text 'FolderBlock') (Get-Text 'FolderMoveBadPath'); return }
  if (-not (Confirm-Action (Get-Text 'FolderBlock') (Get-Text 'FolderDomainAsk' $acc $script:Folder $f "`r`n`r`n"))) { return }
  try { Set-DomainFolder $acc $script:Folder } catch { Show-Message (Get-Text 'FolderBlock') (Get-Text 'FolderDomainFailed' $_.Exception.Message) 'Error'; return }
  Update-SettingsTabs; $barText.Text = Get-Text 'FolderDomainDone' $acc })
$btnFolderMove.add_Click({
  if ($script:LocalMode) { Show-Message (Get-Text 'FolderBlock') (Get-Text 'FolderMoveLocal'); return }
  Add-Type -AssemblyName Microsoft.VisualBasic
  $to = [Microsoft.VisualBasic.Interaction]::InputBox((Get-Text 'FolderMoveAsk' $script:Folder), (Get-Text 'BtnFolderMove'), '')
  if (-not $to) { return }
  if (-not (Confirm-Action (Get-Text 'BtnFolderMove') (Get-Text 'FolderMoveConfirm' $script:Folder $to.TrimEnd('\')) 'Button2')) { return }
  $form.Cursor = 'WaitCursor'
  try { $r = @(Move-ManagementFolder $to) } catch { $form.Cursor = 'Default'; Show-Message (Get-Text 'BtnFolderMove') (Get-Text 'FolderMoveFailed' $_.Exception.Message) 'Error'; return }
  $form.Cursor = 'Default'
  Show-Message (Get-Text 'BtnFolderMove') (($r -join "`r`n") + "`r`n`r`n" + (Get-Text 'FolderMoveAfter')) 'Information'
  Update-SettingsTabs; Update-CommonGrid })
$btnLangSave.add_Click({
  $m = Read-ManagerSettings; Set-ManagerSetting $m 'Language' ([string]$script:LangCodes[[Math]::Max(0, $cmbLang.SelectedIndex)]); Save-ManagerSettings $m
  Show-Message (Get-Text 'LangBlock') (Get-Text 'LangSaved') 'Information' })
$btnLocalChoose.add_Click({
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog; $dlg.Description = Get-Text 'LocalFolderDialog'; $dlg.ShowNewFolderButton = $true
  $cur = Get-LocalCopyPath; if ($cur) { $dlg.SelectedPath = $cur }
  if ($dlg.ShowDialog() -ne 'OK' -or -not $dlg.SelectedPath) { return }
  if ($dlg.SelectedPath.TrimEnd('\') -ieq $script:Folder.TrimEnd('\')) { Show-Message (Get-Text 'LocalBlock') (Get-Text 'LocalSame'); return }
  $m = Read-ManagerSettings; Set-ManagerSetting $m 'LocalCopy' $dlg.SelectedPath; Save-ManagerSettings $m
  [void](Start-LocalCopySync $script:Folder $dlg.SelectedPath); Update-SettingsTabs })
$btnLocalSync.add_Click({ if (Start-LocalCopySync $script:Folder (Get-LocalCopyPath)) { $barText.Text = Get-Text 'LocalSyncStarted' (Get-LocalCopyPath) } })
$btnLocalOpen.add_Click({
  $lc = Get-LocalCopyPath; if (-not $lc -or -not (Test-Path -LiteralPath (Join-Path $lc 'config'))) { Show-Message (Get-Text 'LocalBlock') (Get-Text 'LocalNone'); return }
  $fd = $lc; if ($fd.EndsWith('\')) { $fd += '\' }
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path $script:ManagerDir 'OpenThinRDP-Manager.ps1')`"", '-Folder', "`"$fd`"")
  if ($Language) { $a += @('-Language', $Language) }
  try { Start-Process (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $a -WorkingDirectory $script:ManagerDir -WindowStyle Hidden } catch { Show-Message (Get-Text 'LocalBlock') $_.Exception.Message 'Error' } })
# the custom checks of the Health Center: in config\health-checks of the management folder
$lblCustomNote = New-Label '' $fontBase $Theme.Muted; $lblCustomNote.AutoSize = $false; $lblCustomNote.Dock = 'Top'; $lblCustomNote.Height = 64; $lblCustomNote.Padding = New-Object System.Windows.Forms.Padding(14, 10, 14, 0)
$lvCustom = New-Object System.Windows.Forms.ListView; $lvCustom.Dock = 'Fill'; $lvCustom.View = 'Details'; $lvCustom.FullRowSelect = $true; $lvCustom.MultiSelect = $false; $lvCustom.Font = $fontBase; $lvCustom.BorderStyle = 'None'; $lvCustom.HideSelection = $false
foreach ($ck in @(@('CustomColName', 220), @('CustomColWhere', 160), @('CustomColEvery', 90), @('CustomColRepair', 220), @('CustomColResult', 300))) { [void]$lvCustom.Columns.Add((Get-Text $ck[0]), $ck[1]) }
$btnCuAdd = New-ActionButton 'BtnCustomAdd' 'Add' 'primary'; $btnCuEdit = New-ActionButton 'BtnCustomEdit' 'Settings' 'secondary'; $btnCuFolder = New-ActionButton 'BtnOpenFolder' 'Folder' 'secondary'
$btnCuDel = New-ActionButton 'BtnCustomDelete' 'Delete' 'danger'
$barCustom = New-ActionBar @($btnCuAdd, $btnCuEdit, $btnCuFolder) @($btnCuDel)
$setCuCard = New-SetCard $tabSetCustom; $setCuCard.AutoScroll = $false; $setCuCard.Controls.Add($lvCustom); $setCuCard.Controls.Add($lblCustomNote); $setCuCard.Controls.Add($barCustom)
$btnCuAdd.add_Click({ Show-CustomCheckDialog $null })
$btnCuEdit.add_Click({ if ($lvCustom.SelectedItems.Count) { Show-CustomCheckDialog $lvCustom.SelectedItems[0].Tag } })
$lvCustom.add_DoubleClick({ if ($lvCustom.SelectedItems.Count) { Show-CustomCheckDialog $lvCustom.SelectedItems[0].Tag } })
$btnCuFolder.add_Click({ $d = Get-HealthCustomDir; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }; Start-Process explorer.exe $d })
$btnCuDel.add_Click({
  if (-not $lvCustom.SelectedItems.Count) { return }; $c = $lvCustom.SelectedItems[0].Tag
  if (-not (Confirm-Action (Get-Text 'SetTabCustom') (Get-Text 'CustomDeleteAsk' $c.Name) 'Button2')) { return }
  try { Remove-HealthCustomCheck $c.Id } catch { Show-Message (Get-Text 'SetTabCustom') $_.Exception.Message 'Error' }; Update-SettingsTabs })
$lvCustom.add_SelectedIndexChanged({ $on = $lvCustom.SelectedItems.Count -gt 0; Set-ActionEnabled $btnCuEdit $on; Set-ActionEnabled $btnCuDel $on })
$setTabs.add_SelectedIndexChanged({ Update-SettingsTabs })
# the screenshots of the documentation: a tab of the Settings page
if ($env:OTR_MANAGER_SET_TAB) { $setTabs.SelectedIndex = [Math]::Min(3, [int]$env:OTR_MANAGER_SET_TAB) }
foreach ($cd in @($setHcCard, $setMgrCard)) { $cd.add_Resize({ Set-SettingsHeights }) }
function Set-SettingsHeights { Set-BlockHeights $setHcCard @($blkSetHc, $blkSetVdi); Set-BlockHeights $setMgrCard @($blkManager, $blkLang, $blkLocal) }
# the notes of the blocks and the list of the custom checks, as they are now
function Update-SettingsTabs {
  $s = if ($script:HealthLoaded) { Get-HealthSettings } else { $null }
  $blkSetHc.Tag.Note.Text = if ($s) { Get-Text 'SetHcNote' $(if ($s.Enabled) { Get-Text 'HcModeOn' } else { Get-Text 'HcModeOff' }) $(if ($s.Mode -eq 'repair') { Get-Text 'HcModeRepair' } else { Get-Text 'HcModeDiagnose' }) $($c = @($script:HealthInvLists | ForEach-Object { @($s.Inventory.$_).Count } | Measure-Object -Sum).Sum; if ($c) { Get-Text 'HcInvCount' $c } else { Get-Text 'HcNotConfigured' }) $(if ($s.Limits) { $s.Limits } else { Get-Text 'HcLimitsDefault' }) } else { '' }
  $vs = if ($script:VdiLoaded) { try { Get-VdiSettings } catch { $null } } else { $null }
  $blkSetVdi.Tag.Note.Text = Get-Text 'SetVdiNote' $(if ($vs -and $vs.PSObject.Properties['Brokers'] -and $vs.Brokers) { $vs.Brokers } else { Get-Text 'HcAuto' })
  $cur = $script:LangCodes.IndexOf([string]$(try { (Read-ManagerSettings).Language } catch { '' })); $cmbLang.SelectedIndex = [Math]::Max(0, $cur)
  $blkLang.Tag.Note.Text = Get-Text 'LangNote' $script:Language
  $acc = Get-DeviceAccount; $dmap = Get-DomainFolderMap (Get-DomainFolderFile)
  $blkFolder.Tag.Note.Text = (Get-Text 'FolderNote' $script:Folder) + "`r`n" + $(if (-not $acc) { Get-Text 'FolderNoAccount' } elseif ($dmap.Contains($acc)) { Get-Text 'FolderDomainIs' $acc $dmap[$acc] } else { Get-Text 'FolderDomainNone' $acc })
  $lc = Get-LocalCopyPath; $age = Get-LocalCopyAge $lc
  $blkLocal.Tag.Note.Text = (Get-Text 'LocalNote') + "`r`n" + $(if ($script:LocalMode) { Get-Text 'LocalNowLocal' $lc } elseif ($lc) { Get-Text 'LocalIs' $lc $(if ($age) { $age } else { Get-Text 'LocalNever' }) } else { Get-Text 'LocalNotSet' })
  Set-ActionEnabled $btnLocalSync ([bool]$lc -and -not $script:LocalMode); Set-ActionEnabled $btnLocalOpen ([bool]$age -and -not $script:LocalMode)
  # the block of this manager: its version and the newest one (Update-UpdatesView fills it)
  try { Update-UpdatesView } catch { }
  if ($script:HealthLoaded) {
    $open = @(Test-HealthCustomFolder)
    $lblCustomNote.Text = (Get-Text 'CustomNote' (Get-HealthCustomDir)) + $(if ($open.Count) { "`r`n" + (Get-Text 'HcX_CustomFolder' ($open -join ', ')) } else { '' })
    $lblCustomNote.ForeColor = if ($open.Count) { $script:KindColor.error } else { $Theme.Muted }
    $lvCustom.BeginUpdate(); $lvCustom.Items.Clear()
    foreach ($c in @(Get-HealthCustomChecks)) {
      $it = New-Object System.Windows.Forms.ListViewItem($c.Name); $it.Tag = $c
      [void]$it.SubItems.Add($c.Where); [void]$it.SubItems.Add((Get-Text 'HcEveryMin' $c.IntervalMin))
      [void]$it.SubItems.Add($(if (-not $c.Repair) { Get-Text 'CustomNoRepair' } elseif ($c.Risky) { Get-Text 'HcRepairAsks' } else { Get-Text 'HcRepairSafe' }))
      $res = @($script:HealthCustomResults.Values | Where-Object { $_.Name -eq $c.Name }); [void]$it.SubItems.Add((@($res | ForEach-Object { "$($_.Target): $(Get-Text "HcStatus_$($_.State)")" }) -join ', '))
      [void]$lvCustom.Items.Add($it)
    }
    $lvCustom.EndUpdate()
  }
  Set-ActionEnabled $btnCuEdit ($lvCustom.SelectedItems.Count -gt 0); Set-ActionEnabled $btnCuDel ($lvCustom.SelectedItems.Count -gt 0)
  Set-SettingsHeights
}

$script:Pages = @($pageDevices, $pageCommon, $pageKeys, $pageProblems, $pageVault, $pageUpdates, $pageDesktops, $pageHealth)
foreach ($p in $script:Pages) { $p.Visible = $false; $content.Controls.Add($p) }
# Fill first, then the edges: the last one added takes its side first
$root.Controls.Add($content); $root.Controls.Add($nav); $root.Controls.Add($header); $root.Controls.Add($bar)
$root.add_Resize({ Set-NavFit $root.ClientSize.Width })
$form.Controls.Add($root)

# ---------------------------------------------------------------------------------------------
# Behaviour
# ---------------------------------------------------------------------------------------------
$script:Devices = @(); $script:Selected = $null; $script:Loading = $false; $script:Listing = $false

function Select-Page([int]$i) {
  # the SSH keys of the devices (index 2) are a part of the Vault page now
  if ($i -eq 2) { $i = 4 }
  $script:Page = $i
  for ($k = 0; $k -lt $script:Pages.Count; $k++) {
    $script:Pages[$k].Visible = ($k -eq $i)
    $b = $script:NavButtons[$k]; $b.BackColor = if ($k -eq $i -or ($i -eq 6 -and $k -eq 7)) { $Theme.ShellSelected } else { $Theme.Shell }; $b.Invalidate()
  }
  if ($i -eq 3) { Update-ProblemView }
  if ($i -eq 4) { Update-VaultView }
  if ($i -eq 5) { Update-UpdatesView }
  if ($i -eq 1) { Update-SettingsTabs }
  if ($i -eq 6) { Set-DskSplitFit; Update-DesktopsView; if (-not $script:Vdi.Model) { Start-VdiRefresh } }
  if ($i -eq 7) { Set-HcSplitFit; Update-HealthView; if (-not $script:Health.Model -and -not $script:Health.Busy) { Start-HealthRefresh } }
}

function Set-Cell($row, $col, $s, $value) {
  if ($s.Type -eq 'choice') {
    $cb = New-Object System.Windows.Forms.DataGridViewComboBoxCell
    foreach ($c in $s.Choices) { [void]$cb.Items.Add($c) }
    $cb.FlatStyle = 'Flat'; $cb.DisplayStyle = 'DropDownButton'; $row.Cells[$col] = $cb
    $cb.Value = if ($null -ne $value -and $value -ne '') { ConvertTo-Canonical $s.Key $value } else { $s.Choices[0] }
  } else { $row.Cells[$col].Value = [string]$value }
}
function Get-Cell($row, $col) { $v = $row.Cells[$col].Value; if ($null -eq $v) { '' } else { ([string]$v).Trim() } }
# the settings are many: a title row per group (Tag = $null, skipped when saving)
function Add-SectionRow($g, $title, $checkCol) {
  $i = $g.Rows.Add(); $r = $g.Rows[$i]
  $r.Cells[$checkCol] = New-Object System.Windows.Forms.DataGridViewTextBoxCell
  $r.Cells[0].Value = $title; $r.ReadOnly = $true; $r.Tag = $null; $r.Height = 32
  $r.DefaultCellStyle.BackColor = $Theme.Section; $r.DefaultCellStyle.SelectionBackColor = $Theme.Section; $r.DefaultCellStyle.Font = $fontBold
  $r.DefaultCellStyle.ForeColor = $Theme.Text; $r.DefaultCellStyle.SelectionForeColor = $Theme.Text
}
# Managed values of a grid: KEY -> value, or $null when the tick is off
function Get-GridValues($g, $valueCol, $checkCol) {
  $m = [ordered]@{}
  foreach ($r in $g.Rows) { if ($null -eq $r.Tag) { continue }; $m[$r.Tag.Key] = if ($r.Cells[$checkCol].Value -eq $true) { Get-Cell $r $valueCol } else { $null } }
  $m
}
# a ticked row in the colour of its kind (own value of a device / managed for all); the value of an unticked row
# is only a proposal (ticking pins it) and stays grey
function Set-RowLook($r, $valueCol, $checkCol, $tint) {
  $on = $r.Cells[$checkCol].Value -eq $true
  $r.DefaultCellStyle.BackColor = if ($on) { $tint } else { $Theme.Card }
  $r.Cells[$valueCol].Style.ForeColor = if ($on) { $Theme.Text } else { $Theme.Muted }
}
function Set-Dirty([string]$what, [bool]$on) {
  switch ($what) { 'dev' { $lblDirtyDev.Visible = $on } 'com' { $lblDirtyCom.Visible = $on } 'keys' { $lblDirtyKeys.Visible = $on } }
}

function Get-SessionUser($s) {
  $v = [string]$s['SESSION']
  if ($v -match '^active \((.+)\)$') { return $Matches[1] }
  if ($v -and $v -ne 'none') { return $v }
  # a screen that shows a web page (WEB_BUTTON=kiosk) has no Windows session: the page is what it shows
  if ($s['CFG_WEB_BUTTON'] -eq 'kiosk') { return (Get-Text 'UserKiosk') }
  ''
}
function Get-Version($s) { (([string]$s['SOFTWARE']).Trim() -split '\s+')[-1] }
function Get-Seen($d) { if ($d.Minutes -lt 1) { Get-Text 'SeenNow' } else { Get-Text 'SeenAgo' (Format-Minutes $d.Minutes) } }

function Update-DeviceList {
  try {
    [void](Get-GroupFiles)
    $renamed = @(Complete-Renames)
    if ($renamed.Count) { [void](Get-GroupFiles) }
    $script:Devices = @(Get-Devices)
  } catch { $barText.Text = Get-Text 'ErrReadFolder' $script:Folder $_.Exception.Message; return }
  $sel = if ($script:Selected) { $script:Selected.File } else { $null }
  $f = [System.Management.Automation.WildcardPattern]::Escape($txtDevSearch.Text.Trim())
  $script:Rollout = try { Get-RolloutState } catch { $null }
  $script:Listing = $true
  $list.BeginUpdate(); $list.Items.Clear()
  foreach ($d in $script:Devices) {
    $s = $d.S; $user = Get-SessionUser $s
    if ($f -and -not (@($d.Name, $d.State, $s['IP'], $user, $s['DEFAULT_USER'], $s['MAC'], $d.Group) | Where-Object { "$_" -like "*$f*" })) { continue }
    $it = New-Object System.Windows.Forms.ListViewItem($d.Name)
    $it.ImageKey = $d.Kind; $it.UseItemStyleForSubItems = $false; $it.BackColor = $Theme.Card
    $ver = Get-Version $s; if ($script:Rollout -and $script:Rollout.Pilots -contains $d.Name) { $ver = Get-Text 'ListPilot' $ver }
    foreach ($v in @($d.State, $user, $ver, (Get-Seen $d))) { [void]$it.SubItems.Add([string]$v) }
    $it.SubItems[1].ForeColor = if ($d.Kind -eq 'ok') { $Theme.Text } else { $script:KindColor[$d.Kind] }
    if (-not $user) { $it.SubItems[2].Text = '' }
    $it.ToolTipText = "$($d.Name)   $([char]0x00B7)   $($d.State)   $([char]0x00B7)   $($s['IP'])"
    foreach ($x in $it.SubItems) { $x.BackColor = $Theme.Card }
    $it.Tag = $d
    [void]$list.Items.Add($it)
    if ($d.File -eq $sel) { $it.Selected = $true; $script:Selected = $d }
  }
  $list.Sort()
  $list.EndUpdate()
  # the tree, from the list (search and order already applied): the site with the devices in no group, its groups
  # (empty ones too: a device can be dragged onto them), the devices; what was open or closed stays as it was
  $site = Get-SiteName; $open = @{}
  foreach ($n in $tvDev.Nodes) { $open["$($n.Tag)"] = $n.IsExpanded; foreach ($c in $n.Nodes) { if ($c.Tag -is [string]) { $open[$c.Tag] = $c.IsExpanded } } }
  $tvDev.BeginUpdate(); $tvDev.Nodes.Clear()
  $root = $tvDev.Nodes.Add('site', $site); $root.Tag = ''
  $gn = [ordered]@{}
  foreach ($g in (@(Get-Groups) + @($script:Devices | ForEach-Object Group | Where-Object { $_ }) | Sort-Object -Unique)) { $x = $root.Nodes.Add("g:$g", $g); $x.Tag = [string]$g; $gn[$g] = $x }
  $selNode = $null
  foreach ($it in $list.Items) {
    $d = $it.Tag; $p = if ($d.Group -and $gn.Contains($d.Group)) { $gn[$d.Group] } else { $root }
    $dn = $p.Nodes.Add($d.Name, ((@($d.Name, $d.State, $it.SubItems[2].Text, $it.SubItems[3].Text) | Where-Object { $_ }) -join "  $([char]0x00B7)  "))
    $dn.Tag = $d; $dn.ImageKey = $d.Kind; $dn.SelectedImageKey = $d.Kind; $dn.ToolTipText = $it.ToolTipText
    if ($script:Selected -and $d.File -eq $script:Selected.File) { $selNode = $dn }
    if (-not $script:Selected -and -not $selNode) { $selNode = $dn }       # nothing selected yet: the first device
  }
  # each group with its dot (the worst state of its devices), how many devices, how many to look at
  $fill = { param($x, $ds, $label)
    $kd = Get-WorstKind @($ds | ForEach-Object Kind); $bad = @($ds | Where-Object { $_.Kind -in 'error', 'warn' }).Count
    $x.Text = Get-Text 'GroupHeader' $label $ds.Count $(if ($bad) { Get-Text 'GroupHeaderBad' $bad } else { '' }); $x.ImageKey = $kd; $x.SelectedImageKey = $kd }
  & $fill $root @($script:Devices) $site
  foreach ($g in @($gn.Keys)) { & $fill $gn[$g] @($script:Devices | Where-Object { $_.Group -eq $g }) $g }
  foreach ($x in @($root) + @($gn.Values)) { $key = [string]$x.Tag; if (-not $open.ContainsKey($key) -or $open[$key]) { $x.Expand() } }
  if ($selNode) { $tvDev.SelectedNode = $selNode }
  $tvDev.EndUpdate()
  $script:Listing = $false
  if ($list.SelectedItems.Count) { $list.SelectedItems[0].EnsureVisible() }
  $on = @($script:Devices | Where-Object { $_.Minutes -le $script:StaleMinutes }).Count
  $bad = @($script:Devices | Where-Object { $_.Kind -in 'error', 'warn' }).Count
  $lblDevCount.Text = Get-Text 'DevCount' $script:Devices.Count $on $bad
  $navDevices.Tag.Count = "$($script:Devices.Count)"; $navDevices.Invalidate(); try { Update-UpdateBadges } catch { }
  $upd = try { Get-PublishedUpdate } catch { '?' }
  if ($script:Rollout -and $script:Rollout.Pinned) { $upd = Get-Text 'UpdFleetPinned' $upd $script:Rollout.Fleet $script:Rollout.Pilots.Count }
  $barText.Text = Get-Text 'StatusBar' $script:Folder $script:Devices.Count $on $upd (Get-Date) $(if ($renamed.Count) { Get-Text 'StatusRenamed' ($renamed -join ', ') } else { '' })
  if ($script:Selected) { Update-DeviceHeader $script:Selected }
}

# header of the selected device: refreshed with the list, without touching the settings being edited
function Update-DeviceHeader($d) {
  if (-not $d) {
    $lblDevName.Text = Get-Text 'NoDevice'; $lblDevState.Visible = $false; $lblDevInfo.Text = ''
    $btnRemoteDev.Enabled = $false; $btnPowerDev.Enabled = $false; $btnGroupDev.Enabled = $false; $btnBrandDev.Enabled = $false; $btnTrackDev.Enabled = $false; $btnVpnDev.Visible = $false; $btnDot1xDev.Visible = $false; return
  }
  $s = $d.S
  $lblDevName.Text = $d.Name
  $lblDevState.Text = $d.State; $lblDevState.ForeColor = $script:KindColor[$d.Kind]; $lblDevState.BackColor = $script:KindSoft[$d.Kind]; $lblDevState.Visible = $true
  $lblDevState.Location = New-Object System.Drawing.Point(($lblDevName.Right + 12), ($lblDevName.Top + [int](($lblDevName.Height - $lblDevState.Height) / 2) + 1))
  $dot = "   $([char]0x00B7)   "; $parts = @()
  $ip = ([string]$s['IP']) -replace '/.*$', ''; if ($ip) { $parts += $ip }
  $v = Get-Version $s; if ($v) { $parts += Get-Text 'DevVersion' $v }
  $parts += Get-Text 'DevLastReport' (Get-Seen $d)
  $u = Get-SessionUser $s
  $parts += if ($u -and $u -eq (Get-Text 'UserKiosk') -and $s['SESSION'] -in $null, '', 'none') { Get-Text 'DevKioskPage' } elseif ($u) { Get-Text 'DevSessionOf' $u } else { Get-Text 'DevNoSession' }
  # a pilot device, or one on a version of its own (like all devices: nothing to say)
  if ($script:Rollout) { $t = Get-DeviceTrack $d.Name $script:Rollout
    if ($t.Kind -eq 'pilot') { $parts += Get-Text 'DevPilot' } elseif ($t.Kind -eq 'own') { $parts += Get-Text 'DevOwnVersion' $t.Target } }
  $lblDevInfo.Text = $parts -join $dot
  $btnRemoteDev.Enabled = $true; $btnPowerDev.Enabled = $true; $btnGroupDev.Enabled = $true; $btnBrandDev.Enabled = $true; $btnTrackDev.Enabled = $true; $btnVpnDev.Visible = ($s['CFG_VPN'] -eq 'openvpn')
  $btnDot1xDev.Visible = ($s['CFG_DOT1X'] -in 'peap', 'tls') -or ($s['CFG_WIFI'] -eq 'on' -and $s['CFG_WIFI_SECURITY'] -in 'peap', 'tls')
  Set-DeviceActionsFit
}
# what a device installs, in words: pilot (the newest), its own version, or like all devices
function Get-TrackText($d) {
  $st = $script:Rollout; if (-not $st) { return '' }
  $t = Get-DeviceTrack $d.Name $st
  $newest = if ($st.Latest) { $st.Latest } else { Get-Text 'UpdNone' }
  switch ($t.Kind) {
    'pilot' { Get-Text 'TrackPilot' $newest }
    'own' { Get-Text 'TrackOwn' $t.Target }
    default { Get-Text 'TrackFleet' $(if ($t.Target -eq 'latest') { Get-Text 'TrackNewest' $newest } else { $t.Target }) }
  }
}

# the [Peer] of a device for the configuration of the WireGuard server: its public key and its address in the tunnel
function Get-WgPeerBlock($d) {
  $a = [string]$d.S['CFG_VPN_ADDRESS']; if (-not $a) { $a = [string](Read-ConfFile (Get-HostFile $d.Name))['VPN_ADDRESS'] }
  $a = $a -replace '/.*$', ''
  "# $($d.Name)`r`n[Peer]`r`nPublicKey = $($d.S['VPN_PUBLIC_KEY'])`r`nAllowedIPs = $(if ($a) { "$a/32" } else { '<VPN_ADDRESS>/32' })`r`n"
}
function Update-Summary($d) {
  $s = $d.S
  $net = @(@('ColIp', $s['IP']), @('ColMac', $s['MAC']), @('ColNetwork', $s['NETWORK']), @('ColWifi', $s['WIFI_STATUS']))
  # the VPN (0.1.14 and later); the WireGuard key is copied as the [Peer] block the server needs for this device
  if ($s['VPN'] -and $s['VPN'] -ne 'off') { $net += , @('SumVpn', $s['VPN']) }
  if ($s['VPN_PUBLIC_KEY']) { $net += , @('SumVpnKey', $s['VPN_PUBLIC_KEY'], (Get-WgPeerBlock $d)) }
  # 802.1X on the cable, adapter by adapter (since this version)
  if ($s['DOT1X'] -and $s['DOT1X'] -ne 'off') { $net += , @('Sum8021x', $s['DOT1X']) }
  $lvSummary.BeginUpdate(); $lvSummary.Items.Clear(); $lvSummary.Groups.Clear()
  $groups = [ordered]@{
    SumSession = @(@('ColSession', $s['SESSION']), @('ColDefaultUser', $s['DEFAULT_USER']), @('ColTransport', $s['TRANSPORT']), @('ColWebButton', $(
      $w = [string]$s['CFG_WEB_BUTTON']; if ($s['CFG_POWER_ON_TIME'] -or $s['CFG_POWER_OFF_TIME']) { $w += "   ($($s['CFG_POWER_ON_TIME'])-$($s['CFG_POWER_OFF_TIME']))" }; $w)))
    SumNetwork = $net
    SumSoftware = @(@('ColSoftware', $s['SOFTWARE']), @('ColFreeRdp', $s['FREERDP']), @('ColShareUpdate', $s['SHARE_UPDATE']), @('SumUpdateKeys', $(
      # where the updates come from, which signature they need, and the site key the device has (0.1.13 and later)
      if ($s['UPDATE_KEY']) { Get-Text 'SumUpdateKeysValue' $s['UPDATE_FROM'] $s['UPDATE_KEY'] $(if ($s['SITE_KEY'] -match '^[0-9A-F]{40}$') { ($s['SITE_KEY'] -replace '(.{4})', '$1 ').Trim() } else { Get-Text 'SumSiteKeyNone' }) }
      else { [string]$s['UPDATE_FROM'] })), @('SumUpdateTo', $(
      # what the folder asks for, and what the device reports (UPDATE_TO in force there, the update installed)
      $x = Get-TrackText $d
      if ($s.ContainsKey('UPDATE_TO')) { $x += '   ' + (Get-Text 'SumUpdateToReported' $s['UPDATE_TO'] $s['UPDATE_VERSION']) } elseif ($x) { $x += '   ' + (Get-Text 'SumUpdateToOld') }
      $x)), @('ColSecurityUpdates', $(
      $x = [string]$s['SECURITY_UPDATES']; if ($s['LAST_UPDATE']) { $x = Get-Text 'LastUpdate' $x $s['LAST_UPDATE'] }; $x)))
    SumManagement = @(@('ColCentralConfig', $s['CENTRAL_CONFIG']), @('SumSecrets', $s['SECRETS']), @('SumSsh', $s['CFG_SSH']), @('SumRemoteScreen', $s['CFG_REMOTE_SCREEN']), @('ColUptime', $s['UPTIME']))
  }
  foreach ($gk in $groups.Keys) {
    $grp = New-Object System.Windows.Forms.ListViewGroup((Get-Text $gk)); [void]$lvSummary.Groups.Add($grp)
    foreach ($row in $groups[$gk]) {
      $val = [string]$row[1]; if (-not $val) { $val = [string][char]0x2014 }
      $it = New-Object System.Windows.Forms.ListViewItem((Get-Text $row[0]), $grp); $it.ForeColor = $Theme.Muted; $it.UseItemStyleForSubItems = $false
      $sub = $it.SubItems.Add($val); $sub.ForeColor = $Theme.Text
      $it.Tag = if ($row.Count -gt 2) { $row[2] } else { [string]$row[1] }
      [void]$lvSummary.Items.Add($it)
    }
  }
  $lvSummary.EndUpdate()
}

function Show-Device($d) {
  $script:Selected = $d
  Update-DeviceHeader $d
  if (-not $d) { $gridDev.Rows.Clear(); $txtStatus.Text = ''; $txtEvents.Text = ''; $lvSummary.Items.Clear(); return }
  $txtStatus.Text = (Read-Lines (Join-Path $script:StatusDir "$($d.File).txt")) -join "`r`n"
  $ev = @(Read-Lines (Join-Path $script:StatusDir "$($d.File)-events.log") | Where-Object { $_ })
  $txtEvents.Text = ($ev | Select-Object -Last 400) -join "`r`n"
  $txtEvents.SelectionStart = $txtEvents.Text.Length; $txtEvents.ScrollToCaret()
  Update-Summary $d
  Update-DeviceGrid
}

# value reported by the device for a setting (the secrets never come back as such)
function Get-ReportedValue($d, $s) {
  if ($s.Key -eq 'WIFI_PSK') { return (Get-Text 'ValNeverReadBack') }
  $v = if ($s.Key -eq 'HOSTNAME') { $d.S['HOSTNAME'] } else { $d.S["CFG_$($s.Key)"] }
  if ($null -eq $v) { return $null }
  if ($s.Key -eq 'SETTINGS_PIN_SHA256') { if ($v) { return $script:MarkSet } else { return (Get-Text 'ValNoPin') } }
  $v
}

function Update-DeviceGrid {
  $d = $script:Selected; if (-not $d) { return }
  $script:Loading = $true
  $common = Read-ConfFile $script:CommonFile
  # the settings of its group count as common ones for this device (between common.conf and its own file)
  $gc = @{}; if ($d.Group) { $gc = Read-ConfFile (Join-Path (Join-Path (Get-GroupsDir) $d.Group) '_group.conf'); foreach ($k in @($gc.Keys)) { $common[$k] = $gc[$k] } }
  $exc = Read-ConfFile (Get-HostFile $d.Name)
  $gridDev.Rows.Clear(); $section = $null
  $arrow = [string][char]0x2192
  foreach ($s in $script:Settings) {
    if ($s.Section -ne $section) { $section = $s.Section; Add-SectionRow $gridDev $section 4 }
    $now = Get-ReportedValue $d $s
    $nowText = if ($null -eq $now) { Get-Text 'ValNotReported' } else { $now }
    $use = $exc.Contains($s.Key)
    $inCommon = -not $s.HostOnly -and $common.Contains($s.Key)
    # where the value in force comes from, and the one on its way when the device has not applied it yet
    $src = if ($use) { 'SrcThis' } elseif ($inCommon -and $gc.Contains($s.Key)) { 'SrcGroup' } elseif ($inCommon) { 'SrcCommon' } else { 'SrcDevice' }
    $srcText = if ($src -eq 'SrcGroup') { Get-Text 'SrcGroup' $d.Group } else { Get-Text $src }
    $target = if ($use) { $exc[$s.Key] } elseif ($inCommon) { $common[$s.Key] } else { $null }
    $pending = $false
    if ($null -ne $target -and $null -ne $now -and $s.Key -notin 'WIFI_PSK', 'SETTINGS_PIN_SHA256') { $pending = (ConvertTo-Canonical $s.Key $target) -cne [string]$now }
    $i = $gridDev.Rows.Add(); $r = $gridDev.Rows[$i]
    $r.Cells[0].Value = $s.Label; $r.Cells[1].Value = [string]$nowText; $r.Tag = $s
    # on its way: where it comes from and the value in the tooltip, the cell stays short
    $r.Cells[2].Value = if ($pending) { "$arrow " + (Get-Text 'SrcPending') } else { $srcText }
    $r.Cells[2].Style.ForeColor = if ($pending) { $script:KindColor.warn } elseif ($use) { New-Color '#a16207' } elseif ($inCommon) { $Theme.Accent } else { $Theme.Muted }
    $r.Cells[2].ToolTipText = if ($pending) { Get-Text 'TipPending' $srcText (ConvertTo-Canonical $s.Key $target) } elseif ($s.HostOnly) { Get-Text 'ValDeviceOnly' } elseif ($common.Contains($s.Key)) { "$(if ($gc.Contains($s.Key)) { "groups\$($d.Group)\_group.conf" } else { 'common.conf' }): $(if ($s.Key -in 'WIFI_PSK', 'SETTINGS_PIN_SHA256') { $script:MarkSaved } else { $common[$s.Key] })" } else { Get-Text 'ValDeviceDecides' }
    $r.Cells[1].ToolTipText = [string]$nowText
    # without an exception the cell proposes the current value: ticking the box alone pins it
    $init = if ($use) { $exc[$s.Key] } elseif ($null -ne $now -and $s.Key -ne 'SETTINGS_PIN_SHA256') { $now } else { '' }
    if ($s.Key -eq 'WIFI_PSK') { $init = if ($use) { $script:MarkSaved } else { '' } }
    if ($s.Key -eq 'SETTINGS_PIN_SHA256' -and $use) { $init = if ($exc[$s.Key]) { $script:MarkSet } else { '' } }
    Set-Cell $r 3 $s $init
    $r.Cells[4].Value = $use
    Set-RowLook $r 3 4 $Theme.Own
  }
  $ign = @(Get-IgnoredKeys $exc)
  if ($ign.Count) { $barText.Text = Get-Text 'IgnoredKeysDevice' $d.Name ($ign -join ', ') }
  Set-GridFilter $gridDev $filterDev.Tag.Box.Text
  $gridDev.CurrentCell = $null; Show-Help $helpDev $null
  $script:Loading = $false; Set-Dirty 'dev' $false
}

function Update-CommonGrid {
  $script:Loading = $true
  $cf = if ($script:ScopeGroup) { Join-Path (Join-Path (Get-GroupsDir) $script:ScopeGroup) '_group.conf' } else { $script:CommonFile }
  $common = Read-ConfFile $cf
  # a group: what it does not set comes from the site (shown, not highlighted: valid from the site down)
  $site = if ($script:ScopeGroup) { Read-ConfFile $script:CommonFile } else { @{} }
  $commented = @{}
  foreach ($l in (Read-Lines $cf)) { if ($l -cmatch '^\s*#\s*([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*$') { $commented[$Matches[1]] = $Matches[2] } }
  $gridCom.Rows.Clear(); $section = $null
  foreach ($s in @($script:Settings | Where-Object { -not $_.HostOnly })) {
    if ($s.Section -ne $section) { $section = $s.Section; Add-SectionRow $gridCom $section 2 }
    $i = $gridCom.Rows.Add(); $r = $gridCom.Rows[$i]; $r.Tag = $s
    $r.Cells[0].Value = $s.Label
    # value proposed when the key is not managed yet: the commented line, else the first device that
    # reports it, else the project default
    $v = if ($common.Contains($s.Key)) { $common[$s.Key] } elseif ($site.Contains($s.Key)) { $site[$s.Key] } elseif ($commented.ContainsKey($s.Key)) { $commented[$s.Key] } else {
      $dd = $script:Devices | Where-Object { $null -ne $_.S["CFG_$($s.Key)"] } | Select-Object -First 1
      if ($dd) { $dd.S["CFG_$($s.Key)"] } else { $s.Default } }
    if ($s.Key -eq 'WIFI_PSK') { $v = if ($common.Contains('WIFI_PSK')) { $script:MarkSaved } else { '' } }
    if ($s.Key -eq 'SETTINGS_PIN_SHA256') { $v = if ($common[$s.Key]) { $script:MarkSet } else { '' } }
    Set-Cell $r 1 $s $v
    $r.Cells[2].Value = $common.Contains($s.Key)
    Set-RowLook $r 1 2 $Theme.Managed
  }
  $ign = @(Get-IgnoredKeys $common -Common)
  if ($ign.Count) { $barText.Text = Get-Text 'IgnoredKeysCommon' ($ign -join ', ') }
  Set-GridFilter $gridCom $filterCom.Tag.Box.Text
  $gridCom.CurrentCell = $null; Show-Help $helpCom $null
  $script:Loading = $false; Set-Dirty 'com' $false
}

function Update-KeysView {
  $script:Loading = $true
  $txtKeys.Text = if (Test-Path -LiteralPath $script:KeysFile) { (Read-Lines $script:KeysFile) -join "`r`n" } else { '' }
  $txtKeys.SelectionStart = 0; $txtKeys.SelectionLength = 0     # all selected, one key press would erase the list
  $script:Loading = $false; Set-Dirty 'keys' $false
}

function Save-Device {
  $d = $script:Selected; if (-not $d) { return }
  [void]$gridDev.EndEdit()
  $plan = Get-DeviceSavePlan $d (Get-GridValues $gridDev 3 4)
  if ($plan.Errors.Count) { Show-Message (Get-Text 'MsgInvalidTitle') ((Get-Text 'MsgNotSaved') + "`r`n`r`n- " + ($plan.Errors -join "`r`n- ")); return }
  if (-not $plan.Changes.Count) { Show-Message (Get-Text 'MsgNoChangesTitle') (Get-Text 'MsgNoChanges') 'Information'; return }
  $extra = if ($plan.Notes.Count) { "`r`n`r`n" + ($plan.Notes -join "`r`n`r`n") } else { '' }
  if (-not (Confirm-Action (Get-Text 'ConfirmSaveDeviceTitle' $d.Name) ((Get-Text 'ConfirmSaveDevice' $d.Name) + "`r`n`r`n- " + ($plan.Changes -join "`r`n- ") + $extra))) { return }
  try { [void](Write-ConfFile $plan.File $plan.Values $script:HostHeader $plan.RenameMac) } catch { Show-Message (Get-Text 'MsgErrorTitle') (Get-Text 'MsgSaveFailed' $_.Exception.Message) 'Error'; return }
  $barText.Text = Get-Text 'SavedDevice' $plan.File (Get-Text 'ColSource')
  Update-DeviceGrid
}

function Clear-Device {
  $d = $script:Selected; if (-not $d) { return }
  $f = Get-HostFile $d.Name
  if (-not (Test-Path -LiteralPath $f)) { Show-Message (Get-Text 'MsgNoExceptionsTitle') (Get-Text 'MsgNoExceptions' $d.Name) 'Information'; return }
  if (-not (Confirm-Action (Get-Text 'ConfirmRemoveTitle') (Get-Text 'ConfirmRemove' $d.Name) 'Button2')) { return }
  # an empty file, not no file: a device that finds no file of its own keeps its last settings (a file moved by hand,
  # a folder copied in part, a version that does not see groups); an empty one says "no exceptions any more"
  Copy-Item -LiteralPath $f -Destination (Get-BackupPath $f)
  [IO.File]::WriteAllText($f, (($script:HostHeader -join "`r`n") + "`r`n"), $script:Utf8)
  Add-ChangeLog "$($d.Name).conf: all exceptions removed"
  Update-DeviceGrid
}

function Save-Common {
  # a group: the same checks as common.conf, on the file of the group
  if ($script:ScopeGroup) {
    $keep = $script:CommonFile, $script:CommonHeader
    $script:CommonFile = Join-Path (Join-Path (Get-GroupsDir) $script:ScopeGroup) '_group.conf'
    $script:CommonHeader = @("# Settings for the devices of the group $($script:ScopeGroup) (written by the OpenThinRDP manager).", '')
    try { Save-CommonScope } finally { $script:CommonFile, $script:CommonHeader = $keep }
    return
  }
  Save-CommonScope
}
function Save-CommonScope {
  [void]$gridCom.EndEdit()
  $plan = Get-CommonSavePlan (Get-GridValues $gridCom 1 2) $script:Devices
  if ($plan.Errors.Count) { Show-Message (Get-Text 'MsgInvalidTitle') ((Get-Text 'MsgNotSaved') + "`r`n`r`n- " + ($plan.Errors -join "`r`n- ")); return }
  if (-not $plan.Changes.Count) { Show-Message (Get-Text 'MsgNoChangesTitle') (Get-Text 'MsgNoChanges') 'Information'; return }
  $extra = ''
  if ($plan.Warnings.Count) {
    $w = @($plan.Warnings | Select-Object -First 15); if ($plan.Warnings.Count -gt 15) { $w += Get-Text 'MsgMoreWarnings' ($plan.Warnings.Count - 15) }
    $extra += "`r`n`r`n" + (Get-Text 'MsgWillReject') + "`r`n- " + ($w -join "`r`n- ")
  }
  if ($plan.Notes.Count) { $extra += "`r`n`r`n" + ($plan.Notes -join "`r`n`r`n") }
  # with problems the safe answer is No
  $def = if ($plan.Warnings.Count -or $plan.Notes.Count) { 'Button2' } else { 'Button1' }
  if (-not (Confirm-Action (Get-Text 'ConfirmSaveCommonTitle') ((Get-Text 'ConfirmSaveCommon') + "`r`n`r`n- " + ($plan.Changes -join "`r`n- ") + $extra) $def)) { return }
  try { [void](Write-ConfFile $plan.File $plan.Values $script:CommonHeader) } catch { Show-Message (Get-Text 'MsgErrorTitle') (Get-Text 'MsgSaveFailed' $_.Exception.Message) 'Error'; return }
  $barText.Text = Get-Text 'SavedCommon' $plan.File (Get-Text 'ColSource')
  Update-CommonGrid
  if ($script:Selected) { Update-DeviceGrid }
}

# the device file ($dev) or common.conf ($null) as text; unsaved changes of the page first (one place edits at a time)
# the settings of a group as text: the same checks as common.conf (a group may not set what identifies a device)
function Show-GroupTextDialog([string]$group) {
  $keep = $script:CommonFile, $script:CommonHeader; $script:InGroupText = $true
  $script:CommonFile = Join-Path (Join-Path (Get-GroupsDir) $group) '_group.conf'
  $script:CommonHeader = @("# Settings for the devices of the group $group (written by the OpenThinRDP manager).", '')
  try { Show-ConfTextDialog $null } finally { $script:CommonFile, $script:CommonHeader = $keep; $script:InGroupText = $false; Update-CommonGrid }
}
function Show-ConfTextDialog($dev) {
  if (($dev -and $lblDirtyDev.Visible) -or (-not $dev -and -not $script:InGroupText -and $lblDirtyCom.Visible)) { Show-Message (Get-Text 'MsgTextDirtyTitle') (Get-Text 'MsgTextDirty') 'Information'; return }
  $f = if ($dev) { Get-HostFile $dev.Name } else { $script:CommonFile }
  $orig = if (Test-Path -LiteralPath $f) { @(Read-Lines $f) } elseif ($dev) { $script:HostHeader } else { $script:CommonHeader }
  $dlg = New-Object System.Windows.Forms.Form; Set-WindowIcon $dlg
  $dlg.Text = Get-Text 'TextTitle' ([IO.Path]::GetFileName($f)); $dlg.Font = $fontBase; $dlg.StartPosition = 'CenterParent'; $dlg.MinimizeBox = $false
  $dlg.ClientSize = New-Object System.Drawing.Size(860, 620); $dlg.MinimumSize = New-Object System.Drawing.Size(560, 380)
  $top = New-Object System.Windows.Forms.Label; $top.Dock = 'Top'; $top.Height = 44; $top.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 0)
  $top.Text = (Get-Text 'TextHint') + "`r`n" + $f; $top.ForeColor = $Theme.Muted
  $tb = New-Object System.Windows.Forms.TextBox; $tb.Multiline = $true; $tb.ScrollBars = 'Both'; $tb.AcceptsReturn = $true; $tb.AcceptsTab = $false; $tb.WordWrap = $false
  $tb.Font = $fontMono; $tb.Dock = 'Fill'; $tb.Text = (@(ConvertTo-MaskedConf $orig) -join "`r`n")
  $bottom = New-Object System.Windows.Forms.Panel; $bottom.Dock = 'Bottom'; $bottom.Height = 96
  $err = New-Object System.Windows.Forms.TextBox; $err.Multiline = $true; $err.ReadOnly = $true; $err.ScrollBars = 'Vertical'; $err.BorderStyle = 'None'
  $err.ForeColor = $script:KindColor.error; $err.SetBounds(10, 6, 620, 84); $err.Anchor = 'Top, Left, Right, Bottom'
  $ok = New-Button 'BtnSave' 110 28; $cancel = New-Button 'BtnCancel' 100 28
  $cancel.Location = New-Object System.Drawing.Point((860 - 12 - $cancel.Width), 58); $ok.Location = New-Object System.Drawing.Point(($cancel.Left - 8 - $ok.Width), 58)
  $ok.Anchor = 'Bottom, Right'; $cancel.Anchor = 'Bottom, Right'; $cancel.DialogResult = 'Cancel'; $dlg.CancelButton = $cancel
  $bottom.Controls.AddRange(@($err, $ok, $cancel))
  $dlg.Controls.Add($tb); $dlg.Controls.Add($top); $dlg.Controls.Add($bottom)
  $ok.add_Click({
    try { $p = Get-ConfTextPlan $dev $tb.Text } catch { $err.Text = $_.Exception.Message; return }
    if ($p.Errors.Count) { $err.Text = (Get-Text 'MsgNotSaved') + "`r`n- " + ($p.Errors -join "`r`n- "); return }
    if (-not $p.Changes.Count -and (($p.Lines -join "`n").TrimEnd() -ceq ((@($orig) -join "`n").TrimEnd()))) { $dlg.DialogResult = 'Cancel'; return }
    $msg = (Get-Text 'ConfirmText' ([IO.Path]::GetFileName($p.File)))
    if ($p.Changes.Count) { $msg += "`r`n`r`n- " + ($p.Changes -join "`r`n- ") } else { $msg += "`r`n`r`n" + (Get-Text 'TextOnlyComments') }
    if ($p.Warnings.Count) { $w = @($p.Warnings | Select-Object -First 15); $msg += "`r`n`r`n" + (Get-Text 'MsgWillReject') + "`r`n- " + ($w -join "`r`n- ") }
    if ($p.Notes.Count) { $msg += "`r`n`r`n" + ($p.Notes -join "`r`n`r`n") }
    if (-not (Confirm-Action (Get-Text 'TextTitle' ([IO.Path]::GetFileName($p.File))) $msg $(if ($p.Warnings.Count -or $p.Notes.Count) { 'Button2' } else { 'Button1' }))) { return }
    try { Save-ConfText $p } catch { $err.Text = Get-Text 'MsgSaveFailed' $_.Exception.Message; return }
    $dlg.DialogResult = 'OK' })
  try {
    if ($dlg.ShowDialog($form) -eq 'OK') {
      $barText.Text = Get-Text 'SavedText' $f
      Update-CommonGrid; if ($script:Selected) { Update-DeviceGrid }
    }
  } finally { $dlg.Dispose() }
}

function Save-Keys {
  $err = @(Test-AuthorizedKeys $txtKeys.Text)
  if ($err.Count) { Show-Message (Get-Text 'MsgKeysInvalidTitle') ((Get-Text 'MsgKeysNotSaved') + "`r`n`r`n- " + ($err -join "`r`n- ")); return }
  $n = @(Get-KeyLines $txtKeys.Text).Count
  $msg = if ($n) { Get-Text 'ConfirmSaveKeys' $n } else { Get-Text 'ConfirmSaveKeysEmpty' }
  if (-not (Confirm-Action (Get-Text 'ConfirmSaveKeysTitle') $msg $(if ($n) { 'Button1' } else { 'Button2' }))) { return }
  try { $r = Save-AuthorizedKeys $txtKeys.Text } catch { Show-Message (Get-Text 'MsgErrorTitle') (Get-Text 'MsgSaveFailed' $_.Exception.Message) 'Error'; return }
  $barText.Text = Get-Text 'SavedKeys' $script:KeysFile $r.Before $r.After
  Update-KeysView; Update-VaultView
}
# a public key into the list (not saved yet); $false = not a key line
function Add-KeyLine([string]$line) {
  $line = "$line".Trim()
  if ($line -cnotmatch $script:Rx.SshKey) { return $false }
  $body = ($line -split ' ')[1]
  if (@(Get-KeyLines $txtKeys.Text | Where-Object { ($_ -split ' ')[1] -ceq $body }).Count) { $barText.Text = Get-Text 'KeyAlready' (Get-KeyLabel $line); return $true }
  $t = $txtKeys.Text.TrimEnd()
  $txtKeys.Text = $(if ($t) { "$t`r`n$line" } else { $line }) + "`r`n"
  $barText.Text = Get-Text 'KeyAdded' (Get-KeyLabel $line)
  $true
}
# the key of the manager (in the vault, made when missing): the one the remote screen uses
function Add-MyKey {
  if (-not (Request-VaultOpen)) { return }
  if (-not $script:Vault['ssh_public']) {
    try { [void](New-VaultSshKey) } catch { Show-Message (Get-Text 'VaultTitle') $_.Exception.Message 'Error'; return } finally { Update-VaultView }
  }
  [void](Add-KeyLine $script:Vault['ssh_public']); Select-Page 2
}

# ---------------- vault ----------------
# the vault open: created at the first use (asking the code), opened with the code otherwise; $false = not open
function Request-VaultOpen {
  if (Test-VaultOpen) { return $true }
  if (-not (Test-VaultFile)) { return (Start-VaultCreate) }
  $ok = Show-CodeDialog 'Open' $form
  Update-VaultView
  $ok
}
# a new vault: the code, then a new SSH key for the manager, put in the SSH keys list (saved from there)
function Start-VaultCreate {
  if (-not (Show-CodeDialog 'Create' $form)) { Update-VaultView; return $false }
  $line = $null
  try { $line = New-VaultSshKey } catch { Show-Message (Get-Text 'VaultTitle') $_.Exception.Message 'Error' }
  Update-VaultView
  if ($line) { [void](Add-KeyLine $line); Select-Page 2; Show-Message (Get-Text 'VaultTitle') (Get-Text 'VaultCreated') 'Information' }
  $true
}
# the public SSH key of the vault is in config\authorized_keys (saved)
function Test-VaultKeyListed {
  if (-not (Test-VaultOpen) -or -not $script:Vault['ssh_public'] -or -not (Test-Path -LiteralPath $script:KeysFile)) { return $false }
  $body = ([string]$script:Vault['ssh_public'] -split ' ')[1]
  @(Get-KeyLines ((Read-Lines $script:KeysFile) -join "`n") | Where-Object { ($_ -split ' ')[1] -ceq $body }).Count -gt 0
}
function Update-VaultView {
  $open = Test-VaultOpen; $exists = Test-VaultFile
  $state = if ($open) { 'Open' } elseif ($exists) { 'Closed' } else { 'None' }
  $t = Get-Text "VaultTool$state"
  if ($btnVaultTool.Tag -is [hashtable] -and $btnVaultTool.Tag.ContainsKey('Full')) { $btnVaultTool.Tag.Full = $t }
  if ($script:ToolbarCompact) { $btnVaultTool.Text = ''; $tips.SetToolTip($btnVaultTool, $t) } else { $btnVaultTool.Text = $t }
  $btnVaultTool.Image = New-Glyph $(if ($open) { 'Unlock' } else { 'Lock' }) $(if ($state -eq 'None') { $script:KindColor.warn } else { $Theme.ShellText }) 16
  $blkVault.Tag.Note.Text = Get-Text "VaultState$state" $script:VaultFile
  $btnVaultOpen.Text = Get-Text $(if ($open) { 'BtnVaultClose' } elseif ($exists) { 'BtnVaultOpen' } else { 'BtnVaultCreate' })
  $btnVaultOpen.Image = New-Glyph $(if ($open) { 'Lock' } else { 'Unlock' }) ([System.Drawing.Color]::White) 16
  $btnVaultCode.Enabled = $open
  if (-not $open) { $blkSsh.Tag.Note.Text = Get-Text 'VaultClosedNote'; $blkSign.Tag.Note.Text = Get-Text 'VaultClosedNote' }
  else {
    $pub = [string]$script:Vault['ssh_public']
    $blkSsh.Tag.Note.Text = if ($pub) { (Get-KeyLabel $pub) + "   $([char]0x00B7)   " + ($pub -split ' ')[0] + "`r`n" + (Get-Text $(if (Test-VaultKeyListed) { 'VaultSshListed' } else { 'VaultSshNotListed' })) } else { Get-Text 'VaultSshNone' }
    $k = Get-VaultSigningKey
    $blkSign.Tag.Note.Text = if ($k) {
      $fp = ($k.Hex() -replace '(.{4})', '$1 ').Trim()
      $when = [DateTimeOffset]::FromUnixTimeSeconds($k.Created).LocalDateTime.ToString('d')
      Get-Text 'VaultSignSet' $fp $k.User $when (Get-Text "VaultRole_$(Get-SigningKeyRole $k.Hex())")
    } else { Get-Text 'VaultSignNone' }
  }
  foreach ($b in @($btnVaultSshAdd, $btnVaultSshNew, $btnVaultSshImport, $btnVaultSignImport, $btnVaultSignNew)) { $b.Enabled = $open }
  $btnVaultSshAdd.Enabled = $open -and [bool]$script:Vault['ssh_public']
  $btnVaultSign.Enabled = $open -and [bool]$script:Vault['sign_seed']
  $btnVaultSignExport.Enabled = $btnVaultSign.Enabled
  # sending makes sense for a key of the site only: the devices have the project key already
  $btnVaultSignSend.Enabled = $btnVaultSign.Enabled -and [bool](Get-ResignKey)
  Set-VaultHeights
}
function Switch-Vault {
  if (Test-VaultOpen) { Close-Vault; Update-VaultView; $barText.Text = Get-Text 'VaultClosedNow'; return }
  [void](Request-VaultOpen)
}
function Import-SshKeyDialog {
  $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Title = Get-Text 'VaultSshImportTitle'; $ofd.Filter = Get-Text 'VaultSshFilter'
  $d = Join-Path $env:USERPROFILE '.ssh'; if (Test-Path -LiteralPath $d) { $ofd.InitialDirectory = $d }
  if ($ofd.ShowDialog() -ne 'OK') { return }
  if ($script:Vault['ssh_private'] -and -not (Confirm-Action (Get-Text 'VaultTitle') (Get-Text 'VaultSshReplace') 'Button2')) { return }
  try { $line = Import-VaultSshKey $ofd.FileName } catch { Show-Message (Get-Text 'VaultTitle') $_.Exception.Message 'Error'; return } finally { Update-VaultView }
  Show-Message (Get-Text 'VaultTitle') (Get-Text 'VaultSshImported' (Get-KeyLabel $line) $ofd.FileName) 'Information'
}
function New-SshKeyAction {
  if (-not (Confirm-Action (Get-Text 'VaultTitle') (Get-Text $(if ($script:Vault['ssh_private']) { 'VaultSshReplace' } else { 'VaultSshNewConfirm' })) 'Button2')) { return }
  try { $line = New-VaultSshKey } catch { Show-Message (Get-Text 'VaultTitle') $_.Exception.Message 'Error'; return } finally { Update-VaultView }
  [void](Add-KeyLine $line); Select-Page 2
}
function Import-SigningKeyDialog {
  $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Title = Get-Text 'VaultSignImportTitle'; $ofd.Filter = Get-Text 'VaultSignFilter'
  if ($ofd.ShowDialog() -ne 'OK') { return }
  if ($script:Vault['sign_seed'] -and -not (Confirm-Action (Get-Text 'VaultTitle') (Get-Text 'VaultSignReplace' $script:Vault['sign_fingerprint']) 'Button2')) { return }
  try { $k = Import-VaultSigningKey $ofd.FileName } catch { Show-Message (Get-Text 'VaultTitle') (Get-Text 'VaultSignNotValid' $_.Exception.Message) 'Error'; return } finally { Update-VaultView }
  Add-ChangeLog "vault: signing key $($k.Hex()) imported"
  # the exported file holds the key without any protection
  if (Confirm-Action (Get-Text 'VaultTitle') (Get-Text 'VaultSignDeleteFile' $k.Hex() $ofd.FileName)) {
    try { Remove-Item -LiteralPath $ofd.FileName -Force } catch { Show-Message (Get-Text 'VaultTitle') $_.Exception.Message 'Error' }
  }
}
# a new key of this site, in the vault; then its public half to save (update-key.asc)
function New-SiteKeyAction {
  $msg = if ($script:Vault['sign_seed']) { Get-Text 'VaultSignNewReplace' $script:Vault['sign_fingerprint'] } else { Get-Text 'VaultSignNewConfirm' }
  if (-not (Confirm-Action (Get-Text 'VaultTitle') $msg $(if ($script:Vault['sign_seed']) { 'Button2' } else { 'Button1' }))) { return }
  Add-Type -AssemblyName Microsoft.VisualBasic
  $def = if ($env:USERDNSDOMAIN) { "Thin client updates ($($env:USERDNSDOMAIN.ToLower()))" } else { 'Thin client updates' }
  $user = [Microsoft.VisualBasic.Interaction]::InputBox((Get-Text 'VaultSignNewName'), (Get-Text 'VaultTitle'), $def).Trim()
  if (-not $user) { return }
  if ($user.Length -gt 100 -or $user -match '[\x00-\x1f]') { Show-Message (Get-Text 'VaultTitle') (Get-Text 'VaultSignNewBadName'); return }
  try { $k = New-VaultSiteKey $user } catch { Show-Message (Get-Text 'VaultTitle') $_.Exception.Message 'Error'; return } finally { Update-VaultView }
  Add-ChangeLog "vault: new site key $($k.Hex()) ($user)"
  Show-Message (Get-Text 'VaultTitle') (Get-Text 'VaultSignNewDone' $k.Hex()) 'Information'
  Export-PublicKeyDialog
}
# the site key to every device that reports a different one (or none): over SSH, one by one, with the result of each
function Send-SiteKeyAction {
  $k = Get-VaultSigningKey; $key = Get-VaultKeyFile
  if (-not $k) { return }
  if (-not $key) { Show-Message (Get-Text 'VaultTitle') (Get-Text 'ErrRemoteNoVaultKey'); return }
  $fp = $k.Hex()
  $todo = @($script:Devices | Where-Object { $_.Kind -ne 'off' -and $_.S['SITE_KEY'] -ne $fp })
  $off = @($script:Devices | Where-Object { $_.Kind -eq 'off' -and $_.S['SITE_KEY'] -ne $fp })
  if (-not $todo.Count) { Show-Message (Get-Text 'VaultTitle') (Get-Text 'SendKeyNothing' $fp $off.Count) 'Information'; return }
  if (-not (Confirm-Action (Get-Text 'VaultTitle') (Get-Text 'SendKeyConfirm' $fp ($todo.Name -join ', ') $off.Count))) { return }
  $armored = [OtrVault]::ExportPublic($k); $lines = @()
  $form.Cursor = 'WaitCursor'
  try {
    foreach ($d in $todo) {
      $barText.Text = Get-Text 'SendKeyRunning' $d.Name; [System.Windows.Forms.Application]::DoEvents()
      $why = Send-SiteKey $d $key $armored
      $lines += if ($why) { "$([char]0x2717) $($d.Name): $why" } else { "$([char]0x2713) $($d.Name)" }
    }
  } finally { $form.Cursor = 'Default'; $barText.Text = '' }
  Add-ChangeLog "site key $fp sent over SSH: $(@($lines | ForEach-Object { $_.Substring(2) }) -join '; ')"
  Show-Message (Get-Text 'VaultTitle') ((Get-Text 'SendKeyDone' $fp $off.Count) + "`r`n`r`n" + ($lines -join "`r`n")) 'Information'
}
function Export-PublicKeyDialog {
  $sfd = New-Object System.Windows.Forms.SaveFileDialog; $sfd.Title = Get-Text 'VaultSignExportTitle'; $sfd.FileName = 'update-key.asc'
  $sfd.Filter = 'update-key.asc|*.asc'
  if ($sfd.ShowDialog() -ne 'OK') { return }
  try { $k = Export-VaultPublicKey $sfd.FileName } catch { Show-Message (Get-Text 'VaultTitle') $_.Exception.Message 'Error'; return }
  Show-Message (Get-Text 'VaultTitle') (Get-Text 'VaultSignExported' $sfd.FileName $k.Hex()) 'Information'
}
function Invoke-SignDialog {
  $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Title = Get-Text 'SignTitle'; $ofd.Filter = 'LATEST.txt|LATEST.txt|*.txt|*.txt'
  if ($ofd.ShowDialog() -ne 'OK') { return }
  try { $r = Invoke-SignUpdate $ofd.FileName } catch { Show-Message (Get-Text 'SignTitle') $_.Exception.Message 'Error'; return }
  Add-ChangeLog "update $($r.Version) signed with key $($r.Fingerprint) ($($r.Signature))"
  $m = Get-Text 'SignDone' $r.Version $r.Fingerprint (Get-Text "SignRole_$($r.Role)") $r.Signature
  if (-not $r.PackageChecked) { $m += "`r`n`r`n" + (Get-Text 'SignNoPackage') }
  Show-Message (Get-Text 'SignTitle') $m 'Information'
}
function Add-KeyFromFile {
  $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Title = Get-Text 'KeyFileTitle'; $ofd.Filter = Get-Text 'KeyFilter'
  $d = Join-Path $env:USERPROFILE '.ssh'; if (Test-Path -LiteralPath $d) { $ofd.InitialDirectory = $d }
  if ($ofd.ShowDialog() -ne 'OK') { return }
  $n = 0; foreach ($l in (Read-Lines $ofd.FileName)) { if (Add-KeyLine $l) { $n++ } }
  if (-not $n) { Show-Message (Get-Text 'KeyTitle') (Get-Text 'KeyNotValid' $ofd.FileName) }
}

# Logo and background picture of every device ($d = $null) or of one device: a preview on the background colors, where the
# picture comes from, Choose... and Remove for this level
function Show-BrandingDialog($d) {
  $hostName = if ($d) { $d.Name } else { '' }
  $common = Read-ConfFile $script:CommonFile
  $bgKey = { param($k, $def) $v = if ($d -and $d.S["CFG_$k"]) { $d.S["CFG_$k"] } elseif ($common[$k]) { $common[$k] } else { $def }
             try { [System.Drawing.ColorTranslator]::FromHtml($v) } catch { [System.Drawing.ColorTranslator]::FromHtml($def) } }
  $top = & $bgKey 'BG_TOP' '#1b2733'; $bottom = & $bgKey 'BG_BOTTOM' '#000000'
  $dlg = New-Object System.Windows.Forms.Form; Set-WindowIcon $dlg
  $dlg.Text = if ($d) { Get-Text 'BrandTitleDevice' $hostName } else { Get-Text 'BrandTitleCommon' }
  $dlg.Font = $fontBase; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
  $dlg.StartPosition = 'CenterParent'; $dlg.ClientSize = New-Object System.Drawing.Size(700, 600)
  $note = New-Object System.Windows.Forms.Label; $note.SetBounds(12, 10, 676, 60)
  $note.Text = if ($d) { Get-Text 'BrandNoteDevice' $hostName } else { Get-Text 'BrandNoteCommon' }
  if ($d -and $d.S['BRANDING']) { $note.Text += "`r`n" + (Get-Text 'BrandReported' $d.S['BRANDING']) }
  $dlg.Controls.Add($note)
  $y = 76
  foreach ($kind in @('logo', 'splash')) {
    $box = New-Object System.Windows.Forms.GroupBox; $box.Text = Get-Text $(if ($kind -eq 'logo') { 'BrandLogo' } else { 'BrandSplash' })
    $ph = if ($kind -eq 'logo') { 150 } else { 260 }
    $box.SetBounds(12, $y, 676, $ph + 34); $y += $ph + 44
    $pic = New-Object System.Windows.Forms.PictureBox; $pic.SetBounds(12, 22, 470, $ph); $pic.SizeMode = 'CenterImage'
    $pic.Tag = @{ Top = $top; Bottom = $bottom }
    $pic.add_Paint({ param($s, $e)
      $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($s.ClientRectangle, $s.Tag.Top, $s.Tag.Bottom, 90.0)
      $e.Graphics.FillRectangle($br, $s.ClientRectangle); $br.Dispose()
      if ($s.Tag.Image) { $i = $s.Tag.Image
        $k = [Math]::Min(1.0, [Math]::Min([double]($s.Width - 8) / $i.Width, [double]($s.Height - 8) / $i.Height)); $w = [int]($i.Width * $k); $h = [int]($i.Height * $k)
        $e.Graphics.DrawImage($i, [int](($s.Width - $w) / 2), [int](($s.Height - $h) / 2), $w, $h) }
      elseif ($s.Tag.Text) { [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $s.Tag.Text, $fontBase, $s.ClientRectangle, [System.Drawing.Color]::White) } })
    $lbl = New-Object System.Windows.Forms.Label; $lbl.SetBounds(494, 22, 172, 60)
    $choose = New-Button 'BtnChoose' 172 27; $choose.Location = New-Object System.Drawing.Point(494, 88)
    $remove = New-Button 'BtnRemovePicture' 172 27; $remove.Location = New-Object System.Drawing.Point(494, 121)
    $state = @{ Kind = $kind; Host = $hostName; Pic = $pic; Label = $lbl; Remove = $remove }
    $refresh = {
      param($st)
      $src = Get-BrandingSource $st.Kind $st.Host
      if ($st.Pic.Tag.Image) { $st.Pic.Tag.Image.Dispose(); $st.Pic.Tag.Image = $null }
      $st.Pic.Tag.Text = ''
      if ($src.File) { try { $st.Pic.Tag.Image = Read-Picture $src.File } catch { $st.Pic.Tag.Text = $_.Exception.Message } }
      else { $st.Pic.Tag.Text = Get-Text 'BrandImageOwn' }
      $size = if ($st.Pic.Tag.Image) { "{0} x {1} px" -f $st.Pic.Tag.Image.Width, $st.Pic.Tag.Image.Height } else { '' }
      $st.Label.Text = switch ($src.From) { 'device' { Get-Text 'BrandFromDevice' $size } 'common' { Get-Text 'BrandFromCommon' $size } default { Get-Text 'BrandFromImage' } }
      # Remove only what belongs to this level: a device cannot remove the common picture
      $st.Remove.Enabled = Test-Path -LiteralPath (Get-BrandingFile $st.Kind $st.Host)
      $st.Pic.Invalidate()
    }
    $choose.Tag = @{ State = $state; Refresh = $refresh }; $remove.Tag = $choose.Tag
    $choose.add_Click({ param($s, $e)
      $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Title = Get-Text 'BrandChooseTitle'; $ofd.Filter = Get-Text 'BrandFilter'
      if ($ofd.ShowDialog() -ne 'OK') { return }
      try { $r = Save-BrandingImage $ofd.FileName $s.Tag.State.Kind $s.Tag.State.Host; $barText.Text = Get-Text 'SavedBranding' $r.File $r.Width $r.Height }
      catch { Show-Message (Get-Text 'MsgErrorTitle') $_.Exception.Message 'Error' }
      & $s.Tag.Refresh $s.Tag.State })
    $remove.add_Click({ param($s, $e)
      if (-not (Confirm-Action (Get-Text 'BrandRemoveTitle') (Get-Text 'BrandRemoveConfirm') 'Button2')) { return }
      try { if (Remove-BrandingImage $s.Tag.State.Kind $s.Tag.State.Host) { $barText.Text = Get-Text 'RemovedBranding' (Get-BrandingFile $s.Tag.State.Kind $s.Tag.State.Host) } }
      catch { Show-Message (Get-Text 'MsgErrorTitle') $_.Exception.Message 'Error' }
      & $s.Tag.Refresh $s.Tag.State })
    $box.Controls.AddRange(@($pic, $lbl, $choose, $remove)); $dlg.Controls.Add($box)
    & $refresh $state
  }
  $close = New-Button 'BtnClose' 100 27; $close.Location = New-Object System.Drawing.Point((688 - $close.Width), ($y + 2)); $close.DialogResult = 'Cancel'
  $dlg.Controls.Add($close); $dlg.CancelButton = $close
  $dlg.ClientSize = New-Object System.Drawing.Size(700, ($y + 40)); $dlg.Tag = $dlg.ClientSize
  if ($env:OTR_MANAGER_HCSET_SHOT) { $form.add_Shown({ Show-HealthSettingsDialog; $form.Close() }) }
if ($env:OTR_MANAGER_BRANDING_SHOT) {   # test: draws the dialog into a PNG and closes it
    # control by control at their own size: Windows clamps the dialog to a small test screen, not its controls
    $dlg.add_Shown({ try { $dlg.Refresh(); $cs = $dlg.Tag; $b = New-Object System.Drawing.Bitmap($cs.Width, $cs.Height)
      $gb = [System.Drawing.Graphics]::FromImage($b); $gb.Clear($dlg.BackColor); $gb.Dispose()
      foreach ($c in $dlg.Controls) { $c.DrawToBitmap($b, $c.Bounds) }
      $b.Save($env:OTR_MANAGER_BRANDING_SHOT, [System.Drawing.Imaging.ImageFormat]::Png)
    } catch { [Console]::Error.WriteLine("branding screenshot failed: $($_.Exception.Message)") } finally { $dlg.Close() } })
  }
  [void]$dlg.ShowDialog($form)
  foreach ($c in $dlg.Controls) { if ($c -is [System.Windows.Forms.GroupBox]) { foreach ($p in $c.Controls) { if ($p -is [System.Windows.Forms.PictureBox] -and $p.Tag.Image) { $p.Tag.Image.Dispose() } } } }
  $dlg.Dispose()
}

# changing a value ticks "exception" / "managed here" by itself; the tick colours the row
$gridDev.add_CellValueChanged({ param($s, $e)
  if ($script:Loading -or $e.RowIndex -lt 0 -or $null -eq $gridDev.Rows[$e.RowIndex].Tag) { return }
  $r = $gridDev.Rows[$e.RowIndex]
  if ($e.ColumnIndex -eq 3) { $r.Cells[4].Value = $true }
  Set-RowLook $r 3 4 $Theme.Own; Set-Dirty 'dev' $true })
$gridCom.add_CellValueChanged({ param($s, $e)
  if ($script:Loading -or $e.RowIndex -lt 0 -or $null -eq $gridCom.Rows[$e.RowIndex].Tag) { return }
  $r = $gridCom.Rows[$e.RowIndex]
  if ($e.ColumnIndex -eq 1) { $r.Cells[2].Value = $true }
  Set-RowLook $r 1 2 $Theme.Managed; Set-Dirty 'com' $true })
foreach ($g in @($gridDev, $gridCom)) {
  $g.add_CurrentCellDirtyStateChanged({ param($s, $e) if ($s.IsCurrentCellDirty) { [void]$s.CommitEdit('CurrentCellChange') } })
  # the help of the selected setting under the grid
  $g.add_CurrentCellChanged({ param($s, $e) if ($script:Loading) { return }; $r = $s.CurrentRow; Show-Help $s.Tag $(if ($r) { $r.Tag } else { $null }) })
}
$txtKeys.add_TextChanged({ if (-not $script:Loading) { Set-Dirty 'keys' $true } })

$list.add_SelectedIndexChanged({ if (-not $script:Listing -and $list.SelectedItems.Count -eq 1) { Show-Device $list.SelectedItems[0].Tag } })
$txtDevSearch.add_TextChanged({ Update-DeviceList })
$btnRefresh.add_Click({
  Update-DeviceList
  if ($script:Selected) { $n = $script:Selected.File; $q = $script:Devices | Where-Object File -eq $n | Select-Object -First 1; if ($q) { Show-Device $q } }
  if ($script:Page -eq 3) { Update-ProblemView }
  if ($script:Page -eq 6) { Start-VdiRefresh -Queue } })
$btnOpen.add_Click({ Start-Process explorer.exe $script:Folder })
# ---------------- releases and versions ----------------
# The signature a checked release goes in with: the site key signs it again (the vault opened for it when there is
# one). Site = the key or $null; Text = what the confirmation says about it; Error = it cannot go in.
function Get-ReleaseSigning($rel) {
  if ((Test-VaultFile) -and -not (Test-VaultOpen)) { [void](Request-VaultOpen) }
  $site = Get-ResignKey
  if ($site -and $rel.Signature -ne $true) { return @{ Error = (Get-Text 'RelResignUnchecked') } }
  $t = if ($rel.Signature) { Get-Text 'RelSigChecked' } else { Get-Text 'RelSigNotChecked' }
  $siteOnly = (Read-ConfFile $script:CommonFile)['UPDATE_KEY'] -eq 'site'
  $t += "`r`n" + $(if ($site) { Get-Text 'RelResign' $site.Hex() } elseif ($siteOnly) { Get-Text 'RelNoResignWarn' } else { Get-Text 'RelNoResign' })
  @{ Site = $site; Text = $t; Error = $null }
}
# after UPDATE_TO changed in a file: the grids show it, without losing edits not saved yet (a grid saved later with
# the old value would undo it)
function Sync-UpdateToRows {
  $c = Read-ConfFile $script:CommonFile
  if ($lblDirtyCom.Visible) { Set-GridSetting $gridCom 'UPDATE_TO' $c['UPDATE_TO'] 1 2 $Theme.Managed } else { Update-CommonGrid }
  if ($script:Selected) {
    $h = Read-ConfFile (Get-HostFile $script:Selected.Name)
    if ($lblDirtyDev.Visible) { Set-GridSetting $gridDev 'UPDATE_TO' $h['UPDATE_TO'] 3 4 $Theme.Own } else { Update-DeviceGrid }
  }
  Update-DeviceList; if ($script:Selected) { Update-Summary $script:Selected }; Update-UpdatesView
}
function Set-GridSetting($g, [string]$key, $value, [int]$valueCol, [int]$checkCol, $tint) {
  $script:Loading = $true
  try {
    foreach ($r in $g.Rows) { if ($r.Tag -and $r.Tag.Key -eq $key) {
      if ($null -ne $value) { $r.Cells[$valueCol].Value = [string]$value }
      $r.Cells[$checkCol].Value = ($null -ne $value); Set-RowLook $r $valueCol $checkCol $tint } }
  } finally { $script:Loading = $false }
}
# Release from GitHub: the latest release, checked, to all devices or to the pilot devices only. Pilot only keeps every
# other device on the version published now (UPDATE_TO of common.conf, set BEFORE the new LATEST.txt is there, so that
# no device takes it in between); all devices also ends a pinned fleet (UPDATE_TO=latest).
function Start-ReleaseImport {
  $form.Cursor = 'WaitCursor'
  try { $rel = Get-Release } catch { $rel = [pscustomobject]@{ Ok = $false; Message = $_.Exception.Message } } finally { $form.Cursor = 'Default' }
  if (-not $rel.Ok) { Show-Message (Get-Text 'RelTitle') $rel.Message 'Information'; return }
  try {
    $sg = Get-ReleaseSigning $rel
    if ($sg.Error) { Show-Message (Get-Text 'RelTitle') $sg.Error 'Error'; return }
    $st = Get-RolloutState
    # first what changes from the version published now to this one; then where it goes
    $form.Cursor = 'WaitCursor'; $notes = Get-ReleaseNotes ([string]$st.Latest) $rel.Version; $form.Cursor = 'Default'
    if (-not (Show-NotesDialog (Get-Text 'RelTitle') (Get-Text 'RelNotesIntro' $rel.Version $(if ($st.Latest) { $st.Latest } else { Get-Text 'UpdNone' })) $notes 'BtnNext')) { return }
    # the others stay on the version published now: there must be one, signed, to keep them on
    $l = Join-Path (Get-UpdatesDir) 'LATEST.txt'
    $stay = if ($st.Pinned) { $st.Fleet } elseif ($st.Latest -and (Test-Path -LiteralPath "$l.sig")) { $st.Latest } else { $null }
    $pilots = if ($st.Pilots.Count) { $st.Pilots -join ', ' } else { Get-Text 'RelNoPilots' }
    $opts = @((Get-Text 'RelScopeAll' $rel.Version),
      $(if ($stay) { , @((Get-Text 'RelScopePilot' $st.Pilots.Count $stay $pilots), $true) } else { , @((Get-Text 'RelScopePilotNo'), $false) }))
    $sel = if ($stay -and ($st.Pinned -or $st.Pilots.Count)) { 1 } else { 0 }
    $pick = Show-PickDialog (Get-Text 'RelTitle') (Get-Text 'RelConfirm' $rel.Version (Get-PublishedUpdate) $sg.Text) $opts $sel -okKey 'BtnPublish'
    if (-not $pick) { return }
    # Devices before 0.2.0 do not know UPDATE_TO (their report has no UPDATE_TO line): on the folder they take the new
    # LATEST.txt whatever common.conf says, so pilot only would not hold them back. Said before anything is written.
    if ($pick.Option -eq 1) {
      $old = @($script:Devices | Where-Object { -not $_.S.ContainsKey('UPDATE_TO') -and $st.Pilots -notcontains $_.Name } | ForEach-Object Name | Sort-Object)
      if ($old.Count -and -not (Confirm-Action (Get-Text 'RelTitle') (Get-Text 'RelPilotOldDevices' $old.Count ($old -join ', ') $rel.Version) 'Button2')) { return }
    }
    try {
      if ($pick.Option -eq 1 -and -not $st.Pinned) {
        $v = Initialize-VersionIndex
        if (-not $v) { throw (Get-Text 'RelPilotNoIndex') }
        [void](Set-UpdateTo $v)
      }
      [void](Publish-Release $rel $sg.Site)
      if ($pick.Option -eq 0 -and $st.Pinned) { [void](Set-UpdateTo 'latest') }
      Show-Message (Get-Text 'RelTitle') $(if ($pick.Option -eq 1) { Get-Text 'RelDonePilot' $rel.Version $stay } else { Get-Text 'RelDone' $rel.Version }) 'Information'
    } catch { Show-Message (Get-Text 'RelTitle') (Get-Text 'RelCopyFailed' $_.Exception.Message) 'Error' }
    Sync-UpdateToRows
  } finally { Remove-Item -LiteralPath $rel.Dir -Recurse -Force -ErrorAction SilentlyContinue }
}
# A release of GitHub by its version (tag v<version>), with the checks of Release from GitHub, into updates\ and
# updates\versions\: to keep devices on it or to go back. Returns the version now in updates\versions\, or $null.
function Invoke-FetchVersion {
  Add-Type -AssemblyName Microsoft.VisualBasic
  $v = [Microsoft.VisualBasic.Interaction]::InputBox((Get-Text 'FetchAsk' (Get-ReleaseRepo)), (Get-Text 'FetchTitle'), '').Trim() -replace '^[vV](?=[0-9])', ''
  if (-not $v) { return $null }
  if ($v -cnotmatch $script:Rx.Version -or $v -eq 'latest') { Show-Message (Get-Text 'FetchTitle') (Get-Text 'ErrUpdateTo'); return $null }
  if (@(Get-PublishedVersions | Where-Object { $_.Version -ceq $v -and $_.Usable }).Count) { Show-Message (Get-Text 'FetchTitle') (Get-Text 'FetchAlready' $v) 'Information'; return $v }
  $form.Cursor = 'WaitCursor'
  try { $rel = Get-Release '' $script:ReleaseKey $v } catch { $rel = [pscustomobject]@{ Ok = $false; Message = $_.Exception.Message } } finally { $form.Cursor = 'Default' }
  if (-not $rel.Ok) { Show-Message (Get-Text 'FetchTitle') $rel.Message 'Information'; return $null }
  try {
    $sg = Get-ReleaseSigning $rel
    if ($sg.Error) { Show-Message (Get-Text 'FetchTitle') $sg.Error 'Error'; return $null }
    $cur = Get-CurrentVersion
    $where = if ($cur -and (Compare-Version $v $cur) -le 0) { Get-Text 'FetchOlder' $cur } else { Get-Text 'FetchNewer' $(if ($cur) { $cur } else { Get-Text 'UpdNone' }) }
    if (-not (Confirm-Action (Get-Text 'FetchTitle') (Get-Text 'FetchConfirm' $v $sg.Text $where))) { return $null }
    try { [void](Publish-Release $rel $sg.Site) } catch { Show-Message (Get-Text 'FetchTitle') (Get-Text 'RelCopyFailed' $_.Exception.Message) 'Error'; return $null }
    Update-DeviceList; Update-UpdatesView
    $v
  } finally { Remove-Item -LiteralPath $rel.Dir -Recurse -Force -ErrorAction SilentlyContinue }
}
# the versions that can be chosen: in updates\versions\, signed, with their package (newest first)
function Get-ChoosableVersions { @(Get-PublishedVersions | Where-Object Usable | ForEach-Object Version) }
# "the newest (0.2.0)" or a version, for the texts
function Format-Target([string]$t, $st) { if ($t -eq 'latest') { Get-Text 'TrackNewest' $(if ($st.Latest) { $st.Latest } else { Get-Text 'UpdNone' }) } else { $t } }
# a version older than the newest published: the devices go back to it
function Get-BackText([string]$v, $st) { if ($v -ne 'latest' -and $st.Latest -and (Compare-Version $v $st.Latest) -lt 0) { "`r`n`r`n" + (Get-Text 'VerBack' $v $st.Latest) } else { '' } }
# Release to all devices: the fleet kept on a version goes to the newest (UPDATE_TO=latest in common.conf)
function Start-ReleaseToAll {
  $st = Get-RolloutState
  if (-not $st.Pinned) { Show-Message (Get-Text 'AllTitle') (Get-Text 'AllNothing') 'Information'; return }
  if (-not $st.Latest) { Show-Message (Get-Text 'AllTitle') (Get-Text 'UpdNone') 'Information'; return }
  if (-not (Confirm-Action (Get-Text 'AllTitle') (Get-Text 'AllConfirm' $st.Fleet $st.Latest))) { return }
  try { [void](Set-UpdateTo 'latest') } catch { Show-Message (Get-Text 'MsgErrorTitle') (Get-Text 'MsgSaveFailed' $_.Exception.Message) 'Error'; return }
  $barText.Text = Get-Text 'AllDone' $st.Latest
  Sync-UpdateToRows
}
# Version for all devices: the newest, or one of updates\versions\ (also older: going back); pilots and devices with a
# version of their own keep theirs
function Start-FleetVersion {
  $st = Get-RolloutState
  $opts = @((Get-Text 'FleetOptLatest' $(if ($st.Latest) { $st.Latest } else { Get-Text 'UpdNone' })), (Get-Text 'FleetOptVersion'))
  $pick = Show-PickDialog (Get-Text 'FleetTitle') (Get-Text 'FleetText' (Format-Target $st.Fleet $st)) $opts $(if ($st.Pinned) { 1 } else { 0 }) (Get-ChoosableVersions) $st.Fleet { Invoke-FetchVersion }
  if (-not $pick) { return }
  $v = if ($pick.Option -eq 0) { 'latest' } else { $pick.Version }
  if (-not $v) { return }
  if ($v -eq $st.Fleet) { Show-Message (Get-Text 'MsgNoChangesTitle') (Get-Text 'MsgNoChanges') 'Information'; return }
  $back = Get-BackText $v $st
  if (-not (Confirm-Action (Get-Text 'FleetTitle') (Get-Text 'FleetConfirm' (Format-Target $st.Fleet $st) (Format-Target $v $st) $back) $(if ($back) { 'Button2' } else { 'Button1' }))) { return }
  try { [void](Set-UpdateTo $v) } catch { Show-Message (Get-Text 'MsgErrorTitle') (Get-Text 'MsgSaveFailed' $_.Exception.Message) 'Error'; return }
  $barText.Text = Get-Text 'SavedCommon' $script:CommonFile (Get-Text 'ColSource')
  Sync-UpdateToRows
}
# Software version of one device: like all devices (no UPDATE_TO of its own), pilot (UPDATE_TO=latest), or a version of
# its own (also older: going back)
function Show-DeviceVersionDialog($d) {
  $st = Get-RolloutState; $t = Get-DeviceTrack $d.Name $st
  $opts = @((Get-Text 'DevOptFleet' (Format-Target $st.Fleet $st)), (Get-Text 'DevOptPilot' $(if ($st.Latest) { $st.Latest } else { Get-Text 'UpdNone' })), (Get-Text 'DevOptVersion'))
  $sel = switch ($t.Kind) { 'pilot' { 1 } 'own' { 2 } default { 0 } }
  $installed = if ($d.S['UPDATE_VERSION']) { $d.S['UPDATE_VERSION'] } else { [string][char]0x2014 }
  $text = Get-Text 'DevVerText' $d.Name (Get-Version $d.S) $installed (Get-TrackText $d)
  $pick = Show-PickDialog (Get-Text 'DevVerTitle' $d.Name) $text $opts $sel (Get-ChoosableVersions) $(if ($t.Kind -eq 'own') { $t.Target } else { '' }) { Invoke-FetchVersion }
  if (-not $pick) { return }
  $v = switch ($pick.Option) { 0 { $null } 1 { 'latest' } default { $pick.Version } }
  if ($pick.Option -eq 2 -and -not $v) { return }
  $now = switch ($t.Kind) { 'fleet' { $null } default { $t.Target } }
  if ($v -ceq $now) { Show-Message (Get-Text 'MsgNoChangesTitle') (Get-Text 'MsgNoChanges') 'Information'; return }
  $back = if ($v -and $v -ne 'latest') { Get-BackText $v $st } else { '' }
  $label = { param($k, $x) switch ($k) { 0 { Get-Text 'TrackFleet' (Format-Target $st.Fleet $st) } 1 { Get-Text 'TrackPilot' (Format-Target 'latest' $st) } default { Get-Text 'TrackOwn' $x } } }
  if (-not (Confirm-Action (Get-Text 'DevVerTitle' $d.Name) ((Get-Text 'DevVerConfirm' $d.Name (& $label $sel $t.Target) (& $label $pick.Option $v)) + $back) $(if ($back) { 'Button2' } else { 'Button1' }))) { return }
  try { $plan = Set-UpdateTo $v $d } catch { Show-Message (Get-Text 'MsgErrorTitle') (Get-Text 'MsgSaveFailed' $_.Exception.Message) 'Error'; return }
  $barText.Text = Get-Text 'SavedDevice' $plan.File (Get-Text 'ColSource')
  Sync-UpdateToRows
}
# the Updates page: what is published, what the devices install, and this manager
function Update-UpdatesView {
  $st = $null; try { $st = Get-RolloutState } catch { }
  $lines = @()
  if ($st) {
    $vers = @(Get-ChoosableVersions)
    $lines += Get-Text 'UpdNoteLatest' $(if ($st.Latest) { $st.Latest } else { Get-Text 'UpdNone' })
    # the latest on GitHub (from the check of the manager): newer than the published one, said so
    if ($script:GitHubLatest) { $lines += if ($script:DeviceOffer) { Get-Text 'UpdNoteGitHubNew' $script:GitHubLatest } else { Get-Text 'UpdNoteGitHub' $script:GitHubLatest } }
    $lines += if ($st.Pinned) { Get-Text 'UpdNoteFleetPinned' $st.Fleet } else { Get-Text 'UpdNoteFleetLatest' }
    $lines += if ($st.Pilots.Count) { Get-Text 'UpdNotePilots' $st.Pilots.Count ($st.Pilots -join ', ') } else { Get-Text 'UpdNoPilots' }
    if ($st.Own.Count) { $lines += Get-Text 'UpdNoteOwn' (@($st.Own.Keys | ForEach-Object { "$_ ($($st.Own[$_]))" }) -join ', ') }
    $lines += if ($vers.Count) { Get-Text 'UpdNoteVersions' ($vers -join ', ') } else { Get-Text 'UpdNoVersions' }
    # what the devices run now, from their reports
    $run = @($script:Devices | Where-Object { -not $_.OldName } | Group-Object { Get-Version $_.S } | ForEach-Object { [pscustomobject]@{ Version = $_.Name; N = $_.Count } })
    if ($run.Count) { $lines += Get-Text 'UpdNoteInstalled' (@(Get-NewestFirst $run | ForEach-Object { Get-Text 'UpdOnDevices' $(if ($_.Version) { $_.Version } else { '?' }) $_.N }) -join ', ') }
  }
  $blkFleet.Tag.Note.Text = $lines -join "`r`n"
  $btnUpdAll.Enabled = [bool]($st -and $st.Pinned -and $st.Latest)
  $btnUpdFleet.Enabled = [bool]$st
  # this manager
  $o = $script:ManagerOffer
  $state = if (-not $script:ManagerVersion) { Get-Text 'MgrStatus_Development' } elseif ($script:ManagerChecking) { Get-Text 'MgrChecking' }
    elseif ($script:ManagerCheckError) { Get-Text 'MgrCheckFailed' $script:ManagerCheckError } elseif ($o) { Get-Text "MgrStatus_$($o.Status)" $o.Version } else { Get-Text 'MgrStatus_Unknown' }
  $blkManager.Tag.Note.Text = Get-Text 'MgrNote' $(if ($script:ManagerVersion) { $script:ManagerVersion } else { Get-Text 'MgrDevelopmentShort' }) $script:ManagerDir $state
  # only when there is one: a disabled blue button still looks like the thing to press
  $btnMgrUpdate.Visible = [bool]($o -and $o.Status -eq 'Available')
  $btnMgrCheck.Enabled = [bool]$script:ManagerVersion -and -not $script:ManagerChecking
  Set-BlockHeights $updCard @($blkFleet); if ($setMgrCard) { Set-BlockHeights $setMgrCard @($blkManager, $blkLang, $blkLocal) }
}

# ---------------- the manager updates itself ----------------
$script:ManagerOffer = $null; $script:ManagerChecking = $false; $script:ManagerCheckError = $null
# the notice in the top bar: only when a newer manager is there
# Something new to take, in sight on any page: how many updates on Updates in the menu (orange), a dot on the Release buttons when
# GitHub has a release newer than the one published to the devices, on Updates also for a newer manager. From the
# check of the manager (at the start, then every 6 hours) and the LATEST.txt of the folder (every minute).
$script:GitHubLatest = ''; $script:DeviceOffer = $false
function Update-UpdateBadges {
  $pub = ''; $f = Join-Path $script:Folder 'updates\LATEST.txt'
  if (Test-Path -LiteralPath $f) { $pub = (Read-Lines $f | Where-Object { $_ -match '^version=' } | Select-Object -First 1) -replace '^version=', '' }
  $dev = [bool]($script:GitHubLatest -and (-not $pub -or (Compare-Version $script:GitHubLatest $pub) -gt 0))
  $mgr = [bool]($script:ManagerOffer -and $script:ManagerOffer.Status -eq 'Available')
  $tip = @($(if ($dev) { Get-Text 'BadgeDevices' $script:GitHubLatest $(if ($pub) { $pub } else { Get-Text 'UpdNone' }) }), $(if ($mgr) { Get-Text 'BadgeManager' $script:ManagerOffer.Version })) | Where-Object { $_ }
  if ($dev -ne $script:DeviceOffer) { $script:DeviceOffer = $dev; $btnRelease.Invalidate(); $btnUpdRelease.Invalidate() }
  # how many: one for the devices (a release newer than the published one), one for the manager
  $nUp = [int]$dev + [int]$mgr; $c = if ($nUp) { "$nUp" } else { '' }
  if ($navUpdates.Tag.Count -ne $c) { $navUpdates.Tag.Count = $c; $navUpdates.Tag.CountColor = $script:KindColor.warn; $navUpdates.Invalidate() }
  $tips.SetToolTip($navUpdates, $(if ($tip) { $tip -join "`r`n" } elseif ($script:NavCompact) { $navUpdates.Tag.Label.Trim() } else { '' }))
  foreach ($b in $btnRelease, $btnUpdRelease) { $tips.SetToolTip($b, $(if ($dev) { Get-Text 'BadgeDevices' $script:GitHubLatest $(if ($pub) { $pub } else { Get-Text 'UpdNone' }) } else { '' })) }
}
# the dot on a Release button: top right, over its corner
foreach ($b in @($btnRelease, $btnUpdRelease)) {
  $b.add_Paint({ param($s, $e) if (-not $script:DeviceOffer) { return }
    $e.Graphics.SmoothingMode = 'AntiAlias'; $br = New-Object System.Drawing.SolidBrush($script:KindColor.warn)
    $e.Graphics.FillEllipse($br, ($s.Width - 13), 3, 9, 9); $br.Dispose() })
}
function Update-ManagerNotice {
  Update-UpdateBadges
  $on = [bool]($script:ManagerOffer -and $script:ManagerOffer.Status -eq 'Available')
  # the bar back to full texts, then fitted again with the notice in it or not
  Set-CompactButtons @($btnMgrNotice, $btnVaultTool, $btnPerm, $btnRelease, $btnOpen, $btnRefresh) $false; $script:ToolbarCompact = $false
  if ($on) {
    $t = Get-Text 'MgrAvailable' $script:ManagerOffer.Version
    $btnMgrNotice.Text = $t; $btnMgrNotice.Width = (Get-TextWidth $t) + 50
    $tips.SetToolTip($btnMgrNotice, (Get-Text 'MgrStatus_Available' $script:ManagerOffer.Version))
    $btnMgrNotice.Tag = $null      # Set-CompactButtons takes the new text and width as the full ones
  }
  $btnMgrNotice.Visible = $on
  Set-ToolbarFit
  if ($script:Page -eq 5) { Update-UpdatesView }
}
# At the start, in the background (a runspace: the window does not wait): LATEST.txt + .sig of the latest release,
# checked here when they are there. Every failure is silent: the Updates page says it only when asked again.
function Start-ManagerCheck([switch]$Loud) {
  if (-not $script:ManagerVersion -or $script:ManagerChecking) { return }
  $tmp = Join-Path $env:TEMP "otr-manager-$(Get-Random)"; New-Item -ItemType Directory $tmp | Out-Null
  $ps = [powershell]::Create()
  [void]$ps.AddScript({ param($base, $dir)
    $ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    foreach ($n in 'LATEST.txt', 'LATEST.txt.sig') {
      if ($base -match '^https?://') { Invoke-WebRequest -UseBasicParsing -Uri "$base/$n" -OutFile (Join-Path $dir $n) -TimeoutSec 60 }
      else { Copy-Item -LiteralPath (Join-Path $base $n) -Destination (Join-Path $dir $n) }
    } }).AddArgument((Get-ManagerReleaseBase)).AddArgument($tmp)
  $script:ManagerChecking = $true; $script:ManagerCheckError = $null
  $t = New-Object System.Windows.Forms.Timer; $t.Interval = 500
  $t.Tag = @{ PS = $ps; H = $ps.BeginInvoke(); Dir = $tmp; Started = (Get-Date); Loud = [bool]$Loud }
  $t.add_Tick({ param($s, $e)
    $st = $s.Tag
    if (-not $st.H.IsCompleted -and ((Get-Date) - $st.Started).TotalSeconds -lt 150) { return }
    $s.Stop(); $s.Dispose(); $script:ManagerChecking = $false
    try {
      if (-not $st.H.IsCompleted) { [void]$st.PS.BeginStop($null, $null); throw 'timeout' }
      [void]$st.PS.EndInvoke($st.H)
      $script:ManagerOffer = Test-ManagerOffer $st.Dir
      # the same signed LATEST.txt says the version of the devices of that release
      $script:GitHubLatest = if ($script:ManagerOffer.Status -in 'Available', 'UpToDate', 'NoManager') { [string]$script:ManagerOffer.Version } else { '' }
    } catch { if ($st.Loud) { $script:ManagerCheckError = $_.Exception.GetBaseException().Message } }
    finally { if ($st.H.IsCompleted) { $st.PS.Dispose() }; Remove-Item -LiteralPath $st.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    Update-ManagerNotice; if ($st.Loud) { Update-UpdatesView }
  })
  $t.Start()
  if ($script:Page -eq 5) { Update-UpdatesView }
}
# Update the manager: the zip of the offer in place of these files (Update-Manager), then the manager starts again
# with the same folder and language, and this window closes
function Start-ManagerUpdate {
  $o = $script:ManagerOffer; if (-not $o -or $o.Status -ne 'Available') { return }
  $unsaved = $lblDirtyDev.Visible -or $lblDirtyCom.Visible -or $lblDirtyKeys.Visible
  $msg = (Get-Text 'MgrConfirm' $script:ManagerVersion $o.Version $script:ManagerDir) + $(if ($unsaved) { Get-Text 'MgrUnsaved' } else { '' })
  # the question with what changes from this version to that one
  $form.Cursor = 'WaitCursor'; $notes = Get-ReleaseNotes $script:ManagerVersion $o.Version; $form.Cursor = 'Default'
  if (-not (Show-NotesDialog (Get-Text 'MgrTitle') $msg $notes 'BtnUpdateManager')) { return }
  $form.Cursor = 'WaitCursor'; $barText.Text = Get-Text 'MgrUpdating' $o.Version; [System.Windows.Forms.Application]::DoEvents()
  try { $r = Update-Manager $o } catch { $form.Cursor = 'Default'; $barText.Text = ''; Show-Message (Get-Text 'MgrTitle') $_.Exception.Message 'Error'; return }
  $form.Cursor = 'Default'
  try { Add-ManagerChangeLog $r } catch { }
  Show-Message (Get-Text 'MgrTitle') ((Get-ManagerDoneText $r) + "`r`n`r`n" + (Get-Text 'MgrRestart')) 'Information'
  # the same start as OpenThinRDP-Manager.cmd, on the folder open now (a path ending in \ would escape the quote)
  $fd = $script:Folder; if ($fd.EndsWith('\')) { $fd += '\' }
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path $script:ManagerDir 'OpenThinRDP-Manager.ps1')`"", '-Folder', "`"$fd`"")
  if ($Language) { $a += @('-Language', $Language) }
  try { Start-Process (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $a -WorkingDirectory $script:ManagerDir -WindowStyle Hidden }
  catch { Show-Message (Get-Text 'MgrTitle') $_.Exception.Message 'Error'; return }
  $form.Close()
}

$btnRelease.add_Click({ Start-ReleaseImport })
$btnUpdRelease.add_Click({ Start-ReleaseImport })
$btnUpdAll.add_Click({ Start-ReleaseToAll })
$btnUpdFleet.add_Click({ Start-FleetVersion })
$btnUpdFetch.add_Click({ if (Invoke-FetchVersion) { Update-UpdatesView } })
$btnMgrUpdate.add_Click({ Start-ManagerUpdate })
$btnMgrNotice.add_Click({ Start-ManagerUpdate })
$btnMgrCheck.add_Click({ Start-ManagerCheck -Loud })
$btnTrackDev.add_Click({ if ($script:Selected) { Show-DeviceVersionDialog $script:Selected } })
$btnPerm.add_Click({
  $acc = @(Get-MgmtAccounts $script:Devices)
  if (-not $acc.Count) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $a = [Microsoft.VisualBasic.Interaction]::InputBox((Get-Text 'PermAskAccount'), (Get-Text 'PermTitle'), '')
    if (-not $a.Trim()) { return }; $acc = @($a.Trim())
  }
  $form.Cursor = 'WaitCursor'; $bad = $false
  try {
    $lines = foreach ($x in $acc) {
      Get-Text 'PermAccount' $x
      foreach ($r in (Test-FolderPermissions $x)) { if ($r.Problem) { $bad = $true; "  $([char]0x2717) $($r.Text)" } else { "  $([char]0x2713) $($r.Text)" } }
      ''
    }
    $lines += Get-Text 'PermFooter'
  } catch { $bad = $true; $lines = @($_.Exception.Message) } finally { $form.Cursor = 'Default' }
  if (-not $bad) { Show-Message (Get-Text 'PermTitle') ($lines -join "`r`n") 'Information'; return }
  # with problems: the rights the account needs and no more, after asking (Button2: No is the default)
  if (-not (Confirm-Action (Get-Text 'PermTitle') (($lines -join "`r`n") + "`r`n`r`n" + (Get-Text 'PermFixAsk' ($acc -join ', '))) 'Button2')) { return }
  $form.Cursor = 'WaitCursor'
  try {
    $r = foreach ($x in $acc) { Get-Text 'PermAccount' $x; @(Repair-FolderPermissions $x | ForEach-Object { "  $_" })
      foreach ($t in (Test-FolderPermissions $x)) { if ($t.Problem) { "  $([char]0x2717) $($t.Text)" } else { "  $([char]0x2713) $($t.Text)" } }; '' }
  } catch { $r = @(Get-Text 'PermFixFailed' $_.Exception.Message) } finally { $form.Cursor = 'Default' }
  Show-Message (Get-Text 'PermTitle') ($r -join "`r`n") 'Information'
})
function Update-ProblemView {
  $since = switch ($cmbPeriod.SelectedIndex) { 0 { (Get-Date).Date } 1 { (Get-Date).AddHours(-24) } 2 { (Get-Date).AddDays(-7) } default { (Get-Date).AddDays(-30) } }
  $form.Cursor = 'WaitCursor'
  try { $sum = Get-ProblemSummary (Get-ProblemEvents $since) } finally { $form.Cursor = 'Default' }
  $lblHeadline.Text = Get-ProblemHeadline $sum
  $lblHeadline.ForeColor = if (@($sum | Where-Object { $_ }).Count) { $Theme.Text } else { $script:KindColor.ok }
  $probList.BeginUpdate(); $probList.Items.Clear(); $probText.Text = ''
  foreach ($p in @($sum | Where-Object { $_ })) {
    $it = New-Object System.Windows.Forms.ListViewItem (Get-Text "Prob_$($p.Kind)")
    $it.ImageKey = if ($p.Wide) { 'warn' } else { 'off' }
    foreach ($v in @((Get-WhereLabel $p.Where), "$($p.Count)", "$($p.Devices.Count): $($p.Devices -join ', ')", ($p.Users -join ', '), $p.First.ToString('dd/MM HH:mm'), $p.Last.ToString('dd/MM HH:mm'))) { [void]$it.SubItems.Add($v) }
    if ($p.Wide) { $it.BackColor = $script:KindSoft.warn }
    $it.Tag = $p; [void]$probList.Items.Add($it)
  }
  $probList.EndUpdate()
}
$probList.add_SelectedIndexChanged({
  if ($probList.SelectedItems.Count -ne 1) { return }
  $probText.Text = (@($probList.SelectedItems[0].Tag.Events | ForEach-Object { '{0:dd/MM HH:mm:ss}  {1,-14} {2}' -f $_.Time, $_.Device, $_.Text }) -join "`r`n")
})
$cmbPeriod.add_SelectedIndexChanged({ if ($script:Page -eq 3) { Update-ProblemView } })

# ---------------- Desktops, brokers and hosts ----------------
# The probe reads the servers in a runspace of its own, every $script:VdiRefreshSeconds while the window is open: a
# host that does not answer holds nothing in the window. What it found is shown with the time it was read; the actions
# that stop or end something are not offered on data older than $script:VdiStaleMinutes (OtrVdi.ps1).
$script:Vdi = @{ Model = $null; Received = $null; Busy = $false; Error = $null; Action = $null; Again = $false }
# one action at a time, on both pages: an action of the Health Center holds those of the Desktops page too
function Get-VdiState { @{ Model = $script:Vdi.Model; Received = $script:Vdi.Received; Running = $(if ($script:Vdi.Action) { $script:Vdi.Action } elseif ($script:Health -and $script:Health.Action) { $script:Health.Action }) } }
function Start-VdiRefresh([switch]$Queue) {
  # asked while reading (after an action, Refresh): read again as soon as this reading ends; the timer only skips
  if ($script:Vdi.Busy) { if ($Queue) { $script:Vdi.Again = $true }; return }
  if (-not $script:VdiLoaded) { return }
  $set = Get-VdiSettings
  if ($env:OTR_MANAGER_VDI_DEMO) {
    # demo and screenshots: the answer of a probe from a file, at once
    $raw = $null; try { $raw = Get-Content -LiteralPath $env:OTR_MANAGER_VDI_DEMO -Raw | ConvertFrom-Json } catch { $script:Vdi.Error = $_.Exception.Message }
    Complete-VdiRefresh $raw; return
  }
  $cfg = Get-VdiProbeConfig $script:Devices $set
  if (-not $set.Enabled -or -not @($cfg.BrokerNames).Count) { Complete-VdiRefresh $null; return }
  $ps = [powershell]::Create()
  [void]$ps.AddScript($script:VdiProbe.ToString()).AddArgument($cfg)
  $script:Vdi.Busy = $true; $script:Vdi.Error = $null; Update-VdiStamp
  $t = New-Object System.Windows.Forms.Timer; $t.Interval = 500
  $t.Tag = @{ PS = $ps; H = $ps.BeginInvoke(); Started = (Get-Date) }
  $t.add_Tick({ param($s, $e)
    $st = $s.Tag
    if (-not $st.H.IsCompleted -and ((Get-Date) - $st.Started).TotalSeconds -lt 300) { return }
    $s.Stop(); $s.Dispose(); $script:Vdi.Busy = $false
    $raw = $null
    try {
      if (-not $st.H.IsCompleted) { [void]$st.PS.BeginStop($null, $null); throw (Get-Text 'VdiErrTimeout') }
      $raw = @($st.PS.EndInvoke($st.H)) | Select-Object -Last 1
    } catch { $script:Vdi.Error = $_.Exception.GetBaseException().Message }
    finally { if ($st.H.IsCompleted) { $st.PS.Dispose() } }
    if ($raw) { Complete-VdiRefresh $raw } else { Update-VdiStamp }
    if ($script:Vdi.Again) { $script:Vdi.Again = $false; Start-VdiRefresh }
  })
  $t.Start()
}
function Complete-VdiRefresh($raw) {
  $now = if ($raw -and $raw.Taken) { ConvertFrom-VdiTime $raw.Taken }; if (-not $now) { $now = Get-Date }   # a partial read (progress) has no Taken yet
  if (-not $now) { $now = Get-Date }
  try { $script:Vdi.Model = ConvertTo-VdiModel $raw $script:Devices $now (Get-VdiSettings); $script:Vdi.Received = Get-Date }
  catch { $script:Vdi.Error = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))" }
  Update-DesktopsView; Update-VdiBrokersView; Update-VdiNav
  # the Health Center shows the findings of the brokers and hosts: its model follows
  if ($script:HealthLoaded -and $script:Health.Raw) { Update-HealthModel }
}
# "updated at 10:42:05", "reading the servers...", and why the last reading failed
function Update-VdiStamp {
  $t = if ($script:Vdi.Busy) { Get-Text 'VdiReading' } elseif ($script:Vdi.Received) { Get-Text 'VdiUpdatedAt' $script:Vdi.Received.ToString('HH:mm:ss') } else { '' }
  if (-not $script:Vdi.Busy -and $script:Vdi.Received -and (Test-VdiStale $script:Vdi.Received (Get-Date))) { $t = Get-Text 'VdiStaleAt' $script:Vdi.Received.ToString('HH:mm:ss') }
  if ($script:Vdi.Error -and -not $script:Vdi.Busy) { $t = Get-Text 'VdiReadFailed' $script:Vdi.Error }
  $lblDskUpdated.Text = $t; $tips.SetToolTip($lblDskUpdated, $t)
  $lblDskUpdated.ForeColor = if ($script:Vdi.Error) { $script:KindColor.warn } else { $Theme.Muted }
  $btnDskRefresh.Enabled = -not $script:Vdi.Busy
  $dskTop.PerformLayout(); $dskTop.Invalidate()
  # the label is laid out by the resize of its bar
  $w = $dskTop.ClientSize.Width; $uw = [Math]::Min(300, [Math]::Max(120, (Get-TextWidth $t $fontSmall) + 10))
  $lblDskUpdated.SetBounds(($w - $uw - 14), 52, $uw, 24); $lblDskHead.Width = [Math]::Max(80, $w - $uw - 40)
}
# the menu: in red what needs a person now (who cannot sign in, and the problems of brokers and hosts), else the rows
function Update-VdiNav {
  $m = $script:Vdi.Model
  $navDesktops.Tag.Count = ''; $navDesktops.Tag.CountColor = $null
  if ($m -and $m.Access -ne 'off') {
    $now = [int]$m.CannotSignIn + @($m.Findings | Where-Object { $_.Kind -eq 'error' }).Count
    if ($now) { $navDesktops.Tag.Count = "$now"; $navDesktops.Tag.CountColor = New-Color '#f87171' }
    else { $navDesktops.Tag.Count = "$(@($m.Rows).Count)" }
  }
  $navDesktops.Invalidate()
}
# the list, with the search and the filter of the page; the selected row stays selected
function Update-DesktopsView {
  Update-VdiStamp
  $m = $script:Vdi.Model
  if (-not $m) {
    $lblDskHead.Text = if (-not $script:VdiLoaded) { Get-Text 'VdiNotLoaded' } elseif ($script:Vdi.Busy) { Get-Text 'VdiReading' } else { Get-Text 'VdiNoData' }
    $lblDskHead.ForeColor = $Theme.Muted; $dskList.Items.Clear(); Show-DskRow $null; return
  }
  if ($m.Access -ne 'ok') { $lblDskHead.Text = Get-Text "VdiAccess_$($m.Access)" $m.AccessText; $lblDskHead.ForeColor = $(if ($m.Access -eq 'off') { $Theme.Muted } else { $script:KindColor.warn }) }
  else { $lblDskHead.Text = $m.Headline; $lblDskHead.ForeColor = $script:KindColor[$m.HeadlineKind] }
  $tips.SetToolTip($lblDskHead, $lblDskHead.Text)
  $sel = if ($dskList.SelectedItems.Count) { $dskList.SelectedItems[0].Tag.Key } else { $null }
  $f = [System.Management.Automation.WildcardPattern]::Escape($txtDskSearch.Text.Trim())
  $dash = [string][char]0x2014
  $script:DskListing = $true
  $dskList.BeginUpdate(); $dskList.Items.Clear()
  foreach ($r in $m.Rows) {
    $show = switch ($cmbDskFilter.SelectedIndex) {
      1 { $r.Kind -in 'error', 'warn' }
      2 { $r.Session -and $r.Session.State -eq 'active' }
      3 { $r.Session -and $r.Session.State -eq 'disconnected' }
      4 { $r.VmInfo -and $r.VmInfo.State -in 'Off', 'Saved' }
      default { $true }
    }
    if (-not $show) { continue }
    $ip = if ($r.Device) { ([string]$r.Device.S['IP']) -replace '/.*$', '' } else { '' }
    if ($f -and -not (@($r.User, $r.State, $r.DeviceText, $ip, $r.Vm, $r.Host, $r.VmText, $r.SessionText, $r.SignInText) | Where-Object { "$_" -like "*$f*" })) { continue }
    $it = New-Object System.Windows.Forms.ListViewItem($(if ($r.User) { $r.User } else { $dash }))
    $it.ImageKey = $r.Kind; $it.UseItemStyleForSubItems = $false
    foreach ($v in @($r.State, $r.DeviceText, $r.Vm, $r.Host, $r.VmText, $r.SessionText, $r.SignInText)) { [void]$it.SubItems.Add([string]$v) }
    foreach ($x in $it.SubItems) { $x.BackColor = $Theme.Card; $x.ForeColor = $Theme.Text }
    # the state in the colour of its kind, with its words: never the colour alone
    $it.SubItems[1].ForeColor = if ($r.Kind -eq 'ok') { $script:KindColor.ok } elseif ($r.Kind -eq 'off') { $Theme.Muted } else { $script:KindColor[$r.Kind] }
    if ($r.Device -and $r.Device.Minutes -gt $script:StaleMinutes) { $it.SubItems[2].ForeColor = $Theme.Muted }
    if ($r.SignIn -and $r.SignIn.Last -and -not $r.SignIn.Last.Ok) { $it.SubItems[7].ForeColor = $script:KindColor.error }
    $it.ToolTipText = $r.Why
    $it.Tag = $r
    [void]$dskList.Items.Add($it)
    if ($sel -and $r.Key -eq $sel) { $it.Selected = $true }
  }
  if ($dskList.ListViewItemSorter) { $dskList.Sort() }
  $dskList.EndUpdate()
  $script:DskListing = $false
  if (-not $dskList.SelectedItems.Count -and $dskList.Items.Count) { $dskList.Items[0].Selected = $true }
  if ($dskList.SelectedItems.Count) { $dskList.SelectedItems[0].EnsureVisible(); Show-DskRow $dskList.SelectedItems[0].Tag } else { Show-DskRow $null }
}
# the selected row: what is wrong, its desktop and session, its last sign-ins, the actions it allows now
function Show-DskRow($r) {
  $script:DskRow = $r
  $lvDskInfo.BeginUpdate(); $lvDskInfo.Items.Clear(); $lvDskSign.BeginUpdate(); $lvDskSign.Items.Clear()
  try {
    if (-not $r) { $lblDskName.Text = Get-Text 'VdiNoRow'; $lblDskState.Visible = $false; $lblDskWhy.Text = ''; return }
    $now = $script:Vdi.Model.Taken; $dash = [string][char]0x2014; $dot = "   $([char]0x00B7)   "
    $lblDskName.Text = if ($r.User) { $r.User } elseif ($r.Device) { $r.Device.Name } else { $dash }
    $lblDskState.Text = $r.State; $lblDskState.ForeColor = $script:KindColor[$r.Kind]; $lblDskState.BackColor = $script:KindSoft[$r.Kind]; $lblDskState.Visible = [bool]$r.State
    $lblDskState.Location = New-Object System.Drawing.Point(($lblDskName.Right + 10), ($lblDskName.Top + [int](($lblDskName.Height - $lblDskState.Height) / 2) + 1))
    $lblDskWhy.Text = $r.Why; $tips.SetToolTip($lblDskWhy, $r.Why)
    $add = { param($k, $v) $it = New-Object System.Windows.Forms.ListViewItem((Get-Text $k)); $it.ForeColor = $Theme.Muted; $it.UseItemStyleForSubItems = $false
      $sub = $it.SubItems.Add($(if ($v) { [string]$v } else { $dash })); $sub.ForeColor = $Theme.Text; $it.ToolTipText = [string]$v; [void]$lvDskInfo.Items.Add($it) }
    $vi = $r.VmInfo
    & $add 'VdiInfoDesktop' $(if ($r.Vm) { $r.Vm + $(if ($r.Collection) { $dot + $r.Collection } else { '' }) + $(if ($r.Rdsh) { $dot + (Get-Text 'VdiInfoRdsh') } else { '' }) })
    & $add 'VdiInfoHost' $r.Host
    & $add 'VdiInfoVm' $(if ($vi) { (@($r.VmText, $(if ($vi.State -eq 'Running') { Get-Text 'VdiInfoHeartbeat' $(if ("$($vi.Heartbeat)" -like 'Ok*') { 'OK' } else { $vi.Heartbeat }) }), $(if ($vi.Tpm) { 'vTPM' }),
        $(if ($vi.State -eq 'Running' -and $vi.UptimeMin) { Get-Text 'VdiInfoUptime' (Format-Minutes ([int]$vi.UptimeMin)) })) | Where-Object { $_ }) -join $dot })
    $s = $r.Session
    & $add 'VdiInfoSession' $(if ($s) { (@($r.SessionText, $(if ($s.Logon) { Get-Text 'VdiInfoLogon' (Format-VdiClock $s.Logon $now) }), "id $($s.Id)") | Where-Object { $_ }) -join $dot } else { Get-Text 'VdiInfoNoSession' })
    & $add 'VdiInfoDevice' $(if ($r.Device) { (@($r.Device.Name, (([string]$r.Device.S['IP']) -replace '/.*$', ''), (Get-Text 'DevLastReport' (Get-Seen $r.Device))) | Where-Object { $_ }) -join $dot })
    foreach ($e in @($r.SignIn.Recent | Sort-Object Time -Descending)) {
      $it = New-Object System.Windows.Forms.ListViewItem((Format-VdiClock $e.Time $now)); $it.ImageKey = $(if ($e.Ok) { 'ok' } else { 'error' })
      [void]$it.SubItems.Add($(if ($e.Ok) { Get-Text 'VdiOutOk' } else { Get-Text 'VdiOutFail' }))
      $by = if ($e.Source -eq 'device') { Get-Text 'VdiBySource' $(if ($e.Broker) { $e.Broker } else { '?' }) $e.Device } else { $e.Broker }
      [void]$it.SubItems.Add($by)
      $it.ToolTipText = (@($e.Kind, $e.Why) | Where-Object { $_ }) -join ': '
      [void]$lvDskSign.Items.Add($it)
    }
  } finally { $lvDskInfo.EndUpdate(); $lvDskSign.EndUpdate(); Update-DskButtons }
}
# each button as the plan of its action allows it now; the reason it does not in its tooltip
$script:DskActions = @{ SessionShadow = $btnDskShadow; SessionMessage = $btnDskMessage; SessionDisconnect = $btnDskDisconnect; VmStart = $btnDskStart
  VmRestart = $btnDskRestart; AssignDesktop = $btnDskAssign; SessionLogoff = $btnDskLogoff; VmShutdown = $btnDskShutdown }
function Get-DskPlan([string]$kind, $r) { Get-VdiActionPlan $kind $r (Get-VdiState) (Get-Date) $(if ($kind -in 'SessionMessage', 'AssignDesktop') { '*' } else { $null }) }
# A flat button with colours of its own does not look disabled by itself: grey when it cannot be used now, so that a
# blue or red button never invites a click that does nothing
$script:BtnLook = @{}
function Set-ActionEnabled($b, [bool]$on) {
  if (-not $script:BtnLook.ContainsKey($b)) { $script:BtnLook[$b] = @{ Back = $b.BackColor; Fore = $b.ForeColor; Border = $b.FlatAppearance.BorderColor } }
  $l = $script:BtnLook[$b]; $b.Enabled = $on
  if ($on) { $b.BackColor = $l.Back; $b.ForeColor = $l.Fore; $b.FlatAppearance.BorderColor = $l.Border }
  else { $b.BackColor = $Theme.Card; $b.ForeColor = $Theme.Muted; $b.FlatAppearance.BorderColor = $Theme.Line }
}
function Update-DskButtons {
  $r = $script:DskRow
  foreach ($k in $script:DskActions.Keys) {
    $b = $script:DskActions[$k]
    if (-not $r -or -not $script:Vdi.Model) { Set-ActionEnabled $b $false; continue }
    $p = Get-DskPlan $k $r
    Set-ActionEnabled $b (-not $p.Blocked)
    $tip = if ($p.Blocked) { $p.Blocked } else { $p.Title }
    # a button that shows only its icon keeps this text for its tooltip (Set-CompactButtons)
    if ($b.Tag -is [hashtable] -and $b.Tag.ContainsKey('Full')) { $b.Tag.Tip = $tip; if (-not $b.Text) { $tip = "$($b.Tag.Full): $tip" } }
    $tips.SetToolTip($b, $tip)
  }
}
# The action, after its confirmation: what will happen and to whom, in the plan's words. Runs in the background;
# the result in a message, the line in config\changes.log, and the page read again.
function Invoke-VdiAction([string]$kind, $target, $arg = $null) {
  if (-not $script:Vdi.Model) { return }
  $title = Get-Text "VdiAct_$kind"
  if ($kind -eq 'SessionMessage' -and -not $arg) {
    $pre = Get-VdiActionPlan $kind $target (Get-VdiState) (Get-Date) '*'
    if ($pre.Blocked) { Show-Message $title $pre.Blocked 'Information'; return }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $arg = [Microsoft.VisualBasic.Interaction]::InputBox((Get-Text 'VdiMessageAsk' $target.User), $title, '').Trim()
    if (-not $arg) { return }
  }
  if ($kind -eq 'AssignDesktop' -and $null -eq $arg) {
    $pre = Get-VdiActionPlan $kind $target (Get-VdiState) (Get-Date) '*'
    if ($pre.Blocked) { Show-Message $title $pre.Blocked 'Information'; return }
    $arg = Show-AssignDialog $target; if ($null -eq $arg) { return }
  }
  $plan = Get-VdiActionPlan $kind $target (Get-VdiState) (Get-Date) $arg
  if ($plan.Blocked) { Show-Message $plan.Title $plan.Blocked 'Information'; return }
  $text = $plan.Text; if (Test-VdiDryRun) { $text += "`r`n`r`n" + (Get-Text 'VdiDryRunNote') }
  if (-not (Confirm-Action $plan.Title $text $(if ($plan.DefaultNo) { 'Button2' } else { 'Button1' }))) { return }
  Start-VdiJob $plan
}
function Start-VdiJob($plan) {
  $dry = Test-VdiDryRun
  $ps = [powershell]::Create()
  [void]$ps.AddScript($script:VdiJobRunner.ToString()).AddArgument(@($plan.Steps)).AddArgument($dry).AddArgument(8000).AddArgument(420000)
  $script:Vdi.Action = $plan.Title
  $barText.Text = Get-Text 'VdiActionRunning' $plan.Title; $form.Cursor = 'AppStarting'
  Update-DskButtons
  $t = New-Object System.Windows.Forms.Timer; $t.Interval = 400
  $t.Tag = @{ PS = $ps; H = $ps.BeginInvoke(); Plan = $plan; Dry = $dry; Started = (Get-Date) }
  $t.add_Tick({ param($s, $e)
    $st = $s.Tag
    if (-not $st.H.IsCompleted -and ((Get-Date) - $st.Started).TotalSeconds -lt 900) { return }
    $s.Stop(); $s.Dispose()
    $res = @()
    try {
      if (-not $st.H.IsCompleted) { [void]$st.PS.BeginStop($null, $null); throw (Get-Text 'VdiErrTimeout') }
      $res = @($st.PS.EndInvoke($st.H) | ForEach-Object { $_ })
    } catch { $res = @([pscustomobject]@{ Name = $st.Plan.Title; Computer = ''; Ok = $false; DryRun = $false; Data = $null; Error = $_.Exception.GetBaseException().Message }) }
    finally { if ($st.H.IsCompleted) { $st.PS.Dispose() } }
    $script:Vdi.Action = $null; $form.Cursor = 'Default'; $barText.Text = ''
    Complete-VdiJob $st.Plan $res $st.Dry
  })
  $t.Start()
}
function Complete-VdiJob($plan, $res, [bool]$dry) {
  # shadow: a policy that cannot be read (no WinRM to the desktop) = with the user's consent, the safe way
  $shadowBlind = $plan.Kind -eq 'SessionShadow' -and -not $dry -and -not @($res)[0].Ok
  $ok = $shadowBlind -or (@($res).Count -gt 0 -and -not @($res | Where-Object { -not $_.Ok }).Count)
  $why = (@($res | Where-Object { -not $_.Ok } | ForEach-Object { "$($_.Name): $($_.Error)" })) -join '; '
  try { Add-ChangeLog ("desktops: {0}: {1}{2}" -f $plan.Log, $(if ($ok) { 'done' } else { "FAILED ($why)" }), $(if ($dry) { ' (dry run, nothing changed)' } else { '' })) } catch { }
  $lines = @(foreach ($r in @($res)) { Format-VdiStepResult $r })
  if ($plan.Kind -eq 'SessionShadow' -and $ok) {
    # the policy of the desktop says how: with the user's consent, or without
    $pol = if ($dry -or $shadowBlind) { 1 } else { [int](@($res)[0].Data.Policy) }
    $lines += Start-VdiShadow $plan.Target $pol $dry
  }
  Show-Message $plan.Title ((@($(if ($ok) { Get-Text 'VdiResDone' } else { Get-Text 'VdiResFailed' })) + '' + $lines) -join "`r`n") $(if ($ok) { 'Information' } else { 'Warning' })
  Start-VdiRefresh -Queue
}
# a step in words, with what the server answered (service states, members, the VM before and after)
function Format-VdiStepResult($r) {
  $where = if ($r.Computer) { Get-VdiShort $r.Computer } else { Get-Text 'VdiHere' }
  $n = if ($r.PSObject.Properties['Label'] -and $r.Label) { $r.Label } else { $r.Name }
  if ($r.DryRun) { return (Get-Text 'VdiResDry' $n $where) }
  $l = @($(if ($r.Ok) { Get-Text 'VdiResOk' $n $where } else { Get-Text 'VdiResFail' $n $where $(if ($r.Error) { $r.Error } else { '?' }) }))
  $d = $r.Data
  if ($d) {
    $has = { param($n) [bool]$d.PSObject.Properties[$n] }
    if ((& $has 'Steps') -and (& $has 'After')) {
      foreach ($x in @($d.Steps)) { $l += "   $($x.Name): $($x.Before) -> $($x.Stopped)" + $(if ([int]$x.Killed) { '  ' + (Get-Text 'VdiResKilled' $x.Killed) } else { '' }) }
      foreach ($x in @($d.After)) { $l += "   $($x.Name): $($x.State)" }
    } elseif ((& $has 'Vm') -and (& $has 'Before')) { $l += "   $($d.Vm): $($d.Before) -> $($d.After)" }
    elseif (& $has 'Results') {
      foreach ($x in @($d.Results)) { $l += '   ' + ((@($x.PSObject.Properties | Where-Object { $_.Name -notmatch '^(PS|RunspaceId)' -and "$($_.Value)" -ne '' } | ForEach-Object { "$($_.Value)" })) -join '  ') }
    } elseif ((& $has 'Now')) { $l += '   ' + (Get-Text 'VdiResAssigned' $(if (@($d.Now).Count) { @($d.Now) -join ', ' } else { [string][char]0x2014 })) }
  }
  $l
}
function Start-VdiShadow($r, [int]$policy, [bool]$dry) {
  $s = $r.Session
  if ($policy -eq 0) { return (Get-Text 'VdiShadowOff' $s.Vm) }
  $a = @("/v:$($s.Vm)", "/shadow:$($s.Id)")
  switch ($policy) { 1 { $a += '/control' } 2 { $a += '/control', '/noConsentPrompt' } 4 { $a += '/noConsentPrompt' } }
  if ($dry) { return (Get-Text 'VdiShadowDry' ("mstsc.exe " + ($a -join ' '))) }
  try { Start-Process mstsc.exe -ArgumentList $a } catch { return $_.Exception.Message }
  Get-Text $(if ($policy -in 1, 3) { 'VdiShadowConsent' } else { 'VdiShadowStarted' }) $r.User
}
# the personal desktop for a user: none, or one of the collection that nobody else has
function Show-AssignDialog($r) {
  $m = $script:Vdi.Model
  $coll = if ($r.Collection) { $r.Collection } else { (@($m.Collections | Where-Object { $_.Kind -eq 'vm' }) | Select-Object -First 1).Alias }
  $free = @($m.Desktops | Where-Object { $_.Collection -ieq $coll -and (-not $_.User -or (Get-VdiUserKey $_.User) -eq $r.UserKey) } | ForEach-Object Name | Sort-Object)
  $opts = @((Get-Text 'VdiAssignNone'), (Get-Text 'VdiAssignPick' $coll))
  $pick = Show-PickDialog (Get-Text 'VdiAct_AssignDesktop') (Get-Text 'VdiAssignText' $r.User $(if ($r.Vm) { $r.Vm } else { [string][char]0x2014 })) $opts 1 $free $r.Vm $null 'BtnApply'
  if (-not $pick) { return $null }
  if ($pick.Option -eq 0) { return '' }
  [string]$pick.Version
}
# Brokers and hosts on top of the Desktops page: the problems (errors, warnings, notes) with their buttons; the healthy
# lines only when asked (Show all). All healthy: one green line, the card no higher than its title.
$script:VdiShowAll = $false
function Update-VdiBrokersView {
  $m = $script:Vdi.Model
  $show = $script:VdiLoaded -and $m -and $m.Access -notin 'off', 'nobroker'
  # the brokers and the hosts are items of the Health Center tree: the Distribution shows the users only
  $dskOuter.Panel1Collapsed = $true
  if (-not $show) { return }
  $all = @($m.Findings); $bad = @($all | Where-Object { $_.Kind -ne 'ok' })
  if ($bad.Count) {
    $parts = foreach ($k in 'error', 'warn', 'info') { $n = @($bad | Where-Object Kind -eq $k).Count; if ($n) { "$(Get-Text "VdiKind_$k"): $n" } }
    $lblVdiPSum.Text = ($parts -join "   $([char]0x00B7)   "); $lblVdiPSum.ForeColor = $script:KindColor[$bad[0].Kind]
    $btnVdiPAll.Text = if ($script:VdiShowAll) { Get-Text 'VdiBrokShowProblems' } else { Get-Text 'VdiBrokShowAll' $all.Count }
  } else {
    $lblVdiPSum.Text = Get-Text 'VdiBrokAllOk' $all.Count; $lblVdiPSum.ForeColor = $script:KindColor.ok
    $btnVdiPAll.Text = if ($script:VdiShowAll) { Get-Text 'VdiBrokHide' } else { Get-Text 'VdiBrokShow' $all.Count }
  }
  $btnVdiPAll.Visible = $all.Count -gt $bad.Count -or $script:VdiShowAll
  $lines = if ($script:VdiShowAll) { $all } else { $bad }
  $gridVdi.Rows.Clear()
  foreach ($f in @($lines)) {
    $i = $gridVdi.Rows.Add((Get-Text "VdiKind_$($f.Kind)"), $f.Where, $f.Text, $(if ($f.Fix) { Get-Text "VdiFix_$($f.Fix)" } else { '' }))
    $row = $gridVdi.Rows[$i]; $row.Tag = $f
    if (-not $f.Fix) { $row.Cells[3] = New-Object System.Windows.Forms.DataGridViewTextBoxCell }
    $c = $row.Cells[0]; $c.Style.ForeColor = $script:KindColor[$f.Kind]; $c.Style.BackColor = $script:KindSoft[$f.Kind]
    $c.Style.SelectionForeColor = $script:KindColor[$f.Kind]; $c.Style.SelectionBackColor = $script:KindSoft[$f.Kind]; $c.Style.Font = $fontSmallBold
    $row.Cells[2].ToolTipText = $f.Text
  }
  $gridVdi.Visible = @($lines).Count -gt 0
  $gridVdi.CurrentCell = $null
  Set-VdiBrokFit
}
# the card as high as its lines, at most 30% of the page (its lines scroll): the users keep their room: the users keep their room
function Set-VdiBrokFit {
  if ($dskOuter.Panel1Collapsed) { return }
  for ($k = 0; $k -lt 3; $k++) { if ($gridVdi.Columns[$k].FillWeight -ne $script:VdiGridWeights[$k]) { $gridVdi.Columns[$k].FillWeight = $script:VdiGridWeights[$k] } }
  $h = $dskOuter.Height; if ($h -lt 200) { return }
  $rowsH = 0; if ($gridVdi.Visible) { foreach ($r in $gridVdi.Rows) { $rowsH += $r.Height } }
  $need = 42 + 2 + $(if ($gridVdi.Visible) { $rowsH + 4 } else { 0 })
  $d = [Math]::Max(44, [Math]::Min($need, [int]($h * 0.30)))
  if ($dskOuter.SplitterDistance -ne $d) { try { $dskOuter.SplitterDistance = $d } catch { } }
}
$btnVdiPAll.add_Click({ $script:VdiShowAll = -not $script:VdiShowAll; Update-VdiBrokersView })
$dskOuter.add_SizeChanged({ Set-VdiBrokFit })
$gridVdi.add_CellContentClick({ param($s, $e)
  if ($e.RowIndex -lt 0 -or $e.ColumnIndex -ne 3) { return }
  $f = $s.Rows[$e.RowIndex].Tag; if ($f -and $f.Fix) { Invoke-VdiAction $f.Fix $f.Where $f.FixArg } })
# Enter = the fix of the line. The grid takes Enter for itself (it moves to the next row) unless told it is input.
$gridVdi.add_PreviewKeyDown({ param($s, $e) if ($e.KeyCode -eq 'Enter') { $e.IsInputKey = $true } })
$gridVdi.add_KeyDown({ param($s, $e)
  if ($e.KeyCode -eq 'Enter' -and $s.CurrentRow -and $s.CurrentRow.Tag -and $s.CurrentRow.Tag.Fix) {
    $e.Handled = $true; $e.SuppressKeyPress = $true; $f = $s.CurrentRow.Tag; Invoke-VdiAction $f.Fix $f.Where $f.FixArg } })
$gridVdi.add_CellMouseDown({ param($s, $e) if ($e.Button -eq 'Right' -and $e.RowIndex -ge 0) { $s.CurrentCell = $s.Rows[$e.RowIndex].Cells[[Math]::Max(0, $e.ColumnIndex)] } })
# from the brokers and hosts of the Desktops page to the Health Center, and from a row to its VM there
$miVdiHealth = New-Object System.Windows.Forms.ToolStripMenuItem (Get-Text 'HcOpenHealth'); $miVdiHealth.Tag = 'OpenHealth'; [void]$vdiMenu.Items.Add($miVdiHealth)
[void]$dskMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miDskHealth = New-Object System.Windows.Forms.ToolStripMenuItem (Get-Text 'HcOpenHealth'); $miDskHealth.Tag = 'OpenHealth'; [void]$dskMenu.Items.Add($miDskHealth)
$vdiMenu.add_Opening({ param($s, $e)
  $f = if ($gridVdi.CurrentRow) { $gridVdi.CurrentRow.Tag } else { $null }
  $m = $script:Vdi.Model
  $isB = $f -and $m -and @($m.Brokers | Where-Object { $_.Name -eq $f.Where }).Count
  $isH = $f -and $m -and @($m.Hosts | Where-Object { $_.Name -eq $f.Where }).Count
  if (-not ($isB -or $isH)) { $e.Cancel = $true; return }
  foreach ($mi in $s.Items) { $mi.Visible = ($mi.Tag -like 'Broker*' -and $isB) -or ($mi.Tag -like 'Host*' -and $isH) -or ($mi.Tag -eq 'OpenHealth' -and $script:HealthLoaded) } })
foreach ($mi in $vdiMenu.Items) { $mi.add_Click({ param($s, $e)
  $f = if ($gridVdi.CurrentRow) { $gridVdi.CurrentRow.Tag } else { $null }; if (-not $f) { return }
  if ($s.Tag -eq 'OpenHealth') { Show-InHealth $(if (@($script:Vdi.Model.Hosts | Where-Object { $_.Name -eq $f.Where }).Count) { "host:$($f.Where)" } else { "broker:$($f.Where)" }); return }
  Invoke-VdiAction $s.Tag $f.Where $(if ($s.Tag -eq 'HostUnblock') { if ($f.Fix -eq 'HostUnblock' -and $f.FixArg) { $f.FixArg } else { 'VmHostAgent' } }) }) }
$dskMenu.add_Opening({ param($s, $e)
  if (-not $script:DskRow) { $e.Cancel = $true; return }
  foreach ($mi in $s.Items) { if ($mi.Tag -eq 'OpenHealth') { $mi.Enabled = $script:HealthLoaded -and [bool]$script:DskRow.Vm } elseif ($mi.Tag) { $mi.Enabled = -not (Get-DskPlan $mi.Tag $script:DskRow).Blocked } } })
foreach ($mi in $dskMenu.Items) { if ($mi.Tag) { $mi.add_Click({ param($s, $e) if (-not $script:DskRow) { return }
  if ($s.Tag -eq 'OpenHealth') { Show-InHealth "vm:$(([string]$script:DskRow.Vm).ToUpper())"; return }
  Invoke-VdiAction $s.Tag $script:DskRow }) } }
$dskList.add_SelectedIndexChanged({ if (-not $script:DskListing -and $dskList.SelectedItems.Count -eq 1) { Show-DskRow $dskList.SelectedItems[0].Tag } })
$txtDskSearch.add_TextChanged({ Update-DesktopsView })
$cmbDskFilter.add_SelectedIndexChanged({ Update-DesktopsView })
$btnDskRefresh.add_Click({ Update-DeviceList; Start-VdiRefresh -Queue })
$btnDskSettings.add_Click({ Select-Page 7 })
$btnDskShadow.add_Click({ if ($script:DskRow) { Invoke-VdiAction 'SessionShadow' $script:DskRow } })
$btnDskMessage.add_Click({ if ($script:DskRow) { Invoke-VdiAction 'SessionMessage' $script:DskRow } })
$btnDskDisconnect.add_Click({ if ($script:DskRow) { Invoke-VdiAction 'SessionDisconnect' $script:DskRow } })
$btnDskStart.add_Click({ if ($script:DskRow) { Invoke-VdiAction 'VmStart' $script:DskRow } })
$btnDskRestart.add_Click({ if ($script:DskRow) { Invoke-VdiAction 'VmRestart' $script:DskRow } })
$btnDskAssign.add_Click({ if ($script:DskRow) { Invoke-VdiAction 'AssignDesktop' $script:DskRow } })
$btnDskLogoff.add_Click({ if ($script:DskRow) { Invoke-VdiAction 'SessionLogoff' $script:DskRow } })
$btnDskShutdown.add_Click({ if ($script:DskRow) { Invoke-VdiAction 'VmShutdown' $script:DskRow } })
# the settings of the page: in the manager's settings of this account, not in the folder
function Show-VdiSettingsDialog {
  $s = Get-VdiSettings
  $W = 600; $X0 = 200
  $dlg = New-Object System.Windows.Forms.Form; Set-WindowIcon $dlg
  $dlg.Text = Get-Text 'VdiSetTitle'; $dlg.Font = $fontBase; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.StartPosition = 'CenterParent'
  $note = New-Object System.Windows.Forms.Label; $note.Text = Get-Text 'VdiSetNote' $script:SettingsFile
  $note.MaximumSize = New-Object System.Drawing.Size(($W - 28), 0); $note.AutoSize = $true; $note.Location = New-Object System.Drawing.Point(14, 12); $dlg.Controls.Add($note)
  $y = 12 + $note.GetPreferredSize((New-Object System.Drawing.Size(($W - 28), 0))).Height + 12
  $chk = New-Object System.Windows.Forms.CheckBox; $chk.Text = Get-Text 'VdiSetEnabled'; $chk.Checked = [bool]$s.Enabled; $chk.AutoSize = $true; $chk.Location = New-Object System.Drawing.Point(14, $y); $dlg.Controls.Add($chk); $y += 34
  $boxes = @{}
  foreach ($k in 'BrokerGroup', 'Brokers', 'Hosts') {
    $l = New-Object System.Windows.Forms.Label; $l.Text = Get-Text "VdiSet$k"; $l.AutoSize = $true; $l.Location = New-Object System.Drawing.Point(14, ($y + 4))
    $tb = New-Object System.Windows.Forms.TextBox; $tb.SetBounds($X0, $y, ($W - $X0 - 14), 26); $tb.Text = [string]$s.$k; $y += 30
    $hint = New-Object System.Windows.Forms.Label; $hint.Text = Get-Text "VdiSet${k}Hint"; $hint.ForeColor = $Theme.Muted
    $hint.MaximumSize = New-Object System.Drawing.Size(($W - $X0 - 14), 0); $hint.AutoSize = $true; $hint.Location = New-Object System.Drawing.Point($X0, $y)
    $y += $hint.GetPreferredSize((New-Object System.Drawing.Size(($W - $X0 - 14), 0))).Height + 12
    $dlg.Controls.AddRange(@($l, $tb, $hint)); $boxes[$k] = $tb
  }
  $err = New-Object System.Windows.Forms.Label; $err.ForeColor = $script:KindColor.error; $err.SetBounds(14, $y, ($W - 28), 36); $dlg.Controls.Add($err); $y += 40
  $ok = New-Button 'BtnSave' 110 28; $cancel = New-Button 'BtnCancel' 100 28
  $cancel.Location = New-Object System.Drawing.Point(($W - 14 - $cancel.Width), $y); $ok.Location = New-Object System.Drawing.Point(($cancel.Left - 8 - $ok.Width), $y)
  $cancel.DialogResult = 'Cancel'; $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel; $dlg.Controls.AddRange(@($ok, $cancel))
  $dlg.ClientSize = New-Object System.Drawing.Size($W, ($y + 42))
  $ok.add_Click({
    $n = [pscustomobject]@{ Enabled = $chk.Checked; BrokerGroup = $boxes['BrokerGroup'].Text.Trim(); Brokers = $boxes['Brokers'].Text; Hosts = $boxes['Hosts'].Text }
    $why = Test-VdiSettings $n
    if ($why) { $err.Text = $why; return }
    try { Save-VdiSettings $n } catch { $err.Text = $_.Exception.Message; return }
    $dlg.DialogResult = 'OK' })
  try { if ($dlg.ShowDialog($form) -eq 'OK') { $barText.Text = Get-Text 'VdiSetSaved'; Start-VdiRefresh } } finally { $dlg.Dispose() }
}
$vdiTimer = New-Object System.Windows.Forms.Timer; $vdiTimer.Interval = $script:VdiRefreshSeconds * 1000
$vdiTimer.add_Tick({ if (-not $env:OTR_MANAGER_VDI_DEMO) { Start-VdiRefresh } else { Update-VdiStamp } })

# ---------------- Health Center ----------------
# The probe reads the infrastructure in a runspace of its own every $script:HealthRefreshSeconds (OtrHealth.ps1). Its
# model is built again when the Desktops page reads its servers (the findings of the brokers and hosts come from
# there). In "diagnosis and repair" mode the safe repairs of the items in that mode run after each reading, one after
# the other, each logged; the others wait for a click and a confirmation.
$script:Health = @{ Model = $null; Raw = $null; Received = $null; Busy = $false; Error = $null; Action = $null; Again = $false
  Recent = (New-Object Collections.ArrayList); Tried = @{}; Queue = (New-Object Collections.ArrayList); AutoLog = (New-Object Collections.ArrayList); Expanded = @{}; Selected = $null }
function Get-HealthState {
  @{ Model = $script:Health.Model; Vdi = $script:Vdi.Model; Received = $script:Health.Received; VdiReceived = $script:Vdi.Received
     Running = $(if ($script:Vdi.Action) { $script:Vdi.Action } else { $script:Health.Action }); Recent = @($script:Health.Recent) }
}
function Start-HealthRefresh([switch]$Queue) {
  if ($script:Health.Busy) { if ($Queue) { $script:Health.Again = $true }; return }
  if (-not $script:HealthLoaded) { return }
  $set = Get-HealthSettings
  if ($env:OTR_MANAGER_HEALTH_DEMO) {
    $raw = $null; try { $raw = Get-Content -LiteralPath $env:OTR_MANAGER_HEALTH_DEMO -Raw | ConvertFrom-Json } catch { $script:Health.Error = $_.Exception.Message }
    Complete-HealthRefresh $raw; return
  }
  if (-not $set.Enabled) { Complete-HealthRefresh $null; return }
  $cfg = Get-HealthProbeConfig $set $script:Vdi.Model
  $prog = [hashtable]::Synchronized(@{ Step = ''; Count = 0; Index = 0; Version = 0; Snap = $null }); $cfg.Progress = $prog
  $script:Health.Progress = $prog; $script:Health.Seen = 0
  $ps = [powershell]::Create()
  # the probe uses OtrHealthNet (the backup log, the shares): the type is loaded in this process, the runspace shares it
  [void]$ps.AddScript($script:HealthProbe.ToString()).AddArgument($cfg)
  $script:Health.Busy = $true; $script:Health.Error = $null; Update-HealthStamp
  $t = New-Object System.Windows.Forms.Timer; $t.Interval = 500
  $t.Tag = @{ PS = $ps; H = $ps.BeginInvoke(); Started = (Get-Date) }
  $t.add_Tick({ param($s, $e)
    $st = $s.Tag
    $pg = $script:Health.Progress
    if ($pg -and [int]$pg.Version -ne [int]$script:Health.Seen) {
      $script:Health.Seen = [int]$pg.Version; Update-HealthStamp
      # the first reading: the parts already read go into the tree at once (later readings keep the last full one)
      if (-not $script:Health.Raw -and $pg.Snap) {
        # only while its page is open: each partial tree took 0.5-0.9 s of the window, six times in the first minute
        if ($script:Page -eq 7) { try { $script:Health.Model = ConvertTo-HealthModel $pg.Snap $script:Vdi.Model (Get-Date) (Get-HealthSettings); Update-HealthView; Update-HealthNav } catch { } }
      }
    }
    if (-not $st.H.IsCompleted -and ((Get-Date) - $st.Started).TotalSeconds -lt 400) { return }
    $s.Stop(); $s.Dispose(); $script:Health.Busy = $false; $script:Health.Progress = $null
    $raw = $null
    try {
      if (-not $st.H.IsCompleted) { [void]$st.PS.BeginStop($null, $null); throw (Get-Text 'VdiErrTimeout') }
      $raw = @($st.PS.EndInvoke($st.H)) | Select-Object -Last 1
    } catch { $script:Health.Error = $_.Exception.GetBaseException().Message }
    finally { if ($st.H.IsCompleted) { $st.PS.Dispose() } }
    if ($raw) { Complete-HealthRefresh $raw } else { Update-HealthStamp }
    if ($script:Health.Again) { $script:Health.Again = $false; Start-HealthRefresh }
  })
  $t.Start()
}
function Complete-HealthRefresh($raw) {
  $script:Health.Raw = $raw; $script:Health.Received = Get-Date
  Update-HealthModel
  Start-HealthAutoRepair
}
# the model from the last reading and the last model of the Desktops page
function Update-HealthModel {
  $raw = $script:Health.Raw
  $now = if ($raw -and $raw.Taken) { ConvertFrom-VdiTime $raw.Taken }; if (-not $now) { $now = Get-Date }   # a partial read (progress) has no Taken yet
  if (-not $now) { $now = Get-Date }
  try { $script:Health.Model = ConvertTo-HealthModel $raw $script:Vdi.Model $now (Get-HealthSettings) }
  catch { $script:Health.Error = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))" }
  Update-HealthView; Update-HealthNav
}
function Update-HealthStamp {
  $pg = $script:Health.Progress
  $t = if ($script:Health.Busy -and $pg -and $pg.Step) { Get-Text 'HcReadingStep' (Get-Text "HcProbe_$($pg.Step)") $(if ([int]$pg.Count) { " ($($pg.Count))" } else { '' }) $pg.Index $script:HealthProbeSteps } elseif ($script:Health.Busy) { Get-Text 'HcReading' } elseif ($script:Health.Received) { Get-Text 'VdiUpdatedAt' $script:Health.Received.ToString('HH:mm:ss') } else { '' }
  if (-not $script:Health.Busy -and $script:Health.Received -and (Test-VdiStale $script:Health.Received (Get-Date)) -and -not $env:OTR_MANAGER_HEALTH_DEMO) { $t = Get-Text 'VdiStaleAt' $script:Health.Received.ToString('HH:mm:ss') }
  if ($script:Health.Error -and -not $script:Health.Busy) { $t = Get-Text 'VdiReadFailed' $script:Health.Error }
  $pbHc.Visible = [bool]$script:Health.Busy; $pbHc.Value = if ($script:Health.Busy -and $pg) { [Math]::Min(100, [int](100 * [int]$pg.Index / $script:HealthProbeSteps)) } else { 0 }
  $lblHcUpdated.Text = $t; $tips.SetToolTip($lblHcUpdated, $t)
  $lblHcUpdated.ForeColor = if ($script:Health.Error) { $script:KindColor.warn } else { $Theme.Muted }
  $btnHcRefresh.Enabled = -not $script:Health.Busy
  $w = $hcTop.ClientSize.Width; $uw = [Math]::Min(320, [Math]::Max(120, (Get-TextWidth $t $fontSmall) + 10))
  $lblHcUpdated.SetBounds(($w - $uw - 14), 52, $uw, 24); $lblHcHead.Width = [Math]::Max(80, $w - $uw - 40)
}
function Update-HealthNav {
  $m = $script:Health.Model
  $navHealth.Tag.Count = ''; $navHealth.Tag.CountColor = $null
  if ($m -and $m.Access -eq 'ok') {
    if ($m.Errors) { $navHealth.Tag.Count = "$($m.Errors)"; $navHealth.Tag.CountColor = New-Color '#f87171' }
    elseif ($m.Warnings) { $navHealth.Tag.Count = "$($m.Warnings)"; $navHealth.Tag.CountColor = New-Color '#fbbf24' }
  }
  $navHealth.Invalidate()
}
# the words of a node in the tree: its name, and what is wrong (or its state) after it
function Get-HcNodeText($n) { if ($n.Short -and $n.Short -ne (Get-Text 'HcStatusOk')) { "$($n.Name)   $([char]0x00B7)   $($n.Short)" } else { $n.Name } }
function Update-HealthView {
  Update-HealthStamp
  $m = $script:Health.Model
  $mode = (Get-HealthSettings).Mode
  $script:HcSetting = $true; $cmbHcMode.SelectedIndex = $(if ($mode -eq 'repair') { 1 } else { 0 }); $script:HcSetting = $false
  if (-not $m -or $m.Access -ne 'ok') {
    $lblHcHead.Text = if (-not $script:HealthLoaded) { Get-Text 'HcNotLoaded' } elseif ($script:Health.Busy -and -not $m) { Get-Text 'HcReading' } elseif ($m) { Get-Text "HcAccess_$($m.Access)" } else { Get-Text 'HcNoData' }
    $lblHcHead.ForeColor = $Theme.Muted; $tvHc.Nodes.Clear(); Show-HealthNode $null; return
  }
  $head = $m.Headline
  if ($script:Health.AutoLog.Count) { $head += "   $([char]0x00B7)   " + (Get-Text 'HcRepairedNow' $script:Health.AutoLog[$script:Health.AutoLog.Count - 1].Time.ToString('HH:mm') $script:Health.AutoLog[$script:Health.AutoLog.Count - 1].Text) }
  $lblHcHead.Text = $head; $lblHcHead.ForeColor = $script:KindColor[$m.HeadlineKind]; $tips.SetToolTip($lblHcHead, (@($head) + @($m.Problems | ForEach-Object { "$($_.Node.Name): $($_.Check.Title): $($_.Check.Text)" })) -join "`r`n")
  # the tree again, the selection and what was open kept; a new problem opens its branch
  $sel = if ($tvHc.SelectedNode) { [string]$tvHc.SelectedNode.Name } else { $script:Health.Selected }
  foreach ($tn in @(Get-HcTreeNodes $tvHc.Nodes)) { $script:Health.Expanded[[string]$tn.Name] = $tn.IsExpanded }
  $script:HcListing = $true
  $tvHc.BeginUpdate()
  try {
    $tvHc.Nodes.Clear(); $map = @{}
    foreach ($n in $m.Nodes) {
      $tn = New-Object System.Windows.Forms.TreeNode((Get-HcNodeText $n))
      $tn.Name = $n.Id; $tn.Tag = $n; $tn.ImageKey = $n.Status; $tn.SelectedImageKey = $n.Status
      $tn.ToolTipText = "$(Get-Text "HcStatus_$($n.Status)"): $(Get-HcNodeText $n)"
      if ($n.Status -eq 'off') { $tn.ForeColor = $Theme.Muted }
      if ($n.Parent -and $map.ContainsKey($n.Parent)) { [void]$map[$n.Parent].Nodes.Add($tn) } else { [void]$tvHc.Nodes.Add($tn) }
      $map[$n.Id] = $tn
    }
    foreach ($n in $m.Nodes) {
      $tn = $map[$n.Id]; if (-not $tn.Nodes.Count) { continue }
      $open = if ($script:Health.Expanded.ContainsKey($n.Id)) { $script:Health.Expanded[$n.Id] } else { -not $n.Parent -or $n.Status -in 'error', 'warn' }
      if ($n.Status -in 'error', 'warn' -and $n.Kind -ne 'host') { $open = $true }
      if ($open) { $tn.Expand() }
    }
    $pick = if ($sel -and $map.ContainsKey($sel)) { $map[$sel] } elseif ($m.Problems.Count -and $map.ContainsKey($m.Problems[0].Node.Id)) { $map[$m.Problems[0].Node.Id] } elseif ($tvHc.Nodes.Count) { $tvHc.Nodes[0] } else { $null }
    if ($pick) { $tvHc.SelectedNode = $pick; $pick.EnsureVisible() }
  } finally { $tvHc.EndUpdate(); $script:HcListing = $false }
  Show-HealthNode $(if ($tvHc.SelectedNode) { $tvHc.SelectedNode.Tag } else { $null })
}
function Get-HcTreeNodes($nodes) { foreach ($x in $nodes) { $x; Get-HcTreeNodes $x.Nodes } }
# the selected item: what is wrong, its mode, its facts, its checks with their fix, its actions
function Show-HealthNode($n) {
  $script:HcNode = $n
  $lvHcFacts.BeginUpdate(); $lvHcFacts.Items.Clear(); $gridHc.Rows.Clear()
  try {
    if (-not $n) { $lblHcName.Text = Get-Text 'HcNoItem'; $lblHcState.Visible = $false; $lblHcWhy.Text = ''; $cmbHcItem.Enabled = $false; return }
    $script:Health.Selected = $n.Id
    $lblHcName.Text = $n.Name
    # its own state; the state of what is under it when it has nothing of its own
    $st = if ($n.Own -in 'error', 'warn', 'off') { $n.Own } else { $n.Status }
    $lblHcState.Text = Get-Text "HcStatus_$st"; $lblHcState.ForeColor = $script:KindColor[$st]; $lblHcState.BackColor = $script:KindSoft[$st]; $lblHcState.Visible = $true
    $lblHcState.Location = New-Object System.Drawing.Point(($lblHcName.Right + 10), ($lblHcName.Top + [int](($lblHcName.Height - $lblHcState.Height) / 2) + 1))
    $first = @(Get-HcByKind $n.Checks | Where-Object { $_.Kind -in 'error', 'warn' }) | Select-Object -First 1
    $lblHcWhy.Text = if ($first) { "$($first.Title): $($first.Text)" } elseif ($n.Problems) { Get-Text 'HcProblemsBelow' $n.Problems } else { Get-Text 'HcAllOkLine' }
    $tips.SetToolTip($lblHcWhy, $(if ($first) { "$($first.Text) $($first.Why)" } else { $lblHcWhy.Text }))
    # the mode of the item: its own, or the one of the page
    $s = Get-HealthSettings; $own = Get-HealthItemMode $s $n.Id
    $eff = Get-HealthEffectiveMode $script:Health.Model $s $(if ($n.Parent) { $n.Parent } else { $n.Id })
    if (-not $n.Parent) { $eff = $s.Mode }
    $script:HcSetting = $true; $cmbHcItem.Items.Clear()
    [void]$cmbHcItem.Items.AddRange(@((Get-Text 'HcItemInherit' $(if ($eff -eq 'repair') { Get-Text 'HcModeRepair' } else { Get-Text 'HcModeDiagnose' })), (Get-Text 'HcModeDiagnose'), (Get-Text 'HcModeRepair')))
    $cmbHcItem.SelectedIndex = switch ($own) { 'diagnose' { 1 } 'repair' { 2 } default { 0 } }; $cmbHcItem.Enabled = $true; $script:HcSetting = $false
    $lvHcFacts.Columns[0].Width = Get-FitWidth 120 (@($n.Facts | ForEach-Object Label)) $fontBase 18
    foreach ($f in $n.Facts) {
      $it = New-Object System.Windows.Forms.ListViewItem($f.Label); $it.ForeColor = $Theme.Muted; $it.UseItemStyleForSubItems = $false
      $sub = $it.SubItems.Add($f.Value); $sub.ForeColor = $Theme.Text; $it.ToolTipText = $f.Value; [void]$lvHcFacts.Items.Add($it)
    }
    $checks = @(Get-HcByKind $n.Checks)
    $state = Get-HealthState; $now = Get-Date
    foreach ($c in $checks) {
      $fixText = ''
      if ($c.Fix) { $p = Get-HealthCheckPlan $c $state $now; $fixText = if ($p.Safe) { Get-Text 'HcFixSafe' } else { Get-Text 'HcFix' } }
      $i = $gridHc.Rows.Add((Get-Text "HcStatus_$($c.Kind)"), $c.Title, $(if ($c.Why) { "$($c.Text)`r`n$($c.Why)" } else { $c.Text }), $fixText)
      $row = $gridHc.Rows[$i]; $row.Tag = $c
      if (-not $c.Fix) { $row.Cells[3] = New-Object System.Windows.Forms.DataGridViewTextBoxCell }
      else { $row.Cells[3].ToolTipText = $(if ($p.Blocked) { $p.Blocked } else { $p.Title }) }
      $cc = $row.Cells[0]; $cc.Style.ForeColor = $script:KindColor[$c.Kind]; $cc.Style.BackColor = $script:KindSoft[$c.Kind]
      $cc.Style.SelectionForeColor = $script:KindColor[$c.Kind]; $cc.Style.SelectionBackColor = $script:KindSoft[$c.Kind]; $cc.Style.Font = $fontSmallBold
      $row.Cells[2].ToolTipText = "$($c.Text) $($c.Why)"
      # the explanation in grey under the sentence: one cell, two lines
      $row.Cells[2].Style.ForeColor = $Theme.Text
    }
    if (-not $checks.Count) { $i = $gridHc.Rows.Add((Get-Text 'HcStatus_ok'), '', (Get-Text 'HcNoChecks'), ''); $gridHc.Rows[$i].Cells[3] = New-Object System.Windows.Forms.DataGridViewTextBoxCell
      $cc = $gridHc.Rows[$i].Cells[0]; $cc.Style.ForeColor = $script:KindColor.ok; $cc.Style.BackColor = $script:KindSoft.ok; $cc.Style.Font = $fontSmallBold }
    $gridHc.CurrentCell = $null
  } finally {
    $lvHcFacts.EndUpdate()
    # the value takes the rest of the width (the label column changed with the item): no horizontal scroll bar
    $lvHcFacts.Columns[1].Width = [Math]::Max(120, $lvHcFacts.ClientSize.Width - $lvHcFacts.Columns[0].Width - 4)
    Update-HcButtons; Set-HcInnerFit
  }
}
# the buttons of the item: those it offers, each as its plan allows it now (the reason in the tooltip)
function Update-HcButtons {
  $n = $script:HcNode
  $state = Get-HealthState; $now = Get-Date
  foreach ($k in @($script:HcButtons.Keys)) {
    $b = $script:HcButtons[$k]
    $want = $n -and (@($n.Actions) -contains $k -or ($script:HcVdiKinds -contains $k -and $script:Vdi.Model -and $n.Kind -eq $(if ($k -like 'Broker*') { 'broker' } else { 'host' }) -and @($(if ($k -like 'Broker*') { $script:Vdi.Model.Brokers } else { $script:Vdi.Model.Hosts }) | Where-Object { $_ -and $_.Name -eq $n.Name }).Count))
    if ($k -eq 'TimeSync' -and $n) { $want = $n.Kind -in 'host', 'dc', 'broker', 'replica' -and $n.Data -and $n.Data.PSObject.Properties['Reachable'] -and $n.Data.Reachable }
    $b.Visible = [bool]$want
    if (-not $want) { continue }
    if ($k -eq 'OpenDesktops') { Set-ActionEnabled $b ([bool]$script:VdiLoaded); $tips.SetToolTip($b, (Get-Text 'HcOpenDesktops')); continue }
    # the session of the user of a desktop: the plans of the Desktops part; the LAPS password: read only
    if ($script:HcVdiKinds -contains $k) {
      $list = if ($k -like 'Broker*') { @($script:Vdi.Model.Brokers) } else { @($script:Vdi.Model.Hosts) }
      $want = $n -and $script:Vdi.Model -and $n.Kind -eq $(if ($k -like 'Broker*') { 'broker' } else { 'host' }) -and @($list | Where-Object { $_ -and $_.Name -eq $n.Name }).Count
      $b.Visible = [bool]$want; if (-not $want) { continue }
      $vp = Get-VdiActionPlan $k $n.Name (Get-VdiState) $now; Set-ActionEnabled $b (-not $vp.Blocked); $tips.SetToolTip($b, $(if ($vp.Blocked) { $vp.Blocked } else { $vp.Title })); continue
    }
    if ($k -like 'Session*' -or $k -eq 'AssignDesktop') {
      $vp = if ($n.Desktop -and $script:Vdi.Model) { Get-VdiActionPlan $k $n.Desktop (Get-VdiState) $now $(if ($k -in 'SessionMessage', 'AssignDesktop') { '*' } else { $null }) } else { $null }
      Set-ActionEnabled $b ([bool]($vp -and -not $vp.Blocked)); $tips.SetToolTip($b, $(if (-not $vp) { Get-Text 'HcNoVdi' } elseif ($vp.Blocked) { $vp.Blocked } else { $vp.Title })); continue
    }
    if ($k -eq 'OpenSettings') { Set-ActionEnabled $b $true; $tips.SetToolTip($b, (Get-Text 'HcTipOpenSettings')); continue }
    if ($k -eq 'Laps') { Set-ActionEnabled $b $true; $tips.SetToolTip($b, (Get-Text 'HcTipLaps')); continue }
    $p = Get-HealthActionPlan $k $n.Id $state $now
    Set-ActionEnabled $b (-not $p.Blocked)
    $tips.SetToolTip($b, $(if ($p.Blocked) { $p.Blocked } else { $p.Title }))
  }
  $barHc.PerformLayout()
}
# An action by hand: a check's fix (its own plan, or the Desktops page's for its findings) or a button of the item.
# Always confirmed, with what happens and to whom; a safe one says so.
function Invoke-HealthAction([string]$kind, $n, $check = $null) {
  if (-not $script:Health.Model -or -not $n) { return }
  if ($kind -eq 'OpenDesktops') { Show-HealthInDesktops $n; return }
  if ($kind -like 'Session*' -or $kind -eq 'AssignDesktop') { if ($n.Desktop) { Invoke-VdiAction $kind $n.Desktop }; return }
  if ($kind -eq 'Laps') { Show-HealthLaps $n; return }
  if ($kind -eq 'OpenSettings') { Select-Page 1; $setTabs.SelectedTab = $tabSetHealth; return }
  if ($script:HcVdiKinds -contains $kind) { Invoke-VdiAction $kind $n.Name; return }
  if ($check -and $check.Source -eq 'vdi') { Invoke-VdiAction $check.Fix $check.Where $check.FixArg; return }
  $state = Get-HealthState; $now = Get-Date
  $plan = if ($check) { Get-HealthCheckPlan $check $state $now } else { Get-HealthActionPlan $kind $n.Id $state $now }
  if ($plan.Blocked) { Show-Message $plan.Title $plan.Blocked 'Information'; return }
  $text = $plan.Text
  if ($plan.Safe) { $text += "`r`n`r`n" + (Get-Text 'HcSafeNote') }
  if (Test-VdiDryRun) { $text += "`r`n`r`n" + (Get-Text 'VdiDryRunNote') }
  if (-not (Confirm-Action $plan.Title $text $(if ($plan.DefaultNo) { 'Button2' } else { 'Button1' }))) { return }
  Start-HealthJob $plan $false
}
# Runs a plan in the background: the result in a message (by hand) or in the status bar (by itself), the line in
# config\changes.log, the role remembered (never two servers of the same role in $script:HealthRoleMinutes)
function Start-HealthJob($plan, [bool]$auto) {
  $dry = Test-VdiDryRun
  $ps = [powershell]::Create()
  [void]$ps.AddScript($script:VdiJobRunner.ToString()).AddArgument(@($plan.Steps)).AddArgument($dry).AddArgument(8000).AddArgument(600000)
  $script:Health.Action = $plan.Title
  if ($plan.Role) { [void]$script:Health.Recent.Add([pscustomobject]@{ Role = $plan.Role; Target = $plan.Target; Name = $(if ($plan.PSObject.Properties['RoleName'] -and $plan.RoleName) { $plan.RoleName } elseif ($plan.Node) { $plan.Node.Name } else { "$($plan.Target)" }); Time = (Get-Date) }) }
  $barText.Text = Get-Text $(if ($auto) { 'HcAutoRunning' } else { 'VdiActionRunning' }) $plan.Title; $form.Cursor = 'AppStarting'
  Update-HcButtons
  $t = New-Object System.Windows.Forms.Timer; $t.Interval = 400
  $t.Tag = @{ PS = $ps; H = $ps.BeginInvoke(); Plan = $plan; Dry = $dry; Auto = $auto; Started = (Get-Date) }
  $t.add_Tick({ param($s, $e)
    $st = $s.Tag
    if (-not $st.H.IsCompleted -and ((Get-Date) - $st.Started).TotalSeconds -lt 900) { return }
    $s.Stop(); $s.Dispose()
    $res = @()
    try {
      if (-not $st.H.IsCompleted) { [void]$st.PS.BeginStop($null, $null); throw (Get-Text 'VdiErrTimeout') }
      $res = @($st.PS.EndInvoke($st.H) | ForEach-Object { $_ })
    } catch { $res = @([pscustomobject]@{ Name = $st.Plan.Title; Computer = ''; Ok = $false; DryRun = $false; Data = $null; Error = $_.Exception.GetBaseException().Message }) }
    finally { if ($st.H.IsCompleted) { $st.PS.Dispose() } }
    $script:Health.Action = $null; $form.Cursor = 'Default'; $barText.Text = ''
    Complete-HealthJob $st.Plan $res $st.Dry $st.Auto
  })
  $t.Start()
}
function Complete-HealthJob($plan, $res, [bool]$dry, [bool]$auto) {
  $ok = @($res).Count -gt 0 -and -not @($res | Where-Object { -not $_.Ok }).Count
  $why = (@($res | Where-Object { -not $_.Ok } | ForEach-Object { "$($_.Name): $($_.Error)" })) -join '; '
  $prefix = if ($plan.Source -eq 'vdi') { 'desktops' } else { 'health' }
  try { Add-ChangeLog ("{0}: {1}{2}: {3}{4}" -f $prefix, $(if ($auto) { 'automatic repair: ' } else { '' }), $plan.Log, $(if ($ok) { 'done' } else { "FAILED ($why)" }), $(if ($dry) { ' (dry run, nothing changed)' } else { '' })) } catch { }
  $lines = @(foreach ($r in @($res)) { Format-HealthStepResult $r })
  if ($auto) {
    [void]$script:Health.AutoLog.Add([pscustomobject]@{ Time = (Get-Date); Text = $plan.Title + $(if ($plan.Node) { " ($($plan.Node.Name))" } elseif ($plan.Target -is [string]) { " ($($plan.Target))" }); Ok = $ok })
    while ($script:Health.AutoLog.Count -gt 30) { $script:Health.AutoLog.RemoveAt(0) }
    $barText.Text = Get-Text $(if ($ok) { 'HcAutoDone' } else { 'HcAutoFailed' }) ($plan.Title + $(if ($plan.Node) { " ($($plan.Node.Name))" }))
    if ($script:Health.Queue.Count) { Start-HealthQueue; return }
  } else {
    Show-Message $plan.Title ((@($(if ($ok) { Get-Text 'VdiResDone' } else { Get-Text 'VdiResFailed' })) + '' + $lines) -join "`r`n") $(if ($ok) { 'Information' } else { 'Warning' })
  }
  Start-HealthRefresh -Queue
  if ($plan.Source -eq 'vdi' -or $plan.Kind -like 'Vm*') { Start-VdiRefresh -Queue }
}
# the safe repairs of the items in repair mode, after each reading: one after the other, never while another action runs
function Start-HealthAutoRepair {
  if (-not $script:Health.Model -or $script:Health.Queue.Count -or $script:Health.Action -or $script:Vdi.Action) { return }
  $plans = @(Get-HealthAutoPlans (Get-HealthState) (Get-HealthSettings) (Get-Date) $script:Health.Tried)
  if (-not $plans.Count) { return }
  foreach ($p in $plans) { [void]$script:Health.Queue.Add($p) }
  Start-HealthQueue
}
function Start-HealthQueue {
  if (-not $script:Health.Queue.Count) { return }
  $p = $script:Health.Queue[0]; $script:Health.Queue.RemoveAt(0)
  $script:Health.Tried[$p.Key] = Get-Date
  Start-HealthJob $p $true
}
# from the Health Center to the Desktops page: the row of a personal desktop, or the brokers and hosts on top
# The password of the local administrator of a server (LAPS), read only: here with the LAPS module of Windows, else on
# a domain controller over WinRM. Copied to the clipboard; changes.log says who read which one, never the password.
function Show-HealthLaps($n) {
  $name = if ($n.Kind -eq 'vm' -and $n.PSObject.Properties['ServerName'] -and $n.ServerName) { $n.ServerName } else { $n.Name }
  $title = Get-Text 'HcAct_Laps'; $pw = $null; $exp = $null; $err = $null
  try {
    if (Get-Command Get-LapsADPassword -ErrorAction SilentlyContinue) { $r = Get-LapsADPassword -Identity $name -AsPlainText -ErrorAction Stop }
    else {
      $dc = @($script:Health.Model.Nodes | Where-Object { $_.Kind -eq 'dc' -and $_.Fqdn -and $_.Data -and $_.Data.Reachable }) | Select-Object -First 1
      if (-not $dc) { throw (Get-Text 'LapsNoTool') }
      $r = Invoke-Command -ComputerName $dc.Fqdn -ErrorAction Stop -ScriptBlock { param($c) Get-LapsADPassword -Identity $c -AsPlainText -ErrorAction Stop } -ArgumentList $name
    }
    $pw = [string]$r.Password; $exp = $r.ExpirationTimestamp
  } catch { $err = $_.Exception.Message }
  try { Add-ChangeLog "LAPS: password of the local administrator of $name read$(if (-not $pw) { " (not found: $err)" })" } catch { }
  if (-not $pw) { Show-Message $title (Get-Text 'LapsNone' $name $(if ($err) { $err } else { '-' })) 'Information'; return }
  try { [System.Windows.Forms.Clipboard]::SetText($pw) } catch { }
  Show-Message $title (Get-Text 'LapsText' $name $pw $(if ($exp) { try { $(if ("$exp" -match '^\d{15,}$') { [datetime]::FromFileTime([int64]"$exp") } else { [datetime]$exp }).ToString('g') } catch { "$exp" } } else { '-' })) 'Information'
}
function Show-HealthInDesktops($n) {
  Select-Page 6
  if ($n -and $n.Kind -eq 'vm') { foreach ($it in $dskList.Items) { if ($it.Tag.Vm -ieq $n.Name) { $it.Selected = $true; $it.EnsureVisible(); break } } }
}
# from the Desktops page to the Health Center: a host, a broker or the VM of a row
function Show-InHealth([string]$id) {
  Select-Page 7
  $script:Health.Selected = $id
  $tn = @($tvHc.Nodes.Find($id, $true)) | Select-Object -First 1
  if ($tn) { $tvHc.SelectedNode = $tn; $tn.EnsureVisible() }
}
$tvHc.add_AfterSelect({ param($s, $e) if (-not $script:HcListing) { Show-HealthNode $e.Node.Tag } })
$cmbHcMode.add_SelectedIndexChanged({
  if ($script:HcSetting) { return }
  $s = Get-HealthSettings; $s.Mode = if ($cmbHcMode.SelectedIndex -eq 1) { 'repair' } else { 'diagnose' }
  try { Save-HealthSettings $s; Add-ChangeLog "health: mode of the page: $($s.Mode)" } catch { }
  if ($script:HcNode) { Show-HealthNode $script:HcNode }
  Start-HealthAutoRepair })
$cmbHcItem.add_SelectedIndexChanged({
  if ($script:HcSetting -or -not $script:HcNode) { return }
  $s = Get-HealthSettings; $mode = switch ($cmbHcItem.SelectedIndex) { 1 { 'diagnose' } 2 { 'repair' } default { '' } }
  Set-HealthItemMode $s $script:HcNode.Id $mode
  try { Save-HealthSettings $s; Add-ChangeLog "health: mode of $($script:HcNode.Name): $(if ($mode) { $mode } else { 'as the page' })" } catch { }
  Start-HealthAutoRepair })
$gridHc.add_CellContentClick({ param($s, $e)
  if ($e.RowIndex -lt 0 -or $e.ColumnIndex -ne 3) { return }
  $c = $s.Rows[$e.RowIndex].Tag; if ($c -and $c.Fix) { Invoke-HealthAction $c.Fix $script:Health.Model.Index[$c.Node] $c } })
$gridHc.add_PreviewKeyDown({ param($s, $e) if ($e.KeyCode -eq 'Enter') { $e.IsInputKey = $true } })
$gridHc.add_KeyDown({ param($s, $e)
  if ($e.KeyCode -eq 'Enter' -and $s.CurrentRow -and $s.CurrentRow.Tag -and $s.CurrentRow.Tag.Fix) {
    $e.Handled = $true; $e.SuppressKeyPress = $true; $c = $s.CurrentRow.Tag; Invoke-HealthAction $c.Fix $script:Health.Model.Index[$c.Node] $c } })
foreach ($b in $script:HcButtons.Values) { $b.add_Click({ param($s, $e) if ($script:HcNode) { Invoke-HealthAction $s.Name $script:HcNode } }) }
$btnHcRefresh.add_Click({ Start-HealthRefresh -Queue })
$btnHcSettings.add_Click({ Select-Page 6 })
# the settings of the Health Center: in the manager's settings of this account, not in the folder
# A custom check: its name, where it runs, the diagnostic script (returns @{ State = 'ok'|'warn'|'error'; Text = '...' }),
# the optional repair script, risky or not, every how many minutes. Saved in config\health-checks (Save-HealthCustomCheck).
function Show-CustomCheckDialog($c) {
  $W = 760; $X0 = 170
  $dlg = New-Object System.Windows.Forms.Form; Set-WindowIcon $dlg
  $dlg.Text = Get-Text 'CustomDlgTitle'; $dlg.Font = $fontBase; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.StartPosition = 'CenterParent'
  $y = 14
  $row = { param($key, $ctl, $h)
    $l = New-Object System.Windows.Forms.Label; $l.Text = Get-Text $key; $l.AutoSize = $true; $l.Location = New-Object System.Drawing.Point(14, ($script:CuY + 4)); $dlg.Controls.Add($l)
    $ctl.SetBounds($X0, $script:CuY, ($W - $X0 - 20), $h); $dlg.Controls.Add($ctl); $script:CuY += $h + 8 }
  $script:CuY = $y
  $tbName = New-Object System.Windows.Forms.TextBox; & $row 'CustomName' $tbName 26
  $cbWhere = New-Object System.Windows.Forms.ComboBox; $cbWhere.Font = $fontBase; foreach ($w in 'hosts', 'dcs', 'brokers', 'sql', 'servers') { [void]$cbWhere.Items.Add($w) }; & $row 'CustomWhere' $cbWhere 26
  $nuEvery = New-Object System.Windows.Forms.NumericUpDown; $nuEvery.Minimum = 3; $nuEvery.Maximum = 1440; $nuEvery.Value = 15; & $row 'CustomEvery' $nuEvery 26
  $tbDesc = New-Object System.Windows.Forms.TextBox; & $row 'CustomDesc' $tbDesc 26
  $tbScript = New-Object System.Windows.Forms.TextBox; $tbScript.Multiline = $true; $tbScript.ScrollBars = 'Both'; $tbScript.AcceptsReturn = $true; $tbScript.AcceptsTab = $true; $tbScript.WordWrap = $false; $tbScript.Font = $fontMono; & $row 'CustomScript' $tbScript 170
  $tbRepair = New-Object System.Windows.Forms.TextBox; $tbRepair.Multiline = $true; $tbRepair.ScrollBars = 'Both'; $tbRepair.AcceptsReturn = $true; $tbRepair.AcceptsTab = $true; $tbRepair.WordWrap = $false; $tbRepair.Font = $fontMono; & $row 'CustomRepair' $tbRepair 110
  $chkRisky = New-Object System.Windows.Forms.CheckBox; $chkRisky.Text = Get-Text 'CustomRisky'; $chkRisky.AutoSize = $true; $chkRisky.Location = New-Object System.Drawing.Point($X0, $script:CuY); $dlg.Controls.Add($chkRisky); $script:CuY += 30
  $hint = New-Object System.Windows.Forms.Label; $hint.Text = Get-Text 'CustomHint'; $hint.ForeColor = $Theme.Muted; $hint.MaximumSize = New-Object System.Drawing.Size(($W - 34), 0); $hint.AutoSize = $true; $hint.Location = New-Object System.Drawing.Point(14, $script:CuY); $dlg.Controls.Add($hint)
  $script:CuY += $hint.GetPreferredSize((New-Object System.Drawing.Size(($W - 34), 0))).Height + 8
  $err = New-Object System.Windows.Forms.Label; $err.ForeColor = $script:KindColor.error; $err.SetBounds(14, $script:CuY, ($W - 34), 36); $dlg.Controls.Add($err); $script:CuY += 40
  $ok = New-Button 'BtnSave' 110 28; $cancel = New-Button 'BtnCancel' 100 28
  $cancel.Location = New-Object System.Drawing.Point(($W - 20 - $cancel.Width), $script:CuY); $ok.Location = New-Object System.Drawing.Point(($cancel.Left - 8 - $ok.Width), $script:CuY)
  $cancel.DialogResult = 'Cancel'; $dlg.CancelButton = $cancel; $dlg.Controls.AddRange(@($ok, $cancel))
  $dlg.ClientSize = New-Object System.Drawing.Size($W, ($script:CuY + 42))
  if ($c) { $tbName.Text = $c.Name; $cbWhere.Text = $c.Where; $nuEvery.Value = [Math]::Max(3, [Math]::Min(1440, [int]$c.IntervalMin)); $tbDesc.Text = $c.Description; $tbScript.Text = $c.Script -replace "(?<!`r)`n", "`r`n"; $tbRepair.Text = $c.Repair -replace "(?<!`r)`n", "`r`n"; $chkRisky.Checked = [bool]$c.Risky }
  else { $cbWhere.Text = 'servers'; $tbScript.Text = "# @{ State = 'ok' | 'warn' | 'error'; Text = '...' }`r`n@{ State = 'ok'; Text = 'ok' }" }
  $ok.add_Click({
    $n = [pscustomobject]@{ Id = ''; Name = $tbName.Text.Trim(); Where = $cbWhere.Text.Trim(); IntervalMin = [int]$nuEvery.Value; Description = $tbDesc.Text.Trim(); Script = $tbScript.Text; Repair = $tbRepair.Text; Risky = $chkRisky.Checked }
    $why = Test-HealthCustomCheck $n; if ($why) { $err.Text = $why; return }
    try { Save-HealthCustomCheck $n $(if ($c) { $c.Id } else { '' }) } catch { $err.Text = $_.Exception.Message; return }
    $dlg.DialogResult = 'OK' })
  try { if ($dlg.ShowDialog($form) -eq 'OK') { Update-SettingsTabs; Start-HealthRefresh -Queue } } finally { $dlg.Dispose() }
}
# Settings > Health Center: every server typed by hand by its role (nothing is found by itself: servers can be on other
# networks or anywhere), each list with its notes; a new line at the bottom of a list adds, Remove (or Delete) removes.
# Settings of the Health Center: the areas on the left (a dot: on or off, how many of its checks), on the right the
# area chosen: its switch, the servers it reads, its own settings and thresholds, its checks. An area switched on
# without what it needs is not saved (Test-HcAreaReady): the window goes there and says what is missing.
function Show-HealthSettingsDialog {
  $s = Get-HealthSettings; $inv = $s.Inventory
  $areas = @($script:HcAreas.Keys); $pages = @{}
  $off = @{}; foreach ($x in @($s.Off)) { $off["$x"] = $true }
  $dlg = New-Object System.Windows.Forms.Form; Set-WindowIcon $dlg
  $dlg.Text = Get-Text 'HcSetTitle'; $dlg.Font = $fontBase; $dlg.StartPosition = 'CenterParent'; $dlg.MinimizeBox = $false; $dlg.BackColor = $Theme.Page
  # up to 1040x720, never larger than the screen (a foldable, a laptop with display scaling)
  $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
  $dlg.Size = New-Object System.Drawing.Size([Math]::Min(1040, $wa.Width - 24), [Math]::Min(720, $wa.Height - 24))
  $dlg.MinimumSize = New-Object System.Drawing.Size([Math]::Min(720, $wa.Width - 24), [Math]::Min(480, $wa.Height - 24))

  # top: where these settings are kept, and the switch of the whole reading
  $top = New-Panel 'Top' $Theme.Card 76; $top.Padding = New-Object System.Windows.Forms.Padding(18, 10, 18, 8); Add-Line $top 'Bottom'
  $chk = New-Object System.Windows.Forms.CheckBox; $chk.Text = Get-Text 'HcSetEnabled'; $chk.Checked = [bool]$s.Enabled; $chk.Font = $fontBold; $chk.AutoSize = $true; $chk.Dock = 'Top'
  $note = New-Label (Get-Text 'HcSetNote' $script:SettingsFile) $fontSmall $Theme.Muted; $note.AutoSize = $false; $note.Dock = 'Top'
  $top.Controls.Add($note); $top.Controls.Add($chk)
  # bottom: what is wrong, Save, Cancel
  $bottom = New-Panel 'Bottom' $Theme.Card 58; Add-Line $bottom 'Top'
  $err = New-Label '' $fontBase $script:KindColor.error; $err.AutoSize = $false; $err.Location = New-Object System.Drawing.Point(18, 8)
  $okB = New-ActionButton 'BtnSave' 'Save' 'primary'; $cancel = New-ActionButton 'BtnCancel'
  $cancel.DialogResult = 'Cancel'; $dlg.CancelButton = $cancel; $bottom.Controls.AddRange(@($err, $okB, $cancel))
  $bottom.add_Resize({ param($p, $e)
    $cancel.Location = New-Object System.Drawing.Point(($p.ClientSize.Width - 18 - $cancel.Width), 13)
    $okB.Location = New-Object System.Drawing.Point(($cancel.Left - 8 - $okB.Width), 13)
    $err.Size = New-Object System.Drawing.Size([Math]::Max(100, $okB.Left - 30), 44) })

  # left: the areas
  $nav = New-Object System.Windows.Forms.ListBox; $nav.Dock = 'Left'; $nav.Width = 250; $nav.DrawMode = 'OwnerDrawFixed'; $nav.ItemHeight = 56
  $nav.BorderStyle = 'None'; $nav.BackColor = $Theme.Card; $nav.IntegralHeight = $false
  foreach ($a in $areas) { [void]$nav.Items.Add($a) }
  $navLine = New-Panel 'Left' $Theme.Line 0 1
  $body = New-Panel 'Fill' $Theme.Card

  # ---- the parts of a page (a FlowLayoutPanel from top to bottom: the parts marked Full take its whole width)
  $part = { param($pg, $c, [bool]$full = $true) if ($full) { [void]$pg.Tag.Full.Add($c) }; $pg.Controls.Add($c); $c }
  $text = { param($pg, [string]$t, $font, $color, [int]$top = 0)
    $l = New-Label $t $font $color; $l.Margin = New-Object System.Windows.Forms.Padding(0, $top, 0, 4); & $part $pg $l | Out-Null; $l }
  $section = { param($pg, [string]$key) $l = & $text $pg (Get-Text $key) $fontSmallBold $Theme.Muted 18; $l.Text = $l.Text.ToUpper(); [void]$pg.Tag.Parts.Add($l); $l }
  $cue = { param($t, [string]$hint) $t.Tag = @{ Cue = $hint; Col = $t.Tag }; $t.add_HandleCreated({ param($x, $e) [void][OtrNative]::SendMessage($x.Handle, 0x1501, [IntPtr]1, [string]$x.Tag.Cue) }) }
  # a field: its name above, the box, a hint under it
  $field = { param($pg, [string]$key, [string]$value, [int]$width = 420, [string]$hintKey = '')
    $w = New-Object System.Windows.Forms.FlowLayoutPanel; $w.FlowDirection = 'TopDown'; $w.WrapContents = $false; $w.AutoSize = $true; $w.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 6)
    $l = New-Label (Get-Text $key) $fontBase $Theme.Text; $l.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 3); $w.Controls.Add($l)
    $tb = New-Object System.Windows.Forms.TextBox; $tb.Font = $fontBase; $tb.Width = $width; $tb.Text = $value; $w.Controls.Add($tb)
    if ($hintKey -and $script:Text.ContainsKey($hintKey)) { $h = New-Label (Get-Text $hintKey) $fontSmall $Theme.Muted; $h.MaximumSize = New-Object System.Drawing.Size(640, 0); $h.Margin = New-Object System.Windows.Forms.Padding(0, 3, 0, 0); $w.Controls.Add($h) }
    & $part $pg $w $false | Out-Null; [void]$pg.Tag.Parts.Add($w); $tb }
  # a list of servers: one line each (its boxes, a remove button), "+ Add" for one more line
  $widths = @{ Name = 260; Note = 320 }
  $devWidths = @{ Name = 130; Address = 120; Ports = 80; Share = 160; Mac = 130; Note = 150 }
  $addRow = { param($box, $values)
    $r = New-Object System.Windows.Forms.FlowLayoutPanel; $r.WrapContents = $false; $r.AutoSize = $true; $r.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
    # as wide as the names of the columns above it are now (the page may have made them narrower)
    $hd = $box.Controls[0]; $j = 0
    foreach ($c in $box.Tag.Cols) {
      $tb = New-Object System.Windows.Forms.TextBox; $tb.Font = $fontBase; $tb.Width = $(if ($hd -and $hd.Controls.Count -gt $j) { $hd.Controls[$j].Width - 6 } else { $box.Tag.Widths[$c] }); $j++; $tb.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 0)
      $tb.Text = if ($values) { [string]$values.$c } else { '' }; $tb.Tag = $c; & $cue $tb (Get-Text "HcInvCol_$c"); $r.Controls.Add($tb) }
    $x = New-Object System.Windows.Forms.Button; $x.Text = [string][char]0x2715; $x.FlatStyle = 'Flat'; $x.FlatAppearance.BorderSize = 0; $x.ForeColor = $Theme.Muted
    $x.Size = New-Object System.Drawing.Size(28, 24); $x.Cursor = 'Hand'; $x.Tag = $r; $tips.SetToolTip($x, (Get-Text 'HcRemoveRow'))
    $x.add_Click({ param($b, $e) $row = $b.Tag; $row.Parent.Controls.Remove($row); $row.Dispose() }); $r.Controls.Add($x)
    $box.Controls.Add($r); $box.Controls.SetChildIndex($r, $box.Controls.Count - 2); $r }
  $list = { param($pg, [string]$key, $cols, $rows)
    & $text $pg (Get-Text "HcInv_$key") $fontBold $Theme.Text 8 | Out-Null
    $hk = "HcInvHint_$key"; if ($script:Text.ContainsKey($hk)) { & $text $pg (Get-Text $hk) $fontSmall $Theme.Muted | Out-Null }
    $box = New-Object System.Windows.Forms.FlowLayoutPanel; $box.FlowDirection = 'TopDown'; $box.WrapContents = $false; $box.AutoSize = $true; $box.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 8)
    $box.Tag = @{ Cols = $cols; Widths = $(if ($cols.Count -gt 2) { $devWidths } else { $widths }) }
    # the names of the columns over the boxes (the grey hint inside a box goes when it is filled)
    $hd = New-Object System.Windows.Forms.FlowLayoutPanel; $hd.WrapContents = $false; $hd.AutoSize = $true; $hd.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 2)
    foreach ($c in $cols) { $l = New-Label (Get-Text "HcInvCol_$c") $fontSmall $Theme.Muted; $l.AutoSize = $false; $l.Size = New-Object System.Drawing.Size(($box.Tag.Widths[$c] + 6), 18); $l.Margin = New-Object System.Windows.Forms.Padding(0); $hd.Controls.Add($l) }
    $box.Controls.Add($hd)
    $add = New-Object System.Windows.Forms.LinkLabel; $add.Text = Get-Text 'HcAddRow'; $add.AutoSize = $true; $add.Font = $fontSmallBold; $add.LinkColor = $Theme.Accent; $add.LinkBehavior = 'HoverUnderline'
    $add.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0); $add.Tag = $box; $box.Controls.Add($add)
    $add.add_LinkClicked({ param($l, $e) $r = & $addRow $l.Tag $null; $r.Controls[0].Focus() })
    foreach ($row in @($rows)) { [void](& $addRow $box $row) }
    if (-not @($rows).Count) { [void](& $addRow $box $null) }
    & $part $pg $box $false | Out-Null; [void]$pg.Tag.Parts.Add($box); $pg.Tag.Lists[$key] = $box; $box }
  $readList = { param($box) @(foreach ($r in $box.Controls) { if ($r -isnot [System.Windows.Forms.FlowLayoutPanel] -or -not ($r.Controls[0] -is [System.Windows.Forms.TextBox])) { continue }
      $o = [ordered]@{}; foreach ($tb in $r.Controls) { if ($tb -is [System.Windows.Forms.TextBox]) { $o[[string]$tb.Tag.Col] = $tb.Text.Trim() } }
      if ($o.Name) { [pscustomobject]$o } }) }

  foreach ($a in $areas) {
    $def = $script:HcAreas[$a]
    $pg = New-Object System.Windows.Forms.FlowLayoutPanel; $pg.Dock = 'Fill'; $pg.FlowDirection = 'TopDown'; $pg.WrapContents = $false; $pg.AutoScroll = $true
    $pg.Padding = New-Object System.Windows.Forms.Padding(24, 16, 24, 24); $pg.BackColor = $Theme.Card; $pg.Visible = $false
    $pg.Tag = @{ Area = $a; Full = (New-Object System.Collections.ArrayList); Parts = (New-Object System.Collections.ArrayList); Lists = @{}; Checks = (New-Object System.Collections.ArrayList); Limits = (New-Object System.Collections.ArrayList) }
    $pages[$a] = $pg; $body.Controls.Add($pg)
    & $text $pg (Get-Text "HcArea_$a") $fontPageTitle $Theme.Text | Out-Null
    & $text $pg (Get-Text "HcAreaDesc_$a") $fontBase $Theme.Muted | Out-Null
    # the switch of the area: on when at least one of its checks is and it has what they need (without it they have
    # nothing to read: an area never configured opens switched off, and Save does not stop on it)
    $sw = New-Object System.Windows.Forms.CheckBox; $sw.Text = Get-Text 'HcAreaOn' (Get-Text "HcArea_$a"); $sw.Font = $fontBold; $sw.AutoSize = $true
    $sw.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 2); $sw.Checked = [bool]@($def.Checks | Where-Object { -not $off[$_] }).Count -and -not (Test-HcAreaReady $s $a); $sw.Tag = $pg
    $pg.Tag.Switch = $sw; & $part $pg $sw $false | Out-Null
    if ($def.Lists.Count) { & $section $pg 'HcSecServers' | Out-Null
      foreach ($k in $def.Lists) { [void](& $list $pg $k $(if ($k -eq 'DeviceList') { @('Name', 'Address', 'Ports', 'Share', 'Mac', 'Note') } else { @('Name', 'Note') }) $inv.$k) } }
    switch ($a) {
      'hyperv' { & $section $pg 'HcSecSettings' | Out-Null
        $cbCl = New-Object System.Windows.Forms.CheckBox; $cbCl.Text = Get-Text 'HcInvCluster'; $cbCl.AutoSize = $true; $cbCl.Checked = $inv.HvCluster -eq 'yes'; $cbCl.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 2)
        & $part $pg $cbCl $false | Out-Null; [void]$pg.Tag.Parts.Add($cbCl)
        $tbClName = & $field $pg 'HcInvClusterName' $inv.ClusterName 300
        $cbCl.add_CheckedChanged({ $tbClName.Enabled = $cbCl.Checked -and $pages.hyperv.Tag.Switch.Checked }); $tbClName.Enabled = $cbCl.Checked
        $tbCrit = & $field $pg 'HcSetCritical' $s.CriticalVms 520 'HcSetCriticalHint' }
      'desktops' { & $section $pg 'HcSecSettings' | Out-Null; $tbBroker = & $field $pg 'HcSetBrokerName' $s.BrokerName 420 'HcSetBrokerNameHint' }
      'sql' { & $section $pg 'HcSecSettings' | Out-Null; $tbSql = & $field $pg 'HcSetSql' $s.SqlListener 420 'HcSetSqlHint' }
      'backup' { & $section $pg 'HcSecSettings' | Out-Null
        $tbBPath = & $field $pg 'HcSetBackup' $s.BackupPath 520 'HcSetBackupHint'
        $tbBText = & $field $pg 'HcSetBackupText' $s.BackupText 420 'HcSetBackupTextHint'
        $tbBHours = & $field $pg 'HcSetBackupHours' ([string]$s.BackupHours) 90 }
    }
    # its thresholds, as numbers with their names
    if ($def.Limits.Count) { & $section $pg 'HcSecLimits' | Out-Null
      $lw = New-Object System.Windows.Forms.FlowLayoutPanel; $lw.AutoSize = $true; $lw.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 4)
      foreach ($k in $def.Limits) {
        $cell = New-Object System.Windows.Forms.FlowLayoutPanel; $cell.WrapContents = $false; $cell.AutoSize = $true; $cell.Margin = New-Object System.Windows.Forms.Padding(0, 0, 24, 6)
        $l = New-Label (Get-Text "HcLim_$k") $fontBase $Theme.Text; $l.AutoSize = $false; $l.Size = New-Object System.Drawing.Size(300, 26); $l.TextAlign = 'MiddleLeft'; $cell.Controls.Add($l)
        $nu = New-Object System.Windows.Forms.NumericUpDown; $nu.Minimum = 0; $nu.Maximum = 100000; $nu.Width = 90; $nu.Value = [decimal]$script:HealthLimits[$k]; $nu.Tag = $k; $nu.TextAlign = 'Right'
        $tips.SetToolTip($nu, "$k ($([string]$script:HealthLimitsDefault[$k]))"); $cell.Controls.Add($nu); [void]$pg.Tag.Limits.Add($nu); $lw.Controls.Add($cell) }
      & $part $pg $lw | Out-Null; [void]$pg.Tag.Parts.Add($lw) }
    # its checks, two columns where there is room; the reason of each in its tooltip
    & $section $pg 'HcSecChecks' | Out-Null
    $links = New-Object System.Windows.Forms.FlowLayoutPanel; $links.AutoSize = $true; $links.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
    foreach ($w in 'All', 'None') { $ll = New-Object System.Windows.Forms.LinkLabel; $ll.Text = Get-Text "HcChecks$w"; $ll.AutoSize = $true; $ll.LinkColor = $Theme.Accent; $ll.LinkBehavior = 'HoverUnderline'
      $ll.Margin = New-Object System.Windows.Forms.Padding(0, 0, 14, 0); $ll.Tag = @{ Page = $pg; On = ($w -eq 'All') }
      $ll.add_LinkClicked({ param($x, $e) foreach ($cb in $x.Tag.Page.Tag.Checks) { $cb.Checked = $x.Tag.On } }); $links.Controls.Add($ll) }
    & $part $pg $links $false | Out-Null; [void]$pg.Tag.Parts.Add($links)
    $cw = New-Object System.Windows.Forms.FlowLayoutPanel; $cw.AutoSize = $true; $cw.Margin = New-Object System.Windows.Forms.Padding(0)
    $titles = @($def.Checks | ForEach-Object { ((Get-Text "HcT_$_") -replace '\s*\{\d+\}', '').Trim().TrimEnd(':') })
    for ($k = 0; $k -lt $def.Checks.Count; $k++) {
      $id = $def.Checks[$k]; $tt = $titles[$k]; if (@($titles | Where-Object { $_ -eq $tt }).Count -gt 1) { $tt = "$tt ($id)" }
      $cb = New-Object System.Windows.Forms.CheckBox; $cb.Text = $tt; $cb.Tag = $id; $cb.Checked = -not $off[$id]; $cb.AutoSize = $false; $cb.AutoEllipsis = $true
      $cb.Size = New-Object System.Drawing.Size(330, 24); $cb.Margin = New-Object System.Windows.Forms.Padding(0, 0, 12, 0)
      $why = [string]$script:Text["HcW_$id"]; if ($why) { $tips.SetToolTip($cb, ($why -replace '\{\d+\}', [string][char]0x2026)) }
      $cb.add_CheckedChanged({ $nav.Invalidate() }); [void]$pg.Tag.Checks.Add($cb); $cw.Controls.Add($cb) }
    & $part $pg $cw | Out-Null; [void]$pg.Tag.Parts.Add($cw)
    # off, its parts are greyed (kept as they are); on again with nothing ticked, every check is
    $sw.add_CheckedChanged({ param($x, $e) $p = $x.Tag
      foreach ($c in $p.Tag.Parts) { $c.Enabled = $x.Checked }
      if ($x.Checked -and -not @($p.Tag.Checks | Where-Object { $_.Checked }).Count) { foreach ($cb in $p.Tag.Checks) { $cb.Checked = $true } }
      if ($p.Tag.Area -eq 'hyperv') { $tbClName.Enabled = $x.Checked -and $cbCl.Checked }
      $nav.Invalidate() })
    foreach ($c in $pg.Tag.Parts) { $c.Enabled = $sw.Checked }
    # the parts marked Full follow the width of the page (texts wrap, the checks make columns)
    # and the boxes of the lists share that width in proportion (never under 60 points): nothing goes past the edge
    $pg.add_Resize({ param($p, $e) $w = [Math]::Max(200, $p.ClientSize.Width - $p.Padding.Horizontal - 8)
      foreach ($c in $p.Tag.Full) { $c.MaximumSize = New-Object System.Drawing.Size($w, 0) }
      foreach ($box in $p.Tag.Lists.Values) {
        $cols = $box.Tag.Cols; $base = 0; foreach ($c in $cols) { $base += $box.Tag.Widths[$c] }
        $room = $w - 40 - 6 * $cols.Count; $f = [Math]::Min(1.4, $room / [double]$base)
        $cw = @{}; foreach ($c in $cols) { $cw[$c] = [Math]::Max(60, [int]($box.Tag.Widths[$c] * $f)) }
        foreach ($r in $box.Controls) { if ($r -isnot [System.Windows.Forms.FlowLayoutPanel]) { continue }
          $j = 0; foreach ($x in $r.Controls) { if ($j -ge $cols.Count) { break }; $x.Width = $cw[$cols[$j]] + $(if ($x -is [System.Windows.Forms.Label]) { 6 } else { 0 }); $j++ } } } })
  }
  if ($pages.hyperv) { $tbClName.Enabled = $tbClName.Enabled -and $pages.hyperv.Tag.Switch.Checked }

  $nav.add_DrawItem({ param($x, $e) if ($e.Index -lt 0) { return }
    $a = [string]$x.Items[$e.Index]; $p = $pages[$a]; $sel = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
    $g = $e.Graphics; $b = $e.Bounds
    $br = New-Object System.Drawing.SolidBrush($(if ($sel) { $Theme.Hover } else { $Theme.Card })); $g.FillRectangle($br, $b); $br.Dispose()
    if ($sel) { $br = New-Object System.Drawing.SolidBrush($Theme.Accent); $g.FillRectangle($br, $b.X, ($b.Y + 10), 4, ($b.Height - 20)); $br.Dispose() }
    $on = $p.Tag.Switch.Checked
    $g.SmoothingMode = 'AntiAlias'; $br = New-Object System.Drawing.SolidBrush($(if ($on) { $script:KindColor.ok } else { $script:KindColor.off })); $g.FillEllipse($br, ($b.X + 18), ($b.Y + 14), 10, 10); $br.Dispose()
    [System.Windows.Forms.TextRenderer]::DrawText($g, (Get-Text "HcArea_$a"), $fontBold, (New-Object System.Drawing.Point(($b.X + 38), ($b.Y + 8))), $Theme.Text)
    $st = if ($on) { Get-Text 'HcAreaState' @($p.Tag.Checks | Where-Object { $_.Checked }).Count $p.Tag.Checks.Count } else { Get-Text 'HcAreaStateOff' }
    [System.Windows.Forms.TextRenderer]::DrawText($g, $st, $fontSmall, (New-Object System.Drawing.Point(($b.X + 38), ($b.Y + 30))), $Theme.Muted) })
  $nav.add_SelectedIndexChanged({ foreach ($p in $pages.Values) { $p.Visible = $false }; $p = $pages[[string]$nav.SelectedItem]; if ($p) { $p.Visible = $true; $p.BringToFront() } })
  $top.add_Resize({ param($p, $e) $note.Height = (Measure-Note $note.Text ($p.ClientSize.Width - $p.Padding.Horizontal) $fontSmall) + 4; $h = $chk.Height + $note.Height + $p.Padding.Vertical + 4; if ($p.Height -ne $h) { $p.Height = $h } })
  $dlg.Controls.Add($body); $dlg.Controls.Add($navLine); $dlg.Controls.Add($nav); $dlg.Controls.Add($top); $dlg.Controls.Add($bottom)
  $nav.SelectedIndex = 0

  $okB.add_Click({
    $n = Get-HealthSettings; $i = New-HealthInventory
    foreach ($p in $pages.Values) { foreach ($k in @($p.Tag.Lists.Keys)) { $i.$k = @(& $readList $p.Tag.Lists[$k]) } }
    $i.HvCluster = if ($cbCl.Checked) { 'yes' } else { 'no' }; $i.ClusterName = $tbClName.Text.Trim()
    $n.Inventory = $i; $n.Enabled = $chk.Checked; $n.BrokerName = $tbBroker.Text; $n.SqlListener = $tbSql.Text; $n.CriticalVms = $tbCrit.Text
    $n.BackupPath = $tbBPath.Text; $n.BackupText = $tbBText.Text; $n.BackupHours = $tbBHours.Text
    # the thresholds that differ from the defaults
    $n.Limits = (@(foreach ($p in $pages.Values) { foreach ($nu in $p.Tag.Limits) { if ([int]$nu.Value -ne [int]$script:HealthLimitsDefault[$nu.Tag]) { "$($nu.Tag)=$([int]$nu.Value)" } } }) | Sort-Object) -join '; '
    # off: the checks not ticked and every check of an area switched off; the others (custom checks) as they were
    $known = @($areas | ForEach-Object { $script:HcAreas[$_].Checks })
    $n.Off = @(@(@($s.Off) | Where-Object { $known -notcontains $_ }) + @(foreach ($p in $pages.Values) { foreach ($cb in $p.Tag.Checks) { if (-not $p.Tag.Switch.Checked -or -not $cb.Checked) { [string]$cb.Tag } } }))
    foreach ($a in $areas) { if ($pages[$a].Tag.Switch.Checked) { $why = Test-HcAreaReady $n $a; if ($why) { $nav.SelectedItem = $a; $err.Text = $why; return } } }
    $why = Test-HealthSettings $n
    if ($why) { $err.Text = $why; return }
    try { Save-HealthSettings $n } catch { $err.Text = $_.Exception.Message; return }
    $dlg.DialogResult = 'OK' })
  # test: the dialog drawn into OTR_MANAGER_HCSET_SHOT (OTR_MANAGER_HCSET_TAB = the area, by its number), then closed
  # with OTR_MANAGER_HCSET_SAVE=1 Save is pressed as it is (what it refuses goes to stderr): saved = nothing lost
  if ($env:OTR_MANAGER_HCSET_SHOT) { $dlg.add_Shown({ $nav.SelectedIndex = [int]$env:OTR_MANAGER_HCSET_TAB; $dlg.Refresh(); [System.Windows.Forms.Application]::DoEvents()
    $bm = New-Object System.Drawing.Bitmap($dlg.Width, $dlg.Height); $dlg.DrawToBitmap($bm, (New-Object System.Drawing.Rectangle(0, 0, $dlg.Width, $dlg.Height))); $bm.Save($env:OTR_MANAGER_HCSET_SHOT)
    if ($env:OTR_MANAGER_HCSET_SAVE) { $okB.PerformClick(); if ($dlg.DialogResult -ne 'OK') { [Console]::Error.WriteLine("not saved: $($err.Text)") } }
    $dlg.Close() }) }
  try { if ($dlg.ShowDialog($form) -eq 'OK') { $barText.Text = Get-Text 'HcSetSaved'; Update-SettingsTabs; Start-HealthRefresh -Queue; Start-VdiRefresh -Queue } } finally { $dlg.Dispose() }
}
$hcTimer = New-Object System.Windows.Forms.Timer; $hcTimer.Interval = $script:HealthRefreshSeconds * 1000
$hcTimer.add_Tick({ if (-not $env:OTR_MANAGER_HEALTH_DEMO) { Start-HealthRefresh } else { Update-HealthStamp } })
# ---------------- remote screen ----------------
# The screen of the device in the default browser: over SSH (the key of the manager in the vault, as otradmin) the
# device starts x11vnc and the noVNC viewer on 127.0.0.1 with a one-time password (remote-screen.sh); an SSH tunnel
# brings them to a free local port. Nothing is installed on this PC: the ssh.exe of Windows 10/11 and the browser.
# Only the key of the vault is offered (IdentitiesOnly): the keys in the profile of this account do not open
# screens. The device shows a notice while it lasts and stops by itself after 2 hours; closing the window here ends it.
# kind: wake, reboot, poweroff, report, command
function Invoke-DeviceAction($d, [string]$kind) {
  $name = $d.Name; $title = Get-Text 'PwrTitle' $name
  if ($kind -eq 'wake') {
    if (-not (Confirm-Action $title (Get-Text 'PwrWakeAsk' $name ([string]$d.S['MAC'])))) { return }
    if (Send-DeviceWake $d) { $barText.Text = Get-Text 'PwrWakeSent' $name } else { Show-Message $title (Get-Text 'PwrNoMac') }
    return
  }
  $ip = Get-DeviceIp $d
  if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) { Show-Message $title (Get-Text 'ErrRemoteNoSshExe'); return }
  if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Show-Message $title (Get-Text 'ErrRemoteNoIp'); return }
  if ($d.S['CFG_SSH'] -ne 'on') { Show-Message $title (Get-Text 'ErrRemoteNoSsh'); return }
  $user = Get-SessionUser $d.S
  $cmd = switch ($kind) { 'reboot' { 'sudo systemctl reboot' } 'poweroff' { 'sudo systemctl poweroff' } 'report' { 'sudo systemctl start openthinrdp-report.service' } default { '' } }
  if ($kind -eq 'command') {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $cmd = [Microsoft.VisualBasic.Interaction]::InputBox((Get-Text 'PwrCommandAsk' $name), $title, '')
    if (-not $cmd.Trim()) { return }
  }
  $ask = switch ($kind) { 'reboot' { Get-Text 'PwrRebootAsk' $name } 'poweroff' { Get-Text 'PwrOffAsk' $name } 'report' { $null } default { Get-Text 'PwrCommandConfirm' $name $cmd "`r`n`r`n" } }
  if ($ask -and $user) { $ask += "`r`n`r`n" + (Get-Text 'PwrSessionWarn' $user) }
  if ($ask -and -not (Confirm-Action $title $ask $(if ($user -or $kind -eq 'command') { 'Button2' } else { 'Button1' }))) { return }
  if (-not (Request-VaultOpen)) { return }
  $key = Get-VaultKeyFile
  if (-not $key) { Show-Message $title (Get-Text 'ErrRemoteNoVaultKey'); Select-Page 4; return }
  $form.Cursor = 'WaitCursor'
  try { $r = Invoke-DeviceSsh $ip $cmd $key $name } finally { $form.Cursor = 'Default' }
  Add-ChangeLog "${name}: $kind ($cmd) -> exit $($r.Code)"
  # reboot and poweroff end the connection themselves (255): that is the expected answer
  if ($kind -in 'reboot', 'poweroff' -and $r.Code -in 0, 255) { $barText.Text = Get-Text "Pwr${kind}Done" $name; return }
  if ($kind -eq 'report' -and $r.Code -eq 0) { $barText.Text = Get-Text 'PwrReportDone' $name; return }
  $out = if ($r.Text) { $r.Text } else { Get-Text 'PwrNoOutput' }
  if ($out.Length -gt 6000) { $out = $out.Substring(0, 6000) + "`r`n..." }
  Show-Message $title ((Get-Text 'PwrResult' $cmd $r.Code "`r`n") + "`r`n`r`n" + ($out -replace "(?<!`r)`n", "`r`n")) $(if ($r.Code -eq 0) { 'Information' } else { 'Warning' })
}

function Start-RemoteScreen($d) {
  $name = $d.Name; $ip = Get-DeviceIp $d
  if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) { Show-Message (Get-Text 'RemoteTitle' $name) (Get-Text 'ErrRemoteNoSshExe'); return }
  if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Show-Message (Get-Text 'RemoteTitle' $name) (Get-Text 'ErrRemoteNoIp'); return }
  if ($d.S['CFG_SSH'] -ne 'on') { Show-Message (Get-Text 'RemoteTitle' $name) (Get-Text 'ErrRemoteNoSsh'); return }
  if (-not (Request-VaultOpen)) { return }
  $key = Get-VaultKeyFile
  if (-not $key) { Show-Message (Get-Text 'RemoteTitle' $name) (Get-Text 'ErrRemoteNoVaultKey'); Select-Page 4; return }
  $form.Cursor = 'WaitCursor'; $barText.Text = Get-Text 'RemoteStarting' $name; [System.Windows.Forms.Application]::DoEvents()
  try {
    $r = Invoke-DeviceSsh $ip 'sudo /opt/openthinrdp/remote-screen.sh start' $key $name
    # a new host key for this name: only the administrator can tell whether the device was reinstalled
    if (Test-HostKeyChanged $r.Text) {
      if (-not (Confirm-Action (Get-Text 'RemoteTitle' $name) (Get-Text 'RemoteHostKeyChanged' $name $ip) 'Button2')) { return }
      Remove-HostKey $name
      $r = Invoke-DeviceSsh $ip 'sudo /opt/openthinrdp/remote-screen.sh start' $key $name
    }
    $pw = if ($r.Text -match '(?m)^PASSWORD=(\S+)') { $Matches[1] } else { '' }
    if (-not $pw) {
      $why = if ($r.Text -match '(?m)^ERROR=(.+)$') { $Matches[1] } else { $r.Text.Trim() }
      Show-Message (Get-Text 'RemoteTitle' $name) (Get-Text 'ErrRemoteFailed' $why); return
    }
    # a free local port, then the tunnel to the viewer on the device (127.0.0.1:6080 there)
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0); $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
    # Start-Process joins the arguments with spaces: the path of the key in quotes
    $tunnel = Start-Process ssh.exe -WindowStyle Hidden -PassThru -ArgumentList (@('-N', '-i', "`"$key`"", '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes') + @(Get-HostKeyArgs $name) + @(
      '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=15', '-L', "${port}:127.0.0.1:6080", "otradmin@$ip"))
    $ok = $false
    for ($i = 0; $i -lt 40 -and -not $tunnel.HasExited; $i++) {
      try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $port); $c.Close(); $ok = $true; break } catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $ok) {
      if (-not $tunnel.HasExited) { $tunnel.Kill() }
      [void](Invoke-DeviceSsh $ip 'sudo /opt/openthinrdp/remote-screen.sh stop' $key $name)
      Show-Message (Get-Text 'RemoteTitle' $name) (Get-Text 'ErrRemoteFailed' (Get-Text 'ErrRemoteTunnel')); return
    }
    Start-Process "http://127.0.0.1:$port/vnc_lite.html?password=$pw&scale=true"
    Add-ChangeLog (Get-Text 'LogRemoteScreen' $name)
  } finally { $form.Cursor = 'Default'; $barText.Text = '' }
  # while this window is open the remote screen stays on; closing it ends it on the device too
  $w = New-Object System.Windows.Forms.Form; Set-WindowIcon $w
  $w.Text = Get-Text 'RemoteTitle' $name; $w.Font = $fontBase; $w.StartPosition = 'CenterParent'; $w.FormBorderStyle = 'FixedDialog'
  $w.MinimizeBox = $false; $w.MaximizeBox = $false; $w.ClientSize = New-Object System.Drawing.Size(460, 130)
  $t = New-Object System.Windows.Forms.Label; $t.Text = Get-Text 'RemoteRunning' $name; $t.SetBounds(14, 12, 432, 70)
  $b = New-Button 'BtnRemoteEnd' 140 28; $b.Location = New-Object System.Drawing.Point((460 - $b.Width - 14), 90)
  $b.add_Click({ $w.Close() }); $w.AcceptButton = $b; $w.Controls.AddRange(@($t, $b))
  [void]$w.ShowDialog($form)
  if (-not $tunnel.HasExited) { $tunnel.Kill() }
  [void](Invoke-DeviceSsh $ip 'sudo /opt/openthinrdp/remote-screen.sh stop' $key $name)
}

# ---------------- VPN profile ----------------
# The OpenVPN profile of a device (.ovpn, as the VPN provider or the firewall gives it) and the user and password it
# asks for, over SSH with the key of the vault. They are secrets of the device (in its TPM when it has one): they never
# go through the management folder, which every device can read.
function Show-VpnProfileDialog($d) {
  $name = $d.Name
  if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) { Show-Message (Get-Text 'VpnTitle' $name) (Get-Text 'ErrRemoteNoSshExe'); return }
  if ($d.S['CFG_SSH'] -ne 'on') { Show-Message (Get-Text 'VpnTitle' $name) (Get-Text 'ErrRemoteNoSsh'); return }
  if (-not (Request-VaultOpen)) { return }
  $key = Get-VaultKeyFile
  if (-not $key) { Show-Message (Get-Text 'VpnTitle' $name) (Get-Text 'ErrRemoteNoVaultKey'); Select-Page 4; return }
  $dlg = New-Object System.Windows.Forms.Form; Set-WindowIcon $dlg
  $dlg.Text = Get-Text 'VpnTitle' $name; $dlg.Font = $fontBase; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
  $dlg.StartPosition = 'CenterParent'; $W = 600
  $note = New-Object System.Windows.Forms.Label; $note.Text = (Get-Text 'VpnNote') + "`r`n" + (Get-Text 'VpnNow' $(if ($d.S['VPN']) { $d.S['VPN'] } else { [char]0x2014 }))
  $note.MaximumSize = New-Object System.Drawing.Size(($W - 28), 0); $note.AutoSize = $true; $note.Location = New-Object System.Drawing.Point(14, 12)
  $dlg.Controls.Add($note); $y = 12 + $note.GetPreferredSize((New-Object System.Drawing.Size(($W - 28), 0))).Height + 14
  $lp = New-Object System.Windows.Forms.Label; $lp.Text = Get-Text 'VpnProfile'; $lp.AutoSize = $true; $lp.Location = New-Object System.Drawing.Point(14, ($y + 4))
  $tp = New-Object System.Windows.Forms.TextBox; $tp.SetBounds(150, $y, ($W - 150 - 14 - 110), 26); $tp.ReadOnly = $true
  $bp = New-Button 'BtnChoose' 100 27; $bp.Location = New-Object System.Drawing.Point(($W - 14 - 100), ($y - 1)); $y += 38
  $lu = New-Object System.Windows.Forms.Label; $lu.Text = Get-Text 'VpnUser'; $lu.AutoSize = $true; $lu.Location = New-Object System.Drawing.Point(14, ($y + 4))
  $tu = New-Object System.Windows.Forms.TextBox; $tu.SetBounds(150, $y, 240, 26); $y += 34
  $lw = New-Object System.Windows.Forms.Label; $lw.Text = Get-Text 'VpnPassword'; $lw.AutoSize = $true; $lw.Location = New-Object System.Drawing.Point(14, ($y + 4))
  $tw = New-Object System.Windows.Forms.TextBox; $tw.SetBounds(150, $y, 240, 26); $tw.UseSystemPasswordChar = $true; $y += 34
  $hint = New-Object System.Windows.Forms.Label; $hint.Text = Get-Text 'VpnAuthHint'; $hint.ForeColor = $Theme.Muted
  $hint.MaximumSize = New-Object System.Drawing.Size(($W - 164), 0); $hint.AutoSize = $true; $hint.Location = New-Object System.Drawing.Point(150, $y)
  $y += $hint.GetPreferredSize((New-Object System.Drawing.Size(($W - 164), 0))).Height + 16
  $ok = New-Button 'BtnVpnSend' 120 28; $ok.Location = New-Object System.Drawing.Point(($W - 14 - 120 - 8 - 100), $y)
  $cancel = New-Button 'BtnCancel' 100 28; $cancel.Location = New-Object System.Drawing.Point(($W - 14 - 100), $y); $cancel.DialogResult = 'Cancel'
  $dlg.Controls.AddRange(@($lp, $tp, $bp, $lu, $tu, $lw, $tw, $hint, $ok, $cancel)); $dlg.CancelButton = $cancel; $dlg.AcceptButton = $ok
  $dlg.ClientSize = New-Object System.Drawing.Size($W, ($y + 42))
  $st = @{ Text = '' }
  $bp.add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Title = Get-Text 'VpnChooseTitle'; $ofd.Filter = 'OpenVPN (*.ovpn;*.conf)|*.ovpn;*.conf|*.*|*.*'
    if ($ofd.ShowDialog() -ne 'OK') { return }
    try { $x = [IO.File]::ReadAllText($ofd.FileName) } catch { Show-Message (Get-Text 'VpnTitle' $name) $_.Exception.Message 'Error'; return }
    $why = Test-OvpnProfile $x
    if ($why) { Show-Message (Get-Text 'VpnTitle' $name) (Get-Text 'VpnProfileRefused' $ofd.FileName $why) 'Error'; return }
    $st.Text = $x; $tp.Text = $ofd.FileName
    # a profile with auth-user-pass and no file after it asks for a user and a password
    if ($x -match '(?m)^[ \t]*auth-user-pass[ \t]*\r?$') { $tu.Focus() } })
  $ok.add_Click({
    $u = $tu.Text.Trim()
    if (-not $st.Text -and -not $u) { Show-Message (Get-Text 'VpnTitle' $name) (Get-Text 'VpnNothing'); return }
    if ($u -and ($u -match '[\r\n]' -or $tw.Text -match '[\r\n]' -or -not $tw.Text)) { Show-Message (Get-Text 'VpnTitle' $name) (Get-Text 'VpnErrAuth'); return }
    if ($st.Text -match '(?m)^[ \t]*auth-user-pass[ \t]*\r?$' -and -not $u -and -not (Confirm-Action (Get-Text 'VpnTitle' $name) (Get-Text 'VpnNoAuthConfirm') 'Button2')) { return }
    $dlg.Cursor = 'WaitCursor'
    try { $why = Send-VpnFiles $d $key $st.Text $u $tw.Text } finally { $dlg.Cursor = 'Default' }
    $what = @($(if ($st.Text) { Split-Path -Leaf $tp.Text }), $(if ($u) { Get-Text 'VpnLogAuth' $u }) | Where-Object { $_ }) -join ', '
    if ($why) { Show-Message (Get-Text 'VpnTitle' $name) (Get-Text 'VpnFailed' $why) 'Error'; return }
    Add-ChangeLog (Get-Text 'LogVpnProfile' $name $what)
    Show-Message (Get-Text 'VpnTitle' $name) (Get-Text 'VpnDone' $name) 'Information'
    $dlg.DialogResult = 'OK' })
  [void]$dlg.ShowDialog($form)
  $tw.Text = ''; $st.Text = ''; $dlg.Dispose()
}

# ---------------- 802.1X ----------------
# The client certificate (EAP-TLS) and the PEAP password of a device, over SSH with the key of the vault: secrets of
# the device (in its TPM when it has one), never through the management folder, which every device can read.
function Show-Dot1xDialog($d) {
  $name = $d.Name; $title = Get-Text 'Dot1xTitle' $name
  if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) { Show-Message $title (Get-Text 'ErrRemoteNoSshExe'); return }
  if ($d.S['CFG_SSH'] -ne 'on') { Show-Message $title (Get-Text 'ErrRemoteNoSsh'); return }
  if (-not (Request-VaultOpen)) { return }
  $key = Get-VaultKeyFile
  if (-not $key) { Show-Message $title (Get-Text 'ErrRemoteNoVaultKey'); Select-Page 4; return }
  $dlg = New-Object System.Windows.Forms.Form; Set-WindowIcon $dlg
  $dlg.Text = $title; $dlg.Font = $fontBase; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
  $dlg.StartPosition = 'CenterParent'; $W = 640; $X0 = 190
  $dash = [string][char]0x2014
  $note = New-Object System.Windows.Forms.Label
  $note.Text = (Get-Text 'Dot1xNote') + "`r`n" + (Get-Text 'Dot1xNow' $(if ($d.S['DOT1X']) { $d.S['DOT1X'] } else { $dash }) $(if ($d.S['CFG_WIFI_SECURITY']) { $d.S['CFG_WIFI_SECURITY'] } else { $dash }))
  $note.MaximumSize = New-Object System.Drawing.Size(($W - 28), 0); $note.AutoSize = $true; $note.Location = New-Object System.Drawing.Point(14, 12)
  $dlg.Controls.Add($note); $y = 12 + $note.GetPreferredSize((New-Object System.Drawing.Size(($W - 28), 0))).Height + 14
  $HW = $W - $X0 - 14
  $lc = New-Object System.Windows.Forms.Label; $lc.Text = Get-Text 'Dot1xCert'; $lc.AutoSize = $true; $lc.Location = New-Object System.Drawing.Point(14, ($y + 4))
  $tc = New-Object System.Windows.Forms.TextBox; $tc.SetBounds($X0, $y, ($HW - 110), 26); $tc.ReadOnly = $true
  $bc = New-Button 'BtnChoose' 100 27; $bc.Location = New-Object System.Drawing.Point(($W - 14 - 100), ($y - 1)); $y += 34
  $lk = New-Object System.Windows.Forms.Label; $lk.Text = Get-Text 'Dot1xKey'; $lk.AutoSize = $true; $lk.Location = New-Object System.Drawing.Point(14, ($y + 4))
  $tk = New-Object System.Windows.Forms.TextBox; $tk.SetBounds($X0, $y, ($HW - 110), 26); $tk.ReadOnly = $true
  $bk = New-Button 'BtnChoose' 100 27; $bk.Location = New-Object System.Drawing.Point(($W - 14 - 100), ($y - 1)); $y += 34
  $lw = New-Object System.Windows.Forms.Label; $lw.Text = Get-Text 'Dot1xKeyPassword'; $lw.AutoSize = $true; $lw.Location = New-Object System.Drawing.Point(14, ($y + 4))
  $tw = New-Object System.Windows.Forms.TextBox; $tw.SetBounds($X0, $y, 240, 26); $tw.UseSystemPasswordChar = $true; $y += 30
  $hint = New-Object System.Windows.Forms.Label; $hint.Text = Get-Text 'Dot1xCertHint'; $hint.ForeColor = $Theme.Muted
  $hint.MaximumSize = New-Object System.Drawing.Size($HW, 0); $hint.AutoSize = $true; $hint.Location = New-Object System.Drawing.Point($X0, $y)
  $dlg.Controls.Add($hint); $y += $hint.GetPreferredSize((New-Object System.Drawing.Size($HW, 0))).Height + 14   # measured in the font of the dialog
  $lp = New-Object System.Windows.Forms.Label; $lp.Text = Get-Text 'Dot1xPassword'; $lp.AutoSize = $true; $lp.Location = New-Object System.Drawing.Point(14, ($y + 4))
  $tp = New-Object System.Windows.Forms.TextBox; $tp.SetBounds($X0, $y, 240, 26); $tp.UseSystemPasswordChar = $true; $y += 30
  $hint2 = New-Object System.Windows.Forms.Label; $hint2.Text = Get-Text 'Dot1xPasswordHint'; $hint2.ForeColor = $Theme.Muted
  $hint2.MaximumSize = New-Object System.Drawing.Size($HW, 0); $hint2.AutoSize = $true; $hint2.Location = New-Object System.Drawing.Point($X0, $y)
  $dlg.Controls.Add($hint2); $y += $hint2.GetPreferredSize((New-Object System.Drawing.Size($HW, 0))).Height + 16
  $dlg.Controls.AddRange(@($lc, $tc, $bc, $lk, $tk, $bk, $lw, $tw, $lp, $tp))
  $ok = New-Button 'BtnDot1xSend' 120 28; $ok.Location = New-Object System.Drawing.Point(($W - 14 - 120 - 8 - 100), $y)
  $cancel = New-Button 'BtnCancel' 100 28; $cancel.Location = New-Object System.Drawing.Point(($W - 14 - 100), $y); $cancel.DialogResult = 'Cancel'
  $dlg.Controls.AddRange(@($ok, $cancel)); $dlg.CancelButton = $cancel; $dlg.AcceptButton = $ok
  $dlg.ClientSize = New-Object System.Drawing.Size($W, ($y + 42))
  $bc.add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Title = Get-Text 'Dot1xChooseCert'
    $ofd.Filter = (Get-Text 'Dot1xCertFilter') + ' (*.pfx;*.p12;*.pem;*.crt;*.cer)|*.pfx;*.p12;*.pem;*.crt;*.cer|*.*|*.*'
    if ($ofd.ShowDialog() -eq 'OK') { $tc.Text = $ofd.FileName } })
  $bk.add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Title = Get-Text 'Dot1xChooseKey'; $ofd.Filter = 'PEM (*.key;*.pem)|*.key;*.pem|*.*|*.*'
    if ($ofd.ShowDialog() -eq 'OK') { $tk.Text = $ofd.FileName } })
  $ok.add_Click({
    if (-not $tc.Text -and -not $tp.Text) { Show-Message $title (Get-Text 'Dot1xNothing'); return }
    if ($tp.Text -match '[\r\n]' -or $tp.Text.Length -gt 256) { Show-Message $title (Get-Text 'Dot1xErrPasswordLine'); return }
    $data = $null; $what = @()
    if ($tc.Text) {
      $c = Read-Dot1xClient $tc.Text $tk.Text $tw.Text
      if ($c.Error) { Show-Message $title (Get-Text 'Dot1xRefused' (Split-Path -Leaf $tc.Text) $c.Error) 'Error'; return }
      $info = Get-Text 'Dot1xCertInfo' $c.Subject $c.NotAfter
      if ($c.Warning -and -not (Confirm-Action $title ($info + "`r`n`r`n" + $c.Warning) 'Button2')) { return }
      $data = $c.Data; $what += "$(Split-Path -Leaf $tc.Text) ($($c.Subject))"
    }
    if ($tp.Text) { $what += Get-Text 'Dot1xLogPassword' }
    $dlg.Cursor = 'WaitCursor'
    try { $why = Send-Dot1xFiles $d $key $data $tp.Text } finally { $dlg.Cursor = 'Default' }
    if ($why) { Show-Message $title (Get-Text 'Dot1xFailed' $why) 'Error'; return }
    Add-ChangeLog (Get-Text 'LogDot1x' $name ($what -join ', '))
    Show-Message $title (Get-Text 'Dot1xDone' $name) 'Information'
    $dlg.DialogResult = 'OK' })
  [void]$dlg.ShowDialog($form)
  $tw.Text = ''; $tp.Text = ''; $dlg.Dispose()
}

$btnProbRefresh.add_Click({ Update-ProblemView })
$btnSaveDev.add_Click({ Save-Device })
$btnReloadDev.add_Click({ Update-DeviceGrid })
$btnClearDev.add_Click({ Clear-Device })
$btnSaveCom.add_Click({ Save-Common })
$btnTextDev.add_Click({ if ($script:Selected) { Show-ConfTextDialog $script:Selected } })
$btnTextCom.add_Click({ if ($script:ScopeGroup) { Show-GroupTextDialog $script:ScopeGroup } else { Show-ConfTextDialog $null } })
# Groups: folders of the management folder (config\groups\<group>), each with its settings and the files of its devices
function Show-GroupsDialog {
  $dlg = New-Object System.Windows.Forms.Form; Set-WindowIcon $dlg
  $dlg.Text = Get-Text 'GroupsTitle'; $dlg.Font = $fontBase; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.StartPosition = 'CenterParent'
  $dlg.ClientSize = New-Object System.Drawing.Size(640, 420)
  $hint = New-Object System.Windows.Forms.Label; $hint.Text = Get-Text 'GroupsHint'; $hint.SetBounds(14, 10, 612, 54); $hint.ForeColor = $Theme.Muted
  $lb = New-Object System.Windows.Forms.ListBox; $lb.SetBounds(14, 70, 440, 330); $lb.Font = $fontBase
  $fill = { $lb.Items.Clear(); foreach ($g in (Get-Groups)) { $n = @($script:Devices | Where-Object Group -eq $g).Count; [void]$lb.Items.Add((Get-Text 'GroupsItem' $g $n)) } }
  $name = { if ($lb.SelectedIndex -lt 0) { $null } else { (Get-Groups)[$lb.SelectedIndex] } }
  $mk = { param($k) $b = New-Button $k 160 30; $b.Location = New-Object System.Drawing.Point(466, $script:GrY); $script:GrY += 38; $dlg.Controls.Add($b); $b }
  $script:GrY = 70
  $bNew = & $mk 'GroupsNew'; $bEdit = & $mk 'GroupsEdit'; $bDel = & $mk 'GroupsDelete'; $bClose = & $mk 'BtnClose'; $bClose.DialogResult = 'Cancel'; $dlg.CancelButton = $bClose
  $dlg.Controls.AddRange(@($hint, $lb))
  $bNew.add_Click({ Add-Type -AssemblyName Microsoft.VisualBasic
    $g = [Microsoft.VisualBasic.Interaction]::InputBox((Get-Text 'GroupsNewAsk'), (Get-Text 'GroupsTitle'), '')
    if (-not $g) { return }; try { New-DeviceGroup $g.Trim() } catch { Show-Message (Get-Text 'GroupsTitle') $_.Exception.Message; return }; & $fill })
  $bEdit.add_Click({ $g = & $name; if ($g) { Show-GroupTextDialog $g } })
  $bDel.add_Click({ $g = & $name; if (-not $g) { return }
    if (-not (Confirm-Action (Get-Text 'GroupsTitle') (Get-Text 'GroupsDeleteAsk' $g) 'Button2')) { return }
    try { Remove-DeviceGroup $g } catch { Show-Message (Get-Text 'GroupsTitle') $_.Exception.Message; return }; & $fill })
  & $fill
  try { [void]$dlg.ShowDialog($form) } finally { $dlg.Dispose(); Update-DeviceList }
}
$btnGroupsCom.add_Click({ Show-GroupsDialog })
# a device into a group ('' = the site, no group): its file moves in the share
function Move-ListDevice($d, [string]$g) {
  if (-not $d) { return }
  if ($lblDirtyDev.Visible -and $script:Selected -and $script:Selected.Name -eq $d.Name) { Show-Message (Get-Text 'MsgTextDirtyTitle') (Get-Text 'MsgTextDirty') 'Information'; return }
  if ([string]$d.Group -eq $g) { return }
  try { Move-DeviceToGroup $d.Name $g } catch { Show-Message (Get-Text 'GroupDevTitle' $d.Name) $_.Exception.Message 'Error'; return }
  $barText.Text = Get-Text 'GroupDevDone' $d.Name $(if ($g) { $g } else { Get-SiteName })
  Update-DeviceList; Update-DeviceGrid
}
# right click on the list: a new group, the selected device into a group, the groups
$mnuList = New-Object System.Windows.Forms.ContextMenuStrip; $mnuList.Font = $fontBase
$miNewGroup = $mnuList.Items.Add((Get-Text 'GroupsNew'))
$miMoveTo = New-Object System.Windows.Forms.ToolStripMenuItem((Get-Text 'GroupMoveTo')); [void]$mnuList.Items.Add($miMoveTo)
$miGroups = $mnuList.Items.Add((Get-Text 'GroupsManage'))
$mnuList.add_Opening({
  $miMoveTo.DropDownItems.Clear(); $miMoveTo.Enabled = [bool]$script:Selected
  foreach ($g in @('') + @(Get-Groups)) {
    $mi = $miMoveTo.DropDownItems.Add($(if ($g) { $g } else { Get-SiteName })); $mi.Tag = $g
    if ($script:Selected -and [string]$script:Selected.Group -eq $g) { $mi.Enabled = $false }
    $mi.add_Click({ param($s, $e) Move-ListDevice $script:Selected ([string]$s.Tag) })
  } })
$miNewGroup.add_Click({ Add-Type -AssemblyName Microsoft.VisualBasic
  $g = [Microsoft.VisualBasic.Interaction]::InputBox((Get-Text 'GroupsNewAsk'), (Get-Text 'GroupsTitle'), ''); if (-not $g) { return }
  try { New-DeviceGroup $g.Trim() } catch { Show-Message (Get-Text 'GroupsTitle') $_.Exception.Message; return }
  # the selected device goes in at once: an empty group has no header to drop on
  if ($script:Selected -and (Confirm-Action (Get-Text 'GroupsTitle') (Get-Text 'GroupMoveNew' $script:Selected.Name $g.Trim()))) { Move-ListDevice $script:Selected $g.Trim() } else { Update-DeviceList } })
$miGroups.add_Click({ Show-GroupsDialog })
$list.ContextMenuStrip = $mnuList; $tvDev.ContextMenuStrip = $mnuList
# drag a device onto the site or a group (empty ones too): its file moves in the share
$tvDev.AllowDrop = $true
$tvDev.add_ItemDrag({ param($s, $e) if ($e.Item.Tag -isnot [string]) { [void]$tvDev.DoDragDrop($e.Item, [System.Windows.Forms.DragDropEffects]::Move) } })
$tvDev.add_DragOver({ param($s, $e) $e.Effect = [System.Windows.Forms.DragDropEffects]::Move })
$tvDev.add_DragDrop({ param($s, $e)
  $src = $e.Data.GetData([System.Windows.Forms.TreeNode]); if (-not $src) { return }
  $t = $tvDev.GetNodeAt($tvDev.PointToClient((New-Object System.Drawing.Point($e.X, $e.Y)))); if (-not $t) { return }
  Move-ListDevice $src.Tag $(if ($t.Tag -is [string]) { $t.Tag } else { [string]$t.Tag.Group }) })
# drag a device onto a group: the group of the device under the drop, or of the first one below the header dropped on
$list.AllowDrop = $true
$list.add_ItemDrag({ param($s, $e) [void]$list.DoDragDrop($e.Item, [System.Windows.Forms.DragDropEffects]::Move) })
$list.add_DragOver({ param($s, $e) $e.Effect = [System.Windows.Forms.DragDropEffects]::Move })
$list.add_DragDrop({ param($s, $e)
  $src = $e.Data.GetData([System.Windows.Forms.ListViewItem]); if (-not $src) { return }
  $p = $list.PointToClient((New-Object System.Drawing.Point($e.X, $e.Y)))
  $t = $list.GetItemAt($p.X, $p.Y)
  if (-not $t) { $t = @($list.Items | Where-Object { $_.Bounds.Top -ge $p.Y } | Sort-Object { $_.Bounds.Top }) | Select-Object -First 1 }
  if (-not $t) { $t = @($list.Items | Sort-Object { $_.Bounds.Top }) | Select-Object -Last 1 }
  if ($t -and $t.Group) { Move-ListDevice $src.Tag ([string]$t.Group.Tag) } })
# the group of the selected device: its file moves to that folder of the share
$btnGroupDev.add_Click({
  $d = $script:Selected; if (-not $d) { return }
  if ($lblDirtyDev.Visible) { Show-Message (Get-Text 'MsgTextDirtyTitle') (Get-Text 'MsgTextDirty') 'Information'; return }
  $dlg = New-Object System.Windows.Forms.Form; Set-WindowIcon $dlg
  $dlg.Text = Get-Text 'GroupDevTitle' $d.Name; $dlg.Font = $fontBase; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.StartPosition = 'CenterParent'
  $dlg.ClientSize = New-Object System.Drawing.Size(460, 150)
  $l = New-Object System.Windows.Forms.Label; $l.Text = Get-Text 'GroupDevAsk' $d.Name; $l.SetBounds(14, 12, 432, 40)
  $cb = New-Object System.Windows.Forms.ComboBox; $cb.DropDownStyle = 'DropDownList'; $cb.SetBounds(14, 58, 432, 28)
  $none = Get-Text 'GroupNone'; [void]$cb.Items.Add($none); foreach ($g in (Get-Groups)) { [void]$cb.Items.Add($g) }
  $cb.SelectedItem = $(if ($d.Group -and $cb.Items.Contains($d.Group)) { $d.Group } else { $none })
  $ok = New-Button 'BtnSave' 100 30; $ok.Location = New-Object System.Drawing.Point(238, 106); $ok.DialogResult = 'OK'
  $cancel = New-Button 'BtnCancel' 100 30; $cancel.Location = New-Object System.Drawing.Point(346, 106); $cancel.DialogResult = 'Cancel'
  $dlg.Controls.AddRange(@($l, $cb, $ok, $cancel)); $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
  $r = $dlg.ShowDialog($form); $g = [string]$cb.SelectedItem; $dlg.Dispose()
  if ($r -ne 'OK') { return }
  try { Move-DeviceToGroup $d.Name $(if ($g -eq $none) { '' } else { $g }) } catch { Show-Message (Get-Text 'GroupDevTitle' $d.Name) $_.Exception.Message 'Error'; return }
  $barText.Text = Get-Text 'GroupDevDone' $d.Name $(if ($g -eq $none) { $none } else { $g })
  Update-DeviceList; Update-DeviceGrid })
$btnReloadCom.add_Click({ Update-CommonGrid })
$btnBrandDev.add_Click({ if ($script:Selected) { Show-BrandingDialog $script:Selected } })
$btnRemoteDev.add_Click({ if ($script:Selected) { Start-RemoteScreen $script:Selected } })
$btnVpnDev.add_Click({ if ($script:Selected) { Show-VpnProfileDialog $script:Selected } })
$btnDot1xDev.add_Click({ if ($script:Selected) { Show-Dot1xDialog $script:Selected } })
$btnBrandCom.add_Click({ Show-BrandingDialog $null })
$btnSaveKeys.add_Click({ Save-Keys })
$btnReloadKeys.add_Click({ Update-KeysView })
$btnMyKey.add_Click({ Add-MyKey })
$btnKeyFile.add_Click({ Add-KeyFromFile })
$btnVaultTool.add_Click({ Select-Page 4 })
$btnVaultOpen.add_Click({ Switch-Vault })
$btnVaultCode.add_Click({ if (Show-CodeDialog 'Change' $form) { $barText.Text = Get-Text 'VaultCodeChanged' } })
$btnVaultSshAdd.add_Click({ [void](Add-KeyLine $script:Vault['ssh_public']); Select-Page 2 })
$btnVaultSshNew.add_Click({ New-SshKeyAction })
$btnVaultSshImport.add_Click({ Import-SshKeyDialog })
$btnVaultSign.add_Click({ Invoke-SignDialog })
$btnVaultSignImport.add_Click({ Import-SigningKeyDialog })
$btnVaultSignNew.add_Click({ New-SiteKeyAction })
$btnVaultSignExport.add_Click({ Export-PublicKeyDialog })
$btnVaultSignSend.add_Click({ Send-SiteKeyAction; Update-DeviceList })
# the secrets leave memory and the disk with the window
$form.add_FormClosed({ Close-Vault })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 60000
$timer.add_Tick({ Update-DeviceList })      # the list and the header only: grids being edited are left alone

$form.add_Shown({
  Write-Trace 'shown'
  Set-SplitFit
  Select-Page 0
  Update-DeviceList; Update-CommonGrid; Update-KeysView
  Write-Trace 'devices, common settings, keys'
  # brokers and hosts in the background from the start: the menu shows who cannot sign in, on any page
  if ($script:VdiLoaded) { Start-VdiRefresh; $vdiTimer.Start() } else { $dskOuter.Panel1Collapsed = $true }
  # the infrastructure too: the menu shows its problems on any page
  if ($script:HealthLoaded) { Start-HealthRefresh; $hcTimer.Start() } else { Update-HealthView }
  if ($tvDev.SelectedNode -and $tvDev.SelectedNode.Tag -isnot [string]) { Show-Device $tvDev.SelectedNode.Tag } else { Show-Device $null }
  $timer.Start()
  # the access code at every start: the vault opened, or created the first time (both can be skipped)
  if ($env:OTR_MANAGER_SCREENSHOT) { if ($env:OTR_MANAGER_VAULT_CODE -and (Test-VaultFile)) { [void](Open-Vault $env:OTR_MANAGER_VAULT_CODE) } }
  else { [void](Request-VaultOpen) }
  Update-VaultView
  # a newer manager? In the background: the window does not wait for GitHub (a screenshot only with OTR_MANAGER_RELEASES)
  if (-not $env:OTR_MANAGER_SCREENSHOT -or $env:OTR_MANAGER_RELEASES) { try { Start-ManagerCheck } catch { } }
  # and again every 6 hours: the window stays open all day, a release can come out meanwhile
  if (-not $env:OTR_MANAGER_SCREENSHOT) { $script:MgrTimer = New-Object System.Windows.Forms.Timer; $script:MgrTimer.Interval = 6 * 3600 * 1000; $script:MgrTimer.add_Tick({ try { Start-ManagerCheck } catch { } }); $script:MgrTimer.Start() }
})
if ($env:OTR_MANAGER_HCSET_SHOT) { $form.add_Shown({ Show-HealthSettingsDialog; $form.Close() }) }
# test: the notes window of a release, OTR_MANAGER_NOTES_FROM to OTR_MANAGER_NOTES_TO, drawn into OTR_MANAGER_NOTES_SHOT
if ($env:OTR_MANAGER_NOTES_SHOT -and $env:OTR_MANAGER_NOTES_TO) { $form.add_Shown({ [void](Show-NotesDialog (Get-Text 'RelTitle') (Get-Text 'RelNotesIntro' $env:OTR_MANAGER_NOTES_TO $env:OTR_MANAGER_NOTES_FROM) (Get-ReleaseNotes $env:OTR_MANAGER_NOTES_FROM $env:OTR_MANAGER_NOTES_TO) 'BtnNext'); $form.Close() }) }
if ($env:OTR_MANAGER_BRANDING_SHOT) {   # test: the logo dialog (of OTR_MANAGER_BRANDING_HOST, or common) into a PNG
  $form.add_Shown({ Show-BrandingDialog ($script:Devices | Where-Object Name -eq $env:OTR_MANAGER_BRANDING_HOST | Select-Object -First 1); $form.Close() })
}
if ($env:OTR_MANAGER_SCREENSHOT) {   # test: draws the window into a PNG instead of leaving it open
  # OTR_MANAGER_TAB = page (0 devices, 1 common, 2 keys, 3 history, 4 vault, 5 updates, 6 desktops, 7 health center), OTR_MANAGER_DETAIL = tab of the selected device,
  # OTR_MANAGER_DEVICE = the device to select, OTR_MANAGER_ROW = the setting whose help shows
  # an error must close the window and be reported: nobody is there to close it
  $form.add_Shown({ try {
    # OTR_MANAGER_DEVICE = the device to select: its node in the tree (the key of a node is the name of its device)
    if ($env:OTR_MANAGER_DEVICE -and -not $env:OTR_MANAGER_TREE) { $env:OTR_MANAGER_TREE = $env:OTR_MANAGER_DEVICE }
    # OTR_MANAGER_TREE = a node of the device tree to select: site, or g:<group>
    if ($env:OTR_MANAGER_TREE) { $tn = @($tvDev.Nodes.Find($env:OTR_MANAGER_TREE, $true)) | Select-Object -First 1; if ($tn) { $tvDev.SelectedNode = $tn; Show-TreeNode $tn } }
    # the servers read in the background (without OTR_MANAGER_VDI_DEMO): waited for, at most 120 s
    if ($script:VdiLoaded) { $t0 = Get-Date
      # and the automatic repairs of the Health Center (in repair mode), with the reading that follows them
      while (($script:Vdi.Busy -or ($script:HealthLoaded -and ($script:Health.Busy -or $script:Health.Action -or $script:Health.Queue.Count))) -and ((Get-Date) - $t0).TotalSeconds -lt 240) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 } }
    if ($env:OTR_MANAGER_TAB) { Select-Page ([int]$env:OTR_MANAGER_TAB) }
    # OTR_MANAGER_VDI_ROW = the user (or device) to select on the Desktops page
    if ($env:OTR_MANAGER_VDI_ROW) { foreach ($it in $dskList.Items) { if ($it.Text -eq $env:OTR_MANAGER_VDI_ROW -or ($it.Tag.Device -and $it.Tag.Device.Name -eq $env:OTR_MANAGER_VDI_ROW)) { $it.Selected = $true; break } } }
    # OTR_MANAGER_HEALTH_ITEM = the item to select in the Health Center (its id: host:HV1, vm:VM-ALICE, dc:DC1...)
    if ($env:OTR_MANAGER_HEALTH_ITEM -and $script:HealthLoaded) { $tn = @($tvHc.Nodes.Find($env:OTR_MANAGER_HEALTH_ITEM, $true)) | Select-Object -First 1; if ($tn) { $tvHc.SelectedNode = $tn; $tn.EnsureVisible() } }
    if ($env:OTR_MANAGER_DETAIL) { $detail.SelectedIndex = [int]$env:OTR_MANAGER_DETAIL }
    if ($env:OTR_MANAGER_ROW) {
      $g = if ($script:Page -eq 1) { $gridCom } else { $gridDev }
      foreach ($r in $g.Rows) { if ($r.Tag -and $r.Tag.Key -eq $env:OTR_MANAGER_ROW) { $g.CurrentCell = $r.Cells[0]; break } }
    }
    # Windows clamps a window to the screen: the contents are drawn at the intended size instead (child controls
    # are not clamped), without the title bar
    # OTR_MANAGER_SIZE = <width>x<height> (default 1440x840): the window at another size, to check how it fits
    # with OTR_MANAGER_RELEASES the check of a newer manager is waited for (at most 20 s): its notice is drawn too
    if ($env:OTR_MANAGER_RELEASES) { $t0 = Get-Date
      while ($script:ManagerChecking -and ((Get-Date) - $t0).TotalSeconds -lt 20) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 } }
    $w = 1440; $h = 840
    if ($env:OTR_MANAGER_SIZE -match '^(\d{3,4})x(\d{3,4})$') { $w = [int]$Matches[1]; $h = [int]$Matches[2] }
    $root.Dock = 'None'; $root.SetBounds(0, 0, $w, $h)
    Set-SplitFit; $form.Refresh(); [System.Windows.Forms.Application]::DoEvents()
    if ($script:VdiLoaded) { Set-VdiBrokFit; Set-DskSplitFit; if ($dskList.SelectedItems.Count) { $dskList.SelectedItems[0].EnsureVisible() }; $form.Refresh(); [System.Windows.Forms.Application]::DoEvents() }
    if ($script:HealthLoaded -and $script:Page -eq 7) { Set-HcSplitFit; Set-HcInnerFit; if ($tvHc.SelectedNode) { $tvHc.SelectedNode.EnsureVisible() }; $form.Refresh(); [System.Windows.Forms.Application]::DoEvents() }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $root.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $w, $h)))
    $bmp.Save($env:OTR_MANAGER_SCREENSHOT, [System.Drawing.Imaging.ImageFormat]::Png)
  } catch { [Console]::Error.WriteLine("screenshot failed: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))") } finally { $form.Close() } })
}
Write-Trace 'window built'
[void]$form.ShowDialog()
