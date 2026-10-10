<#
.SYNOPSIS
  My Win10 IoT 21H2 setup. Unattended, rerunnable.
.DESCRIPTION
  Built for a tiny10 box with no store and usually no network
  on first boot. PS 5.1, Komorebi + whkd, Helium, VSCodium, stock taskbar.
  No terminal, no extra shells. Stock colors everywhere.
  Engines per app, first hit wins: staged -OfflineDir files, winget,
  choco, github releases. Log lands in C:\Windows\Logs\Win10IoT-Setup either way.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Install-Win10-IoT-21H2.ps1
  powershell -ExecutionPolicy Bypass -File Install-Win10-IoT-21H2.ps1 -Unattended -OfflineDir D:\Offline
  powershell -ExecutionPolicy Bypass -File Install-Win10-IoT-21H2.ps1 -Unattended -DriverDir D:\Drivers -Reboot
  powershell -ExecutionPolicy Bypass -File Install-Win10-IoT-21H2.ps1 -IncludeOptional -Unattended
  powershell -ExecutionPolicy Bypass -File Install-Win10-IoT-21H2.ps1 -TweaksOnly
  (tweaks-only: just the tweaks on any live machine. no apps, no configs, no debloat.)
#>
[CmdletBinding()]
param(
  [switch]$IncludeOptional,
  [switch]$Unattended,
  [switch]$NoWingetBootstrap,
  [switch]$NoChocoBootstrap,
  [string]$OfflineDir = '',
  [string]$LogDir = 'C:\Windows\Logs\Win10IoT-Setup',
  [string]$DriverDir = '',
  [switch]$NoTweaks,
  [switch]$NoDebloat,
  [switch]$TweaksOnly,
  [switch]$Reboot
)
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = Split-Path $MyInvocation.MyCommand.Path -Parent
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
# C:\Windows\Logs needs admin. non-admin runs fall back to TEMP instead of dying.
try { New-Item -ItemType Directory -Force -Path $LogDir -EA Stop | Out-Null }
catch { $LogDir = Join-Path $env:TEMP 'Win10IoT-Setup'; New-Item -ItemType Directory -Force -Path $LogDir -EA SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "install-$Stamp.log"
$transcriptOn = $false
try { Start-Transcript -Path $LogFile -Force -EA Stop | Out-Null; $transcriptOn = $true } catch {}
function Log($m) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) }
function Refresh-Path {
  # fresh installs don't land on PATH in this session. re-read it or python/codium are "missing".
  try { $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User') } catch {}
}
# one-shot task from FirstBoot already fired. remove it so it never refires.
try { Unregister-ScheduledTask -TaskName 'Win10IoT-Setup' -Confirm:$false -EA Stop } catch {}

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
if (-not $online) { Log 'OFFLINE mode: online engines skipped; pre-seeded files still apply.' }

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
    netsh interface teredo set state disabled 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Log '  teredo off.' } else { Log "  WARN teredo exit=$LASTEXITCODE" }
    # clock reads RTC as UTC. dual-boot friendly, linux does the same.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' 'RealTimeIsUniversal' 1
    # clock may be off after the rtc flip. sync once when online, warn and move on.
    if ($online) {
      try {
        $LASTEXITCODE = 0
        w32tm /resync 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Log '  clock synced.' } else { Log "  WARN clock sync exit=$LASTEXITCODE (syncs on its own later)" }
      } catch { Log "  WARN clock sync: $_" }
    }
    # high performance plan. tiny10 parks on balanced, bench boxes want full clocks.
    powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635ec 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Log '  power: high performance.' } else { Log "  WARN power plan exit=$LASTEXITCODE" }
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
  # occasional start suggestions off. the win10 name for the same toggle.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 0
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
  if ($Unattended -and -not (Get-ItemProperty 'HKCU:\Software\Win10IoT' -Name StartTilesDone -EA SilentlyContinue)) {
    try {
      Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount' -Recurse -Force -EA Stop
      if (-not (Test-Path 'HKCU:\Software\Win10IoT')) { New-Item -Path 'HKCU:\Software\Win10IoT' -Force -EA Stop | Out-Null }
      New-ItemProperty -Path 'HKCU:\Software\Win10IoT' -Name StartTilesDone -Value 1 -PropertyType DWord -Force -EA Stop | Out-Null
      Log '  start tiles reset (applies on explorer restart below).'
    } catch { Log "  WARN tile reset: $_" }
  }
  # stock colors stay. snappier menus below, nothing else visual.
  Set-Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '100' 'String'
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
  Log '  NOTE: End-Task-with-right-click and Start-menu-layout are Win11-only - skipped on Win10.'
  Log '  tweaks done.'
  # taskbar reads most of that at logon. nudge explorer so it applies now, reboot covers the rest.
  try { Stop-Process -Name explorer -Force -EA Stop; Log '  explorer restarted.' }
  catch { Log '  explorer restart skipped (reboot applies everything).' }
} else { Log 'Tweaks skipped (-NoTweaks).' }

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
  $oldEA = $ErrorActionPreference; $ErrorActionPreference = 'Stop'
  try { & winget --version 2>&1 | Out-Null; return ($LASTEXITCODE -eq 0) }
  catch { return $false }
  finally { $ErrorActionPreference = $oldEA }
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
          Start-Process $warOff.FullName -ArgumentList '--quiet' -Wait -EA Stop
          if ($LASTEXITCODE -eq 0) { Log "installed (offline): $($warOff.Name)" }
          else { Log "WARN WindowsAppRuntime offline exit=$LASTEXITCODE" }
        } else {
          $warExe = Join-Path $tmp 'windowsappruntimeinstall-x64.exe'
          try { if ((Test-Path $warExe) -and ((Get-Item $warExe).Length -lt 1MB)) { Remove-Item $warExe -Force -EA SilentlyContinue } } catch {}
          if (-not (Test-Path $warExe)) {
            Log 'downloading WindowsAppRuntime 1.8 (~80MB, slow link, wait)...'
            Invoke-WebRequest -Uri 'https://aka.ms/windowsappsdk/1.8/latest/windowsappruntimeinstall-x64.exe' -OutFile $warExe -UseBasicParsing -TimeoutSec 600 -EA Stop
            Log "  got WindowsAppRuntime ($([math]::Round((Get-Item $warExe).Length/1MB,1)) MB)"
          } else { Log 'WindowsAppRuntime installer cached, using it.' }
          Start-Process $warExe -ArgumentList '--quiet' -Wait -EA Stop
          if ($LASTEXITCODE -eq 0) { Log 'installed: WindowsAppRuntime 1.8' }
          else { Log "WARN WindowsAppRuntime exit=$LASTEXITCODE (winget may still fail with 0x80073CF3)" }
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
if (-not $TweaksOnly) { $hasWinget = Ensure-Winget } else { $hasWinget = $false }

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
if (-not $TweaksOnly) { $hasChoco = Ensure-Chocolatey } else { $hasChoco = $false }

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
if ($isAdmin -and (-not $TweaksOnly)) {
  # install media carries its own payload. same-version sources only, per ms docs.
  $sxs = Get-PSDrive -PSProvider FileSystem -EA SilentlyContinue |
    ForEach-Object { Join-Path $_.Root 'sources\sxs' } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($sxs) { Log "  features source: $sxs" }
  foreach ($f in @('NetFx3','DirectPlay')) {
    # NOTE learned the hard way: native exes don't throw. check the exit code or the log lies.
    $LASTEXITCODE = 0
    if ($sxs) { DISM /Online /Enable-Feature /FeatureName:$f /All /NoRestart /LimitAccess "/Source:$sxs" | Out-Null }
    else { DISM /Online /Enable-Feature /FeatureName:$f /All /NoRestart | Out-Null }
    # 3010 = success, reboot pending. not a failure.
    if ($LASTEXITCODE -in @(0,3010)) { Log "${f}: enabled.$(if ($LASTEXITCODE -eq 3010) { ' (reboot pending, normal)' })" }
    else { Log "WARN ${f}: DISM exit=$LASTEXITCODE (insert install media so sources\sxs is visible) - enable manually for old vendor tools." }
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
      } elseif ($file.Name -like '*VSCodium*' -or $file.Name -like '*Git*' -or $file.Name -like '*Telegram*' -or $file.Name -like '*tsetup*' -or $file.Name -like '*td-setup*') {
        Start-Process $exe -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -EA Stop
      } else {
        Start-Process $exe -ArgumentList '/S' -Wait -EA Stop
      }
      if ($LASTEXITCODE -notin @(0,1641,3010)) { throw "installer exit=$LASTEXITCODE ($($file.Name))" }
    }
  }
}
# upgrade-all without the red wall. native exes don't throw, so EA Stop + exit check.
function Invoke-Upgrade($label, [scriptblock]$cmd) {
  $oldEA = $ErrorActionPreference; $ErrorActionPreference = 'Stop'
  try { & $cmd 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { Log "  WARN $label exit=$LASTEXITCODE" } else { Log "  $label done." } }
  catch { Log "  WARN ${label}: $_" }
  finally { $ErrorActionPreference = $oldEA }
}
if ((-not $TweaksOnly) -and ($hasWinget -or $hasChoco -or ($OfflineDir -and (Test-Path $OfflineDir)))) {
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
      $LASTEXITCODE = 0
      winget install --id $id -e --silent --accept-source-agreements --accept-package-agreements
      if ($LASTEXITCODE -eq 0) { Log '  ok'; continue }
      Log "  WARN exit=$LASTEXITCODE, falling through"
    }
    if ($hasChoco -and $chocoMap.ContainsKey($id)) {
      # NOTE native exe, exit code is the truth. try/catch alone lies.
      Log "choco install: $($chocoMap[$id]) (for $id)"
      $LASTEXITCODE = 0
      choco install $chocoMap[$id] -y --no-progress
      if ($LASTEXITCODE -eq 0) { Log '  ok'; continue }
      Log "  WARN exit=$LASTEXITCODE, falling through"
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
  if ($hasWinget -and $online) { Invoke-Upgrade 'winget upgrade' { winget upgrade --all --silent --accept-source-agreements --accept-package-agreements } }
  elseif ($hasWinget) { Log 'SKIP winget upgrade (offline).' }
  if ($hasChoco -and $online) { Invoke-Upgrade 'choco upgrade' { choco upgrade all -y --no-progress } }
  elseif ($hasChoco) { Log 'SKIP choco upgrade (offline).' }
} elseif ($TweaksOnly) { Log 'Tweaks-only: apps skipped.' } else {
  Log 'SKIP installs (no winget, no choco, no -OfflineDir). Get net for choco, or stage with Get-Offline.ps1 - nothing marked failed yet.'
}

