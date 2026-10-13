<#
.SYNOPSIS
  Seed ISO/Offline on an ONLINE pc with winget. Not on the stripped box.
.DESCRIPTION
  One subfolder per winget id, same names install-Win-Iot.ps1 expects.
  Copy the Offline folder into the ISO (or USB) next to FirstLogon.cmd.
  Keep the id list in sync with the installer. yep, by hand.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Get-Offline.ps1
  powershell -ExecutionPolicy Bypass -File Get-Offline.ps1 -OfflineDir D:\Offline -IncludeOptional
  powershell -ExecutionPolicy Bypass -File Get-Offline.ps1 -GapsOnly
#>
param(
  [string]$OfflineDir = (Join-Path $PSScriptRoot 'Offline'),
  [switch]$IncludeOptional,
  # minimal staging for an online stripped box: github covers komorebi/whkd/vesktop
  # now, choco covers the mainstream. only helium + runtimes still need files.
  # full seed for offline boxes.
  [switch]$GapsOnly
)
$ErrorActionPreference = 'Continue'
# same list as install-Win-Iot.ps1 $runtimeApps. change one, change both.
$runtimeApps = @(
  'Microsoft.VCRedist.2005.x86','Microsoft.VCRedist.2005.x64',
  'Microsoft.VCRedist.2008.x86','Microsoft.VCRedist.2008.x64',
  'Microsoft.VCRedist.2010.x86','Microsoft.VCRedist.2010.x64',
  'Microsoft.VCRedist.2012.x86','Microsoft.VCRedist.2012.x64',
  'Microsoft.VCRedist.2013.x86','Microsoft.VCRedist.2013.x64',
  'Microsoft.VCRedist.2015+.x86','Microsoft.VCRedist.2015+.x64',
  'Microsoft.DotNet.DesktopRuntime.8'
)
# same list as install-Win-Iot.ps1 $coreApps. change one, change both.
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
  'Git.Git',
  'OpenJS.NodeJS.LTS',
  'Python.Python.3.12',
  '7zip.7zip',
  'WiresharkFoundation.Wireshark',
  'SST.opencode'
)
if ($IncludeOptional) { $coreApps += @('Obsidian.Obsidian','Spotify.Spotify') }
# github + choco cover everything else online (see $gitMap/$chocoMap in the installer).
$gapIds = @('ImputNet.Helium')
$ids = if ($GapsOnly) { $runtimeApps + $gapIds } else { $runtimeApps + $coreApps }

if (-not (Get-Command winget -EA SilentlyContinue)) { Write-Host 'winget missing here. run this on a normal online pc, not the stripped box.'; exit 1 }
New-Item -ItemType Directory -Force -Path $OfflineDir | Out-Null
$failed = @()
$manifest = @()
foreach ($id in $ids) {
  $sub = Join-Path $OfflineDir ($id -replace '[^A-Za-z0-9]+','_')
  New-Item -ItemType Directory -Force -Path $sub | Out-Null
  Write-Host "fetch: $id"
  # exact-id download so filenames keep the tech tag (_wix_/_inno_/_nullsoft_/_burn_/_exe_). installer reads that for silent flags.
  winget download --id $id -e -d $sub --accept-source-agreements --accept-package-agreements
  if ($LASTEXITCODE -ne 0) { Write-Host "  WARN exit=$LASTEXITCODE"; $failed += $id; continue }
  Write-Host '  ok'
  foreach ($f in (Get-ChildItem -Path $sub -File -ErrorAction SilentlyContinue)) {
    $hash = ''
    try { $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash } catch {}
    $manifest += [PSCustomObject]@{
      id       = $id
      file     = $f.Name
      relpath  = ($sub.Substring($OfflineDir.Length).TrimStart('\')) + '\' + $f.Name
      size     = $f.Length
      sha256   = $hash
    }
  }
}
$manifestPath = Join-Path $OfflineDir 'manifest.json'
try {
  ConvertTo-Json -InputObject @($manifest) -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8
  Write-Host "manifest: $manifestPath ($($manifest.Count) files)"
} catch { Write-Host "WARN could not write manifest: $($_.Exception.Message)" }
Write-Host '---'
if ($failed.Count) { Write-Host ('RETRY: ' + ($failed -join ', ')) }
else { Write-Host 'all fetched.' }
Write-Host "copy this folder into the ISO next to FirstLogon.cmd, or seed a USB: $OfflineDir"
