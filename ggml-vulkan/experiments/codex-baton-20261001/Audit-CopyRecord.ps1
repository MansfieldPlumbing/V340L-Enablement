<#
.SYNOPSIS
    Self-contained launcher and benchmark for stock llama.cpp using the lowered
    V340L managed assembly shim and D3D12 cross-adapter GPU hardware baton.

.DESCRIPTION
    Fulfills the Gemini work order (gemini-stock-llama-pwsh-baton-workorder-20261001.md):
    - Uses unmodified stock runtime DLLs staged in runtime-stock (SHA256 verified).
    - Patches IAT before Vulkan initialization to inject VK_KHR_external_semaphore_win32.
    - Emits & loads V340L-LlamaBatonShim.dll (via PersistedAssemblyBuilder, zero Roslyn/MSBuild).
    - Creates D3D12 cross-adapter shared fence and imports into Vulkan binary semaphores.
    - Intercepts cpy_tensor_async to route layer-boundary activations through the shared aperture.
    - Hardware D3D12 fence signals on Die 0 SDMA and waits on Die 1 compute with ZERO CPU waits.
    - Executes real Gemma 4 model inference and records machine-readable receipts.
#>

[CmdletBinding()]
param(
    [string] $Model = 'C:\Models\gemma-4-E4B-it-Q4_K_M.gguf',
    [string] $RuntimeDir = 'C:\dev\V340L-Emancipated\scratch\codex-baton-20261001\runtime',
    [string] $DeviceSelection = 'Vulkan0/Vulkan1',
    [string] $TensorSplit = '1/1',
    [string] $Prompt = 'The capital of France is',
    [int] $Tokens = 1,
    [uint64] $ApertureBytes = 33554432, # 32 MiB
    [string] $ReceiptPath = 'C:\dev\V340L-Emancipated\GGML\Vulkan\Receipts\vulkan-stock-llama-baton-20261001.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([IntPtr]::Size -ne 8) { throw '64-bit PowerShell required.' }

Write-Host "=== V340L Stock llama.cpp GPU Hardware Baton Launcher ===" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# 1. Validation of Runtime Binaries and Hashes
# -----------------------------------------------------------------------------
Write-Host "[1/7] Validating stock binaries and runtime directory..." -ForegroundColor Yellow

$stockVulkanExpectedHash = 'AE67DDD85CC9C0E777FA76368E1A63AD90DDD4B97709CBC5C46F734F97C5248E'
$stagedVulkanDll = Join-Path $RuntimeDir 'ggml-vulkan.dll'
if (-not (Test-Path $stagedVulkanDll)) {
    throw "Missing staged Vulkan DLL at $stagedVulkanDll"
}
$actualVulkanHash = (Get-FileHash -LiteralPath $stagedVulkanDll -Algorithm SHA256).Hash
if ($actualVulkanHash -ne $stockVulkanExpectedHash) {
    throw "Staged Vulkan DLL hash mismatch: $actualVulkanHash (expected $stockVulkanExpectedHash)"
}
Write-Host "  [+] Stock Vulkan DLL verified: $actualVulkanHash" -ForegroundColor Green

if (-not (Test-Path -LiteralPath $Model)) { throw "Model file not found: $Model" }
Write-Host "  [+] Model file verified: $Model ($([math]::Round((Get-Item $Model).Length / 1GB, 2)) GB)" -ForegroundColor Green

$interop = & "C:\dev\V340L-Emancipated\src\New-WindowsFunctionPointerBinder.ps1"
$blocks = [Collections.Generic.List[IntPtr]]::new()
$com = [Collections.Generic.List[IntPtr]]::new()

function Block([int]$Bytes) {
    $p = [Runtime.InteropServices.Marshal]::AllocHGlobal($Bytes)
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new($Bytes), 0, $p, $Bytes)
    $blocks.Add($p)
    return $p
}
function W32([IntPtr]$P, [int]$O, $V) { [Runtime.InteropServices.Marshal]::WriteInt32($P, $O, [int]$V) }
function W64([IntPtr]$P, [int]$O, $V) {
    $signed = [BitConverter]::ToInt64([BitConverter]::GetBytes([uint64]$V), 0)
    [Runtime.InteropServices.Marshal]::WriteInt64($P, $O, $signed)
}
function WP([IntPtr]$P, [int]$O, [IntPtr]$V) { [Runtime.InteropServices.Marshal]::WriteIntPtr($P, $O, $V) }
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

# -----------------------------------------------------------------------------
# 2. Build and Load Lowered Shim Assembly
# -----------------------------------------------------------------------------
Write-Host "[2/7] Emitting and loading V340L-LlamaBatonShim.dll..." -ForegroundColor Yellow

$shimDllPath = Join-Path $RuntimeDir 'V340L-LlamaBatonShim.dll'
& "C:\dev\V340L-Emancipated\scratch\codex-baton-20261001\New-CopyRecordAuditShim.ps1" -OutputPath $shimDllPath

