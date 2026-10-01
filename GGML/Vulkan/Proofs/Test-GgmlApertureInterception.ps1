<#
.SYNOPSIS
    No-build, in-runspace interception of ggml Vulkan cross-device tensor copies.

.DESCRIPTION
    Loads the stock ggml DLLs, imports one VirtualAlloc allocation into two Vulkan
    backends through ggml_backend_dev_buffer_from_host_ptr, replaces the destination
    backend's cpy_tensor_async function pointer in memory, and performs a real,
    byte-verified VRAM -> shared aperture -> VRAM tensor copy.

    Nothing is compiled and no DLL or executable is modified on disk.

.NOTES
    This script is intentionally pinned to the runtime-validated 64-bit ggml backend
    layout used by commit 4da633776. ggml_guid_t is a pointer, so ggml_backend_i
    begins at +0x08 and cpy_tensor_async is at +0x38. The script fails closed if the
    live object does not match that layout.
#>

[CmdletBinding()]
param(
    [string] $LlamaBinDir = 'C:\bin\llama.cpp',
    [int] $Bytes = 8192,
    [int] $ApertureBytes = 2MB,
    [int] $SourceDevice = -1,
    [int] $DestinationDevice = -1
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([IntPtr]::Size -ne 8) { throw '64-bit PowerShell is required.' }
if ($Bytes -le 0) { throw 'Bytes must be positive.' }
if ($ApertureBytes -lt $Bytes -or ($ApertureBytes % 4096) -ne 0) {
    throw 'ApertureBytes must cover the payload and be a multiple of 4096.'
}

$vkDll = Join-Path $LlamaBinDir 'ggml-vulkan.dll'
$baseDll = Join-Path $LlamaBinDir 'ggml-base.dll'
foreach ($path in @($vkDll, $baseDll)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing required DLL: $path" }
}

$env:PATH = "$LlamaBinDir;$env:PATH"

# Dynamic native-call binder. x64 Windows uses one native calling convention, but
# cdecl is retained here to document ggml's C ABI.
$assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
    [Reflection.AssemblyName]::new('V340L.GgmlAperture.' + [Guid]::NewGuid().ToString('N')),
    [Reflection.Emit.AssemblyBuilderAccess]::Run)
$module = $assembly.DefineDynamicModule('Interop')
$delegateTypes = [Collections.Generic.Dictionary[string, Type]]::new()

function Get-NativeDelegateType([Type] $ReturnType, [Type[]] $ParameterTypes) {
    $signature = $ReturnType.FullName + ':' + (($ParameterTypes | ForEach-Object FullName) -join ',')
    if (-not $delegateTypes.ContainsKey($signature)) {
        $builder = $module.DefineType(
            'NativeCall_' + [Guid]::NewGuid().ToString('N'),
            'Class,Public,Sealed',
            [MulticastDelegate])
        $builder.DefineConstructor(
            'Public,HideBySig,RTSpecialName',
            [Reflection.CallingConventions]::Standard,
            @([object], [IntPtr])).SetImplementationFlags('Runtime,Managed')
        $builder.DefineMethod(
            'Invoke',
            'Public,HideBySig,NewSlot,Virtual',
            $ReturnType,
            $ParameterTypes).SetImplementationFlags('Runtime,Managed')
        $builder.SetCustomAttribute([Reflection.Emit.CustomAttributeBuilder]::new(
            [Runtime.InteropServices.UnmanagedFunctionPointerAttribute].GetConstructor(
                @([Runtime.InteropServices.CallingConvention])),
            @([Runtime.InteropServices.CallingConvention]::Cdecl)))
        $delegateTypes[$signature] = $builder.CreateTypeInfo().AsType()
    }
    return $delegateTypes[$signature]
}

