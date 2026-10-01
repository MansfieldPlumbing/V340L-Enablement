<#
.SYNOPSIS
    Proves resident VRAM -> dedicated SDMA -> aperture -> cross-die baton -> consumer verifier.

.DESCRIPTION
    Full end-to-end multi-queue hardware ordering and payload visibility:
    1. Die 0 Compute generates word-varying patterns (base + i * step) in local VRAM (HBM2).
    2. Local GPU semaphore orders Die 0 Compute -> Die 0 SDMA transfer.
    3. Die 0 SDMA copies 21 regions into shared host aperture (VK_EXT_external_memory_host)
       and writes the manifest footer last with a transfer-to-transfer dependency.
    4. Release barrier flushes transfer writes before signaling the cross-adapter D3D12 fence.
    5. Die 1 waits on the D3D12 fence and dispatches ArenaFooterVerify-20260930.spv
       directly against the imported aperture.
    6. All three queue submissions are dispatched asynchronously with zero CPU waits.
    7. Host observes completion strictly via a single terminal fence on Die 1.
#>

[CmdletBinding()]
param(
    [ValidateRange(0, 3)] [int] $ProducerOrdinal = 0,
    [ValidateRange(0, 3)] [int] $ConsumerOrdinal = 1,
    [string] $ReceiptPath = 'C:\dev\V340L-Emancipated\GGML\Vulkan\Receipts\vulkan-resident-sdma-baton-20261001.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([IntPtr]::Size -ne 8) { throw '64-bit PowerShell required.' }

$interop = & "C:\dev\V340L-Emancipated\src\New-WindowsFunctionPointerBinder.ps1"
$blocks = [Collections.Generic.List[IntPtr]]::new()
$com = [Collections.Generic.List[IntPtr]]::new()
$handles = [Collections.Generic.List[IntPtr]]::new()

function Block([int]$Bytes) {
    $p = [Runtime.InteropServices.Marshal]::AllocHGlobal($Bytes)
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new($Bytes), 0, $p, $Bytes)
    $blocks.Add($p)
    return $p
}

function W32([IntPtr]$P, [int]$O, $V) {
    [Runtime.InteropServices.Marshal]::WriteInt32($P, $O, [int]$V)
}

function W64([IntPtr]$P, [int]$O, $V) {
    $signed = [BitConverter]::ToInt64([BitConverter]::GetBytes([uint64]$V), 0)
    [Runtime.InteropServices.Marshal]::WriteInt64($P, $O, $signed)
}

function WP([IntPtr]$P, [int]$O, [IntPtr]$V) {
    [Runtime.InteropServices.Marshal]::WriteIntPtr($P, $O, $V)
}

function GuidBlock([string]$Value) {
    $p = Block 16
    [Runtime.InteropServices.Marshal]::Copy(([Guid]$Value).ToByteArray(), 0, $p, 16)
    return $p
}

function Keep([IntPtr]$Pointer) {
    if ($Pointer -eq [IntPtr]::Zero) { throw 'Null COM interface.' }
    $com.Add($Pointer)
    return $Pointer
}

function CheckHR([int]$Hr, [string]$Op) {
    if ($Hr -lt 0) { throw "$Op failed: 0x{0:X8}" -f [BitConverter]::ToUInt32([BitConverter]::GetBytes($Hr), 0) }
}

function CheckVK([int]$Res, [string]$Op) {
    if ($Res -ne 0) { throw "$Op returned VkResult=$Res" }
}

function Fn([string]$Name, $Ret, [Type[]]$Params) {
    $retStr = "$Ret".Trim('[]')
    $retType = if ($Ret -is [Type]) { 
        $Ret 
    } elseif ($retStr -match '^(int|int32|System\.Int32)$') { 
        [int] 
    } elseif ($retStr -match '^(void|System\.Void)$') { 
        [void] 
    } else { 
        [IntPtr] 
    }
    $interop.GetExportCall('C:\Windows\System32\vulkan-1.dll', $Name, $retType, $Params)
}

$spvGenPath = 'C:\dev\V340L-Emancipated\GGML\Vulkan\ArenaPatternGenerate.spv'
$spvVerifyPath = 'C:\dev\V340L-Emancipated\GGML\Vulkan\ArenaFooterVerify-20260930.spv'
if (-not (Test-Path -LiteralPath $spvGenPath)) { throw "Missing $spvGenPath" }
if (-not (Test-Path -LiteralPath $spvVerifyPath)) { throw "Missing $spvVerifyPath" }
$genShaderBytes = [IO.File]::ReadAllBytes($spvGenPath)
$verifyShaderBytes = [IO.File]::ReadAllBytes($spvVerifyPath)

Write-Host "=== Resident VRAM -> SDMA -> Aperture -> GPU Baton Proof ===" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# 1. DXGI & D3D12 Cross-Adapter Fence Setup
# -----------------------------------------------------------------------------
Write-Host "[1/6] Setting up D3D12 cross-adapter fence..." -ForegroundColor Yellow

$createFactory = $interop.GetExportCall('dxgi.dll', 'CreateDXGIFactory1', [int], @([IntPtr], [IntPtr]))
$createD3D12Device = $interop.GetExportCall('d3d12.dll', 'D3D12CreateDevice', [int], @([IntPtr], [int], [IntPtr], [IntPtr]))

$iidFactory = GuidBlock '770aae78-f26f-4dba-a829-253c83d1b387'
$iidD3D12Device = GuidBlock '189819f1-1db6-4b57-be54-1821339b85f7'
$iidFence = GuidBlock '0a753dcf-c4d8-4b91-adf6-be5a60d95a76'

$outFactory = Block 8
CheckHR ($createFactory.Invoke($iidFactory, $outFactory)) 'CreateDXGIFactory1'
$factory = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($outFactory))

$enumAdapters = $interop.GetComCall($factory, 12, [int], @([uint32], [IntPtr]))
$dxgiAdapters = [Collections.Generic.List[object]]::new()
$idx = 0
while ($true) {
    $outAdapter = Block 8
    $hr = $enumAdapters.DynamicInvoke($factory, [uint32]$idx, $outAdapter)
    if ($hr -lt 0) { break }
    $adPtr = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($outAdapter))
    
    $desc = Block 312
    $getDesc = $interop.GetComCall($adPtr, 10, [int], @([IntPtr]))
    CheckHR ($getDesc.DynamicInvoke($adPtr, $desc)) "GetDesc1($idx)"
    $name = [Runtime.InteropServices.Marshal]::PtrToStringUni($desc, 128).TrimEnd([char]0)
    $vendorId = [Runtime.InteropServices.Marshal]::ReadInt32($desc, 256)
    $luidBytes = [byte[]]::new(8)
    [Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($desc, 296), $luidBytes, 0, 8)
    $luidHex = [Convert]::ToHexString($luidBytes)
    
    if ($vendorId -eq 0x1002 -and $name -match 'V340') {
        $dxgiAdapters.Add([pscustomobject]@{ Index=$idx; Name=$name; Adapter=$adPtr; LUID=$luidHex })
    }
    $idx++
}

if ($dxgiAdapters.Count -lt 2) { throw "Need at least 2 V340 adapters; found $($dxgiAdapters.Count)" }
$prodAdapter = $dxgiAdapters[$ProducerOrdinal]
$consAdapter = $dxgiAdapters[$ConsumerOrdinal]
Write-Host "  [+] Producer DXGI: $($prodAdapter.Index) (LUID: $($prodAdapter.LUID))" -ForegroundColor Gray
Write-Host "  [+] Consumer DXGI: $($consAdapter.Index) (LUID: $($consAdapter.LUID))" -ForegroundColor Gray

$outD3DDev = Block 8
CheckHR ($createD3D12Device.Invoke($prodAdapter.Adapter, 0xB000, $iidD3D12Device, $outD3DDev)) 'D3D12CreateDevice(Producer)'
$d3dDev0 = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($outD3DDev))

