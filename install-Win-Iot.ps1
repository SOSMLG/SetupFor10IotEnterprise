<#
.SYNOPSIS
  My Win10/Win11 IoT (Enterprise) LTSC setup. Unattended, rerunnable.
.DESCRIPTION
  Built for a tiny10 box with no store and usually no network
  on first boot. PS 5.1, Komorebi + whkd, Helium, VSCodium, stock taskbar.
  No terminal, no extra shells. Stock colors everywhere.
  Engines per app, first hit wins: staged -OfflineDir files, winget,
  choco, github releases. Log lands in C:\Windows\Logs\Win-Iot-Setup either way.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install-Win-Iot.ps1
  powershell -ExecutionPolicy Bypass -File install-Win-Iot.ps1 -Unattended -OfflineDir D:\Offline
  powershell -ExecutionPolicy Bypass -File install-Win-Iot.ps1 -Unattended -DriverDir D:\Drivers -Reboot
  powershell -ExecutionPolicy Bypass -File install-Win-Iot.ps1 -IncludeOptional -Unattended
  powershell -ExecutionPolicy Bypass -File install-Win-Iot.ps1 -TweaksOnly
  (tweaks-only: just the tweaks on any live machine. no apps, no configs, no debloat.)
  powershell -ExecutionPolicy Bypass -File install-Win-Iot.ps1 -ConfigsOnly
  (configs-only: re-copy user configs to their real locations, nothing else.)
#>
[CmdletBinding()]
param(
  [switch]$AdGuard,
  [switch]$NextDNS,
  [switch]$DNSAuto = $true,
  [switch]$SkipHashVerify,
  [switch]$SkipTemplateGen,
  [switch]$Idempotent,
  [switch]$Force,
  [string]$StateDir = 'C:\Windows\Logs\Win-Iot-Setup\state',
  [string]$BuildConfig = '',
  [string]$Arch = '',
  [switch]$DetectHardware,
  [switch]$IncludeOptional,
  [switch]$Unattended,
  [switch]$NoWingetBootstrap,
  [switch]$NoChocoBootstrap,
  [string]$OfflineDir = '',
  [string]$LogDir = 'C:\Windows\Logs\Win-Iot-Setup',
  [string]$DriverDir = '',
  [string]$Dns = 'Auto',
  [switch]$NoTweaks,
  [switch]$NoDebloat,
  [switch]$TweaksOnly,
  [switch]$ConfigsOnly,
  [switch]$Reboot,
  [switch]$Fixes,
  [switch]$GamingTweaks,
  [switch]$ExtraPrivacy,
  [switch]$KeepFastStartup,
  [switch]$DnsOffByDefault,
  [switch]$NoBackup,
  [switch]$SkipOOSU
)
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = Split-Path $MyInvocation.MyCommand.Path -Parent
# -ConfigsOnly re-deploys user configs (VSCodium, Vesktop, qBittorrent, opencode,
# komorebi, ...) and nothing else. tweaks are forced off; install phases are gated below.
if ($ConfigsOnly) { $NoTweaks = $true }
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
# C:\Windows\Logs needs admin. non-admin runs fall back to TEMP instead of dying.
try { New-Item -ItemType Directory -Force -Path $LogDir -EA Stop | Out-Null }
catch { $LogDir = Join-Path $env:TEMP 'Win-Iot-Setup'; New-Item -ItemType Directory -Force -Path $LogDir -EA SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "install-$Stamp.log"
$transcriptOn = $false
try { Start-Transcript -Path $LogFile -Force -EA Stop | Out-Null; $transcriptOn = $true } catch {}
function Log($m) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) }
function Refresh-Path {
  # fresh installs don't land on PATH in this session. re-read it or python/codium are "missing".
  try { $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User') } catch {}
}

# ---------- phase 0. helpers: module load, state, OS + hw detect, templates ----------
# dot-source our lib modules if present. they carry the new universal-upgrade
# plumbing, but every call below still guards on a missing module, so a bare
# repo (lib/ absent) keeps working exactly as before.
$LibDir = Join-Path $Repo 'lib'
$loadedModules = @()
if (Test-Path $LibDir) {
  foreach ($m in @('Logging','Utils','Registry','OSInfo','Network','Security','Template','Config','TweakMatrix')) {
    $mp = Join-Path $LibDir "$m.psm1"
    if (Test-Path $mp) {
      try { Import-Module $mp -Force -ErrorAction Stop -DisableNameChecking; $loadedModules += $m }
      catch { Log "WARN module $m`: $($_.Exception.Message)" }
    }
  }
  if ($loadedModules.Count) { Log ('  lib modules: ' + ($loadedModules -join ', ')) }
}
# idempotency: one small json per phase under StateDir. a completed phase is
# skipped on re-run unless -Force. a missing state file is never fatal.
function Get-PhaseState {
  if (-not (Test-Path $StateDir)) { return @{} }
  $sf = Join-Path $StateDir 'phases.json'
  if (-not (Test-Path $sf)) { return @{} }
  try { return (Get-Content $sf -Raw | ConvertFrom-Json) } catch { return @{} }
}
function Set-PhaseDone($name) {
  try {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir -EA Stop | Out-Null }
    $sf = Join-Path $StateDir 'phases.json'
    $data = @{}
    if (Test-Path $sf) {
      try { $obj = Get-Content $sf -Raw | ConvertFrom-Json; foreach ($p in $obj.PSObject.Properties) { $data[$p.Name] = $p.Value } } catch {}
    }
    $data[$name] = (Get-Date).ToString('o')
    ($data | ConvertTo-Json) | Set-Content -Path $sf -Encoding UTF8 -EA Stop
  } catch { Log "  WARN state write $name`: $_" }
}
function Test-PhaseDone($name) {
  if ($Force) { return $false }
  $st = Get-PhaseState
  if ($st -and ($st.PSObject.Properties.Name -contains $name)) { return $true }
  return $false
}
# idempotency is opt-in (-Idempotent). without it every phase runs like before.
function Should-Run($phase) {
  if (-not $Idempotent) { return $true }
  if (Test-PhaseDone $phase) { Log "  skip (done): $phase"; return $false }
  return $true
}
function Complete-Phase($phase) {
  if ($Idempotent) { Set-PhaseDone $phase }
}

# optional sha256 check for downloaded installers. config/hashes.json maps an
# asset name (or glob) to a hex sha256. empty/missing config = nothing checked,
# downloads proceed as before. a mismatch tosses the file so retry re-downloads.
function Get-ExpectedHash($name) {
  if (-not $name) { return $null }
  $hf = Join-Path $Repo 'config\hashes.json'
  if (-not (Test-Path $hf)) { return $null }
  try {
    $map = Get-Content $hf -Raw | ConvertFrom-Json
    foreach ($p in $map.PSObject.Properties) {
      if ($name -like $p.Name) { return [string]$p.Value }
    }
  } catch {}
  return $null
}
function Test-DownloadHash($file) {
  if ($SkipHashVerify) { return $true }
  $exp = Get-ExpectedHash (Split-Path $file.FullName -Leaf)
  if (-not $exp) { return $true }
  try {
    $actual = (Get-FileHash -Algorithm SHA256 -Path $file.FullName -EA Stop).Hash
    if ($actual.ToUpper() -eq $exp.ToUpper()) { Log "  hash ok: $($file.Name)"; return $true }
    Log "  WARN hash MISMATCH $($file.Name): got $actual want $exp - tossing."
    Remove-Item $file.FullName -Force -EA SilentlyContinue
    return $false
  } catch { Log "  WARN hash check $($file.Name): $_"; return $true }
}
# native exes don't throw, and Start-Process never sets $LASTEXITCODE at all
# (verified: stale code survives it). everything native goes through here.
# returns the real exit code, -1 if it never even launched.
function Invoke-Native {
  param(
    [scriptblock]$cmd,
    [object[]]$Args
  )
  $LASTEXITCODE = 0
  $oldEA = $ErrorActionPreference; $ErrorActionPreference = 'Stop'
  try {
    if ($PSBoundParameters.ContainsKey('Args') -and $null -ne $Args) { & $cmd @Args 2>&1 | Out-Null }
    else { & $cmd 2>&1 | Out-Null }
    return $LASTEXITCODE
  }
  catch { return -1 }
  finally { $ErrorActionPreference = $oldEA }
}
# one-shot task from FirstBoot already fired. remove it so it never refires.
try { Unregister-ScheduledTask -TaskName 'Win-Iot-Setup' -Confirm:$false -EA Stop } catch {}

function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
$isAdmin = Test-Admin
if (-not $isAdmin) { Log 'WARN: not admin. fonts and autostart will probably fail.' }

# os + hardware. keeps edition/ltsc/arch detect + optional hw gate.
try {
  $b = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
  Log "OS build: $b"
  $osInfo = $null
  if (Get-Command Get-OSInfo -EA SilentlyContinue) { $osInfo = Get-OSInfo }
  if ($osInfo) {
    Log ("OS: {0} {1} ({2}) arch={3}" -f $osInfo.ProductName, $osInfo.Version, $osInfo.Build, $osInfo.Architecture)
    $family = if ($osInfo.IsWin11) { 'Win11' } else { 'Win10' }
    # name the ltsc family plainly so a 10 box and an 11 box both read right.
    if ($osInfo.IsWin10LTSC -or $osInfo.IsWin11LTSC) { Log "  $family LTSC/IoT detected ($($osInfo.Build))." }
    elseif ($osInfo.IsLTSC -or $osInfo.IsIoT) { Log "  LTSC/IoT edition detected ($family $($osInfo.Build))." }
    else { Log "  WARN: not an LTSC/IoT edition ($family $($osInfo.Build)). going ahead anyway." }
    # tweaks are one set for both 10 and 11 ltsc. win11-only extras are not applied.
    if ($osInfo.IsWin11) { Log '  note: same tweak set as win10; win11-only extras are not applied.' }
  }
  # known ltsc builds: 17763 = win10 iot ltsc 2019, 19044 = win10 iot ltsc 2021,
  # 26100 = win11 (iot) enterprise ltsc 2024. anything else, warn + keep going.
  $knownLtsc = @('17763', '19044', '26100')
  if ($osInfo -and ($osInfo.IsLTSC -or $osInfo.IsIoT) -and ($knownLtsc -notcontains [string]$b)) { Log "WARN: LTSC build $b not in known list. going ahead anyway, watch the log." }
} catch { Log "WARN: OS check failed: $_" }

# arch gate: this repo assumes x64. warn loudly if someone runs it on arm32.
if ($env:PROCESSOR_ARCHITECTURE -and $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
  Log "WARN: PROCESSOR_ARCHITECTURE=$env:PROCESSOR_ARCHITECTURE, repo is x64-only. downloads may not match."
}
if ($Arch -and $Arch -ne 'x64' -and $Arch -ne 'amd64') { Log "WARN: -Arch $Arch given, x64 is the only tested target." }