function Get-NativeCall([IntPtr] $Address, [Type] $ReturnType, [Type[]] $ParameterTypes) {
    if ($Address -eq [IntPtr]::Zero) { throw 'Cannot bind a null native function pointer.' }
    $type = Get-NativeDelegateType $ReturnType $ParameterTypes
    return [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($Address, $type)
}

function Get-ExportCall([IntPtr] $Library, [string] $Name, [Type] $ReturnType, [Type[]] $ParameterTypes) {
    $address = [Runtime.InteropServices.NativeLibrary]::GetExport($Library, $Name)
    return Get-NativeCall $address $ReturnType $ParameterTypes
}

function Format-Pointer([IntPtr] $Pointer) {
    return '0x{0:X16}' -f [uint64]$Pointer.ToInt64()
}

function New-I8Tensor([IntPtr] $Buffer, [long] $Length, $TensorAlloc, $NBytes) {
    # Exact ggml_tensor layout for the matched ABI. The allocation is deliberately
    # larger than the current 336-byte struct so future tail growth cannot overrun it.
    $tensor = [Runtime.InteropServices.Marshal]::AllocHGlobal(512)
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new(512), 0, $tensor, 512)

    # enum ggml_type::GGML_TYPE_I8
    [Runtime.InteropServices.Marshal]::WriteInt32($tensor, 0, 24)
    # ne[4]
    [Runtime.InteropServices.Marshal]::WriteInt64($tensor, 16, $Length)
    [Runtime.InteropServices.Marshal]::WriteInt64($tensor, 24, 1)
    [Runtime.InteropServices.Marshal]::WriteInt64($tensor, 32, 1)
    [Runtime.InteropServices.Marshal]::WriteInt64($tensor, 40, 1)
    # nb[4]
    [Runtime.InteropServices.Marshal]::WriteInt64($tensor, 48, 1)
    [Runtime.InteropServices.Marshal]::WriteInt64($tensor, 56, $Length)
    [Runtime.InteropServices.Marshal]::WriteInt64($tensor, 64, $Length)
    [Runtime.InteropServices.Marshal]::WriteInt64($tensor, 72, $Length)

    $status = $TensorAlloc.Invoke($Buffer, $tensor, [IntPtr]0x1000)
    if ($status -ne 0) {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($tensor)
        throw "ggml_backend_tensor_alloc failed with status $status"
    }
    $reported = [uint64]$NBytes.Invoke($tensor)
    if ($reported -ne [uint64]$Length) {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($tensor)
        throw "Synthetic tensor ABI validation failed: expected $Length bytes, ggml reported $reported."
    }
    return $tensor
}

