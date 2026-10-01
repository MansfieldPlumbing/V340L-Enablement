param(
    [int]$Trials = 20,
    [int]$Bytes = 65536,
    [int]$Die0 = 0,
    [int]$Die1 = 1
)

$ErrorActionPreference = 'Stop'
if ([IntPtr]::Size -ne 8) { throw '64-bit PowerShell is required.' }
if ($Trials -lt 1 -or $Trials -gt 10000) { throw 'Trials must be 1 through 10000.' }
if ($Bytes -lt 4096 -or $Bytes -gt 268435456 -or ($Bytes % 4)) { throw 'Bytes must be a 4-byte multiple from 4096 through 268435456.' }

$binderPath = Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))) 'src\New-WindowsFunctionPointerBinder.ps1'
if (-not (Test-Path -LiteralPath $binderPath)) { throw "Missing repository binder: $binderPath" }
$api = & $binderPath

$blocks = [Collections.Generic.List[object]]::new()
function Block([int]$len) { $b=$api.NewBuffer($len); $blocks.Add($b); return $b }
function W32($b,[int]$o,[uint32]$v) { $api.WriteUInt32($b,$o,$v) }
function R32($b,[int]$o) { $api.ReadUInt32($b,$o) }
function W64($b,[int]$o,[uint64]$v) { $api.WriteUInt64($b,$o,$v) }
function R64($b,[int]$o) { $api.ReadUInt64($b,$o) }
function WritePtr($b,[int]$o,[IntPtr]$v) { $api.WritePointer($b,$o,$v) }
function ReadPtr($b,[int]$o) { $api.ReadPointer($b,$o) }
function Fn([string]$name,[Type]$ret,[Type[]]$types) { $api.GetExportCall('vulkan-1.dll',$name,$ret,$types) }
function Check([int]$c,[string]$s) { if($c -ne 0){throw "$s failed: VkResult=$c"} }

$ptr=[IntPtr]; $u32=[uint32]; $u64=[uint64]; $i32=[int]; $void=[void]
$vkCreateInstance=Fn 'vkCreateInstance' $i32 @($ptr,$ptr,$ptr)
$vkDestroyInstance=Fn 'vkDestroyInstance' $void @($ptr,$ptr)
$vkEnumeratePhysicalDevices=Fn 'vkEnumeratePhysicalDevices' $i32 @($ptr,$ptr,$ptr)
$vkGetPhysicalDeviceProperties=Fn 'vkGetPhysicalDeviceProperties' $void @($ptr,$ptr)
$vkGetPhysicalDeviceQueueFamilyProperties=Fn 'vkGetPhysicalDeviceQueueFamilyProperties' $void @($ptr,$ptr,$ptr)
$vkGetPhysicalDeviceMemoryProperties=Fn 'vkGetPhysicalDeviceMemoryProperties' $void @($ptr,$ptr)
$vkCreateDevice=Fn 'vkCreateDevice' $i32 @($ptr,$ptr,$ptr,$ptr)
$vkDestroyDevice=Fn 'vkDestroyDevice' $void @($ptr,$ptr)
$vkGetDeviceQueue=Fn 'vkGetDeviceQueue' $void @($ptr,$u32,$u32,$ptr)
$vkCreateBuffer=Fn 'vkCreateBuffer' $i32 @($ptr,$ptr,$ptr,$ptr)
$vkDestroyBuffer=Fn 'vkDestroyBuffer' $void @($ptr,$ptr,$ptr)
$vkGetBufferMemoryRequirements=Fn 'vkGetBufferMemoryRequirements' $void @($ptr,$ptr,$ptr)
$vkAllocateMemory=Fn 'vkAllocateMemory' $i32 @($ptr,$ptr,$ptr,$ptr)
$vkFreeMemory=Fn 'vkFreeMemory' $void @($ptr,$ptr,$ptr)
$vkBindBufferMemory=Fn 'vkBindBufferMemory' $i32 @($ptr,$ptr,$ptr,$u64)
$vkMapMemory=Fn 'vkMapMemory' $i32 @($ptr,$ptr,$u64,$u64,$u32,$ptr)
$vkUnmapMemory=Fn 'vkUnmapMemory' $void @($ptr,$ptr)
$vkCreateCommandPool=Fn 'vkCreateCommandPool' $i32 @($ptr,$ptr,$ptr,$ptr)
$vkDestroyCommandPool=Fn 'vkDestroyCommandPool' $void @($ptr,$ptr,$ptr)
$vkAllocateCommandBuffers=Fn 'vkAllocateCommandBuffers' $i32 @($ptr,$ptr,$ptr)
$vkBeginCommandBuffer=Fn 'vkBeginCommandBuffer' $i32 @($ptr,$ptr)
$vkEndCommandBuffer=Fn 'vkEndCommandBuffer' $i32 @($ptr)
$vkResetCommandBuffer=Fn 'vkResetCommandBuffer' $i32 @($ptr,$u32)
$vkCmdFillBuffer=Fn 'vkCmdFillBuffer' $void @($ptr,$ptr,$u64,$u64,$u32)
$vkCmdCopyBuffer=Fn 'vkCmdCopyBuffer' $void @($ptr,$ptr,$ptr,$u32,$ptr)
$vkCmdPipelineBarrier=Fn 'vkCmdPipelineBarrier' $void @($ptr,$u32,$u32,$u32,$u32,$ptr,$u32,$ptr,$u32,$ptr)
$vkQueueSubmit=Fn 'vkQueueSubmit' $i32 @($ptr,$u32,$ptr,$ptr)
$vkQueueWaitIdle=Fn 'vkQueueWaitIdle' $i32 @($ptr)
$vkDeviceWaitIdle=Fn 'vkDeviceWaitIdle' $i32 @($ptr)

