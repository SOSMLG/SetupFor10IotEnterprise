Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$fails = @()
function Assert($cond, $msg) {
  if ($cond) { Write-Host ('  ok: ' + $msg) }
  else { Write-Host ('  FAIL: ' + $msg); $script:fails += $msg }
}

# --- installer AST: params + helpers survive refactors ---
$installer = Join-Path $root 'install-Win-Iot.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'installer parses'
if ($errors.Count) { foreach ($e in $errors) { Write-Host ('  line ' + $e.Extent.StartLineNumber + ': ' + $e.Message) } }

$paramNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
foreach ($p in @('TweaksOnly','ConfigsOnly','Idempotent','Unattended','OfflineDir','DryRun','Verify','Only','SkipApps','Reboot','NoBackup','NoDebloat','NoTweaks','Fixes','IncludeStudy','SkipBatteryCap')) {
  Assert ($paramNames -contains $p) ("param -$p exists")
}
# types, not just names: a switch quietly losing [switch] is a bug magnet
foreach ($sw in @('DryRun','Verify','TweaksOnly','SkipBatteryCap')) {
  $pd = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $sw } | Select-Object -First 1
  Assert ($pd -and $pd.StaticType.ToString() -eq 'System.Management.Automation.SwitchParameter') ("-$sw is a switch")
}
foreach ($arr in @('Only','SkipApps')) {
  $pd = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $arr } | Select-Object -First 1
  Assert ($pd -and $pd.StaticType.ToString() -eq 'System.String[]') ("-$arr is a string array")
}

$fnNames = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
foreach ($fn in @('Invoke-Download','Test-DownloadComplete','Install-App','Test-AppDone','Set-AppDone','Test-AppFilter','Start-Phase','Stop-Phase','Test-PhaseDone','Set-PhaseDone','Should-Run','Resolve-ChargeCapAction','Test-QuickcssStale')) {
  Assert ($fnNames -contains $fn) ("function $fn defined")
}

# functional: pull the pure helpers out of the AST and exercise them
function Get-FnText($name) {
  $f = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
  if ($f) { return $f.Extent.Text }
  return $null
}
$t = Get-FnText 'Test-AppFilter'
if ($t) {
  . ([scriptblock]::Create($t))
  Assert ((Test-AppFilter 'Spotify.Spotify' @('spotif')) -eq $true) 'Test-AppFilter matches substring'
  Assert ((Test-AppFilter 'Git.Git' @('spotif','obs')) -eq $false) 'Test-AppFilter rejects non-match'
} else { Assert $false 'Test-AppFilter found for functional check' }

# charge cap guard chain: poked with made-up hardware so the real boxes stay clean
$t = Get-FnText 'Resolve-ChargeCapAction'
if ($t) {
  . ([scriptblock]::Create($t))
  Assert ((Resolve-ChargeCapAction 'Dell Inc.' $true 'ON' $null).action -eq 'skip') 'charge cap: non-lenovo skips'
  Assert ((Resolve-ChargeCapAction 'LENOVO' $false 'ON' $null).action -eq 'skip') 'charge cap: lenovo without PM driver skips'
  Assert ((Resolve-ChargeCapAction 'LENOVO' $true 'Charge threshold for Battery #1: ON.' $null).action -eq 'keep') 'charge cap: ON status keeps'
  $c = Resolve-ChargeCapAction 'LENOVO' $true 'Charge threshold for Battery #1: OFF.' $null
  Assert ($c.action -eq 'set' -and $c.start -eq 75) 'charge cap: OFF sets 80/75'
  $c = Resolve-ChargeCapAction 'LENOVO' $true 'OFF' 60
  Assert ($c.start -eq 60) 'charge cap: lower existing start kept'
  $c = Resolve-ChargeCapAction 'LENOVO' $true 'OFF' 90
  Assert ($c.start -eq 75) 'charge cap: start never above 75'
  Assert ((Resolve-ChargeCapAction 'LENOVO' $true '' $null).action -eq 'set') 'charge cap: empty status sets'
  Assert ((Resolve-ChargeCapAction 'LENOVO' $true 'AUS' $null).action -eq 'set') 'charge cap: unparsed status sets'
  Assert ((Resolve-ChargeCapAction 'LENOVO' $true 'OFF' -5).start -eq 75) 'charge cap: junk existing start ignored'
} else { Assert $false 'Resolve-ChargeCapAction found for functional check' }

