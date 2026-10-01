<#
.SYNOPSIS
    Automates Microsoft PIX GPU Timing Capture for llama-bench on dual V340L dies.
#>

param(
    [string]$PixDir = "C:\Program Files\Microsoft PIX\2603.25",
    [string]$LlamaBin = "C:\bin\llama.cpp\llama-bench.exe",
    [string]$Model = "C:\Models\gemma-4-E4B-it-Q4_K_M.gguf",
    [string]$Devices = "Vulkan1/Vulkan2",
    [int]$GenTokens = 8,
    [int]$DurationMs = 4000,
    [string]$OutputPath = "C:\dev\v340l_gemma_dual_die_timing.wpix"
)

$ErrorActionPreference = "Stop"

$pixtool = Join-Path $PixDir "pixtool.exe"
if (-not (Test-Path $pixtool)) {
    throw "pixtool.exe not found at $pixtool"
}

if (-not (Test-Path $LlamaBin)) {
    throw "llama-bench not found at $LlamaBin"
}

if (-not (Test-Path $Model)) {
    throw "Model not found at $Model"
}

if (Test-Path $OutputPath) {
    Remove-Item $OutputPath -Force
}

$llamaArgs = "-m $Model -n $GenTokens -p 0 -ngl 99 -dev $Devices"
Write-Host "[*] Executable: $LlamaBin" -ForegroundColor Cyan
Write-Host "[*] Arguments : $llamaArgs" -ForegroundColor Cyan
Write-Host "[*] Output    : $OutputPath" -ForegroundColor Cyan
Write-Host "[*] Duration  : $DurationMs ms" -ForegroundColor Cyan

# Launch pixtool with timing capture
$pixArgs = @(
    "launch",
    "`"$LlamaBin`"",
    "--timing",
    "--command-line=`"$llamaArgs`"",
    "take-new-timing-capture",
    "`"$OutputPath`"",
    "--duration=$DurationMs"
)

Write-Host "[*] Starting PIX Timing Capture..." -ForegroundColor Yellow
$proc = Start-Process -FilePath $pixtool -ArgumentList $pixArgs -NoNewWindow -PassThru -Wait

Write-Host "[*] PIX exited with code $($proc.ExitCode)" -ForegroundColor Green

if (Test-Path $OutputPath) {
    $item = Get-Item $OutputPath
    Write-Host "[+] SUCCESS: Timing capture saved! Size: $($item.Length) bytes ($([math]::Round($item.Length/1MB, 2)) MB)" -ForegroundColor Green
} else {
    Write-Host "[-] WARNING: Capture file not found at $OutputPath" -ForegroundColor Red
}
