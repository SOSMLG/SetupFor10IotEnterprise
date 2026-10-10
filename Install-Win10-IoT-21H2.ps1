<#
.SYNOPSIS
  My Win10 IoT 21H2 setup. Unattended, rerunnable.
.DESCRIPTION
  Built for a tiny10 box with no store, no winget, and usually no network
  on first boot. PS 5.1, Komorebi + whkd, Helium, VSCodium, stock taskbar.
  No terminal, no extra shells. Red and black everywhere.
  Run it, reboot, double-click the Finish thing on the desktop. Log lands in
  C:\Windows\Logs\Win10IoT-Setup either way.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Install-Win10-IoT-21H2.ps1
  powershell -ExecutionPolicy Bypass -File Install-Win10-IoT-21H2.ps1 -IncludeOptional -Unattended
  powershell -ExecutionPolicy Bypass -File Install-Win10-IoT-21H2.ps1 -TweaksOnly
  (tweaks-only: just the Titus tweaks on any live machine. no apps, no configs, no debloat.)
#>
[CmdletBinding()]
param(
  [switch]$IncludeOptional,
  [switch]$Unattended,
  [switch]$NoWingetBootstrap,
  [string]$OfflineDir = '',
  [string]$LogDir = 'C:\Windows\Logs\Win10IoT-Setup',
  [switch]$NoTweaks,
  [switch]$NoDebloat,
  [switch]$TweaksOnly
)
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = Split-Path $MyInvocation.MyCommand.Path -Parent
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir "install-$Stamp.log"
Start-Transcript -Path $LogFile -Force | Out-Null
function Log($m) { Write-Host $m }

function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
$isAdmin = Test-Admin
if (-not $isAdmin) { Log 'WARN: not admin. fonts and autostart will probably fail.' }

try {
  $b = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
  Log "OS build: $b"
  if ($b -ne '19044' -and $b -ne '19045') { Log 'WARN: not 19044. going ahead anyway, watch the log.' }
} catch { Log "WARN: OS check failed: $_" }

if (-not $Unattended) {
  try { Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -EA SilentlyContinue } catch {}
}

# no net + no OfflineDir means nothing to install. say so now, not 20 min in.
$online = $false
try { $online = Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -EA Stop } catch {}
if (-not $online -and -not $OfflineDir) {
  Log 'WARN: no network detected and no -OfflineDir given.'
  Log '  Either connect, or seed ISO/Offline via Get-Offline.ps1 on an online PC'
  Log "  and re-run with: -OfflineDir '<path-to-Offline>' -Unattended"
}
if (-not $online) { Log 'OFFLINE mode: winget source installs will fail; pre-seeded files still apply.' }

# fresh boot almost never has DHCP yet. wait up to 4 min or winget dies for no reason.
# tweaks need no net, so tweaks-only skips the wait entirely.
if ((-not $online) -and (-not $TweaksOnly)) {
  $waited = 0
  while (-not $online -and $waited -lt 240) {
    Start-Sleep -Seconds 15; $waited += 15
    try { $online = Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -EA Stop } catch {}
  }
  if ($online) { Log "network up after ${waited}s." }
  else { Log 'WARN: still offline after 4 min - continuing with pre-seeded files only.' }
}

