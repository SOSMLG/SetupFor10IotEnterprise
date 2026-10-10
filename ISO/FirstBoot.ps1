param([switch]$Now)
# first-boot entry. autounattend calls this with no args: registers a one-shot
# task 2 min out so first logon finishes in seconds, then the installer runs
# detached with a live window. installer unregisters the task at start.
# FirstLogon.cmd passes -Now for immediate manual runs.
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path $here -Parent
if (-not (Test-Path (Join-Path $repo 'Install-Win10-IoT-21H2.ps1'))) { $repo = 'C:\Setup' }
$installer = Join-Path $repo 'Install-Win10-IoT-21H2.ps1'
$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$installer`"", '-Unattended')
foreach ($cand in @((Join-Path $here 'Offline'), 'C:\Setup\Offline', (Join-Path $repo 'Offline'))) {
  if (Test-Path $cand) { $argList += @('-OfflineDir', "`"$cand`""); break }
}
if ($Now) { Start-Process powershell -ArgumentList $argList -WindowStyle Normal; return }
try {
  Unregister-ScheduledTask -TaskName 'Win10IoT-Setup' -Confirm:$false -EA Stop
} catch {}
try {
  $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($argList -join ' ')
  $trg = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(2))
  $prn = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
  $set = New-ScheduledTaskSettingsSet -StartWhenAvailable
  Register-ScheduledTask -TaskName 'Win10IoT-Setup' -Action $act -Trigger $trg -Principal $prn -Settings $set -Force -EA Stop | Out-Null
} catch {
  # task scheduler gutted too. detached start, same as before.
  Start-Process powershell -ArgumentList $argList -WindowStyle Normal
}