# quickcss upgrade rule: only the exact placeholder (or an empty file) upgrades
$t = Get-FnText 'Test-QuickcssStale'
if ($t) {
  . ([scriptblock]::Create($t))
  Assert ((Test-QuickcssStale "/* QuickCSS placeholder. Stock Vesktop look.`r`n   Add your own rules below if you want them. */") -eq $true) 'quickcss: untouched placeholder upgrades'
  Assert ((Test-QuickcssStale $null) -eq $true) 'quickcss: missing file content upgrades'
  Assert ((Test-QuickcssStale "$([char]0xFEFF)") -eq $true) 'quickcss: bom-only file upgrades'
  Assert ((Test-QuickcssStale "/* QuickCSS placeholder. Stock Vesktop look.`n   Add your own rules below if you want them. */`nbody { color: red }") -eq $false) 'quickcss: user edits keep'
  Assert ((Test-QuickcssStale '/* QuickCSS placeholder. Stock Vesktop look.') -eq $false) 'quickcss: partial marker text alone stays'
} else { Assert $false 'Test-QuickcssStale found for functional check' }

# app state round-trip in a temp dir. dry-run must stay read-only.
$StateDir = Join-Path $env:TEMP ('win-iot-state-test-' + $PID)
$Force = $false
$DryRun = $false
function Log($m) {}
foreach ($fn in @('Get-AppState','Test-AppDone','Set-AppDone')) {
  $t = Get-FnText $fn
  if ($t) { . ([scriptblock]::Create($t)) }
}
if (Get-FnText 'Set-AppDone') {
  Set-AppDone 'Test.App'
  Assert (Test-Path (Join-Path $StateDir 'apps.json')) 'Set-AppDone writes apps.json'
  Assert ((Test-AppDone 'Test.App') -eq $true) 'Test-AppDone sees a done app'
  Assert ((Test-AppDone 'Other.App') -eq $false) 'Test-AppDone ignores unknown app'
  $Force = $true
  Assert ((Test-AppDone 'Test.App') -eq $false) '-Force bypasses app state'
  $Force = $false
  $DryRun = $true
  Set-AppDone 'Dry.App'
  Assert ((Test-AppDone 'Dry.App') -eq $false) 'dry-run writes no state'
  $DryRun = $false
  # Remove-Item -Recurse falls over on short-name (~) temp paths here; .NET delete does not.
  try { [System.IO.Directory]::Delete($StateDir, $true) } catch {}
}

# --- study pack: ids wired, shipped configs sane, one-click wrapper present ---
$rawInstaller = Get-Content $installer -Raw
foreach ($sid in @('DigitalScholar.Zotero','SumatraPDF.SumatraPDF','MiKTeX.MiKTeX','Typst.Typst','Microsoft.WindowsTerminal')) {
  Assert ($rawInstaller -match ("'" + [regex]::Escape($sid) + "'")) ("study id wired: $sid")
}
Assert ($rawInstaller -match [regex]::Escape('$coreApps += $studyApps')) 'study apps append to coreApps'
Assert ($rawInstaller -match [regex]::Escape('if ($IncludeStudy) { $extList +=')) 'study extensions gated on -IncludeStudy'
$rawOffline = Get-Content (Join-Path $root 'ISO\Get-Offline.ps1') -Raw
foreach ($sid in @('DigitalScholar.Zotero','SumatraPDF.SumatraPDF','MiKTeX.MiKTeX','Typst.Typst','Microsoft.WindowsTerminal')) {
  Assert ($rawOffline -match ("'" + [regex]::Escape($sid) + "'")) ("Get-Offline mirrors study id: $sid")
}
Assert ($rawOffline -match [regex]::Escape('$runtimeApps + $gapIds + $extras')) 'Get-Offline gaps-only keeps switch extras'
Assert (Test-Path (Join-Path $root 'Setup.cmd')) 'Setup.cmd one-click wrapper present'
$sum = Join-Path $root 'SumatraPDF\SumatraPDF-settings.txt'
Assert (Test-Path $sum) 'SumatraPDF settings shipped'
if (Test-Path $sum) {
  $s = Get-Content $sum -Raw
  Assert ($s -match 'EnableTeXEnhancements\s*=\s*true') 'sumatra: tex enhancements on'
  Assert ($s -match 'InverseSearchCmdLine\s*=\s*codium') 'sumatra: inverse search back to codium'
  Assert ($s -match 'Theme\s*=\s*dark') 'sumatra: dark theme'
}
$wt = Join-Path $root 'WindowsTerminal\settings.json'
Assert (Test-Path $wt) 'terminal settings shipped'
if (Test-Path $wt) {
  $w = $null
  try { $w = (Get-Content $wt -Raw) | ConvertFrom-Json -EA Stop }
  catch { Write-Host ('  terminal settings parse: ' + $_.Exception.Message) }
  # strictmode 2 throws on missing properties, so read defensively.
  $wtDefault = $null
  $wtGuids = @()
  try {
    if ($w) {
      $wtDefault = $w.defaultProfile
      $wtGuids = @($w.profiles.list | ForEach-Object { $_.guid })
    }
  } catch {}
  Assert ($w -and $wtDefault) 'terminal settings parse + defaultProfile set'
  Assert (($wtGuids.Count -gt 0) -and ($wtGuids -contains $wtDefault)) 'terminal defaultProfile exists in profile list'
}
foreach ($sd in @('Zotero','MiKTeX','Typst','SumatraPDF','WindowsTerminal')) {
  Assert (Test-Path (Join-Path $root ($sd + '\README.md'))) ("$sd README shipped")
}

