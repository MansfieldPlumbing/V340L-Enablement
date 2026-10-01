<#
.SYNOPSIS
    Native D3D12 cross-adapter queue-wait and shared-buffer transport test.
.DESCRIPTION
    PowerShell-only COM/vtable calls. Consumer waits and copies are submitted
    BEFORE producer publication. No host completion checks bridge either queue.
    One terminal event wait permits diagnostic readback after all GPU work.
    This tests D3D12 copies, not Vulkan interop or direct shader consumption.
#>
[CmdletBinding()]
param(
    [ValidateRange(0,15)][int]$ProducerOrdinal=0,
    [ValidateRange(0,15)][int]$ConsumerOrdinal=1,
    [ValidateRange(1,64)][int]$Packets=32,
    [ValidateRange(16,16384)][int]$WordsPerPacket=1024,
    [ValidateRange(100,10000)][int]$TimeoutMilliseconds=5000,
    [string]$ReceiptPath,
    [switch]$VulkanFenceInterop
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ([IntPtr]::Size -ne 8) { throw 'x64 PowerShell required.' }
if ($ProducerOrdinal -eq $ConsumerOrdinal) { throw 'Select distinct adapters.' }
$interop=& "$PSScriptRoot\src\New-WindowsFunctionPointerBinder.ps1"
$blocks=[Collections.Generic.List[IntPtr]]::new()
$com=[Collections.Generic.List[IntPtr]]::new()
$handles=[Collections.Generic.List[IntPtr]]::new()
$operations=[Collections.Generic.List[object]]::new()
$inFlight=$false
$completed=$false
$result=[ordered]@{
    Status='FAIL'; Mode='Native D3D12 copy-queue fence and shared-heap transport'
    Packets=$Packets; WordsPerPacket=$WordsPerPacket
    FenceFlags='SHARED | SHARED_CROSS_ADAPTER (0x3)'
    HeapFlags='SHARED | SHARED_CROSS_ADAPTER (0x21)'
    ConsumerEnqueuedBeforeProducer=$false
    HostBoundaryCompletionChecks=0; TerminalEventWaits=0
    VulkanInteropTested=$false; ShaderConsumptionTested=$false
}
function Block([int]$Bytes) {
    $p=[Runtime.InteropServices.Marshal]::AllocHGlobal($Bytes)
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new($Bytes),0,$p,$Bytes)
    $blocks.Add($p); return $p
}
function W32([IntPtr]$P,[int]$O,[uint32]$V) {
    [Runtime.InteropServices.Marshal]::WriteInt32($P,$O,[BitConverter]::ToInt32([BitConverter]::GetBytes($V),0))
}
function W64([IntPtr]$P,[int]$O,[uint64]$V) { [Runtime.InteropServices.Marshal]::WriteInt64($P,$O,[long]$V) }
function WP([IntPtr]$P,[int]$O,[IntPtr]$V) { [Runtime.InteropServices.Marshal]::WriteIntPtr($P,$O,$V) }
function GuidBlock([string]$Value) {
    $p=Block 16; [Runtime.InteropServices.Marshal]::Copy(([Guid]$Value).ToByteArray(),0,$p,16); return $p
}
function Keep([IntPtr]$Pointer) {
    if ($Pointer -eq [IntPtr]::Zero) { throw 'Null COM interface.' }
    $com.Add($Pointer); return $Pointer
}
function Check([int]$Hr,[string]$Operation) {
    $formatted='0x{0:X8}' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes($Hr),0)
    $operations.Add([pscustomobject]@{Operation=$Operation; HRESULT=$formatted})
    if ($Hr -lt 0) { throw "$Operation failed: $formatted" }
}
function BufferDesc([uint64]$Bytes,[uint32]$Flags=0) {
    $p=Block 56; W32 $p 0 1; W64 $p 16 $Bytes; W32 $p 24 1
    [Runtime.InteropServices.Marshal]::WriteInt16($p,28,1)
    [Runtime.InteropServices.Marshal]::WriteInt16($p,30,1)
    W32 $p 36 1; W32 $p 44 1; W32 $p 48 $Flags; return $p
}
function ComCreate([IntPtr]$Device,[int]$Slot,[Type[]]$Types,[object[]]$Values,[string]$Label) {
    $out=Block 8
    $call=$interop.GetComCall($Device,$Slot,([int]),($Types+@([IntPtr])))
    $callArgs=@([IntPtr]$Device)+$Values+@([IntPtr]$out)
    Check ($call.DynamicInvoke([object[]]$callArgs)) $Label
    return (Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($out)))
}
function NewQueue([IntPtr]$Device) {
    $desc=Block 16; W32 $desc 0 3 # COPY queue
    ComCreate $Device 8 @([IntPtr],[IntPtr]) @($desc,$iidQueue) 'CreateCommandQueue(COPY)'
}
function NewFence([IntPtr]$Device,[uint32]$Flags) {
    ComCreate $Device 36 @([uint64],[uint32],[IntPtr]) @([uint64]0,$Flags,$iidFence) "CreateFence(flags=$Flags)"
}
function Share([IntPtr]$Device,[IntPtr]$Object,[string]$Label) {
    $out=Block 8
    $call=$interop.GetComCall($Device,31,([int]),@([IntPtr],[IntPtr],[uint32],[IntPtr],[IntPtr]))
    Check ($call.DynamicInvoke($Device,$Object,[IntPtr]::Zero,[uint32]0x10000000,[IntPtr]::Zero,$out)) "CreateSharedHandle($Label)"
    $handle=[Runtime.InteropServices.Marshal]::ReadIntPtr($out)
    if ($handle -eq [IntPtr]::Zero) { throw 'Null shared handle.' }
    $handles.Add($handle); return $handle
}
function Open([IntPtr]$Device,[IntPtr]$Handle,[IntPtr]$Iid,[string]$Label) {
    ComCreate $Device 32 @([IntPtr],[IntPtr]) @($Handle,$Iid) "OpenSharedHandle($Label)"
}
function Committed([IntPtr]$Device,[uint32]$HeapType,[uint32]$State,[uint64]$Bytes) {
    $properties=Block 24; W32 $properties 0 $HeapType; W32 $properties 12 1; W32 $properties 16 1
    $desc=BufferDesc $Bytes
    ComCreate $Device 27 @([IntPtr],[uint32],[IntPtr],[uint32],[IntPtr],[IntPtr]) @($properties,[uint32]0,$desc,$State,[IntPtr]::Zero,$iidResource) "CreateCommittedResource(heap=$HeapType)"
}
function Placed([IntPtr]$Device,[IntPtr]$Heap,[uint64]$Bytes) {
    $desc=BufferDesc $Bytes 0x10
    ComCreate $Device 29 @([IntPtr],[uint64],[IntPtr],[uint32],[IntPtr],[IntPtr]) @($Heap,[uint64]0,$desc,[uint32]0,[IntPtr]::Zero,$iidResource) 'CreatePlacedResource(shared buffer)'
}
function Transition([IntPtr]$List,[IntPtr]$Resource,[uint32]$Before,[uint32]$After) {
    $b=Block 32; WP $b 8 $Resource; W32 $b 16 ([uint32]::MaxValue); W32 $b 20 $Before; W32 $b 24 $After
    $call=$interop.GetComCall($List,26,([void]),@([uint32],[IntPtr]))
    [void]$call.DynamicInvoke($List,[uint32]1,$b)
}
function CopyList([IntPtr]$Device,[IntPtr]$Dst,[IntPtr]$Src,[uint64]$Offset,[uint64]$Bytes,[bool]$Producer) {
    $allocator=ComCreate $Device 9 @([uint32],[IntPtr]) @([uint32]3,$iidAllocator) 'CreateCommandAllocator(COPY)'
    $list=ComCreate $Device 12 @([uint32],[uint32],[IntPtr],[IntPtr],[IntPtr]) @([uint32]0,[uint32]3,$allocator,[IntPtr]::Zero,$iidList) 'CreateCommandList(COPY)'
    if ($Producer) { Transition $list $Dst 0 0x400 } else { Transition $list $Src 0 0x800 }
    $copy=$interop.GetComCall($list,15,([void]),@([IntPtr],[uint64],[IntPtr],[uint64],[uint64]))
    [void]$copy.DynamicInvoke($list,$Dst,$Offset,$Src,$Offset,$Bytes)
    if ($Producer) { Transition $list $Dst 0x400 0 } else { Transition $list $Src 0x800 0 }
    $close=$interop.GetComCall($list,9,([int]),@())
    Check ($close.DynamicInvoke($list)) 'Close(COPY list)'
    $p=Block 8; WP $p 0 $list; return $p
}
function VkExport([string]$Name,[Type]$Return,[Type[]]$Parameters) {
    $interop.GetExportCall('C:\Windows\System32\vulkan-1.dll',$Name,$Return,$Parameters)
}
function VkCheck([int]$Code,[string]$Label) {
    $vkSteps.Add([pscustomobject]@{Operation=$Label; VkResult=$Code})
    if ($Code -ne 0) { throw "$Label returned VkResult=$Code" }
}
function Invoke-VulkanFenceInterop([bool]$CrossDevice) {
    $vkSteps=[Collections.Generic.List[object]]::new()
    $vkResources=[Collections.Generic.List[object]]::new()
    $vkInstance=[IntPtr]::Zero
    $vkSubmitted=$false
    $vkFinished=$false
    $vkResult=[ordered]@{Mode=$(if ($CrossDevice) {'CrossDevice'} else {'SameDeviceControl'}); Status='FAIL'; PayloadTested=$false; NativeFenceFlags=3; VkSemaphoreType='Binary'; FenceValue=1; HostBoundaryCompletionChecks=0}
    try {
        $createInstance=VkExport 'vkCreateInstance' ([int]) @([IntPtr],[IntPtr],[IntPtr])
        $enumeratePhysical=VkExport 'vkEnumeratePhysicalDevices' ([int]) @([IntPtr],[IntPtr],[IntPtr])
        $getProperties2=VkExport 'vkGetPhysicalDeviceProperties2' ([void]) @([IntPtr],[IntPtr])
        $getFamilies=VkExport 'vkGetPhysicalDeviceQueueFamilyProperties' ([void]) @([IntPtr],[IntPtr],[IntPtr])
        $createVkDevice=VkExport 'vkCreateDevice' ([int]) @([IntPtr],[IntPtr],[IntPtr],[IntPtr])
        $getQueue=VkExport 'vkGetDeviceQueue' ([void]) @([IntPtr],[uint32],[uint32],[IntPtr])
        $getProc=VkExport 'vkGetDeviceProcAddr' ([IntPtr]) @([IntPtr],[string])
        $app=Block 48; W32 $app 44 0x401000
        $ci=Block 64; W32 $ci 0 1; WP $ci 24 $app
        $out=Block 8; VkCheck ($createInstance.Invoke($ci,[IntPtr]::Zero,$out)) 'vkCreateInstance(1.1)'
        $vkInstance=[Runtime.InteropServices.Marshal]::ReadIntPtr($out)
        $count=Block 4; VkCheck ($enumeratePhysical.Invoke($vkInstance,$count,[IntPtr]::Zero)) 'vkEnumeratePhysicalDevices(count)'
        $physicalCount=[Runtime.InteropServices.Marshal]::ReadInt32($count)
        $physicalList=Block ($physicalCount*8); VkCheck ($enumeratePhysical.Invoke($vkInstance,$count,$physicalList)) 'vkEnumeratePhysicalDevices(list)'
        $matches=[Collections.Generic.Dictionary[string,object]]::new()
        for ($i=0;$i -lt $physicalCount;$i++) {
            $physical=[Runtime.InteropServices.Marshal]::ReadIntPtr($physicalList,$i*8)
            $ids=Block 64; W32 $ids 0 1000071004
            $props=Block 1040; W32 $props 0 1000059001; WP $props 8 $ids
            [void]$getProperties2.Invoke($physical,$props)
            if ([Runtime.InteropServices.Marshal]::ReadInt32($props,24) -ne 0x1002) { continue }
            if ([Runtime.InteropServices.Marshal]::ReadInt32($ids,60) -ne 1) { continue }
            $bytes=[byte[]]::new(8); [Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($ids,48),$bytes,0,8)
            $luid=[Convert]::ToHexString($bytes)
            $uuid=[byte[]]::new(16); [Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($ids,16),$uuid,0,16)
            $matches[$luid]=[pscustomobject]@{Physical=$physical; Ordinal=$i; UUID=[Convert]::ToHexString($uuid)}
        }
        $destLuid=if ($CrossDevice) {$consumer.LUID} else {$producer.LUID}
        if (-not $matches.ContainsKey($producer.LUID) -or -not $matches.ContainsKey($destLuid)) { throw 'DXGI-to-Vulkan LUID mapping failed.' }
        $vkResult.ProducerPhysicalOrdinal=$matches[$producer.LUID].Ordinal
        $vkResult.ConsumerPhysicalOrdinal=$matches[$destLuid].Ordinal
        $vkResult.ProducerUUID=$matches[$producer.LUID].UUID
        $vkResult.ConsumerUUID=$matches[$destLuid].UUID
        # D3D12 owns the fence; Vulkan imports it without requesting Vulkan export.
        $nativeFence=NewFence $d0 3
        $nativeHandle=Share $d0 $nativeFence "Vulkan $($vkResult.Mode) fence"
        $extensions=@('VK_KHR_external_semaphore','VK_KHR_external_semaphore_win32')
        $extensionNames=Block ($extensions.Count*8)
        for ($i=0;$i -lt $extensions.Count;$i++) {
            $str=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($extensions[$i]); $blocks.Add($str); WP $extensionNames ($i*8) $str
        }
        foreach ($luid in @($producer.LUID,$destLuid)) {
            $physical=$matches[$luid].Physical
            [void]$getFamilies.Invoke($physical,$count,[IntPtr]::Zero)
            $familyCount=[Runtime.InteropServices.Marshal]::ReadInt32($count)
            $families=Block ($familyCount*24); [void]$getFamilies.Invoke($physical,$count,$families)
            $family=-1
            for ($i=0;$i -lt $familyCount;$i++) {
                if (([Runtime.InteropServices.Marshal]::ReadInt32($families,$i*24) -band 2) -ne 0) { $family=$i; break }
            }
            if ($family -lt 0) { throw 'No compute queue family.' }
            $priority=Block 4; W32 $priority 0 0x3F800000
            $qci=Block 40; W32 $qci 0 2; W32 $qci 20 $family; W32 $qci 24 1; WP $qci 32 $priority
            $dci=Block 72; W32 $dci 0 3; W32 $dci 20 1; WP $dci 24 $qci; W32 $dci 48 $extensions.Count; WP $dci 56 $extensionNames
            $out=Block 8; VkCheck ($createVkDevice.Invoke($physical,$dci,[IntPtr]::Zero,$out)) "vkCreateDevice(LUID=$luid)"
            $device=[Runtime.InteropServices.Marshal]::ReadIntPtr($out)
            $resource=[pscustomobject]@{Device=$device; Semaphore=[uint64]0; Fence=[uint64]0; Queue=[IntPtr]::Zero}
            $vkResources.Add($resource)
            $out=Block 8; [void]$getQueue.Invoke($device,[uint32]$family,[uint32]0,$out)
            $resource.Queue=[Runtime.InteropServices.Marshal]::ReadIntPtr($out)
            $createSemaphore=$interop.GetCall($getProc.Invoke($device,'vkCreateSemaphore'),([int]),@([IntPtr],[IntPtr],[IntPtr],[IntPtr]))
            $sci=Block 24; W32 $sci 0 9; $out=Block 8
            VkCheck ($createSemaphore.Invoke($device,$sci,[IntPtr]::Zero,$out)) 'vkCreateSemaphore(binary)'
            $resource.Semaphore=[uint64][Runtime.InteropServices.Marshal]::ReadInt64($out)
            $import=$interop.GetCall($getProc.Invoke($device,'vkImportSemaphoreWin32HandleKHR'),([int]),@([IntPtr],[IntPtr]))
            $info=Block 48; W32 $info 0 1000078000; W64 $info 16 $resource.Semaphore; W32 $info 28 8; WP $info 32 $nativeHandle
            # sType imported from the installed Vulkan ABI: IMPORT_SEMAPHORE_WIN32_HANDLE_INFO_KHR.
            VkCheck ($import.Invoke($device,$info)) "vkImportSemaphoreWin32HandleKHR(D3D12_FENCE,LUID=$luid)"
        }
        $src=$vkResources[0]; $dst=$vkResources[1]
        $createFence=$interop.GetCall($getProc.Invoke($dst.Device,'vkCreateFence'),([int]),@([IntPtr],[IntPtr],[IntPtr],[IntPtr]))
        $fci=Block 24; W32 $fci 0 8; $out=Block 8
        VkCheck ($createFence.Invoke($dst.Device,$fci,[IntPtr]::Zero,$out)) 'vkCreateFence(terminal)'
        $dst.Fence=[uint64][Runtime.InteropServices.Marshal]::ReadInt64($out)
        $semDst=Block 8; W64 $semDst 0 $dst.Semaphore
        $semSrc=Block 8; W64 $semSrc 0 $src.Semaphore
        $value=Block 8; W64 $value 0 1
        $stages=Block 4; W32 $stages 0 0x10000
        # Explicit D3D12 fence values on binary imported semaphores.
        $waitValues=Block 48; W32 $waitValues 0 1000078002; W32 $waitValues 16 1; WP $waitValues 24 $value
        $waitSubmit=Block 72; W32 $waitSubmit 0 4; WP $waitSubmit 8 $waitValues
        W32 $waitSubmit 16 1; WP $waitSubmit 24 $semDst; WP $waitSubmit 32 $stages
        $signalValues=Block 48; W32 $signalValues 0 1000078002; W32 $signalValues 32 1; WP $signalValues 40 $value
        $signalSubmit=Block 72; W32 $signalSubmit 0 4; WP $signalSubmit 8 $signalValues
        W32 $signalSubmit 56 1; WP $signalSubmit 64 $semSrc
        $submitDst=$interop.GetCall($getProc.Invoke($dst.Device,'vkQueueSubmit'),([int]),@([IntPtr],[uint32],[IntPtr],[uint64]))
        $submitSrc=$interop.GetCall($getProc.Invoke($src.Device,'vkQueueSubmit'),([int]),@([IntPtr],[uint32],[IntPtr],[uint64]))
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $code=$submitDst.Invoke($dst.Queue,[uint32]1,$waitSubmit,$dst.Fence)
        $watch.Stop(); $vkResult.ConsumerSubmitApiMilliseconds=$watch.Elapsed.TotalMilliseconds
        VkCheck $code 'vkQueueSubmit(consumer wait,D3D12 value=1)'
        $vkSubmitted=$true
        VkCheck ($submitSrc.Invoke($src.Queue,[uint32]1,$signalSubmit,[uint64]0)) 'vkQueueSubmit(producer signal,D3D12 value=1)'
        $waitFence=$interop.GetCall($getProc.Invoke($dst.Device,'vkWaitForFences'),([int]),@([IntPtr],[uint32],[IntPtr],[uint32],[uint64]))
        $terminalFence=Block 8; W64 $terminalFence 0 $dst.Fence
        VkCheck ($waitFence.Invoke($dst.Device,[uint32]1,$terminalFence,[uint32]1,[uint64]($TimeoutMilliseconds*1000000L))) 'vkWaitForFences(terminal only)'
        $vkFinished=$true
        $getValue=$interop.GetComCall($nativeFence,8,([uint64]),@())
        $vkResult.NativeFenceCompletedValue=$getValue.DynamicInvoke($nativeFence)
        if ($vkResult.NativeFenceCompletedValue -lt 1) { throw 'Native D3D12 fence did not reach value 1.' }
        $vkResult.Status='PASS'
    } catch { $vkResult.Error=$_.Exception.Message }
    finally {
        $vkResult.Operations=$vkSteps.ToArray()
        if (-not $vkSubmitted -or $vkFinished) {
            for ($i=$vkResources.Count-1;$i -ge 0;$i--) {
                $resource=$vkResources[$i]
                if ($resource.Fence -ne 0) {
                    $destroy=$interop.GetCall($getProc.Invoke($resource.Device,'vkDestroyFence'),([void]),@([IntPtr],[uint64],[IntPtr]))
                    [void]$destroy.Invoke($resource.Device,$resource.Fence,[IntPtr]::Zero)
                }
                if ($resource.Semaphore -ne 0) {
                    $destroy=$interop.GetCall($getProc.Invoke($resource.Device,'vkDestroySemaphore'),([void]),@([IntPtr],[uint64],[IntPtr]))
                    [void]$destroy.Invoke($resource.Device,$resource.Semaphore,[IntPtr]::Zero)
                }
                $destroy=$interop.GetCall($getProc.Invoke($resource.Device,'vkDestroyDevice'),([void]),@([IntPtr],[IntPtr]))
                [void]$destroy.Invoke($resource.Device,[IntPtr]::Zero)
            }
            if ($vkInstance -ne [IntPtr]::Zero) {
                $destroy=VkExport 'vkDestroyInstance' ([void]) @([IntPtr],[IntPtr]); [void]$destroy.Invoke($vkInstance,[IntPtr]::Zero)
            }
        } else { $script:completed=$false; $vkResult.Cleanup='Unfinished resources retained until process exits.' }
    }
    return [pscustomobject]$vkResult
}
try {
    $iidDevice=GuidBlock '189819f1-1db6-4b57-be54-1821339b85f7'
    $iidQueue=GuidBlock '0ec870a6-5d7e-4c22-8cfc-5baae07616ed'
    $iidFence=GuidBlock '0a753dcf-c4d8-4b91-adf6-be5a60d95a76'
    $iidHeap=GuidBlock '6b3b2502-6e51-45b3-90ee-9884265e8df3'
    $iidResource=GuidBlock '696442be-a72e-4059-bc79-5b5c98040fad'
    $iidAllocator=GuidBlock '6102dee4-af59-4b09-b999-b44d73f09b24'
    $iidList=GuidBlock '5b160d0f-ac1b-4185-8ba8-b3ae42a5a455'
    $iidFactory=GuidBlock '770aae78-f26f-4dba-a829-253c83d1b387'
    $createFactory=$interop.GetExportCall('C:\Windows\System32\dxgi.dll','CreateDXGIFactory1',([int]),@([IntPtr],[IntPtr]))
    $createDevice=$interop.GetExportCall('C:\Windows\System32\d3d12.dll','D3D12CreateDevice',([int]),@([IntPtr],[int],[IntPtr],[IntPtr]))
    $closeHandle=$interop.GetExportCall('C:\Windows\System32\kernel32.dll','CloseHandle',([bool]),@([IntPtr]))
    $out=Block 8; Check ($createFactory.Invoke($iidFactory,$out)) 'CreateDXGIFactory1'
    $factory=Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($out))
    $enum=$interop.GetComCall($factory,12,([int]),@([uint32],[IntPtr]))
    $v340s=[Collections.Generic.List[object]]::new()
    for ($index=0; ; $index++) {
        $out=Block 8; $hr=$enum.DynamicInvoke($factory,[uint32]$index,$out)
        if ([BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$hr),0) -eq 0x887A0002L) { break }
        Check $hr "EnumAdapters1($index)"
        $adapter=Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($out))
        $desc=Block 312; $getDesc=$interop.GetComCall($adapter,10,([int]),@([IntPtr]))
        Check ($getDesc.DynamicInvoke($adapter,$desc)) "GetDesc1($index)"
        $name=[Runtime.InteropServices.Marshal]::PtrToStringUni($desc,128).TrimEnd([char]0)
        $vendor=[Runtime.InteropServices.Marshal]::ReadInt32($desc,256)
        $deviceId=[Runtime.InteropServices.Marshal]::ReadInt32($desc,260)
        if ($vendor -eq 0x1002 -and $deviceId -eq 0x6864 -and $name -match 'V340') {
            $luidBytes=[byte[]]::new(8); [Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($desc,296),$luidBytes,0,8)
            $v340s.Add([pscustomobject]@{Adapter=$adapter; DXGIIndex=$index; Name=$name; LUID=[Convert]::ToHexString($luidBytes)})
        }
    }
    if ($ProducerOrdinal -ge $v340s.Count -or $ConsumerOrdinal -ge $v340s.Count) { throw "Found only $($v340s.Count) V340 adapters." }
    $producer=$v340s[$ProducerOrdinal]; $consumer=$v340s[$ConsumerOrdinal]
    if ($producer.LUID -eq $consumer.LUID) { throw 'Adapters have identical LUIDs.' }
    $result.Producer=[ordered]@{Ordinal=$ProducerOrdinal; DXGIIndex=$producer.DXGIIndex; LUID=$producer.LUID; Name=$producer.Name}
    $result.Consumer=[ordered]@{Ordinal=$ConsumerOrdinal; DXGIIndex=$consumer.DXGIIndex; LUID=$consumer.LUID; Name=$consumer.Name}
    $devices=[Collections.Generic.List[IntPtr]]::new()
    foreach ($target in @($producer,$consumer)) {
        $out=Block 8; Check ($createDevice.Invoke($target.Adapter,0xB000,$iidDevice,$out)) "D3D12CreateDevice(DXGI $($target.DXGIIndex))"
        $devices.Add((Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($out))))
    }
    $d0=$devices[0]; $d1=$devices[1]
    $q0=NewQueue $d0; $q1=NewQueue $d1
    $publication=NewFence $d0 3
    $publicationHandle=Share $d0 $publication 'cross-adapter fence'
    $importedPublication=Open $d1 $publicationHandle $iidFence 'cross-adapter fence'
    $terminal=NewFence $d1 0
    $packetBytes=[uint64]$WordsPerPacket*4; $totalBytes=$packetBytes*$Packets
    $result.PayloadBytes=$totalBytes
    $heapDesc=Block 48
    W64 $heapDesc 0 ([uint64]([Math]::Ceiling($totalBytes/65536.0)*65536))
    W32 $heapDesc 8 1; W32 $heapDesc 20 1; W32 $heapDesc 24 1
    W64 $heapDesc 32 65536; W32 $heapDesc 40 0x21
    $sharedHeap=ComCreate $d0 28 @([IntPtr],[IntPtr]) @($heapDesc,$iidHeap) 'CreateHeap(cross-adapter)'
    $heapHandle=Share $d0 $sharedHeap 'cross-adapter heap'
    $importedHeap=Open $d1 $heapHandle $iidHeap 'cross-adapter heap'
    $arena0=Placed $d0 $sharedHeap $totalBytes
    $arena1=Placed $d1 $importedHeap $totalBytes
    $upload=Committed $d0 2 0xAC3 $totalBytes
    $readback=Committed $d1 3 0x400 $totalBytes
    # Initial diagnostic fixture only; no CPU copies connect the two adapters.
    $mappedOut=Block 8; $emptyRange=Block 16
    $map=$interop.GetComCall($upload,8,([int]),@([uint32],[IntPtr],[IntPtr]))
    Check ($map.DynamicInvoke($upload,[uint32]0,$emptyRange,$mappedOut)) 'Map(initial fixture)'
    $mapped=[Runtime.InteropServices.Marshal]::ReadIntPtr($mappedOut)
    for ($p=0;$p -lt $Packets;$p++) {
        for ($w=0;$w -lt $WordsPerPacket;$w++) { W32 $mapped (($p*$WordsPerPacket+$w)*4) ([uint32](0x34000000L+($p+1)*65536+$w)) }
    }
    $unmap=$interop.GetComCall($upload,9,([void]),@([uint32],[IntPtr])); [void]$unmap.DynamicInvoke($upload,[uint32]0,[IntPtr]::Zero)
    $producerLists=[Collections.Generic.List[IntPtr]]::new(); $consumerLists=[Collections.Generic.List[IntPtr]]::new()
    for ($p=0;$p -lt $Packets;$p++) {
        $producerLists.Add((CopyList $d0 $arena0 $upload ([uint64]($p*$packetBytes)) $packetBytes $true))
        $consumerLists.Add((CopyList $d1 $readback $arena1 ([uint64]($p*$packetBytes)) $packetBytes $false))
    }
    $queueWait=$interop.GetComCall($q1,15,([int]),@([IntPtr],[uint64]))
    $execute0=$interop.GetComCall($q0,10,([void]),@([uint32],[IntPtr]))
    $execute1=$interop.GetComCall($q1,10,([void]),@([uint32],[IntPtr]))
    $signal0=$interop.GetComCall($q0,14,([int]),@([IntPtr],[uint64]))
    $signal1=$interop.GetComCall($q1,14,([int]),@([IntPtr],[uint64]))
    # Bind terminal APIs before submission, avoiding any dependency on host progress.
    $createEvent=$interop.GetExportCall('C:\Windows\System32\kernel32.dll','CreateEventW',([IntPtr]),@([IntPtr],[bool],[bool],[IntPtr]))
    $event=$createEvent.Invoke([IntPtr]::Zero,$false,$false,[IntPtr]::Zero)
    if ($event -eq [IntPtr]::Zero) { throw 'CreateEventW failed.' }; $handles.Add($event)
    $setEvent=$interop.GetComCall($terminal,9,([int]),@([uint64],[IntPtr]))
    $terminalWait=$interop.GetExportCall('C:\Windows\System32\kernel32.dll','WaitForSingleObject',([uint32]),@([IntPtr],[uint32]))
    $waitDurations=[Collections.Generic.List[double]]::new()
    $inFlight=$true
    $submitWatch=[Diagnostics.Stopwatch]::StartNew()
    for ($p=0;$p -lt $Packets;$p++) {
        $callWatch=[Diagnostics.Stopwatch]::StartNew()
        $hr=$queueWait.DynamicInvoke($q1,$importedPublication,[uint64]($p+1))
        $callWatch.Stop(); $waitDurations.Add($callWatch.Elapsed.TotalMilliseconds)
        Check $hr "Consumer Queue::Wait(sequence=$($p+1))"
        [void]$execute1.DynamicInvoke($q1,[uint32]1,$consumerLists[$p])
    }
    Check ($signal1.DynamicInvoke($q1,$terminal,[uint64]1)) 'Consumer Queue::Signal(terminal)'
    $result.ConsumerEnqueuedBeforeProducer=$true
    for ($p=0;$p -lt $Packets;$p++) {
        [void]$execute0.DynamicInvoke($q0,[uint32]1,$producerLists[$p])
        Check ($signal0.DynamicInvoke($q0,$publication,[uint64]($p+1))) "Producer Queue::Signal(sequence=$($p+1))"
    }
    $submitWatch.Stop()
    $result.CpuSubmissionMilliseconds=[Math]::Round($submitWatch.Elapsed.TotalMilliseconds,4)
    $result.QueueWaitApiMilliseconds=$waitDurations.ToArray()
    # Terminal diagnostic wait only: all publications and consumers are enqueued.
    Check ($setEvent.DynamicInvoke($terminal,[uint64]1,$event)) 'SetEventOnCompletion(terminal only)'
    $result.TerminalEventWaits=1
    $endWatch=[Diagnostics.Stopwatch]::StartNew()
    $waitStatus=$terminalWait.Invoke($event,[uint32]$TimeoutMilliseconds)
    $endWatch.Stop(); $result.TerminalWaitMilliseconds=[Math]::Round($endWatch.Elapsed.TotalMilliseconds,4)
    $result.TerminalWaitStatus=$waitStatus
    if ($waitStatus -ne 0) { throw "Terminal experiment wait failed/timed out: $waitStatus" }
    $completed=$true
    $range=Block 16; W64 $range 8 $totalBytes
    $mappedOut=Block 8
    $map=$interop.GetComCall($readback,8,([int]),@([uint32],[IntPtr],[IntPtr]))
    Check ($map.DynamicInvoke($readback,[uint32]0,$range,$mappedOut)) 'Map(terminal diagnostic readback)'
    $mapped=[Runtime.InteropServices.Marshal]::ReadIntPtr($mappedOut)
    $mismatches=0; $firstMismatch=$null
    for ($p=0;$p -lt $Packets;$p++) {
        for ($w=0;$w -lt $WordsPerPacket;$w++) {
            $expected=[uint32](0x34000000L+($p+1)*65536+$w)
            $actual=[uint32][Runtime.InteropServices.Marshal]::ReadInt32($mapped,($p*$WordsPerPacket+$w)*4)
            if ($actual -ne $expected) {
                $mismatches++
                if ($null -eq $firstMismatch) { $firstMismatch=[pscustomobject]@{Packet=$p+1; Word=$w; Expected=$expected; Actual=$actual} }
            }
        }
    }
    $unmap=$interop.GetComCall($readback,9,([void]),@([uint32],[IntPtr])); [void]$unmap.DynamicInvoke($readback,[uint32]0,$emptyRange)
    $result.WordsVerified=$Packets*$WordsPerPacket; $result.Mismatches=$mismatches; $result.FirstMismatch=$firstMismatch
    if ($mismatches -ne 0) { throw "$mismatches payload word mismatches." }
    $result.Status='PASS'
    if ($VulkanFenceInterop) {
        $result.VulkanInteropTested=$true
        $control=Invoke-VulkanFenceInterop $false
        $result.VulkanSameDeviceControl=$control
        if ($control.Status -eq 'PASS') {
            $cross=Invoke-VulkanFenceInterop $true
            $result.VulkanCrossDevice=$cross
            if ($cross.Status -ne 'PASS') { $result.Status='PARTIAL'; $result.Error='Native D3D12 passed; Vulkan cross-device baton failed.' }
        } else { $result.Status='PARTIAL'; $result.Error='Native D3D12 passed; Vulkan same-device control failed. Cross-device not attempted.' }
    }
} catch {
    $result.Error=$_.Exception.Message
} finally {
    $result.Operations=$operations.ToArray()
    # Never free command/resource allocations still referenced by unfinished GPU work.
    if (-not $inFlight -or $completed) {
        if ($null -ne (Get-Variable closeHandle -ErrorAction SilentlyContinue)) {
            foreach ($handle in $handles) { [void]$closeHandle.Invoke($handle) }
        }
        for ($i=$com.Count-1;$i -ge 0;$i--) { [void]$interop.ReleaseCom($com[$i]) }
        foreach ($block in $blocks) { [Runtime.InteropServices.Marshal]::FreeHGlobal($block) }
        $interop.Dispose()
    } else { $result.Cleanup='Unfinished resources retained until test process exits.' }
}
$result.TimestampUtc=[DateTime]::UtcNow.ToString('o')
$json=$result | ConvertTo-Json -Depth 8
if ($ReceiptPath) { [IO.File]::WriteAllText($ReceiptPath,$json) }
$json
if ($result.Status -ne 'PASS') { exit 1 }
