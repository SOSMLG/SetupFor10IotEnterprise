Set-StrictMode -Version 2
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$files = Get-ChildItem $root -Recurse | Where-Object {
  $_.Extension -in @('.ps1', '.psm1') -and $_.FullName -notmatch '\\ISO\\build\\|\\ISO\\Offline\\|\\node_modules\\'
}
$bad = @()
foreach ($f in $files) {
  $tokens = $null
  $errors = $null
  $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
  if ($errors -and $errors.Count) {
    $bad += $f.FullName
    Write-Host ('ERR: ' + $f.FullName)
    foreach ($e in $errors) { Write-Host ('  line ' + $e.Extent.StartLineNumber + ': ' + $e.Message) }
  }
}
if ($bad.Count -eq 0) {
  Write-Host ("Syntax: OK (" + $files.Count + " files)")
  exit 0
} else {
  Write-Host ("Syntax: FAIL (" + $bad.Count + " of " + $files.Count + " files)")
  exit 1
}
