<#
.SYNOPSIS
    Registers one in-memory ggml device for each V340L die discovered on the host.

.DESCRIPTION
    Emits the ggml backend-registry and device callbacks from PowerShell,
    constructs the native ggml_backend_reg and ggml_backend_device objects in
    unmanaged memory, calls the stock ggml_backend_register export, verifies
    that all four devices are discoverable through ggml's public registry, and
    unregisters them before freeing the emitted state.

    This proves the no-build registration seam that lets llama.cpp perform its
    existing layer split and tensor placement. It does not yet implement the
    buffer type, allocation, or graph execution interfaces required to load a
    model onto these registered devices.
#>

[CmdletBinding()]
param(
    [string] $LlamaBinDir = 'C:\bin\llama.cpp',
    [ValidateRange(1GB, 8GB)] [uint64] $ReportedFreeBytes = 7GB,
    [ValidateRange(1GB, 16GB)] [uint64] $ReportedTotalBytes = 8GB,
    [switch] $Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([IntPtr]::Size -ne 8) { throw '64-bit PowerShell is required.' }
if ($ReportedFreeBytes -gt $ReportedTotalBytes) {
    throw 'ReportedFreeBytes cannot exceed ReportedTotalBytes.'
}
$v340Adapters = @(Get-CimInstance Win32_VideoController | Where-Object {
    $_.Name -match 'Radeon Pro V340' -and $_.PNPDeviceID -match '^PCI\\VEN_1002&DEV_6864'
})
$deviceCount = $v340Adapters.Count
if ($deviceCount -lt 1) { throw 'No PCI Radeon Pro V340 dies were discovered through Win32_VideoController.' }

$interop = & (Join-Path $PSScriptRoot 'src\New-WindowsFunctionPointerBinder.ps1')
$blocks = [Collections.Generic.List[IntPtr]]::new()
$callbacks = [Collections.Generic.List[Delegate]]::new()
$registered = $false
$registration = [IntPtr]::Zero
$unload = $null

function New-Block([int] $Bytes) {
    $pointer = [Runtime.InteropServices.Marshal]::AllocHGlobal($Bytes)
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new($Bytes), 0, $pointer, $Bytes)
    $blocks.Add($pointer)
    $pointer
}

function New-Ansi([string] $Value) {
    $pointer = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($Value)
    $blocks.Add($pointer)
    $pointer
}

function New-Callback([Type] $ReturnType, [Type[]] $ParameterTypes, [scriptblock] $Body) {
    $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
        [Reflection.AssemblyName]::new('V340L.BackendCallback.' + [Guid]::NewGuid().ToString('N')),
        [Reflection.Emit.AssemblyBuilderAccess]::Run)
    $module = $assembly.DefineDynamicModule('Callback')
    $builder = $module.DefineType('NativeCallback', 'Public,Sealed', [MulticastDelegate])
    [void]$builder.DefineConstructor(
        'Public,HideBySig,RTSpecialName', [Reflection.CallingConventions]::Standard,
        @([object], [IntPtr])).SetImplementationFlags('Runtime,Managed')
    [void]$builder.DefineMethod(
        'Invoke', 'Public,HideBySig,NewSlot,Virtual', $ReturnType,
        $ParameterTypes).SetImplementationFlags('Runtime,Managed')
    [void]$builder.SetCustomAttribute([Reflection.Emit.CustomAttributeBuilder]::new(
        [Runtime.InteropServices.UnmanagedFunctionPointerAttribute].GetConstructor(
            @([Runtime.InteropServices.CallingConvention])),
        @([Runtime.InteropServices.CallingConvention]::StdCall)))
    $type = $builder.CreateType()
    # The callback runs while this script scope is alive, so preserve the body
    # scope. Closing it here would bind against New-Callback's local scope and
    # hide the registry/device arrays owned by the caller.
    $delegate = [Management.Automation.LanguagePrimitives]::ConvertTo($Body, $type)
    $callbacks.Add($delegate)
    [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($delegate)
}

