function Get-TweakMatrix {
  return @(
    @{ Name='Telemetry0'; Category='Privacy'; Enabled=$true; Description='Set AllowTelemetry=0 (LTSC/Enterprise supported)' },
    @{ Name='DiagTrackDisabled'; Category='Privacy'; Enabled=$true; Description='Stop and disable the DiagTrack service' },
    @{ Name='LocationOff'; Category='Privacy'; Enabled=$true; Description='Disable location sensors via policy' },
    @{ Name='DisableTelemetry'; Category='Privacy'; Enabled=$true; Description='Disable telemetry scheduling key' }
  )
}

function _Set-RegValue {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)]$Value,
    [string]$Type = 'DWord'
  )
  if (-not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) {
    New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
  }
  New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
}

function Get-TweakAction {
  param([Parameter(Mandatory=$true)][string]$TweakName)
  switch ($TweakName) {
    'Telemetry0' {
      return { _Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Value 0 -Type DWord }
    }
    'DiagTrackDisabled' {
      return {
        try { Stop-Service -Name 'DiagTrack' -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
        try { Set-Service -Name 'DiagTrack' -StartupType Disabled -ErrorAction SilentlyContinue | Out-Null } catch {}
      }
    }
    'LocationOff' {
      return { _Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' -Name 'DisableLocation' -Value 1 -Type DWord }
    }
    'DisableTelemetry' {
      return {
        _Set-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' -Name 'AllowTelemetry' -Value 0 -Type DWord
        _Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'DoNotShowFeedbackNotifications' -Value 1 -Type DWord
      }
    }
    default { return $null }
  }
}

function Apply-Tweak {
  param(
    [Parameter(Mandatory=$true)][string]$TweakName,
    [hashtable]$Context
  )
  $action = Get-TweakAction -TweakName $TweakName
  if ($null -eq $action) {
    return @{ Success = $false; Name = $TweakName; Error = 'unknown tweak' }
  }
  try {
    & $action
    return @{ Success = $true; Name = $TweakName }
  } catch {
    return @{ Success = $false; Name = $TweakName; Error = $_.Exception.Message }
  }
}

Export-ModuleMember -Function Get-TweakMatrix, Get-TweakAction, Apply-Tweak