$shimBytes = [IO.File]::ReadAllBytes($shimDllPath)
$shimAssembly = [Reflection.Assembly]::Load($shimBytes)
$shimType = $shimAssembly.GetType('V340L.LlamaBatonShim')
if ($null -eq $shimType) { throw 'Failed to load V340L.LlamaBatonShim from assembly.' }
Write-Host "  [+] Lowered managed assembly loaded successfully." -ForegroundColor Green

# -----------------------------------------------------------------------------
# 3. Setup D3D12 Cross-Adapter Fence
# -----------------------------------------------------------------------------
Write-Host "[3/7] Setting up D3D12 cross-adapter fence..." -ForegroundColor Yellow

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

if ($dxgiAdapters.Count -lt 2) { throw "Found $($dxgiAdapters.Count) V340 adapters; need at least 2." }
$dev0Dxgi = $dxgiAdapters[0]
$dev1Dxgi = $dxgiAdapters[1]
Write-Host "  [+] Die 0 DXGI: $($dev0Dxgi.Name) (LUID: $($dev0Dxgi.LUID))" -ForegroundColor Gray
Write-Host "  [+] Die 1 DXGI: $($dev1Dxgi.Name) (LUID: $($dev1Dxgi.LUID))" -ForegroundColor Gray

$outD3DDev = Block 8
CheckHR ($createD3D12Device.Invoke($dev0Dxgi.Adapter, 0xB000, $iidD3D12Device, $outD3DDev)) 'D3D12CreateDevice(Die0)'
$d3dDev0 = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($outD3DDev))

$createFenceD3D = $interop.GetComCall($d3dDev0, 36, [int], @([uint64], [uint32], [IntPtr], [IntPtr]))
$outFence = Block 8
CheckHR ($createFenceD3D.DynamicInvoke($d3dDev0, [uint64]0, [uint32]3, $iidFence, $outFence)) 'CreateFence(SHARED_CROSS_ADAPTER)'
$nativeFence = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($outFence))

$createShared = $interop.GetComCall($d3dDev0, 31, [int], @([IntPtr], [IntPtr], [uint32], [IntPtr], [IntPtr]))
$outHandle = Block 8
CheckHR ($createShared.DynamicInvoke($d3dDev0, $nativeFence, [IntPtr]::Zero, [uint32]0x10000000, [IntPtr]::Zero, $outHandle)) 'CreateSharedHandle'
$sharedFenceHandle = [Runtime.InteropServices.Marshal]::ReadIntPtr($outHandle)
Write-Host "  [+] D3D12 cross-adapter shared handle: 0x$($sharedFenceHandle.ToString('X'))" -ForegroundColor Green

# -----------------------------------------------------------------------------
# 4. Allocate Permanent Shared Host Aperture
# -----------------------------------------------------------------------------
Write-Host "[4/7] Allocating permanent pinned host aperture arena..." -ForegroundColor Yellow

$virtualAlloc = $interop.GetExportCall('kernel32.dll', 'VirtualAlloc', [IntPtr], @([IntPtr], [uint64], [uint32], [uint32]))
$apertureHost = $virtualAlloc.Invoke([IntPtr]::Zero, [uint64]$ApertureBytes, [uint32]0x3000, [uint32]4) # MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE
if ($apertureHost -eq [IntPtr]::Zero) { throw 'VirtualAlloc failed for host aperture' }
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new($ApertureBytes), 0, $apertureHost, [int][Math]::Min($ApertureBytes, 1048576))
Write-Host "  [+] Allocated $([math]::Round($ApertureBytes / 1MB)) MiB aperture arena at 0x$($apertureHost.ToString('X'))" -ForegroundColor Green

# -----------------------------------------------------------------------------
# 5. Patch IAT on stock ggml-vulkan.dll and Hook Device Creation
# -----------------------------------------------------------------------------
Write-Host "[5/7] Patching stock ggml-vulkan.dll IAT to intercept vkCreateDevice..." -ForegroundColor Yellow

$hVkLib = $interop.LoadLibrary('C:\Windows\System32\vulkan-1.dll')
$pfnRealGipa = $interop.GetExport($hVkLib, 'vkGetInstanceProcAddr')
$pfnRealCreateDevice = $interop.GetExport($hVkLib, 'vkCreateDevice')
$pfnQueueSubmit = $interop.GetExport($hVkLib, 'vkQueueSubmit')
$pfnGetDeviceQueue = $interop.GetExport($hVkLib, 'vkGetDeviceQueue')

$hStockVulkan = $interop.LoadLibrary($stagedVulkanDll)

# Locate IAT slot for vkGetInstanceProcAddr in stock ggml-vulkan.dll
$dosHeader = $hStockVulkan
$e_lfanew = [Runtime.InteropServices.Marshal]::ReadInt32($dosHeader, 0x3C)
$ntHeaders = [IntPtr]::Add($dosHeader, $e_lfanew)
$optHeader = [IntPtr]::Add($ntHeaders, 0x18)
$importRva = [Runtime.InteropServices.Marshal]::ReadInt32($optHeader, 0x78)
$pImportDesc = [IntPtr]::Add($hStockVulkan, $importRva)

