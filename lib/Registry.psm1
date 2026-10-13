function Set-RegSafe {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)]$Value,
    [ValidateSet('DWord','QWord','String','ExpandString','MultiString','Binary')][string]$Type = 'DWord'
  )
  try {
    if ($Path -like 'HKU:*' -and -not (Get-PSDrive HKU -ErrorAction SilentlyContinue)) {
      New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -ErrorAction Stop | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) {
      New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Get-RegSafe {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Name
  )
  try {
    if ($Path -like 'HKU:*' -and -not (Get-PSDrive HKU -ErrorAction SilentlyContinue)) {
      New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -ErrorAction Stop | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) { return $null }
    $prop = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
    return $prop.$Name
  } catch {
    return $null
  }
}

Export-ModuleMember -Function Set-RegSafe, Get-RegSafe
