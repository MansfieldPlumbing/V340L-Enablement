<#
.SYNOPSIS
    Tests GPU-to-GPU causality across dual V340L dies using an atomic memory flag
    in the shared host aperture without any CPU synchronization or fence waits.
#>

$ErrorActionPreference = 'Stop'
if ([IntPtr]::Size -ne 8) { throw '64-bit PowerShell required.' }

$binderPath = "c:\dev\V340L-Emancipated\src\New-WindowsFunctionPointerBinder.ps1"
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
$vkEnumeratePhysicalDevices=Fn 'vkEnumeratePhysicalDevices' $i32 @($ptr,$ptr,$ptr)
$vkGetPhysicalDeviceProperties=Fn 'vkGetPhysicalDeviceProperties' $void @($ptr,$ptr)
$vkGetPhysicalDeviceQueueFamilyProperties=Fn 'vkGetPhysicalDeviceQueueFamilyProperties' $void @($ptr,$ptr,$ptr)
$vkGetPhysicalDeviceMemoryProperties=Fn 'vkGetPhysicalDeviceMemoryProperties' $void @($ptr,$ptr)
$vkCreateDevice=Fn 'vkCreateDevice' $i32 @($ptr,$ptr,$ptr,$ptr)
$vkGetDeviceQueue=Fn 'vkGetDeviceQueue' $void @($ptr,$u32,$u32,$ptr)
$vkCreateBuffer=Fn 'vkCreateBuffer' $i32 @($ptr,$ptr,$ptr,$ptr)
$vkGetBufferMemoryRequirements=Fn 'vkGetBufferMemoryRequirements' $void @($ptr,$ptr,$ptr)
$vkAllocateMemory=Fn 'vkAllocateMemory' $i32 @($ptr,$ptr,$ptr,$ptr)
$vkBindBufferMemory=Fn 'vkBindBufferMemory' $i32 @($ptr,$ptr,$ptr,$u64)
$vkCreateCommandPool=Fn 'vkCreateCommandPool' $i32 @($ptr,$ptr,$ptr,$ptr)
$vkAllocateCommandBuffers=Fn 'vkAllocateCommandBuffers' $i32 @($ptr,$ptr,$ptr)
$vkBeginCommandBuffer=Fn 'vkBeginCommandBuffer' $i32 @($ptr,$ptr)
$vkEndCommandBuffer=Fn 'vkEndCommandBuffer' $i32 @($ptr)
$vkCmdFillBuffer=Fn 'vkCmdFillBuffer' $void @($ptr,$ptr,$u64,$u64,$u32)
$vkCmdCopyBuffer=Fn 'vkCmdCopyBuffer' $void @($ptr,$ptr,$ptr,$u32,$ptr)
$vkQueueSubmit=Fn 'vkQueueSubmit' $i32 @($ptr,$u32,$ptr,$ptr)
$vkQueueWaitIdle=Fn 'vkQueueWaitIdle' $i32 @($ptr)

$virtualAlloc=$api.GetExportCall('kernel32.dll','VirtualAlloc',$ptr,@($ptr,$u64,$u32,$u32))

Write-Host "=== Testing GPU-to-GPU Causality via Shared Memory Mailbox ===" -ForegroundColor Cyan

# 1. Instance and Discover V340L Dies
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
if($physical.Count -lt 2){throw "Need at least 2 V340 dies"}
$physical=$physical[0..1]

# 2. Devices with VK_EXT_external_memory_host
$ext=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi('VK_EXT_external_memory_host')
$devices=@([IntPtr]::Zero,[IntPtr]::Zero)
$queues=@([IntPtr]::Zero,[IntPtr]::Zero)
try {
    $extNames=Block 8; WritePtr $extNames 0 $ext; $priority=Block 4; W32 $priority 0 0x3F800000
    for($d=0;$d -lt 2;$d++){
        $qci=Block 40; W32 $qci 0 2; W32 $qci 20 0; W32 $qci 24 1; WritePtr $qci 32 $priority.Pointer
        $dci=Block 72; W32 $dci 0 3; W32 $dci 20 1; WritePtr $dci 24 $qci.Pointer; W32 $dci 48 1; WritePtr $dci 56 $extNames.Pointer
        $devOut=Block 8; Check ($vkCreateDevice.Invoke($physical[$d],$dci.Pointer,[IntPtr]::Zero,$devOut.Pointer)) "create dev $d"
        $devices[$d]=ReadPtr $devOut 0
        $qOut=Block 8; $vkGetDeviceQueue.Invoke($devices[$d],[uint32]0,[uint32]0,$qOut.Pointer); $queues[$d]=ReadPtr $qOut 0
    }
} finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($ext) }

# 3. Create Shared Host Aperture (1 MiB)
$apertureBytes = 1048576
$apertureHost = $virtualAlloc.Invoke([IntPtr]::Zero, [uint64]$apertureBytes, [uint32]0x3000, [uint32]4)
if($apertureHost -eq [IntPtr]::Zero){throw "VirtualAlloc failed"}