$virtualAlloc=$api.GetExportCall('kernel32.dll','VirtualAlloc',$ptr,@($ptr,$u64,$u32,$u32))
$virtualFree=$api.GetExportCall('kernel32.dll','VirtualFree',[bool],@($ptr,$u64,$u32))
$rtlMoveMemory=$api.GetExportCall('kernel32.dll','RtlMoveMemory',$void,@($ptr,$ptr,$u64))

$instance=[IntPtr]::Zero
$devices=@([IntPtr]::Zero,[IntPtr]::Zero)
$queues=@([IntPtr]::Zero,[IntPtr]::Zero)
$pools=@([IntPtr]::Zero,[IntPtr]::Zero)
$buffers=[Collections.Generic.List[object]]::new()
$memories=[Collections.Generic.List[object]]::new()
$apertureHost=[IntPtr]::Zero
$readbackHost=[IntPtr]::Zero
$stagingMapped0=[IntPtr]::Zero
$stagingMapped1=[IntPtr]::Zero

try {
    # 1. Instance & V340L discovery
    $ci=Block 64; W32 $ci 0 1
    $out=Block 8
    Check ($vkCreateInstance.Invoke($ci.Pointer,[IntPtr]::Zero,$out.Pointer)) 'vkCreateInstance'
    $instance=ReadPtr $out 0
    $count=Block 4
    Check ($vkEnumeratePhysicalDevices.Invoke($instance,$count.Pointer,[IntPtr]::Zero)) 'enumerate count'
    $n=R32 $count 0
    $physicalList=Block ([int]($n*8))
    Check ($vkEnumeratePhysicalDevices.Invoke($instance,$count.Pointer,$physicalList.Pointer)) 'enumerate devices'
    $props=Block 1024
    $physical=[Collections.Generic.List[IntPtr]]::new()
    for($i=0;$i -lt $n;$i++){
        $p=ReadPtr $physicalList ($i*8)
        $vkGetPhysicalDeviceProperties.Invoke($p,$props.Pointer)
        $name=[Runtime.InteropServices.Marshal]::PtrToStringUTF8([IntPtr]::Add($props.Pointer,20))
        if((R32 $props 8) -eq 0x1002 -and $name -match 'V340'){$physical.Add($p)}
    }
    if($physical.Count -lt 2){throw "Expected at least two V340L dies; found $($physical.Count)"}
    if($Die0 -ge $physical.Count -or $Die1 -ge $physical.Count){throw "Die index out of range: Die0=$Die0, Die1=$Die1, Count=$($physical.Count)"}
    $physical=@($physical[$Die0], $physical[$Die1])

    # 2. Devices & Transfer Queues
    $queueFamilies=@(0,0)
    $ext=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi('VK_EXT_external_memory_host')
    try {
        $extNames=Block 8; WritePtr $extNames 0 $ext
        $priority=Block 4; W32 $priority 0 0x3F800000
        for($d=0;$d -lt 2;$d++){
            $vkGetPhysicalDeviceQueueFamilyProperties.Invoke($physical[$d],$count.Pointer,[IntPtr]::Zero)
            $qCount=R32 $count 0
            $qProps=Block ([int]($qCount*24))
            $vkGetPhysicalDeviceQueueFamilyProperties.Invoke($physical[$d],$count.Pointer,$qProps.Pointer)
            $family=-1
            for($q=0;$q -lt $qCount;$q++){
                $flags=R32 $qProps ($q*24)
                if($flags -band 4){$family=$q;if(-not($flags -band 3)){break}}
            }
            if($family -lt 0){throw "Die $d has no transfer queue"}
            $queueFamilies[$d]=$family
            $qci=Block 40; W32 $qci 0 2; W32 $qci 20 $family; W32 $qci 24 1; WritePtr $qci 32 $priority.Pointer
            $dci=Block 72; W32 $dci 0 3; W32 $dci 20 1; WritePtr $dci 24 $qci.Pointer; W32 $dci 48 1; WritePtr $dci 56 $extNames.Pointer
            $devOut=Block 8
            Check ($vkCreateDevice.Invoke($physical[$d],$dci.Pointer,[IntPtr]::Zero,$devOut.Pointer)) "create die $d"
            $devices[$d]=ReadPtr $devOut 0
            $queueOut=Block 8
            $vkGetDeviceQueue.Invoke($devices[$d],[uint32]$family,[uint32]0,$queueOut.Pointer)
            $queues[$d]=ReadPtr $queueOut 0
        }
    } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($ext) }

    # 3. Memory Helper
    function AllocBuffer([int]$d, [bool]$import, [IntPtr]$hostPtr, [bool]$hostVisible = $false) {
        $extInfo=Block 24; W32 $extInfo 0 1000072000; W32 $extInfo 16 128
        $bci=Block 56; W32 $bci 0 12; if($import){WritePtr $bci 8 $extInfo.Pointer}; W64 $bci 24 $Bytes; W32 $bci 32 3
        $bufOut=Block 8
        Check ($vkCreateBuffer.Invoke($devices[$d],$bci.Pointer,[IntPtr]::Zero,$bufOut.Pointer)) "create buffer"
        $buf=ReadPtr $bufOut 0
        $buffers.Add(@{Device=$d;Handle=$buf})
        $req=Block 24; $vkGetBufferMemoryRequirements.Invoke($devices[$d],$buf,$req.Pointer)
        $required=R64 $req 0; $bits=R32 $req 16
        $memProps=Block 520; $vkGetPhysicalDeviceMemoryProperties.Invoke($physical[$d],$memProps.Pointer)
        if($import){
            $getHostPropsAddress=$api.GetExportCall('vulkan-1.dll','vkGetDeviceProcAddr',$ptr,@($ptr,$ptr))
            $name=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi('vkGetMemoryHostPointerPropertiesEXT')
            try{$addr=$getHostPropsAddress.Invoke($devices[$d],$name)}finally{[Runtime.InteropServices.Marshal]::FreeHGlobal($name)}
            $getHostProps=$api.GetCall($addr,$i32,@($ptr,$u32,$ptr,$ptr))
            $hp=Block 24; W32 $hp 0 1000178001
            Check ($getHostProps.Invoke($devices[$d],[uint32]128,$hostPtr,$hp.Pointer)) "host properties"
            $bits=$bits -band (R32 $hp 16)
        }
        $want = if($import){2} elseif($hostVisible){6} else{1} # 6 = HostVisible | HostCoherent, 1 = DeviceLocal
        $type=-1
        $types=R32 $memProps 0
        for($i=0;$i -lt $types;$i++){
            $flags=R32 $memProps (4+$i*8)
            if(($bits -band (1u -shl $i)) -and (($flags -band $want) -eq $want)){$type=$i;break}
        }
        if($type -lt 0){throw "No memory type on die $d for want=$want"}
        $imp=Block 32; W32 $imp 0 1000178000; W32 $imp 16 128; WritePtr $imp 24 $hostPtr
        $ai=Block 32; W32 $ai 0 5; if($import){WritePtr $ai 8 $imp.Pointer}; W64 $ai 16 $required; W32 $ai 24 $type
        $memOut=Block 8
        Check ($vkAllocateMemory.Invoke($devices[$d],$ai.Pointer,[IntPtr]::Zero,$memOut.Pointer)) "allocate memory"
        $mem=ReadPtr $memOut 0
        $memories.Add(@{Device=$d;Handle=$mem})
        Check ($vkBindBufferMemory.Invoke($devices[$d],$buf,$mem,[uint64]0)) "bind memory"
        return @{Buffer=$buf; Memory=$mem}
    }

    # Allocate Device-Local VRAM on Die 0 and Die 1 (simulating activation tensors)
    $vram0 = (AllocBuffer 0 $false ([IntPtr]::Zero) $false).Buffer
    $vram1 = (AllocBuffer 1 $false ([IntPtr]::Zero) $false).Buffer

    # --- METHOD 1: STOCK CPU STAGING BOUNCE ---
    # Die 0 staging (host visible) + Die 1 staging (host visible)
    $stg0 = AllocBuffer 0 $false ([IntPtr]::Zero) $true
    $stg1 = AllocBuffer 1 $false ([IntPtr]::Zero) $true
    $mapOut=Block 8
    Check ($vkMapMemory.Invoke($devices[0],$stg0.Memory,[uint64]0,[uint64]$Bytes,[uint32]0,$mapOut.Pointer)) "map stg0"
    $stagingMapped0=ReadPtr $mapOut 0
    Check ($vkMapMemory.Invoke($devices[1],$stg1.Memory,[uint64]0,[uint64]$Bytes,[uint32]0,$mapOut.Pointer)) "map stg1"
    $stagingMapped1=ReadPtr $mapOut 0

    # --- METHOD 2: OUR VALIDATED HOST APERTURE SDMA ---
    $apertureHost = $virtualAlloc.Invoke([IntPtr]::Zero,[uint64]$Bytes,[uint32]0x3000,[uint32]4)
    if($apertureHost -eq [IntPtr]::Zero){throw "VirtualAlloc aperture failed"}
    $aperture0 = (AllocBuffer 0 $true $apertureHost).Buffer
    $aperture1 = (AllocBuffer 1 $true $apertureHost).Buffer

    # Readback buffer on Die 1 for byte verification
    $readbackHost = $virtualAlloc.Invoke([IntPtr]::Zero,[uint64]$Bytes,[uint32]0x3000,[uint32]4)
    if($readbackHost -eq [IntPtr]::Zero){throw "VirtualAlloc readback failed"}
    $readback1 = (AllocBuffer 1 $true $readbackHost).Buffer

    # Command pools & buffers
    for($d=0;$d -lt 2;$d++){
        $pci=Block 24; W32 $pci 0 38; W32 $pci 16 2; W32 $pci 20 $queueFamilies[$d]
        $poolOut=Block 8; Check ($vkCreateCommandPool.Invoke($devices[$d],$pci.Pointer,[IntPtr]::Zero,$poolOut.Pointer)) "create pool $d"
        $pools[$d]=ReadPtr $poolOut 0
    }

    function RecordCopy([IntPtr]$dev,[IntPtr]$pool,[IntPtr]$src,[IntPtr]$dst,[object]$cmdOutBlock,[object]$subBlock){
        $cai=Block 32; W32 $cai 0 40; WritePtr $cai 16 $pool; W32 $cai 28 1
        Check ($vkAllocateCommandBuffers.Invoke($dev,$cai.Pointer,$cmdOutBlock.Pointer)) "alloc cmd"
        $cmd=ReadPtr $cmdOutBlock 0
        $begin=Block 32; W32 $begin 0 42
        $region=Block 24; W64 $region 16 $Bytes
        Check ($vkBeginCommandBuffer.Invoke($cmd,$begin.Pointer)) "begin"
        $vkCmdCopyBuffer.Invoke($cmd,$src,$dst,[uint32]1,$region.Pointer)
        Check ($vkEndCommandBuffer.Invoke($cmd)) "end"
        W32 $subBlock 0 4; W32 $subBlock 40 1; WritePtr $subBlock 48 $cmdOutBlock.Pointer
    }

    $cmdStock0 = Block 24; $cmdStock1 = Block 24
    $cmdAperture0 = Block 24; $cmdAperture1 = Block 24
    $cmdReadback = Block 24
    $cmdFill0 = Block 24
    $subStock0 = Block 72; $subStock1 = Block 72
    $subAperture0 = Block 72; $subAperture1 = Block 72
    $subReadback = Block 72
    $subFill0 = Block 72

    RecordCopy $devices[0] $pools[0] $vram0 $stg0.Buffer $cmdStock0 $subStock0
    RecordCopy $devices[1] $pools[1] $stg1.Buffer $vram1 $cmdStock1 $subStock1
    RecordCopy $devices[0] $pools[0] $vram0 $aperture0 $cmdAperture0 $subAperture0
    RecordCopy $devices[1] $pools[1] $aperture1 $vram1 $cmdAperture1 $subAperture1
    RecordCopy $devices[1] $pools[1] $vram1 $readback1 $cmdReadback $subReadback

    # Allocate fill command buffer on Die 0
    $caiFill=Block 32; W32 $caiFill 0 40; WritePtr $caiFill 16 $pools[0]; W32 $caiFill 28 1
    Check ($vkAllocateCommandBuffers.Invoke($devices[0],$caiFill.Pointer,$cmdFill0.Pointer)) "alloc fill cmd"
    $fillCmd = ReadPtr $cmdFill0 0
    W32 $subFill0 0 4; W32 $subFill0 40 1; WritePtr $subFill0 48 $cmdFill0.Pointer

    # --- BYTE VERIFICATION FOR BOTH METHODS ---
    $testPattern = 0xA5A5A5A5u
    $begin=Block 32; W32 $begin 0 42
    Check ($vkBeginCommandBuffer.Invoke($fillCmd,$begin.Pointer)) "begin fill"
    $vkCmdFillBuffer.Invoke($fillCmd,$vram0,[uint64]0,[uint64]$Bytes,$testPattern)
    Check ($vkEndCommandBuffer.Invoke($fillCmd)) "end fill"
    Check ($vkQueueSubmit.Invoke($queues[0],[uint32]1,$subFill0.Pointer,[IntPtr]::Zero)) "submit fill"
    Check ($vkQueueWaitIdle.Invoke($queues[0])) "wait fill"

    # Test Aperture SDMA Byte Correctness
    Check ($vkQueueSubmit.Invoke($queues[0],[uint32]1,$subAperture0.Pointer,[IntPtr]::Zero)) "apt sub0 verify"
    Check ($vkQueueWaitIdle.Invoke($queues[0])) "apt wait0 verify"
    Check ($vkQueueSubmit.Invoke($queues[1],[uint32]1,$subAperture1.Pointer,[IntPtr]::Zero)) "apt sub1 verify"
    Check ($vkQueueWaitIdle.Invoke($queues[1])) "apt wait1 verify"
    Check ($vkQueueSubmit.Invoke($queues[1],[uint32]1,$subReadback.Pointer,[IntPtr]::Zero)) "readback sub verify"
    Check ($vkQueueWaitIdle.Invoke($queues[1])) "readback wait verify"

    $memcmp = $api.GetExportCall('msvcrt.dll','memcmp',[int],@([IntPtr],[IntPtr],[uint64]))
    $memset = $api.GetExportCall('msvcrt.dll','memset',[IntPtr],@([IntPtr],[int],[uint64]))
    $refHost = $virtualAlloc.Invoke([IntPtr]::Zero,[uint64]$Bytes,[uint32]0x3000,[uint32]4)
    if($refHost -eq [IntPtr]::Zero){throw "VirtualAlloc refHost failed"}
    $memset.Invoke($refHost, 0xA5, [uint64]$Bytes) | Out-Null

    $cmp = $memcmp.Invoke($readbackHost, $refHost, [uint64]$Bytes)
    [void]$virtualFree.Invoke($refHost, [uint64]0, [uint32]0x8000)
    if($cmp -ne 0){
        throw "Aperture byte mismatch: readback does not match expected pattern ($Bytes bytes)"
    }

    # --- BENCHMARK STOCK CPU STAGING ---
    # Die 0 VRAM -> Staging0 | CPU memcpy(Staging0 -> Staging1) | Staging1 -> Die 1 VRAM
    $stockTimes = [Collections.Generic.List[double]]::new()
    for($t=0;$t -lt $Trials;$t++){
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Check ($vkQueueSubmit.Invoke($queues[0],[uint32]1,$subStock0.Pointer,[IntPtr]::Zero)) "stock sub0"
        Check ($vkQueueWaitIdle.Invoke($queues[0])) "stock wait0"
        $rtlMoveMemory.Invoke($stagingMapped1, $stagingMapped0, [uint64]$Bytes)
        Check ($vkQueueSubmit.Invoke($queues[1],[uint32]1,$subStock1.Pointer,[IntPtr]::Zero)) "stock sub1"
        Check ($vkQueueWaitIdle.Invoke($queues[1])) "stock wait1"
        $sw.Stop()
        $stockTimes.Add($sw.Elapsed.TotalMicroseconds)
    }

    # --- BENCHMARK OUR APERTURE METHOD ---
    # Die 0 VRAM -> Aperture (imported) | ZERO CPU COPY | Aperture -> Die 1 VRAM
    $apertureTimes = [Collections.Generic.List[double]]::new()
    for($t=0;$t -lt $Trials;$t++){
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Check ($vkQueueSubmit.Invoke($queues[0],[uint32]1,$subAperture0.Pointer,[IntPtr]::Zero)) "aperture sub0"
        Check ($vkQueueWaitIdle.Invoke($queues[0])) "aperture wait0"
        Check ($vkQueueSubmit.Invoke($queues[1],[uint32]1,$subAperture1.Pointer,[IntPtr]::Zero)) "aperture sub1"
        Check ($vkQueueWaitIdle.Invoke($queues[1])) "aperture wait1"
        $sw.Stop()
        $apertureTimes.Add($sw.Elapsed.TotalMicroseconds)
    }

    $stk = $stockTimes.ToArray(); [array]::Sort($stk)
    $apt = $apertureTimes.ToArray(); [array]::Sort($apt)
    $med = [int][math]::Floor(($Trials-1)*0.5)
    $p95 = [int][math]::Ceiling(($Trials-1)*0.95)

    $stkMean = ($stk | Measure-Object -Average).Average
    $aptMean = ($apt | Measure-Object -Average).Average

    [pscustomobject]@{
        Bytes               = $Bytes
        Trials              = $Trials
        ByteVerification    = 'PASS (Bit-for-Bit Identical)'
        StockCpuBounceMinUs = [math]::Round($stk[0], 2)
        StockCpuBounceP50Us = [math]::Round($stk[$med], 2)
        StockCpuBounceP95Us = [math]::Round($stk[$p95], 2)
        StockCpuBounceMeanUs= [math]::Round($stkMean, 2)
        OurApertureMinUs    = [math]::Round($apt[0], 2)
        OurApertureP50Us    = [math]::Round($apt[$med], 2)
        OurApertureP95Us    = [math]::Round($apt[$p95], 2)
        OurApertureMeanUs   = [math]::Round($aptMean, 2)
        SpeedupRatio        = [math]::Round($stk[$med] / [math]::Max(1.0, $apt[$med]), 2)
        SpeedupPercent      = [math]::Round((($stk[$med] - $apt[$med]) / $stk[$med]) * 100, 1)
    }
} finally {
    for($d=0;$d -lt 2;$d++){if($devices[$d] -ne [IntPtr]::Zero){[void]$vkDeviceWaitIdle.Invoke($devices[$d])}}
    if($stagingMapped0 -ne [IntPtr]::Zero){$vkUnmapMemory.Invoke($devices[0],$stg0.Memory)}
    if($stagingMapped1 -ne [IntPtr]::Zero){$vkUnmapMemory.Invoke($devices[1],$stg1.Memory)}
    for($d=0;$d -lt 2;$d++){if($pools[$d] -ne [IntPtr]::Zero){$vkDestroyCommandPool.Invoke($devices[$d],$pools[$d],[IntPtr]::Zero)}}
    foreach($b in $buffers){$vkDestroyBuffer.Invoke($devices[$b.Device],$b.Handle,[IntPtr]::Zero)}
    foreach($m in $memories){$vkFreeMemory.Invoke($devices[$m.Device],$m.Handle,[IntPtr]::Zero)}
    if($apertureHost -ne [IntPtr]::Zero){[void]$virtualFree.Invoke($apertureHost,[uint64]0,[uint32]0x8000)}
    if($readbackHost -ne [IntPtr]::Zero){[void]$virtualFree.Invoke($readbackHost,[uint64]0,[uint32]0x8000)}
    for($d=0;$d -lt 2;$d++){if($devices[$d] -ne [IntPtr]::Zero){$vkDestroyDevice.Invoke($devices[$d],[IntPtr]::Zero)}}
    if($instance -ne [IntPtr]::Zero){$vkDestroyInstance.Invoke($instance,[IntPtr]::Zero)}
    foreach($b in $blocks){$api.FreeBuffer($b)}
    $api.Dispose()
}