# fresh installs don't land on PATH in this session. re-read it or python/codium are "missing".
Refresh-Path
Log 'PATH refreshed.'

# bench drivers (ch340/cp210x/st-link). point at a folder of extracted vendor infs.
if ($DriverDir -and (Test-Path $DriverDir) -and (-not $TweaksOnly)) {
  if ($isAdmin) {
    Log "drivers: $DriverDir"
    $LASTEXITCODE = 0
    pnputil /add-driver "$DriverDir\*.inf" /subdirs /install 2>&1 | Out-Null
    if ($LASTEXITCODE -in @(0,3010)) { Log "  drivers staged+installed$(if ($LASTEXITCODE -eq 3010) { ' (reboot pending)' })" }
    else { Log "  WARN pnputil exit=$LASTEXITCODE (check the inf folder, install manually)" }
  } else { Log '  WARN drivers: skipped (not admin).' }
} elseif ($DriverDir) { Log '  WARN drivers: folder missing or tweaks-only run.' }

Log 'NOTE manual-only: ExplorerBlurMica (Maplespe releases, optional), Spicetify (after Spotify: Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/spicetify/cli/main/install.ps1 | Invoke-Expression).'

# ---------- 3. configs ----------
if (-not $TweaksOnly) {
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
if ($codium -and (Test-Path $codium)) {
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
      $LASTEXITCODE = 0
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
  $LASTEXITCODE = 0
  & python -m pip install --upgrade pip 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "pip upgrade exit=$LASTEXITCODE" }
  $LASTEXITCODE = 0
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
  try {
    $shell = New-Object -ComObject Shell.Application -EA Stop
    $fFolder = $shell.Namespace(0x14)
    Get-ChildItem $fontDir -Include *.ttf,*.otf -Recurse -EA SilentlyContinue | ForEach-Object {
      try { $fFolder.CopyHere($_.FullName, 0x10); Log "  font: $($_.Name)" } catch { Log "  WARN font $($_.Name): $_" }
    }
  } catch { Log "  WARN fonts: shell object unavailable on this trim - right-click Install the .ttfs." }
} else { Log '  Fonts: drop JetBrainsMono Nerd Font + Monocraft .ttf into Fonts/ and re-run as admin (or right-click Install).' }
} else { Log 'Configs skipped (tweaks-only).' }

