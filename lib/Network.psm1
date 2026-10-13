function Test-HostReachable {
  # PS 5.1 has no Test-Connection -TimeoutSeconds (that is PS 7+). use .NET ping
  # so the probe works on the target OS and never silently returns false.
  param([string]$Server, [int]$TimeoutSec = 2)
  try {
    $ping = New-Object System.Net.NetworkInformation.Ping
    $reply = $ping.Send($Server, [int]($TimeoutSec * 1000))
    return ($null -ne $reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
  } catch {
    return $false
  }
}

function Test-Online {
  param([int]$TimeoutSec = 2)
  return (Test-HostReachable -Server '8.8.8.8' -TimeoutSec $TimeoutSec)
}

$script:DnsProviders = [ordered]@{
  'Cloudflare' = @('1.1.1.1','1.0.0.1')
  'Google'     = @('8.8.8.8','8.8.4.4')
  'Quad9'      = @('9.9.9.9','149.112.112.112')
  'AdGuard'    = @('94.140.14.14','94.140.15.15')
}

function Test-DnsServer {
  param(
    [Parameter(Mandatory=$true)][string]$Server,
    [int]$TimeoutSec = 2
  )
  return (Test-HostReachable -Server $Server -TimeoutSec $TimeoutSec)
}

function Resolve-DnsBest {
  param([int]$TimeoutSec = 2)
  $best = $null
  $bestServer = $null
  foreach ($name in $script:DnsProviders.Keys) {
    $servers = $script:DnsProviders[$name]
    if (-not $servers -or $servers.Count -eq 0) { continue }
    $primary = $servers[0]
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = Test-DnsServer -Server $primary -TimeoutSec $TimeoutSec
    $sw.Stop()
    if (-not $ok) { continue }
    if ($null -eq $best -or $sw.ElapsedMilliseconds -lt $best) {
      $best = $sw.ElapsedMilliseconds
      $bestServer = $name
    }
  }
  if ($bestServer) {
    return @{ Provider = $bestServer; Servers = $script:DnsProviders[$bestServer]; LatencyMs = $best }
  }
  return $null
}

function Set-DNS {
  param(
    [string]$Provider = 'Cloudflare',
    [bool]$Auto = $false,
    [switch]$Reset
  )
  $dnsMap = @{}
  foreach ($k in $script:DnsProviders.Keys) { $dnsMap[$k] = $script:DnsProviders[$k] }
  $dnsMap['NextDNS'] = @('45.90.28.0','45.90.30.0')
  $dnsMap['DHCP'] = @()
  $dnsMap['Auto'] = @()

  if ($Auto -or $Provider -eq 'Auto') {
    $resolved = Resolve-DnsBest
    if ($resolved) { $Provider = $resolved.Provider } else { $Provider = 'DHCP' }
  }
  if ($Reset -or $Provider -eq 'DHCP') {
    try {
      foreach ($a in (Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })) {
        Set-DnsClientServerAddress -InterfaceAlias $a.Name -ResetServerAddresses -ErrorAction SilentlyContinue
      }
      return $true
    } catch { return $false }
  }
  if (-not $dnsMap.ContainsKey($Provider)) { $Provider = 'Cloudflare' }
  $servers = $dnsMap[$Provider]
  if (-not $servers -or $servers.Count -eq 0) { return $false }
  try {
    foreach ($a in (Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })) {
      Set-DnsClientServerAddress -InterfaceAlias $a.Name -ServerAddresses $servers -ErrorAction SilentlyContinue
    }
    return $true
  } catch {
    return $false
  }
}

function Set-NextDns {
  # NextDNS anycast resolver. A config Id only changes behavior over DoH/DoT;
  # plain IPs always work, so we apply the anycast pair regardless of Id.
  param(
    [string]$Id = '',
    [string[]]$Servers = @('45.90.28.0','45.90.30.0')
  )
  try {
    foreach ($a in (Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })) {
      Set-DnsClientServerAddress -InterfaceAlias $a.Name -ServerAddresses $servers -ErrorAction SilentlyContinue
    }
    return $true
  } catch { return $false }
}

Export-ModuleMember -Function Test-Online, Test-DnsServer, Resolve-DnsBest, Set-DNS, Set-NextDns
