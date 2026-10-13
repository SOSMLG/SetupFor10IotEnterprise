function Write-Log {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Message,
    [string]$Level = 'INFO'
  )
  $ts = (Get-Date).ToString('HH:mm:ss')
  $line = "[{0}] [{1}] {2}" -f $ts, $Level.ToUpper(), $Message
  Write-Host $line
  # Get-Variable is StrictMode-safe: reading an unset $global:LogFile directly would throw.
  $lf = Get-Variable -Name LogFile -Scope Global -ValueOnly -ErrorAction SilentlyContinue
  if ($lf -and (Test-Path (Split-Path $lf -Parent))) {
    try {
      Add-Content -Path $lf -Value $line -Encoding UTF8
    } catch { }
  }
}

function Log-Info { param([string]$m) Write-Log -Message $m -Level INFO }
function Log-Warn { param([string]$m) Write-Log -Message $m -Level WARN }
function Log-Err  { param([string]$m) Write-Log -Message $m -Level ERR }
function Log-Debug{ param([string]$m) Write-Log -Message $m -Level DEBUG }

Export-ModuleMember -Function Write-Log, Log-Info, Log-Warn, Log-Err, Log-Debug
