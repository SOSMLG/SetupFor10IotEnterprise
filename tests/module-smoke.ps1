Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'lib\Network.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'lib\OSInfo.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'lib\TweakMatrix.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'lib\Config.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'lib\Logging.psm1') -Force -DisableNameChecking

$fails = @()
function Assert($cond, $msg) {
  if ($cond) { Write-Host ('  ok: ' + $msg) }
  else { Write-Host ('  FAIL: ' + $msg); $script:fails += $msg }
}

Write-Host ('Network: ' + ((Get-Command -Module Network).Name -join ','))
Write-Host ('TweakMatrix: ' + ((Get-Command -Module TweakMatrix).Name -join ','))
Write-Host ('Config: ' + ((Get-Command -Module Config).Name -join ','))
Write-Host ('OSInfo: ' + ((Get-Command -Module OSInfo).Name -join ','))

foreach ($fn in @('Resolve-DnsBest','Set-DNS','Set-NextDns','Test-DnsServer','Test-Online')) {
  Assert ([bool](Get-Command -Name $fn -Module Network -EA SilentlyContinue)) "Network exports $fn"
}
foreach ($fn in @('Merge-Config','Import-JsonSafe','Export-JsonSafe','Test-JsonObject')) {
  Assert ([bool](Get-Command -Name $fn -Module Config -EA SilentlyContinue)) "Config exports $fn"
}
foreach ($fn in @('Get-TweakMatrix','Get-TweakAction','Apply-Tweak')) {
  Assert ([bool](Get-Command -Name $fn -Module TweakMatrix -EA SilentlyContinue)) "TweakMatrix exports $fn"
}

$o = Get-OSInfo
Write-Host ('OS: build=' + $o.Build + ' ubr=' + $o.UBR + ' win10=' + $o.IsWin10 + ' win11=' + $o.IsWin11 + ' ltsc=' + $o.IsLTSC + ' iot=' + $o.IsIoT + ' arch=' + $o.Architecture)
Assert ($o.IsWin10 -or $o.IsWin11) 'OS build classified as Win10 or Win11'
Assert ($o.IsWin10 -xor $o.IsWin11) 'OS build is exactly one of Win10/Win11'
Assert ($o.IsWin10LTSC -eq ($o.IsWin10 -and ($o.IsLTSC -or $o.IsIoT))) 'IsWin10LTSC consistent with base flags'
Assert ($o.IsWin11LTSC -eq ($o.IsWin11 -and ($o.IsLTSC -or $o.IsIoT))) 'IsWin11LTSC consistent with base flags'

$m = Get-TweakMatrix
Write-Host ('Matrix count=' + $m.Count)
Assert ($m.Count -ge 1) 'tweak matrix loaded'
foreach ($t in $m) {
  $act = Get-TweakAction -TweakName $t.Name
  Assert ($null -ne $act) ('tweak ' + $t.Name + ' has an action')
}
$unknown = Apply-Tweak -TweakName 'Nope'
Assert ($unknown.Success -eq $false) 'unknown tweak rejected'

# nested PSCustomObject merge (ConvertFrom-Json shape)
$base = '{"a":{"b":1,"c":2},"arr":[1,2]}' | ConvertFrom-Json
$over = '{"a":{"c":9,"d":4},"arr":[3]}' | ConvertFrom-Json
$merged = Merge-Config -Base $base -Override $over
Assert ($merged.a.b -eq 1 -and $merged.a.c -eq 9 -and $merged.a.d -eq 4 -and $merged.arr[0] -eq 3) 'deep merge nested objects, replace arrays'

# hashtable/dictionary merge (Test-JsonObject must accept dictionaries)
$hb = @{ a = @{ b = 1; c = 2 } }
$ho = @{ a = @{ c = 9; d = 4 } }
Assert ((Test-JsonObject $hb) -eq $true) 'Test-JsonObject accepts hashtable'
$hm = Merge-Config -Base $hb -Override $ho
Assert ($hm.a.b -eq 1 -and $hm.a.c -eq 9 -and $hm.a.d -eq 4) 'deep merge hashtables'

# dns probe may legitimately return nothing when offline; only assert the shape when it answers
$best = Resolve-DnsBest -TimeoutSec 1
if ($best) {
  Assert ($best.Provider -and $best.Servers.Count -ge 1) ('Resolve-DnsBest shape (' + $best.Provider + ' ' + $best.LatencyMs + 'ms)')
} else { Write-Host '  info: dns best=none (offline ok)' }

# Write-Log must not throw under StrictMode when $global:LogFile is unset
try { Write-Log -Message 'smoke' -Level INFO; Assert $true 'Write-Log runs with unset $global:LogFile' }
catch { Assert $false ('Write-Log threw: ' + $_.Exception.Message) }

if ($fails.Count -eq 0) { Write-Host 'ALL OK'; exit 0 }
Write-Host ('FAILURES: ' + $fails.Count); exit 1