# ---------- 1. winget. tiny10 has no store so this is always missing at first. ----------
function Ensure-Winget {
  if (Get-Command winget -EA SilentlyContinue) { Log 'winget: found.'; return $true }
  if ($NoWingetBootstrap) { Log 'winget: missing, bootstrap skipped (-NoWingetBootstrap).'; return $false }
  Log 'winget: missing (normal here). Bootstrapping...'
  $tmp = Join-Path $env:TEMP 'winget-bootstrap'; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    $deps = @(
      @{ name='VCLibs.x64.14.00.Desktop.appx'; url='https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx' },
      @{ name='XAML.x64.appx'; url='https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx' }
    )
    foreach ($d in $deps) {
      $p = Join-Path $tmp $d.name
      $off = if ($OfflineDir) { Join-Path $OfflineDir $d.name } else { '' }
      if ($off -and (Test-Path $off)) { Copy-Item $off $p -Force; Log "dep (offline): $($d.name)" }
      elseif (-not (Test-Path $p)) {
        # one dead download must not nuke the whole bootstrap
        try { Log "downloading $($d.name)..."; Invoke-WebRequest -Uri $d.url -OutFile $p -UseBasicParsing }
        catch { Log "WARN download $($d.name): $_"; continue }
      }
      try { Add-AppxPackage -Path $p -EA Stop; Log "installed: $($d.name)" } catch { Log "WARN dep $($d.name): $_" }
    }
    $msix = Join-Path $tmp 'Microsoft.DesktopAppInstaller.msixbundle'
    $offMsix = if ($OfflineDir) { Get-ChildItem $OfflineDir -Filter '*.msixbundle' -EA SilentlyContinue | Select-Object -First 1 } else { $null }
    if ($offMsix) { Copy-Item $offMsix.FullName $msix -Force; Log "winget (offline): $($offMsix.Name)" }
    else {
      Log 'resolving latest winget release...'
      $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -UseBasicParsing
      $asset = $rel.assets | Where-Object { $_.name -like '*.msixbundle' } | Select-Object -First 1
      if (-not $asset) { throw 'no msixbundle in latest release' }
      Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msix -UseBasicParsing
    }
    Add-AppxPackage -Path $msix -EA Stop
    $env:Path += ';' + (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
    Log 'winget: installed.'
    return $true
  } catch { Log "WARN winget bootstrap failed: $_. Install App Installer manually, then re-run."; return $false }
}
if (-not $TweaksOnly) { $hasWinget = Ensure-Winget } else { $hasWinget = $false }

