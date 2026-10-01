<#
.SYNOPSIS
    Proves cross-die GPU baton ordering and payload visibility using a shared D3D12 fence
    and pinned host memory aperture (VK_EXT_external_memory_host) without CPU synchronization.

.DESCRIPTION
    1. Discovers two V340 dies and maps DXGI adapters to Vulkan physical devices via LUID.
    2. Creates a D3D12 cross-adapter shared fence (flags 3) and exports its Win32 NT handle.
    3. Imports the fence into binary Vulkan semaphores on Die 0 and Die 1 (D3D12_FENCE_BIT).
    4. Allocates a 1 MiB pinned host aperture via VirtualAlloc and imports it into both dies.
    5. Die 0 fills 21 distinct payload regions and writes the manifest footer last via GPU transfer.
    6. Die 0 signals the D3D12 fence semaphore at value 1 upon completion.
    7. Die 1 waits on the D3D12 fence semaphore at value 1 and dispatches ArenaFooterVerify-20260930.spv.
    8. Die 1 is submitted BEFORE Die 0 with zero CPU synchronization.
    9. Host reads diagnostic results from Die 1 only after terminal fence completion.
#>

[CmdletBinding()]
param(
    [ValidateRange(0, 3)] [int] $ProducerOrdinal = 0,
    [ValidateRange(0, 3)] [int] $ConsumerOrdinal = 1,
    [string] $ReceiptPath = 'C:\dev\V340L-Emancipated\GGML\Vulkan\Receipts\vulkan-d3d12-baton-payload-20261001.json'
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

$spvPath = 'C:\dev\V340L-Emancipated\GGML\Vulkan\ArenaFooterVerify-20260930.spv'
if (-not (Test-Path -LiteralPath $spvPath)) { throw "Shader bytecode not found: $spvPath" }
$shaderBytes = [IO.File]::ReadAllBytes($spvPath)

Write-Host "=== Dual-Die GPU Baton & Payload Visibility Proof ===" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# 1. DXGI & D3D12 Cross-Adapter Fence Setup
# -----------------------------------------------------------------------------
Write-Host "[1/6] Initializing DXGI and creating D3D12 cross-adapter fence..." -ForegroundColor Yellow

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

if ($dxgiAdapters.Count -lt 2) { throw "Need at least 2 V340 DXGI adapters; found $($dxgiAdapters.Count)" }
$prodAdapter = $dxgiAdapters[$ProducerOrdinal]
$consAdapter = $dxgiAdapters[$ConsumerOrdinal]
Write-Host "  [+] Producer DXGI: $($prodAdapter.Index) (LUID: $($prodAdapter.LUID))" -ForegroundColor Gray
Write-Host "  [+] Consumer DXGI: $($consAdapter.Index) (LUID: $($consAdapter.LUID))" -ForegroundColor Gray

# Create D3D12 device on producer to own the fence
$outD3DDev = Block 8
CheckHR ($createD3D12Device.Invoke($prodAdapter.Adapter, 0xB000, $iidD3D12Device, $outD3DDev)) 'D3D12CreateDevice(Producer)'
$d3dDev0 = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($outD3DDev))

# CreateFence(initialValue=0, flags=3: SHARED | SHARED_CROSS_ADAPTER)
$createFenceD3D = $interop.GetComCall($d3dDev0, 36, [int], @([uint64], [uint32], [IntPtr], [IntPtr]))
$outFence = Block 8
CheckHR ($createFenceD3D.DynamicInvoke($d3dDev0, [uint64]0, [uint32]3, $iidFence, $outFence)) 'CreateFence(SHARED_CROSS_ADAPTER)'
$nativeFence = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($outFence))

# CreateSharedHandle
$createShared = $interop.GetComCall($d3dDev0, 31, [int], @([IntPtr], [IntPtr], [uint32], [IntPtr], [IntPtr]))
$outHandle = Block 8
CheckHR ($createShared.DynamicInvoke($d3dDev0, $nativeFence, [IntPtr]::Zero, [uint32]0x10000000, [IntPtr]::Zero, $outHandle)) 'CreateSharedHandle'
$sharedFenceHandle = [Runtime.InteropServices.Marshal]::ReadIntPtr($outHandle)
$handles.Add($sharedFenceHandle)
Write-Host "  [+] D3D12 Cross-Adapter Fence Shared Handle: 0x$($sharedFenceHandle.ToString('X'))" -ForegroundColor Green

# -----------------------------------------------------------------------------
# 2. Vulkan Device Creation and D3D12 Fence Import
# -----------------------------------------------------------------------------
Write-Host "[2/6] Creating Vulkan devices and importing shared fence..." -ForegroundColor Yellow

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

