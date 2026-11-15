<#
.SYNOPSIS
  CatFlapRelay throughput benchmark: iperf3 direct baseline vs. through relay.

.EXAMPLE
  pwsh tools/bench/Run-Throughput.ps1
  pwsh tools/bench/Run-Throughput.ps1 -Duration 10 -Runs 1 -BufferSizes 65536   # quick smoke test
  pwsh tools/bench/Run-Throughput.ps1 -Skip Udp,Sweep
#>
[CmdletBinding()]
param(
    [int]$Duration = 15,                       # seconds per iperf3 run
    [int]$Runs = 3,                            # repeats per scenario (median reported)
    [string[]]$Streams = @('1', '4', '16'),    # TCP parallel streams (comma list ok: -Streams 1,4)
    [string[]]$BufferSizes = @('16384', '65536', '131072', '524288'),  # --buffer-size sweep
    [int]$DefaultBuffer = 131072,
    [string]$UdpBandwidth = '1G',              # UDP offered load per run
    [int]$UdpPayload = 1200,
    [string]$BindIp = '127.0.0.1',
    [int]$ServerPort = 5201,
    [int]$RelayPort = 5202,
    [string[]]$Skip = @(),                     # any of: Tcp, Udp, Sweep
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
# -File passes '1,4' as one string; normalise to int arrays / string list
$Streams = @($Streams | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { [int]$_ })
$BufferSizes = @($BufferSizes | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { [int]$_ })
$Skip = @($Skip | ForEach-Object { $_ -split ',' })
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$iperf = Join-Path $root 'iperf3.22\iperf3.exe'
if (-not (Test-Path $iperf)) { throw "iperf3 not found: $iperf" }
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'results' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

Write-Host '==> Building CLI (Release)...'
dotnet build (Join-Path $root 'CatFlapRelay.CLI') -c Release -v q -nologo | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'build failed' }
$cli = Get-ChildItem (Join-Path $root 'CatFlapRelay.CLI\bin\Release') -Recurse -Filter 'catflaprelay-cli.exe' |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $cli) { throw 'catflaprelay-cli.exe not found' }

function Start-Relay([int]$Buffer) {
    Start-Process $cli -PassThru -WindowStyle Hidden -ArgumentList @(
        '--listen', "${BindIp}:$RelayPort", '--target', "${BindIp}:$ServerPort",
        '--buffer-size', $Buffer, '--log-level', 'Error')
    Start-Sleep -Milliseconds 1500
}

function Start-Server {
    Start-Process $iperf -PassThru -WindowStyle Hidden -ArgumentList @('-s', '-p', $ServerPort, '-B', $BindIp)
}

function Stop-Proc($p) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force } }

function Invoke-Iperf([int]$Port, [string[]]$Extra) {
    $json = & $iperf -c $BindIp -p $Port -t $Duration -J @Extra 2>&1 | Out-String
    $j = $json | ConvertFrom-Json
    if ($j.error) { throw "iperf3: $($j.error)" }
    $e = $j.end
    if ($Extra -contains '-u') {
        # e.sum is the sender-side view (sender=true); the receiver's numbers are in
        # sum_received, and the loss reported by the server is e.sum.lost_percent.
        [pscustomobject]@{
            Mbps     = $e.sum_received.bits_per_second / 1e6   # goodput actually received
            SentMbps = $e.sum_sent.bits_per_second / 1e6
            Loss     = $e.sum.lost_percent
        }
    } else {
        $s = if ($e.sum_received) { $e.sum_received } else { $e.sum }
        [pscustomobject]@{ Mbps = $s.bits_per_second / 1e6; SentMbps = $null; Loss = $null }
    }
}

