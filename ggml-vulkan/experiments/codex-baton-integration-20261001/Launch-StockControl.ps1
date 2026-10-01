param([switch]$SingleDie,[int]$Tokens=32,[switch]$DisableCache,[string]$DeviceSelection='Vulkan0,Vulkan1',[string]$TensorSplit='1,1',[switch]$DisablePipelineParallel,[string]$RunTag='',[int]$LogVerbosity=-1)
$ErrorActionPreference='Stop'
$runtimeDir='C:\dev\V340L-Emancipated\scratch\codex-baton-20261001\runtime'
$taskDir='C:\dev\V340L-Emancipated\scratch\codex-baton-integration-20261001'
$expectedHash='AE67DDD85CC9C0E777FA76368E1A63AD90DDD4B97709CBC5C46F734F97C5248E'
if((Get-FileHash -LiteralPath (Join-Path $runtimeDir 'ggml-vulkan.dll')).Hash -ne $expectedHash){throw 'Wrong Vulkan DLL'}
$interop=& 'C:\dev\V340L-Emancipated\src\New-WindowsFunctionPointerBinder.ps1'
$env:PATH="$runtimeDir;$env:PATH"
$ggml=$interop.LoadLibrary((Join-Path $runtimeDir 'ggml.dll'))
$cli=$interop.LoadLibrary((Join-Path $runtimeDir 'llama-cli-impl.dll'))
$load=$interop.GetCall($interop.GetExport($ggml,'ggml_backend_load_all_from_path'),[void],@([IntPtr]))
$runtimePtr=[Runtime.InteropServices.Marshal]::StringToCoTaskMemUTF8($runtimeDir)
$load.Invoke($runtimePtr)
$entry=$interop.GetCall($interop.GetExport($cli,'?llama_cli@@YAHHPEAPEAD@Z'),[int],@([int],[IntPtr]))
$devices=if($SingleDie){$DeviceSelection.Split(',')[0]}else{$DeviceSelection}
$split=if($SingleDie){'1'}else{$TensorSplit}
$cliArgs=@('llama-cli.exe','-m','C:\Models\gemma-4-E4B-it-Q4_K_M.gguf','-ngl','999','-dev',$devices,'-sm','layer','-ts',$split,'-c','512','-p','The capital of France is','-n',"$Tokens",'-s','1234','--temp','0','--ignore-eos','--perf','--no-warmup','--simple-io','--single-turn','--no-display-prompt','--log-file',(Join-Path $taskDir "stock-$($devices.Replace(',','-'))-native.log"))
if($DisableCache){$cliArgs+=@('--ctx-checkpoints','0','--cache-ram','0')}
if($DisablePipelineParallel){$cliArgs+=@('--override-tensor','DummyIDontExist=CPU')}
if($LogVerbosity -ge 0){$cliArgs+=@('--log-verbosity',"$LogVerbosity")}
if($RunTag){$logIndex=[Array]::IndexOf($cliArgs,'--log-file')+1;$cliArgs[$logIndex]=Join-Path $taskDir "stock-$RunTag-native.log"}
$pointers=@($cliArgs | ForEach-Object {[Runtime.InteropServices.Marshal]::StringToCoTaskMemUTF8($_)})
$argv=[Runtime.InteropServices.Marshal]::AllocHGlobal(($pointers.Count+1)*8)
for($i=0;$i -lt $pointers.Count;$i++){[Runtime.InteropServices.Marshal]::WriteIntPtr($argv,$i*8,$pointers[$i])}
[Runtime.InteropServices.Marshal]::WriteIntPtr($argv,$pointers.Count*8,[IntPtr]::Zero)
$exitCode=[int]$entry.DynamicInvoke([int]$pointers.Count,$argv)
$modules=@([Diagnostics.Process]::GetCurrentProcess().Modules | Where-Object ModuleName -Match '^(ggml|llama|mtmd|libomp)' | ForEach-Object {
 if((Split-Path $_.FileName) -ne $runtimeDir){throw "Wrong module path: $($_.FileName)"}
 [pscustomobject]@{Name=$_.ModuleName;Path=$_.FileName;SHA256=(Get-FileHash -LiteralPath $_.FileName).Hash}
})
$modules | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskDir "stock-$($devices.Replace(',','-'))-loaded-modules.json")
$receiptName=if($RunTag){"stock-$RunTag-$Tokens-token-receipt.json"}else{"stock-$($devices.Replace(',','-'))-$Tokens-token-receipt.json"}
[pscustomobject]@{ExitCode=$exitCode;DeviceSelection=$devices;RequestedTokens=$Tokens;Mutation=$false;DummyTensorOverride=[bool]$DisablePipelineParallel;Arguments=$cliArgs} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $taskDir $receiptName)
if($exitCode -ne 0){throw "CLI exit $exitCode"}