$appInfo = Block 48
W32 $appInfo 44 0x00401000 # Vulkan 1.1
$instCi = Block 64
W32 $instCi 0 1
WP $instCi 24 $appInfo
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
    $idProps = Block 64; W32 $idProps 0 1000071004 # VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES
    $props2 = Block 1040; W32 $props2 0 1000059001; WP $props2 8 $idProps
    $vkGetPhysicalDeviceProperties2.Invoke($pPhys, $props2)
    
    if ([Runtime.InteropServices.Marshal]::ReadInt32($props2, 24) -ne 0x1002) { continue }
    if ([Runtime.InteropServices.Marshal]::ReadInt32($idProps, 60) -ne 1) { continue } # deviceLUIDValid
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

function CreateVkDie([IntPtr]$Phys, [string]$Role) {
    $outC = Block 4
    $vkGetPhysicalDeviceQueueFamilyProperties.Invoke($Phys, $outC, [IntPtr]::Zero)
    $qfCount = [Runtime.InteropServices.Marshal]::ReadInt32($outC)
    $qfList = Block ($qfCount * 24)
    $vkGetPhysicalDeviceQueueFamilyProperties.Invoke($Phys, $outC, $qfList)
    $qf = -1
    for ($f = 0; $f -lt $qfCount; $f++) {
        $flags = [Runtime.InteropServices.Marshal]::ReadInt32($qfList, $f * 24)
        if (($flags -band 2) -ne 0) { $qf = $f; break } # COMPUTE family
    }
    if ($qf -lt 0) { throw "No compute queue family found for $Role" }
    
    $prio = Block 4; W32 $prio 0 0x3F800000
    $qci = Block 40; W32 $qci 0 2; W32 $qci 20 $qf; W32 $qci 24 1; WP $qci 32 $prio
    $dci = Block 72; W32 $dci 0 3; W32 $dci 20 1; WP $dci 24 $qci; W32 $dci 48 $devExtensions.Count; WP $dci 56 $pExtNames
    $outDev = Block 8
    CheckVK ($vkCreateDevice.Invoke($Phys, $dci, [IntPtr]::Zero, $outDev)) "vkCreateDevice($Role)"
    $dev = [Runtime.InteropServices.Marshal]::ReadIntPtr($outDev)
    
    $outQ = Block 8
    $vkGetDeviceQueue.Invoke($dev, [uint32]$qf, [uint32]0, $outQ)
    $queue = [Runtime.InteropServices.Marshal]::ReadIntPtr($outQ)
    
    # Import D3D12 fence into binary semaphore
    $fnCreateSem = $interop.GetCall($vkGetDeviceProcAddr.Invoke($dev, 'vkCreateSemaphore'), [int], @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
    $fnImportWin32 = $interop.GetCall($vkGetDeviceProcAddr.Invoke($dev, 'vkImportSemaphoreWin32HandleKHR'), [int], @([IntPtr], [IntPtr]))
    
    $sci = Block 24; W32 $sci 0 9
    $outSem = Block 8
    CheckVK ($fnCreateSem.Invoke($dev, $sci, [IntPtr]::Zero, $outSem)) "vkCreateSemaphore($Role)"
    $sem = [Runtime.InteropServices.Marshal]::ReadInt64($outSem)
    
    $impInfo = Block 48
    W32 $impInfo 0 1000078000 # VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_WIN32_HANDLE_INFO_KHR
    W64 $impInfo 16 $sem
    W32 $impInfo 24 0         # permanent
    W32 $impInfo 28 8         # VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_D3D12_FENCE_BIT
    WP  $impInfo 32 $sharedFenceHandle
    CheckVK ($fnImportWin32.Invoke($dev, $impInfo)) "vkImportSemaphoreWin32HandleKHR($Role, D3D12_FENCE)"
    
    return [pscustomobject]@{
        Physical = $Phys
        Device = $dev
        Queue = $queue
        QueueFamily = $qf
        Semaphore = [uint64]$sem
    }
}

$die0 = CreateVkDie $prodPhys 'Die0-Producer'
$die1 = CreateVkDie $consPhys 'Die1-Consumer'
Write-Host "  [+] Die 0 & Die 1 created; D3D12 shared fence imported into both semaphores." -ForegroundColor Green

# -----------------------------------------------------------------------------
# 3. Pinned Host Memory Aperture (VirtualAlloc + VK_EXT_external_memory_host)
# -----------------------------------------------------------------------------
Write-Host "[3/6] Allocating and importing shared host aperture..." -ForegroundColor Yellow

$virtualAlloc = $interop.GetExportCall('kernel32.dll', 'VirtualAlloc', [IntPtr], @([IntPtr], [uint64], [uint32], [uint32]))
$virtualFree = $interop.GetExportCall('kernel32.dll', 'VirtualFree', [bool], @([IntPtr], [uint64], [uint32]))

$apertureBytes = 1048576 # 1 MiB = 262,144 uint32 words
$apertureHost = $virtualAlloc.Invoke([IntPtr]::Zero, [uint64]$apertureBytes, [uint32]0x3000, [uint32]4) # MEM_COMMIT|MEM_RESERVE, PAGE_READWRITE
if ($apertureHost -eq [IntPtr]::Zero) { throw 'VirtualAlloc failed for aperture' }
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new($apertureBytes), 0, $apertureHost, $apertureBytes)