$targetIatSlot = [IntPtr]::Zero
while ($true) {
    $nameRva = [Runtime.InteropServices.Marshal]::ReadInt32($pImportDesc, 12)
    if ($nameRva -eq 0) { break }
    $dllName = [Runtime.InteropServices.Marshal]::PtrToStringAnsi([IntPtr]::Add($hStockVulkan, $nameRva))
    if ($dllName -match 'vulkan') {
        $firstThunkRva = [Runtime.InteropServices.Marshal]::ReadInt32($pImportDesc, 16)
        $origThunkRva = [Runtime.InteropServices.Marshal]::ReadInt32($pImportDesc, 0)
        $thunkRva = if ($origThunkRva -ne 0) { $origThunkRva } else { $firstThunkRva }
        $pThunk = [IntPtr]::Add($hStockVulkan, $thunkRva)
        $pIat = [IntPtr]::Add($hStockVulkan, $firstThunkRva)
        $i = 0
        while ($true) {
            $data = [Runtime.InteropServices.Marshal]::ReadInt64($pThunk, $i * 8)
            if ($data -eq 0) { break }
            if (($data -band [long]0x8000000000000000L) -eq 0) {
                $pByName = [IntPtr]::Add($hStockVulkan, [int]$data)
                $fnName = [Runtime.InteropServices.Marshal]::PtrToStringAnsi([IntPtr]::Add($pByName, 2))
                if ($fnName -eq 'vkGetInstanceProcAddr') {
                    $targetIatSlot = [IntPtr]::Add($pIat, $i * 8)
                    break
                }
            }
            $i++
        }
    }
    if ($targetIatSlot -ne [IntPtr]::Zero) { break }
    $pImportDesc = [IntPtr]::Add($pImportDesc, 20)
}

if ($targetIatSlot -eq [IntPtr]::Zero) { throw 'Could not locate vkGetInstanceProcAddr IAT slot in stock DLL.' }

# Bind and prepare shim delegates
$fnHookGipa = $shimType.GetMethod('Hook_VkGetInstanceProcAddr')
$fnHookCreateDevice = $shimType.GetMethod('Hook_VkCreateDevice')
$fnHookCpy = $shimType.GetMethod('Hook_CpyTensorAsync')
$fnHookInit0 = $shimType.GetMethod('Hook_InitBackend0')
$fnHookInit1 = $shimType.GetMethod('Hook_InitBackend1')

[Runtime.CompilerServices.RuntimeHelpers]::PrepareMethod($fnHookGipa.MethodHandle)
[Runtime.CompilerServices.RuntimeHelpers]::PrepareMethod($fnHookCreateDevice.MethodHandle)
[Runtime.CompilerServices.RuntimeHelpers]::PrepareMethod($fnHookCpy.MethodHandle)
[Runtime.CompilerServices.RuntimeHelpers]::PrepareMethod($fnHookInit0.MethodHandle)
[Runtime.CompilerServices.RuntimeHelpers]::PrepareMethod($fnHookInit1.MethodHandle)

