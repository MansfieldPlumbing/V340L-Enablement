<#
.SYNOPSIS
    Creates D3D12 and DirectML devices on every Radeon Pro V340 adapter from PowerShell.

.DESCRIPTION
    A no-build capability probe. It uses dynamic delegates and COM vtable calls from
    the current runspace; it does not compile code, change drivers, or modify binaries.
    The Quadro P2000 is enumerated for provenance but deliberately excluded from the
    DirectML inference device set.
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 65535)] [int] $M = 16,
    [ValidateRange(1, 65535)] [int] $K = 16,
    [ValidateRange(1, 65535)] [int] $N = 16
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([IntPtr]::Size -ne 8) { throw '64-bit PowerShell is required.' }

$interop = & (Join-Path $PSScriptRoot 'src\New-WindowsFunctionPointerBinder.ps1')
$factory = [IntPtr]::Zero
$adapters = [Collections.Generic.List[IntPtr]]::new()
$d3dDevices = [Collections.Generic.List[IntPtr]]::new()
$dmlDevices = [Collections.Generic.List[IntPtr]]::new()
$dmlOperators = [Collections.Generic.List[IntPtr]]::new()
$dmlCompiledOperators = [Collections.Generic.List[IntPtr]]::new()
$nativeBlocks = [Collections.Generic.List[IntPtr]]::new()

function New-NativeBlock([int] $Bytes) {
    $pointer = [Runtime.InteropServices.Marshal]::AllocHGlobal($Bytes)
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new($Bytes), 0, $pointer, $Bytes)
    $nativeBlocks.Add($pointer)
    return $pointer
}

function New-GuidPointer([Guid] $Guid) {
    $pointer = New-NativeBlock 16
    [Runtime.InteropServices.Marshal]::Copy($Guid.ToByteArray(), 0, $pointer, 16)
    return $pointer
}

function Format-HResult([int] $Value) {
    $unsigned = [BitConverter]::ToUInt32([BitConverter]::GetBytes($Value), 0)
    return '0x{0:X8}' -f $unsigned
}

function Write-Pointer([IntPtr] $Block, [int] $Offset, [IntPtr] $Value) {
    [Runtime.InteropServices.Marshal]::WriteIntPtr($Block, $Offset, $Value)
}

function Write-UInt32([IntPtr] $Block, [int] $Offset, [uint32] $Value) {
    [Runtime.InteropServices.Marshal]::WriteInt32($Block, $Offset, [int]$Value)
}

function Write-UInt64([IntPtr] $Block, [int] $Offset, [uint64] $Value) {
    [Runtime.InteropServices.Marshal]::WriteInt64($Block, $Offset, [long]$Value)
}

function Write-Float32([IntPtr] $Block, [int] $Offset, [float] $Value) {
    $bits = [BitConverter]::ToInt32([BitConverter]::GetBytes($Value), 0)
    [Runtime.InteropServices.Marshal]::WriteInt32($Block, $Offset, $bits)
}

function New-DmlBufferTensorDescription([uint32[]] $Sizes) {
    $sizesBlock = New-NativeBlock ($Sizes.Count * 4)
    for ($index = 0; $index -lt $Sizes.Count; $index++) {
        Write-UInt32 $sizesBlock ($index * 4) $Sizes[$index]
    }

    [uint64]$elements = 1
    foreach ($size in $Sizes) { $elements *= $size }

    # DML_BUFFER_TENSOR_DESC (x64): FLOAT16, contiguous strides, 16-byte base alignment.
    $bufferDescription = New-NativeBlock 48
    Write-UInt32 $bufferDescription 0 2 # DML_TENSOR_DATA_TYPE_FLOAT16
    Write-UInt32 $bufferDescription 4 0 # DML_TENSOR_FLAG_NONE
    Write-UInt32 $bufferDescription 8 $Sizes.Count
    Write-Pointer $bufferDescription 16 $sizesBlock
    Write-Pointer $bufferDescription 24 ([IntPtr]::Zero)
    Write-UInt64 $bufferDescription 32 ($elements * 2)
    Write-UInt32 $bufferDescription 40 16

    # DML_TENSOR_DESC
    $tensorDescription = New-NativeBlock 16
    Write-UInt32 $tensorDescription 0 1 # DML_TENSOR_TYPE_BUFFER
    Write-Pointer $tensorDescription 8 $bufferDescription
    return $tensorDescription
}