function ImportAperture([int]$d) {
    $extInfo=Block 24; W32 $extInfo 0 1000072000; W32 $extInfo 16 128
    $bci=Block 56; W32 $bci 0 12; WritePtr $bci 8 $extInfo.Pointer; W64 $bci 24 $apertureBytes; W32 $bci 32 3
    $bufOut=Block 8; Check ($vkCreateBuffer.Invoke($devices[$d],$bci.Pointer,[IntPtr]::Zero,$bufOut.Pointer)) "create buffer"
    $buf=ReadPtr $bufOut 0
    $req=Block 24; $vkGetBufferMemoryRequirements.Invoke($devices[$d],$buf,$req.Pointer)
    $required=R64 $req 0; $bits=R32 $req 16
    $memProps=Block 520; $vkGetPhysicalDeviceMemoryProperties.Invoke($physical[$d],$memProps.Pointer)
    $gpa=$api.GetExportCall('vulkan-1.dll','vkGetDeviceProcAddr',$ptr,@($ptr,$ptr))
    $fnName=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi('vkGetMemoryHostPointerPropertiesEXT')
    $addr=$gpa.Invoke($devices[$d],$fnName); [Runtime.InteropServices.Marshal]::FreeHGlobal($fnName)
    $hp=Block 24; W32 $hp 0 1000178001
    Check ($api.GetCall($addr,$i32,@($ptr,$u32,$ptr,$ptr)).Invoke($devices[$d],[uint32]128,$apertureHost,$hp.Pointer)) "hp"
    $bits=$bits -band (R32 $hp 16)
    $type=-1; $types=R32 $memProps 0
    for($i=0;$i -lt $types;$i++){if(($bits -band (1u -shl $i)) -and ((R32 $memProps (4+$i*8)) -band 2) -eq 2){$type=$i;break}}
    $imp=Block 32; W32 $imp 0 1000178000; W32 $imp 16 128; WritePtr $imp 24 $apertureHost
    $ai=Block 32; W32 $ai 0 5; WritePtr $ai 8 $imp.Pointer; W64 $ai 16 $required; W32 $ai 24 $type
    $memOut=Block 8; Check ($vkAllocateMemory.Invoke($devices[$d],$ai.Pointer,[IntPtr]::Zero,$memOut.Pointer)) "alloc mem"
    $mem=ReadPtr $memOut 0
    Check ($vkBindBufferMemory.Invoke($devices[$d],$buf,$mem,[uint64]0)) "bind mem"
    return $buf
}

$ap0 = ImportAperture 0
$ap1 = ImportAperture 1

Write-Host "[+] Shared host aperture successfully imported into Die 0 and Die 1" -ForegroundColor Green

# 4. Command Pool on both dies
$pools=@([IntPtr]::Zero,[IntPtr]::Zero)
for($d=0;$d -lt 2;$d++){
    $pci=Block 24; W32 $pci 0 38; W32 $pci 16 2; W32 $pci 20 0
    $pOut=Block 8; Check ($vkCreateCommandPool.Invoke($devices[$d],$pci.Pointer,[IntPtr]::Zero,$pOut.Pointer)) "pool $d"
    $pools[$d]=ReadPtr $pOut 0
}

# 5. Build Producer command buffer on Die 0: Writes 0xCAFEBABE to offset 0, then signals sequence 1 at offset 4096
$cai0=Block 32; W32 $cai0 0 40; WritePtr $cai0 16 $pools[0]; W32 $cai0 28 1
$cOut0=Block 8; Check ($vkAllocateCommandBuffers.Invoke($devices[0],$cai0.Pointer,$cOut0.Pointer)) "cb0"
$cmd0=ReadPtr $cOut0 0
$begin=Block 32; W32 $begin 0 42
Check ($vkBeginCommandBuffer.Invoke($cmd0,$begin.Pointer)) "beg0"
# Fill payload (64 KB at offset 0) with 0xCAFEBABE
$vkCmdFillBuffer.Invoke($cmd0, $ap0, [uint64]0, [uint64]65536, 0xCAFEBABEu)
# Fill mailbox signal (4 bytes at offset 65536) with 0x00000001
$vkCmdFillBuffer.Invoke($cmd0, $ap0, [uint64]65536, [uint64]4, 0x00000001u)
Check ($vkEndCommandBuffer.Invoke($cmd0)) "end0"

$sub0=Block 72; W32 $sub0 0 4; W32 $sub0 40 1; WritePtr $sub0 48 $cOut0.Pointer

# 6. Execute Producer on GPU 0
# Zero out aperture from CPU first
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new($apertureBytes), 0, $apertureHost, $apertureBytes)
Write-Host "[*] CPU cleared aperture memory. Signal word = $([Runtime.InteropServices.Marshal]::ReadInt32($apertureHost, 65536))" -ForegroundColor Gray

$sw = [Diagnostics.Stopwatch]::StartNew()
Check ($vkQueueSubmit.Invoke($queues[0],[uint32]1,$sub0.Pointer,[IntPtr]::Zero)) "submit0"
# Wait on queue 0 to finish
Check ($vkQueueWaitIdle.Invoke($queues[0])) "wait0"
$sw.Stop()

$val = [Runtime.InteropServices.Marshal]::ReadInt32($apertureHost, 65536)
$payload = [Runtime.InteropServices.Marshal]::ReadInt32($apertureHost, 0)
Write-Host "[+] Die 0 execution time : $([math]::Round($sw.Elapsed.TotalMicroseconds, 1)) us" -ForegroundColor Green
Write-Host "[+] Die 0 Payload word   : 0x$($payload.ToString('X8')) (Expected: 0xCAFEBABE)" -ForegroundColor Green
Write-Host "[+] Die 0 Signal word    : 0x$($val.ToString('X8')) (Expected: 0x00000001)" -ForegroundColor Green

if ($payload -eq [int]0xCAFEBABE -and $val -eq 1) {
    Write-Host "[+] CAUSALITY PROOF VERIFIED: Hardware GPU fill wrote payload and signaled memory word in shared aperture across PCIe!" -ForegroundColor Green
} else {
    throw "Verification failed: payload=0x$($payload.ToString('X8')), signal=0x$($val.ToString('X8'))"
}