$vkCreateBuffer = Fn 'vkCreateBuffer' [int] @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
$vkDestroyBuffer = Fn 'vkDestroyBuffer' [void] @([IntPtr], [uint64], [IntPtr])
$vkGetBufferMemoryRequirements = Fn 'vkGetBufferMemoryRequirements' [void] @([IntPtr], [uint64], [IntPtr])
$vkAllocateMemory = Fn 'vkAllocateMemory' [int] @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
$vkFreeMemory = Fn 'vkFreeMemory' [void] @([IntPtr], [uint64], [IntPtr])
$vkBindBufferMemory = Fn 'vkBindBufferMemory' [int] @([IntPtr], [uint64], [uint64], [uint64])

function ImportAperture([object]$Die, [string]$Role) {
    $extInfo = Block 24
    W32 $extInfo 0 1000072000 # VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO
    W32 $extInfo 16 128        # VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT
    
    $bci = Block 56
    W32 $bci 0 12 # VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
    WP  $bci 8 $extInfo
    W64 $bci 24 $apertureBytes
    W32 $bci 32 0x23 # STORAGE_BUFFER (0x20) | TRANSFER_DST (0x2) | TRANSFER_SRC (0x1)
    
    $outBuf = Block 8
    CheckVK ($vkCreateBuffer.Invoke($Die.Device, $bci, [IntPtr]::Zero, $outBuf)) "vkCreateBuffer($Role)"
    $buf = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outBuf)
    
    $req = Block 24
    $vkGetBufferMemoryRequirements.Invoke($Die.Device, $buf, $req)
    $reqBytes = [Runtime.InteropServices.Marshal]::ReadInt64($req, 0)
    $bits = [Runtime.InteropServices.Marshal]::ReadInt32($req, 16)
    
    $memProps = Block 520
    $vkGetPhysicalDeviceMemoryProperties.Invoke($Die.Physical, $memProps)
    
    $fnGetHostProps = $interop.GetCall($vkGetDeviceProcAddr.Invoke($Die.Device, 'vkGetMemoryHostPointerPropertiesEXT'), [int], @([IntPtr], [uint32], [IntPtr], [IntPtr]))
    $hp = Block 24; W32 $hp 0 1000178001
    CheckVK ($fnGetHostProps.Invoke($Die.Device, [uint32]128, $apertureHost, $hp)) "vkGetMemoryHostPointerPropertiesEXT($Role)"
    $bits = $bits -band ([Runtime.InteropServices.Marshal]::ReadInt32($hp, 16))
    
    $typeCount = [Runtime.InteropServices.Marshal]::ReadInt32($memProps, 0)
    $memType = -1
    for ($t = 0; $t -lt $typeCount; $t++) {
        if (($bits -band (1 -shl $t)) -ne 0) { $memType = $t; break }
    }
    if ($memType -lt 0) { throw "No compatible memory type for host pointer on $Role" }
    
    $impInfo = Block 32
    W32 $impInfo 0 1000178000 # VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT
    W32 $impInfo 16 128        # VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT
    WP  $impInfo 24 $apertureHost
    
    $mai = Block 32
    W32 $mai 0 5 # VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
    WP  $mai 8 $impInfo
    W64 $mai 16 $reqBytes
    W32 $mai 24 $memType
    
    $outMem = Block 8
    CheckVK ($vkAllocateMemory.Invoke($Die.Device, $mai, [IntPtr]::Zero, $outMem)) "vkAllocateMemory($Role)"
    $mem = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outMem)
    CheckVK ($vkBindBufferMemory.Invoke($Die.Device, $buf, $mem, [uint64]0)) "vkBindBufferMemory($Role)"
    
    return [pscustomobject]@{ Buffer=$buf; Memory=$mem }
}

$ap0 = ImportAperture $die0 'Die0'
$ap1 = ImportAperture $die1 'Die1'
Write-Host "  [+] Pinned aperture imported into Die 0 and Die 1 (Buffer handles: 0x$($ap0.Buffer.ToString('X')), 0x$($ap1.Buffer.ToString('X')))." -ForegroundColor Green

# -----------------------------------------------------------------------------
# 4. Consumer Pipeline Setup (ArenaFooterVerify Shader on Die 1)
# -----------------------------------------------------------------------------
Write-Host "[4/6] Building consumer verification compute pipeline on Die 1..." -ForegroundColor Yellow

