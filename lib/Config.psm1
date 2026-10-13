function Import-JsonSafe {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $raw = Get-Content -Path $Path -Raw -ErrorAction Stop
    return $raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return $null
  }
}

function Export-JsonSafe {
  param(
    [string]$Path,
    [object]$Data
  )
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  try {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
    $json = $Data | ConvertTo-Json -Depth 10 -ErrorAction Stop
    Set-Content -Path $Path -Value $json -Encoding UTF8 -ErrorAction Stop
    return $true
  } catch {
    return $false
  }
}

function Merge-Config {
  param(
    [object]$Base,
    [object]$Override
  )
  if ($null -eq $Base) { return $Override }
  if ($null -eq $Override) { return $Base }

  # arrays replace wholesale; nested objects merge key-by-key
  if (-not (Test-JsonObject $Override) -or -not (Test-JsonObject $Base)) { return $Override }

  $res = $Base | ConvertTo-Json -Depth 20 | ConvertFrom-Json
  # normalise override too, so hashtables/dictionaries walk like PSCustomObject.
  $ovr = $Override | ConvertTo-Json -Depth 20 | ConvertFrom-Json
  $runtimeKeys = @('PSComputerName','PSShowComputerName','RunspaceId','PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')
  foreach ($p in $ovr.PSObject.Properties) {
    if ($runtimeKeys -contains $p.Name) { continue }
    $existing = $null
    if ($res.PSObject.Properties.Name -contains $p.Name) { $existing = $res.$($p.Name) }
    if ((Test-JsonObject $existing) -and (Test-JsonObject $p.Value)) {
      $merged = Merge-Config -Base $existing -Override $p.Value
      $res | Add-Member -MemberType NoteProperty -Name $p.Name -Value $merged -Force
    } else {
      $res | Add-Member -MemberType NoteProperty -Name $p.Name -Value $p.Value -Force
    }
  }
  return $res
}

function Test-JsonObject {
  param([object]$Value)
  if ($null -eq $Value) { return $false }
  if ($Value -is [string]) { return $false }
  if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [System.Management.Automation.PSCustomObject] -and $Value -isnot [System.Collections.IDictionary]) { return $false }
  return ($Value -is [System.Management.Automation.PSCustomObject] -or $Value -is [hashtable] -or $Value -is [System.Collections.IDictionary])
}

Export-ModuleMember -Function Import-JsonSafe, Export-JsonSafe, Merge-Config, Test-JsonObject