# ---------- 1b. runtimes first. apps below need them. ----------
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
if ($isAdmin -and (-not $TweaksOnly)) {
  foreach ($f in @('NetFx3','DirectPlay')) {
    # NOTE learned the hard way: native exes don't throw. check the exit code or the log lies.
    DISM /Online /Enable-Feature /FeatureName:$f /All /NoRestart | Out-Null
    if ($LASTEXITCODE -eq 0) { Log "${f}: enabled." }
    else { Log "WARN ${f}: DISM exit=$LASTEXITCODE (may need install media as source) - enable manually for old vendor tools." }
  }
} else { if (-not $TweaksOnly) { Log 'WARN NetFx3/DirectPlay: skipped (not admin).' } }
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
      Start-Process msiexec -ArgumentList '/i', "`"$($file.FullName)`"", '/qn', '/norestart' -Wait -EA Stop
      if ($LASTEXITCODE -notin @(0,1641,3010)) { throw "msiexec exit=$LASTEXITCODE" }
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
        Start-Process $exe -ArgumentList '/install', '/quiet', '/norestart' -Wait -EA Stop
      } elseif ($file.Name -like '*redist*' -or $file.Name -like '*dotnet*' -or $file.Name -like '*runtime*') {
        Start-Process $exe -ArgumentList '/q' -Wait -EA Stop
      } elseif ($file.Name -like '*python*') {
        Start-Process $exe -ArgumentList '/quiet', 'InstallAllUsers=0', 'PrependPath=1' -Wait -EA Stop
      } elseif ($file.Name -like '*VSCodium*' -or $file.Name -like '*Git*' -or $file.Name -like '*Telegram*' -or $file.Name -like '*tsetup*') {
        Start-Process $exe -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -EA Stop
      } else {
        Start-Process $exe -ArgumentList '/S' -Wait -EA Stop
      }
      if ($LASTEXITCODE -notin @(0,1641,3010)) { throw "installer exit=$LASTEXITCODE ($($file.Name))" }
    }
  }
}
if ((-not $TweaksOnly) -and $hasWinget) {
  foreach ($id in ($runtimeApps + $coreApps)) {
    $off = Find-OfflineInstaller $id
    if ($off -and $Unattended) {
      # no net, no winget source: burn through whatever was pre-seeded
      Log "offline install: $($off.Name) for $id"
      try { Install-OfflineFile $off; Log '  ok (offline)'; continue }
      catch { Log "  WARN offline failed, trying winget: $_" }
    }
    Log "winget install: $id"
    winget install --id $id -e --silent --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { Log "  WARN exit=$LASTEXITCODE"; $failed += $id } else { Log '  ok' }
  }
  if ($online) { try { winget upgrade --all --silent --accept-source-agreements --accept-package-agreements } catch {} }
  else { Log 'SKIP upgrade (offline).' }
} elseif ($TweaksOnly) { Log 'Tweaks-only: apps skipped.' } else {
  # winget completely absent. whatever is on disk still goes on.
  if ($OfflineDir -and (Test-Path $OfflineDir)) {
    Log 'No winget - installing from -OfflineDir only...'
    foreach ($id in ($runtimeApps + $coreApps)) {
      $off = Find-OfflineInstaller $id
      if ($off) {
        try { Install-OfflineFile $off; Log "  ok (offline): $id" }
        catch { Log "  WARN offline ${id}: $_"; $failed += $id }
      } else { $failed += $id }
    }
  } else { Log 'SKIP installs (no winget, no -OfflineDir).'; $failed += ($runtimeApps + $coreApps) }
}

# fresh installs don't land on PATH in this session. re-read it or python/codium are "missing".
try {
  $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
  Log 'PATH refreshed.'
} catch {}

Log 'NOTE manual-only: ExplorerBlurMica (Maplespe releases, optional), Spicetify (after Spotify: Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/spicetify/cli/main/install.ps1 | Invoke-Expression).'

# ---------- 3. configs ----------
if (-not $TweaksOnly) {
Log 'Configs...'
function Copy-Config($src, $dst) {
  New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
  Copy-Item $src $dst -Force
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

# vscodium eats vscode settings as-is. extensions come from open vsx though.
$vs = Join-Path $env:APPDATA 'VSCodium\User\settings.json'
if (Test-Path (Split-Path $vs)) { Copy-Config (Join-Path $Repo 'VSCodium\settings.json') $vs }
else { Log '  VSCodium not installed yet - settings kept in repo VSCodium/.' }

# extensions live in extensions.txt next to the script. edit that file, not this one.
$codium = (Get-Command codium -EA SilentlyContinue).Source
if (-not $codium) {
  foreach ($cand in @("$env:LOCALAPPDATA\Programs\VSCodium\VSCodium.exe",
                      "$env:ProgramFiles\VSCodium\VSCodium.exe",
                      "${env:ProgramFiles(x86)}\VSCodium\VSCodium.exe")) {
    if (Test-Path $cand) { $codium = $cand; break }
  }
}
if (Test-Path $codium) {
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
      & $codium --install-extension $ext 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "exit=$LASTEXITCODE" }
      Log "  vscodium ext: $ext"
    }
    catch { Log "  WARN vscodium ext ${ext}: install manually from Open VSX." }
  }
  Log '  NOTE: MATLAB extension (MathWorks) is MS-marketplace only - download the .vsix and: codium --install-extension <file>.vsix'
} else { Log '  VSCodium exe not found - extensions skipped.' }

# pip libs for bench work. needs python on PATH, so this runs after the refresh above.
try {
  & python -m pip install --upgrade pip 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "pip upgrade exit=$LASTEXITCODE" }
  & python -m pip install numpy scipy matplotlib pyserial pymodbus 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "pip install exit=$LASTEXITCODE" }
  Log '  python libs: numpy scipy matplotlib pyserial pymodbus'
} catch { Log '  WARN pip libs skipped - run manually: python -m pip install numpy scipy matplotlib pyserial pymodbus' }

# only fresh installs get configs. never clobber a lived-in one.
function Copy-Fresh($src, $dst) {
  if ((Test-Path $src) -and -not (Test-Path $dst)) { Copy-Config $src $dst }
  elseif (Test-Path $dst) { Log "  keep existing: $dst" }
}
Copy-Fresh (Join-Path $Repo 'Vesktop\settings.json') (Join-Path $env:APPDATA 'Vesktop\settings.json')
Copy-Fresh (Join-Path $Repo 'qBittorrent\qbittorrent.ini') (Join-Path $env:APPDATA 'qBittorrent\qbittorrent.ini')
Copy-Fresh (Join-Path $Repo 'VLC\vlcrc') (Join-Path $env:APPDATA 'vlc\vlcrc')
Copy-Fresh (Join-Path $Repo 'OBS\profiles\Recording\basic.ini') (Join-Path $env:APPDATA 'obs-studio\basic\profiles\Recording\basic.ini')
Copy-Fresh (Join-Path $Repo 'Vesktop\quickcss.css') (Join-Path $env:APPDATA 'Vesktop\settings\quickcss.css')
if (Test-Path (Join-Path $Repo 'Helium\master_preferences')) {
  $heData = Join-Path $env:LOCALAPPDATA 'Helium\User Data'
  if (-not (Test-Path $heData)) { Copy-Config (Join-Path $Repo 'Helium\master_preferences') (Join-Path $heData 'master_preferences') }
  else { Log '  Helium already ran - master_preferences ignored (change settings in UI).' }
}

# drop your .ttfs in Fonts/ and they get installed. admin only, windows rules.
$fontDir = Join-Path $Repo 'Fonts'
if ((Test-Path $fontDir) -and $isAdmin) {
  $shell = New-Object -ComObject Shell.Application
  $fFolder = $shell.Namespace(0x14)
  Get-ChildItem $fontDir -Include *.ttf,*.otf -Recurse -EA SilentlyContinue | ForEach-Object {
    try { $fFolder.CopyHere($_.FullName, 0x10); Log "  font: $($_.Name)" } catch { Log "  WARN font $($_.Name): $_" }
  }
} else { Log '  Fonts: drop JetBrainsMono Nerd Font + Monocraft .ttf into Fonts/ and re-run as admin (or right-click Install).' }
} else { Log 'Configs skipped (tweaks-only).' }

# ---------- 3b. sane defaults. titus-style, but plain reg so it works with no net. ----------
# win10 updates come as one blob, no security-only split exists.
# LTSC + "tell me first" + no surprise reboots + no driver pushes. good enough.
function Set-Reg($path, $name, $value, $type = 'DWord') {
  try {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $type -Force | Out-Null
  } catch { Log "  WARN reg ${path}\${name}: $_" }
}
if (-not $NoTweaks) {
  Log 'Sane defaults...'
  if ($isAdmin) {
    # restore point first. tiny10 usually ripped system restore out, so don't hold your breath.
    try { Checkpoint-Computer -Description 'Win10IoT pre-tweaks' -RestorePointType MODIFY_SETTINGS -EA Stop; Log '  restore point created.' }
    catch { Log '  WARN restore point: unavailable (common on tiny10) - continuing.' }
    # O&O ShutUp10++ next, our reg values after, so ours win any overlap.
    try {
      $oosu = Join-Path $Repo 'OOSU\OOSHUTUP10.exe'
      $oocfg = Join-Path $Repo 'OOSU\ooshutup10.cfg'
      if ((Test-Path $oosu) -and (Test-Path $oocfg)) {
        Start-Process $oosu -ArgumentList "`"$oocfg`"", '/quiet' -Wait -EA Stop
        Log '  O&O ShutUp10++ applied (titus cfg).'
      } else { Log '  O&O skipped (exe/cfg missing from OOSU/).' }
    } catch { Log "  WARN O&O: $_" }
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
    # tell-me-first updates, no reboot while logged in, and windows keeps its hands off my drivers.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions' 2
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1
    # machine-side privacy.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
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
    # WPBT lets vendor blobs run at boot. off.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'DisableWpbtExecution' 1
    # teredo off. xbox tunneling only, pure attack surface otherwise.
    netsh interface teredo set state disabled 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Log '  teredo off.' } else { Log "  WARN teredo exit=$LASTEXITCODE" }
    # clock reads RTC as UTC. dual-boot friendly, linux does the same.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' 'RealTimeIsUniversal' 1
    # reserved storage off. small disks need those gigs back.
    try { Set-WindowsReservedStorageState -State Disabled -EA Stop; Log '  reserved storage off.' }
    catch { Log "  WARN reserved storage: $_" }
    # IPv4 preferred, IPv6 stays alive. full disable breaks things, this doesn't.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents' 32
    # cloudflare DNS on every live adapter. dhcp hands the address, we pick the resolver.
    try {
      Get-NetAdapter -Physical -EA Stop | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
        Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses @('1.1.1.1','1.0.0.1') -EA Stop
      }
      Log '  DNS: cloudflare on live adapters.'
    } catch { Log "  WARN DNS: $_" }
    # notification center gone (toasts die per-user below).
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableNotificationCenter' 1
  } else { Log '  machine tweaks need admin. skipped.' }
  # per-user stuff, no admin needed.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSyncProviderNotifications' 0
  Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
  # feeds = win10's widgets. off.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Feeds' 'ShellFeedsTaskbarViewMode' 2
  # store suggestions. does nothing on tiny10, costs nothing. leave it.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'DisableSearchBoxSuggestions' 1
  # stop explorer from re-guessing every folder's view type. your settings stay put.
  Set-Reg 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell' 'FolderType' 'NotSpecified' 'String'
  # taskbar tuning with plain settings, no hooks: small icons, never combine so titles
  # show like sway workspaces, seconds in the clock, tray icons all out, junk
  # buttons gone, classic volume mixer and alt-tab, no aero shake.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarSmallIcons' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarGlomLevel' 2
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSecondsInSystemClock' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'EnableAutoTray' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowCortanaButton' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowTaskViewButton' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\People' 'PeopleBand' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'HideSCAMeetNow' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\MTCUVC' 'EnableMtcUvc' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'AltTabSettings' 1
  Set-Reg 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisallowShaking' 1
  # dark everywhere to match the red/black, snappier menus, numlock on, verbose boot.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 0
  Set-Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '100' 'String'
  # red accent on taskbar + start, matches everything else. needs the prevalence flag or it won't show.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Accent' 'AccentColorMenu' 5064933
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'ColorPrevalence' 1
  # console reds. errors and diffs pick these up in every terminal.
  Set-Reg 'HKCU:\Console' 'ColorTable04' 5064933
  Set-Reg 'HKCU:\Console' 'ColorTable12' 6906879
  # background apps: none. stuff runs when opened, not before.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
  # quiet box: toast popups off. (notification center itself dies machine-side above.)
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0
  # looks fast: best-performance preset, but keep ClearType or fonts turn to mush.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
  Set-Reg 'HKCU:\Control Panel\Desktop' 'FontSmoothing' '2' 'String'
  Set-Reg 'HKCU:\Control Panel\Desktop' 'FontSmoothingType' 2
  # storage sense off. this box is managed by hand.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01' 0
  # no AI leftovers: inking + typing personalization off. copilot and recall
  # don't exist on 21H2. opencode isn't windows, it stays.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\InputPersonalization' 'AllowInputPersonalization' 0
  # trash out temp.
  try {
    Remove-Item (Join-Path $env:TEMP '*') -Recurse -Force -EA SilentlyContinue
    if ($isAdmin) { Remove-Item 'C:\Windows\Temp\*' -Recurse -Force -EA SilentlyContinue }
    Log '  temp files removed.'
  } catch { Log "  WARN temp cleanup: $_" }
  if ($isAdmin) {
    # hibernate off (frees hiberfil.sys - matters on small tiny10 disks)
    powercfg /hibernate off 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Log '  hibernation off.' } else { Log "  WARN hibernate exit=$LASTEXITCODE" }
    # disk cleanup, no prompts (may be stripped on tiny10 -> warn only)
    try { Start-Process cleanmgr -ArgumentList '/VERYLOWDISK' -Wait -EA Stop; Log '  disk cleanup done.' }
    catch { Log '  WARN disk cleanup: cleanmgr missing (common on tiny10).' }
  }
  Log '  NOTE: End-Task-with-right-click and Start-menu-layout are Win11-only - skipped on Win10.'
  Log '  tweaks done.'
  # taskbar reads most of that at logon. nudge explorer so it applies now, reboot covers the rest.
  try { Stop-Process -Name explorer -Force -EA Stop; Log '  explorer restarted.' }
  catch { Log '  explorer restart skipped (reboot applies everything).' }
} else { Log 'Tweaks skipped (-NoTweaks).' }