function Measure-Scenario([string]$Label, [int]$Port, [string[]]$Extra) {
    $rs = @()
    foreach ($i in 1..$Runs) {
        # iperf3 serves one test at a time and the relay may still hold the previous
        # connection open, so restart the server for every run.
        Stop-Proc $script:server; $script:server = Start-Server; Start-Sleep -Milliseconds 800
        try { $rs += Invoke-Iperf $Port $Extra }
        catch { Write-Warning "$Label run ${i}: $($_.Exception.Message)" }
        Start-Sleep -Seconds 1
    }
    if ($rs.Count -eq 0) {
        Write-Host ("    {0,-28} {1,10}" -f $Label, 'FAILED')
        return [pscustomobject]@{ Scenario = $Label; Mbps = $null; SentMbps = $null; LossPct = $null }
    }
    # median of every column (mixing median and mean made the UDP rows self-contradictory)
    function Get-Median($v) { $v = @($v | Sort-Object); $v[[int][math]::Floor($v.Count / 2)] }
    $med = Get-Median $rs.Mbps
    $sent = if ($null -ne $rs[0].SentMbps) { [math]::Round((Get-Median $rs.SentMbps), 0) } else { $null }
    $loss = if ($null -ne $rs[0].Loss) { [math]::Round((Get-Median $rs.Loss), 2) } else { $null }
    $lossTxt = if ($null -ne $loss) { "  (sent $sent Mbps, loss $loss%)" } else { '' }
    Write-Host ("    {0,-28} {1,10:N0} Mbps recv{2}" -f $Label, $med, $lossTxt)
    [pscustomobject]@{ Scenario = $Label; Mbps = [math]::Round($med, 0); SentMbps = $sent; LossPct = $loss }
}

# UDP floods can wedge the relay's UDP path; give every UDP scenario a fresh relay.
function Measure-UdpRelay([string]$Label, [string[]]$Extra) {
    $script:relay = Start-Relay $DefaultBuffer
    try { Measure-Scenario $Label $RelayPort $Extra } finally { Stop-Proc $script:relay; $script:relay = $null }
}

$results = @()
$server = $null; $relay = $null
try {
    $server = Start-Server
    Start-Sleep -Milliseconds 800

    # ---------- TCP / UDP: baseline vs relay (default buffer) ----------
    $relay = Start-Relay $DefaultBuffer
    if ('Tcp' -notin $Skip) {
        Write-Host "`n==> TCP (buffer=$DefaultBuffer)"
        foreach ($n in $Streams) {
            $d = Measure-Scenario "TCP P=$n direct" $ServerPort @('-P', $n)
            $r = Measure-Scenario "TCP P=$n relay"  $RelayPort  @('-P', $n)
            $results += $d, $r
        }
        Write-Host "`n==> TCP reverse (server -> client), P=4"
        $results += Measure-Scenario 'TCP P=4 -R direct' $ServerPort @('-P', 4, '-R')
        $results += Measure-Scenario 'TCP P=4 -R relay'  $RelayPort  @('-P', 4, '-R')
    }
    if ('Udp' -notin $Skip) {
        Write-Host "`n==> UDP (offered $UdpBandwidth, payload $UdpPayload B)"
        $results += Measure-Scenario 'UDP direct' $ServerPort @('-u', '-b', $UdpBandwidth, '-l', $UdpPayload)
        Stop-Proc $relay; $relay = $null
        $results += Measure-UdpRelay 'UDP relay' @('-u', '-b', $UdpBandwidth, '-l', $UdpPayload)
        $results += Measure-Scenario 'UDP 64B direct' $ServerPort @('-u', '-b', '200M', '-l', 64)
        $results += Measure-UdpRelay 'UDP 64B relay' @('-u', '-b', '200M', '-l', 64)
    }
    Stop-Proc $relay; $relay = $null

    # ---------- Buffer-size sweep ----------
    if ('Sweep' -notin $Skip) {
        Write-Host "`n==> Buffer-size sweep (TCP P=4)"
        foreach ($b in $BufferSizes) {
            $relay = Start-Relay $b
            $results += Measure-Scenario "TCP P=4 buf=$($b / 1024)K" $RelayPort @('-P', 4)
            Stop-Proc $relay; $relay = $null
        }
    }
}
finally {
    Stop-Proc $relay
    Stop-Proc $server
}

$csv = Join-Path $OutDir "throughput-$stamp.csv"
$results | Select-Object Scenario, Mbps, SentMbps, LossPct | Export-Csv $csv 
Write-Host "`n==> Summary"
$results | Select-Object Scenario, Mbps, SentMbps, LossPct | Format-Table -AutoSize
Write-Host "Saved: $csv"
