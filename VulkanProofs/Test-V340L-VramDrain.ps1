<#
.SYNOPSIS
    Transfers multiple gigabytes of VRAM from Die 0 into Die 1
    across a Vulkan VK_EXT_external_memory_host aperture to benchmark PCIe throughput.
    PowerShell 7 with unmanaged Vulkan C ABI interop.
#>

[CmdletBinding()]
param(
    [ValidateSet(1, 2, 4, 6, 7)]
    [int]$Gigabytes = 4,
    [int]$Trials = 3
)

$ErrorActionPreference = 'Stop'
if ([IntPtr]::Size -ne 8) { throw '64-bit PowerShell is required.' }

$bytes = [uint64]$Gigabytes * 1073741824

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "       V340L MULTI-GIGABYTE VRAM DRAIN TEST: $Gigabytes GB ($bytes bytes)       " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

$binderPath = Join-Path $PSScriptRoot '..\src\New-WindowsFunctionPointerBinder.ps1'
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
$vkCreateCommandPool=Fn 'vkCreateCommandPool' $i32 @($ptr,$ptr,$ptr,$ptr)
$vkDestroyCommandPool=Fn 'vkDestroyCommandPool' $void @($ptr,$ptr,$ptr)
$vkAllocateCommandBuffers=Fn 'vkAllocateCommandBuffers' $i32 @($ptr,$ptr,$ptr)
$vkBeginCommandBuffer=Fn 'vkBeginCommandBuffer' $i32 @($ptr,$ptr)
$vkEndCommandBuffer=Fn 'vkEndCommandBuffer' $i32 @($ptr)
$vkCmdFillBuffer=Fn 'vkCmdFillBuffer' $void @($ptr,$ptr,$u64,$u64,$u32)
$vkCmdCopyBuffer=Fn 'vkCmdCopyBuffer' $void @($ptr,$ptr,$ptr,$u32,$ptr)
$vkQueueSubmit=Fn 'vkQueueSubmit' $i32 @($ptr,$u32,$ptr,$ptr)
$vkQueueWaitIdle=Fn 'vkQueueWaitIdle' $i32 @($ptr)
$vkDeviceWaitIdle=Fn 'vkDeviceWaitIdle' $i32 @($ptr)

$virtualAlloc=$api.GetExportCall('kernel32.dll','VirtualAlloc',$ptr,@($ptr,$u64,$u32,$u32))
$virtualFree=$api.GetExportCall('kernel32.dll','VirtualFree',[bool],@($ptr,$u64,$u32))

$instance=[IntPtr]::Zero
$devices=@([IntPtr]::Zero,[IntPtr]::Zero)
$queues=@([IntPtr]::Zero,[IntPtr]::Zero)
$pools=@([IntPtr]::Zero,[IntPtr]::Zero)
$buffers=[Collections.Generic.List[object]]::new()
$memories=[Collections.Generic.List[object]]::new()
$apertureHost=[IntPtr]::Zero