$createFenceD3D = $interop.GetComCall($d3dDev0, 36, [int], @([uint64], [uint32], [IntPtr], [IntPtr]))
$outFence = Block 8
CheckHR ($createFenceD3D.DynamicInvoke($d3dDev0, [uint64]0, [uint32]3, $iidFence, $outFence)) 'CreateFence(SHARED_CROSS_ADAPTER)'
$nativeFence = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($outFence))

$createShared = $interop.GetComCall($d3dDev0, 31, [int], @([IntPtr], [IntPtr], [uint32], [IntPtr], [IntPtr]))
$outHandle = Block 8
CheckHR ($createShared.DynamicInvoke($d3dDev0, $nativeFence, [IntPtr]::Zero, [uint32]0x10000000, [IntPtr]::Zero, $outHandle)) 'CreateSharedHandle'
$sharedFenceHandle = [Runtime.InteropServices.Marshal]::ReadIntPtr($outHandle)
$handles.Add($sharedFenceHandle)
Write-Host "  [+] Cross-Adapter Fence Shared Handle: 0x$($sharedFenceHandle.ToString('X'))" -ForegroundColor Green

# -----------------------------------------------------------------------------
# 2. Vulkan Device Creation, Queues, and D3D12 Fence Import
# -----------------------------------------------------------------------------
Write-Host "[2/6] Initializing Vulkan devices and queues..." -ForegroundColor Yellow

$vkCreateInstance = Fn 'vkCreateInstance' [int] @([IntPtr], [IntPtr], [IntPtr])
$vkDestroyInstance = Fn 'vkDestroyInstance' [void] @([IntPtr], [IntPtr])
$vkEnumeratePhysicalDevices = Fn 'vkEnumeratePhysicalDevices' [int] @([IntPtr], [IntPtr], [IntPtr])
$vkGetPhysicalDeviceProperties2 = Fn 'vkGetPhysicalDeviceProperties2' [void] @([IntPtr], [IntPtr])
$vkGetPhysicalDeviceQueueFamilyProperties = Fn 'vkGetPhysicalDeviceQueueFamilyProperties' [void] @([IntPtr], [IntPtr], [IntPtr])
$vkGetPhysicalDeviceMemoryProperties = Fn 'vkGetPhysicalDeviceMemoryProperties' [void] @([IntPtr], [IntPtr])
$vkCreateDevice = Fn 'vkCreateDevice' [int] @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
$vkDestroyDevice = Fn 'vkDestroyDevice' [void] @([IntPtr], [IntPtr])
$vkGetDeviceQueue = Fn 'vkGetDeviceQueue' [void] @([IntPtr], [uint32], [uint32], [IntPtr])
$vkGetDeviceProcAddr = Fn 'vkGetDeviceProcAddr' [IntPtr] @([IntPtr], [string])

$appInfo = Block 48; W32 $appInfo 44 0x00401000
$instCi = Block 64; W32 $instCi 0 1; WP $instCi 24 $appInfo
$outInst = Block 8
CheckVK ($vkCreateInstance.Invoke($instCi, [IntPtr]::Zero, $outInst)) 'vkCreateInstance'
$vkInstance = [Runtime.InteropServices.Marshal]::ReadIntPtr($outInst)

$outCount = Block 4
CheckVK ($vkEnumeratePhysicalDevices.Invoke($vkInstance, $outCount, [IntPtr]::Zero)) 'vkEnumeratePhysicalDevices(count)'
$physCount = [Runtime.InteropServices.Marshal]::ReadInt32($outCount)
$physList = Block ($physCount * 8)
CheckVK ($vkEnumeratePhysicalDevices.Invoke($vkInstance, $outCount, $physList)) 'vkEnumeratePhysicalDevices(list)'

$vkPhysMatches = [Collections.Generic.Dictionary[string, object]]::new()
for ($i = 0; $i -lt $physCount; $i++) {
    $pPhys = [Runtime.InteropServices.Marshal]::ReadIntPtr($physList, $i * 8)
    $idProps = Block 64; W32 $idProps 0 1000071004
    $props2 = Block 1040; W32 $props2 0 1000059001; WP $props2 8 $idProps
    $vkGetPhysicalDeviceProperties2.Invoke($pPhys, $props2)
    
    if ([Runtime.InteropServices.Marshal]::ReadInt32($props2, 24) -ne 0x1002) { continue }
    if ([Runtime.InteropServices.Marshal]::ReadInt32($idProps, 60) -ne 1) { continue }
    $lBytes = [byte[]]::new(8); [Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($idProps, 48), $lBytes, 0, 8)
    $lHex = [Convert]::ToHexString($lBytes)
    $uBytes = [byte[]]::new(16); [Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($idProps, 16), $uBytes, 0, 16)
    $uHex = [Convert]::ToHexString($uBytes)
    $vkPhysMatches[$lHex] = [pscustomobject]@{ Physical=$pPhys; Ordinal=$i; UUID=$uHex; LUID=$lHex }
}

$prodPhys = $vkPhysMatches[$prodAdapter.LUID].Physical
$consPhys = $vkPhysMatches[$consAdapter.LUID].Physical

$devExtensions = @(
    'VK_KHR_external_semaphore',
    'VK_KHR_external_semaphore_win32',
    'VK_EXT_external_memory_host'
)
$pExtNames = Block ($devExtensions.Count * 8)
for ($e = 0; $e -lt $devExtensions.Count; $e++) {
    $pStr = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($devExtensions[$e])
    $blocks.Add($pStr)
    WP $pExtNames ($e * 8) $pStr
}

# Discover queue families on Die 0: Compute (Flags 15 or 14) and Dedicated Transfer (Flags 12)
$outC0 = Block 4
$vkGetPhysicalDeviceQueueFamilyProperties.Invoke($prodPhys, $outC0, [IntPtr]::Zero)
$qfCount0 = [Runtime.InteropServices.Marshal]::ReadInt32($outC0)
$qfList0 = Block ($qfCount0 * 24)
$vkGetPhysicalDeviceQueueFamilyProperties.Invoke($prodPhys, $outC0, $qfList0)

$computeQf0 = -1
$transferQf0 = -1
for ($f = 0; $f -lt $qfCount0; $f++) {
    $flags = [Runtime.InteropServices.Marshal]::ReadInt32($qfList0, $f * 24)
    if (($flags -band 2) -ne 0 -and $computeQf0 -lt 0) { $computeQf0 = $f }
    if (($flags -band 4) -ne 0 -and ($flags -band 2) -eq 0 -and $transferQf0 -lt 0) { $transferQf0 = $f } # Dedicated SDMA
}
if ($computeQf0 -lt 0) { throw 'No compute queue family found on Die 0' }
if ($transferQf0 -lt 0) { $transferQf0 = $computeQf0 } # Fallback to shared transfer if no pure transfer family

Write-Host "  [+] Die 0 Queue Families: Compute=$computeQf0, Transfer=$transferQf0" -ForegroundColor Gray

# Create Die 0 with Compute + Transfer queue
$prio = Block 4; W32 $prio 0 0x3F800000
$qcis0 = Block (2 * 40)
W32 $qcis0 0 2; W32 $qcis0 20 $computeQf0; W32 $qcis0 24 1; WP $qcis0 32 $prio
$qciCount0 = 1
if ($transferQf0 -ne $computeQf0) {
    W32 $qcis0 40 2; W32 $qcis0 60 $transferQf0; W32 $qcis0 64 1; WP $qcis0 72 $prio
    $qciCount0 = 2
}