# optional hardware sanity. never blocks, just reports so you know before a 20 min run.
if ($DetectHardware -and (Get-Command Test-HardwareMin -EA SilentlyContinue)) {
  $hw = Test-HardwareMin
  if ($hw.OK) { Log ("Hardware: {0} / {1} GB RAM" -f $hw.CPU, $hw.MemoryGB) }
  else { Log 'WARN: hardware detection failed (wmi gutted?).' }
}

# ---------- phase 0b. template-generated answer file (build-time parity) ----------
# templates/autounattend.xml.tpl is the source of truth now. if it exists and
# -SkipTemplateGen was not passed, render ISO/autounattend.xml from it so the
# repo copy can never drift from the template. ventoy copy stays a manual mirror.
if ((-not $SkipTemplateGen) -and (-not $TweaksOnly) -and (-not $ConfigsOnly) -and (-not $Unattended)) {
  $tpl = Join-Path $Repo 'templates\autounattend.xml.tpl'
  if (Test-Path $tpl) {
    try {
      $cfg = $null
      $cfgPath = Join-Path $Repo 'templates\build-config.json'
      if (Test-Path $cfgPath) { $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json }
      $userName = if ($cfg -and $cfg.username) { $cfg.username } else { 'My Pc' }
      $arch = if ($Arch) { $Arch } elseif ($cfg -and $cfg.arch) { $cfg.arch } else { 'amd64' }
      $inLoc = if ($cfg -and $cfg.locales.input) { $cfg.locales.input } else { '0409:00000409' }
      $sysLoc = if ($cfg -and $cfg.locales.system) { $cfg.locales.system } else { 'en-US' }
      $uiLoc = if ($cfg -and $cfg.locales.ui) { $cfg.locales.ui } else { 'en-US' }
      $userLoc = if ($cfg -and $cfg.locales.user) { $cfg.locales.user } else { 'en-001' }
      $body = Get-Content $tpl -Raw
      $body = $body.Replace('{{ARCH}}', $arch).Replace('{{USERNAME}}', $userName).Replace('{{INPUT_LOCALE}}', $inLoc).Replace('{{SYSTEM_LOCALE}}', $sysLoc).Replace('{{UILANGUAGE}}', $uiLoc).Replace('{{USERLOCALE}}', $userLoc)
      $outXml = Join-Path $Repo 'ISO\autounattend.xml'
      $existing = if (Test-Path $outXml) { Get-Content $outXml -Raw } else { '' }
      if ($body -ne $existing) {
        if (Test-Path (Split-Path $outXml)) { Set-Content -Path $outXml -Value $body -Encoding UTF8 -EA Stop; Log '  autounattend.xml regenerated from template.' }
      } else { Log '  autounattend.xml already matches template.' }
    } catch { Log "  WARN template gen: $_" }
  }
}

if (-not $Unattended) {
  try { Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -EA SilentlyContinue } catch {}
}

# no net + no OfflineDir means nothing to install. say so now, not 20 min in.
$online = $false
try { $online = Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -EA Stop } catch {}
if (-not $online -and -not $OfflineDir) {
  Log 'WARN: no network detected and no -OfflineDir given.'
  Log '  plug phone in for usb tethering, or seed ISO/Offline via Get-Offline.ps1 on an online PC'
  Log "  and re-run with: -OfflineDir '<path-to-Offline>' -Unattended"
}
if (-not $online) { Log 'OFFLINE mode: online engines skipped; pre-seeded files still apply.' }

# fresh boot almost never has DHCP yet. usb tethering takes a few min to enable,
# so wait up to 10 min or winget dies for no reason.
# tweaks need no net, so tweaks-only skips the wait entirely.
if ((-not $online) -and (-not $TweaksOnly) -and (-not $ConfigsOnly)) {
  $waited = 0
  while (-not $online -and $waited -lt 600) {
    Start-Sleep -Seconds 15; $waited += 15
    try { $online = Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -EA Stop } catch {}
  }
  if ($online) { Log "network up after ${waited}s." }
  else { Log 'WARN: still offline after 10 min - continuing with pre-seeded files only.' }
}

# ---------- 0. repairs. opt-in only (-Fixes), runs before everything. ----------
if ($Fixes) {
  Log 'Repairs...'
  $exit = Invoke-Native { ipconfig /flushdns }
  if ($exit -eq 0) { Log '  dns cache flushed.' } else { Log "  WARN flushdns exit=$exit" }
  try {
    foreach ($svc in @('Dnscache','NlaSvc')) {
      if (Get-Service $svc -EA SilentlyContinue) { Restart-Service $svc -Force -EA Stop; Log "  svc restarted: $svc" }
    }
  } catch { Log "  WARN net services: $_" }
  $exit = Invoke-Native { netsh winsock reset }
  if ($exit -eq 0) { Log '  winsock reset (needs the reboot at the end).' } else { Log "  WARN winsock exit=$exit" }
  if ($isAdmin) {
    # update stack reset. stops services, parks the caches aside, starts over.
    try {
      foreach ($svc in @('wuauserv','bits','cryptsvc')) { Stop-Service $svc -Force -EA SilentlyContinue }
      foreach ($d in @('C:\Windows\SoftwareDistribution','C:\Windows\System32\catroot2')) {
        if ((Test-Path $d) -and -not (Test-Path "$d.bak")) { Rename-Item $d "$d.bak" -Force -EA Stop; Log "  parked: $d" }
      }
      foreach ($svc in @('cryptsvc','bits','wuauserv')) { Start-Service $svc -EA SilentlyContinue }
      Log '  update stack reset.'
    } catch { Log "  WARN update reset: $_" }
  } else { Log '  update reset needs admin. skipped.' }
  Complete-Phase 'repairs'
}