# --- taste port: app configs, battery, shell pack (win10 + win11) ---
$vsSet = Join-Path $root 'VSCodium\settings.json'
Assert (Test-Path $vsSet) 'vscodium settings shipped'
if (Test-Path $vsSet) {
  $vj = Get-Content $vsSet -Raw | ConvertFrom-Json
  $ct = $vj.PSObject.Properties['workbench.colorTheme']
  Assert ($ct -and $ct.Value -eq 'Darkmatter') 'vscodium settings: darkmatter theme picked'
}
$kb = Join-Path $root 'VSCodium\keybindings.json'
Assert (Test-Path $kb) 'vscodium keybindings shipped'
if (Test-Path $kb) {
  # ps 5.1 quirk: @(ConvertFrom-Json ...) nests the array, assign first then wrap.
  $kbJson = Get-Content $kb -Raw | ConvertFrom-Json
  Assert (@($kbJson).Count -ge 2) 'vscodium keybindings parse with entries'
  Assert ($rawInstaller -match [regex]::Escape('VSCodium\keybindings.json')) 'installer deploys keybindings'
}
$tp = Join-Path $root 'VSCodium\darkmatter-theme\package.json'
Assert (Test-Path $tp) 'vscodium theme shipped'
if (Test-Path $tp) {
  $t = Get-Content $tp -Raw | ConvertFrom-Json
  Assert (("$($t.publisher).$($t.name)") -eq 'xfcemlg.darkmatter-theme') 'vscodium theme id is xfcemlg.darkmatter-theme'
  Assert ($rawInstaller -match [regex]::Escape("xfcemlg.darkmatter-theme-$($t.version)")) 'installer deploy folder carries the theme version'
  # the theme label has to be exactly what settings.json picks, or vscodium sits on the default theme.
  $lab = @($t.contributes.themes)[0].label
  $vjT = Get-Content $vsSet -Raw | ConvertFrom-Json
  Assert ($vjT.'workbench.colorTheme' -eq $lab) 'vscodium theme label matches the picked colorTheme'
}
$qc = Join-Path $root 'Vesktop\quickcss.css'
Assert (Test-Path $qc) 'vesktop quickcss shipped'
if (Test-Path $qc) {
  $q = Get-Content $qc -Raw
  Assert ($q -match 'system24') 'vesktop quickcss is the system24 darkmatter theme'
  Assert ($q -notmatch 'QuickCSS placeholder') 'vesktop quickcss no longer carries the placeholder text'
}
Assert ($rawInstaller -match [regex]::Escape('Test-QuickcssStale')) 'installer upgrades only an untouched quickcss placeholder'
Assert ($rawInstaller -match [regex]::Escape('powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')) 'power: high performance guid is intact'
foreach ($sid in @('Starship.Starship','ajeetdsouza.zoxide','junegunn.fzf','sharkdp.bat','eza-community.eza','Fastfetch-cli.Fastfetch')) {
  Assert ($rawInstaller -match ("'" + [regex]::Escape($sid) + "'")) ("shell tool wired: $sid")
  Assert ($rawOffline -match ("'" + [regex]::Escape($sid) + "'")) ("Get-Offline mirrors shell tool: $sid")
}
$prof = Join-Path $root 'PowerShell\Microsoft.PowerShell_profile.ps1'
Assert (Test-Path $prof) 'shell profile shipped'
if (Test-Path $prof) {
  $pr = Get-Content $prof -Raw
  foreach ($needle in @('starship init','zoxide init','Set-PSReadLineOption -BellStyle None','HistorySearchBackward','eza','IsOutputRedirected')) {
    Assert ($pr -match [regex]::Escape($needle)) ("profile shell pack: $needle")
  }
}
foreach ($needle in @('SkipBatteryCap','monitor-timeout-dc 3','monitor-timeout-ac 10','standby-timeout-dc 30','standby-timeout-ac 0','5ca83367-6e45-459f-a27b-476b1d01c936','ChargeThreshold.exe','download.lenovo.com','ChargeStopPercentage','Get-AuthenticodeSignature','[dry-run] would set the lenovo charge cap')) {
  Assert ($rawInstaller -match [regex]::Escape($needle)) ("battery port wired: $needle")
}