# Results buffer on Die 1: host-visible, 32 bytes (8 uint32 words)
$resultsBytes = 32
$bciRes = Block 56; W32 $bciRes 0 12; W64 $bciRes 24 $resultsBytes; W32 $bciRes 32 0x20 # STORAGE_BUFFER
$outResBuf = Block 8
CheckVK ($vkCreateBuffer.Invoke($die1.Device, $bciRes, [IntPtr]::Zero, $outResBuf)) 'vkCreateBuffer(Results)'
$resBuf1 = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outResBuf)

$reqRes = Block 24; $vkGetBufferMemoryRequirements.Invoke($die1.Device, $resBuf1, $reqRes)
$resReqBytes = [Runtime.InteropServices.Marshal]::ReadInt64($reqRes, 0)
$resBits = [Runtime.InteropServices.Marshal]::ReadInt32($reqRes, 16)
$memProps1 = Block 520; $vkGetPhysicalDeviceMemoryProperties.Invoke($die1.Physical, $memProps1)
$resTypeCount = [Runtime.InteropServices.Marshal]::ReadInt32($memProps1, 0)
$resMemType = -1
for ($t = 0; $t -lt $resTypeCount; $t++) {
    $propFlags = [Runtime.InteropServices.Marshal]::ReadInt32($memProps1, 4 + $t * 8)
    if (($resBits -band (1 -shl $t)) -ne 0 -and ($propFlags -band 6) -eq 6) { # HOST_VISIBLE | HOST_COHERENT
        $resMemType = $t; break
    }
}
if ($resMemType -lt 0) { throw 'No host-visible coherent memory for results buffer' }

$maiRes = Block 32; W32 $maiRes 0 5; W64 $maiRes 16 $resReqBytes; W32 $maiRes 24 $resMemType
$outResMem = Block 8
CheckVK ($vkAllocateMemory.Invoke($die1.Device, $maiRes, [IntPtr]::Zero, $outResMem)) 'vkAllocateMemory(Results)'
$resMem1 = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outResMem)
CheckVK ($vkBindBufferMemory.Invoke($die1.Device, $resBuf1, $resMem1, [uint64]0)) 'vkBindBufferMemory(Results)'

# Initialize results memory: {0, 0, 0xffffffff, 0, 0, 0, 0, 0}
$vkMapMemory = Fn 'vkMapMemory' [int] @([IntPtr], [uint64], [uint64], [uint64], [uint32], [IntPtr])
$vkUnmapMemory = Fn 'vkUnmapMemory' [void] @([IntPtr], [uint64])
$outMap = Block 8
CheckVK ($vkMapMemory.Invoke($die1.Device, $resMem1, [uint64]0, [uint64]$resultsBytes, [uint32]0, $outMap)) 'vkMapMemory(Results)'
$pMappedResults = [Runtime.InteropServices.Marshal]::ReadIntPtr($outMap)
for ($i = 0; $i -lt 8; $i++) {
    $val = if ($i -eq 2) { -1 } else { 0 }
    [Runtime.InteropServices.Marshal]::WriteInt32($pMappedResults, $i * 4, $val)
}

# Create Shader Module
$vkCreateShaderModule = Fn 'vkCreateShaderModule' [int] @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
$pCode = Block $shaderBytes.Length
[Runtime.InteropServices.Marshal]::Copy($shaderBytes, 0, $pCode, $shaderBytes.Length)
$smci = Block 40; W32 $smci 0 16; W64 $smci 24 $shaderBytes.Length; WP $smci 32 $pCode
$outSm = Block 8
CheckVK ($vkCreateShaderModule.Invoke($die1.Device, $smci, [IntPtr]::Zero, $outSm)) 'vkCreateShaderModule'
$shaderModule = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outSm)

# Descriptor Set Layout: Binding 0 (Arena, STORAGE), Binding 1 (Results, STORAGE)
$vkCreateDescriptorSetLayout = Fn 'vkCreateDescriptorSetLayout' [int] @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
$bindings = Block (2 * 24)
# Binding 0
W32 $bindings 0 0    # binding 0
W32 $bindings 4 7    # VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
W32 $bindings 8 1    # count 1
W32 $bindings 12 0x20 # COMPUTE
# Binding 1
W32 $bindings 24 1   # binding 1
W32 $bindings 28 7   # VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
W32 $bindings 32 1   # count 1
W32 $bindings 36 0x20 # COMPUTE

$dslci = Block 32; W32 $dslci 0 32; W32 $dslci 20 2; WP $dslci 24 $bindings
$outDsl = Block 8
CheckVK ($vkCreateDescriptorSetLayout.Invoke($die1.Device, $dslci, [IntPtr]::Zero, $outDsl)) 'vkCreateDescriptorSetLayout'
$dsl = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outDsl)