$dci0 = Block 72; W32 $dci0 0 3; W32 $dci0 20 $qciCount0; WP $dci0 24 $qcis0; W32 $dci0 48 $devExtensions.Count; WP $dci0 56 $pExtNames
$outDev0 = Block 8
CheckVK ($vkCreateDevice.Invoke($prodPhys, $dci0, [IntPtr]::Zero, $outDev0)) 'vkCreateDevice(Die0)'
$dev0 = [Runtime.InteropServices.Marshal]::ReadIntPtr($outDev0)

$outQ0Comp = Block 8; $vkGetDeviceQueue.Invoke($dev0, [uint32]$computeQf0, [uint32]0, $outQ0Comp)
$q0Compute = [Runtime.InteropServices.Marshal]::ReadIntPtr($outQ0Comp)

$outQ0Xfer = Block 8; $vkGetDeviceQueue.Invoke($dev0, [uint32]$transferQf0, [uint32]0, $outQ0Xfer)
$q0Transfer = [Runtime.InteropServices.Marshal]::ReadIntPtr($outQ0Xfer)

# Discover queue family on Die 1: Compute
$outC1 = Block 4
$vkGetPhysicalDeviceQueueFamilyProperties.Invoke($consPhys, $outC1, [IntPtr]::Zero)
$qfCount1 = [Runtime.InteropServices.Marshal]::ReadInt32($outC1)
$qfList1 = Block ($qfCount1 * 24)
$vkGetPhysicalDeviceQueueFamilyProperties.Invoke($consPhys, $outC1, $qfList1)
$computeQf1 = -1
for ($f = 0; $f -lt $qfCount1; $f++) {
    $flags = [Runtime.InteropServices.Marshal]::ReadInt32($qfList1, $f * 24)
    if (($flags -band 2) -ne 0) { $computeQf1 = $f; break }
}
if ($computeQf1 -lt 0) { throw 'No compute queue family found on Die 1' }

$qci1 = Block 40; W32 $qci1 0 2; W32 $qci1 20 $computeQf1; W32 $qci1 24 1; WP $qci1 32 $prio
$dci1 = Block 72; W32 $dci1 0 3; W32 $dci1 20 1; WP $dci1 24 $qci1; W32 $dci1 48 $devExtensions.Count; WP $dci1 56 $pExtNames
$outDev1 = Block 8
CheckVK ($vkCreateDevice.Invoke($consPhys, $dci1, [IntPtr]::Zero, $outDev1)) 'vkCreateDevice(Die1)'
$dev1 = [Runtime.InteropServices.Marshal]::ReadIntPtr($outDev1)

$outQ1 = Block 8; $vkGetDeviceQueue.Invoke($dev1, [uint32]$computeQf1, [uint32]0, $outQ1)
$q1 = [Runtime.InteropServices.Marshal]::ReadIntPtr($outQ1)

# Import D3D12 fence into binary semaphores on both devices
$fnCreateSem0 = $interop.GetCall($vkGetDeviceProcAddr.Invoke($dev0, 'vkCreateSemaphore'), [int], @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
$fnImportWin32_0 = $interop.GetCall($vkGetDeviceProcAddr.Invoke($dev0, 'vkImportSemaphoreWin32HandleKHR'), [int], @([IntPtr], [IntPtr]))

$fnCreateSem1 = $interop.GetCall($vkGetDeviceProcAddr.Invoke($dev1, 'vkCreateSemaphore'), [int], @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
$fnImportWin32_1 = $interop.GetCall($vkGetDeviceProcAddr.Invoke($dev1, 'vkImportSemaphoreWin32HandleKHR'), [int], @([IntPtr], [IntPtr]))

$sci = Block 24; W32 $sci 0 9
$outSem0 = Block 8; CheckVK ($fnCreateSem0.Invoke($dev0, $sci, [IntPtr]::Zero, $outSem0)) 'vkCreateSemaphore(Die0-Fence)'
$d3d12Sem0 = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outSem0)

$impInfo0 = Block 48; W32 $impInfo0 0 1000078000; W64 $impInfo0 16 $d3d12Sem0; W32 $impInfo0 24 0; W32 $impInfo0 28 8; WP $impInfo0 32 $sharedFenceHandle
CheckVK ($fnImportWin32_0.Invoke($dev0, $impInfo0)) 'vkImportSemaphoreWin32HandleKHR(Die0, D3D12_FENCE)'

$outSem1 = Block 8; CheckVK ($fnCreateSem1.Invoke($dev1, $sci, [IntPtr]::Zero, $outSem1)) 'vkCreateSemaphore(Die1-Fence)'
$d3d12Sem1 = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outSem1)

$impInfo1 = Block 48; W32 $impInfo1 0 1000078000; W64 $impInfo1 16 $d3d12Sem1; W32 $impInfo1 24 0; W32 $impInfo1 28 8; WP $impInfo1 32 $sharedFenceHandle
CheckVK ($fnImportWin32_1.Invoke($dev1, $impInfo1)) 'vkImportSemaphoreWin32HandleKHR(Die1, D3D12_FENCE)'

# Create Die 0 producer-local semaphore for Compute -> SDMA ordering
$outLocalSem = Block 8
CheckVK ($fnCreateSem0.Invoke($dev0, $sci, [IntPtr]::Zero, $outLocalSem)) 'vkCreateSemaphore(Die0-ComputeToTransfer)'
$semComputeToTransfer = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outLocalSem)

Write-Host "  [+] Die 0 & Die 1 configured. Local GPU semaphore created for Compute -> SDMA ordering." -ForegroundColor Green

# -----------------------------------------------------------------------------
# 3. Memory Setup: Resident VRAM on Die 0 + Shared Pinned Host Aperture
# -----------------------------------------------------------------------------
Write-Host "[3/6] Allocating Die 0 resident VRAM and shared host aperture..." -ForegroundColor Yellow

$virtualAlloc = $interop.GetExportCall('kernel32.dll', 'VirtualAlloc', [IntPtr], @([IntPtr], [uint64], [uint32], [uint32]))
$vkCreateBuffer = Fn 'vkCreateBuffer' [int] @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
$vkGetBufferMemoryRequirements = Fn 'vkGetBufferMemoryRequirements' [void] @([IntPtr], [uint64], [IntPtr])
$vkAllocateMemory = Fn 'vkAllocateMemory' [int] @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
$vkBindBufferMemory = Fn 'vkBindBufferMemory' [int] @([IntPtr], [uint64], [uint64], [uint64])

$apertureBytes = 1048576 # 1 MiB
$apertureHost = $virtualAlloc.Invoke([IntPtr]::Zero, [uint64]$apertureBytes, [uint32]0x3000, [uint32]4)
if ($apertureHost -eq [IntPtr]::Zero) { throw 'VirtualAlloc failed' }
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new($apertureBytes), 0, $apertureHost, $apertureBytes)

# A. Resident VRAM Buffer on Die 0 (DEVICE_LOCAL HBM2)
$qfIndices0 = Block 8; W32 $qfIndices0 0 $computeQf0; W32 $qfIndices0 4 $transferQf0
$sharingMode0 = if ($computeQf0 -eq $transferQf0) { 0 } else { 1 } # 0=EXCLUSIVE, 1=CONCURRENT
$qfCountForBuf = if ($computeQf0 -eq $transferQf0) { 0 } else { 2 }

$bciVram = Block 56; W32 $bciVram 0 12; W64 $bciVram 24 $apertureBytes; W32 $bciVram 32 0x21 # STORAGE_BUFFER | TRANSFER_SRC
W32 $bciVram 36 $sharingMode0; W32 $bciVram 40 $qfCountForBuf; WP $bciVram 48 $qfIndices0
$outVramBuf = Block 8
CheckVK ($vkCreateBuffer.Invoke($dev0, $bciVram, [IntPtr]::Zero, $outVramBuf)) 'vkCreateBuffer(Die0-ResidentVRAM)'
$vramBuf0 = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outVramBuf)