# ---------- 3c. rip out what helium/vlc/vscodium already replace ----------
# checks state first. on tiny10 half of this is already gone, it just says so and moves on.
if ((-not $NoDebloat) -and (-not $TweaksOnly)) {
  Log 'Ripping out the replaced stuff...'
  if (-not $isAdmin) { Log '  skipped (not admin).' }
  else {
    try {
      $ie = Get-WindowsOptionalFeature -Online -FeatureName 'Internet-Explorer-Optional-amd64' -EA Stop
      if ($ie.State -ne 'Disabled') { Disable-WindowsOptionalFeature -Online -FeatureName 'Internet-Explorer-Optional-amd64' -NoRestart -EA Stop | Out-Null; Log '  IE11 removed.' }
      else { Log '  IE11 already gone.' }
    } catch { Log "  WARN IE11: $_" }
    try {
      $edgeVer = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft\Edge\Application" -Directory -EA SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
      $edgeSetup = if ($edgeVer) { Join-Path $edgeVer.FullName 'Installer\setup.exe' } else { $null }
      if ($edgeSetup -and (Test-Path $edgeSetup)) {
        Start-Process $edgeSetup -ArgumentList '--uninstall','--system-level','--force-uninstall' -Wait -EA Stop
        Log '  Edge uninstalled (edgeupdate services left alone - other MS apps may use them).'
      } else { Log '  Edge already gone.' }
    } catch { Log "  WARN Edge: $_" }
    try {
      $wmp = Get-WindowsOptionalFeature -Online -FeatureName 'WindowsMediaPlayer' -EA Stop
      if ($wmp.State -ne 'Disabled') { Disable-WindowsOptionalFeature -Online -FeatureName 'WindowsMediaPlayer' -NoRestart -EA Stop | Out-Null; Log '  Media Player removed (VLC covers media).' }
      else { Log '  Media Player already gone.' }
    } catch { Log "  WARN Media Player: $_" }
    # PowerShell ISE <- VSCodium (editing) + console (running)
    try {
      $ise = Get-WindowsOptionalFeature -Online -FeatureName 'MicrosoftWindowsPowerShellISE' -EA Stop
      if ($ise.State -ne 'Disabled') { Disable-WindowsOptionalFeature -Online -FeatureName 'MicrosoftWindowsPowerShellISE' -NoRestart -EA Stop | Out-Null; Log '  PowerShell ISE removed (VSCodium covers it).' }
      else { Log '  PowerShell ISE already gone.' }
    } catch { Log "  WARN ISE: $_" }
    # WordPad <- VSCodium/Obsidian (capability, not a feature)
    try {
      $wp = Get-WindowsCapability -Online -Name 'Microsoft.Windows.WordPad~~~~0.0.1.0' -EA Stop
      if ($wp.State -ne 'NotPresent') { Remove-WindowsCapability -Online -Name 'Microsoft.Windows.WordPad~~~~0.0.1.0' -EA Stop | Out-Null; Log '  WordPad removed.' }
      else { Log '  WordPad already gone.' }
    } catch { Log "  WARN WordPad: $_" }
    # OneDrive. nothing here replaces sync, but nobody asked for it either. out.
    try {
      $od = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
      if (-not (Test-Path $od)) { $od = "$env:SystemRoot\System32\OneDriveSetup.exe" }
      if (Test-Path $od) { Start-Process $od -ArgumentList '/uninstall' -Wait -EA Stop; Log '  OneDrive removed.' }
      else { Log '  OneDrive already gone.' }
    } catch { Log "  WARN OneDrive: $_" }
  }
} else { if ($TweaksOnly) { Log 'Tweaks-only: debloat skipped.' } else { Log 'Debloat skipped (-NoDebloat).' } }