# ---------- 1. sane defaults first. hardening lands before gigabytes of downloads. ----------
# win10 updates come as one blob, no security-only split exists.
# LTSC + "tell me first" + no surprise reboots + no driver pushes. good enough.
function Set-Reg($path, $name, $value, $type = 'DWord') {
  try {
    # HKU: drive never exists by default. mount it once or the .DEFAULT key dies.
    if ($path -like 'HKU:*' -and -not (Get-PSDrive HKU -EA SilentlyContinue)) {
      New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -EA Stop | Out-Null
    }
    if (-not (Test-Path $path)) { New-Item -Path $path -Force -EA Stop | Out-Null }
    New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $type -Force -EA Stop | Out-Null
  } catch { Log "  WARN reg ${path}\${name}: $_" }
}
# dns providers. dhcp hands the address, -Dns picks who answers. Auto/DHCP = leave it alone.
# AdGuard + NextDNS are the filtering resolvers, opt-in via -AdGuard / -NextDNS.
$dnsMap = @{
  'Cloudflare' = @('1.1.1.1','1.0.0.1')
  'Google' = @('8.8.8.8','8.8.4.4')
  'Quad9' = @('9.9.9.9','149.112.112.112')
  'AdGuard' = @('94.140.14.14','94.140.15.15')
  'AdGuardFamily' = @('94.140.14.15','94.140.15.16')
  'NextDNS' = @('45.90.28.0','45.90.30.0')
  'Auto' = @()
  'DHCP' = @()
}
# explicit adblock switches win over -Dns, since they name a specific resolver.
if ($AdGuard) { $Dns = 'AdGuard' }
if ($NextDNS) { $Dns = 'NextDNS' }
if ($DNSAuto -and -not $AdGuard -and -not $NextDNS -and -not $PSBoundParameters.ContainsKey('Dns')) { $Dns = 'Auto' }
if ((-not $NoTweaks) -and (Should-Run 'tweaks')) {
  Log 'Sane defaults...'
  if ($isAdmin -and -not $NoBackup) {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $regbak = Join-Path $LogDir "RegBackups-$stamp"
    try {
      New-Item -ItemType Directory -Force -Path $regbak -EA Stop | Out-Null
      $exports = @(
        'HKLM\SOFTWARE\Policies',
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies',
        'HKLM\SYSTEM\CurrentControlSet\Control\Lsa'
      )
      foreach ($r in $exports) {
        $out = Join-Path $regbak ($r -replace '\\','_').Replace(':','').ToLower() + '.reg'
        $null = Invoke-Native { param($root,$f); reg export $root $f /y } -Args $r,$out
      }
      $hkcuOut = Join-Path $regbak 'hkcu_software_policies.reg'
      $null = Invoke-Native { param($f); reg export 'HKCU\SOFTWARE\Policies' $f /y } -Args $hkcuOut
      Log "Reg-backup: $regbak"
    } catch {
      Log "WARN reg-backup failed: $_"
    }
  } elseif ($isAdmin -and $NoBackup) {
    Log 'Reg-backup skipped (-NoBackup).'
  }
  if ($isAdmin) {
    # restore point first. tiny10 usually ripped system restore out, so don't hold your breath.
    if (-not $NoBackup) {
      try { Checkpoint-Computer -Description 'Win-Iot-Setup pre-tweaks' -RestorePointType MODIFY_SETTINGS -EA Stop; Log '  restore point created.' }
      catch { Log '  WARN restore point: unavailable (common on tiny10) - continuing.' }
    } else {
      Log '  restore point skipped (-NoBackup).'
    }
    # O&O ShutUp10++ next, our reg values after, so ours win any overlap.
    if (-not $SkipOOSU) {
      try {
        $oosu = Join-Path $Repo 'OOSU\OOSHUTUP10.exe'
        $oocfg = Join-Path $Repo 'OOSU\ooshutup10.cfg'
        if ((Test-Path $oosu) -and (Test-Path $oocfg)) {
          Log '  O&O ShutUp10++ applying cfg...'
          $proc = Start-Process -FilePath $oosu -ArgumentList '/quiet','/cfg',$oocfg -Wait -PassThru
          if ($proc.ExitCode -eq 0) { Log '  O&O applied.' } else { Log "  WARN O&O exit=$($proc.ExitCode)" }
        } else { Log '  O&O skipped (exe/cfg missing from OOSU/).' }
      } catch { Log "  WARN O&O: $_" }
    } else {
      Log '  O&O ShutUp10++ skipped (-SkipOOSU).'
    }
    # 0 means security-level. only enterprise SKUs honor it, and this is one.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
    foreach ($svc in @('DiagTrack','dmwappushservice')) {
      try { Stop-Service $svc -Force -EA SilentlyContinue; Set-Service $svc -StartupType Disabled -EA Stop; Log "  svc disabled: $svc" }
      catch { Log "  WARN svc ${svc}: $_" }
    }
    # titus sets these to manual. only touching ones that exist and don't matter.
    foreach ($svc in @('MapsBroker','lfsvc','XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc','RetailDemo','WalletService','wisvc','CDPSvc')) {
      try {
        if (Get-Service $svc -EA SilentlyContinue) { Set-Service $svc -StartupType Manual -EA Stop; Log "  svc manual: $svc" }
      } catch { Log "  WARN svc ${svc}: $_" }
    }
    # bluescreens say what actually broke. two keys, zero cost.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' 'DisplayParameters' 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' 'DisableEmoticon' 1
    # svchost split matched to ram. fewer idle processes hanging around.
    try {
      $memKB = (Get-CimInstance Win32_PhysicalMemory -EA Stop | Measure-Object Capacity -Sum).Sum / 1KB
      Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'SvcHostSplitThresholdInKB' -Value ([uint32]$memKB) -EA Stop
      Log '  svchost split matched to ram.'
    } catch { Log "  WARN svchost split: $_" }
    # tell-me-first updates, no reboot while logged in, and windows keeps its hands off my drivers.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions' 2
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1
    # machine-side privacy.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
    # recently-added group gone from start. the a-z list stays, the noise goes.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'HideRecentlyAddedApps' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun' 255
    # verbose boot messages + numlock on at login. admin-only keys, live with the rest up here.
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'VerboseStatus' 1
    Set-Reg 'HKU:\.DEFAULT\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' 'String'
    # no peer-to-peer update uploads on lab and metered nets.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
    # block silent auto-encryption. the service itself stays, untouched.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' 'PreventDeviceEncryption' 1
    # location tracking off
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocation' 1
    # news+interests dies at policy level too, not just the taskbar toggle below.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0
    # no lock screen swipe. straight to logon, faster unlocks.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' 'NoLockScreen' 1
    # usb selective suspend off. stops ch340/cp210x serial drops on the bench.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\USB' 'DisableSelectiveSuspend' 1
    # WPBT lets vendor blobs run at boot. off.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'DisableWpbtExecution' 1
    # teredo off. xbox tunneling only, pure attack surface otherwise.
    $exit = Invoke-Native { netsh interface teredo set state disabled }
    if ($exit -eq 0) { Log '  teredo off.' } else { Log "  WARN teredo exit=$exit" }
    # clock reads RTC as UTC. dual-boot friendly, linux does the same.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' 'RealTimeIsUniversal' 1
    # clock may be off after the rtc flip. sync once when online, warn and move on.
    if ($online) {
      $exit = Invoke-Native { w32tm /resync }
      if ($exit -eq 0) { Log '  clock synced.' } else { Log "  WARN clock sync exit=$exit (syncs on its own later)" }
    }
    # ultimate plan if the sku carries it, high performance otherwise. tiny10 parks on balanced.
    $exit = Invoke-Native { powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 }
    if ($exit -eq 0) { $exit = Invoke-Native { powercfg /setactive e9a42b02-d5df-448d-aa00-03f14749eb61 } }
    if ($exit -eq 0) { Log '  power: ultimate performance.' }
    else {
      $exit = Invoke-Native { powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635ec }
      if ($exit -eq 0) { Log '  power: high performance.' } else { Log "  WARN power plan exit=$exit" }
    }
    # reserved storage off. small disks need those gigs back.
    try { Set-WindowsReservedStorageState -State Disabled -EA Stop; Log '  reserved storage off.' }
    catch { Log "  WARN reserved storage: $_" }
    # IPv4 preferred, IPv6 stays alive. full disable breaks things, this doesn't.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents' 32
    # resolver from -Dns on every live adapter. Auto/DHCP resets to dhcp-supplied.
    try {
      if ($DnsOffByDefault -and -not $PSBoundParameters.ContainsKey('Dns')) {
        Log '  DNS not changed (-DnsOffByDefault and no -Dns specified).'
      } else {
        $servers = $null
        # Auto probes resolvers and picks the fastest reachable one. offline or
        # module absent falls through to a plain DHCP reset just below.
        if ($Dns -eq 'Auto' -and (Get-Command Resolve-DnsBest -EA SilentlyContinue)) {
          $resolved = Resolve-DnsBest
          if ($resolved) {
            $Dns = $resolved.Provider
            $servers = $resolved.Servers
            Log ("  DNS auto: $($resolved.Provider) ($($resolved.LatencyMs)ms)")
          }
        }
        if (-not $servers -and $dnsMap.ContainsKey($Dns)) { $servers = $dnsMap[$Dns] }
        if ($Dns -eq 'Auto' -or $Dns -eq 'DHCP' -or -not $servers -or $servers.Count -eq 0) {
          $adapters = Get-NetAdapter -Physical -EA Stop | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notlike '*Virtual*' }
          foreach ($a in $adapters) { Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ResetServerAddresses -EA SilentlyContinue }
          Log "  DNS: reset to automatic (DHCP)."
        } else {
          Get-NetAdapter -Physical -EA Stop | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notlike '*Virtual*' } | ForEach-Object {
            Set-DnsClientServerAddress -InterfaceIndex $_.InterfaceIndex -ServerAddresses $servers -EA Stop
          }
          Log "  DNS: $Dns on live adapters."
        }
      }
    } catch { Log "  WARN DNS: $_" }
    # notification center gone (toasts die per-user below).
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableNotificationCenter' 1
    # hardening. lan-spoofing + credential hygiene. lab-safe: bench gear talks
    # tcp/serial directly, none of it needs smb1, llmnr, netbios or wpad.
    # smb1 off. 90s protocol, ransomware's favorite door.
    try {
      $smb = Get-WindowsOptionalFeature -Online -FeatureName 'SMB1Protocol' -EA Stop
      if ($smb -and $smb.State -ne 'Disabled') { Disable-WindowsOptionalFeature -Online -FeatureName 'SMB1Protocol' -NoRestart -EA Stop | Out-Null; Log '  SMB1 removed.' }
      else { Log '  SMB1 already gone.' }
    } catch { Log "  WARN SMB1: $_" }
    # llmnr off. poisoned answers on lab lans start here.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast' 0
    # netbios off per live adapter. same reason, older protocol.
    try {
      Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "IPEnabled='TRUE'" -EA Stop | ForEach-Object {
        $r = $_.SetTcpipNetbios(2)
        if ($r.ReturnValue -in @(0,1)) { Log "  netbios off: $($_.Description)" }
        else { Log "  WARN netbios $($_.Description): ret=$($r.ReturnValue)" }
      }
    } catch { Log "  WARN netbios: $_" }
    # anonymous sam enumeration off. default on win10, stated plainly.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RestrictAnonymous' 1
    # remote assistance off. nobody helps this box remotely.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' 'fAllowToGetHelp' 0
    # lsass runs protected. mimikatz-class tools bounce off.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL' 1
    # wdigest cleartext creds off. normal logons don't need it.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' 'UseLogonCredential' 0
    # guest account stays off.
    try {
      $g = Get-LocalUser -Name 'Guest' -EA Stop
      if ($g.Enabled) { Disable-LocalUser -Name 'Guest' -EA Stop; Log '  guest disabled.' }
      else { Log '  guest already off.' }
    } catch { Log "  WARN guest: $_" }
    # firewall on, all profiles. we never punch holes, so nothing breaks.
    try { Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True -EA Stop; Log '  firewall on (all profiles).' }
    catch { Log "  WARN firewall: $_" }
    # defender realtime on if the trim kept it. enabling only, never disabling.
    try {
      if (Get-Command Get-MpComputerStatus -EA SilentlyContinue) {
        Set-MpPreference -DisableRealtimeMonitoring $false -EA Stop; Log '  defender realtime on.'
      } else { Log '  defender absent on this trim. skipped.' }
    } catch { Log "  WARN defender: $_" }
    # defender skips the lab folders that exist. less rescanning big toolchains.
    # more later by hand: Add-MpPreference -ExclusionPath <dir>.
    try {
      if (Get-Command Add-MpPreference -EA SilentlyContinue) {
        foreach ($ex in @('C:\Setup', "$env:ProgramFiles\MATLAB")) {
          if (Test-Path $ex) { Add-MpPreference -ExclusionPath $ex -EA Stop; Log "  defender exclusion: $ex" }
        }
      }
    } catch { Log "  WARN defender exclusions: $_" }
    if ($GamingTweaks) {
      Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 0
      Log '  GamingTweaks applied (safe).'
    }
    if ($KeepFastStartup) {
      Log '  KeepFastStartup requested (no forced hibernate changes).'
    }
  } else { Log '  machine tweaks need admin. skipped.' }
  # per-user stuff, no admin needed.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0
  # occasional start suggestions off. the win10 name for the same toggle.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSyncProviderNotifications' 0
  Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
  if ($GamingTweaks) {
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\GameBar' 'AllowAutoGameMode' 1 -Type 'DWord'
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\GameBar' 'AutoGameModeEnabled' 1 -Type 'DWord'
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0 -Type 'DWord'
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 -Type 'DWord'
  }
  # feeds = win10's widgets. off.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Feeds' 'ShellFeedsTaskbarViewMode' 2
  # store suggestions. does nothing on tiny10, costs nothing. leave it.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'DisableSearchBoxSuggestions' 1
  # stop explorer from re-guessing every folder's view type. your settings stay put.
  Set-Reg 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell' 'FolderType' 'NotSpecified' 'String'
  # full path in explorer title bars. you always know where you are.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\CabinetState' 'FullPath' 1
  # win7 feel, native: This PC on the desktop, labelled My PC. needs logon to show.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel' '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' 0
  try {
    $pcKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\CLSID\{20D04FE0-3AEA-1069-A2D8-08002B30309D}'
    if (-not (Test-Path $pcKey)) { New-Item -Path $pcKey -Value 'My PC' -Force -EA Stop | Out-Null }
    else { Set-ItemProperty -Path $pcKey -Name '(Default)' -Value 'My PC' -EA Stop }
    Log '  desktop icon: My PC.'
  } catch { Log "  WARN desktop rename: $_" }
  # taskbar tuning with plain settings, no hooks: small icons, never combine so titles
  # show like sway workspaces, seconds in the clock, tray icons all out, junk
  # buttons gone, classic volume mixer and alt-tab, no aero shake.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarSmallIcons' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarGlomLevel' 2
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSecondsInSystemClock' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'EnableAutoTray' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowCortanaButton' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowTaskViewButton' 0
  # search box off the taskbar. win key still searches, the box just wastes space.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 0
  # aero peek off. no more desktop flash when you park the mouse in the corner.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'DisablePreviewDesktop' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\People' 'PeopleBand' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'HideSCAMeetNow' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\MTCUVC' 'EnableMtcUvc' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'AltTabSettings' 1
  Set-Reg 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisallowShaking' 1
  # shiftx5 popup dies. you live on win+shift with a tiling wm.
  Set-Reg 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'
  # alt-key underlines always on. keyboard-first box, no hunting.
  Set-Reg 'HKCU:\Control Panel\Accessibility\Keyboard Preference' 'On' '1' 'String'
  # taskbar locked. no accidental drags, still unlockable by right-click.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarSizeMove' 0
  # start tiles: one reset per profile. clears app-spam back to the default layout
  # (blank on iso installs). marker keeps re-runs and lived-in menus untouched.
  if ($Unattended -and -not (Get-ItemProperty 'HKCU:\Software\Win-Iot' -Name StartTilesDone -EA SilentlyContinue)) {
    try {
      Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount' -Recurse -Force -EA Stop
      if (-not (Test-Path 'HKCU:\Software\Win-Iot')) { New-Item -Path 'HKCU:\Software\Win-Iot' -Force -EA Stop | Out-Null }
      New-ItemProperty -Path 'HKCU:\Software\Win-Iot' -Name StartTilesDone -Value 1 -PropertyType DWord -Force -EA Stop | Out-Null
      Log '  start tiles reset (applies on explorer restart below).'
    } catch { Log "  WARN tile reset: $_" }
  }
  # stock colors stay. snappier menus below, nothing else visual.
  Set-Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '100' 'String'
  # background apps: none. stuff runs when opened, not before.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
  # quiet box: toast popups off. (notification center itself dies machine-side above.)
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0
  # dark mode, easier on the eyes. taskbar + apps go dark.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 0
  # world formats, not us. dates and numbers stay unambiguous on shared docs.
  try { Set-Culture 'en-001' -EA Stop; Log '  formats: en-001 (world).' }
  catch { Log "  WARN formats: $_" }
  # looks fast: best-performance preset, but keep ClearType or fonts turn to mush.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
  Set-Reg 'HKCU:\Control Panel\Desktop' 'FontSmoothing' '2' 'String'
  Set-Reg 'HKCU:\Control Panel\Desktop' 'FontSmoothingType' 2
  # balance, not scorched earth: kill animations + peek, keep shadows + content
  # dragging so it still looks right. (winutil goes further; readability loses.)
  Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewAlphaSelect' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\DWM' 'EnableAeroPeek' 0
  # fastest key repeat. keyboard-first box, pays off daily.
  Set-Reg 'HKCU:\Control Panel\Keyboard' 'KeyboardDelay' 0
  # storage sense off. this box is managed by hand.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01' 0
  # no AI leftovers: inking + typing personalization off. copilot and recall
  # don't exist on win10 ltsc. opencode isn't windows, it stays.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\InputPersonalization' 'AllowInputPersonalization' 0
  Log '  NOTE: End-Task-with-right-click and Start-menu-layout are Win11-only - skipped on Win10.'
  # tweak matrix: optional config/tweak-matrix.json lists named tweaks + enabled.
  # it is advisory here (the real values already applied above), but it lets a
  # machine report which named bundles it considers on. missing file = no-op.
  $tmPath = Join-Path $Repo 'config\tweak-matrix.json'
  if (Test-Path $tmPath) {
    try {
      $tm = Get-Content $tmPath -Raw | ConvertFrom-Json
      if ($tm -and $tm.tweaks) {
        $on = @($tm.tweaks | Where-Object { $_.enabled } | ForEach-Object { $_.name })
        if ($on.Count) { Log ('  tweak matrix on: ' + ($on -join ', ')) }
      }
    } catch { Log "  WARN tweak matrix: $_" }
  }
  Log '  tweaks done.'
  # taskbar reads most of that at logon. nudge explorer so it applies now, reboot covers the rest.
  try { Stop-Process -Name explorer -Force -EA Stop; Log '  explorer restarted.' }
  catch { Log '  explorer restart skipped (reboot applies everything).' }
  Complete-Phase 'tweaks'
} elseif ($ConfigsOnly) { Log 'Tweaks skipped (configs-only).' } else { Log 'Tweaks skipped (-NoTweaks).' }

