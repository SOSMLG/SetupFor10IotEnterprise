$root = Split-Path $PSScriptRoot -Parent
$bad = 0
Get-ChildItem $root -Recurse -Filter *.json | Where-Object { $_.FullName -notmatch '\\ISO\\build\\|\\node_modules\\' } | ForEach-Object {
  try {
    $null = Get-Content $_.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    Write-Host ('OK   ' + ($_.FullName.Substring($root.Length + 1)))
  } catch {
    Write-Host ('FAIL ' + $_.FullName + ' :: ' + $_.Exception.Message)
    $bad++
  }
}
# targeted: config/opencode.json must match the current opencode schema shape
$oc = Join-Path $root 'config\opencode.json'
if (Test-Path $oc) {
  try {
    $cfg = Get-Content $oc -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $ok = $true
    $names = @($cfg.PSObject.Properties.Name)
    if ($names -contains 'plugins') { $ok = $false; Write-Host 'opencode.json: uses "plugins" (current schema is "plugin")' }
    if ($names -contains 'plugin' -and -not ($cfg.plugin -is [array])) { $ok = $false; Write-Host 'opencode.json: "plugin" must be an array' }
    if (-not $cfg.mcp) { $ok = $false; Write-Host 'opencode.json: missing mcp' }
    foreach ($name in @('context7', 'playwright')) {
      $s = $cfg.mcp.$name
      if (-not $s) { $ok = $false; Write-Host "opencode.json: missing mcp $name"; continue }
      if ($s.type -ne 'local') { $ok = $false; Write-Host "opencode.json: mcp $name type must be 'local'" }
      if (-not ($s.command -is [array]) -or @($s.command).Count -lt 1) { $ok = $false; Write-Host "opencode.json: mcp $name command must be a non-empty array" }
    }
    if ($ok) { Write-Host 'opencode.json: schema ok' } else { $bad++ }
  } catch {
    Write-Host ("opencode.json check FAIL: " + $_.Exception.Message)
    $bad++
  }
}
if ($bad -gt 0) { Write-Host 'JSON: FAIL'; exit 1 } else { Write-Host 'JSON: all valid + opencode schema ok' }