# ---------- 4. autostart Komorebi + whkd (user logon), stock panel untouched ----------
if (-not $TweaksOnly) {
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
$kExe = (Get-Command komorebi -EA SilentlyContinue).Source
if (-not $kExe) { $kExe = "$env:ProgramFiles\komorebi\bin\komorebi.exe" }
$wExe = (Get-Command whkd -EA SilentlyContinue).Source
if (-not $wExe) { $wExe = "$env:ProgramFiles\whkd\whkd.exe" }
if (Test-Path $kExe) { Set-StartupShortcut 'komorebi' $kExe '' } else { Log '  komorebi exe not found yet - open it once, shortcut applies next run.' }
if (Test-Path $wExe) { Set-StartupShortcut 'whkd' $wExe '' } else { Log '  whkd exe not found yet - open it once, shortcut applies next run.' }

# helium default. per-user, needs no admin.
try {
  $helium = (Get-Command helium -EA SilentlyContinue).Source
  if (-not $helium) {
    foreach ($root in @("$env:LOCALAPPDATA\Helium", "$env:ProgramFiles\Helium", "${env:ProgramFiles(x86)}\Helium")) {
      if (-not (Test-Path $root)) { continue }
      $h = Get-ChildItem $root -Filter 'helium.exe' -Recurse -EA SilentlyContinue | Select-Object -First 1
      if ($h) { $helium = $h.FullName; break }
    }
  }
  if ($helium) { Start-Process $helium -ArgumentList '--make-default-browser' -WindowStyle Hidden -EA SilentlyContinue; Log '  Helium default-browser requested (confirm in Settings > Apps > Default apps).' }
  else { Log '  Helium not found yet - set default manually in Settings > Apps > Default apps.' }
} catch { Log "  WARN default browser: $_" }

# auth can't run unattended, so it goes on the desktop as a double-click thing.
try {
  $finishCmd = '@echo off' + "`r`n" + 'title Win10IoT finish setup' + "`r`n" +
    'powershell -NoProfile -ExecutionPolicy Bypass -Command "opencode auth login"' + "`r`n" +
    'echo.' + "`r`n" + 'echo Set a password now if you want one (Enter twice to stay blank):' + "`r`n" +
    'net user ThisPc *' + "`r`n" +
    'echo.' + "`r`n" + 'echo Delete this shortcut when finished.' + "`r`n" + 'pause'
  $finishPath = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Win10IoT-Finish.cmd'
  Set-Content -Path $finishPath -Value $finishCmd -Encoding Ascii -Force -EA Stop
  Log "  finish helper: $finishPath"
} catch { Log "  WARN finish helper: $_" }
} else { Log 'Autostart/browser/finish skipped (tweaks-only).' }

Log '---'
if ($TweaksOnly) { if ($failed.Count) { Log ('FAILED/RETRY: ' + ($failed -join ', ')) } }
elseif ($failed.Count) { Log ('FAILED/RETRY: ' + ($failed -join ', ')) } else { Log 'All winget installs reported ok.' }
Log "Log: $LogFile"
if (-not $TweaksOnly) {
Log 'NEXT:'
Log '  1. reboot, Komorebi + whkd autostart, stock taskbar as-is.'
Log '  2. double-click Desktop Win10IoT-Finish.cmd (opencode auth + optional password).'
Log '  3. MATLAB via campus license + USB-serial drivers (CH340/CP210x/ST-Link) manually.'
} else { Log 'Tweaks-only done. reboot to feel the taskbar changes.' }
Stop-Transcript | Out-Null