$reqVram = Block 24; $vkGetBufferMemoryRequirements.Invoke($dev0, $vramBuf0, $reqVram)
$vramReqBytes = [Runtime.InteropServices.Marshal]::ReadInt64($reqVram, 0)
$vramBits = [Runtime.InteropServices.Marshal]::ReadInt32($reqVram, 16)
$memProps0 = Block 520; $vkGetPhysicalDeviceMemoryProperties.Invoke($prodPhys, $memProps0)
$typeCount0 = [Runtime.InteropServices.Marshal]::ReadInt32($memProps0, 0)
$devLocalType0 = -1
for ($t = 0; $t -lt $typeCount0; $t++) {
    $propFlags = [Runtime.InteropServices.Marshal]::ReadInt32($memProps0, 4 + $t * 8)
    if (($vramBits -band (1 -shl $t)) -ne 0 -and ($propFlags -band 1) -eq 1) { # DEVICE_LOCAL
        $devLocalType0 = $t; break
    }
}
if ($devLocalType0 -lt 0) { throw 'No DEVICE_LOCAL memory for VRAM buffer on Die 0' }

$maiVram = Block 32; W32 $maiVram 0 5; W64 $maiVram 16 $vramReqBytes; W32 $maiVram 24 $devLocalType0
$outVramMem = Block 8
CheckVK ($vkAllocateMemory.Invoke($dev0, $maiVram, [IntPtr]::Zero, $outVramMem)) 'vkAllocateMemory(Die0-ResidentVRAM)'
$vramMem0 = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outVramMem)
CheckVK ($vkBindBufferMemory.Invoke($dev0, $vramBuf0, $vramMem0, [uint64]0)) 'vkBindBufferMemory(Die0-ResidentVRAM)'

# B. Pinned Host Aperture on Die 0 and Die 1
function ImportHostAperture([IntPtr]$Dev, [IntPtr]$Phys, [string]$Role, [int[]]$Qfs) {
    $extInfo = Block 24; W32 $extInfo 0 1000072000; W32 $extInfo 16 128
    $qfInds = Block ($Qfs.Count * 4)
    for ($i = 0; $i -lt $Qfs.Count; $i++) { W32 $qfInds ($i * 4) $Qfs[$i] }
    $mode = if ($Qfs.Count -gt 1 -and $Qfs[0] -ne $Qfs[1]) { 1 } else { 0 }
    $count = if ($mode -eq 1) { $Qfs.Count } else { 0 }
    
    $bci = Block 56; W32 $bci 0 12; WP $bci 8 $extInfo; W64 $bci 24 $apertureBytes; W32 $bci 32 0x23 # STORAGE | XFER_DST | XFER_SRC
    W32 $bci 36 $mode; W32 $bci 40 $count; WP $bci 48 $qfInds
    $outBuf = Block 8
    CheckVK ($vkCreateBuffer.Invoke($Dev, $bci, [IntPtr]::Zero, $outBuf)) "vkCreateBuffer(Aperture-$Role)"
    $buf = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outBuf)
    
    $req = Block 24; $vkGetBufferMemoryRequirements.Invoke($Dev, $buf, $req)
    $reqBytes = [Runtime.InteropServices.Marshal]::ReadInt64($req, 0)
    $bits = [Runtime.InteropServices.Marshal]::ReadInt32($req, 16)
    
    $memProps = Block 520; $vkGetPhysicalDeviceMemoryProperties.Invoke($Phys, $memProps)
    $fnGetHostProps = $interop.GetCall($vkGetDeviceProcAddr.Invoke($Dev, 'vkGetMemoryHostPointerPropertiesEXT'), [int], @([IntPtr], [uint32], [IntPtr], [IntPtr]))
    $hp = Block 24; W32 $hp 0 1000178001
    CheckVK ($fnGetHostProps.Invoke($Dev, [uint32]128, $apertureHost, $hp)) "vkGetMemoryHostPointerPropertiesEXT($Role)"
    $bits = $bits -band ([Runtime.InteropServices.Marshal]::ReadInt32($hp, 16))
    
    $tCount = [Runtime.InteropServices.Marshal]::ReadInt32($memProps, 0)
    $mType = -1
    for ($t = 0; $t -lt $tCount; $t++) {
        if (($bits -band (1 -shl $t)) -ne 0) { $mType = $t; break }
    }
    if ($mType -lt 0) { throw "No compatible memory type for aperture on $Role" }
    
    $impInfo = Block 32; W32 $impInfo 0 1000178000; W32 $impInfo 16 128; WP $impInfo 24 $apertureHost
    $mai = Block 32; W32 $mai 0 5; WP $mai 8 $impInfo; W64 $mai 16 $reqBytes; W32 $mai 24 $mType
    $outMem = Block 8
    CheckVK ($vkAllocateMemory.Invoke($Dev, $mai, [IntPtr]::Zero, $outMem)) "vkAllocateMemory(Aperture-$Role)"
    $mem = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outMem)
    CheckVK ($vkBindBufferMemory.Invoke($Dev, $buf, $mem, [uint64]0)) "vkBindBufferMemory(Aperture-$Role)"
    
    return [pscustomobject]@{ Buffer=$buf; Memory=$mem }
}

$ap0 = ImportHostAperture $dev0 $prodPhys 'Die0' @($computeQf0, $transferQf0)
$ap1 = ImportHostAperture $dev1 $consPhys 'Die1' @($computeQf1)

# C. Diagnostic Results Buffer on Die 1 (HOST_VISIBLE | HOST_COHERENT)
$resultsBytes = 32
$bciRes = Block 56; W32 $bciRes 0 12; W64 $bciRes 24 $resultsBytes; W32 $bciRes 32 0x20
$outResBuf = Block 8
CheckVK ($vkCreateBuffer.Invoke($dev1, $bciRes, [IntPtr]::Zero, $outResBuf)) 'vkCreateBuffer(Results)'
$resBuf1 = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outResBuf)

$reqRes = Block 24; $vkGetBufferMemoryRequirements.Invoke($dev1, $resBuf1, $reqRes)
$resReqBytes = [Runtime.InteropServices.Marshal]::ReadInt64($reqRes, 0)
$resBits = [Runtime.InteropServices.Marshal]::ReadInt32($reqRes, 16)
$memProps1 = Block 520; $vkGetPhysicalDeviceMemoryProperties.Invoke($consPhys, $memProps1)
$resTypeCount = [Runtime.InteropServices.Marshal]::ReadInt32($memProps1, 0)
$resMemType = -1
for ($t = 0; $t -lt $resTypeCount; $t++) {
    $propFlags = [Runtime.InteropServices.Marshal]::ReadInt32($memProps1, 4 + $t * 8)
    if (($resBits -band (1 -shl $t)) -ne 0 -and ($propFlags -band 6) -eq 6) {
        $resMemType = $t; break
    }
}
if ($resMemType -lt 0) { throw 'No host-visible coherent memory for results buffer' }

$maiRes = Block 32; W32 $maiRes 0 5; W64 $maiRes 16 $resReqBytes; W32 $maiRes 24 $resMemType
$outResMem = Block 8
CheckVK ($vkAllocateMemory.Invoke($dev1, $maiRes, [IntPtr]::Zero, $outResMem)) 'vkAllocateMemory(Results)'
$resMem1 = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outResMem)
CheckVK ($vkBindBufferMemory.Invoke($dev1, $resBuf1, $resMem1, [uint64]0)) 'vkBindBufferMemory(Results)'

