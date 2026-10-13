function Test-AdminSafe {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-NativeResult {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][scriptblock]$Command,
    [int[]]$SuccessCodes = @(0,3010),
    [string]$Description = 'native'
  )
  $LASTEXITCODE = 0
  $oldEA = $ErrorActionPreference
  $ErrorActionPreference = 'Stop'
  try {
    & $Command 2>&1 | Out-Null
    $ec = $LASTEXITCODE
    if ($ec -in $SuccessCodes) {
      return @{ Success = $true; ExitCode = $ec; Message = "$Description succeeded ($ec)" }
    } else {
      return @{ Success = $false; ExitCode = $ec; Message = "$Description failed ($ec)" }
    }
  } catch {
    return @{ Success = $false; ExitCode = -1; Message = "$Description exception: $($_.Exception.Message)" }
  } finally {
    $ErrorActionPreference = $oldEA
  }
}

function Test-PathSafe {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  try {
    return Test-Path -LiteralPath $Path -PathType Any
  } catch {
    return $false
  }
}

function New-DirSafe {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  if (Test-PathSafe -Path $Path) { return $true }
  try {
    New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
    return $true
  } catch {
    return $false
  }
}

Export-ModuleMember -Function Test-AdminSafe, Invoke-NativeResult, Test-PathSafe, New-DirSafe

