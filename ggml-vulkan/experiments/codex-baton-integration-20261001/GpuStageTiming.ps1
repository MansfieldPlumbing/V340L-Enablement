# Diagnostic timestamp resources. No WAIT result flags and no CPU polling.
function NewGpuStageTiming([IntPtr]$Device,[IntPtr]$Physical,[IntPtr]$Queue,[int]$Count,[int]$QueueFamily=1){
 $api=@{}
 foreach($spec in @(
 @{Name='vkCreateQueryPool';Ret=[int];Params=[Type[]]@([IntPtr],[IntPtr],[IntPtr],[IntPtr])},
 @{Name='vkCreateCommandPool';Ret=[int];Params=[Type[]]@([IntPtr],[IntPtr],[IntPtr],[IntPtr])},
 @{Name='vkAllocateCommandBuffers';Ret=[int];Params=[Type[]]@([IntPtr],[IntPtr],[IntPtr])},
 @{Name='vkBeginCommandBuffer';Ret=[int];Params=[Type[]]@([IntPtr],[IntPtr])},
 @{Name='vkEndCommandBuffer';Ret=[int];Params=[Type[]]@([IntPtr])},
 @{Name='vkCmdResetQueryPool';Ret=[void];Params=[Type[]]@([IntPtr],[uint64],[uint32],[uint32])},
 @{Name='vkCmdWriteTimestamp';Ret=[void];Params=[Type[]]@([IntPtr],[uint32],[uint64],[uint32])},
 @{Name='vkGetQueryPoolResults';Ret=[int];Params=[Type[]]@([IntPtr],[uint64],[uint32],[uint32],[uint64],[IntPtr],[uint64],[uint32])}
 )){$api[$spec.Name]=$interop.GetCall($vkGetDeviceProcAddr.Invoke($Device,$spec.Name),$spec.Ret,$spec.Params)}
 $queryCI=Block 32; W32 $queryCI 0 11; W32 $queryCI 20 2; W32 $queryCI 24 ($Count*2)
 $queryOut=Block 8; CheckVK ($api.vkCreateQueryPool.Invoke($Device,$queryCI,[IntPtr]::Zero,$queryOut)) 'create timing queries'
 $queryPool=[uint64][Runtime.InteropServices.Marshal]::ReadInt64($queryOut)
 $timingPoolCI=Block 24; W32 $timingPoolCI 0 39; W32 $timingPoolCI 20 $QueueFamily
 $timingPoolOut=Block 8; CheckVK ($api.vkCreateCommandPool.Invoke($Device,$timingPoolCI,[IntPtr]::Zero,$timingPoolOut)) 'create timing command pool'
 $timingAlloc=Block 32; W32 $timingAlloc 0 40; W64 $timingAlloc 16 ([uint64][Runtime.InteropServices.Marshal]::ReadInt64($timingPoolOut)); W32 $timingAlloc 28 ($Count*2)
 $timingCommands=Block ($Count*16); CheckVK ($api.vkAllocateCommandBuffers.Invoke($Device,$timingAlloc,$timingCommands)) 'allocate timing command buffers'
 $timingBegin=Block 32; W32 $timingBegin 0 42; W32 $timingBegin 16 1
 $timingSubmits=Block ($Count*16)
 for($index=0;$index -lt ($Count*2);$index++){
  $command=[Runtime.InteropServices.Marshal]::ReadIntPtr($timingCommands,$index*8)
  CheckVK ($api.vkBeginCommandBuffer.Invoke($command,$timingBegin)) 'begin timing command'
  if(($index%2) -eq 0){$api.vkCmdResetQueryPool.Invoke($command,$queryPool,[uint32]$index,[uint32]2)}
  $api.vkCmdWriteTimestamp.Invoke($command,[uint32]0x10000,$queryPool,[uint32]$index)
  CheckVK ($api.vkEndCommandBuffer.Invoke($command)) 'end timing command'
  $submit=Block 72; W32 $submit 0 4; W32 $submit 40 1; WP $submit 48 ([IntPtr]::Add($timingCommands,$index*8)); WP $timingSubmits ($index*8) $submit
 }
 # Derive the timestampPeriod offset from the installed native SDK header.
 $nativeHeader=[IO.File]::ReadAllText('C:\VulkanSDK\1.4.357.0\Include\vulkan\vulkan_core.h')
 $limitsMatch=[regex]::Match($nativeHeader,'(?s)typedef struct VkPhysicalDeviceLimits \{(.*?)\} VkPhysicalDeviceLimits;')
 if(-not $limitsMatch.Success){throw 'SDK limits layout missing'}
 $limitOffset=0; $periodOffset=$null
 foreach($line in ($limitsMatch.Groups[1].Value -split "`n")){
  $fieldMatch=[regex]::Match($line,'^\s*(\w+)\s+(\w+)(?:\[(\d+)\])?;')
  if(-not $fieldMatch.Success){continue}
  $fieldType=$fieldMatch.Groups[1].Value; $fieldName=$fieldMatch.Groups[2].Value
  $fieldSize=switch($fieldType){'uint32_t'{4};'int32_t'{4};'float'{4};'VkBool32'{4};'VkSampleCountFlags'{4};'VkDeviceSize'{8};'size_t'{8};default{throw "Unknown limits type $fieldType"}}
  $limitOffset=[int]([math]::Ceiling($limitOffset/$fieldSize)*$fieldSize)
  if($fieldName -eq 'timestampPeriod'){$periodOffset=296+$limitOffset;break}
  $fieldCount=if($fieldMatch.Groups[3].Success){[int]$fieldMatch.Groups[3].Value}else{1}
  $limitOffset+=$fieldSize*$fieldCount
 }
 if($null -eq $periodOffset){throw 'Timestamp period field missing'}
 $properties=Block 4096
 $getProperties=$interop.GetExportCall('C:\Windows\System32\vulkan-1.dll','vkGetPhysicalDeviceProperties',[void],@([IntPtr],[IntPtr]))
 $getProperties.Invoke($Physical,$properties)
 $periodBytes=[byte[]]::new(4); [Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($properties,$periodOffset),$periodBytes,0,4)
 $period=[BitConverter]::ToSingle($periodBytes,0)
 if($period -le 0 -or $period -gt 1000000){throw "Invalid timestamp period: $period"}
 [pscustomobject]@{Device=$Device;Queue=$Queue;QueryPool=$queryPool;Submits=$timingSubmits;Api=$api;TimestampPeriod=$period;PeriodOffset=$periodOffset}
}
function ReadGpuStageTiming($Timing,[int]$GraphCount){
 $results=Block ($GraphCount*32)
 $status=$Timing.Api.vkGetQueryPoolResults.Invoke($Timing.Device,$Timing.QueryPool,[uint32]0,[uint32]($GraphCount*2),[uint64]($GraphCount*32),$results,[uint64]16,[uint32]5)
 CheckVK ([int]$status) 'read completed timing queries without WAIT'
 $rows=@(for($index=0;$index -lt $GraphCount;$index++){
  $start=[Runtime.InteropServices.Marshal]::ReadInt64($results,$index*32)
  $end=[Runtime.InteropServices.Marshal]::ReadInt64($results,$index*32+16)
  $startAvailable=[Runtime.InteropServices.Marshal]::ReadInt64($results,$index*32+8)
  $endAvailable=[Runtime.InteropServices.Marshal]::ReadInt64($results,$index*32+24)
  if($startAvailable -eq 0 -or $endAvailable -eq 0){throw 'Timestamp unavailable after terminal completion'}
  [pscustomobject]@{GraphIndex=$index;Start=$start;End=$end;Milliseconds=($end-$start)*[double]$Timing.TimestampPeriod/1000000.0}
 })
 [pscustomobject]@{TimestampPeriodNanoseconds=$Timing.TimestampPeriod;PeriodOffset=$Timing.PeriodOffset;Rows=$rows}
}