# Initialize results memory: {0, 0, 0xFFFFFFFF, 0, 0, 0, 0, 0}
$vkMapMemory = Fn 'vkMapMemory' [int] @([IntPtr], [uint64], [uint64], [uint64], [uint32], [IntPtr])
$outMap = Block 8
CheckVK ($vkMapMemory.Invoke($dev1, $resMem1, [uint64]0, [uint64]$resultsBytes, [uint32]0, $outMap)) 'vkMapMemory(Results)'
$pMappedResults = [Runtime.InteropServices.Marshal]::ReadIntPtr($outMap)
for ($i = 0; $i -lt 8; $i++) {
    $val = if ($i -eq 2) { -1 } else { 0 }
    [Runtime.InteropServices.Marshal]::WriteInt32($pMappedResults, $i * 4, $val)
}

Write-Host "  [+] Die 0 VRAM buffer and shared host aperture allocated." -ForegroundColor Green

# -----------------------------------------------------------------------------
# 4. Pipelines: Die 0 Pattern Generator + Die 1 Arena Verifier
# -----------------------------------------------------------------------------
Write-Host "[4/6] Creating compute pipelines on Die 0 and Die 1..." -ForegroundColor Yellow

$vkCreateShaderModule = Fn 'vkCreateShaderModule' [int] @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
$vkCreateDescriptorSetLayout = Fn 'vkCreateDescriptorSetLayout' [int] @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
$vkCreatePipelineLayout = Fn 'vkCreatePipelineLayout' [int] @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
$vkCreateComputePipelines = Fn 'vkCreateComputePipelines' [int] @([IntPtr], [uint64], [uint32], [IntPtr], [IntPtr], [IntPtr])
$vkCreateDescriptorPool = Fn 'vkCreateDescriptorPool' [int] @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
$vkAllocateDescriptorSets = Fn 'vkAllocateDescriptorSets' [int] @([IntPtr], [IntPtr], [IntPtr])
$vkUpdateDescriptorSets = Fn 'vkUpdateDescriptorSets' [void] @([IntPtr], [uint32], [IntPtr], [uint32], [IntPtr])

# --- Pipeline 0 (Die 0 Pattern Generator: Binding 0 -> vramBuf0) ---
$pCode0 = Block $genShaderBytes.Length
[Runtime.InteropServices.Marshal]::Copy($genShaderBytes, 0, $pCode0, $genShaderBytes.Length)
$smci0 = Block 40; W32 $smci0 0 16; W64 $smci0 24 $genShaderBytes.Length; WP $smci0 32 $pCode0
$outSm0 = Block 8
CheckVK ($vkCreateShaderModule.Invoke($dev0, $smci0, [IntPtr]::Zero, $outSm0)) 'vkCreateShaderModule(Die0)'
$sm0 = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outSm0)

$bind0 = Block 24; W32 $bind0 0 0; W32 $bind0 4 7; W32 $bind0 8 1; W32 $bind0 12 0x20
$dslci0 = Block 32; W32 $dslci0 0 32; W32 $dslci0 20 1; WP $dslci0 24 $bind0
$outDsl0 = Block 8
CheckVK ($vkCreateDescriptorSetLayout.Invoke($dev0, $dslci0, [IntPtr]::Zero, $outDsl0)) 'vkCreateDescriptorSetLayout(Die0)'
$dsl0 = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outDsl0)

$pcr0 = Block 12; W32 $pcr0 0 0x20; W32 $pcr0 4 0; W32 $pcr0 8 16
$pDsl0Arr = Block 8; W64 $pDsl0Arr 0 $dsl0
$plci0 = Block 48; W32 $plci0 0 30; W32 $plci0 20 1; WP $plci0 24 $pDsl0Arr; W32 $plci0 32 1; WP $plci0 40 $pcr0
$outPl0 = Block 8
CheckVK ($vkCreatePipelineLayout.Invoke($dev0, $plci0, [IntPtr]::Zero, $outPl0)) 'vkCreatePipelineLayout(Die0)'
$pl0 = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outPl0)

$mainStr = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi('main'); $blocks.Add($mainStr)
$cpci0 = Block 96; W32 $cpci0 0 29; W32 $cpci0 24 18; W32 $cpci0 44 0x20; W64 $cpci0 48 $sm0; WP $cpci0 56 $mainStr; W64 $cpci0 72 $pl0; W32 $cpci0 88 -1
$outPipe0 = Block 8
CheckVK ($vkCreateComputePipelines.Invoke($dev0, [uint64]0, [uint32]1, $cpci0, [IntPtr]::Zero, $outPipe0)) 'vkCreateComputePipelines(Die0)'
$pipe0 = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outPipe0)

$dpSize0 = Block 8; W32 $dpSize0 0 7; W32 $dpSize0 4 1
$dpci0 = Block 40; W32 $dpci0 0 33; W32 $dpci0 20 1; W32 $dpci0 24 1; WP $dpci0 32 $dpSize0
$outDp0 = Block 8
CheckVK ($vkCreateDescriptorPool.Invoke($dev0, $dpci0, [IntPtr]::Zero, $outDp0)) 'vkCreateDescriptorPool(Die0)'
$dp0 = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outDp0)

# Harness Correction 1: VkDescriptorSetAllocateInfo is 40 bytes on x64!
$dsai0 = Block 40; W32 $dsai0 0 34; W64 $dsai0 16 $dp0; W32 $dsai0 24 1; WP $dsai0 32 $pDsl0Arr
$outDs0 = Block 8
CheckVK ($vkAllocateDescriptorSets.Invoke($dev0, $dsai0, $outDs0)) 'vkAllocateDescriptorSets(Die0)'
$ds0 = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outDs0)

$vramBufInfo = Block 24; W64 $vramBufInfo 0 $vramBuf0; W64 $vramBufInfo 8 0; W64 $vramBufInfo 16 ([uint64]::MaxValue)
$w0 = Block 64; W32 $w0 0 35; W64 $w0 16 $ds0; W32 $w0 24 0; W32 $w0 32 1; W32 $w0 36 7; WP $w0 48 $vramBufInfo
$vkUpdateDescriptorSets.Invoke($dev0, [uint32]1, $w0, [uint32]0, [IntPtr]::Zero)

# --- Pipeline 1 (Die 1 Verifier: Binding 0 -> ap1.Buffer, Binding 1 -> resBuf1) ---
$pCode1 = Block $verifyShaderBytes.Length
[Runtime.InteropServices.Marshal]::Copy($verifyShaderBytes, 0, $pCode1, $verifyShaderBytes.Length)
$smci1 = Block 40; W32 $smci1 0 16; W64 $smci1 24 $verifyShaderBytes.Length; WP $smci1 32 $pCode1
$outSm1 = Block 8
CheckVK ($vkCreateShaderModule.Invoke($dev1, $smci1, [IntPtr]::Zero, $outSm1)) 'vkCreateShaderModule(Die1)'
$sm1 = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outSm1)

$bind1 = Block (2 * 24)
W32 $bind1 0 0; W32 $bind1 4 7; W32 $bind1 8 1; W32 $bind1 12 0x20
W32 $bind1 24 1; W32 $bind1 28 7; W32 $bind1 32 1; W32 $bind1 36 0x20
$dslci1 = Block 32; W32 $dslci1 0 32; W32 $dslci1 20 2; WP $dslci1 24 $bind1
$outDsl1 = Block 8
CheckVK ($vkCreateDescriptorSetLayout.Invoke($dev1, $dslci1, [IntPtr]::Zero, $outDsl1)) 'vkCreateDescriptorSetLayout(Die1)'
$dsl1 = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outDsl1)

$pcr1 = Block 12; W32 $pcr1 0 0x20; W32 $pcr1 4 0; W32 $pcr1 8 16
$pDsl1Arr = Block 8; W64 $pDsl1Arr 0 $dsl1
$plci1 = Block 48; W32 $plci1 0 30; W32 $plci1 20 1; WP $plci1 24 $pDsl1Arr; W32 $plci1 32 1; WP $plci1 40 $pcr1
$outPl1 = Block 8
CheckVK ($vkCreatePipelineLayout.Invoke($dev1, $plci1, [IntPtr]::Zero, $outPl1)) 'vkCreatePipelineLayout(Die1)'
$pl1 = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outPl1)

