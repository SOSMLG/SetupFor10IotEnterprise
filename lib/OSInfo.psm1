function Get-OSInfo {
  $info = [PSCustomObject]@{
    Build = $null
    UBR = $null
    Version = $null
    ReleaseId = $null
    Edition = $null
    EditionID = $null
    InstallationType = $null
    ProductName = $null
    IsWin10 = $false
    IsWin11 = $false
    IsLTSC = $false
    IsIoT = $false
    IsWin10LTSC = $false
    IsWin11LTSC = $false
    Architecture = $null
  }
  try {
    $win = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $info.Build = [string]$win.CurrentBuild
    $info.UBR = [string]$win.UBR
    $info.Version = [string]$win.DisplayVersion
    if (-not $info.Version) { $info.Version = [string]$win.ReleaseId }
    $info.ReleaseId = [string]$win.ReleaseId
    $info.Edition = [string]$win.ProductName
    $info.EditionID = [string]$win.EditionID
    $info.ProductName = [string]$win.ProductName
    $info.InstallationType = [string]$win.InstallationType
    $info.Architecture = [string]$env:PROCESSOR_ARCHITECTURE
    $b = 0
    if ([int]::TryParse([string]$info.Build, [ref]$b)) {
      if ($b -lt 22000) { $info.IsWin10 = $true } else { $info.IsWin11 = $true }
    }
    $prod = [string]$win.ProductName
    $eid = [string]$win.EditionID
    # LTSC shows as 'LTSC' in ProductName, or as the EnterpriseS edition id
    # (EnterpriseS / IoTEnterpriseS / EnterpriseSN / IoTEnterpriseSK).
    if ($prod -match 'LTSC' -or $eid -match 'EnterpriseS') { $info.IsLTSC = $true }
    if ($prod -match 'IoT' -or $eid -match 'IoT') { $info.IsIoT = $true }
    # combined flags so callers can tell "win10 ltsc" from "win11 ltsc" in one check.
    $ltscish = ($info.IsLTSC -or $info.IsIoT)
    $info.IsWin10LTSC = ($info.IsWin10 -and $ltscish)
    $info.IsWin11LTSC = ($info.IsWin11 -and $ltscish)
  } catch { }
  return $info
}

function Test-HardwareMin {
  try {
    $memGB = [Math]::Round(((Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop | Measure-Object Capacity -Sum).Sum / 1GB), 2)
    $proc = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
    return @{ OK = $true; MemoryGB = $memGB; CPU = [string]$proc.Name }
  } catch {
    return @{ OK = $false; MemoryGB = $null; CPU = $null }
  }
}

Export-ModuleMember -Function Get-OSInfo, Test-HardwareMin