# Pipeline Layout with Push Constants (16 bytes)
$vkCreatePipelineLayout = Fn 'vkCreatePipelineLayout' [int] @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
$pcr = Block 12; W32 $pcr 0 0x20; W32 $pcr 4 0; W32 $pcr 8 16 # stage=COMPUTE, offset=0, size=16
$pDslArr = Block 8; W64 $pDslArr 0 $dsl
$plci = Block 48; W32 $plci 0 30; W32 $plci 20 1; WP $plci 24 $pDslArr; W32 $plci 32 1; WP $plci 40 $pcr
$outPl = Block 8
CheckVK ($vkCreatePipelineLayout.Invoke($die1.Device, $plci, [IntPtr]::Zero, $outPl)) 'vkCreatePipelineLayout'
$pipelineLayout = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outPl)

# Compute Pipeline
$vkCreateComputePipelines = Fn 'vkCreateComputePipelines' [int] @([IntPtr], [uint64], [uint32], [IntPtr], [IntPtr], [IntPtr])
$mainStr = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi('main'); $blocks.Add($mainStr)
$cpci = Block 96
W32 $cpci 0 29 # VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO
# stage at offset 24
W32 $cpci 24 18 # VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
W32 $cpci 44 0x20 # COMPUTE
W64 $cpci 48 $shaderModule
WP  $cpci 56 $mainStr
# layout at offset 72
W64 $cpci 72 $pipelineLayout
W64 $cpci 80 0
W32 $cpci 88 -1

$outPipe = Block 8
CheckVK ($vkCreateComputePipelines.Invoke($die1.Device, [uint64]0, [uint32]1, $cpci, [IntPtr]::Zero, $outPipe)) 'vkCreateComputePipelines'
$pipeline = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outPipe)

# Descriptor Pool & Set
$vkCreateDescriptorPool = Fn 'vkCreateDescriptorPool' [int] @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
$vkAllocateDescriptorSets = Fn 'vkAllocateDescriptorSets' [int] @([IntPtr], [IntPtr], [IntPtr])
$vkUpdateDescriptorSets = Fn 'vkUpdateDescriptorSets' [void] @([IntPtr], [uint32], [IntPtr], [uint32], [IntPtr])

$poolSize = Block 8; W32 $poolSize 0 7; W32 $poolSize 4 2
$dpci = Block 40; W32 $dpci 0 33; W32 $dpci 20 1; W32 $dpci 24 1; WP $dpci 32 $poolSize
$outDp = Block 8
CheckVK ($vkCreateDescriptorPool.Invoke($die1.Device, $dpci, [IntPtr]::Zero, $outDp)) 'vkCreateDescriptorPool'
$descPool = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outDp)

$dsai = Block 32; W32 $dsai 0 34; W64 $dsai 16 $descPool; W32 $dsai 24 1; WP $dsai 32 $pDslArr
$outDs = Block 8
CheckVK ($vkAllocateDescriptorSets.Invoke($die1.Device, $dsai, $outDs)) 'vkAllocateDescriptorSets'
$descSet = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outDs)

# Update Descriptor Set: Binding 0 -> ap1.Buffer, Binding 1 -> resBuf1
$bufInfo0 = Block 24; W64 $bufInfo0 0 $ap1.Buffer; W64 $bufInfo0 8 0; W64 $bufInfo0 16 ([uint64]::MaxValue)
$bufInfo1 = Block 24; W64 $bufInfo1 0 $resBuf1; W64 $bufInfo1 8 0; W64 $bufInfo1 16 ([uint64]::MaxValue)
$writes = Block (2 * 64)
# Write 0
W32 $writes 0 35; W64 $writes 16 $descSet; W32 $writes 24 0; W32 $writes 32 1; W32 $writes 36 7; WP $writes 48 $bufInfo0
# Write 1
W32 $writes 64 35; W64 $writes 80 $descSet; W32 $writes 88 1; W32 $writes 96 1; W32 $writes 100 7; WP $writes 112 $bufInfo1
$vkUpdateDescriptorSets.Invoke($die1.Device, [uint32]2, $writes, [uint32]0, [IntPtr]::Zero)

Write-Host "  [+] Consumer pipeline created and descriptor sets bound." -ForegroundColor Green

# -----------------------------------------------------------------------------
# 5. Recording Command Buffers
# -----------------------------------------------------------------------------
Write-Host "[5/6] Recording Producer payload commands and Consumer verifier dispatch..." -ForegroundColor Yellow