$delHookGipaType = $shimAssembly.GetType('V340L.VkGetInstanceProcAddrCallback')
$delHookGipa = [Delegate]::CreateDelegate($delHookGipaType, $fnHookGipa)
$pHookGipa = [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($delHookGipa)

$delHookCdType = $shimAssembly.GetType('V340L.VkCreateDeviceCallback')
$delHookCd = [Delegate]::CreateDelegate($delHookCdType, $fnHookCreateDevice)
$pHookCd = [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($delHookCd)

$delHookCpyType = $shimAssembly.GetType('V340L.CpyTensorAsyncCallback')
$delHookCpy = [Delegate]::CreateDelegate($delHookCpyType, $fnHookCpy)
$pHookCpy = [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($delHookCpy)

$delHookInitType = $shimAssembly.GetType('V340L.InitBackendCallback')
$delHookInit0 = [Delegate]::CreateDelegate($delHookInitType, $fnHookInit0)
$delHookInit1 = [Delegate]::CreateDelegate($delHookInitType, $fnHookInit1)
$pHookInit0 = [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($delHookInit0)
$pHookInit1 = [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($delHookInit1)

$rootedDelegates = [Collections.Generic.List[object]]::new()
$rootedDelegates.Add($delHookGipa)
$rootedDelegates.Add($delHookCd)
$rootedDelegates.Add($delHookCpy)
$rootedDelegates.Add($delHookInit0)
$rootedDelegates.Add($delHookInit1)

# Configure shim static fields
$shimType.GetField('RealVkGetInstanceProcAddr').SetValue($null, $pfnRealGipa)
$shimType.GetField('RealVkCreateDevice').SetValue($null, $pfnRealCreateDevice)
$shimType.GetField('HookCreateDevicePtr').SetValue($null, $pHookCd)
$shimType.GetField('HookCpyTensorAsyncPtr').SetValue($null, $pHookCpy)
$shimType.GetField('HookInitBackend0Ptr').SetValue($null, $pHookInit0)
$shimType.GetField('HookInitBackend1Ptr').SetValue($null, $pHookInit1)
$shimType.GetField('VkQueueSubmit').SetValue($null, $pfnQueueSubmit)
$shimType.GetField('ApertureCapacity').SetValue($null, $ApertureBytes)
$shimType.GetField('ApertureCursor').SetValue($null, [long]0x1000)
$shimType.GetField('CurrentFenceValue').SetValue($null, [uint64]0)
$shimType.GetField('HandledHandoffs').SetValue($null, [long]0)
$shimType.GetField('FallbackHandoffs').SetValue($null, [long]0)

# Apply IAT hook with VirtualProtect
$virtualProtect = $interop.GetExportCall('kernel32.dll', 'VirtualProtect', [bool], @([IntPtr], [uint64], [uint32], [IntPtr]))
$oldProtect = Block 4
$ok = $virtualProtect.Invoke($targetIatSlot, [uint64]8, [uint32]0x04, $oldProtect) # PAGE_READWRITE
if (-not $ok) { throw 'VirtualProtect PAGE_READWRITE failed on IAT slot.' }
[Runtime.InteropServices.Marshal]::WriteIntPtr($targetIatSlot, $pHookGipa)
$virtualProtect.Invoke($targetIatSlot, [uint64]8, [uint32][Runtime.InteropServices.Marshal]::ReadInt32($oldProtect), $oldProtect) | Out-Null

Write-Host "  [+] IAT hook installed on stock ggml-vulkan.dll: 0x$($targetIatSlot.ToString('X')) -> 0x$($pHookGipa.ToString('X'))" -ForegroundColor Green

# -----------------------------------------------------------------------------
# 6. Initialize Llama Backends and Configure Hardware Baton
# -----------------------------------------------------------------------------
Write-Host "[6/7] Initializing backends and importing hardware baton..." -ForegroundColor Yellow

$oldPath = $env:PATH
$env:PATH = "$RuntimeDir;$env:PATH"

$ggmlLib = $interop.LoadLibrary((Join-Path $RuntimeDir 'ggml.dll'))
$ggmlBaseLib = $interop.LoadLibrary((Join-Path $RuntimeDir 'ggml-base.dll'))
$llamaCliLib = $interop.LoadLibrary((Join-Path $RuntimeDir 'llama-cli-impl.dll'))

$loadAllFromPath = $interop.GetCall($interop.GetExport($ggmlLib, 'ggml_backend_load_all_from_path'), [void], @([IntPtr]))
$devCountFn = $interop.GetCall($interop.GetExport($ggmlLib, 'ggml_backend_dev_count'), [uint64], @())
$devGetFn = $interop.GetCall($interop.GetExport($ggmlLib, 'ggml_backend_dev_get'), [IntPtr], @([uint64]))
$devNameFn = $interop.GetCall($interop.GetExport($ggmlBaseLib, 'ggml_backend_dev_name'), [IntPtr], @([IntPtr]))
$devDescFn = $interop.GetCall($interop.GetExport($ggmlBaseLib, 'ggml_backend_dev_description'), [IntPtr], @([IntPtr]))
$bufFromHostFn = $interop.GetCall($interop.GetExport($ggmlBaseLib, 'ggml_backend_dev_buffer_from_host_ptr'), [IntPtr], @([IntPtr], [IntPtr], [uint64], [uint64]))
$tensorAllocFn = $interop.GetCall($interop.GetExport($ggmlBaseLib, 'ggml_backend_tensor_alloc'), [int], @([IntPtr], [IntPtr], [IntPtr]))
$nbytesFnPtr = $interop.GetExport($ggmlBaseLib, 'ggml_nbytes')

$shimType.GetField('GgmlNBytesFn').SetValue($null, $nbytesFnPtr)

# Load all backends from RuntimeDir
$pRuntimeDirStr = [Runtime.InteropServices.Marshal]::StringToCoTaskMemUTF8($RuntimeDir)
try {
    $loadAllFromPath.DynamicInvoke($pRuntimeDirStr)
} finally {
    [Runtime.InteropServices.Marshal]::FreeCoTaskMem($pRuntimeDirStr)
}

$createdDevCount = [int]$shimType.GetField('DeviceCreateCount').GetValue($null)
Write-Host "  [+] Stock Vulkan initialized through IAT hook ($createdDevCount devices created with VK_KHR_external_semaphore_win32)." -ForegroundColor Green

# Locate Vulkan0 and Vulkan1 backend devices
$devCount = [uint64]$devCountFn.DynamicInvoke()
$selectedDevNames = @($DeviceSelection.Split('/'))
$matchedDevices = @{}

for ($d = [uint64]0; $d -lt $devCount; $d++) {
    $pDev = $devGetFn.DynamicInvoke($d)
    $name = [Runtime.InteropServices.Marshal]::PtrToStringUTF8($devNameFn.DynamicInvoke($pDev))
    $desc = [Runtime.InteropServices.Marshal]::PtrToStringUTF8($devDescFn.DynamicInvoke($pDev))
    
    foreach ($target in $selectedDevNames) {
        if ($name -eq $target) {
            $matchedDevices[$target] = [pscustomobject]@{ Dev = $pDev; Name = $name; Desc = $desc }
        }
    }
}

if ($matchedDevices.Count -ne 2) {
    throw "Failed to match both selected devices: $($selectedDevNames -join ', ')"
}

$dev0Obj = $matchedDevices[$selectedDevNames[0]]
$dev1Obj = $matchedDevices[$selectedDevNames[1]]
Write-Host "  [+] Producer Device: $($dev0Obj.Name) ($($dev0Obj.Desc))" -ForegroundColor Gray
Write-Host "  [+] Consumer Device: $($dev1Obj.Name) ($($dev1Obj.Desc))" -ForegroundColor Gray

# Import aperture arena into both backend devices
$buf0 = $bufFromHostFn.DynamicInvoke($dev0Obj.Dev, $apertureHost, [uint64]$ApertureBytes, [uint64]$ApertureBytes)
$buf1 = $bufFromHostFn.DynamicInvoke($dev1Obj.Dev, $apertureHost, [uint64]$ApertureBytes, [uint64]$ApertureBytes)
if ($buf0 -eq [IntPtr]::Zero -or $buf1 -eq [IntPtr]::Zero) {
    throw "Failed to import host aperture arena into backend devices."
}
Write-Host "  [+] Imported aperture buffer on Die 0: 0x$($buf0.ToString('X'))" -ForegroundColor Gray
Write-Host "  [+] Imported aperture buffer on Die 1: 0x$($buf1.ToString('X'))" -ForegroundColor Gray

$shimType.GetField('DestinationBuffer').SetValue($null, $buf1)

# Allocate SourceBridge tensor on Die 0 inside aperture
$bridgeTensor = Block 512
$length = [long]$ApertureBytes - 0x1000
W32 $bridgeTensor 0 24 # GGML_TYPE_I8
W64 $bridgeTensor 16 $length
W64 $bridgeTensor 24 1
W64 $bridgeTensor 32 1
W64 $bridgeTensor 40 1
W64 $bridgeTensor 48 1
W64 $bridgeTensor 56 $length
W64 $bridgeTensor 64 $length
W64 $bridgeTensor 72 $length
$allocStatus = [int]$tensorAllocFn.DynamicInvoke($buf0, $bridgeTensor, [IntPtr]::new(0x1000))
if ($allocStatus -ne 0) { throw "Bridge tensor allocation failed: status=$allocStatus" }
$shimType.GetField('SourceBridge').SetValue($null, $bridgeTensor)
Write-Host "  [+] Source bridge tensor allocated in aperture." -ForegroundColor Green

# -----------------------------------------------------------------------------
# Import D3D12 Fence into Native Vulkan Devices & Pre-allocate Submissions
# -----------------------------------------------------------------------------
$vkGetDeviceProcAddr = $interop.GetExportCall('C:\Windows\System32\vulkan-1.dll', 'vkGetDeviceProcAddr', [IntPtr], @([IntPtr], [string]))

# Function to get queues and import fence for a captured VkDevice
function Setup-DeviceBaton([IntPtr]$LogicalDev, [int]$QfIndex) {
    $fnCreateSem = $interop.GetCall($vkGetDeviceProcAddr.Invoke($LogicalDev, 'vkCreateSemaphore'), [int], @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
    $fnImportWin32 = $interop.GetCall($vkGetDeviceProcAddr.Invoke($LogicalDev, 'vkImportSemaphoreWin32HandleKHR'), [int], @([IntPtr], [IntPtr]))
    
    $sci = Block 24; W32 $sci 0 9 # VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
    $outSem = Block 8
    CheckVK ($fnCreateSem.Invoke($LogicalDev, $sci, [IntPtr]::Zero, $outSem)) 'vkCreateSemaphore'
    $sem = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($outSem)
    
    $impInfo = Block 48
    W32 $impInfo 0 1000078000 # VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_WIN32_HANDLE_INFO_KHR
    W64 $impInfo 16 $sem
    W32 $impInfo 24 0
    W32 $impInfo 28 8 # VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_D3D12_FENCE_BIT
    WP $impInfo 32 $sharedFenceHandle
    CheckVK ($fnImportWin32.Invoke($LogicalDev, $impInfo)) 'vkImportSemaphoreWin32HandleKHR'
    
    $outQ = Block 8
    $fnGetDevQueue = $interop.GetCall($pfnGetDeviceQueue, [void], @([IntPtr], [uint32], [uint32], [IntPtr]))
    $fnGetDevQueue.Invoke($LogicalDev, [uint32]$QfIndex, [uint32]0, $outQ)
    $queue = [Runtime.InteropServices.Marshal]::ReadIntPtr($outQ)
    
    return [pscustomobject]@{ Semaphore=$sem; Queue=$queue }
}

# In V340 stock ggml-vulkan, device pointers are at device struct
# For each backend, init_backend at device slot 0x28 returns ggml_backend_t
# Let's inspect init_backend on dev0 and dev1:
$initBackendDev0Ptr = [Runtime.InteropServices.Marshal]::ReadIntPtr([IntPtr]::Add($dev0Obj.Dev, 0x28))
$initBackendDev1Ptr = [Runtime.InteropServices.Marshal]::ReadIntPtr([IntPtr]::Add($dev1Obj.Dev, 0x28))

# Initialize backend 0 and 1 to obtain logical VkDevices and vtables
$initBackendFn = $interop.GetCall($initBackendDev0Ptr, [IntPtr], @([IntPtr], [IntPtr]))
$backend0 = $initBackendFn.Invoke($dev0Obj.Dev, [IntPtr]::Zero)
$backend1 = $initBackendFn.Invoke($dev1Obj.Dev, [IntPtr]::Zero)

if ($backend0 -eq [IntPtr]::Zero -or $backend1 -eq [IntPtr]::Zero) {
    throw 'Failed to construct backends for selected devices.'
}

# Retrieve created VkDevices directly from IAT hook capture
$vkDev0 = [IntPtr]$shimType.GetField('CreatedDevice0').GetValue($null)
$vkDev1 = [IntPtr]$shimType.GetField('CreatedDevice1').GetValue($null)
Write-Host "  [+] Die 0 VkDevice: 0x$($vkDev0.ToString('X'))" -ForegroundColor Gray
Write-Host "  [+] Die 1 VkDevice: 0x$($vkDev1.ToString('X'))" -ForegroundColor Gray

if ($vkDev0 -eq [IntPtr]::Zero -or $vkDev1 -eq [IntPtr]::Zero) {
    throw 'Failed to capture created VkDevices via IAT hook.'
}

# Set up baton on both devices using Compute Queue (QF 1)
$baton0 = Setup-DeviceBaton $vkDev0 1
$baton1 = Setup-DeviceBaton $vkDev1 1
Write-Host "  [+] Imported D3D12 fence semaphore on Die 0: 0x$($baton0.Semaphore.ToString('X')) (Queue: 0x$($baton0.Queue.ToString('X')))" -ForegroundColor Gray
Write-Host "  [+] Imported D3D12 fence semaphore on Die 1: 0x$($baton1.Semaphore.ToString('X')) (Queue: 0x$($baton1.Queue.ToString('X')))" -ForegroundColor Gray

$shimType.GetField('Dev0Queue').SetValue($null, $baton0.Queue)
$shimType.GetField('Dev1Queue').SetValue($null, $baton1.Queue)
$shimType.GetField('SourceBackend').SetValue($null, $backend0)
$shimType.GetField('DestinationBackend').SetValue($null, $backend1)

# Pre-allocate Submission structures for zero-allocation hot path
$sigFenceVal = Block 8; W64 $sigFenceVal 0 1
$sigD3D12Info = Block 48
W32 $sigD3D12Info 0 1000078002 # VK_STRUCTURE_TYPE_D3D12_FENCE_SUBMIT_INFO_KHR
W32 $sigD3D12Info 32 1         # signalSemaphoreValuesCount = 1
WP $sigD3D12Info 40 $sigFenceVal # pSignalSemaphoreValues

$pSigSem = Block 8; W64 $pSigSem 0 $baton0.Semaphore
$sigSub = Block 72
W32 $sigSub 0 4 # VK_STRUCTURE_TYPE_SUBMIT_INFO
WP $sigSub 8 $sigD3D12Info
W32 $sigSub 56 1 # signalSemaphoreCount = 1
WP $sigSub 64 $pSigSem

$waitFenceVal = Block 8; W64 $waitFenceVal 0 1
$waitD3D12Info = Block 48
W32 $waitD3D12Info 0 1000078002
W32 $waitD3D12Info 16 1          # waitSemaphoreValuesCount = 1
WP $waitD3D12Info 24 $waitFenceVal # pWaitSemaphoreValues

$pWaitSem = Block 8; W64 $pWaitSem 0 $baton1.Semaphore
$pWaitDst = Block 4; W32 $pWaitDst 0 0x20 # VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT
$waitSub = Block 72
W32 $waitSub 0 4
WP $waitSub 8 $waitD3D12Info
W32 $waitSub 16 1 # waitSemaphoreCount = 1
WP $waitSub 24 $pWaitSem
WP $waitSub 32 $pWaitDst

$shimType.GetField('SigSubmitInfo').SetValue($null, $sigSub)
$shimType.GetField('WaitSubmitInfo').SetValue($null, $waitSub)
$shimType.GetField('SigFenceValPtr').SetValue($null, $sigFenceVal)
$shimType.GetField('WaitFenceValPtr').SetValue($null, $waitFenceVal)

# Hook backend 1's cpy_tensor_async at offset 0x38 in iface
$cpySlot = [IntPtr]::Add($backend1, 0x38)
$pOrigCpy = [Runtime.InteropServices.Marshal]::ReadIntPtr($cpySlot)
if ($pOrigCpy -eq [IntPtr]::Zero) {
    $cpySlot = [IntPtr]::Add($backend1, 0x40)
    $pOrigCpy = [Runtime.InteropServices.Marshal]::ReadIntPtr($cpySlot)
}

$shimType.GetField('OriginalCpyTensorAsync').SetValue($null, $pOrigCpy)
[Runtime.InteropServices.Marshal]::WriteIntPtr($cpySlot, $pHookCpy)
Write-Host "  [+] Hooked cpy_tensor_async on Consumer Backend: 0x$($cpySlot.ToString('X')) -> 0x$($pHookCpy.ToString('X'))" -ForegroundColor Green

# Hook init_backend on device structures to intercept backend creation during llama_cli
$slotInit0 = [IntPtr]::Add($dev0Obj.Dev, 0x28)
$slotInit1 = [IntPtr]::Add($dev1Obj.Dev, 0x28)
$shimType.GetField('RealInitBackend0').SetValue($null, $initBackendDev0Ptr)
$shimType.GetField('RealInitBackend1').SetValue($null, $initBackendDev1Ptr)
[Runtime.InteropServices.Marshal]::WriteIntPtr($slotInit0, $pHookInit0)
[Runtime.InteropServices.Marshal]::WriteIntPtr($slotInit1, $pHookInit1)
Write-Host "  [+] Hooked init_backend on Device 0: 0x$($slotInit0.ToString('X')) -> 0x$($pHookInit0.ToString('X'))" -ForegroundColor Green
Write-Host "  [+] Hooked init_backend on Device 1: 0x$($slotInit1.ToString('X')) -> 0x$($pHookInit1.ToString('X'))" -ForegroundColor Green

# -----------------------------------------------------------------------------
foreach ($spec in @(
    @{Method='Hook_GraphAudit0'; Delegate='V340L.GraphAuditCallback'; Field='HookGraph0'},
    @{Method='Hook_GraphAudit1'; Delegate='V340L.GraphAuditCallback'; Field='HookGraph1'},
    @{Method='Hook_SyncAudit'; Delegate='V340L.SyncAuditCallback'; Field='HookSync'}
)) {
    $nativeDelegate = [Delegate]::CreateDelegate($shimAssembly.GetType($spec.Delegate), $shimType.GetMethod($spec.Method))
    $rootedDelegates.Add($nativeDelegate)
    $shimType.GetField($spec.Field).SetValue($null, [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($nativeDelegate))
}
$loadedModules = @([Diagnostics.Process]::GetCurrentProcess().Modules | Where-Object ModuleName -Match '^(ggml|llama|mtmd|libomp)' | ForEach-Object {
    if ((Split-Path $_.FileName) -ne $RuntimeDir) { throw "Unexpected loaded runtime path: $($_.FileName)" }
    [pscustomobject]@{Name=$_.ModuleName;Path=$_.FileName;SHA256=(Get-FileHash -LiteralPath $_.FileName).Hash}
})
$loadedModules | ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Split-Path $RuntimeDir) 'cli-entry-modules.json')
# 7. Execute Real Gemma Model Inference and Measure Receipts
# -----------------------------------------------------------------------------
Write-Host "[7/7] Launching deterministic inference on $Model..." -ForegroundColor Yellow

$llamaCliEntryPoint = $interop.GetCall(
    $interop.GetExport($llamaCliLib, '?llama_cli@@YAHHPEAPEAD@Z'),
    [int], @([int], [IntPtr]))

$cliDevices = $DeviceSelection.Replace('/', ',')
$cliTensorSplit = $TensorSplit.Replace('/', ',')

$programArgs = @(
    'llama-cli.exe', '-m', $Model,
    '-ngl', '999', '-dev', $cliDevices, '-sm', 'layer', '-ts', $cliTensorSplit,
    '-ncmoe', '0', '-ctk', 'q4_0', '-ctv', 'q4_0', '-fa', 'on', '--no-host',
    '-p', $Prompt, '-n', "$Tokens", '-s', '1234', '--temp', '0',
    '--no-display-prompt', '--simple-io', '--single-turn', '--no-warmup', '-c', '512'
)

$pointers = [Collections.Generic.List[IntPtr]]::new()
$vector = [IntPtr]::Zero

$swInference = [Diagnostics.Stopwatch]::StartNew()
try {
    foreach ($arg in $programArgs) {
        $pointers.Add([Runtime.InteropServices.Marshal]::StringToCoTaskMemUTF8($arg))
    }
    $vector = [Runtime.InteropServices.Marshal]::AllocHGlobal($pointers.Count * [IntPtr]::Size)
    for ($i = 0; $i -lt $pointers.Count; $i++) {
        [Runtime.InteropServices.Marshal]::WriteIntPtr($vector, $i * [IntPtr]::Size, $pointers[$i])
    }
    
    $exitCode = [int]$llamaCliEntryPoint.DynamicInvoke($pointers.Count, $vector)
} finally {
    $swInference.Stop()
    if ($vector -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($vector) }
    foreach ($p in $pointers) { [Runtime.InteropServices.Marshal]::FreeCoTaskMem($p) }
    if ($slotInit0 -ne [IntPtr]::Zero -and $initBackendDev0Ptr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::WriteIntPtr($slotInit0, $initBackendDev0Ptr)
    }
    if ($slotInit1 -ne [IntPtr]::Zero -and $initBackendDev1Ptr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::WriteIntPtr($slotInit1, $initBackendDev1Ptr)
    }
    if ($targetIatSlot -ne [IntPtr]::Zero -and $pfnRealGipa -ne [IntPtr]::Zero) {
        $oldP = Block 4
        $virtualProtect.Invoke($targetIatSlot, [uint64]8, [uint32]0x04, $oldP) | Out-Null
        [Runtime.InteropServices.Marshal]::WriteIntPtr($targetIatSlot, $pfnRealGipa)
        $virtualProtect.Invoke($targetIatSlot, [uint64]8, [uint32][Runtime.InteropServices.Marshal]::ReadInt32($oldP), $oldP) | Out-Null
    }
}

$handledHandoffs = [long]$shimType.GetField('HandledHandoffs').GetValue($null)
$fallbackHandoffs = [long]$shimType.GetField('FallbackHandoffs').GetValue($null)
$finalFenceVal = [uint64]$shimType.GetField('CurrentFenceValue').GetValue($null)
$finalCursor = [long]$shimType.GetField('ApertureCursor').GetValue($null)

# Verify terminal native fence value
$getNativeValue = $interop.GetComCall($nativeFence, 8, [uint64], @())
$nativeCompleted = $getNativeValue.DynamicInvoke($nativeFence)

$pass = ($exitCode -eq 0) -and ($handledHandoffs -gt 0) -and ($fallbackHandoffs -eq 0)

Write-Host "`n=== Benchmark & Execution Receipt ===" -ForegroundColor $(if ($pass) { 'Green' } else { 'Red' })
Write-Host "Status:                       $(if ($pass) { 'PASS' } else { 'FAIL' })"
Write-Host "Exit Code:                    $exitCode"
Write-Host "Handled Boundary Handoffs:    $handledHandoffs"
Write-Host "Fallback Blocking Handoffs:   $fallbackHandoffs (Expected: 0)"
Write-Host "Final Published Fence Value:  $finalFenceVal"
Write-Host "D3D12 Native Completed Value: $nativeCompleted"
Write-Host "Total Aperture Bytes Routed:  $($finalCursor - 0x1000) bytes"
Write-Host "Total Inference Wall Time:    $([math]::Round($swInference.Elapsed.TotalMilliseconds, 2)) ms"

$receipt = [ordered]@{
    Status = if ($pass) { 'PASS' } else { 'FAIL' }
    ExitCode = $exitCode
    Model = $Model
    Prompt = $Prompt
    TokensGenerated = $Tokens
    SelectedDevices = $DeviceSelection
    TensorSplit = $TensorSplit
    ProducerLUID = $dev0Dxgi.LUID
    ConsumerLUID = $dev1Dxgi.LUID
    HandledBoundaryHandoffs = $handledHandoffs
    FallbackBlockingHandoffs = $fallbackHandoffs
    FinalFenceValue = $finalFenceVal
    NativeFenceCompletedValue = $nativeCompleted
    TotalApertureBytesRouted = ($finalCursor - 0x1000)
    InferenceWallMilliseconds = [math]::Round($swInference.Elapsed.TotalMilliseconds, 3)
    StockVulkanSha256 = $actualVulkanHash
    ShimDllPath = $shimDllPath
    TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
}

$receiptDir = Split-Path $ReceiptPath
if (-not (Test-Path $receiptDir)) { New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null }
$receipt | ConvertTo-Json -Depth 4 | Set-Content -Path $ReceiptPath -Encoding UTF8
Write-Host "Receipt saved to: $ReceiptPath" -ForegroundColor Cyan

$env:PATH = $oldPath
if (-not $pass) {
    throw "Verification failed: ExitCode=$exitCode, Handled=$handledHandoffs, Fallback=$fallbackHandoffs"
}