try {
    $createFactory = $interop.GetExportCall(
        'dxgi.dll', 'CreateDXGIFactory1', ([int]), @([IntPtr], [IntPtr]))
    $createD3D12Device = $interop.GetExportCall(
        'd3d12.dll', 'D3D12CreateDevice', ([int]), @([IntPtr], [int], [IntPtr], [IntPtr]))
    $createDmlDevice = $interop.GetExportCall(
        'DirectML.dll', 'DMLCreateDevice', ([int]), @([IntPtr], [uint32], [IntPtr], [IntPtr]))

    $iidFactory1 = New-GuidPointer ([Guid]'770aae78-f26f-4dba-a829-253c83d1b387')
    $iidD3D12Device = New-GuidPointer ([Guid]'189819f1-1db6-4b57-be54-1821339b85f7')
    $iidDmlDevice = New-GuidPointer ([Guid]'6dbd6437-96fd-423f-a98c-ae5e7c2a573f')
    $iidDmlOperator = New-GuidPointer ([Guid]'26caae7a-3081-4633-9581-226fbe57695d')
    $iidDmlCompiledOperator = New-GuidPointer ([Guid]'6b15e56a-bf5c-4902-92d8-da3a650afea4')

    $aTensorDescription = New-DmlBufferTensorDescription @([uint32]1, [uint32]1, [uint32]$M, [uint32]$K)
    $bTensorDescription = New-DmlBufferTensorDescription @([uint32]1, [uint32]1, [uint32]$K, [uint32]$N)
    $outputTensorDescription = New-DmlBufferTensorDescription @([uint32]1, [uint32]1, [uint32]$M, [uint32]$N)

    # DML_GEMM_OPERATOR_DESC
    $gemmDescription = New-NativeBlock 56
    Write-Pointer $gemmDescription 0 $aTensorDescription
    Write-Pointer $gemmDescription 8 $bTensorDescription
    Write-Pointer $gemmDescription 16 ([IntPtr]::Zero) # optional C tensor
    Write-Pointer $gemmDescription 24 $outputTensorDescription
    Write-UInt32 $gemmDescription 32 0 # DML_MATRIX_TRANSFORM_NONE
    Write-UInt32 $gemmDescription 36 0 # DML_MATRIX_TRANSFORM_NONE
    Write-Float32 $gemmDescription 40 1.0
    Write-Float32 $gemmDescription 44 0.0
    Write-Pointer $gemmDescription 48 ([IntPtr]::Zero)

    # DML_OPERATOR_DESC, DML_OPERATOR_GEMM == 54 in the installed SDK ABI.
    $operatorDescription = New-NativeBlock 16
    Write-UInt32 $operatorDescription 0 54
    Write-Pointer $operatorDescription 8 $gemmDescription
    $factoryOut = New-NativeBlock 8
    $hr = $createFactory.Invoke($iidFactory1, $factoryOut)
    if ($hr -lt 0) { throw "CreateDXGIFactory1 failed: $(Format-HResult $hr)" }
    $factory = [Runtime.InteropServices.Marshal]::ReadIntPtr($factoryOut)

    # IDXGIFactory1::EnumAdapters1 is vtable slot 12.
    $enumAdapters1 = $interop.GetComCall($factory, 12, ([int]), @([uint32], [IntPtr]))
    $rows = [Collections.Generic.List[object]]::new()
    $index = 0
    while ($true) {
        $adapterOut = New-NativeBlock 8
        $hr = $enumAdapters1.DynamicInvoke($factory, [uint32]$index, $adapterOut)
        $unsignedHr = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$hr), 0)
        if ($unsignedHr -eq 0x887A0002L) { break } # DXGI_ERROR_NOT_FOUND
        if ($hr -lt 0) { throw "EnumAdapters1($index) failed: $(Format-HResult $hr)" }
        $adapter = [Runtime.InteropServices.Marshal]::ReadIntPtr($adapterOut)
        $adapters.Add($adapter)

        # IDXGIAdapter1::GetDesc1 is vtable slot 10.
        $description = New-NativeBlock 312
        $getDesc1 = $interop.GetComCall($adapter, 10, ([int]), @([IntPtr]))
        $hr = $getDesc1.DynamicInvoke($adapter, $description)
        if ($hr -lt 0) { throw "IDXGIAdapter1::GetDesc1($index) failed: $(Format-HResult $hr)" }

        $name = [Runtime.InteropServices.Marshal]::PtrToStringUni($description, 128).TrimEnd([char]0)
        $vendorId = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($description, 256)
        $deviceId = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($description, 260)
        $dedicatedBytes = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($description, 272)
        $flags = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($description, 304)
        $isV340 = $vendorId -eq 0x1002 -and $deviceId -eq 0x6864 -and $name -match 'V340'

        $d3dStatus = 'SKIPPED'
        $dmlStatus = 'SKIPPED'
        $gemmStatus = 'SKIPPED'
        $descriptorCount = [uint32]0
        $temporaryBytes = [uint64]0
        $persistentBytes = [uint64]0
        if ($isV340) {
            $d3dOut = New-NativeBlock 8
            # D3D_FEATURE_LEVEL_11_0 is DirectML's minimum and is supported by Vega 10.
            $d3dHr = $createD3D12Device.Invoke($adapter, 0xB000, $iidD3D12Device, $d3dOut)
            $d3dStatus = Format-HResult $d3dHr
            if ($d3dHr -ge 0) {
                $d3dDevice = [Runtime.InteropServices.Marshal]::ReadIntPtr($d3dOut)
                $d3dDevices.Add($d3dDevice)

                $dmlOut = New-NativeBlock 8
                $dmlHr = $createDmlDevice.Invoke($d3dDevice, [uint32]0, $iidDmlDevice, $dmlOut)
                $dmlStatus = Format-HResult $dmlHr
                if ($dmlHr -ge 0) {
                    $dmlDevice = [Runtime.InteropServices.Marshal]::ReadIntPtr($dmlOut)
                    $dmlDevices.Add($dmlDevice)

                    # IDMLDevice::CreateOperator and CompileOperator are slots 8 and 9.
                    $createOperator = $interop.GetComCall(
                        $dmlDevice, 8, ([int]), @([IntPtr], [IntPtr], [IntPtr]))
                    $operatorOut = New-NativeBlock 8
                    $operatorHr = $createOperator.DynamicInvoke(
                        $dmlDevice, $operatorDescription, $iidDmlOperator, $operatorOut)
                    if ($operatorHr -ge 0) {
                        $dmlOperator = [Runtime.InteropServices.Marshal]::ReadIntPtr($operatorOut)
                        $dmlOperators.Add($dmlOperator)
                        $compileOperator = $interop.GetComCall(
                            $dmlDevice, 9, ([int]), @([IntPtr], [uint32], [IntPtr], [IntPtr]))
                        $compiledOut = New-NativeBlock 8
                        # Allow fp16 execution; do not set DISABLE_META_COMMANDS.
                        $compileHr = $compileOperator.DynamicInvoke(
                            $dmlDevice, $dmlOperator, [uint32]1, $iidDmlCompiledOperator, $compiledOut)
                        $gemmStatus = Format-HResult $compileHr
                        if ($compileHr -ge 0) {
                            $compiledOperator = [Runtime.InteropServices.Marshal]::ReadIntPtr($compiledOut)
                            $dmlCompiledOperators.Add($compiledOperator)

                            # The native MSVC call sequence for this 24-byte value return is:
                            # RCX=this, RDX=&result, RAX=&result. Express that lowered ABI
                            # directly; declaring a managed value return would put the hidden
                            # result pointer before `this` and corrupt the call.
                            $propertiesBlock = New-NativeBlock 24
                            $getBindingProperties = $interop.GetComCall(
                                $compiledOperator, 8, ([IntPtr]), @([IntPtr]))
                            $returnedBlock = $getBindingProperties.DynamicInvoke(
                                $compiledOperator, $propertiesBlock)
                            if ($returnedBlock -ne $propertiesBlock) {
                                throw 'IDMLDispatchable::GetBindingProperties returned an unexpected result pointer.'
                            }
                            $descriptorCount = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($propertiesBlock, 0)
                            $temporaryBytes = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($propertiesBlock, 8)
                            $persistentBytes = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($propertiesBlock, 16)
                        }
                    } else {
                        $gemmStatus = Format-HResult $operatorHr
                    }
                }
            }
        }

        $rows.Add([PSCustomObject]@{
            AdapterIndex = $index
            Description = $name
            VendorId = '0x{0:X4}' -f $vendorId
            DeviceId = '0x{0:X4}' -f $deviceId
            DedicatedGiB = [Math]::Round($dedicatedBytes / 1GB, 2)
            DxgiFlags = '0x{0:X8}' -f $flags
            SelectedForInference = $isV340
            D3D12CreateDevice = $d3dStatus
            DMLCreateDevice = $dmlStatus
            FP16GemmCompile = $gemmStatus
            RequiredDescriptors = $descriptorCount
            TemporaryBytes = $temporaryBytes
            PersistentBytes = $persistentBytes
        })
        $index++
    }

    $selected = @($rows | Where-Object SelectedForInference)
    $ready = @($selected | Where-Object {
        $_.D3D12CreateDevice -eq '0x00000000' -and
        $_.DMLCreateDevice -eq '0x00000000' -and
        $_.FP16GemmCompile -eq '0x00000000'
    })
    if ($selected.Count -ne 4) { throw "Expected four V340 adapters; selected $($selected.Count)." }
    if ($ready.Count -ne 4) { throw "DirectML device creation succeeded on $($ready.Count) of four V340 adapters." }

    $rows | Format-Table -AutoSize | Out-Host
    [PSCustomObject]@{
        Status = 'PASS'
        Mode = 'No-build PowerShell COM/vtable probe'
        EnumeratedAdapters = $rows.Count
        SelectedV340Adapters = $selected.Count
        DirectMLReadyV340Adapters = $ready.Count
        CompiledGemmShape = "[$M,$K] x [$K,$N]"
        BindingRequirements = @($ready | ForEach-Object {
            [PSCustomObject]@{
                AdapterIndex = $_.AdapterIndex
                RequiredDescriptors = $_.RequiredDescriptors
                TemporaryBytes = $_.TemporaryBytes
                PersistentBytes = $_.PersistentBytes
            }
        })
        MetaCommandsDisabled = $false
        P2000Excluded = (@($rows | Where-Object { $_.Description -match 'P2000' -and -not $_.SelectedForInference }).Count -eq 1)
    }
} finally {
    # Child interfaces before parents.
    for ($index = $dmlCompiledOperators.Count - 1; $index -ge 0; $index--) { [void]$interop.ReleaseCom($dmlCompiledOperators[$index]) }
    for ($index = $dmlOperators.Count - 1; $index -ge 0; $index--) { [void]$interop.ReleaseCom($dmlOperators[$index]) }
    for ($index = $dmlDevices.Count - 1; $index -ge 0; $index--) { [void]$interop.ReleaseCom($dmlDevices[$index]) }
    for ($index = $d3dDevices.Count - 1; $index -ge 0; $index--) { [void]$interop.ReleaseCom($d3dDevices[$index]) }
    for ($index = $adapters.Count - 1; $index -ge 0; $index--) { [void]$interop.ReleaseCom($adapters[$index]) }
    if ($factory -ne [IntPtr]::Zero) { [void]$interop.ReleaseCom($factory) }
    foreach ($pointer in $nativeBlocks) {
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($pointer) }
    }
    $interop.Dispose()
}