$vkCreateCommandPool = Fn 'vkCreateCommandPool' [int] @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
$vkAllocateCommandBuffers = Fn 'vkAllocateCommandBuffers' [int] @([IntPtr], [IntPtr], [IntPtr])
$vkBeginCommandBuffer = Fn 'vkBeginCommandBuffer' [int] @([IntPtr], [IntPtr])
$vkEndCommandBuffer = Fn 'vkEndCommandBuffer' [int] @([IntPtr])
$vkCmdFillBuffer = Fn 'vkCmdFillBuffer' [void] @([IntPtr], [uint64], [uint64], [uint64], [uint32])
$vkCmdUpdateBuffer = Fn 'vkCmdUpdateBuffer' [void] @([IntPtr], [uint64], [uint64], [uint64], [IntPtr])
$vkCmdPipelineBarrier = Fn 'vkCmdPipelineBarrier' [void] @([IntPtr], [uint32], [uint32], [uint32], [uint32], [IntPtr], [uint32], [IntPtr], [uint32], [IntPtr])
$vkCmdBindPipeline = Fn 'vkCmdBindPipeline' [void] @([IntPtr], [uint32], [uint64])
$vkCmdBindDescriptorSets = Fn 'vkCmdBindDescriptorSets' [void] @([IntPtr], [uint32], [uint64], [uint32], [uint32], [IntPtr], [uint32], [IntPtr])
$vkCmdPushConstants = Fn 'vkCmdPushConstants' [void] @([IntPtr], [uint64], [uint32], [uint32], [uint32], [IntPtr])
$vkCmdDispatch = Fn 'vkCmdDispatch' [void] @([IntPtr], [uint32], [uint32], [uint32])

# Command pools
function NewPool([IntPtr]$Dev, [int]$Qf) {
    $pci = Block 24; W32 $pci 0 38; W32 $pci 16 2; W32 $pci 20 $Qf
    $outP = Block 8
    CheckVK ($vkCreateCommandPool.Invoke($Dev, $pci, [IntPtr]::Zero, $outP)) 'vkCreateCommandPool'
    return [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outP)
}
$pool0 = NewPool $die0.Device $die0.QueueFamily
$pool1 = NewPool $die1.Device $die1.QueueFamily

function NewCmd([IntPtr]$Dev, [uint64]$Pool) {
    $cai = Block 32; W32 $cai 0 40; W64 $cai 16 $Pool; W32 $cai 28 1
    $outC = Block 8
    CheckVK ($vkAllocateCommandBuffers.Invoke($Dev, $cai, $outC)) 'vkAllocateCommandBuffers'
    return [Runtime.InteropServices.Marshal]::ReadIntPtr($outC)
}
$cmd0 = NewCmd $die0.Device $pool0
$cmd1 = NewCmd $die1.Device $pool1

# --- Record Producer (Die 0) ---
# Geometry: 21 regions of 256 words (1024 bytes) each, spaced by 1024 words (4096 bytes)
$regionCount = 21
$wordsPerRegion = 256
$expectedSequence = 1
$footerWord = 22000
$payloadEndWord = $regionCount * 1024

$footerData = [uint32[]]::new(4 + $regionCount * 4)
$footerData[0] = 0x56333430 # MAGIC "V340"
$footerData[1] = $expectedSequence
$footerData[2] = $regionCount
$footerData[3] = $payloadEndWord

$totalWordsExpected = 0
for ($e = 0; $e -lt $regionCount; $e++) {
    $off = $e * 1024
    $len = $wordsPerRegion
    $baseVal = 0x10000000 + ($e * 0x00010000)
    $stepVal = 0
    $footerData[4 + $e * 4 + 0] = $off
    $footerData[4 + $e * 4 + 1] = $len
    $footerData[4 + $e * 4 + 2] = $baseVal
    $footerData[4 + $e * 4 + 3] = $stepVal
    $totalWordsExpected += $len
}

$cbBegin = Block 32; W32 $cbBegin 0 42
CheckVK ($vkBeginCommandBuffer.Invoke($cmd0, $cbBegin)) 'vkBeginCommandBuffer(Die0)'

# 1. Fill 21 payload regions
for ($e = 0; $e -lt $regionCount; $e++) {
    $byteOffset = [uint64]($e * 1024 * 4)
    $byteSize = [uint64]($wordsPerRegion * 4)
    $val = [uint32](0x10000000 + ($e * 0x00010000))
    $vkCmdFillBuffer.Invoke($cmd0, $ap0.Buffer, $byteOffset, $byteSize, $val)
}

# 2. Write Manifest Footer
$pFooterBytes = Block ($footerData.Length * 4)
for ($i = 0; $i -lt $footerData.Length; $i++) {
    [Runtime.InteropServices.Marshal]::WriteInt32($pFooterBytes, $i * 4, [BitConverter]::ToInt32([BitConverter]::GetBytes($footerData[$i]), 0))
}
$vkCmdUpdateBuffer.Invoke($cmd0, $ap0.Buffer, [uint64]($footerWord * 4), [uint64]($footerData.Length * 4), $pFooterBytes)

