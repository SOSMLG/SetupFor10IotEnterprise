function Get-TemplatePath {
  param([string]$Name)
  $root = Split-Path $PSScriptRoot -Parent
  $p = Join-Path $root "templates\$Name"
  if (Test-Path -LiteralPath $p) { return $p }
  return $null
}

function Merge-Template {
  param(
    [string]$TemplatePath,
    [hashtable]$Replacements
  )
  if ([string]::IsNullOrWhiteSpace($TemplatePath) -or -not (Test-Path -LiteralPath $TemplatePath)) {
    return $null
  }
  try {
    $content = Get-Content -Path $TemplatePath -Raw -ErrorAction Stop
    if ($null -eq $Replacements) { return $content }
    foreach ($k in $Replacements.Keys) {
      $key = "{{$k}}"
      $val = [string]$Replacements[$k]
      $content = $content -replace [regex]::Escape($key), $val
    }
    return $content
  } catch {
    return $null
  }
}

function Write-AutoUnattend {
  param(
    [string]$OutPath,
    [hashtable]$Replacements = @{}
  )
  $root = Split-Path $PSScriptRoot -Parent
  $tpl = Join-Path $root 'templates\autounattend.xml.tpl'
  if (-not (Test-Path -LiteralPath $tpl)) {
    $tplAlt = Join-Path $root 'templates\autounattend-template.xml'
    if (Test-Path -LiteralPath $tplAlt) { $tpl = $tplAlt }
  }
  $merged = Merge-Template -TemplatePath $tpl -Replacements $Replacements
  if ($null -eq $merged) { return $false }
  try {
    $dir = Split-Path $OutPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
    Set-Content -Path $OutPath -Value $merged -Encoding UTF8 -ErrorAction Stop
    return $true
  } catch {
    return $false
  }
}

Export-ModuleMember -Function Get-TemplatePath, Merge-Template, Write-AutoUnattend