$cpci1 = Block 96; W32 $cpci1 0 29; W32 $cpci1 24 18; W32 $cpci1 44 0x20; W64 $cpci1 48 $sm1; WP $cpci1 56 $mainStr; W64 $cpci1 72 $pl1; W32 $cpci1 88 -1
$outPipe1 = Block 8
CheckVK ($vkCreateComputePipelines.Invoke($dev1, [uint64]0, [uint32]1, $cpci1, [IntPtr]::Zero, $outPipe1)) 'vkCreateComputePipelines(Die1)'
$pipe1 = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outPipe1)

$dpSize1 = Block 8; W32 $dpSize1 0 7; W32 $dpSize1 4 2
$dpci1 = Block 40; W32 $dpci1 0 33; W32 $dpci1 20 1; W32 $dpci1 24 1; WP $dpci1 32 $dpSize1
$outDp1 = Block 8
CheckVK ($vkCreateDescriptorPool.Invoke($dev1, $dpci1, [IntPtr]::Zero, $outDp1)) 'vkCreateDescriptorPool(Die1)'
$dp1 = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outDp1)

# Harness Correction 1: VkDescriptorSetAllocateInfo is 40 bytes on x64!
$dsai1 = Block 40; W32 $dsai1 0 34; W64 $dsai1 16 $dp1; W32 $dsai1 24 1; WP $dsai1 32 $pDsl1Arr
$outDs1 = Block 8
CheckVK ($vkAllocateDescriptorSets.Invoke($dev1, $dsai1, $outDs1)) 'vkAllocateDescriptorSets(Die1)'
$ds1 = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outDs1)

$bufInfoAperture1 = Block 24; W64 $bufInfoAperture1 0 $ap1.Buffer; W64 $bufInfoAperture1 8 0; W64 $bufInfoAperture1 16 ([uint64]::MaxValue)
$bufInfoRes1 = Block 24; W64 $bufInfoRes1 0 $resBuf1; W64 $bufInfoRes1 8 0; W64 $bufInfoRes1 16 ([uint64]::MaxValue)
$w1 = Block (2 * 64)
W32 $w1 0 35; W64 $w1 16 $ds1; W32 $w1 24 0; W32 $w1 32 1; W32 $w1 36 7; WP $w1 48 $bufInfoAperture1
W32 $w1 64 35; W64 $w1 80 $ds1; W32 $w1 88 1; W32 $w1 96 1; W32 $w1 100 7; WP $w1 112 $bufInfoRes1
$vkUpdateDescriptorSets.Invoke($dev1, [uint32]2, $w1, [uint32]0, [IntPtr]::Zero)

Write-Host "  [+] Compute pipelines created on Die 0 and Die 1." -ForegroundColor Green

# -----------------------------------------------------------------------------
# 5. Command Recording: Compute Pattern Gen -> SDMA Transfer -> Verifier
# -----------------------------------------------------------------------------
Write-Host "[5/6] Recording Producer Compute, Producer SDMA, and Consumer Verifier..." -ForegroundColor Yellow

$vkCreateCommandPool = Fn 'vkCreateCommandPool' [int] @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
$vkAllocateCommandBuffers = Fn 'vkAllocateCommandBuffers' [int] @([IntPtr], [IntPtr], [IntPtr])
$vkBeginCommandBuffer = Fn 'vkBeginCommandBuffer' [int] @([IntPtr], [IntPtr])
$vkEndCommandBuffer = Fn 'vkEndCommandBuffer' [int] @([IntPtr])
$vkCmdCopyBuffer = Fn 'vkCmdCopyBuffer' [void] @([IntPtr], [uint64], [uint64], [uint32], [IntPtr])
$vkCmdUpdateBuffer = Fn 'vkCmdUpdateBuffer' [void] @([IntPtr], [uint64], [uint64], [uint64], [IntPtr])
$vkCmdPipelineBarrier = Fn 'vkCmdPipelineBarrier' [void] @([IntPtr], [uint32], [uint32], [uint32], [uint32], [IntPtr], [uint32], [IntPtr], [uint32], [IntPtr])
$vkCmdBindPipeline = Fn 'vkCmdBindPipeline' [void] @([IntPtr], [uint32], [uint64])
$vkCmdBindDescriptorSets = Fn 'vkCmdBindDescriptorSets' [void] @([IntPtr], [uint32], [uint64], [uint32], [uint32], [IntPtr], [uint32], [IntPtr])
$vkCmdPushConstants = Fn 'vkCmdPushConstants' [void] @([IntPtr], [uint64], [uint32], [uint32], [uint32], [IntPtr])
$vkCmdDispatch = Fn 'vkCmdDispatch' [void] @([IntPtr], [uint32], [uint32], [uint32])

function NewPool([IntPtr]$Dev, [int]$Qf) {
    $pci = Block 24; W32 $pci 0 38; W32 $pci 16 2; W32 $pci 20 $Qf
    $outP = Block 8
    CheckVK ($vkCreateCommandPool.Invoke($Dev, $pci, [IntPtr]::Zero, $outP)) 'vkCreateCommandPool'
    return [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outP)
}
function NewCmd([IntPtr]$Dev, [uint64]$Pool) {
    $cai = Block 32; W32 $cai 0 40; W64 $cai 16 $Pool; W32 $cai 28 1
    $outC = Block 8
    CheckVK ($vkAllocateCommandBuffers.Invoke($Dev, $cai, $outC)) 'vkAllocateCommandBuffers'
    return [Runtime.InteropServices.Marshal]::ReadIntPtr($outC)
}

$pool0Comp = NewPool $dev0 $computeQf0
$pool0Xfer = NewPool $dev0 $transferQf0
$pool1Comp = NewPool $dev1 $computeQf1

$cmd0Comp = NewCmd $dev0 $pool0Comp
$cmd0Xfer = NewCmd $dev0 $pool0Xfer
$cmd1Verify = NewCmd $dev1 $pool1Comp

# Problem Geometry
$regionCount = 21
$wordsPerRegion = 256
$spacingWords = 1024
$sequence = 2 # Fresh sequence
$footerWord = 22000
$payloadEndWord = $regionCount * $spacingWords
$totalWordsExpected = $regionCount * $wordsPerRegion

# Footer Data layout
$footerData = [uint32[]]::new(4 + $regionCount * 4)
$footerData[0] = 0x56333430 # MAGIC "V340"
$footerData[1] = $sequence
$footerData[2] = $regionCount
$footerData[3] = $payloadEndWord

for ($e = 0; $e -lt $regionCount; $e++) {
    $off = $e * $spacingWords
    $len = $wordsPerRegion
    $baseVal = 0x20000000 + ($sequence * 0x01000000) + ($e * 0x00010000)
    $stepVal = $e + 1 # Non-zero varying step!
    $footerData[4 + $e * 4 + 0] = $off
    $footerData[4 + $e * 4 + 1] = $len
    $footerData[4 + $e * 4 + 2] = $baseVal
    $footerData[4 + $e * 4 + 3] = $stepVal
}

$cbBegin = Block 32; W32 $cbBegin 0 42

# --- Record Die 0 Compute (Pattern Generator into VRAM) ---
CheckVK ($vkBeginCommandBuffer.Invoke($cmd0Comp, $cbBegin)) 'vkBeginCommandBuffer(Die0-Compute)'
$vkCmdBindPipeline.Invoke($cmd0Comp, [uint32]1, $pipe0)
$pDs0Arr = Block 8; W64 $pDs0Arr 0 $ds0
$vkCmdBindDescriptorSets.Invoke($cmd0Comp, [uint32]1, $pl0, [uint32]0, [uint32]1, $pDs0Arr, [uint32]0, [IntPtr]::Zero)