# 3. Pipeline Barrier (Transfer Write -> Bottom of Pipe / Memory Available)
$memBarrier = Block 24
W32 $memBarrier 0 46 # VK_STRUCTURE_TYPE_MEMORY_BARRIER
W32 $memBarrier 16 0x1000 # VK_ACCESS_TRANSFER_WRITE_BIT
W32 $memBarrier 20 0x800  # VK_ACCESS_MEMORY_READ_BIT
$vkCmdPipelineBarrier.Invoke($cmd0, [uint32]0x1000, [uint32]0x2000, [uint32]0, [uint32]1, $memBarrier, [uint32]0, [IntPtr]::Zero, [uint32]0, [IntPtr]::Zero)

CheckVK ($vkEndCommandBuffer.Invoke($cmd0)) 'vkEndCommandBuffer(Die0)'

# --- Record Consumer (Die 1) ---
CheckVK ($vkBeginCommandBuffer.Invoke($cmd1, $cbBegin)) 'vkBeginCommandBuffer(Die1)'
$vkCmdBindPipeline.Invoke($cmd1, [uint32]1, $pipeline) # 1 = BIND_POINT_COMPUTE
$pDsArr = Block 8; W64 $pDsArr 0 $descSet
$vkCmdBindDescriptorSets.Invoke($cmd1, [uint32]1, $pipelineLayout, [uint32]0, [uint32]1, $pDsArr, [uint32]0, [IntPtr]::Zero)

$pushConstants = Block 16
W32 $pushConstants 0 $footerWord
W32 $pushConstants 4 $expectedSequence
W32 $pushConstants 8 ($apertureBytes / 4) # arenaWordCount
W32 $pushConstants 12 0                   # resultWord
$vkCmdPushConstants.Invoke($cmd1, $pipelineLayout, [uint32]0x20, [uint32]0, [uint32]16, $pushConstants)

# 1 workgroup (64 invocations)
$vkCmdDispatch.Invoke($cmd1, [uint32]1, [uint32]1, [uint32]1)
CheckVK ($vkEndCommandBuffer.Invoke($cmd1)) 'vkEndCommandBuffer(Die1)'

Write-Host "  [+] Command buffers recorded." -ForegroundColor Green

# -----------------------------------------------------------------------------
# 6. Submission & Hardware Baton Execution (Zero Host Synchronization)
# -----------------------------------------------------------------------------
Write-Host "[6/6] Executing GPU baton pipeline..." -ForegroundColor Yellow

$vkCreateFence = Fn 'vkCreateFence' [int] @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
$vkWaitForFences = Fn 'vkWaitForFences' [int] @([IntPtr], [uint32], [IntPtr], [uint32], [uint64])
$vkQueueSubmit = Fn 'vkQueueSubmit' [int] @([IntPtr], [uint32], [IntPtr], [uint64])

# Create terminal fence on Die 1 for final completion observation
$fci = Block 24; W32 $fci 0 8
$outTermFence = Block 8
CheckVK ($vkCreateFence.Invoke($die1.Device, $fci, [IntPtr]::Zero, $outTermFence)) 'vkCreateFence(Terminal)'
$terminalFence = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outTermFence)

$fenceValue = Block 8; W64 $fenceValue 0 1

# Consumer Submit Info (Die 1): WAITS on D3D12 fence semaphore value 1
$waitValues = Block 48
W32 $waitValues 0 1000078002 # VK_STRUCTURE_TYPE_D3D12_FENCE_SUBMIT_INFO_KHR
W32 $waitValues 16 1         # waitSemaphoreValuesCount
WP  $waitValues 24 $fenceValue
$pWaitSem = Block 8; W64 $pWaitSem 0 $die1.Semaphore
$pWaitDstStage = Block 4; W32 $pWaitDstStage 0 0x20 # VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT
$pCmd1 = Block 8; WP $pCmd1 0 $cmd1

$sub1 = Block 72
W32 $sub1 0 4 # VK_STRUCTURE_TYPE_SUBMIT_INFO
WP  $sub1 8 $waitValues
W32 $sub1 16 1; WP $sub1 24 $pWaitSem; WP $sub1 32 $pWaitDstStage
W32 $sub1 40 1; WP $sub1 48 $pCmd1

# Producer Submit Info (Die 0): SIGNALS D3D12 fence semaphore value 1
$signalValues = Block 48
W32 $signalValues 0 1000078002 # VK_STRUCTURE_TYPE_D3D12_FENCE_SUBMIT_INFO_KHR
W32 $signalValues 32 1         # signalSemaphoreValuesCount
WP  $signalValues 40 $fenceValue
$pSigSem = Block 8; W64 $pSigSem 0 $die0.Semaphore
$pCmd0 = Block 8; WP $pCmd0 0 $cmd0