function New-ApertureCallback(
    [IntPtr] $ExpectedSource,
    [IntPtr] $ExpectedDestination,
    [IntPtr] $SourceBridgeTensor,
    [IntPtr] $DestinationBridgeTensor,
    [uint64] $ExpectedBytes,
    [Delegate] $NBytes,
    [Delegate] $Synchronize,
    [Delegate] $BufferCopy
) {
    $callbackType = Get-NativeDelegateType ([bool]) @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
    $nBytesType = $NBytes.GetType()
    $syncType = $Synchronize.GetType()
    $copyType = $BufferCopy.GetType()

    $builder = $module.DefineType(
        'ApertureBridge_' + [Guid]::NewGuid().ToString('N'),
        'Class,Public,Abstract,Sealed')
    $flags = [Reflection.FieldAttributes]'Public,Static'
    $sourceField = $builder.DefineField('ExpectedSource', [IntPtr], $flags)
    $destinationField = $builder.DefineField('ExpectedDestination', [IntPtr], $flags)
    $sourceTensorField = $builder.DefineField('SourceBridgeTensor', [IntPtr], $flags)
    $destinationTensorField = $builder.DefineField('DestinationBridgeTensor', [IntPtr], $flags)
    $bytesField = $builder.DefineField('ExpectedBytes', [uint64], $flags)
    $nBytesField = $builder.DefineField('NBytes', $nBytesType, $flags)
    $syncField = $builder.DefineField('Synchronize', $syncType, $flags)
    $copyField = $builder.DefineField('BufferCopy', $copyType, $flags)
    $handledField = $builder.DefineField('HandledCount', [long], $flags)
    $fallbackField = $builder.DefineField('FallbackCount', [long], $flags)

    $method = $builder.DefineMethod(
        'CopyTensorAsync',
        'Public,Static',
        [bool],
        @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
    $il = $method.GetILGenerator()
    $incrementInt64 = [Threading.Interlocked].GetMethods() |
        Where-Object {
            $_.Name -eq 'Increment' -and
            -not $_.IsGenericMethod -and
            $_.ReturnType -eq [long] -and
            $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType -eq [long].MakeByRefType()
        } |
        Select-Object -First 1
    if ($null -eq $incrementInt64) { throw 'Could not resolve Interlocked.Increment(ref Int64).' }
    $fallback = $il.DefineLabel()
    $legOneFailed = $il.DefineLabel()

    # Only claim the exact selected direction and real tensors.
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $sourceField)
    $il.Emit([Reflection.Emit.OpCodes]::Bne_Un, $fallback)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $destinationField)
    $il.Emit([Reflection.Emit.OpCodes]::Bne_Un, $fallback)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Brfalse, $fallback)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
    $il.Emit([Reflection.Emit.OpCodes]::Brfalse, $fallback)

    # Require the preallocated activation size. Other tensor sizes use stock fallback.
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $nBytesField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Callvirt, $nBytesType.GetMethod('Invoke'))
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $bytesField)
    $il.Emit([Reflection.Emit.OpCodes]::Bne_Un, $fallback)

    # Cross-device ordering is made explicit for this correctness milestone.
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $syncField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
    $il.Emit([Reflection.Emit.OpCodes]::Callvirt, $syncType.GetMethod('Invoke'))
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $syncField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
    $il.Emit([Reflection.Emit.OpCodes]::Callvirt, $syncType.GetMethod('Invoke'))

    # Leg 1: source VRAM -> source device's view of shared host aperture.
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $copyField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $sourceTensorField)
    $il.Emit([Reflection.Emit.OpCodes]::Callvirt, $copyType.GetMethod('Invoke'))
    $il.Emit([Reflection.Emit.OpCodes]::Brfalse, $legOneFailed)

    # Leg 2: destination device's view of the same allocation -> destination VRAM.
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $copyField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $destinationTensorField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
    $il.Emit([Reflection.Emit.OpCodes]::Callvirt, $copyType.GetMethod('Invoke'))
    $il.Emit([Reflection.Emit.OpCodes]::Brfalse, $legOneFailed)

    $il.Emit([Reflection.Emit.OpCodes]::Ldsflda, $handledField)
    $il.Emit([Reflection.Emit.OpCodes]::Call, $incrementInt64)
    $il.Emit([Reflection.Emit.OpCodes]::Pop)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
    $il.Emit([Reflection.Emit.OpCodes]::Ret)

    $il.MarkLabel($legOneFailed)
    $il.MarkLabel($fallback)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsflda, $fallbackField)
    $il.Emit([Reflection.Emit.OpCodes]::Call, $incrementInt64)
    $il.Emit([Reflection.Emit.OpCodes]::Pop)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
    $il.Emit([Reflection.Emit.OpCodes]::Ret)

    $type = $builder.CreateTypeInfo().AsType()
    $type.GetField('ExpectedSource').SetValue($null, $ExpectedSource)
    $type.GetField('ExpectedDestination').SetValue($null, $ExpectedDestination)
    $type.GetField('SourceBridgeTensor').SetValue($null, $SourceBridgeTensor)
    $type.GetField('DestinationBridgeTensor').SetValue($null, $DestinationBridgeTensor)
    $type.GetField('ExpectedBytes').SetValue($null, $ExpectedBytes)
    $type.GetField('NBytes').SetValue($null, $NBytes)
    $type.GetField('Synchronize').SetValue($null, $Synchronize)
    $type.GetField('BufferCopy').SetValue($null, $BufferCopy)

    $delegate = [Delegate]::CreateDelegate($callbackType, $type.GetMethod('CopyTensorAsync'))
    return [PSCustomObject]@{ Delegate = $delegate; Type = $type }
}