$pushGen = Block 16
W32 $pushGen 0 $regionCount
W32 $pushGen 4 $wordsPerRegion
W32 $pushGen 8 $spacingWords
W32 $pushGen 12 $sequence
$vkCmdPushConstants.Invoke($cmd0Comp, $pl0, [uint32]0x20, [uint32]0, [uint32]16, $pushGen)

# Dispatch invocations for all elements: ceil(totalWords / 64)
$invocations = $totalWordsExpected
$workgroups = [int][Math]::Ceiling($invocations / 64.0)
$vkCmdDispatch.Invoke($cmd0Comp, [uint32]$workgroups, [uint32]1, [uint32]1)

# Pipeline Barrier on Die 0: Compute Shader Write -> Transfer Read
$compBarrier = Block 24
W32 $compBarrier 0 46 # VK_STRUCTURE_TYPE_MEMORY_BARRIER
W32 $compBarrier 16 0x40   # VK_ACCESS_SHADER_WRITE_BIT
W32 $compBarrier 20 0x800  # VK_ACCESS_TRANSFER_READ_BIT
$vkCmdPipelineBarrier.Invoke($cmd0Comp, [uint32]0x20, [uint32]0x1000, [uint32]0, [uint32]1, $compBarrier, [uint32]0, [IntPtr]::Zero, [uint32]0, [IntPtr]::Zero)
CheckVK ($vkEndCommandBuffer.Invoke($cmd0Comp)) 'vkEndCommandBuffer(Die0-Compute)'

# --- Record Die 0 SDMA (Hardware Copy VRAM -> Aperture + Manifest Footer) ---
CheckVK ($vkBeginCommandBuffer.Invoke($cmd0Xfer, $cbBegin)) 'vkBeginCommandBuffer(Die0-SDMA)'

# 1. SDMA Copy 21 regions from VRAM to Aperture
$copyRegions = Block ($regionCount * 24)
for ($e = 0; $e -lt $regionCount; $e++) {
    $byteOffset = [uint64]($e * $spacingWords * 4)
    $byteSize = [uint64]($wordsPerRegion * 4)
    W64 $copyRegions ($e * 24 + 0) $byteOffset # srcOffset
    W64 $copyRegions ($e * 24 + 8) $byteOffset # dstOffset
    W64 $copyRegions ($e * 24 + 16) $byteSize  # size
}
$vkCmdCopyBuffer.Invoke($cmd0Xfer, $vramBuf0, $ap0.Buffer, [uint32]$regionCount, $copyRegions)

# 2. Transfer-to-Transfer Dependency before writing Footer
$xferBarrier = Block 24
W32 $xferBarrier 0 46
W32 $xferBarrier 16 0x1000 # VK_ACCESS_TRANSFER_WRITE_BIT
W32 $xferBarrier 20 0x1000 # VK_ACCESS_TRANSFER_WRITE_BIT
$vkCmdPipelineBarrier.Invoke($cmd0Xfer, [uint32]0x1000, [uint32]0x1000, [uint32]0, [uint32]1, $xferBarrier, [uint32]0, [IntPtr]::Zero, [uint32]0, [IntPtr]::Zero)

# 3. Write Manifest Footer last
$pFooterBytes = Block ($footerData.Length * 4)
for ($i = 0; $i -lt $footerData.Length; $i++) {
    [Runtime.InteropServices.Marshal]::WriteInt32($pFooterBytes, $i * 4, [BitConverter]::ToInt32([BitConverter]::GetBytes($footerData[$i]), 0))
}
$vkCmdUpdateBuffer.Invoke($cmd0Xfer, $ap0.Buffer, [uint64]($footerWord * 4), [uint64]($footerData.Length * 4), $pFooterBytes)

# Harness Correction 2: Correct release barrier before signaling cross-adapter semaphore:
# srcStage = TRANSFER (0x1000), dstStage = BOTTOM_OF_PIPE (0x2000)
# srcAccess = TRANSFER_WRITE (0x1000), dstAccess = 0
$relBarrier = Block 24
W32 $relBarrier 0 46
W32 $relBarrier 16 0x1000 # VK_ACCESS_TRANSFER_WRITE_BIT
W32 $relBarrier 20 0      # 0 dstAccess with BOTTOM_OF_PIPE
$vkCmdPipelineBarrier.Invoke($cmd0Xfer, [uint32]0x1000, [uint32]0x2000, [uint32]0, [uint32]1, $relBarrier, [uint32]0, [IntPtr]::Zero, [uint32]0, [IntPtr]::Zero)
CheckVK ($vkEndCommandBuffer.Invoke($cmd0Xfer)) 'vkEndCommandBuffer(Die0-SDMA)'

# --- Record Die 1 Verifier Compute ---
CheckVK ($vkBeginCommandBuffer.Invoke($cmd1Verify, $cbBegin)) 'vkBeginCommandBuffer(Die1-Verifier)'
$vkCmdBindPipeline.Invoke($cmd1Verify, [uint32]1, $pipe1)
$pDs1Arr = Block 8; W64 $pDs1Arr 0 $ds1
$vkCmdBindDescriptorSets.Invoke($cmd1Verify, [uint32]1, $pl1, [uint32]0, [uint32]1, $pDs1Arr, [uint32]0, [IntPtr]::Zero)

$pushVerify = Block 16
W32 $pushVerify 0 $footerWord
W32 $pushVerify 4 $sequence
W32 $pushVerify 8 ($apertureBytes / 4)
W32 $pushVerify 12 0
$vkCmdPushConstants.Invoke($cmd1Verify, $pl1, [uint32]0x20, [uint32]0, [uint32]16, $pushVerify)

$vkCmdDispatch.Invoke($cmd1Verify, [uint32]1, [uint32]1, [uint32]1)
CheckVK ($vkEndCommandBuffer.Invoke($cmd1Verify)) 'vkEndCommandBuffer(Die1-Verifier)'

Write-Host "  [+] Command buffers recorded." -ForegroundColor Green

# -----------------------------------------------------------------------------
# 6. Submission & Hardware Execution (Zero CPU Synchronization)
# -----------------------------------------------------------------------------
Write-Host "[6/6] Submitting GPU queues asynchronously..." -ForegroundColor Yellow

$vkCreateFence = Fn 'vkCreateFence' [int] @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
$vkWaitForFences = Fn 'vkWaitForFences' [int] @([IntPtr], [uint32], [IntPtr], [uint32], [uint64])
$vkQueueSubmit = Fn 'vkQueueSubmit' [int] @([IntPtr], [uint32], [IntPtr], [uint64])

$fci = Block 24; W32 $fci 0 8
$outTermFence = Block 8
CheckVK ($vkCreateFence.Invoke($dev1, $fci, [IntPtr]::Zero, $outTermFence)) 'vkCreateFence(Terminal)'
$terminalFence = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outTermFence)

$fenceValue = Block 8; W64 $fenceValue 0 1

# Submit 1: Die 1 Consumer (Waits on D3D12 fence == 1 at COMPUTE_SHADER, signals terminalFence)
$waitValues1 = Block 48; W32 $waitValues1 0 1000078002; W32 $waitValues1 16 1; WP $waitValues1 24 $fenceValue
$pWaitSem1 = Block 8; W64 $pWaitSem1 0 $d3d12Sem1
$pWaitDst1 = Block 4; W32 $pWaitDst1 0 0x20 # COMPUTE_SHADER
$pCmd1 = Block 8; WP $pCmd1 0 $cmd1Verify

$sub1 = Block 72; W32 $sub1 0 4; WP $sub1 8 $waitValues1
W32 $sub1 16 1; WP $sub1 24 $pWaitSem1; WP $sub1 32 $pWaitDst1
W32 $sub1 40 1; WP $sub1 48 $pCmd1

