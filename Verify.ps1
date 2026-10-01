[CmdletBinding()]
param([string]$OutputDirectory=(Join-Path $PSScriptRoot 'output'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$started=[DateTime]::UtcNow
$probe=@(& (Join-Path $PSScriptRoot 'Probe-DirectMLV340.ps1'))
$gemm=@(& (Join-Path $PSScriptRoot 'Test-DirectMLGemm.ps1'))
$receipt=[ordered]@{schemaVersion=1;startedUtc=$started.ToString('o');finishedUtc=[DateTime]::UtcNow.ToString('o');powerShell=$PSVersionTable.PSVersion.ToString();probe=$probe;gemm=$gemm}
$path=Join-Path $OutputDirectory ("enablement-{0}.json" -f $started.ToString('yyyyMMdd-HHmmss-fff'))
$receipt | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding utf8
[pscustomobject]@{Receipt=$path;ProbeResults=$probe.Count;GemmResults=$gemm.Count}