$hBase = [IntPtr]::Zero
$hVulkan = [IntPtr]::Zero
$hKernel = [IntPtr]::Zero
$backends = [Collections.Generic.List[IntPtr]]::new()
$buffers = [Collections.Generic.List[IntPtr]]::new()
$tensors = [Collections.Generic.List[IntPtr]]::new()
$aperture = [IntPtr]::Zero
$copySlot = [IntPtr]::Zero
$originalCopy = [IntPtr]::Zero
$callback = $null
$synchronize = $null
$freeBuffer = $null
$freeBackend = $null
$virtualFree = $null

try {
    # Load the base library first so the stock Vulkan sidecar resolves against it.
    $hBase = [Runtime.InteropServices.NativeLibrary]::Load($baseDll)
    $hVulkan = [Runtime.InteropServices.NativeLibrary]::Load($vkDll)
    $hKernel = [Runtime.InteropServices.NativeLibrary]::Load('kernel32.dll')
    $hCrt = [Runtime.InteropServices.NativeLibrary]::Load('msvcrt.dll')

    $deviceCount = Get-ExportCall $hVulkan 'ggml_backend_vk_get_device_count' ([int]) @()
    $deviceDescription = Get-ExportCall $hVulkan 'ggml_backend_vk_get_device_description' ([void]) @([int], [IntPtr], [uint64])
    $vkInit = Get-ExportCall $hVulkan 'ggml_backend_vk_init' ([IntPtr]) @([uint64])

    $backendName = Get-ExportCall $hBase 'ggml_backend_name' ([IntPtr]) @([IntPtr])
    $backendGuid = Get-ExportCall $hBase 'ggml_backend_guid' ([IntPtr]) @([IntPtr])
    $backendDevice = Get-ExportCall $hBase 'ggml_backend_get_device' ([IntPtr]) @([IntPtr])
    $bufferFromHost = Get-ExportCall $hBase 'ggml_backend_dev_buffer_from_host_ptr' ([IntPtr]) @([IntPtr], [IntPtr], [uint64], [uint64])
    $allocBuffer = Get-ExportCall $hBase 'ggml_backend_alloc_buffer' ([IntPtr]) @([IntPtr], [uint64])
    $freeBuffer = Get-ExportCall $hBase 'ggml_backend_buffer_free' ([void]) @([IntPtr])
    $freeBackend = Get-ExportCall $hBase 'ggml_backend_free' ([void]) @([IntPtr])
    $tensorAlloc = Get-ExportCall $hBase 'ggml_backend_tensor_alloc' ([int]) @([IntPtr], [IntPtr], [IntPtr])
    $tensorSet = Get-ExportCall $hBase 'ggml_backend_tensor_set' ([void]) @([IntPtr], [IntPtr], [uint64], [uint64])
    $tensorGet = Get-ExportCall $hBase 'ggml_backend_tensor_get' ([void]) @([IntPtr], [IntPtr], [uint64], [uint64])
    $tensorCopyAsync = Get-ExportCall $hBase 'ggml_backend_tensor_copy_async' ([void]) @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
    $synchronize = Get-ExportCall $hBase 'ggml_backend_synchronize' ([void]) @([IntPtr])
    $bufferCopy = Get-ExportCall $hBase 'ggml_backend_buffer_copy_tensor' ([bool]) @([IntPtr], [IntPtr])
    $nBytes = Get-ExportCall $hBase 'ggml_nbytes' ([uint64]) @([IntPtr])
    $virtualAlloc = Get-ExportCall $hKernel 'VirtualAlloc' ([IntPtr]) @([IntPtr], [uint64], [uint32], [uint32])
    $virtualFree = Get-ExportCall $hKernel 'VirtualFree' ([bool]) @([IntPtr], [uint64], [uint32])
    $memcmp = Get-ExportCall $hCrt 'memcmp' ([int]) @([IntPtr], [IntPtr], [uint64])

    $descriptions = @()
    $v340Indices = [Collections.Generic.List[int]]::new()
    for ($index = 0; $index -lt $deviceCount.Invoke(); $index++) {
        $descriptionBuffer = [Runtime.InteropServices.Marshal]::AllocHGlobal(512)
        try {
            [Runtime.InteropServices.Marshal]::Copy([byte[]]::new(512), 0, $descriptionBuffer, 512)
            $deviceDescription.Invoke($index, $descriptionBuffer, [uint64]512)
            $description = [Runtime.InteropServices.Marshal]::PtrToStringUTF8($descriptionBuffer)
        } finally {
            [Runtime.InteropServices.Marshal]::FreeHGlobal($descriptionBuffer)
        }
        $descriptions += [PSCustomObject]@{ Index = $index; Description = $description }
        if ($description -match 'V340') { $v340Indices.Add($index) }
    }

    Write-Host '[+] Stock Vulkan devices' -ForegroundColor Cyan
    $descriptions | Format-Table -AutoSize | Out-Host
    if ($v340Indices.Count -lt 2) { throw "Need at least two V340 Vulkan devices; found $($v340Indices.Count)." }
    if ($SourceDevice -lt 0) { $SourceDevice = $v340Indices[0] }
    if ($DestinationDevice -lt 0) { $DestinationDevice = $v340Indices[1] }
    if ($SourceDevice -eq $DestinationDevice) { throw 'SourceDevice and DestinationDevice must differ.' }
    if (-not $v340Indices.Contains($SourceDevice) -or -not $v340Indices.Contains($DestinationDevice)) {
        throw 'Both selected devices must be V340 dies. The P2000 is deliberately excluded.'
    }

    $sourceBackend = $vkInit.Invoke([uint64]$SourceDevice)
    $destinationBackend = $vkInit.Invoke([uint64]$DestinationDevice)
    if ($sourceBackend -eq [IntPtr]::Zero -or $destinationBackend -eq [IntPtr]::Zero) {
        throw 'ggml_backend_vk_init returned null.'
    }
    $backends.Add($sourceBackend)
    $backends.Add($destinationBackend)

    # Runtime ABI proof. ggml_guid_t is a pointer at +0x00; iface.get_name is +0x08.
    foreach ($backend in @($sourceBackend, $destinationBackend)) {
        $guidFromApi = $backendGuid.Invoke($backend)
        $guidInObject = [Runtime.InteropServices.Marshal]::ReadIntPtr($backend, 0)
        if ($guidFromApi -ne $guidInObject -or $guidFromApi -eq [IntPtr]::Zero) {
            throw 'ggml_backend GUID pointer layout mismatch; refusing to mutate.'
        }
        $nameFromApiPointer = $backendName.Invoke($backend)
        $getNamePointer = [Runtime.InteropServices.Marshal]::ReadIntPtr($backend, 8)
        $getName = Get-NativeCall $getNamePointer ([IntPtr]) @([IntPtr])
        $nameFromSlotPointer = $getName.Invoke($backend)
        $nameFromApi = [Runtime.InteropServices.Marshal]::PtrToStringUTF8($nameFromApiPointer)
        $nameFromSlot = [Runtime.InteropServices.Marshal]::PtrToStringUTF8($nameFromSlotPointer)
        if ($nameFromApi -ne $nameFromSlot -or $nameFromApi -notmatch '^Vulkan') {
            throw 'ggml_backend interface layout mismatch; refusing to mutate.'
        }
    }
    Write-Host '[+] Runtime ABI validated : iface +0x08, cpy_tensor_async +0x38' -ForegroundColor Green

    $aperture = $virtualAlloc.Invoke([IntPtr]::Zero, [uint64]$ApertureBytes, [uint32]0x3000, [uint32]4)
    if ($aperture -eq [IntPtr]::Zero) { throw 'VirtualAlloc failed.' }

    $sourceDeviceHandle = $backendDevice.Invoke($sourceBackend)
    $destinationDeviceHandle = $backendDevice.Invoke($destinationBackend)
    $sourceBridgeBuffer = $bufferFromHost.Invoke($sourceDeviceHandle, $aperture, [uint64]$ApertureBytes, [uint64]$Bytes)
    $destinationBridgeBuffer = $bufferFromHost.Invoke($destinationDeviceHandle, $aperture, [uint64]$ApertureBytes, [uint64]$Bytes)
    if ($sourceBridgeBuffer -eq [IntPtr]::Zero -or $destinationBridgeBuffer -eq [IntPtr]::Zero) {
        throw 'Stock Vulkan backend could not import the shared host allocation.'
    }
    $buffers.Add($sourceBridgeBuffer)
    $buffers.Add($destinationBridgeBuffer)

    $sourceVramBuffer = $allocBuffer.Invoke($sourceBackend, [uint64]$Bytes)
    $destinationVramBuffer = $allocBuffer.Invoke($destinationBackend, [uint64]$Bytes)
    if ($sourceVramBuffer -eq [IntPtr]::Zero -or $destinationVramBuffer -eq [IntPtr]::Zero) {
        throw 'Could not allocate Vulkan device buffers.'
    }
    $buffers.Add($sourceVramBuffer)
    $buffers.Add($destinationVramBuffer)

    $sourceTensor = New-I8Tensor $sourceVramBuffer $Bytes $tensorAlloc $nBytes
    $destinationTensor = New-I8Tensor $destinationVramBuffer $Bytes $tensorAlloc $nBytes
    $sourceBridgeTensor = New-I8Tensor $sourceBridgeBuffer $Bytes $tensorAlloc $nBytes
    $destinationBridgeTensor = New-I8Tensor $destinationBridgeBuffer $Bytes $tensorAlloc $nBytes
    foreach ($tensor in @($sourceTensor, $destinationTensor, $sourceBridgeTensor, $destinationBridgeTensor)) { $tensors.Add($tensor) }

    $input = [byte[]]::new($Bytes)
    for ($index = 0; $index -lt $input.Length; $index++) {
        $input[$index] = [byte](($index * 131 + 17) -band 0xFF)
    }
    $zero = [byte[]]::new($Bytes)
    $inputHandle = [Runtime.InteropServices.GCHandle]::Alloc($input, [Runtime.InteropServices.GCHandleType]::Pinned)
    $zeroHandle = [Runtime.InteropServices.GCHandle]::Alloc($zero, [Runtime.InteropServices.GCHandleType]::Pinned)
    try {
        $tensorSet.Invoke($sourceTensor, $inputHandle.AddrOfPinnedObject(), [uint64]0, [uint64]$Bytes)
        $tensorSet.Invoke($destinationTensor, $zeroHandle.AddrOfPinnedObject(), [uint64]0, [uint64]$Bytes)
    } finally {
        $inputHandle.Free()
        $zeroHandle.Free()
    }

    $copySlot = [IntPtr]::new($destinationBackend.ToInt64() + 0x38)
    $originalCopy = [Runtime.InteropServices.Marshal]::ReadIntPtr($copySlot)
    if ($originalCopy -eq [IntPtr]::Zero) { throw 'cpy_tensor_async slot is null.' }

    $callback = New-ApertureCallback `
        $sourceBackend $destinationBackend `
        $sourceBridgeTensor $destinationBridgeTensor `
        ([uint64]$Bytes) $nBytes $synchronize $bufferCopy
    $replacementPointer = [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($callback.Delegate)
    [Runtime.InteropServices.Marshal]::WriteIntPtr($copySlot, $replacementPointer)
    if ([Runtime.InteropServices.Marshal]::ReadIntPtr($copySlot) -ne $replacementPointer) {
        throw 'Function pointer installation did not stick.'
    }

    Write-Host "[+] Interception installed : $(Format-Pointer $originalCopy) -> $(Format-Pointer $replacementPointer)" -ForegroundColor Green
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $tensorCopyAsync.Invoke($sourceBackend, $destinationBackend, $sourceTensor, $destinationTensor)
    $synchronize.Invoke($destinationBackend)
    $stopwatch.Stop()

    $output = [byte[]]::new($Bytes)
    $outputHandle = [Runtime.InteropServices.GCHandle]::Alloc($output, [Runtime.InteropServices.GCHandleType]::Pinned)
    try {
        $tensorGet.Invoke($destinationTensor, $outputHandle.AddrOfPinnedObject(), [uint64]0, [uint64]$Bytes)
    } finally {
        $outputHandle.Free()
    }
    $apertureSnapshot = [byte[]]::new($Bytes)
    [Runtime.InteropServices.Marshal]::Copy($aperture, $apertureSnapshot, 0, $Bytes)

    $verifyInputHandle = [Runtime.InteropServices.GCHandle]::Alloc($input, [Runtime.InteropServices.GCHandleType]::Pinned)
    $verifyOutputHandle = [Runtime.InteropServices.GCHandle]::Alloc($output, [Runtime.InteropServices.GCHandleType]::Pinned)
    $verifyApertureHandle = [Runtime.InteropServices.GCHandle]::Alloc($apertureSnapshot, [Runtime.InteropServices.GCHandleType]::Pinned)
    try {
        $destinationMatches = $memcmp.Invoke(
            $verifyInputHandle.AddrOfPinnedObject(),
            $verifyOutputHandle.AddrOfPinnedObject(),
            [uint64]$Bytes) -eq 0
        $apertureMatches = $memcmp.Invoke(
            $verifyInputHandle.AddrOfPinnedObject(),
            $verifyApertureHandle.AddrOfPinnedObject(),
            [uint64]$Bytes) -eq 0
    } finally {
        $verifyInputHandle.Free()
        $verifyOutputHandle.Free()
        $verifyApertureHandle.Free()
    }
    $handledCount = [long]$callback.Type.GetField('HandledCount').GetValue($null)
    $fallbackCount = [long]$callback.Type.GetField('FallbackCount').GetValue($null)
    if (-not $destinationMatches -or -not $apertureMatches -or $handledCount -ne 1) {
        throw "Copy verification failed: destination=$destinationMatches aperture=$apertureMatches handled=$handledCount fallback=$fallbackCount"
    }

    [PSCustomObject]@{
        Status = 'PASS'
        Mode = 'No-build in-runspace ggml callback mutation'
        Bytes = $Bytes
        ApertureBytes = $ApertureBytes
        SourceDevice = $SourceDevice
        DestinationDevice = $DestinationDevice
        SourceDescription = ($descriptions | Where-Object Index -eq $SourceDevice).Description
        DestinationDescription = ($descriptions | Where-Object Index -eq $DestinationDevice).Description
        ApertureAddress = Format-Pointer $aperture
        CallbackSlotOffset = '0x38'
        OriginalCallback = Format-Pointer $originalCopy
        ReplacementCallback = Format-Pointer $replacementPointer
        CallbackHandled = $handledCount
        CallbackFallback = $fallbackCount
        DestinationByteMatch = $destinationMatches
        ApertureByteMatch = $apertureMatches
        ElapsedMicroseconds = [Math]::Round($stopwatch.Elapsed.TotalMicroseconds, 1)
    }
} finally {
    # Restore first so no callback can observe torn-down bridge state.
    if ($copySlot -ne [IntPtr]::Zero -and $originalCopy -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::WriteIntPtr($copySlot, $originalCopy)
    }
    foreach ($backend in $backends) {
        try { if ($null -ne $synchronize) { $synchronize.Invoke($backend) } } catch { }
    }
    foreach ($tensor in $tensors) {
        if ($tensor -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($tensor) }
    }
    foreach ($buffer in $buffers) {
        try { if ($buffer -ne [IntPtr]::Zero -and $null -ne $freeBuffer) { $freeBuffer.Invoke($buffer) } } catch { }
    }
    foreach ($backend in $backends) {
        try { if ($backend -ne [IntPtr]::Zero -and $null -ne $freeBackend) { $freeBackend.Invoke($backend) } } catch { }
    }
    if ($aperture -ne [IntPtr]::Zero -and $null -ne $virtualFree) {
        [void]$virtualFree.Invoke($aperture, [uint64]0, [uint32]0x8000)
    }
}