try {
    $env:PATH = "$LlamaBinDir;$env:PATH"
    $registryLibrary = $interop.LoadLibrary((Join-Path $LlamaBinDir 'ggml.dll'))
    $baseLibrary = $interop.LoadLibrary((Join-Path $LlamaBinDir 'ggml-base.dll'))

    function Registry-Call([string] $Name, [Type] $ReturnType, [Type[]] $Parameters) {
        $interop.GetCall($interop.GetExport($registryLibrary, $Name), $ReturnType, $Parameters)
    }
    function Base-Call([string] $Name, [Type] $ReturnType, [Type[]] $Parameters) {
        $interop.GetCall($interop.GetExport($baseLibrary, $Name), $ReturnType, $Parameters)
    }

    $register = Registry-Call 'ggml_backend_register' ([void]) @([IntPtr])
    $unload = Registry-Call 'ggml_backend_unload' ([void]) @([IntPtr])
    $regByName = Registry-Call 'ggml_backend_reg_by_name' ([IntPtr]) @([IntPtr])
    $regCount = Registry-Call 'ggml_backend_reg_count' ([uint64]) @()
    $devCount = Registry-Call 'ggml_backend_dev_count' ([uint64]) @()
    $devGet = Registry-Call 'ggml_backend_dev_get' ([IntPtr]) @([uint64])
    $devName = Base-Call 'ggml_backend_dev_name' ([IntPtr]) @([IntPtr])
    $devDescription = Base-Call 'ggml_backend_dev_description' ([IntPtr]) @([IntPtr])
    $devMemory = Base-Call 'ggml_backend_dev_memory' ([void]) @([IntPtr], [IntPtr], [IntPtr])
    $devType = Base-Call 'ggml_backend_dev_type' ([int]) @([IntPtr])
    $devGetProps = Base-Call 'ggml_backend_dev_get_props' ([void]) @([IntPtr], [IntPtr])
    $devBufferType = Base-Call 'ggml_backend_dev_buffer_type' ([IntPtr]) @([IntPtr])
    $buftName = Base-Call 'ggml_backend_buft_name' ([IntPtr]) @([IntPtr])
    $buftGetDevice = Base-Call 'ggml_backend_buft_get_device' ([IntPtr]) @([IntPtr])
    $buftAllocBuffer = Base-Call 'ggml_backend_buft_alloc_buffer' ([IntPtr]) @([IntPtr], [uint64])
    $bufferInit = Base-Call 'ggml_backend_buffer_init' ([IntPtr]) @([IntPtr], [IntPtr], [IntPtr], [uint64])
    $bufferGetBase = Base-Call 'ggml_backend_buffer_get_base' ([IntPtr]) @([IntPtr])
    $bufferGetSize = Base-Call 'ggml_backend_buffer_get_size' ([uint64]) @([IntPtr])
    $bufferFree = Base-Call 'ggml_backend_buffer_free' ([void]) @([IntPtr])
    $memcpy = $interop.GetExportCall(
        'msvcrt.dll', 'memcpy', ([IntPtr]), @([IntPtr], [IntPtr], [uint64]))
    $memset = $interop.GetExportCall(
        'msvcrt.dll', 'memset', ([IntPtr]), @([IntPtr], [int], [uint64]))

    $backendName = New-Ansi 'V340L-DML'
    $deviceNames = [IntPtr[]]::new($deviceCount)
    $deviceDescriptions = [IntPtr[]]::new($deviceCount)
    $devices = [IntPtr[]]::new($deviceCount)
    $bufferTypeNames = [IntPtr[]]::new($deviceCount)
    $bufferTypes = [IntPtr[]]::new($deviceCount)
    $ordinals = [Collections.Generic.Dictionary[long, int]]::new()
    $bufferTypeOrdinals = [Collections.Generic.Dictionary[long, int]]::new()
    $liveHostAllocations = [hashtable]::Synchronized(@{})
    for ($ordinal = 0; $ordinal -lt $deviceCount; $ordinal++) {
        $deviceNames[$ordinal] = New-Ansi "V340L-DML$ordinal"
        $deviceDescriptions[$ordinal] = New-Ansi "Radeon Pro V340L DirectML die $ordinal"
        $bufferTypeNames[$ordinal] = New-Ansi "V340L-DML$ordinal-HOST-BUCKET"
        $devices[$ordinal] = New-Block 136
        $bufferTypes[$ordinal] = New-Block 64
        $ordinals[$devices[$ordinal].ToInt64()] = $ordinal
        $bufferTypeOrdinals[$bufferTypes[$ordinal].ToInt64()] = $ordinal
    }

    $regGetName = New-Callback ([IntPtr]) @([IntPtr]) {
        param([IntPtr] $Reg)
        $backendName
    }
    $regGetDeviceCount = New-Callback ([uint64]) @([IntPtr]) {
        param([IntPtr] $Reg)
        [uint64]$deviceCount
    }
    $regGetDevice = New-Callback ([IntPtr]) @([IntPtr], [uint64]) {
        param([IntPtr] $Reg, [uint64] $Index)
        if ($Index -ge $deviceCount) { return [IntPtr]::Zero }
        $devices[[int]$Index]
    }
    $regGetProcAddress = New-Callback ([IntPtr]) @([IntPtr], [IntPtr]) {
        param([IntPtr] $Reg, [IntPtr] $Name)
        [IntPtr]::Zero
    }

    $deviceGetName = New-Callback ([IntPtr]) @([IntPtr]) {
        param([IntPtr] $Device)
        $deviceNames[$ordinals[$Device.ToInt64()]]
    }
    $deviceGetDescription = New-Callback ([IntPtr]) @([IntPtr]) {
        param([IntPtr] $Device)
        $deviceDescriptions[$ordinals[$Device.ToInt64()]]
    }
    $deviceGetMemory = New-Callback ([void]) @([IntPtr], [IntPtr], [IntPtr]) {
        param([IntPtr] $Device, [IntPtr] $Free, [IntPtr] $Total)
        [Runtime.InteropServices.Marshal]::WriteInt64($Free, [long]$ReportedFreeBytes)
        [Runtime.InteropServices.Marshal]::WriteInt64($Total, [long]$ReportedTotalBytes)
    }
    $deviceGetType = New-Callback ([int]) @([IntPtr]) {
        param([IntPtr] $Device)
        1 # GGML_BACKEND_DEVICE_TYPE_GPU
    }
    $deviceGetProps = New-Callback ([void]) @([IntPtr], [IntPtr]) {
        param([IntPtr] $Device, [IntPtr] $Props)
        $ordinal = $ordinals[$Device.ToInt64()]
        [Runtime.InteropServices.Marshal]::WriteIntPtr($Props, 0, $deviceNames[$ordinal])
        [Runtime.InteropServices.Marshal]::WriteIntPtr($Props, 8, $deviceDescriptions[$ordinal])
        [Runtime.InteropServices.Marshal]::WriteInt64($Props, 16, [long]$ReportedFreeBytes)
        [Runtime.InteropServices.Marshal]::WriteInt64($Props, 24, [long]$ReportedTotalBytes)
        [Runtime.InteropServices.Marshal]::WriteInt32($Props, 32, 1)
        [Runtime.InteropServices.Marshal]::WriteIntPtr($Props, 40, [IntPtr]::Zero)
        # caps at +48: async, host_buffer, buffer_from_host_ptr, events,
        # mmap_support. This identity-only proof advertises none of them yet.
    }
    $deviceGetBufferType = New-Callback ([IntPtr]) @([IntPtr]) {
        param([IntPtr] $Device)
        $bufferTypes[$ordinals[$Device.ToInt64()]]
    }

    $bufferTypeGetName = New-Callback ([IntPtr]) @([IntPtr]) {
        param([IntPtr] $BufferType)
        $bufferTypeNames[$bufferTypeOrdinals[$BufferType.ToInt64()]]
    }
    $bufferTypeGetAlignment = New-Callback ([uint64]) @([IntPtr]) {
        param([IntPtr] $BufferType)
        [uint64]256
    }
    $bufferTypeGetMaxSize = New-Callback ([uint64]) @([IntPtr]) {
        param([IntPtr] $BufferType)
        $ReportedFreeBytes
    }
    $bufferTypeIsHost = New-Callback ([bool]) @([IntPtr]) {
        param([IntPtr] $BufferType)
        # The allocation is host-visible during fitting, but this is a GPU
        # placement bucket whose execution shadow is owned by its V340 die.
        $false
    }

    $bufferFreeCallback = New-Callback ([void]) @([IntPtr]) {
        param([IntPtr] $Buffer)
        $base = [Runtime.InteropServices.Marshal]::ReadIntPtr($Buffer, 96)
        if ($base -ne [IntPtr]::Zero) {
            $liveHostAllocations.Remove($base.ToInt64())
            [Runtime.InteropServices.Marshal]::FreeHGlobal($base)
            [Runtime.InteropServices.Marshal]::WriteIntPtr($Buffer, 96, [IntPtr]::Zero)
        }
    }
    $bufferGetBaseCallback = New-Callback ([IntPtr]) @([IntPtr]) {
        param([IntPtr] $Buffer)
        [Runtime.InteropServices.Marshal]::ReadIntPtr($Buffer, 96)
    }
    $bufferMemsetTensor = New-Callback ([void]) @([IntPtr], [IntPtr], [byte], [uint64], [uint64]) {
        param([IntPtr] $Buffer, [IntPtr] $Tensor, [byte] $Value, [uint64] $Offset, [uint64] $Size)
        $tensorData = [Runtime.InteropServices.Marshal]::ReadIntPtr($Tensor, 248)
        [void]$memset.DynamicInvoke(
            [IntPtr]::new($tensorData.ToInt64() + [long]$Offset), [int]$Value, $Size)
    }
    $bufferSetTensor = New-Callback ([void]) @([IntPtr], [IntPtr], [IntPtr], [uint64], [uint64]) {
        param([IntPtr] $Buffer, [IntPtr] $Tensor, [IntPtr] $Data, [uint64] $Offset, [uint64] $Size)
        $tensorData = [Runtime.InteropServices.Marshal]::ReadIntPtr($Tensor, 248)
        [void]$memcpy.DynamicInvoke(
            [IntPtr]::new($tensorData.ToInt64() + [long]$Offset), $Data, $Size)
    }
    $bufferGetTensor = New-Callback ([void]) @([IntPtr], [IntPtr], [IntPtr], [uint64], [uint64]) {
        param([IntPtr] $Buffer, [IntPtr] $Tensor, [IntPtr] $Data, [uint64] $Offset, [uint64] $Size)
        $tensorData = [Runtime.InteropServices.Marshal]::ReadIntPtr($Tensor, 248)
        [void]$memcpy.DynamicInvoke(
            $Data, [IntPtr]::new($tensorData.ToInt64() + [long]$Offset), $Size)
    }
    $bufferClear = New-Callback ([void]) @([IntPtr], [byte]) {
        param([IntPtr] $Buffer, [byte] $Value)
        $base = [Runtime.InteropServices.Marshal]::ReadIntPtr($Buffer, 96)
        $size = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($Buffer, 104)
        if ($size -gt 0) { [void]$memset.DynamicInvoke($base, [int]$Value, $size) }
    }

    # ggml_backend_buffer_i is passed by value to ggml_backend_buffer_init;
    # MSVC x64 lowers this 88-byte aggregate to the interface block pointer.
    $bufferInterface = New-Block 88
    [Runtime.InteropServices.Marshal]::WriteIntPtr($bufferInterface, 0, $bufferFreeCallback)
    [Runtime.InteropServices.Marshal]::WriteIntPtr($bufferInterface, 8, $bufferGetBaseCallback)
    [Runtime.InteropServices.Marshal]::WriteIntPtr($bufferInterface, 24, $bufferMemsetTensor)
    [Runtime.InteropServices.Marshal]::WriteIntPtr($bufferInterface, 32, $bufferSetTensor)
    [Runtime.InteropServices.Marshal]::WriteIntPtr($bufferInterface, 40, $bufferGetTensor)
    [Runtime.InteropServices.Marshal]::WriteIntPtr($bufferInterface, 72, $bufferClear)

    $bufferTypeAlloc = New-Callback ([IntPtr]) @([IntPtr], [uint64]) {
        param([IntPtr] $BufferType, [uint64] $Size)
        if ($Size -gt $ReportedFreeBytes -or $Size -gt [int64]::MaxValue) {
            return [IntPtr]::Zero
        }
        $hostPointer = [Runtime.InteropServices.Marshal]::AllocHGlobal([IntPtr]::new([long]$Size))
        if ($hostPointer -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
        try {
            if ($Size -gt 0) { [void]$memset.DynamicInvoke($hostPointer, 0, $Size) }
            $buffer = $bufferInit.DynamicInvoke(
                $BufferType, $bufferInterface, $hostPointer, $Size)
            if ($buffer -eq [IntPtr]::Zero) { throw 'ggml_backend_buffer_init returned null.' }
            $liveHostAllocations[$hostPointer.ToInt64()] = $Size
            return $buffer
        } catch {
            [Runtime.InteropServices.Marshal]::FreeHGlobal($hostPointer)
            return [IntPtr]::Zero
        }
    }

    # ggml_backend_reg: api_version + padding, four callback pointers, context.
    $registration = New-Block 48
    [Runtime.InteropServices.Marshal]::WriteInt32($registration, 0, 2)
    [Runtime.InteropServices.Marshal]::WriteIntPtr($registration, 8, $regGetName)
    [Runtime.InteropServices.Marshal]::WriteIntPtr($registration, 16, $regGetDeviceCount)
    [Runtime.InteropServices.Marshal]::WriteIntPtr($registration, 24, $regGetDevice)
    [Runtime.InteropServices.Marshal]::WriteIntPtr($registration, 32, $regGetProcAddress)

    # ggml_backend_device: 15 callback pointers, registration, context.
    foreach ($device in $devices) {
        [Runtime.InteropServices.Marshal]::WriteIntPtr($device, 0, $deviceGetName)
        [Runtime.InteropServices.Marshal]::WriteIntPtr($device, 8, $deviceGetDescription)
        [Runtime.InteropServices.Marshal]::WriteIntPtr($device, 16, $deviceGetMemory)
        [Runtime.InteropServices.Marshal]::WriteIntPtr($device, 24, $deviceGetType)
        [Runtime.InteropServices.Marshal]::WriteIntPtr($device, 32, $deviceGetProps)
        [Runtime.InteropServices.Marshal]::WriteIntPtr($device, 48, $deviceGetBufferType)
        [Runtime.InteropServices.Marshal]::WriteIntPtr($device, 120, $registration)
    }
    for ($ordinal = 0; $ordinal -lt $deviceCount; $ordinal++) {
        $bufferType = $bufferTypes[$ordinal]
        [Runtime.InteropServices.Marshal]::WriteIntPtr($bufferType, 0, $bufferTypeGetName)
        [Runtime.InteropServices.Marshal]::WriteIntPtr($bufferType, 8, $bufferTypeAlloc)
        [Runtime.InteropServices.Marshal]::WriteIntPtr($bufferType, 16, $bufferTypeGetAlignment)
        [Runtime.InteropServices.Marshal]::WriteIntPtr($bufferType, 24, $bufferTypeGetMaxSize)
        [Runtime.InteropServices.Marshal]::WriteIntPtr($bufferType, 40, $bufferTypeIsHost)
        [Runtime.InteropServices.Marshal]::WriteIntPtr($bufferType, 48, $devices[$ordinal])
    }

    $beforeRegCount = $regCount.DynamicInvoke()
    $beforeDeviceCount = $devCount.DynamicInvoke()
    [void]$register.DynamicInvoke($registration)
    $registered = $true

    $afterRegCount = $regCount.DynamicInvoke()
    $afterDeviceCount = $devCount.DynamicInvoke()
    if ($afterRegCount -ne ($beforeRegCount + 1)) {
        throw "Expected one new backend registration; count changed $beforeRegCount -> $afterRegCount."
    }
    if ($afterDeviceCount -ne ($beforeDeviceCount + $deviceCount)) {
        throw "Expected $deviceCount new devices; count changed $beforeDeviceCount -> $afterDeviceCount."
    }
    if ($regByName.DynamicInvoke($backendName) -ne $registration) {
        throw 'ggml_backend_reg_by_name did not return the emitted registration.'
    }

    $observed = [Collections.Generic.List[object]]::new()
    [uint64]$bucketProofBytes = 1MB
    for ($ordinal = 0; $ordinal -lt $deviceCount; $ordinal++) {
        $device = $devGet.DynamicInvoke([uint64]($beforeDeviceCount + $ordinal))
        if ($device -ne $devices[$ordinal]) { throw "Registry returned the wrong pointer for die $ordinal." }
        $freeOut = New-Block 8
        $totalOut = New-Block 8
        [void]$devMemory.DynamicInvoke($device, $freeOut, $totalOut)
        $props = New-Block 56
        [void]$devGetProps.DynamicInvoke($device, $props)
        $name = [Runtime.InteropServices.Marshal]::PtrToStringAnsi($devName.DynamicInvoke($device))
        $description = [Runtime.InteropServices.Marshal]::PtrToStringAnsi($devDescription.DynamicInvoke($device))
        $type = $devType.DynamicInvoke($device)
        if ($name -ne "V340L-DML$ordinal" -or $type -ne 1) {
            throw "Unexpected device identity for die ${ordinal}: name=$name type=$type."
        }
        if ([Runtime.InteropServices.Marshal]::ReadIntPtr($props, 0) -ne $deviceNames[$ordinal]) {
            throw "Device properties did not preserve the name pointer for die $ordinal."
        }
        $bufferType = $devBufferType.DynamicInvoke($device)
        if ($bufferType -ne $bufferTypes[$ordinal]) {
            throw "Device $ordinal returned the wrong buffer type."
        }
        if ($buftGetDevice.DynamicInvoke($bufferType) -ne $device) {
            throw "Buffer type $ordinal returned the wrong owning device."
        }
        $observedBufferName = [Runtime.InteropServices.Marshal]::PtrToStringAnsi(
            $buftName.DynamicInvoke($bufferType))
        if ($observedBufferName -ne "V340L-DML$ordinal-HOST-BUCKET") {
            throw "Unexpected buffer type name for die ${ordinal}: $observedBufferName."
        }
        $buffer = $buftAllocBuffer.DynamicInvoke($bufferType, $bucketProofBytes)
        if ($buffer -eq [IntPtr]::Zero) { throw "Host bucket allocation failed for die $ordinal." }
        try {
            if ($bufferGetSize.DynamicInvoke($buffer) -ne $bucketProofBytes) {
                throw "Host bucket size mismatch for die $ordinal."
            }
            $base = $bufferGetBase.DynamicInvoke($buffer)
            $pattern = [byte[]]@(0x56, 0x33, 0x34, [byte]$ordinal)
            [Runtime.InteropServices.Marshal]::Copy($pattern, 0, $base, $pattern.Length)
            $actualPattern = [byte[]]::new($pattern.Length)
            [Runtime.InteropServices.Marshal]::Copy($base, $actualPattern, 0, $actualPattern.Length)
            if (-not [Linq.Enumerable]::SequenceEqual[byte]($pattern, $actualPattern)) {
                throw "Host bucket byte verification failed for die $ordinal."
            }
        } finally {
            [void]$bufferFree.DynamicInvoke($buffer)
        }
        $observed.Add([PSCustomObject]@{
            Ordinal = $ordinal
            Name = $name
            Description = $description
            Type = 'GPU'
            BufferType = $observedBufferName
            HostBucketBytesVerified = $bucketProofBytes
            ReportedFreeBytes = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($freeOut)
            ReportedTotalBytes = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($totalOut)
        })
    }

    [void]$unload.DynamicInvoke($registration)
    $registered = $false
    $restoredRegCount = $regCount.DynamicInvoke()
    $restoredDeviceCount = $devCount.DynamicInvoke()
    if ($restoredRegCount -ne $beforeRegCount -or $restoredDeviceCount -ne $beforeDeviceCount) {
        throw 'ggml registry counts did not return to their original values.'
    }
    if ($liveHostAllocations.Count -ne 0) {
        throw "$($liveHostAllocations.Count) host bucket allocation(s) remained after buffer teardown."
    }

    $result = [PSCustomObject]@{
        Status = 'PASS'
        BackendName = 'V340L-DML'
        ApiVersion = 2
        RegisteredDevices = $observed.ToArray()
        DeviceCountAdded = $deviceCount
        RegistryRestored = $true
        BufferInterfaceImplemented = $true
        HostBucketBytesVerifiedPerDevice = $bucketProofBytes
        LiveHostAllocationsAfterTeardown = $liveHostAllocations.Count
        ModelPlacementExercised = $false
        CompilerUsed = 'None'
    }
    if ($Json) { $result | ConvertTo-Json -Depth 5 -Compress } else { $result }
}
finally {
    if ($registered -and $registration -ne [IntPtr]::Zero -and $null -ne $unload) {
        try { [void]$unload.DynamicInvoke($registration) } catch { }
    }
    $callbacks.Clear()
    for ($i = $blocks.Count - 1; $i -ge 0; $i--) {
        if ($blocks[$i] -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::FreeHGlobal($blocks[$i])
        }
    }
    $interop.Dispose()
}
