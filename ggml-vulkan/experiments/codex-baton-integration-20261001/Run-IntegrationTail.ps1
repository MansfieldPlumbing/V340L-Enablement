# Invoked in the audited launcher's scope after native devices and imports exist.
$integrationRoot = 'C:\dev\V340L-Emancipated\scratch\codex-baton-integration-20261001'
& (Join-Path $integrationRoot 'New-IntegrationAssembly.ps1') | Out-Host
$runtimeAsm=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $integrationRoot 'Codex.BatonRuntime.dll')))
$runtimeType=$runtimeAsm.GetType('Codex.BatonRuntime',$true)
function SetRuntimeField([string]$Name,$Value){$runtimeType.GetField($Name).SetValue($null,$Value)}
SetRuntimeField SourceDevice $dev0Obj.Dev
SetRuntimeField DestinationDevice $dev1Obj.Dev
SetRuntimeField DestinationBuffer $buf1
SetRuntimeField RealInit $initBackendDev0Ptr
SetRuntimeField RealCopy ([Runtime.InteropServices.Marshal]::ReadIntPtr($backend0,0x38))
SetRuntimeField RealGraph ([Runtime.InteropServices.Marshal]::ReadIntPtr($backend0,0x68))
$graphAddress=[Runtime.InteropServices.Marshal]::ReadIntPtr($backend0,0x68)
$stockModule=[Diagnostics.Process]::GetCurrentProcess().Modules | Where-Object ModuleName -eq 'ggml-vulkan.dll' | Select-Object -First 1
Write-Host ('BATCH_ABI: graphRva=0x{0:X}, moduleBase=0x{1:X}, context=0x{2:X}' -f ($graphAddress.ToInt64()-$stockModule.BaseAddress.ToInt64()),$stockModule.BaseAddress.ToInt64(),([Runtime.InteropServices.Marshal]::ReadIntPtr($backend0,0x90)).ToInt64())
if($CoarseDecode){
 if(($graphAddress.ToInt64()-$stockModule.BaseAddress.ToInt64()) -ne 0x36B0){throw 'Coarse batching graph ABI mismatch'}
 $abiBytes=[byte[]]::new(11)
 [Runtime.InteropServices.Marshal]::Copy([IntPtr]($stockModule.BaseAddress.ToInt64()+0x3F67),$abiBytes,0,11)
 if([Convert]::ToHexString($abiBytes) -ne '48F7A73001000048C1EA05'){throw 'Coarse batching divide-by-40 instruction mismatch'}
}
SetRuntimeField CoarseDecode ([int][bool]$CoarseDecode)
SetRuntimeField RealSync ([Runtime.InteropServices.Marshal]::ReadIntPtr($backend0,0x40))
SetRuntimeField RealEventSync ([Runtime.InteropServices.Marshal]::ReadIntPtr($dev0Obj.Dev,0x70))
SetRuntimeField NBytes $nbytesFnPtr
SetRuntimeField NativeBoundaryPhase $nativeBoundaryPhase
SetRuntimeField RealEventRecord ([Runtime.InteropServices.Marshal]::ReadIntPtr($backend0,0x70))
SetRuntimeField MaxEventRecords ([int]128)
SetRuntimeField EventRecords (Block (128*32))
SetRuntimeField ApertureCursor ([long]4096)
SetRuntimeField ApertureCapacity ([long]$ApertureBytes)
SetRuntimeField MaxPublications ([int]$MaxPublications)
SetRuntimeField SingleDieMode ([int][bool]$SingleDie)
SetRuntimeField SourceQueue $baton0.Queue
SetRuntimeField DestinationQueue $baton1.Queue
SetRuntimeField QueueSubmit $pfnQueueSubmit
$fnGetDevQueue=$interop.GetCall($pfnGetDeviceQueue,[void],@([IntPtr],[uint32],[uint32],[IntPtr]))
$qTransferOut=Block 8
$fnGetDevQueue.Invoke($vkDev0,[uint32]$sourceQueueFamilies.Transfer,[uint32]0,$qTransferOut)
$qTransfer=[Runtime.InteropServices.Marshal]::ReadIntPtr($qTransferOut)
SetRuntimeField TransferQueue $qTransfer
foreach($pair in @(@{Field='BeginCommand';Name='vkBeginCommandBuffer'},@{Field='EndCommand';Name='vkEndCommandBuffer'},@{Field='CmdBarrier';Name='vkCmdPipelineBarrier'})){
 SetRuntimeField $pair.Field ($vkGetDeviceProcAddr.Invoke($vkDev0,$pair.Name))
}
if($GpuProfile){
 . 'C:\dev\V340L-Emancipated\scratch\codex-baton-integration-20261001\GpuStageTiming.ps1'
 $sourceTiming=NewGpuStageTiming $vkDev0 ([IntPtr]$shimType.GetField('CreatedPhysicalDevice0').GetValue($null)) $baton0.Queue $MaxPublications $sourceQueueFamilies.Compute
 $consumerTiming=NewGpuStageTiming $vkDev1 ([IntPtr]$shimType.GetField('CreatedPhysicalDevice1').GetValue($null)) $baton1.Queue $MaxPublications $consumerQueueFamilies.Compute
 SetRuntimeField SourceGpuSubmits $sourceTiming.Submits
 SetRuntimeField ConsumerGpuSubmits $consumerTiming.Submits
}
$ourPointers=@{}
foreach($spec in @(
 @{Method='HookInit';Delegate='InitCallback';Field=$null},
 @{Method='HookCopy';Delegate='CopyCallback';Field='HookCopyPtr'},
 @{Method='HookGraph';Delegate='GraphCallback';Field='HookGraphPtr'},
 @{Method='HookSync';Delegate='SyncCallback';Field='HookSyncPtr'},
 @{Method='HookEventSync';Delegate='EventSyncCallback';Field='HookEventSyncPtr'},
 @{Method='HookEventRecord';Delegate='EventSyncCallback';Field='HookEventRecordPtr'}
)){
 $method=$runtimeType.GetMethod($spec.Method)
 [Runtime.CompilerServices.RuntimeHelpers]::PrepareMethod($method.MethodHandle)
 $callback=[Delegate]::CreateDelegate($runtimeAsm.GetType('Codex.'+$spec.Delegate),$method)
 $rootedDelegates.Add($callback)
 $pointer=[Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($callback)
 $ourPointers[$spec.Method]=$pointer
 if($spec.Field){SetRuntimeField $spec.Field $pointer}
}
$nativeBufferContext=[Runtime.InteropServices.Marshal]::ReadIntPtr($buf0,0x60)
$nativeBufferObject=[Runtime.InteropServices.Marshal]::ReadIntPtr($nativeBufferContext,0x10)
$nativeAperture=[uint64][Runtime.InteropServices.Marshal]::ReadInt64($nativeBufferObject)
$configs=Block ($MaxPublications*72)
SetRuntimeField Configurations $configs
$poolCreate=$interop.GetCall($vkGetDeviceProcAddr.Invoke($vkDev0,'vkCreateCommandPool'),[int],@([IntPtr],[IntPtr],[IntPtr],[IntPtr]))
$allocateCmd=$interop.GetCall($vkGetDeviceProcAddr.Invoke($vkDev0,'vkAllocateCommandBuffers'),[int],@([IntPtr],[IntPtr],[IntPtr]))
$poolCI=Block 24; W32 $poolCI 0 39; W32 $poolCI 20 $sourceQueueFamilies.Compute
$poolOut=Block 8
CheckVK ($poolCreate.Invoke($vkDev0,$poolCI,[IntPtr]::Zero,$poolOut)) 'create ownership-return pool'
$pool=[uint64][Runtime.InteropServices.Marshal]::ReadInt64($poolOut)
$cmdAlloc=Block 32; W32 $cmdAlloc 0 40; W64 $cmdAlloc 16 $pool; W32 $cmdAlloc 28 $MaxPublications
$returnCommands=Block ($MaxPublications*8)
CheckVK ($allocateCmd.Invoke($vkDev0,$cmdAlloc,$returnCommands)) 'allocate unique ownership-return commands'
$begin=Block 32; W32 $begin 0 42; W32 $begin 16 1
# Pre-record consumer visibility commands; the hardware wait guards these commands.
$consumerPoolCreate=$interop.GetCall($vkGetDeviceProcAddr.Invoke($vkDev1,'vkCreateCommandPool'),[int],@([IntPtr],[IntPtr],[IntPtr],[IntPtr]))
$consumerAllocate=$interop.GetCall($vkGetDeviceProcAddr.Invoke($vkDev1,'vkAllocateCommandBuffers'),[int],@([IntPtr],[IntPtr],[IntPtr]))
$consumerBegin=$interop.GetCall($vkGetDeviceProcAddr.Invoke($vkDev1,'vkBeginCommandBuffer'),[int],@([IntPtr],[IntPtr]))
$consumerEnd=$interop.GetCall($vkGetDeviceProcAddr.Invoke($vkDev1,'vkEndCommandBuffer'),[int],@([IntPtr]))
$consumerBarrier=$interop.GetCall($vkGetDeviceProcAddr.Invoke($vkDev1,'vkCmdPipelineBarrier'),[void],@([IntPtr],[uint32],[uint32],[uint32],[uint32],[IntPtr],[uint32],[IntPtr],[uint32],[IntPtr]))
$consumerPoolOut=Block 8
$consumerPoolCI=Block 24; W32 $consumerPoolCI 0 39; W32 $consumerPoolCI 20 $consumerQueueFamilies.Compute
CheckVK ($consumerPoolCreate.Invoke($vkDev1,$consumerPoolCI,[IntPtr]::Zero,$consumerPoolOut)) 'create consumer visibility pool'
$consumerCmdAlloc=Block 32; W32 $consumerCmdAlloc 0 40; W64 $consumerCmdAlloc 16 ([uint64][Runtime.InteropServices.Marshal]::ReadInt64($consumerPoolOut)); W32 $consumerCmdAlloc 28 $MaxPublications
$consumerCommands=Block ($MaxPublications*8)
CheckVK ($consumerAllocate.Invoke($vkDev1,$consumerCmdAlloc,$consumerCommands)) 'allocate consumer visibility commands'
$consumerMemoryBarrier=Block 24; W32 $consumerMemoryBarrier 0 46; W32 $consumerMemoryBarrier 20 0x20
for($visibilitySlot=0;$visibilitySlot -lt $MaxPublications;$visibilitySlot++){
 $visibilityCommand=[Runtime.InteropServices.Marshal]::ReadIntPtr($consumerCommands,$visibilitySlot*8)
 CheckVK ($consumerBegin.Invoke($visibilityCommand,$begin)) 'begin consumer visibility command'
 $consumerBarrier.Invoke($visibilityCommand,[uint32]1,[uint32]0x800,[uint32]0,[uint32]1,$consumerMemoryBarrier,[uint32]0,[IntPtr]::Zero,[uint32]0,[IntPtr]::Zero)
 CheckVK ($consumerEnd.Invoke($visibilityCommand)) 'end consumer visibility command'
}
$publisherTypes=[Collections.Generic.List[object]]::new()
if($TransferProfile){
 & (Join-Path $integrationRoot 'New-Publisher-Timing.ps1') | Out-Host
 $publisherBytes=[IO.File]::ReadAllBytes((Join-Path $integrationRoot 'Publisher-Timing.dll'))
 $transferQueryCreate=$interop.GetCall($vkGetDeviceProcAddr.Invoke($vkDev0,'vkCreateQueryPool'),[int],@([IntPtr],[IntPtr],[IntPtr],[IntPtr]))
 $transferQueryRead=$interop.GetCall($vkGetDeviceProcAddr.Invoke($vkDev0,'vkGetQueryPoolResults'),[int],@([IntPtr],[uint64],[uint32],[uint32],[uint64],[IntPtr],[uint64],[uint32]))
 $transferQueryCI=Block 32; W32 $transferQueryCI 0 11; W32 $transferQueryCI 20 2; W32 $transferQueryCI 24 2
}else{$publisherBytes=[IO.File]::ReadAllBytes((Join-Path $integrationRoot 'Publisher-OneShot.dll'))}
for($slot=0; $slot -lt $MaxPublications; $slot++){
 # Assembly.Load(byte[]) supplies an isolated static state for each one-shot publisher.
 $pubAsm=[Reflection.Assembly]::Load($publisherBytes)
 $pubType=$pubAsm.GetType('Antigravity.ProducerPublisher',$true)
 $publisherTypes.Add($pubType)
 $pubType.GetMethod('BindDefaultVulkanFunctions').Invoke($null,@()) | Out-Null
 if($TransferProfile){
  $transferQueryOut=Block 8
  CheckVK ($transferQueryCreate.Invoke($vkDev0,$transferQueryCI,[IntPtr]::Zero,$transferQueryOut)) 'create transfer timing queries'
  $pubType.GetField('TimingQueryPool').SetValue($null,[uint64][Runtime.InteropServices.Marshal]::ReadInt64($transferQueryOut))
  $pubType.GetField('TimingWriteTimestamp').SetValue($null,$vkGetDeviceProcAddr.Invoke($vkDev0,'vkCmdWriteTimestamp'))
  $pubType.GetField('TimingResetQueries').SetValue($null,$vkGetDeviceProcAddr.Invoke($vkDev0,'vkCmdResetQueryPool'))
 }
 # Each boundary uses the proven fresh native-fence payload: signal/wait value 1.
 $slotFenceOut=Block 8
 CheckHR ($createFenceD3D.DynamicInvoke($d3dDev0,[uint64]0,[uint32]3,$iidFence,$slotFenceOut)) "create boundary fence $slot"
 $slotFence=Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($slotFenceOut))
 $slotHandleOut=Block 8
 CheckHR ($createShared.DynamicInvoke($d3dDev0,$slotFence,[IntPtr]::Zero,[uint32]0x10000000,[IntPtr]::Zero,$slotHandleOut)) "share boundary fence $slot"
 $sharedFenceHandle=[Runtime.InteropServices.Marshal]::ReadIntPtr($slotHandleOut)
 $slotBaton0=Setup-DeviceBaton $vkDev0 $sourceQueueFamilies.Compute
 $slotBaton1=Setup-DeviceBaton $vkDev1 $consumerQueueFamilies.Compute
 $setupResult=$pubType.GetMethod('Setup').Invoke($null,@($vkDev0,$baton0.Queue,[int]$sourceQueueFamilies.Compute,$qTransfer,[int]$sourceQueueFamilies.Transfer,$nativeAperture,[uint64]$slotBaton0.Semaphore))
 CheckVK ([int]$setupResult) "publisher setup $slot"
 # VkD3D12FenceSubmitInfoKHR counts match all submit semaphores; the local
 # binary semaphore's value is ignored, but its zero entry is required.
 $producerFenceInfo=[IntPtr]$pubType.GetField('pD3D12FenceSubmitInfo').GetValue($null)
 $producerLocalWaitValue=Block 8
 W32 $producerFenceInfo 16 1
 WP $producerFenceInfo 24 $producerLocalWaitValue
 $callback=[Delegate]::CreateDelegate($pubAsm.GetType('Antigravity.PublishBatchCallback'),$pubType.GetMethod('PublishBatch'))
 $rootedDelegates.Add($callback)
 $config=[IntPtr]::Add($configs,$slot*72)
 WP $config 0 ([Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($callback))
 WP $config 8 $begin
 $returnCmd=[Runtime.InteropServices.Marshal]::ReadIntPtr($returnCommands,$slot*8)
 WP $config 16 $returnCmd
 $regions=Block (64*32); WP $config 32 $regions
 $returnSem=[uint64]$pubType.GetField('SemTransferToCompute').GetValue($null)
 $returnSemArray=Block 8; W64 $returnSemArray 0 $returnSem
 $returnStage=Block 4; W32 $returnStage 0 0x10000
 $returnCmdArray=Block 8; WP $returnCmdArray 0 $returnCmd
 $returnSubmit=Block 72; W32 $returnSubmit 0 4; W32 $returnSubmit 16 1; WP $returnSubmit 24 $returnSemArray; WP $returnSubmit 32 $returnStage; W32 $returnSubmit 40 1; WP $returnSubmit 48 $returnCmdArray; WP $config 24 $returnSubmit
 $signalReturnSubmit=Block 72; W32 $signalReturnSubmit 0 4; W32 $signalReturnSubmit 56 1; WP $signalReturnSubmit 64 $returnSemArray; WP $config 48 $signalReturnSubmit
 $value=Block 8; W64 $value 0 1
 $consumerFenceInfo=Block 48; W32 $consumerFenceInfo 0 1000078002; W32 $consumerFenceInfo 16 1; WP $consumerFenceInfo 24 $value
 $consumerSem=Block 8; W64 $consumerSem 0 $slotBaton1.Semaphore
 $consumerStage=Block 4; W32 $consumerStage 0 0x10000
 $consumerSubmit=Block 72; W32 $consumerSubmit 0 4; WP $consumerSubmit 8 $consumerFenceInfo; W32 $consumerSubmit 16 1; WP $consumerSubmit 24 $consumerSem; WP $consumerSubmit 32 $consumerStage; W32 $consumerSubmit 40 1; WP $consumerSubmit 48 ([IntPtr]::Add($consumerCommands,$slot*8)); WP $config 40 $consumerSubmit
 $waitOut=Block 24; WP $config 56 $waitOut
 WP $config 64 ([IntPtr]$pubType.GetField('pTransferReturnBarriers').GetValue($null))
}
Write-Host "BATON: preallocated $MaxPublications distinct publisher/return command resources."
# Replace only the selected device callbacks; native DLL files remain untouched.
foreach($dev in @($dev0Obj.Dev,$dev1Obj.Dev)){
 [Runtime.InteropServices.Marshal]::WriteIntPtr($dev,0x28,$ourPointers.HookInit)
 [Runtime.InteropServices.Marshal]::WriteIntPtr($dev,0x70,$ourPointers.HookEventSync)
}
$modules=@([Diagnostics.Process]::GetCurrentProcess().Modules | Where-Object ModuleName -Match '^(ggml|llama|mtmd|libomp)' | ForEach-Object {
 if((Split-Path $_.FileName) -ne $RuntimeDir){throw "Unexpected native module: $($_.FileName)"}
 [pscustomobject]@{Name=$_.ModuleName;Path=$_.FileName;SHA256=(Get-FileHash -LiteralPath $_.FileName).Hash}
})
$modules | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $integrationRoot 'integration-loaded-modules.json')
$entry=$interop.GetCall($interop.GetExport($llamaCliLib,'?llama_cli@@YAHHPEAPEAD@Z'),[int],@([int],[IntPtr]))
$selectedCliDevices=if($SingleDie){$dev0Obj.Name}else{"$($dev0Obj.Name),$($dev1Obj.Name)"}
$selectedCliSplit=if($SingleDie){'1'}else{$TensorSplit.Replace('/',',')}
$cliArgs=@('llama-cli.exe','-m',$Model,'-ngl','999','-dev',$selectedCliDevices,'-sm','layer','-ts',$selectedCliSplit,'-c','512','-p',$Prompt,'-n',"$Tokens",'-s','1234','--temp','0','--ignore-eos','--perf','--no-warmup','--simple-io','--single-turn','--no-display-prompt','--log-file',(Join-Path $integrationRoot 'native-inference.log'))
if($DisablePipelineParallel){$cliArgs+=@('--override-tensor','DummyIDontExist=CPU')}
if($LogVerbosity -ge 0){$cliArgs+=@('--log-verbosity',"$LogVerbosity")}
if($RunTag){$logIndex=[Array]::IndexOf($cliArgs,'--log-file')+1;$cliArgs[$logIndex]=Join-Path $integrationRoot "integration-$RunTag-native.log"}
$argvPointers=@($cliArgs | ForEach-Object {[Runtime.InteropServices.Marshal]::StringToCoTaskMemUTF8($_)})
$argv=Block (($argvPointers.Count+1)*8)
for($i=0;$i -lt $argvPointers.Count;$i++){WP $argv ($i*8) $argvPointers[$i]}
Write-Host 'BATON: starting deterministic inference with default F16 KV.'
$exitCode=[int]$entry.DynamicInvoke([int]$argvPointers.Count,$argv)
$counts=[ordered]@{}
foreach($name in @('PublicationCount','PendingCount','HandledCopies','BlockedBoundaryWaits','OtherCopies','SourceGraphs','DestinationGraphs','AllowedSyncs','EventRecordCount','DeferredCompletedEventCleanups')){$counts[$name]=$runtimeType.GetField($name).GetValue($null)}
$nativeCounts=[ordered]@{}
foreach($name in @('BoundaryWaitRequests','ResolveHits','WaitForFencesCalls','WaitSemaphoresCalls','QueueWaitIdleCalls','DeviceWaitIdleCalls','WaitForFencesProfileCalls','WaitSemaphoresProfileCalls','QueueWaitIdleProfileCalls','DeviceWaitIdleProfileCalls','SourceDispatchCalls','ConsumerDispatchCalls','SourceIndirectDispatchCalls','ConsumerIndirectDispatchCalls','SourceSubmitCalls','ConsumerSubmitCalls')){$nativeCounts[$name]=$nativeAuditType.GetField($name).GetValue($null)}
foreach($name in @('WaitForFencesTicks','WaitSemaphoresTicks','QueueWaitIdleTicks','DeviceWaitIdleTicks','SourceWorkgroups','ConsumerWorkgroups','SourceSubmitTicks','ConsumerSubmitTicks')){if($name -like '*Ticks'){$nativeCounts[$name.Replace('Ticks','Milliseconds')]=1000.0*[long]$nativeAuditType.GetField($name).GetValue($null)/[Diagnostics.Stopwatch]::Frequency}else{$nativeCounts[$name]=$nativeAuditType.GetField($name).GetValue($null)}}
$counts['NativeWaitAudit']=$nativeCounts
$phaseAudit=[ordered]@{}
foreach($apiName in @('WaitForFences','WaitSemaphores','QueueWaitIdle','DeviceWaitIdle','GetFenceStatus')){
 foreach($phaseIndex in 0..3){
  $fieldName=$apiName+'Phase'+$phaseIndex
  $phaseAudit[$fieldName]=[ordered]@{Calls=$nativeAuditType.GetField($fieldName+'Calls').GetValue($null);Milliseconds=1000.0*[long]$nativeAuditType.GetField($fieldName+'Ticks').GetValue($null)/[Diagnostics.Stopwatch]::Frequency}
 }
}
$counts['WaitPhaseAudit']=$phaseAudit
$cpuTimings=[ordered]@{}
foreach($name in @('SourceGraphTicks','ConsumerGraphTicks','PublicationTicks')){$cpuTimings[$name.Replace('Ticks','Milliseconds')]=1000.0*[long]$runtimeType.GetField($name).GetValue($null)/[Diagnostics.Stopwatch]::Frequency}
$counts['CpuCallTimings']=$cpuTimings
if($GpuProfile){$counts['GpuSourceStage']=ReadGpuStageTiming $sourceTiming $counts.SourceGraphs; if(-not $SingleDie){$counts['GpuConsumerStage']=ReadGpuStageTiming $consumerTiming $counts.DestinationGraphs}}
if($TransferProfile){
 if(-not $GpuProfile){throw 'TransferProfile requires GpuProfile to obtain the measured timestamp period'}
 $transferRows=@(for($slot=0;$slot -lt $counts.PublicationCount;$slot++){
  $pubType=$publisherTypes[$slot]; $queryResults=Block 32
  CheckVK ($transferQueryRead.Invoke($vkDev0,[uint64]$pubType.GetField('TimingQueryPool').GetValue($null),[uint32]0,[uint32]2,[uint64]32,$queryResults,[uint64]16,[uint32]5)) 'read transfer timing without WAIT'
  if([Runtime.InteropServices.Marshal]::ReadInt64($queryResults,8) -eq 0 -or [Runtime.InteropServices.Marshal]::ReadInt64($queryResults,24) -eq 0){throw 'Transfer timestamps unavailable after terminal completion'}
  $start=[Runtime.InteropServices.Marshal]::ReadInt64($queryResults)
  $end=[Runtime.InteropServices.Marshal]::ReadInt64($queryResults,16)
  $regions=[Runtime.InteropServices.Marshal]::ReadIntPtr($configs,$slot*72+32)
  $regionCount=[int]$pubType.GetField('TimingRegionCount').GetValue($null)
  $payloadBytes=[long]0; for($regionIndex=0;$regionIndex -lt $regionCount;$regionIndex++){$payloadBytes+=[Runtime.InteropServices.Marshal]::ReadInt64($regions,$regionIndex*32+24)}
  $ms=($end-$start)*[double]$sourceTiming.TimestampPeriod/1000000.0
  $graphEnd=$counts.GpuSourceStage.Rows[$slot].End
  [pscustomobject]@{Publication=$slot;Regions=$regionCount;PayloadBytes=$payloadBytes;CopyMilliseconds=$ms;CopyGigabytesPerSecond=if($ms -gt 0){$payloadBytes/($ms*1000000.0)}else{$null};ProducerGraphEndToCopyStartMilliseconds=($start-$graphEnd)*[double]$sourceTiming.TimestampPeriod/1000000.0}
 })
 $counts['GpuTransfer']=$transferRows
}
$counts['DeviceSelection']=$selectedCliDevices
$counts['DummyTensorOverride']=[bool]$DisablePipelineParallel
$counts['CoarseDecode']=[bool]$CoarseDecode
$counts['CoarseDecodeGraphs']=$runtimeType.GetField('CoarseDecodeGraphs').GetValue($null)
$counts['MaxNodesPerSubmit']=$env:GGML_VK_MAX_NODES_PER_SUBMIT
$counts['Arguments']=$cliArgs
$counts['QueueFamilies']=[ordered]@{Source=$sourceQueueFamilies;Consumer=$consumerQueueFamilies}
$counts['ExitCode']=$exitCode
$counts['RequestedTokens']=$Tokens
$counts['StockVulkanSha256']=$actualVulkanHash
$counts['ApertureBytesUsed']=$runtimeType.GetField('ApertureCursor').GetValue($null)
$counts | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $integrationRoot $(if($RunTag){"integration-$RunTag-$Tokens-token-receipt.json"}else{"integration-$($selectedCliDevices.Replace(',', '-'))-$Tokens-token-receipt.json"}))
$counts | ConvertTo-Json -Depth 8 | Write-Host
if($exitCode -ne 0){throw "CLI exited $exitCode"}
