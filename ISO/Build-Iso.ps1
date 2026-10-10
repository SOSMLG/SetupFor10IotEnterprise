<#
.SYNOPSIS
  Slip this repo into iotenterprise10.iso. Files only, image untouched.
.DESCRIPTION
  Extracts the ISO to ISO/build, drops the repo under sources\$OEM$\$1\Setup
  (lands on C:\Setup at install time), stages ISO\Offline gaps next to
  FirstLogon.cmd, swaps in the merged autounattend.xml, rebuilds a bootable
  ISO with oscdimg from the ADK. Needs 7z + oscdimg. No admin needed.
  Assumes the single-image layout the current iso has (index 1).
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File ISO\Build-Iso.ps1
  powershell -ExecutionPolicy Bypass -File ISO\Build-Iso.ps1 -ReuseBuild -OutIso D:\Win10IoT.iso
#>
param(
  [string]$IsoPath = '',
  [string]$WorkDir = '',
  [string]$OfflineDir = '',
  [string]$OutIso = '',
  [string]$Label = 'WIN10IOT',
  [string]$OscdimgPath = '',
  [switch]$ReuseBuild
)
$ErrorActionPreference = 'Continue'
function Log($m) { Write-Host $m }
$ScriptDir = $PSScriptRoot
$Repo = Split-Path $ScriptDir -Parent
if (-not $IsoPath) { $IsoPath = Join-Path $Repo 'iotenterprise10.iso' }
if (-not $WorkDir) { $WorkDir = Join-Path $ScriptDir 'build' }
if (-not $OfflineDir) { $OfflineDir = Join-Path $ScriptDir 'Offline' }
if (-not $OutIso) { $OutIso = Join-Path $ScriptDir ('Win10IoT-21H2-' + (Get-Date -Format 'yyyyMMdd') + '.iso') }

# fail fast on tools. no point extracting 4.5GB then discovering oscdimg is missing.
if (-not (Get-Command 7z -EA SilentlyContinue)) { Log 'need 7z (choco install 7zip). stop.'; exit 1 }
$Oscdimg = $OscdimgPath
if (-not $Oscdimg) { $Oscdimg = (Get-Command oscdimg -EA SilentlyContinue).Source }
if (-not $Oscdimg) { $Oscdimg = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe" }
if (-not $Oscdimg -or -not (Test-Path $Oscdimg)) { $Oscdimg = Join-Path $env:TEMP 'adk-tools\oscdimg.exe' }
if (-not (Test-Path $Oscdimg)) { Log 'need oscdimg (ADK Deployment Tools, or -OscdimgPath). stop.'; exit 1 }
Log "oscdimg: $Oscdimg"
if (-not (Test-Path $IsoPath)) { Log "iso not found: $IsoPath"; exit 1 }

if ((Test-Path (Join-Path $WorkDir 'sources\install.wim')) -and $ReuseBuild) {
  Log 'reusing build dir.'
} else {
  Log 'extracting iso (a few min)...'
  if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force -EA Stop }
  New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
  $LASTEXITCODE = 0
  & 7z x $IsoPath "-o$WorkDir" -y | Out-Null
  if ($LASTEXITCODE -ne 0) { Log "7z exit=$LASTEXITCODE. stop."; exit 1 }
  Log '  extracted.'
}

# repo snapshot onto C:\Setup. the iso itself + caches stay out or the build doubles.
$dest = Join-Path $WorkDir 'sources\$OEM$\$1\Setup'
Log "staging repo -> $dest"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
# NOTE robocopy exit is a bitmask, 0-7 all mean success. only 8+ is failure.
$LASTEXITCODE = 0
& robocopy $Repo $dest /E /XD build Offline .git /XF *.iso /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -gt 7) { Log "robocopy repo exit=$LASTEXITCODE. stop."; exit 1 }

if (Test-Path $OfflineDir) {
  Log 'staging offline gaps...'
  $LASTEXITCODE = 0
  & robocopy $OfflineDir (Join-Path $dest 'ISO\Offline') /E /NFL /NDL /NJH /NJS | Out-Null
  if ($LASTEXITCODE -gt 7) { Log "robocopy offline exit=$LASTEXITCODE. stop."; exit 1 }
} else { Log 'no ISO\Offline. online engines cover all but helium + pre-2015 redists.' }

$merge = Join-Path $ScriptDir 'autounattend.xml'
if (Test-Path $merge) {
  Copy-Item $merge (Join-Path $WorkDir 'autounattend.xml') -Force -EA Stop
  Log '  merged autounattend in.'
} else { Log '  WARN no ISO\autounattend.xml, keeping the tiny10 one.' }

# blank start tiles, applied as SYSTEM before first logon. $OEM$ $$ = %WINDIR%.
$scSrc = Join-Path $ScriptDir 'SetupComplete.cmd'
$scDst = Join-Path $WorkDir 'sources\$OEM$\$$\Setup\Scripts\SetupComplete.cmd'
if (Test-Path $scSrc) {
  New-Item -ItemType Directory -Force -Path (Split-Path $scDst) | Out-Null
  Copy-Item $scSrc $scDst -Force -EA Stop
  Log '  SetupComplete (blank tiles) in.'
} else { Log '  WARN no ISO\SetupComplete.cmd, tiles stay stock.' }

# boot files come from the iso itself. noprompt = no "press any key" on uefi.
$etfs = Join-Path $WorkDir 'boot\etfsboot.com'
$efi = Join-Path $WorkDir 'efi\microsoft\boot\efisys_noprompt.bin'
if (-not ((Test-Path $etfs) -and (Test-Path $efi))) { Log 'boot files missing from build. stop.'; exit 1 }
if (Test-Path $OutIso) {
  # stale output, often locked by the test vm holding it as a dvd. clear it now
  # for a plain error instead of oscdimg error 32 later.
  try { Remove-Item $OutIso -Force -EA Stop }
  catch { Log "output locked ($OutIso). detach it from the vm, then re-run. stop."; exit 1 }
}
Log "rebuilding $OutIso ..."
$LASTEXITCODE = 0
& $Oscdimg -m -o -u2 -h -udfver102 "-bootdata:2#p0,e,b$etfs#pEF,e,b$efi" "-l$Label" $WorkDir $OutIso
if ($LASTEXITCODE -ne 0) { Log "oscdimg exit=$LASTEXITCODE. stop."; exit 1 }
Log "done: $OutIso"
Log 'burn with rufus (or ventoy), boot, first logon runs C:\Setup\ISO\FirstLogon.cmd as ThisPc.'