$sub0 = Block 72
W32 $sub0 0 4 # VK_STRUCTURE_TYPE_SUBMIT_INFO
WP  $sub0 8 $signalValues
W32 $sub0 40 1; WP $sub0 48 $pCmd0
W32 $sub0 56 1; WP $sub0 64 $pSigSem

Write-Host "  [*] Submitting Consumer (Die 1) BEFORE Producer (Die 0)..." -ForegroundColor Gray
$swCons = [Diagnostics.Stopwatch]::StartNew()
CheckVK ($vkQueueSubmit.Invoke($die1.Queue, [uint32]1, $sub1, $terminalFence)) 'vkQueueSubmit(Die1 Consumer Wait)'
$swCons.Stop()

Write-Host "  [*] Submitting Producer (Die 0) to signal baton..." -ForegroundColor Gray
$swProd = [Diagnostics.Stopwatch]::StartNew()
CheckVK ($vkQueueSubmit.Invoke($die0.Queue, [uint32]1, $sub0, [uint64]0)) 'vkQueueSubmit(Die0 Producer Signal)'
$swProd.Stop()

Write-Host "  [*] Both queues in flight. Awaiting terminal fence on Die 1..." -ForegroundColor Gray
$swTotal = [Diagnostics.Stopwatch]::StartNew()
$pTermFence = Block 8; W64 $pTermFence 0 $terminalFence
CheckVK ($vkWaitForFences.Invoke($die1.Device, [uint32]1, $pTermFence, [uint32]1, [uint64]5000000000L)) 'vkWaitForFences(Die1)'
$swTotal.Stop()

# Verify native D3D12 fence completed value
$getNativeValue = $interop.GetComCall($nativeFence, 8, [uint64], @())
$nativeCompleted = $getNativeValue.DynamicInvoke($nativeFence)

# Read Results from Die 1 mapped memory
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

$pass = ($errorFlags -eq 0) -and ($mismatches -eq 0) -and ($observedSeq -eq $expectedSequence) -and ($observedCount -eq $regionCount) -and ($examinedWords -eq $totalWordsExpected)

Write-Host "`n=== Execution Receipt ===" -ForegroundColor $(if ($pass) { 'Green' } else { 'Red' })
Write-Host "Status:                   $(if ($pass) { 'PASS' } else { 'FAIL' })"
Write-Host "Native Fence Value:       $nativeCompleted (Expected: 1)"
Write-Host "Error Flags:              0x$($errorFlags.ToString('X8')) (Expected: 0x0)"
Write-Host "Mismatches:               $mismatches (Expected: 0)"
Write-Host "First Bad Word Index:     0x$($firstBadWord.ToString('X8'))"
Write-Host "Observed Sequence:        $observedSeq (Expected: $expectedSequence)"
Write-Host "Observed Region Count:    $observedCount (Expected: $regionCount)"
Write-Host "Examined Words:           $examinedWords (Expected: $totalWordsExpected)"
Write-Host "Consumer Submit WallTime: $([math]::Round($swCons.Elapsed.TotalMilliseconds, 3)) ms"
Write-Host "Producer Submit WallTime: $([math]::Round($swProd.Elapsed.TotalMilliseconds, 3)) ms"
Write-Host "Total Execution Time:     $([math]::Round($swTotal.Elapsed.TotalMilliseconds, 3)) ms"

$receipt = [ordered]@{
    Status = if ($pass) { 'PASS' } else { 'FAIL' }
    ProducerOrdinal = $ProducerOrdinal
    ConsumerOrdinal = $ConsumerOrdinal
    ProducerLUID = $prodAdapter.LUID
    ConsumerLUID = $consAdapter.LUID
    NativeFenceCompletedValue = $nativeCompleted
    ErrorFlags = $errorFlags
    Mismatches = $mismatches
    FirstBadWord = $firstBadWord
    ObservedSequence = $observedSeq
    ObservedRegionCount = $observedCount
    ExaminedWords = $examinedWords
    ExpectedWords = $totalWordsExpected
    ConsumerSubmitMilliseconds = [math]::Round($swCons.Elapsed.TotalMilliseconds, 4)
    ProducerSubmitMilliseconds = [math]::Round($swProd.Elapsed.TotalMilliseconds, 4)
    TotalPipelineMilliseconds = [math]::Round($swTotal.Elapsed.TotalMilliseconds, 4)
    TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
}

$receiptDir = Split-Path $ReceiptPath
if (-not (Test-Path $receiptDir)) { New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null }
$receipt | ConvertTo-Json -Depth 4 | Set-Content -Path $ReceiptPath -Encoding UTF8
Write-Host "Receipt written to: $ReceiptPath" -ForegroundColor Cyan

if (-not $pass) {
    throw "Verification failed: ErrorFlags=0x$($errorFlags.ToString('X8')), Mismatches=$mismatches"
}