# tweaks live up top now (section 1). runs first, cleanup lands in the finale.

# ---------- 4. rip out what helium/vlc/vscodium already replace ----------
# checks state first. on tiny10 half of this is already gone, it just says so and moves on.
if ((-not $NoDebloat) -and (-not $TweaksOnly)) {
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
        Start-Process $edgeSetup -ArgumentList '--uninstall','--system-level','--force-uninstall' -Wait -EA Stop
        Log '  Edge uninstalled (edgeupdate services left alone - other MS apps may use them).'
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
      if (Test-Path $od) { Start-Process $od -ArgumentList '/uninstall' -Wait -EA Stop; Log '  OneDrive removed.' }
      else { Log '  OneDrive already gone.' }
    } catch { Log "  WARN OneDrive: $_" }
  }
} else { if ($TweaksOnly) { Log 'Tweaks-only: debloat skipped.' } else { Log 'Debloat skipped (-NoDebloat).' } }

# ---------- 5. autostart Komorebi + whkd (user logon), stock panel untouched ----------
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

if (-not $TweaksOnly) {
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
    $oldEA = $ErrorActionPreference; $ErrorActionPreference = 'Stop'
    try {
      $LASTEXITCODE = 0
      $cb = $s.cmd; & $cb 2>&1 | Out-Null
      if ($LASTEXITCODE -eq 0) { Log "  smoke ok: $($s.n)" }
      else { Log "  smoke MISSING: $($s.n) (exit=$LASTEXITCODE)" }
    } catch { Log "  smoke MISSING: $($s.n)" }
    finally { $ErrorActionPreference = $oldEA }
  }
}