# strict-mode safe: Get-Command returns $null when missing, and
# $null.Source throws under Set-StrictMode. use this everywhere.
function Get-CmdPath($name) {
  $c = Get-Command $name -EA SilentlyContinue
  if ($c) { return $c.Source } else { return $null }
}
# ---------- 2. winget. tiny10 has no store so this is always missing at first. ----------
function Test-WingetRuns {
  # staged on disk != runnable. gutted appx leaves a dead exe behind.
  if (-not (Get-Command winget -EA SilentlyContinue)) { return $false }
  return ((Invoke-Native { winget --version }) -eq 0)
}
function Ensure-Winget {
  if (Test-WingetRuns) { Log 'winget: found.'; return $true }
  # store-licensed package already staged but exe not on PATH yet. happens after a half-done bootstrap.
  try {
    if (Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -EA SilentlyContinue) {
      $env:Path += ';' + (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
      if (Test-WingetRuns) { Log 'winget: found (staged package, PATH fixed).'; return $true }
    }
  } catch {}
  if ($NoWingetBootstrap) { Log 'winget: missing, bootstrap skipped (-NoWingetBootstrap).'; return $false }
  if (-not $online) { Log 'winget: offline, bootstrap skipped. connect or stage -OfflineDir.'; return $false }
  Log 'winget: missing (normal here). Bootstrapping...'
  $tmp = Join-Path $env:TEMP 'winget-bootstrap'; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  # appxsvc/clipsvc gutted or disabled on tiny10 = Add-AppxPackage hangs forever. try to wake them.
  # stripped AppX on purpose = winget impossible. bail fast, OfflineDir path below covers apps.
  if (-not (Get-Service AppXSvc -EA SilentlyContinue)) {
    Log 'winget: impossible here (AppXSvc stripped). use -NoWingetBootstrap -OfflineDir <path>.'
    return $false
  }
  foreach ($svc in @('AppXSvc','ClipSVC')) {
    try {
      $s = Get-Service $svc -EA SilentlyContinue
      if ($s -and $s.Status -ne 'Running') { Set-Service $svc -StartupType Manual -EA SilentlyContinue; Start-Service $svc -EA SilentlyContinue }
    } catch {}
  }
  # PS 5.1 renders a progress bar per byte on Invoke-WebRequest. 10x slower + looks stuck. off during bootstrap.
  $oldProg = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
  try {
    # skip what is already staged. reinstalling a newer-present appx is what hangs
    # on "Deployment operation progress ... Processing" for minutes.
    $deps = @(
      @{ name='VCLibs.x64.14.00.Desktop.appx'; url='https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'; pkg='Microsoft.VCLibs.140.00.UWPDesktop' },
      @{ name='XAML.x64.appx'; url='https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx'; pkg='Microsoft.UI.Xaml.2.8' }
    )
    foreach ($d in $deps) {
      try {
        if (Get-AppxPackage -Name $d.pkg -EA SilentlyContinue) { Log "dep already present, skip: $($d.pkg)"; continue }
      } catch {}
      $p = Join-Path $tmp $d.name
      # last hung run leaves a 12MB partial. a corrupt appx just hangs Add-AppxPackage again, so toss small files.
      try { if ((Test-Path $p) -and ((Get-Item $p).Length -lt 1MB)) { Remove-Item $p -Force -EA SilentlyContinue; Log "  tossed partial: $($d.name)" } } catch {}
      $off = if ($OfflineDir) { Join-Path $OfflineDir $d.name } else { '' }
      if ($off -and (Test-Path $off)) { Copy-Item $off $p -Force; Log "dep (offline): $($d.name)" }
      elseif (-not (Test-Path $p)) {
        # one dead download must not nuke the whole bootstrap
        try { Log "downloading $($d.name) (slow link, wait)..."; Invoke-WebRequest -Uri $d.url -OutFile $p -UseBasicParsing -TimeoutSec 300 -EA Stop; Log "  got $($d.name) ($([math]::Round((Get-Item $p).Length/1MB,1)) MB)" }
        catch { Log "WARN download $($d.name): $_"; continue }
      } else { Log "dep cached, using: $($d.name) ($([math]::Round((Get-Item $p).Length/1MB,1)) MB)" }
      try { Log "installing $($d.name) (1-3 min on hdd, wait)..."; Add-AppxPackage -Path $p -EA Stop; Log "installed: $($d.name)" }
      catch {
        # 0x80073D06 = newer version already in the image. that's fine, move on.
        if ("$_" -match '0x80073D06|higher version|already installed') { Log "dep already newer, ok: $($d.name)" }
        else { Log "WARN dep $($d.name): $_" }
      }
    }
    # winget 1.24+ needs WindowsAppRuntime 1.x or the msixbundle dies with 0x80073CF3.
    try {
      $warDone = (Get-AppxPackage -Name 'Microsoft.WindowsAppRuntime.1.8' -EA SilentlyContinue) -ne $null
      if (-not $warDone) {
        $warOff = $null
        if ($OfflineDir -and (Test-Path $OfflineDir)) {
          $warOff = Get-ChildItem $OfflineDir -Recurse -Include '*AppRuntime*','*appruntime*' -EA SilentlyContinue |
            Where-Object { $_.Extension -in @('.msix','.appx','.exe') } | Select-Object -First 1
        }
        if ($warOff -and $warOff.Extension -ne '.exe') {
          Add-AppxPackage -Path $warOff.FullName -EA Stop; Log "installed (offline): $($warOff.Name)"
        } elseif ($warOff) {
          $proc = Start-Process $warOff.FullName -ArgumentList '--quiet' -Wait -PassThru -EA Stop
          if ($proc.ExitCode -eq 0) { Log "installed (offline): $($warOff.Name)" }
          else { Log "WARN WindowsAppRuntime offline exit=$($proc.ExitCode)" }
        } else {
          $warExe = Join-Path $tmp 'windowsappruntimeinstall-x64.exe'
          try { if ((Test-Path $warExe) -and ((Get-Item $warExe).Length -lt 1MB)) { Remove-Item $warExe -Force -EA SilentlyContinue } } catch {}
          if (-not (Test-Path $warExe)) {
            Log 'downloading WindowsAppRuntime 1.8 (~80MB, slow link, wait)...'
            Invoke-WebRequest -Uri 'https://aka.ms/windowsappsdk/1.8/latest/windowsappruntimeinstall-x64.exe' -OutFile $warExe -UseBasicParsing -TimeoutSec 600 -EA Stop
            Log "  got WindowsAppRuntime ($([math]::Round((Get-Item $warExe).Length/1MB,1)) MB)"
          } else { Log 'WindowsAppRuntime installer cached, using it.' }
          $proc = Start-Process $warExe -ArgumentList '--quiet' -Wait -PassThru -EA Stop
          if ($proc.ExitCode -eq 0) { Log 'installed: WindowsAppRuntime 1.8' }
          else { Log "WARN WindowsAppRuntime exit=$($proc.ExitCode) (winget may still fail with 0x80073CF3)" }
        }
      } else { Log 'dep already present, ok: WindowsAppRuntime 1.8' }
    } catch {
      if ("$_" -match '0x80073D06|already installed') { Log 'dep already newer, ok: WindowsAppRuntime' }
      else { Log "WARN WindowsAppRuntime: $_" }
    }
    $msix = Join-Path $tmp 'Microsoft.DesktopAppInstaller.msixbundle'
    $offMsix = if ($OfflineDir) { Get-ChildItem $OfflineDir -Recurse -Filter '*.msixbundle' -EA SilentlyContinue | Select-Object -First 1 } else { $null }
    if ($offMsix) { Copy-Item $offMsix.FullName $msix -Force; Log "winget (offline): $($offMsix.Name)" }
    else {
      Log 'resolving latest winget release...'
      $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -UseBasicParsing -TimeoutSec 60 -EA Stop
      $asset = $rel.assets | Where-Object { $_.name -like '*.msixbundle' -and $_.name -notlike '*symbol*' } | Sort-Object size | Select-Object -First 1
      if (-not $asset) { throw 'no msixbundle in latest release' }
      try {
        if (Test-Path $msix) {
          $mlen = (Get-Item $msix).Length
          if (($mlen -lt 1MB) -or ($asset.size -gt 0 -and $mlen -ne $asset.size)) { Remove-Item $msix -Force -EA SilentlyContinue; Log '  tossed bad partial: winget msixbundle' }
        }
      } catch {}
      if (-not (Test-Path $msix)) {
        Log "downloading $($asset.name) ($([math]::Round($asset.size/1MB,1)) MB, wait)..."
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msix -UseBasicParsing -TimeoutSec 600 -EA Stop
        Log "  got winget ($([math]::Round((Get-Item $msix).Length/1MB,1)) MB)"
      } else { Log 'winget msixbundle cached, using it.' }
    }
    try { Log 'installing winget msixbundle (1-3 min, wait)...'; Add-AppxPackage -Path $msix -EA Stop }
    catch {
      if ("$_" -match '0x80073D06|already installed') { Log 'winget already newer, ok.' }
      else { throw }
    }
    $env:Path += ';' + (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
    if (Test-WingetRuns) { Log 'winget: installed.'; return $true }
    Log 'winget staged but will not execute here (AppX gutted). using choco/offline instead.'
    return $false
  } catch { Log "WARN winget bootstrap failed: $_. Install App Installer manually, then re-run."; return $false }
  finally { $ProgressPreference = $oldProg }
}
if ((-not $TweaksOnly) -and (-not $ConfigsOnly)) { $hasWinget = Ensure-Winget } else { $hasWinget = $false }

# ---------- 2a. choco. plain ps1 + exe/msi, no appx. this is the slick path on stripped images. ----------
function Ensure-Chocolatey {
  if (Get-Command choco -EA SilentlyContinue) { Log 'choco: found.'; return $true }
  if ($NoChocoBootstrap) { Log 'choco: missing, bootstrap skipped (-NoChocoBootstrap).'; return $false }
  if (-not $isAdmin) { Log 'choco: missing, needs admin to bootstrap. re-run as admin.'; return $false }
  if (-not $online) { Log 'choco: offline, bootstrap skipped. connect or stage -OfflineDir.'; return $false }
  Log 'choco: missing. Bootstrapping from community.chocolatey.org (needs net, 2-5 min)...'
  $oldProg = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
  try {
    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    Refresh-Path
    if (Get-Command choco -EA SilentlyContinue) { Log 'choco: installed.'; return $true }
    Log 'WARN choco bootstrap: installer ran but choco not on PATH.'; return $false
  } catch { Log "WARN choco bootstrap failed: $_. Install from chocolatey.org manually, then re-run."; return $false }
  finally { $ProgressPreference = $oldProg }
}
# winget id -> community package. all 11 verified live on community.chocolatey.org.
# a bad name fails safe: choco errors, id lands in the retry list.
# no choco package: helium, all vcredists, dotnet. no choco needed: komorebi,
# whkd, vesktop, telegram, qbittorrent, obs, git, vscodium, opencode ride github.
# 'python' tracks latest 3.x (3.15 at last check) while the winget id says 3.12. close enough.
$chocoMap = @{
  'Git.Git' = 'git'
  'OpenJS.NodeJS.LTS' = 'nodejs-lts'
  'Python.Python.3.12' = 'python'
  '7zip.7zip' = '7zip'
  'VideoLAN.VLC' = 'vlc'
  'qBittorrent.qBittorrent' = 'qbittorrent'
  'OBSProject.OBSStudio' = 'obs-studio'
  'Telegram.TelegramDesktop' = 'telegram'
  'VSCodium.VSCodium' = 'vscodium'
  'WiresharkFoundation.Wireshark' = 'wireshark'
  'SST.opencode' = 'opencode'
}
if ((-not $TweaksOnly) -and (-not $ConfigsOnly)) { $hasChoco = Ensure-Chocolatey } else { $hasChoco = $false }

# github-direct. no manager at all, straight off release pages. patterns verified
# against the live releases api. x64 only, this box is x64. helium has no assets
# on its releases page, so it stays staged-only. unauthenticated api = 60 calls/hr,
# this runs max 9 per pass. cached under TEMP so re-runs skip the download.
$gitMap = @{
  'LGUG2Z.komorebi'        = @{ repo='LGUG2Z/komorebi'; pattern='komorebi-*-x86_64.msi' }
  'LGUG2Z.whkd'            = @{ repo='LGUG2Z/whkd'; pattern='whkd-*-x86_64.msi' }
  'Vencord.Vesktop'        = @{ repo='Vencord/Vesktop'; pattern='Vesktop-Setup-*.exe' }
  'Telegram.TelegramDesktop' = @{ repo='telegramdesktop/tdesktop'; pattern='td-setup-win-x64-*.exe' }
  'qBittorrent.qBittorrent'  = @{ repo='qbittorrent/qBittorrent'; pattern='qbittorrent_*_x64_setup.exe' }
  'OBSProject.OBSStudio'   = @{ repo='obsproject/obs-studio'; pattern='OBS-Studio-*-Windows-x64-Installer.exe' }
  'Git.Git'                = @{ repo='git-for-windows/git'; pattern='Git-*-64-bit.exe' }
  'VSCodium.VSCodium'      = @{ repo='VSCodium/vscodium'; pattern='VSCodiumSetup-x64-*.exe' }
  'SST.opencode'           = @{ repo='sst/opencode'; pattern='opencode-windows-x64.zip' }
}
function Install-GitHubAsset($id) {
  $g = $gitMap[$id]
  $oldProg = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
  try {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$($g.repo)/releases/latest" -UseBasicParsing -TimeoutSec 60 -EA Stop
    $asset = $rel.assets | Where-Object {
      $_.name -like $g.pattern -and $_.name -notmatch '\.(blockmap|yml|asc|txt|sha1|sha256)$' -and $_.name -notmatch 'arm64|aarch64'
    } | Select-Object -First 1
    if (-not $asset) { throw "no asset matching $($g.pattern)" }
    $dir = Join-Path (Join-Path $env:TEMP 'github-dl') ($id -replace '[^A-Za-z0-9]+','_')
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dst = Join-Path $dir $asset.name
    # api knows the real size. a sleep-killed download leaves a big partial
    # that the old 1MB check waved through, then the installer choked on it.
    try {
      if (Test-Path $dst) {
        $len = (Get-Item $dst).Length
        if (($len -lt 1MB) -or ($asset.size -gt 0 -and $len -ne $asset.size)) { Remove-Item $dst -Force -EA SilentlyContinue; Log "  tossed bad partial: $($asset.name)" }
      }
    } catch {}
    if (-not (Test-Path $dst)) {
      Log "  downloading $($asset.name) ($([math]::Round($asset.size/1MB,1)) MB)..."
      Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dst -UseBasicParsing -TimeoutSec 600 -EA Stop
    } else { Log "  cached: $($asset.name)" }
    if (-not (Test-DownloadHash (Get-Item $dst))) {
      Log '  hash mismatch, retrying once...'
      Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dst -UseBasicParsing -TimeoutSec 600 -EA Stop
      if (-not (Test-DownloadHash (Get-Item $dst))) { throw "hash still bad for $($asset.name)" }
    }
    Install-OfflineFile (Get-Item $dst)
  } finally { $ProgressPreference = $oldProg }
}
# evergreen vendor urls, HEAD-verified. no api, no manager. runtimes only:
# everything else desktop-ish has no stable direct link (versioned paths).
$directMap = @{
  'Microsoft.VCRedist.2015+.x86' = 'https://aka.ms/vs/17/release/vc_redist.x86.exe'
  'Microsoft.VCRedist.2015+.x64' = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
  'Microsoft.DotNet.DesktopRuntime.8' = 'https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe'
}
function Install-DirectUrl($id) {
  $url = $directMap[$id]
  $oldProg = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
  try {
    $dir = Join-Path (Join-Path $env:TEMP 'direct-dl') ($id -replace '[^A-Za-z0-9]+','_')
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dst = Join-Path $dir ($url -split '/')[-1]
    try { if ((Test-Path $dst) -and ((Get-Item $dst).Length -lt 1MB)) { Remove-Item $dst -Force -EA SilentlyContinue } } catch {}
    if (-not (Test-Path $dst)) {
      Log "  downloading $(Split-Path $url -Leaf)..."
      Invoke-WebRequest -Uri $url -OutFile $dst -UseBasicParsing -TimeoutSec 600 -EA Stop
    } else { Log "  cached: $(Split-Path $dst -Leaf)" }
    if (-not (Test-DownloadHash (Get-Item $dst))) { throw "hash mismatch for $(Split-Path $dst -Leaf)" }
    try { Install-OfflineFile (Get-Item $dst) }
    catch {
      # 1638 = that version already on disk. for runtimes that means covered.
      if ("$_" -match '1638') { Log '  already present, ok.' }
      else { throw }
    }
  } finally { $ProgressPreference = $oldProg }
}

# ---------- 2b. runtimes first. apps below need them. ----------
# ancient vendor tools still link the old redists, so all of them go on.
$runtimeApps = @(
  'Microsoft.VCRedist.2005.x86','Microsoft.VCRedist.2005.x64',
  'Microsoft.VCRedist.2008.x86','Microsoft.VCRedist.2008.x64',
  'Microsoft.VCRedist.2010.x86','Microsoft.VCRedist.2010.x64',
  'Microsoft.VCRedist.2012.x86','Microsoft.VCRedist.2012.x64',
  'Microsoft.VCRedist.2013.x86','Microsoft.VCRedist.2013.x64',
  'Microsoft.VCRedist.2015+.x86','Microsoft.VCRedist.2015+.x64',
  'Microsoft.DotNet.DesktopRuntime.8'
)
# 3.5 + DirectPlay for old vendor tools. some LTSC trims need install media, hence the warn.
if ($isAdmin -and (-not $TweaksOnly) -and (-not $ConfigsOnly)) {
  # install media carries its own payload. same-version sources only, per ms docs.
  $sxs = Get-PSDrive -PSProvider FileSystem -EA SilentlyContinue |
    ForEach-Object { Join-Path $_.Root 'sources\sxs' } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($sxs) { Log "  features source: $sxs" }
  foreach ($f in @('NetFx3','DirectPlay')) {
    # NOTE learned the hard way: native exes don't throw. check the exit code or the log lies.
    if ($sxs) { $exit = Invoke-Native { DISM /Online /Enable-Feature /FeatureName:$f /All /NoRestart /LimitAccess "/Source:$sxs" | Out-Null } }
    else { $exit = Invoke-Native { DISM /Online /Enable-Feature /FeatureName:$f /All /NoRestart | Out-Null } }
    # 3010 = success, reboot pending. not a failure.
    if ($exit -in @(0,3010)) { Log "${f}: enabled.$(if ($exit -eq 3010) { ' (reboot pending, normal)' })" }
    else { Log "WARN ${f}: DISM exit=$exit (insert install media so sources\sxs is visible) - enable manually for old vendor tools." }
  }
  Complete-Phase 'features'
} elseif ((-not $TweaksOnly) -and (-not $ConfigsOnly)) { Log 'WARN NetFx3/DirectPlay: skipped (not admin).' }
# 4.8 is already in the image. moving on.
$coreApps = @(
  'LGUG2Z.komorebi',
  'LGUG2Z.whkd',
  'ImputNet.Helium',
  'VSCodium.VSCodium',
  'Vencord.Vesktop',
  'Telegram.TelegramDesktop',
  'qBittorrent.qBittorrent',
  'VideoLAN.VLC',
  'OBSProject.OBSStudio',
  # automation-student essentials
  'Git.Git',
  'OpenJS.NodeJS.LTS',
  'Python.Python.3.12',
  '7zip.7zip',
  'WiresharkFoundation.Wireshark',
  # me. terminal agent, reads .m files like anything else.
  'SST.opencode'
)
$optionalApps = @('Obsidian.Obsidian','Spotify.Spotify')
if ($IncludeOptional) { $coreApps += $optionalApps }

$failed = @()
function Find-OfflineInstaller($id) {
  if (-not $OfflineDir -or -not (Test-Path $OfflineDir)) { return $null }
  # exact match: per-ID subfolder from Get-Offline.ps1. also sidesteps VC_redist name collisions.
  $sub = Join-Path $OfflineDir ($id -replace '[^A-Za-z0-9]+','_')
  if (Test-Path $sub) {
    return Get-ChildItem $sub -File -EA SilentlyContinue |
      Where-Object { $_.Extension -in @('.exe','.msi','.msix','.msixbundle','.appx','.zip') } |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
  }
  # sloppy fallback for hand-dropped folders. VCRedist needs the year check
  # because the last segment is just x64/x86 and matches literally everything.
  $segs = $id -split '\.'
  $cands = Get-ChildItem $OfflineDir -File -EA SilentlyContinue |
    Where-Object { $_.Name -like "*$($segs[-1])*" -and $_.Extension -in @('.exe','.msi','.msix','.msixbundle','.appx','.zip') }
  if ($segs[0] -eq 'Microsoft' -and $segs[1] -like 'VCRedist*') {
    $year = $segs[-2]
    $dated = $cands | Where-Object { $_.Name -like "*$year*" }
    if ($dated) { return $dated | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
    $redist = $cands | Where-Object { $_.Name -like '*redist*' }
    if ($redist) { Log "  WARN $id : year unverifiable in flat folder, using $(($redist | Select-Object -First 1).Name)" }
    return $redist | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  }
  return $cands | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
# silent flags per installer type. winget bakes the type into the filename
# (<name>_<ver>_<scope>_<arch>_<tech>_<lang>.<ext>) so read that, don't guess.
function Install-OfflineFile($file) {
  $seg = ($file.BaseName -split '[-_]')[0]
  switch ($file.Extension) {
    '.msi' {
      $proc = Start-Process msiexec -ArgumentList '/i', "`"$($file.FullName)`"", '/qn', '/norestart' -Wait -PassThru -EA Stop
      if ($proc.ExitCode -notin @(0,1641,3010)) { throw "msiexec exit=$($proc.ExitCode)" }
    }
    { $_ -in @('.appx','.msix','.msixbundle') } { Add-AppxPackage -Path $file.FullName -EA Stop }
    '.zip' {
      $dest = Join-Path $env:LOCALAPPDATA "Programs\$seg"
      New-Item -ItemType Directory -Force -Path $dest | Out-Null
      Expand-Archive -Path $file.FullName -DestinationPath $dest -Force -EA Stop
      # binary may sit in a subfolder (e.g. portable zips) - put the real dir on PATH
      $bin = Get-ChildItem $dest -Filter "$seg.exe" -Recurse -EA SilentlyContinue | Select-Object -First 1
      $bindir = if ($bin) { $bin.DirectoryName } else { $dest }
      $upath = [System.Environment]::GetEnvironmentVariable('Path','User')
      if ($upath -notlike "*$bindir*") {
        [System.Environment]::SetEnvironmentVariable('Path', "$upath;$bindir", 'User')
        $env:Path += ";$bindir"
      }
    }
    default {
      $exe = $file.FullName
      if ($file.Name -like '*_burn_*') {
        $proc = Start-Process $exe -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru -EA Stop
      } elseif ($file.Name -like '*redist*' -or $file.Name -like '*dotnet*' -or $file.Name -like '*runtime*') {
        $proc = Start-Process $exe -ArgumentList '/q' -Wait -PassThru -EA Stop
      } elseif ($file.Name -like '*python*') {
        $proc = Start-Process $exe -ArgumentList '/quiet', 'InstallAllUsers=0', 'PrependPath=1' -Wait -PassThru -EA Stop
      } elseif ($file.Name -like '*VSCodium*' -or $file.Name -like '*Git*' -or $file.Name -like '*Telegram*' -or $file.Name -like '*tsetup*' -or $file.Name -like '*td-setup*') {
        $proc = Start-Process $exe -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru -EA Stop
      } else {
        $proc = Start-Process $exe -ArgumentList '/S' -Wait -PassThru -EA Stop
      }
      if ($proc.ExitCode -notin @(0,1641,3010)) { throw "installer exit=$($proc.ExitCode) ($($file.Name))" }
    }
  }
}
if ((-not $TweaksOnly) -and (-not $ConfigsOnly) -and (Should-Run 'apps') -and ($hasWinget -or $hasChoco -or ($OfflineDir -and (Test-Path $OfflineDir)))) {
  foreach ($id in ($runtimeApps + $coreApps)) {
    $off = Find-OfflineInstaller $id
    if ($off -and $Unattended) {
      # staged beats everything. no net needed, no manager needed.
      Log "offline install: $($off.Name) for $id"
      try { Install-OfflineFile $off; Log '  ok (offline)'; continue }
      catch { Log "  WARN offline failed, falling through: $_" }
    }
    if ($hasWinget -and $online) {
      Log "winget install: $id"
      $exit = Invoke-Native { winget install --id $id -e --silent --accept-source-agreements --accept-package-agreements }
      if ($exit -eq 0) { Log '  ok'; continue }
      Log "  WARN exit=$exit, falling through"
    }
    if ($hasChoco -and $chocoMap.ContainsKey($id)) {
      # NOTE native exe, exit code is the truth. try/catch alone lies.
      Log "choco install: $($chocoMap[$id]) (for $id)"
      $exit = Invoke-Native { choco install $chocoMap[$id] -y --no-progress }
      if ($exit -eq 0) { Log '  ok'; continue }
      Log "  WARN exit=$exit, falling through"
    }
    if ($online -and $gitMap.ContainsKey($id)) {
      Log "github release: $id"
      try { Install-GitHubAsset $id; Log '  ok (github)'; continue }
      catch { Log "  WARN github ${id}: $_"; $failed += $id; continue }
    }
    if ($online -and $directMap.ContainsKey($id)) {
      Log "direct download: $id"
      try { Install-DirectUrl $id; Log '  ok (direct)'; continue }
      catch { Log "  WARN direct ${id}: $_"; $failed += $id; continue }
    }
    if ($off) {
      Log "  SKIP $id (staged but no -Unattended. re-run with -Unattended or run $($off.Name) by hand)"
      $failed += $id
    } elseif (-not $chocoMap.ContainsKey($id) -and -not $gitMap.ContainsKey($id) -and -not $directMap.ContainsKey($id)) {
      Log "  SKIP $id (no choco/github source. stage it: Get-Offline.ps1 -GapsOnly on a normal pc)"
      $failed += $id
    } else { $failed += $id }
  }
  if ($hasWinget -and $online) {
    $exit = Invoke-Native { winget upgrade --all --silent --accept-source-agreements --accept-package-agreements }
    if ($exit -eq 0) { Log '  winget upgrade done.' } else { Log "  WARN winget upgrade exit=$exit" }
  }
  elseif ($hasWinget) { Log 'SKIP winget upgrade (offline).' }
  if ($hasChoco -and $online) {
    $exit = Invoke-Native { choco upgrade all -y --no-progress }
    if ($exit -eq 0) { Log '  choco upgrade done.' } else { Log "  WARN choco upgrade exit=$exit" }
  }
  elseif ($hasChoco) { Log 'SKIP choco upgrade (offline).' }
  Complete-Phase 'apps'
} elseif ($TweaksOnly) { Log 'Tweaks-only: apps skipped.' } elseif ($ConfigsOnly) { Log 'Configs-only: apps skipped.' } else {
  Log 'SKIP installs (no winget, no choco, no -OfflineDir). Get net for choco, or stage with Get-Offline.ps1 - nothing marked failed yet.'
}

# fresh installs don't land on PATH in this session. re-read it or python/codium are "missing".
Refresh-Path
Log 'PATH refreshed.'

# bench drivers (ch340/cp210x/st-link). point at a folder of extracted vendor infs.
if ($DriverDir -and (Test-Path $DriverDir) -and (-not $TweaksOnly) -and (-not $ConfigsOnly)) {
  if ($isAdmin) {
    Log "drivers: $DriverDir"
    $exit = Invoke-Native { pnputil /add-driver "$DriverDir\*.inf" /subdirs /install }
    if ($exit -in @(0,3010)) { Log "  drivers staged+installed$(if ($exit -eq 3010) { ' (reboot pending)' })" }
    else { Log "  WARN pnputil exit=$exit (check the inf folder, install manually)" }
  } else { Log '  WARN drivers: skipped (not admin).' }
} elseif ($DriverDir) { Log '  WARN drivers: folder missing or tweaks-only/configs-only run.' }

Log 'NOTE manual-only: ExplorerBlurMica (Maplespe releases, optional), Spicetify (after Spotify: Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/spicetify/cli/main/install.ps1 | Invoke-Expression).'

# ---------- 3. configs ----------
if ((-not $TweaksOnly) -and (Should-Run 'configs')) {
Log 'Configs...'
function Copy-Config($src, $dst) {
  if (-not (Test-Path $src)) { Log "  SKIP missing in repo (not fatal): $src"; return }
  New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
  Copy-Item $src $dst -Force -EA Stop
  Log "  $dst"
}
# stock PS 5.1 profile lives under WindowsPowerShell in docs. that's just how it is.
$docPS = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
Copy-Config (Join-Path $Repo 'PowerShell\Microsoft.PowerShell_profile.ps1') $docPS
if (Get-Command pwsh -EA SilentlyContinue) {
  Copy-Config (Join-Path $Repo 'PowerShell\Microsoft.PowerShell_profile.ps1') (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Microsoft.PowerShell_profile.ps1')
}

# komorebi + whkd. the only WM here.
Copy-Config (Join-Path $Repo 'Komorebi\komorebi.json') (Join-Path $env:USERPROFILE 'komorebi.json')
Copy-Config (Join-Path $Repo 'Komorebi\whkdrc') (Join-Path $env:USERPROFILE '.config\whkd\whkdrc')

# git defaults. identity stays blank, that's yours to fill in after install.
Copy-Config (Join-Path $Repo 'Git\.gitconfig') (Join-Path $env:USERPROFILE '.gitconfig')

# extensions live in extensions.txt next to the script. edit that file, not this one.
$codium = Get-CmdPath 'codium'
if (-not $codium) {
  foreach ($cand in @("$env:LOCALAPPDATA\Programs\VSCodium\VSCodium.exe",
                      "$env:ProgramFiles\VSCodium\VSCodium.exe",
                      "${env:ProgramFiles(x86)}\VSCodium\VSCodium.exe")) {
    if (Test-Path $cand) { $codium = $cand; break }
  }
}

# vscodium eats vscode settings as-is. extensions come from open vsx though.
# appdata dir only shows up after first launch, so seed it when the exe exists.
$vs = Join-Path $env:APPDATA 'VSCodium\User\settings.json'
if ((Test-Path (Split-Path $vs)) -or ($codium -and (Test-Path $codium))) {
  New-Item -ItemType Directory -Force -Path (Split-Path $vs) | Out-Null
  Copy-Config (Join-Path $Repo 'VSCodium\settings.json') $vs
}
else { Log '  VSCodium not installed yet - settings kept in repo VSCodium/.' }
if ($codium -and (Test-Path $codium) -and (-not $ConfigsOnly)) {
  $extList = @('yasirarafat.opencode-ai-chat','Gimly81.matlab')
  $extFile = Join-Path $Repo 'VSCodium\extensions.txt'
  if (Test-Path $extFile) {
    $extList = Get-Content $extFile -EA SilentlyContinue |
      Where-Object { $_ -and $_ -notmatch '^\s*#' } |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ }
  }
  foreach ($ext in $extList) {
    try {
      $exit = Invoke-Native { & $codium --install-extension $ext }
      if ($exit -ne 0) { throw "exit=$exit" }
      Log "  vscodium ext: $ext"
    }
    catch { Log "  WARN vscodium ext ${ext}: install manually from Open VSX." }
  }
  Log '  NOTE: MATLAB extension (MathWorks) is MS-marketplace only - download the .vsix and: codium --install-extension <file>.vsix'
} elseif ($ConfigsOnly) { Log '  extensions skipped (configs-only).' } else { Log '  VSCodium exe not found - extensions skipped.' }

# pip libs for bench work. needs python on PATH, so this runs after the refresh above.
if (-not $ConfigsOnly) {
  try {
    $exit = Invoke-Native { python -m pip install --upgrade pip }
    if ($exit -ne 0) { throw "pip upgrade exit=$exit" }
    $exit = Invoke-Native { python -m pip install numpy scipy matplotlib pyserial pymodbus }
    if ($exit -ne 0) { throw "pip install exit=$exit" }
    Log '  python libs: numpy scipy matplotlib pyserial pymodbus'
  } catch { Log '  WARN pip libs skipped - run manually: python -m pip install numpy scipy matplotlib pyserial pymodbus' }
} else { Log '  python libs skipped (configs-only).' }

# fresh installs get configs; -ConfigsOnly (or -Force) re-deploys over existing ones.
function Copy-Fresh($src, $dst) {
  if (($ConfigsOnly -or $Force) -or -not (Test-Path $dst)) { Copy-Config $src $dst }
  else { Log "  keep existing: $dst" }
}
Copy-Fresh (Join-Path $Repo 'Vesktop\settings.json') (Join-Path $env:APPDATA 'Vesktop\settings.json')
Copy-Fresh (Join-Path $Repo 'qBittorrent\qbittorrent.ini') (Join-Path $env:APPDATA 'qBittorrent\qbittorrent.ini')
Copy-Fresh (Join-Path $Repo 'VLC\vlcrc') (Join-Path $env:APPDATA 'vlc\vlcrc')
Copy-Fresh (Join-Path $Repo 'OBS\profiles\Recording\basic.ini') (Join-Path $env:APPDATA 'obs-studio\basic\profiles\Recording\basic.ini')
Copy-Fresh (Join-Path $Repo 'Vesktop\quickcss.css') (Join-Path $env:APPDATA 'Vesktop\settings\quickcss.css')
# opencode global config: curated MCP servers (context7, playwright). fresh-only.
Copy-Fresh (Join-Path $Repo 'config\opencode.json') (Join-Path $env:USERPROFILE '.config\opencode\opencode.json')
$ocPlugins = Join-Path $env:USERPROFILE '.config\opencode\plugins'
if (-not (Test-Path $ocPlugins)) { New-Item -ItemType Directory -Force -Path $ocPlugins | Out-Null }
if (Test-Path (Join-Path $Repo 'Helium\master_preferences')) {
  $heData = Join-Path $env:LOCALAPPDATA 'Helium\User Data'
  if (-not (Test-Path $heData)) { Copy-Config (Join-Path $Repo 'Helium\master_preferences') (Join-Path $heData 'master_preferences') }
  else { Log '  Helium already ran - master_preferences ignored (change settings in UI).' }
}

# drop your .ttfs in Fonts/ and they get installed. admin only, windows rules.
$fontDir = Join-Path $Repo 'Fonts'
if ((Test-Path $fontDir) -and $isAdmin) {
  try {
    $shell = New-Object -ComObject Shell.Application -EA Stop
    $fFolder = $shell.Namespace(0x14)
    Get-ChildItem $fontDir -Include *.ttf,*.otf -Recurse -EA SilentlyContinue | ForEach-Object {
      try { $fFolder.CopyHere($_.FullName, 0x10); Log "  font: $($_.Name)" } catch { Log "  WARN font $($_.Name): $_" }
    }
  } catch { Log "  WARN fonts: shell object unavailable on this trim - right-click Install the .ttfs." }
} else { Log '  Fonts: drop JetBrainsMono Nerd Font + Monocraft .ttf into Fonts/ and re-run as admin (or right-click Install).' }
Complete-Phase 'configs'
} elseif ($TweaksOnly) { Log 'Configs skipped (tweaks-only).' } else { Log 'Configs skipped (already done).' }

# tweaks live up top now (section 1). runs first, cleanup lands in the finale.

# ---------- 4. rip out what helium/vlc/vscodium already replace ----------
# checks state first. on tiny10 half of this is already gone, it just says so and moves on.
if ((-not $NoDebloat) -and (-not $TweaksOnly) -and (-not $ConfigsOnly) -and (Should-Run 'debloat')) {
  Log 'Ripping out the replaced stuff...'
  if (-not $isAdmin) { Log '  skipped (not admin).' }
  else {
    try {
      $ie = Get-WindowsOptionalFeature -Online -FeatureName 'Internet-Explorer-Optional-amd64' -EA Stop
      if ($ie -and $ie.State -ne 'Disabled') { Disable-WindowsOptionalFeature -Online -FeatureName 'Internet-Explorer-Optional-amd64' -NoRestart -EA Stop | Out-Null; Log '  IE11 removed.' }
      else { Log '  IE11 already gone.' }
    } catch { Log "  WARN IE11: $_" }
    try {
      $edgeVer = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft\Edge\Application" -Directory -EA SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
      $edgeSetup = if ($edgeVer) { Join-Path $edgeVer.FullName 'Installer\setup.exe' } else { $null }
      if ($edgeSetup -and (Test-Path $edgeSetup)) {
        $proc = Start-Process $edgeSetup -ArgumentList '--uninstall','--system-level','--force-uninstall' -Wait -PassThru -EA Stop
        if ($proc.ExitCode -eq 0) { Log '  Edge uninstalled (edgeupdate services left alone - other MS apps may use them).' }
        else { Log "  WARN Edge exit=$($proc.ExitCode)" }
      } else { Log '  Edge already gone.' }
    } catch { Log "  WARN Edge: $_" }
    try {
      $wmp = Get-WindowsOptionalFeature -Online -FeatureName 'WindowsMediaPlayer' -EA Stop
      if ($wmp -and $wmp.State -ne 'Disabled') { Disable-WindowsOptionalFeature -Online -FeatureName 'WindowsMediaPlayer' -NoRestart -EA Stop | Out-Null; Log '  Media Player removed (VLC covers media).' }
      else { Log '  Media Player already gone.' }
    } catch { Log "  WARN Media Player: $_" }
    # PowerShell ISE <- VSCodium (editing) + console (running)
    try {
      $ise = Get-WindowsOptionalFeature -Online -FeatureName 'MicrosoftWindowsPowerShellISE' -EA Stop
      if ($ise -and $ise.State -ne 'Disabled') { Disable-WindowsOptionalFeature -Online -FeatureName 'MicrosoftWindowsPowerShellISE' -NoRestart -EA Stop | Out-Null; Log '  PowerShell ISE removed (VSCodium covers it).' }
      else { Log '  PowerShell ISE already gone.' }
    } catch { Log "  WARN ISE: $_" }
    # WordPad <- VSCodium/Obsidian (capability, not a feature)
    try {
      $wp = Get-WindowsCapability -Online -Name 'Microsoft.Windows.WordPad~~~~0.0.1.0' -EA Stop
      if ($wp -and $wp.State -ne 'NotPresent') { Remove-WindowsCapability -Online -Name 'Microsoft.Windows.WordPad~~~~0.0.1.0' -EA Stop | Out-Null; Log '  WordPad removed.' }
      else { Log '  WordPad already gone.' }
    } catch { Log "  WARN WordPad: $_" }
    # OneDrive. nothing here replaces sync, but nobody asked for it either. out.
    try {
      $od = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
      if (-not (Test-Path $od)) { $od = "$env:SystemRoot\System32\OneDriveSetup.exe" }
      if (Test-Path $od) {
        $proc = Start-Process $od -ArgumentList '/uninstall' -Wait -PassThru -EA Stop
        if ($proc.ExitCode -eq 0) { Log '  OneDrive removed.' } else { Log "  WARN OneDrive exit=$($proc.ExitCode)" }
      }
      else { Log '  OneDrive already gone.' }
    } catch { Log "  WARN OneDrive: $_" }
    # appx leftovers (bing, solitaire, xbox...). tiny10 usually has none; normal boxes do.
    if (Get-Command Get-AppxPackage -EA SilentlyContinue) {
      foreach ($fam in @('Microsoft.BingNews','Microsoft.BingWeather','Microsoft.GetHelp','Microsoft.Getstarted','Microsoft.MicrosoftOfficeHub','Microsoft.MicrosoftSolitaireCollection','Microsoft.People','Microsoft.WindowsFeedbackHub','Microsoft.YourPhone','Microsoft.ZuneMusic','Microsoft.ZuneVideo','Microsoft.SkypeApp','Microsoft.MixedReality.Portal','Microsoft.Print3D','Microsoft.XboxApp','Microsoft.XboxGameOverlay','Microsoft.XboxGamingOverlay','Microsoft.XboxSpeechToTextOverlay','Microsoft.Xbox.TCUI')) {
        try {
          Get-AppxPackage -Name "$fam*" -EA Stop | ForEach-Object {
            try { Remove-AppxPackage -Package $_.PackageFullName -EA Stop; Log "  appx removed: $($_.Name)" }
            catch { Log "  WARN appx $($_.Name): $_" }
          }
          Get-AppxProvisionedPackage -Online -EA Stop | Where-Object { $_.DisplayName -like "$fam*" } | ForEach-Object {
            try { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -EA Stop | Out-Null; Log "  provisioned removed: $($_.DisplayName)" }
            catch { Log "  WARN provisioned $($_.DisplayName): $_" }
          }
        } catch { Log "  WARN appx sweep ${fam}: $_" }
      }
    } else { Log '  appx sweep skipped (no appx provider).' }
  }
  Complete-Phase 'debloat'
} else { if ($TweaksOnly) { Log 'Tweaks-only: debloat skipped.' } elseif ($ConfigsOnly) { Log 'Configs-only: debloat skipped.' } else { Log 'Debloat skipped (-NoDebloat).' } }

# ---------- 5. autostart Komorebi + whkd (user logon), stock panel untouched ----------
if ((-not $TweaksOnly) -and (-not $ConfigsOnly) -and (Should-Run 'autostart')) {
Log 'Autostart...'
function Set-StartupShortcut($name, $target, $args) {
  $sm = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
  $lnk = Join-Path $sm "$name.lnk"
  try {
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lnk)
    $sc.TargetPath = $target; $sc.Arguments = $args; $sc.WorkingDirectory = (Split-Path $target); $sc.Save()
    Log "  startup: $name"
  } catch { Log "  WARN startup ${name}: $_" }
}
$kExe = Get-CmdPath 'komorebi'
if (-not $kExe) { $kExe = "$env:ProgramFiles\komorebi\bin\komorebi.exe" }
$wExe = Get-CmdPath 'whkd'
if (-not $wExe) { $wExe = "$env:ProgramFiles\whkd\whkd.exe" }
if ($kExe -and (Test-Path $kExe)) { Set-StartupShortcut 'komorebi' $kExe '' } else { Log '  komorebi exe not found yet - install it, shortcut applies next run.' }
if ($wExe -and (Test-Path $wExe)) { Set-StartupShortcut 'whkd' $wExe '' } else { Log '  whkd exe not found yet - install it, shortcut applies next run.' }

# helium default. per-user, needs no admin.
try {
  $helium = Get-CmdPath 'helium'
  if (-not $helium) {
    foreach ($root in @("$env:LOCALAPPDATA\Helium", "$env:ProgramFiles\Helium", "${env:ProgramFiles(x86)}\Helium")) {
      if (-not (Test-Path $root)) { continue }
      $h = Get-ChildItem $root -Filter 'helium.exe' -Recurse -EA SilentlyContinue | Select-Object -First 1
      if ($h) { $helium = $h.FullName; break }
    }
  }
  if ($helium) { Start-Process $helium -ArgumentList '--make-default-browser' -WindowStyle Hidden -EA Stop; Log '  Helium default-browser requested (confirm in Settings > Apps > Default apps).' }
  else { Log '  Helium not found yet - set default manually in Settings > Apps > Default apps.' }
} catch { Log "  WARN default browser: $_" }

# auth can't run unattended, so it goes on the desktop as a double-click thing.
try {
  $finishCmd = '@echo off' + "`r`n" + 'title Win-Iot finish setup' + "`r`n" +
    'powershell -NoProfile -ExecutionPolicy Bypass -Command "opencode auth login"' + "`r`n" +
    'echo.' + "`r`n" + 'echo Set a password now if you want one (Enter twice to stay blank):' + "`r`n" +
    'net user "My Pc" *' + "`r`n" +
    'echo.' + "`r`n" + 'echo Delete this shortcut when finished.' + "`r`n" + 'pause'
  $finishPath = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Win-Iot-Finish.cmd'
  Set-Content -Path $finishPath -Value $finishCmd -Encoding Ascii -Force -EA Stop
  Log "  finish helper: $finishPath"
} catch { Log "  WARN finish helper: $_" }
Complete-Phase 'autostart'
} elseif ($ConfigsOnly) { Log 'Autostart/browser/finish skipped (configs-only).' } else { Log 'Autostart/browser/finish skipped (tweaks-only).' }

if ((-not $TweaksOnly) -and (-not $ConfigsOnly)) {
  Log 'Smoke test...'
  foreach ($s in @(
    @{ n='komorebi'; cmd={ komorebi --version } },
    @{ n='whkd'; cmd={ Get-Command whkd -EA Stop | Out-Null } },
    @{ n='git'; cmd={ git --version } },
    @{ n='python'; cmd={ python --version } },
    @{ n='node'; cmd={ node --version } },
    @{ n='codium'; cmd={ & (Get-CmdPath 'codium') --version } },
    @{ n='opencode'; cmd={ opencode --version } },
    @{ n='7zip'; cmd={ Get-Command 7z -EA Stop | Out-Null } }
  )) {
    if ((Invoke-Native $s.cmd) -eq 0) { Log "  smoke ok: $($s.n)" }
    else { Log "  smoke MISSING: $($s.n)" }
  }
}

# ---------- 6. finale. sweep up, including our own mess. ----------
if (-not $NoTweaks) {
  Log 'Cleanup...'
  # installer caches + the fallback log dir survive for faster re-runs. rest goes.
  try {
    Get-ChildItem (Join-Path $env:TEMP '*') -Exclude 'winget-bootstrap','github-dl','direct-dl','Win-Iot-Setup' -EA SilentlyContinue |
      Remove-Item -Recurse -Force -EA SilentlyContinue
    if ($isAdmin) { Remove-Item 'C:\Windows\Temp\*' -Recurse -Force -EA SilentlyContinue }
    Log '  temp files removed.'
  } catch { Log "  WARN temp cleanup: $_" }
  # our own logs pile up in the log dir. keep 30 days, quietly.
  try {
    Get-ChildItem (Join-Path $LogDir 'install-*.log') -EA SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
      Remove-Item -Force -EA SilentlyContinue
  } catch {}
  if ($isAdmin) {
    # hibernate off (frees hiberfil.sys - matters on small tiny10 disks)
    $exit = Invoke-Native { powercfg /hibernate off }
    if ($exit -eq 0) { Log '  hibernation off.' } else { Log "  WARN hibernate exit=$exit" }
    # disk cleanup, no prompts (may be stripped on tiny10 -> warn only)
    try { Start-Process cleanmgr -ArgumentList '/VERYLOWDISK' -Wait -EA Stop; Log '  disk cleanup done.' }
    catch { Log '  WARN disk cleanup: cleanmgr missing (common on tiny10).' }
  }
  Complete-Phase 'cleanup'
} elseif ($ConfigsOnly) { Log 'Cleanup skipped (configs-only).' } else { Log 'Cleanup skipped (-NoTweaks).' }

Log '---'
if ($failed.Count) { Log ('FAILED/RETRY: ' + ($failed -join ', ')) } elseif ((-not $TweaksOnly) -and (-not $ConfigsOnly)) { Log 'All installs reported ok.' }
# success means caches are dead weight on a small disk. failures keep them for retry.
if ((-not $TweaksOnly) -and (-not $ConfigsOnly) -and ($failed.Count -eq 0)) {
  foreach ($c in @('winget-bootstrap','github-dl','direct-dl')) {
    Remove-Item (Join-Path $env:TEMP $c) -Recurse -Force -EA SilentlyContinue
  }
  Log '  installer caches purged.'
}
Log "Log: $LogFile"
if (-not $TweaksOnly) {
Log 'NEXT:'
Log '  1. reboot, Komorebi + whkd autostart, stock taskbar as-is.'
Log '  2. double-click Desktop Win-Iot-Finish.cmd (opencode auth + optional password).'
Log '  3. MATLAB via campus license + USB-serial drivers (CH340/CP210x/ST-Link) manually.'
} elseif ($ConfigsOnly) { Log 'Configs-only done.' } else { Log 'Tweaks-only done. reboot to feel the taskbar changes.' }
if ($Reboot) {
  Log 'rebooting in 60s (-Reboot). save your stuff.'
  shutdown /r /t 60 /c 'Win-Iot setup done. rebooting.' 2>&1 | Out-Null
}
if ($transcriptOn) { try { Stop-Transcript | Out-Null } catch {} }