# Submit 2: Die 0 SDMA Transfer (Waits on semComputeToTransfer at TRANSFER, signals D3D12 fence == 1)
$sigValues0 = Block 48; W32 $sigValues0 0 1000078002; W32 $sigValues0 32 1; WP $sigValues0 40 $fenceValue
$pWaitLocal = Block 8; W64 $pWaitLocal 0 $semComputeToTransfer
$pWaitLocalStage = Block 4; W32 $pWaitLocalStage 0 0x1000 # TRANSFER
$pSigCross = Block 8; W64 $pSigCross 0 $d3d12Sem0
$pCmd0Xfer = Block 8; WP $pCmd0Xfer 0 $cmd0Xfer

$sub0Xfer = Block 72; W32 $sub0Xfer 0 4; WP $sub0Xfer 8 $sigValues0
W32 $sub0Xfer 16 1; WP $sub0Xfer 24 $pWaitLocal; WP $sub0Xfer 32 $pWaitLocalStage
W32 $sub0Xfer 40 1; WP $sub0Xfer 48 $pCmd0Xfer
W32 $sub0Xfer 56 1; WP $sub0Xfer 64 $pSigCross

# Submit 3: Die 0 Compute (Signals semComputeToTransfer)
$pSigLocal = Block 8; W64 $pSigLocal 0 $semComputeToTransfer
$pCmd0Comp = Block 8; WP $pCmd0Comp 0 $cmd0Comp

$sub0Comp = Block 72; W32 $sub0Comp 0 4
W32 $sub0Comp 40 1; WP $sub0Comp 48 $pCmd0Comp
W32 $sub0Comp 56 1; WP $sub0Comp 64 $pSigLocal

# Harness Correction 3: Accurately separate submission wall times vs terminal fence wait
$swSubmissionLoop = [Diagnostics.Stopwatch]::StartNew()

$swCons = [Diagnostics.Stopwatch]::StartNew()
CheckVK ($vkQueueSubmit.Invoke($q1, [uint32]1, $sub1, $terminalFence)) 'vkQueueSubmit(Die1 Consumer Wait)'
$swCons.Stop()

$swXfer = [Diagnostics.Stopwatch]::StartNew()
CheckVK ($vkQueueSubmit.Invoke($q0Transfer, [uint32]1, $sub0Xfer, [uint64]0)) 'vkQueueSubmit(Die0 SDMA Transfer)'
$swXfer.Stop()

$swComp = [Diagnostics.Stopwatch]::StartNew()
CheckVK ($vkQueueSubmit.Invoke($q0Compute, [uint32]1, $sub0Comp, [uint64]0)) 'vkQueueSubmit(Die0 Compute Pattern)'
$swComp.Stop()

$swSubmissionLoop.Stop()

Write-Host "  [*] All three queue submissions in flight (Total submission wall time: $([math]::Round($swSubmissionLoop.Elapsed.TotalMilliseconds, 3)) ms)." -ForegroundColor Gray
Write-Host "  [*] Awaiting terminal completion fence on Die 1..." -ForegroundColor Gray

$swTerminalWait = [Diagnostics.Stopwatch]::StartNew()
$pTermFence = Block 8; W64 $pTermFence 0 $terminalFence
CheckVK ($vkWaitForFences.Invoke($dev1, [uint32]1, $pTermFence, [uint32]1, [uint64]5000000000L)) 'vkWaitForFences(Die1 Terminal)'
$swTerminalWait.Stop()

$getNativeValue = $interop.GetComCall($nativeFence, 8, [uint64], @())
$nativeCompleted = $getNativeValue.DynamicInvoke($nativeFence)

# Read results
$results = [uint32[]]::new(8)
for ($i = 0; $i -lt 8; $i++) {
    $results[$i] = [BitConverter]::ToUInt32([BitConverter]::GetBytes([Runtime.InteropServices.Marshal]::ReadInt32($pMappedResults, $i * 4)), 0)
}

$errorFlags = $results[0]
$mismatches = $results[1]
$firstBadWord = $results[2]
$observedSeq = $results[3]
$observedCount = $results[4]
$examinedWords = $results[5]

$pass = ($errorFlags -eq 0) -and ($mismatches -eq 0) -and ($observedSeq -eq $sequence) -and ($observedCount -eq $regionCount) -and ($examinedWords -eq $totalWordsExpected)

Write-Host "`n=== Execution Receipt ===" -ForegroundColor $(if ($pass) { 'Green' } else { 'Red' })
Write-Host "Status:                       $(if ($pass) { 'PASS' } else { 'FAIL' })"
Write-Host "Native Fence Completed Value: $nativeCompleted (Expected: 1)"
Write-Host "Error Flags:                  0x$($errorFlags.ToString('X8')) (Expected: 0x0)"
Write-Host "Mismatches:                   $mismatches (Expected: 0)"
Write-Host "First Bad Word Index:         0x$($firstBadWord.ToString('X8'))"
Write-Host "Observed Sequence:            $observedSeq (Expected: $sequence)"
Write-Host "Observed Region Count:        $observedCount (Expected: $regionCount)"
Write-Host "Examined Words:               $examinedWords (Expected: $totalWordsExpected)"
Write-Host "Consumer Submit WallTime:     $([math]::Round($swCons.Elapsed.TotalMilliseconds, 3)) ms"
Write-Host "Producer SDMA Submit WallTime:$([math]::Round($swXfer.Elapsed.TotalMilliseconds, 3)) ms"
Write-Host "Producer Comp Submit WallTime:$([math]::Round($swComp.Elapsed.TotalMilliseconds, 3)) ms"
Write-Host "Total Host Submission Loop:   $([math]::Round($swSubmissionLoop.Elapsed.TotalMilliseconds, 3)) ms"
Write-Host "Terminal Fence Wait Duration: $([math]::Round($swTerminalWait.Elapsed.TotalMilliseconds, 3)) ms"

$receipt = [ordered]@{
    Status = if ($pass) { 'PASS' } else { 'FAIL' }
    ProducerOrdinal = $ProducerOrdinal
    ConsumerOrdinal = $ConsumerOrdinal
    ProducerLUID = $prodAdapter.LUID
    ConsumerLUID = $consAdapter.LUID
    ComputeQueueFamily = $computeQf0
    TransferQueueFamily = $transferQf0
    DedicatedTransferQueueUsed = ($transferQf0 -ne $computeQf0)
    NativeFenceCompletedValue = $nativeCompleted
    ErrorFlags = $errorFlags
    Mismatches = $mismatches
    FirstBadWord = $firstBadWord
    ObservedSequence = $observedSeq
    ObservedRegionCount = $observedCount
    ExaminedWords = $examinedWords
    ExpectedWords = $totalWordsExpected
    ConsumerSubmitMilliseconds = [math]::Round($swCons.Elapsed.TotalMilliseconds, 4)
    ProducerSdmaSubmitMilliseconds = [math]::Round($swXfer.Elapsed.TotalMilliseconds, 4)
    ProducerComputeSubmitMilliseconds = [math]::Round($swComp.Elapsed.TotalMilliseconds, 4)
    HostSubmissionLoopMilliseconds = [math]::Round($swSubmissionLoop.Elapsed.TotalMilliseconds, 4)
    TerminalFenceWaitMilliseconds = [math]::Round($swTerminalWait.Elapsed.TotalMilliseconds, 4)
    TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
}

$receiptDir = Split-Path $ReceiptPath
if (-not (Test-Path $receiptDir)) { New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null }
$receipt | ConvertTo-Json -Depth 4 | Set-Content -Path $ReceiptPath -Encoding UTF8
Write-Host "Receipt written to: $ReceiptPath" -ForegroundColor Cyan

if (-not $pass) {
    throw "Verification failed: ErrorFlags=0x$($errorFlags.ToString('X8')), Mismatches=$mismatches"
}
