<#
.SYNOPSIS
  Collect runtime counters (and optionally a CPU trace) of the relay process while iperf3 floods UDP through it.
  Requires: pwsh tools/bench/.tools has dotnet-counters (and dotnet-trace for -Trace).

.EXAMPLE
  pwsh tools/bench/Profile-Udp.ps1
  pwsh tools/bench/Profile-Udp.ps1 -Payload 64 -Bandwidth 200M -Trace
#>
[CmdletBinding()]
param(
    [int]$Duration = 12,
    [int]$Payload = 1200,
    [string]$Bandwidth = '1G',
    [switch]$Trace,
    [string]$BindIp = '127.0.0.1',
    [int]$ServerPort = 5201,
    [int]$RelayPort = 5202,
    [string]$OutDir
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$iperf = Join-Path $root 'iperf3.22\iperf3.exe'
$tools = Join-Path $PSScriptRoot '.tools'
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'results' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

dotnet build (Join-Path $root 'CatFlapRelay.CLI') -c Release -v q -nologo | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'build failed' }
$cli = Get-ChildItem (Join-Path $root 'CatFlapRelay.CLI\bin\Release') -Recurse -Filter 'catflaprelay-cli.exe' | Select-Object -First 1 -ExpandProperty FullName

$server = Start-Process $iperf -PassThru -WindowStyle Hidden -ArgumentList @('-s', '-p', $ServerPort, '-B', $BindIp)
$relay = Start-Process $cli -PassThru -WindowStyle Hidden -ArgumentList @(
    '--listen', "${BindIp}:$RelayPort", '--target', "${BindIp}:$ServerPort", '--log-level', 'Error')
Start-Sleep -Seconds 2
$counters = $null; $tracer = $null
try {
    $csv = Join-Path $OutDir "udp-counters-$stamp.csv"
    $counters = Start-Process (Join-Path $tools 'dotnet-counters.exe') -PassThru -WindowStyle Hidden -ArgumentList @(
        'collect', '-p', $relay.Id, '--format', 'csv', '-o', $csv, '--refresh-interval', 1,
        '--counters', 'System.Runtime')
    if ($Trace) {
        $nettrace = Join-Path $OutDir "udp-trace-$stamp.nettrace"
        $tracer = Start-Process (Join-Path $tools 'dotnet-trace.exe') -PassThru -WindowStyle Hidden -ArgumentList @(
            'collect', '-p', $relay.Id, '--profile', 'dotnet-sampled-thread-time', '-o', $nettrace,
            '--duration', ('00:00:{0:00}' -f ($Duration + 2)))
    }
    Start-Sleep -Seconds 3   # let the collectors attach
    $out = & $iperf -c $BindIp -p $RelayPort -u -b $Bandwidth -l $Payload -t $Duration -J | Out-String | ConvertFrom-Json
    $e = $out.end
    Write-Host ("iperf3: sent {0:N0} Mbps, recv {1:N0} Mbps, loss {2}%" -f ($e.sum_sent.bits_per_second / 1e6), ($e.sum_received.bits_per_second / 1e6), $e.sum.lost_percent)
    Start-Sleep -Seconds 2
}
finally {
    foreach ($p in @($counters, $tracer)) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
    if ($tracer) { Start-Sleep 2 }
    Stop-Process -Id $relay.Id -Force -ErrorAction SilentlyContinue
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
}

# Summarise counters: peak / mean of the interesting ones
if (Test-Path $csv) {
    $rows = Import-Csv $csv
    $names = 'CPU Usage (%)', 'Allocation Rate (B / 1 sec)', 'GC Heap Size (MB)', 'ThreadPool Thread Count', 'ThreadPool Queue Length',
             'Gen 0 GC Count (Count / 1 sec)', 'Gen 1 GC Count (Count / 1 sec)', 'Gen 2 GC Count (Count / 1 sec)', 'Monitor Lock Contention Count (Count / 1 sec)'
    $rows | Group-Object 'Counter Name' | Where-Object { $_.Name -in $names } | ForEach-Object {
        $v = $_.Group | ForEach-Object { [double]$_.'Counter Value' }
        [pscustomobject]@{ Counter = $_.Name; Mean = [math]::Round(($v | Measure-Object -Average).Average, 1); Max = [math]::Round(($v | Measure-Object -Maximum).Maximum, 1) }
    } | Format-Table -AutoSize
    Write-Host "Counters: $csv"
}
if ($Trace) { Write-Host "Trace: $nettrace" }