try {
    # 1. Instance and Discovery
    $ci=Block 64; W32 $ci 0 1; $out=Block 8
    Check ($vkCreateInstance.Invoke($ci.Pointer,[IntPtr]::Zero,$out.Pointer)) 'vkCreateInstance'
    $instance=ReadPtr $out 0
    $count=Block 4; Check ($vkEnumeratePhysicalDevices.Invoke($instance,$count.Pointer,[IntPtr]::Zero)) 'enum count'
    $n=R32 $count 0; $physList=Block ([int]($n*8))
    Check ($vkEnumeratePhysicalDevices.Invoke($instance,$count.Pointer,$physList.Pointer)) 'enum phys'
    $props=Block 1024; $physical=[Collections.Generic.List[IntPtr]]::new()
    for($i=0;$i -lt $n;$i++){
        $p=ReadPtr $physList ($i*8); $vkGetPhysicalDeviceProperties.Invoke($p,$props.Pointer)
        $name=[Runtime.InteropServices.Marshal]::PtrToStringUTF8([IntPtr]::Add($props.Pointer,20))
        if((R32 $props 8) -eq 0x1002 -and $name -match 'V340'){$physical.Add($p)}
    }
    if($physical.Count -lt 2){throw "Expected at least 2 V340L dies, found $($physical.Count)"}
    $physical=$physical[0..1]

    # 2. Devices with VK_EXT_external_memory_host
    $ext=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi('VK_EXT_external_memory_host')
    try {
        $extNames=Block 8; WritePtr $extNames 0 $ext; $priority=Block 4; W32 $priority 0 0x3F800000
        $queueFamilies=@(0,0)
        for($d=0;$d -lt 2;$d++){
            $vkGetPhysicalDeviceQueueFamilyProperties.Invoke($physical[$d],$count.Pointer,[IntPtr]::Zero)
            $qc=R32 $count 0; $qp=Block ([int]($qc*24)); $vkGetPhysicalDeviceQueueFamilyProperties.Invoke($physical[$d],$count.Pointer,$qp.Pointer)
            $family=-1; for($q=0;$q -lt $qc;$q++){if((R32 $qp ($q*24)) -band 4){$family=$q;break}}
            if($family -lt 0){throw "No transfer queue on die $d"}
            $queueFamilies[$d]=$family
            $qci=Block 40; W32 $qci 0 2; W32 $qci 20 $family; W32 $qci 24 1; WritePtr $qci 32 $priority.Pointer
            $dci=Block 72; W32 $dci 0 3; W32 $dci 20 1; WritePtr $dci 24 $qci.Pointer; W32 $dci 48 1; WritePtr $dci 56 $extNames.Pointer
            $devOut=Block 8; Check ($vkCreateDevice.Invoke($physical[$d],$dci.Pointer,[IntPtr]::Zero,$devOut.Pointer)) "create dev $d"
            $devices[$d]=ReadPtr $devOut 0
            $qOut=Block 8; $vkGetDeviceQueue.Invoke($devices[$d],[uint32]$family,[uint32]0,$qOut.Pointer); $queues[$d]=ReadPtr $qOut 0
        }
    } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($ext) }

    # 3. Buffer allocator
    function AllocBuffer([int]$d, [bool]$import, [IntPtr]$hostPtr) {
        $extInfo=Block 24; W32 $extInfo 0 1000072000; W32 $extInfo 16 128
        $bci=Block 56; W32 $bci 0 12; if($import){WritePtr $bci 8 $extInfo.Pointer}; W64 $bci 24 $bytes; W32 $bci 32 3
        $bufOut=Block 8; Check ($vkCreateBuffer.Invoke($devices[$d],$bci.Pointer,[IntPtr]::Zero,$bufOut.Pointer)) "create buffer"
        $buf=ReadPtr $bufOut 0; $buffers.Add(@{Device=$d;Handle=$buf})
        $req=Block 24; $vkGetBufferMemoryRequirements.Invoke($devices[$d],$buf,$req.Pointer)
        $required=R64 $req 0; $bits=R32 $req 16
        $memProps=Block 520; $vkGetPhysicalDeviceMemoryProperties.Invoke($physical[$d],$memProps.Pointer)
        if($import){
            $gpa=$api.GetExportCall('vulkan-1.dll','vkGetDeviceProcAddr',$ptr,@($ptr,$ptr))
            $fnName=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi('vkGetMemoryHostPointerPropertiesEXT')
            $addr=$gpa.Invoke($devices[$d],$fnName); [Runtime.InteropServices.Marshal]::FreeHGlobal($fnName)
            $hp=Block 24; W32 $hp 0 1000178001
            Check ($api.GetCall($addr,$i32,@($ptr,$u32,$ptr,$ptr)).Invoke($devices[$d],[uint32]128,$hostPtr,$hp.Pointer)) "hp"
            $bits=$bits -band (R32 $hp 16)
        }
        $want=if($import){2}else{1}; $type=-1; $types=R32 $memProps 0
        for($i=0;$i -lt $types;$i++){if(($bits -band (1u -shl $i)) -and ((R32 $memProps (4+$i*8)) -band $want) -eq $want){$type=$i;break}}
        if($type -lt 0){throw "No memory type for want=$want on die $d"}
        $imp=Block 32; W32 $imp 0 1000178000; W32 $imp 16 128; WritePtr $imp 24 $hostPtr
        $ai=Block 32; W32 $ai 0 5; if($import){WritePtr $ai 8 $imp.Pointer}; W64 $ai 16 $required; W32 $ai 24 $type
        $memOut=Block 8; Check ($vkAllocateMemory.Invoke($devices[$d],$ai.Pointer,[IntPtr]::Zero,$memOut.Pointer)) "alloc mem"
        $mem=ReadPtr $memOut 0; $memories.Add(@{Device=$d;Handle=$mem})
        Check ($vkBindBufferMemory.Invoke($devices[$d],$buf,$mem,[uint64]0)) "bind mem"
        return $buf
    }

    Write-Host "[*] Allocating $Gigabytes GB HBM2 VRAM on Die 0..." -ForegroundColor Yellow
    $vram0 = AllocBuffer 0 $false ([IntPtr]::Zero)
    Write-Host "[*] Allocating $Gigabytes GB HBM2 VRAM on Die 1..." -ForegroundColor Yellow
    $vram1 = AllocBuffer 1 $false ([IntPtr]::Zero)

    Write-Host "[*] Allocating $Gigabytes GB Pinned Host Aperture (VirtualAlloc)..." -ForegroundColor Yellow
    $apertureHost = $virtualAlloc.Invoke([IntPtr]::Zero, $bytes, [uint32]0x3000, [uint32]4)
    if($apertureHost -eq [IntPtr]::Zero){throw "VirtualAlloc failed for $bytes bytes"}

    Write-Host "[*] Importing Host Aperture into Die 0 and Die 1..." -ForegroundColor Yellow
    $aperture0 = AllocBuffer 0 $true $apertureHost
    $aperture1 = AllocBuffer 1 $true $apertureHost

    # 4. Command recording
    for($d=0;$d -lt 2;$d++){
        $pci=Block 24; W32 $pci 0 38; W32 $pci 16 2; W32 $pci 20 $queueFamilies[$d]
        $pOut=Block 8; Check ($vkCreateCommandPool.Invoke($devices[$d],$pci.Pointer,[IntPtr]::Zero,$pOut.Pointer)) "create pool"
        $pools[$d]=ReadPtr $pOut 0
    }

    function RecordCopy([int]$d, [IntPtr]$src, [IntPtr]$dst) {
        $cai=Block 32; W32 $cai 0 40; WritePtr $cai 16 $pools[$d]; W32 $cai 28 1
        $cOut=Block 8; Check ($vkAllocateCommandBuffers.Invoke($devices[$d],$cai.Pointer,$cOut.Pointer)) "cb"
        $cmd=ReadPtr $cOut 0; $begin=Block 32; W32 $begin 0 42; $reg=Block 24; W64 $reg 16 $bytes
        Check ($vkBeginCommandBuffer.Invoke($cmd,$begin.Pointer)) "beg"
        $vkCmdCopyBuffer.Invoke($cmd,$src,$dst,[uint32]1,$reg.Pointer)
        Check ($vkEndCommandBuffer.Invoke($cmd)) "end"
        $sub=Block 72; W32 $sub 0 4; W32 $sub 40 1; WritePtr $sub 48 $cOut.Pointer
        return $sub
    }

    $subHop1 = RecordCopy 0 $vram0 $aperture0
    $subHop2 = RecordCopy 1 $aperture1 $vram1

    # Fill Die 0 VRAM with test pattern
    Write-Host "[*] Pre-filling Die 0 VRAM with test pattern (0xCAFEF00D)..." -ForegroundColor Yellow
    $caiFill=Block 32; W32 $caiFill 0 40; WritePtr $caiFill 16 $pools[0]; W32 $caiFill 28 1
    $cOutFill=Block 8; Check ($vkAllocateCommandBuffers.Invoke($devices[0],$caiFill.Pointer,$cOutFill.Pointer)) "cbFill"
    $cmdFill=ReadPtr $cOutFill 0; $begin=Block 32; W32 $begin 0 42
    Check ($vkBeginCommandBuffer.Invoke($cmdFill,$begin.Pointer)) "begFill"
    $vkCmdFillBuffer.Invoke($cmdFill,$vram0,[uint64]0,$bytes,0xCAFEF00Du)
    Check ($vkEndCommandBuffer.Invoke($cmdFill)) "endFill"
    $subFill=Block 72; W32 $subFill 0 4; W32 $subFill 40 1; WritePtr $subFill 48 $cOutFill.Pointer
    Check ($vkQueueSubmit.Invoke($queues[0],[uint32]1,$subFill.Pointer,[IntPtr]::Zero)) "subFill"
    Check ($vkQueueWaitIdle.Invoke($queues[0])) "waitFill"

    Write-Host "`n[+] Ready! Executing $Gigabytes GB VRAM Drain across $Trials trials..." -ForegroundColor Green

    $drainTimes = [Collections.Generic.List[double]]::new()
    $hop1Times  = [Collections.Generic.List[double]]::new()
    $hop2Times  = [Collections.Generic.List[double]]::new()

    for($t=1; $t -le $Trials; $t++) {
        Write-Host "  --- Trial $t of $Trials ---" -ForegroundColor Cyan

        # Measure Hop 1 (Die 0 HBM2 -> Host Aperture Write)
        $sw1 = [Diagnostics.Stopwatch]::StartNew()
        Check ($vkQueueSubmit.Invoke($queues[0],[uint32]1,$subHop1.Pointer,[IntPtr]::Zero)) "sub1"
        Check ($vkQueueWaitIdle.Invoke($queues[0])) "wait1"
        $sw1.Stop()
        $t1Us = $sw1.Elapsed.TotalMicroseconds
        $hop1Times.Add($t1Us)
        $bw1 = [math]::Round(($bytes / ($t1Us / 1e6)) / 1e9, 2)
        Write-Host "    Hop 1 (Die 0 HBM2 -> Host Aperture) : $([math]::Round($t1Us/1000, 1)) ms ($bw1 GB/s | $([math]::Round($bw1*8,1)) Gbps)" -ForegroundColor White

        # Measure Hop 2 (Host Aperture -> Die 1 HBM2 Read)
        $sw2 = [Diagnostics.Stopwatch]::StartNew()
        Check ($vkQueueSubmit.Invoke($queues[1],[uint32]1,$subHop2.Pointer,[IntPtr]::Zero)) "sub2"
        Check ($vkQueueWaitIdle.Invoke($queues[1])) "wait2"
        $sw2.Stop()
        $t2Us = $sw2.Elapsed.TotalMicroseconds
        $hop2Times.Add($t2Us)
        $bw2 = [math]::Round(($bytes / ($t2Us / 1e6)) / 1e9, 2)
        Write-Host "    Hop 2 (Host Aperture -> Die 1 HBM2) : $([math]::Round($t2Us/1000, 1)) ms ($bw2 GB/s | $([math]::Round($bw2*8,1)) Gbps)" -ForegroundColor White

        $totalUs = $t1Us + $t2Us
        $drainTimes.Add($totalUs)
        $totalBytes = $bytes * 2
        $aggBw = [math]::Round(($totalBytes / ($totalUs / 1e6)) / 1e9, 2)
        Write-Host "    End-to-End Die 0 -> Die 1 VRAM Drain : $([math]::Round($totalUs/1000, 1)) ms (Agg PCIe Throughput: $aggBw GB/s)" -ForegroundColor Green
    }

    $dArr = $drainTimes.ToArray(); [array]::Sort($dArr)
    $h1Arr = $hop1Times.ToArray(); [array]::Sort($h1Arr)
    $h2Arr = $hop2Times.ToArray(); [array]::Sort($h2Arr)

    $bestTotalMs = [math]::Round($dArr[0] / 1000.0, 2)
    $bestHop1Ms  = [math]::Round($h1Arr[0] / 1000.0, 2)
    $bestHop2Ms  = [math]::Round($h2Arr[0] / 1000.0, 2)

    $bestWriteGbps = [math]::Round((($bytes / ($h1Arr[0] / 1e6)) / 1e9) * 8, 1)
    $bestReadGbps  = [math]::Round((($bytes / ($h2Arr[0] / 1e6)) / 1e9) * 8, 1)
    $bestAggGBps   = [math]::Round(($bytes * 2 / ($dArr[0] / 1e6)) / 1e9, 2)

    Write-Host "`n======================================================================" -ForegroundColor Green
    Write-Host "                      VRAM DRAIN BENCHMARK SUMMARY                    " -ForegroundColor Green
    Write-Host "======================================================================" -ForegroundColor Green
    Write-Host "  Transferred Payload     : $Gigabytes GB ($bytes bytes)" -ForegroundColor Cyan
    Write-Host "  Best Hop 1 (Die0->Host) : $bestHop1Ms ms (Rate: $([math]::Round($bestWriteGbps/8, 2)) GB/s | $bestWriteGbps Gbps)" -ForegroundColor White
    Write-Host "  Best Hop 2 (Host->Die1) : $bestHop2Ms ms (Rate: $([math]::Round($bestReadGbps/8, 2)) GB/s | $bestReadGbps Gbps)" -ForegroundColor White
    Write-Host "  Best End-to-End Drain   : $bestTotalMs ms ($([math]::Round($bestTotalMs/1000, 3)) seconds)" -ForegroundColor Yellow
    Write-Host "  Aggregate PCIe Bandwidth: $bestAggGBps GB/s ($([math]::Round($bestAggGBps*8, 1)) Gbps)" -ForegroundColor Green
    $bestPayloadGBps = [math]::Round(($bytes / ($dArr[0] / 1e6)) / 1e9, 2)
    Write-Host "  Effective Payload Rate  : $bestPayloadGBps GB/s" -ForegroundColor Green
    Write-Host "======================================================================" -ForegroundColor Green

    [PSCustomObject]@{
        Status                   = 'PASS'
        GigabytesDrained         = $Gigabytes
        Hop1Write_GigaBytesPerSec= [math]::Round($bestWriteGbps/8, 2)
        Hop1Write_GigaBitsPerSec = $bestWriteGbps
        Hop2Read_GigaBytesPerSec = [math]::Round($bestReadGbps/8, 2)
        Hop2Read_GigaBitsPerSec  = $bestReadGbps
        TotalDrainTimeSeconds    = [math]::Round($bestTotalMs/1000, 3)
        EffectivePayloadGBps     = $bestPayloadGBps
        AggregatePCIeThroughput  = "$bestAggGBps GB/s"
    }

} finally {
    for($d=0;$d -lt 2;$d++){if($devices[$d] -ne [IntPtr]::Zero){[void]$vkDeviceWaitIdle.Invoke($devices[$d])}}
    for($d=0;$d -lt 2;$d++){if($pools[$d] -ne [IntPtr]::Zero){$vkDestroyCommandPool.Invoke($devices[$d],$pools[$d],[IntPtr]::Zero)}}
    foreach($b in $buffers){$vkDestroyBuffer.Invoke($devices[$b.Device],$b.Handle,[IntPtr]::Zero)}
    foreach($m in $memories){$vkFreeMemory.Invoke($devices[$m.Device],$m.Handle,[IntPtr]::Zero)}
    if($apertureHost -ne [IntPtr]::Zero){[void]$virtualFree.Invoke($apertureHost,[uint64]0,[uint32]0x8000)}
    for($d=0;$d -lt 2;$d++){if($devices[$d] -ne [IntPtr]::Zero){$vkDestroyDevice.Invoke($devices[$d],[IntPtr]::Zero)}}
    if($instance -ne [IntPtr]::Zero){$vkDestroyInstance.Invoke($instance,[IntPtr]::Zero)}
    foreach($b in $blocks){$api.FreeBuffer($b)}
    $api.Dispose()
}