# --- komorebi: british spelling, floats inline, no orphan config path ---
$kPath = Join-Path $root 'Komorebi\komorebi.json'
Assert (Test-Path $kPath) 'komorebi.json exists'
if (Test-Path $kPath) {
  $kRaw = Get-Content $kPath -Raw
  Assert ($kRaw -notmatch 'boarder_') 'komorebi.json has no boarder_ typo'
  Assert ($kRaw -match 'floating_applications') 'komorebi.json keeps float rules inline'
  $k = $null
  try { $k = $kRaw | ConvertFrom-Json -EA Stop; Assert $true 'komorebi.json parses' }
  catch { Assert $false ('komorebi.json parses: ' + $_.Exception.Message) }
  if ($k -and @($k.PSObject.Properties.Name) -contains 'app_specific_configuration_path') {
    # komorebi hard-crashes on a missing path (os error 2). the file must ship.
    $asp = $k.app_specific_configuration_path
    $aspLocal = if ($asp -and -not [System.IO.Path]::IsPathRooted($asp)) { Join-Path $root $asp } else { $asp }
    Assert ($asp -and (Test-Path $aspLocal)) 'app_specific_configuration_path points at a shipped file'
  }
}

# --- autounattend parity: ISO copy vs ventoy copy, comments ignored ---
$a = Join-Path $root 'ISO\autounattend.xml'
$v = Join-Path $root 'ventoy\script\Win-Iot-unattended.xml'
Assert ((Test-Path $a) -and (Test-Path $v)) 'both autounattend copies present'
if ((Test-Path $a) -and (Test-Path $v)) {
  function Normalize($path) {
    $raw = Get-Content $path -Raw
    $raw = [regex]::Replace($raw, '<!--.*?-->', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $lines = @($raw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return ($lines -join "`n")
  }
  $na = Normalize $a
  $nv = Normalize $v
  # case-sensitive on purpose: xml attribute casing drift is still drift
  Assert ($na -ceq $nv) 'ISO/autounattend.xml matches ventoy copy (comments ignored)'
  if ($na -cne $nv) {
    $ca = @($na -split "`n"); $cv = @($nv -split "`n")
    $n = [math]::Min($ca.Count, $cv.Count)
    for ($i = 0; $i -lt $n; $i++) {
      if ($ca[$i] -cne $cv[$i]) {
        Write-Host ('  first diff at line ' + ($i + 1))
        Write-Host ('    ISO:    ' + $ca[$i])
        Write-Host ('    ventoy: ' + $cv[$i])
        break
      }
    }
    if ($ca.Count -ne $cv.Count) { Write-Host ('  line counts differ: ISO=' + $ca.Count + ' ventoy=' + $cv.Count) }
  }
}

if ($fails.Count -eq 0) { Write-Host 'INSTALLER OK'; exit 0 }
Write-Host ('FAILURES: ' + $fails.Count); exit 1