# ---------- 6. finale. sweep up, including our own mess. ----------
if (-not $NoTweaks) {
  Log 'Cleanup...'
  # installer caches + the fallback log dir survive for faster re-runs. rest goes.
  try {
    Get-ChildItem (Join-Path $env:TEMP '*') -Exclude 'winget-bootstrap','github-dl','direct-dl','Win10IoT-Setup' -EA SilentlyContinue |
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
    $LASTEXITCODE = 0
    powercfg /hibernate off 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Log '  hibernation off.' } else { Log "  WARN hibernate exit=$LASTEXITCODE" }
    # disk cleanup, no prompts (may be stripped on tiny10 -> warn only)
    try { Start-Process cleanmgr -ArgumentList '/VERYLOWDISK' -Wait -EA Stop; Log '  disk cleanup done.' }
    catch { Log '  WARN disk cleanup: cleanmgr missing (common on tiny10).' }
  }
} else { Log 'Cleanup skipped (-NoTweaks).' }

Log '---'
if ($failed.Count) { Log ('FAILED/RETRY: ' + ($failed -join ', ')) } elseif (-not $TweaksOnly) { Log 'All installs reported ok.' }
# success means caches are dead weight on a small disk. failures keep them for retry.
if ((-not $TweaksOnly) -and ($failed.Count -eq 0)) {
  foreach ($c in @('winget-bootstrap','github-dl','direct-dl')) {
    Remove-Item (Join-Path $env:TEMP $c) -Recurse -Force -EA SilentlyContinue
  }
  Log '  installer caches purged.'
}
Log "Log: $LogFile"
if (-not $TweaksOnly) {
Log 'NEXT:'
Log '  1. reboot, Komorebi + whkd autostart, stock taskbar as-is.'
Log '  2. double-click Desktop Win10IoT-Finish.cmd (opencode auth + optional password).'
Log '  3. MATLAB via campus license + USB-serial drivers (CH340/CP210x/ST-Link) manually.'
} else { Log 'Tweaks-only done. reboot to feel the taskbar changes.' }
if ($Reboot) {
  Log 'rebooting in 60s (-Reboot). save your stuff.'
  shutdown /r /t 60 /c 'Win10IoT setup done. rebooting.' 2>&1 | Out-Null
}
if ($transcriptOn) { try { Stop-Transcript | Out-Null } catch {} }
