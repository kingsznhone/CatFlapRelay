<#
.SYNOPSIS
  Compare UDP relay capacity for different --udp-senders values using the UdpLoad generator
  (many source ports, per-flow sequence numbers => loss and out-of-order counts).

.EXAMPLE
  pwsh tools/bench/Run-UdpSenders.ps1
  pwsh tools/bench/Run-UdpSenders.ps1 -Senders 1,4 -Flows 16 -Pps 300000
  pwsh tools/bench/Run-UdpSenders.ps1 -BaselineCli C:\tmp\oldrepo\...\catflaprelay-cli.exe   # A/B against another build
#>
[CmdletBinding()]
param(
    [string[]]$Senders = @('1', '2', '4', '8'),
    [int]$Flows = 8,
    [int]$Payload = 64,
    [int]$Pps = 200000,
    [int]$Duration = 6,
    [int]$Runs = 2,
    [string]$BaselineCli,
    [string]$BindIp = '127.0.0.1',
    [int]$SinkPort = 5201,
    [int]$RelayPort = 5202
)
$ErrorActionPreference = 'Stop'
$Senders = @($Senders | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { [int]$_ })
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')

dotnet build (Join-Path $root 'CatFlapRelay.CLI') -c Release -v q -nologo | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'CLI build failed' }
dotnet build (Join-Path $PSScriptRoot 'UdpLoad') -c Release -v q -nologo | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'UdpLoad build failed' }
$cli = Get-ChildItem (Join-Path $root 'CatFlapRelay.CLI\bin\Release') -Recurse -Filter 'catflaprelay-cli.exe' | Select-Object -First 1 -ExpandProperty FullName
$load = Join-Path $PSScriptRoot 'UdpLoad\bin\Release\net10.0\UdpLoad.dll'

function Invoke-One([string]$Label, [string]$Exe, [string[]]$RelayExtra) {
    $relay = Start-Process $Exe -PassThru -WindowStyle Hidden -ArgumentList (@(
            '--listen', "${BindIp}:$RelayPort", '--target', "${BindIp}:$SinkPort", '--log-level', 'Error') + $RelayExtra)
    Start-Sleep -Milliseconds 1500
    try {
        $out = dotnet $load --sink "${BindIp}:$SinkPort" --target "${BindIp}:$RelayPort" --flows $Flows `
            --payload $Payload --pps $Pps --duration $Duration
        Write-Host ("  {0,-12} {1}" -f $Label, ($out -replace '^flows=\d+ payload=\d+B target=[\d,]+pps \| ', ''))
    }
    finally { Stop-Process -Id $relay.Id -Force -ErrorAction SilentlyContinue }
}

Write-Host "Flows=$Flows Payload=${Payload}B Offered=$($Pps.ToString('N0')) pps Duration=${Duration}s Runs=$Runs"
foreach ($r in 1..$Runs) {
    Write-Host "run ${r}:"
    if ($BaselineCli) { Invoke-One 'baseline' $BaselineCli @() }
    foreach ($n in $Senders) { Invoke-One "senders=$n" $cli @('--udp-senders', $n) }
}
