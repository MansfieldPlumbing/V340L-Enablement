<#
.SYNOPSIS
    Dispatches and verifies an FP16 DirectML GEMM on Radeon Pro V340 dies.

.DESCRIPTION
    Pure PowerShell/Reflection.Emit implementation of the D3D12 and DirectML
    COM path. No helper binary is compiled or loaded. The Quadro P2000 is
    enumerated but never selected for compute.

    Inputs are deterministic FP16 matrices staged through upload buffers into
    default-heap unordered-access buffers. DirectML writes an unordered-access
    output buffer, which is copied to a readback heap and compared
    element-by-element with a CPU reference.
#>

[CmdletBinding()]
param(
    [ValidateRange(-1, 3)] [int] $V340Ordinal = -1,
    [ValidateRange(1, 4096)] [int] $M = 4,
    [ValidateRange(1, 4096)] [int] $K = 4,
    [ValidateRange(1, 4096)] [int] $N = 4,
    [ValidateRange(0.0001, 10.0)] [double] $Tolerance = 0.05,
    [float[]] $AValues,
    [float[]] $BValues,
    [switch] $IncludeOutput,
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([IntPtr]::Size -ne 8) { throw '64-bit PowerShell is required.' }
if (($null -eq $AValues) -xor ($null -eq $BValues)) {
    throw 'AValues and BValues must be supplied together.'
}
if ($null -ne $AValues -and $AValues.Count -ne ($M * $K)) {
    throw "AValues must contain M*K = $($M * $K) elements; received $($AValues.Count)."
}
if ($null -ne $BValues -and $BValues.Count -ne ($K * $N)) {
    throw "BValues must contain K*N = $($K * $N) elements; received $($BValues.Count)."
}

$interop = & (Join-Path $PSScriptRoot 'src\New-WindowsFunctionPointerBinder.ps1')
$factory = [IntPtr]::Zero
$adapters = [Collections.Generic.List[IntPtr]]::new()
$blocks = [Collections.Generic.List[IntPtr]]::new()

function New-Block([int] $Bytes) {
    $pointer = [Runtime.InteropServices.Marshal]::AllocHGlobal($Bytes)
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new($Bytes), 0, $pointer, $Bytes)
    $blocks.Add($pointer)
    $pointer
}

function New-GuidBlock([Guid] $Guid) {
    $pointer = New-Block 16
    [Runtime.InteropServices.Marshal]::Copy($Guid.ToByteArray(), 0, $pointer, 16)
    $pointer
}

function W32([IntPtr] $Pointer, [int] $Offset, [uint32] $Value) {
    $signed = [BitConverter]::ToInt32([BitConverter]::GetBytes($Value), 0)
    [Runtime.InteropServices.Marshal]::WriteInt32($Pointer, $Offset, $signed)
}

function W64([IntPtr] $Pointer, [int] $Offset, [uint64] $Value) {
    [Runtime.InteropServices.Marshal]::WriteInt64($Pointer, $Offset, [long]$Value)
}

function WP([IntPtr] $Pointer, [int] $Offset, [IntPtr] $Value) {
    [Runtime.InteropServices.Marshal]::WriteIntPtr($Pointer, $Offset, $Value)
}

function WF32([IntPtr] $Pointer, [int] $Offset, [float] $Value) {
    [Runtime.InteropServices.Marshal]::WriteInt32(
        $Pointer, $Offset, [BitConverter]::ToInt32([BitConverter]::GetBytes($Value), 0))
}

function HRESULT([int] $Value) {
    '0x{0:X8}' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes($Value), 0)
}

function Check-HResult([int] $Value, [string] $Operation) {
    if ($Value -lt 0) { throw "$Operation failed: $(HRESULT $Value)" }
}

function Align4([uint64] $Value) {
    [uint64]($Value + ((4 - ($Value % 4)) % 4))
}

function Write-Half([IntPtr] $Pointer, [int] $ByteOffset, [float] $Value) {
    $bits = [BitConverter]::HalfToUInt16Bits([Half]$Value)
    $signed = [BitConverter]::ToInt16([BitConverter]::GetBytes($bits), 0)
    [Runtime.InteropServices.Marshal]::WriteInt16($Pointer, $ByteOffset, $signed)
}

function Read-Half([IntPtr] $Pointer, [int] $ByteOffset) {
    $signed = [Runtime.InteropServices.Marshal]::ReadInt16($Pointer, $ByteOffset)
    $bits = [BitConverter]::ToUInt16([BitConverter]::GetBytes($signed), 0)
    [float][BitConverter]::UInt16BitsToHalf($bits)
}

function New-DmlTensor([uint32[]] $Sizes) {
    $sizesBlock = New-Block ($Sizes.Count * 4)
    [uint64]$elementCount = 1
    for ($i = 0; $i -lt $Sizes.Count; $i++) {
        W32 $sizesBlock ($i * 4) $Sizes[$i]
        $elementCount *= $Sizes[$i]
    }

    $tensorBytes = Align4 ($elementCount * 2)
    $bufferDescription = New-Block 48
    W32 $bufferDescription 0 2          # DML_TENSOR_DATA_TYPE_FLOAT16
    W32 $bufferDescription 4 0          # DML_TENSOR_FLAG_NONE
    W32 $bufferDescription 8 $Sizes.Count
    WP  $bufferDescription 16 $sizesBlock
    WP  $bufferDescription 24 ([IntPtr]::Zero) # contiguous strides
    W64 $bufferDescription 32 $tensorBytes
    W32 $bufferDescription 40 16

    $tensorDescription = New-Block 16
    W32 $tensorDescription 0 1          # DML_TENSOR_TYPE_BUFFER
    WP  $tensorDescription 8 $bufferDescription
    [PSCustomObject]@{
        Description = $tensorDescription
        ElementCount = $elementCount
        Bytes = $tensorBytes
    }
}

function Invoke-V340Gemm([IntPtr] $Adapter, [int] $AdapterIndex, [int] $Ordinal, [string] $Name) {
    $com = [Collections.Generic.List[IntPtr]]::new()
    $eventHandle = [IntPtr]::Zero

    function Keep([IntPtr] $Pointer) {
        if ($Pointer -eq [IntPtr]::Zero) { throw 'A COM creation call returned a null interface.' }
        $com.Add($Pointer)
        $Pointer
    }

    try {
        $iidD3D12Device = New-GuidBlock ([Guid]'189819f1-1db6-4b57-be54-1821339b85f7')
        $iidResource = New-GuidBlock ([Guid]'696442be-a72e-4059-bc79-5b5c98040fad')
        $iidCommandAllocator = New-GuidBlock ([Guid]'6102dee4-af59-4b09-b999-b44d73f09b24')
        $iidFence = New-GuidBlock ([Guid]'0a753dcf-c4d8-4b91-adf6-be5a60d95a76')
        $iidDescriptorHeap = New-GuidBlock ([Guid]'8efb471d-616c-4f49-90f7-127bb763fa51')
        $iidCommandList = New-GuidBlock ([Guid]'5b160d0f-ac1b-4185-8ba8-b3ae42a5a455')
        $iidCommandQueue = New-GuidBlock ([Guid]'0ec870a6-5d7e-4c22-8cfc-5baae07616ed')
        $iidDmlDevice = New-GuidBlock ([Guid]'6dbd6437-96fd-423f-a98c-ae5e7c2a573f')
        $iidDmlOperator = New-GuidBlock ([Guid]'26caae7a-3081-4633-9581-226fbe57695d')
        $iidCompiled = New-GuidBlock ([Guid]'6b15e56a-bf5c-4902-92d8-da3a650afea4')
        $iidInitializer = New-GuidBlock ([Guid]'427c1113-435c-469c-8676-4d5dd072f813')
        $iidBindingTable = New-GuidBlock ([Guid]'29c687dc-de74-4e3b-ab00-1168f2fc3cfc')
        $iidRecorder = New-GuidBlock ([Guid]'e6857a76-2e3e-4fdd-bff4-5d2ba10fb453')

        $createD3D12Device = $interop.GetExportCall(
            'd3d12.dll', 'D3D12CreateDevice', ([int]), @([IntPtr], [int], [IntPtr], [IntPtr]))
        $createDmlDevice = $interop.GetExportCall(
            'DirectML.dll', 'DMLCreateDevice', ([int]), @([IntPtr], [uint32], [IntPtr], [IntPtr]))

        $out = New-Block 8
        Check-HResult ($createD3D12Device.Invoke($Adapter, 0xB000, $iidD3D12Device, $out)) 'D3D12CreateDevice'
        $d3d = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($out))

        $out = New-Block 8
        Check-HResult ($createDmlDevice.Invoke($d3d, [uint32]0, $iidDmlDevice, $out)) 'DMLCreateDevice'
        $dml = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($out))

        # Create the recorder before any descriptor/resource binding so a later
        # failure cannot be misattributed to the device/recorder ABI itself.
        $createRecorder = $interop.GetComCall($dml, 11, ([int]), @([IntPtr], [IntPtr]))
        $out = New-Block 8
        Check-HResult ($createRecorder.DynamicInvoke($dml, $iidRecorder, $out)) 'IDMLDevice::CreateCommandRecorder'
        $recorder = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($out))

        $aTensor = New-DmlTensor @([uint32]1, [uint32]1, [uint32]$M, [uint32]$K)
        $bTensor = New-DmlTensor @([uint32]1, [uint32]1, [uint32]$K, [uint32]$N)
        $oTensor = New-DmlTensor @([uint32]1, [uint32]1, [uint32]$M, [uint32]$N)

        $gemmDescription = New-Block 56
        WP $gemmDescription 0 $aTensor.Description
        WP $gemmDescription 8 $bTensor.Description
        WP $gemmDescription 16 ([IntPtr]::Zero)
        WP $gemmDescription 24 $oTensor.Description
        W32 $gemmDescription 32 0
        W32 $gemmDescription 36 0
        WF32 $gemmDescription 40 1.0
        WF32 $gemmDescription 44 0.0
        WP $gemmDescription 48 ([IntPtr]::Zero)

        $operatorDescription = New-Block 16
        W32 $operatorDescription 0 54    # DML_OPERATOR_GEMM
        WP $operatorDescription 8 $gemmDescription

        $createOperator = $interop.GetComCall($dml, 8, ([int]), @([IntPtr], [IntPtr], [IntPtr]))
        $out = New-Block 8
        Check-HResult ($createOperator.DynamicInvoke($dml, $operatorDescription, $iidDmlOperator, $out)) 'IDMLDevice::CreateOperator'
        $operator = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($out))

        $compile = $interop.GetComCall($dml, 9, ([int]), @([IntPtr], [uint32], [IntPtr], [IntPtr]))
        $out = New-Block 8
        Check-HResult ($compile.DynamicInvoke($dml, $operator, [uint32]1, $iidCompiled, $out)) 'IDMLDevice::CompileOperator'
        $compiled = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($out))

        $compiledOperators = New-Block 8
        WP $compiledOperators 0 $compiled
        $createInitializer = $interop.GetComCall(
            $dml, 10, ([int]), @([uint32], [IntPtr], [IntPtr], [IntPtr]))
        $out = New-Block 8
        Check-HResult ($createInitializer.DynamicInvoke(
            $dml, [uint32]1, $compiledOperators, $iidInitializer, $out)) 'IDMLDevice::CreateOperatorInitializer'
        $initializer = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($out))

        # Native-lowered ABI for the 24-byte DML_BINDING_PROPERTIES return:
        # RCX=this, RDX=result storage, RAX=result storage.
        $properties = New-Block 24
        $getProperties = $interop.GetComCall($compiled, 8, ([IntPtr]), @([IntPtr]))
        $returned = $getProperties.DynamicInvoke($compiled, $properties)
        if ($returned -ne $properties) { throw 'GetBindingProperties returned an unexpected pointer.' }
        $descriptorCount = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($properties, 0)
        $temporaryBytes = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($properties, 8)
        $persistentBytes = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($properties, 16)
        if ($descriptorCount -lt 1) { throw 'DirectML returned zero required descriptors.' }
        if ($temporaryBytes -ne 0 -or $persistentBytes -ne 0) {
            throw "This verified GEMM path expected no temporary/persistent resource; got $temporaryBytes/$persistentBytes bytes."
        }

        $initializerProperties = New-Block 24
        $getInitializerProperties = $interop.GetComCall($initializer, 8, ([IntPtr]), @([IntPtr]))
        $returned = $getInitializerProperties.DynamicInvoke($initializer, $initializerProperties)
        if ($returned -ne $initializerProperties) { throw 'Initializer GetBindingProperties returned an unexpected pointer.' }
        $initializerDescriptorCount = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($initializerProperties, 0)
        $initializerTemporaryBytes = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($initializerProperties, 8)
        $initializerPersistentBytes = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($initializerProperties, 16)
        if ($initializerTemporaryBytes -ne 0 -or $initializerPersistentBytes -ne 0) {
            throw "This verified GEMM initializer expected no temporary/persistent resource; got $initializerTemporaryBytes/$initializerPersistentBytes bytes."
        }

        $heapDescription = New-Block 16
        W32 $heapDescription 0 0         # D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV
        W32 $heapDescription 4 $descriptorCount
        W32 $heapDescription 8 1         # D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE
        W32 $heapDescription 12 0
        $createHeap = $interop.GetComCall($d3d, 14, ([int]), @([IntPtr], [IntPtr], [IntPtr]))
        $out = New-Block 8
        Check-HResult ($createHeap.DynamicInvoke($d3d, $heapDescription, $iidDescriptorHeap, $out)) 'ID3D12Device::CreateDescriptorHeap'
        $descriptorHeap = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($out))

        $initializerHeapDescription = New-Block 16
        W32 $initializerHeapDescription 0 0
        W32 $initializerHeapDescription 4 ([Math]::Max([uint32]1, $initializerDescriptorCount))
        W32 $initializerHeapDescription 8 1
        W32 $initializerHeapDescription 12 0
        $out = New-Block 8
        Check-HResult ($createHeap.DynamicInvoke(
            $d3d, $initializerHeapDescription, $iidDescriptorHeap, $out)) 'ID3D12Device::CreateDescriptorHeap(initializer)'
        $initializerDescriptorHeap = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($out))

        # D3D12 descriptor handles are C++ value structs; MSVC lowers both to an
        # explicit result pointer just like DML_BINDING_PROPERTIES.
        $cpuHandleBlock = New-Block 8
        $gpuHandleBlock = New-Block 8
        $getCpuHandle = $interop.GetComCall($descriptorHeap, 9, ([IntPtr]), @([IntPtr]))
        $getGpuHandle = $interop.GetComCall($descriptorHeap, 10, ([IntPtr]), @([IntPtr]))
        [void]$getCpuHandle.DynamicInvoke($descriptorHeap, $cpuHandleBlock)
        [void]$getGpuHandle.DynamicInvoke($descriptorHeap, $gpuHandleBlock)

        $initializerCpuHandleBlock = New-Block 8
        $initializerGpuHandleBlock = New-Block 8
        $getInitializerCpuHandle = $interop.GetComCall($initializerDescriptorHeap, 9, ([IntPtr]), @([IntPtr]))
        $getInitializerGpuHandle = $interop.GetComCall($initializerDescriptorHeap, 10, ([IntPtr]), @([IntPtr]))
        [void]$getInitializerCpuHandle.DynamicInvoke($initializerDescriptorHeap, $initializerCpuHandleBlock)
        [void]$getInitializerGpuHandle.DynamicInvoke($initializerDescriptorHeap, $initializerGpuHandleBlock)

        $bindingTableDescription = New-Block 32
        WP $bindingTableDescription 0 $compiled
        W64 $bindingTableDescription 8 ([uint64][Runtime.InteropServices.Marshal]::ReadInt64($cpuHandleBlock))
        W64 $bindingTableDescription 16 ([uint64][Runtime.InteropServices.Marshal]::ReadInt64($gpuHandleBlock))
        W32 $bindingTableDescription 24 $descriptorCount
        $createBindingTable = $interop.GetComCall($dml, 12, ([int]), @([IntPtr], [IntPtr], [IntPtr]))
        $out = New-Block 8
        Check-HResult ($createBindingTable.DynamicInvoke($dml, $bindingTableDescription, $iidBindingTable, $out)) 'IDMLDevice::CreateBindingTable'
        $bindingTable = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($out))

        $initializerBindingTableDescription = New-Block 32
        WP $initializerBindingTableDescription 0 $initializer
        W64 $initializerBindingTableDescription 8 ([uint64][Runtime.InteropServices.Marshal]::ReadInt64($initializerCpuHandleBlock))
        W64 $initializerBindingTableDescription 16 ([uint64][Runtime.InteropServices.Marshal]::ReadInt64($initializerGpuHandleBlock))
        W32 $initializerBindingTableDescription 24 ([Math]::Max([uint32]1, $initializerDescriptorCount))
        $out = New-Block 8
        Check-HResult ($createBindingTable.DynamicInvoke(
            $dml, $initializerBindingTableDescription, $iidBindingTable, $out)) 'IDMLDevice::CreateBindingTable(initializer)'
        $initializerBindingTable = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($out))

        function New-Buffer([uint64] $Bytes, [uint32] $HeapType, [uint32] $Flags, [uint32] $InitialState) {
            $heapProperties = New-Block 24
            W32 $heapProperties 0 $HeapType
            W32 $heapProperties 4 0
            W32 $heapProperties 8 0
            W32 $heapProperties 12 1
            W32 $heapProperties 16 1

            $resourceDescription = New-Block 56
            W32 $resourceDescription 0 1 # D3D12_RESOURCE_DIMENSION_BUFFER
            W64 $resourceDescription 8 0
            W64 $resourceDescription 16 $Bytes
            W32 $resourceDescription 24 1
            [Runtime.InteropServices.Marshal]::WriteInt16($resourceDescription, 28, 1)
            [Runtime.InteropServices.Marshal]::WriteInt16($resourceDescription, 30, 1)
            W32 $resourceDescription 32 0
            W32 $resourceDescription 36 1
            W32 $resourceDescription 40 0
            W32 $resourceDescription 44 1 # D3D12_TEXTURE_LAYOUT_ROW_MAJOR
            W32 $resourceDescription 48 $Flags

            $createResource = $interop.GetComCall(
                $d3d, 27, ([int]),
                @([IntPtr], [uint32], [IntPtr], [uint32], [IntPtr], [IntPtr], [IntPtr]))
            $resourceOut = New-Block 8
            $hr = $createResource.DynamicInvoke(
                $d3d, $heapProperties, [uint32]0, $resourceDescription,
                $InitialState, [IntPtr]::Zero, $iidResource, $resourceOut)
            Check-HResult $hr 'ID3D12Device::CreateCommittedResource'
            Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($resourceOut))
        }

        $aUploadResource = New-Buffer $aTensor.Bytes 2 0 0xAC3
        $bUploadResource = New-Buffer $bTensor.Bytes 2 0 0xAC3
        $aResource = New-Buffer $aTensor.Bytes 1 4 0x400
        $bResource = New-Buffer $bTensor.Bytes 1 4 0x400
        $outputResource = New-Buffer $oTensor.Bytes 1 4 0x8
        $readbackResource = New-Buffer $oTensor.Bytes 3 0 0x400

        function New-RepeatingHalfBytes([int] $ElementCount, [float[]] $Pattern) {
            $seed = [byte[]]::new($Pattern.Length * 2)
            for ($i = 0; $i -lt $Pattern.Length; $i++) {
                $bits = [BitConverter]::GetBytes([BitConverter]::HalfToUInt16Bits([Half]$Pattern[$i]))
                $seed[$i * 2] = $bits[0]
                $seed[$i * 2 + 1] = $bits[1]
            }
            $bytes = [byte[]]::new($ElementCount * 2)
            $filled = [Math]::Min($seed.Length, $bytes.Length)
            [Array]::Copy($seed, 0, $bytes, 0, $filled)
            while ($filled -lt $bytes.Length) {
                $copyLength = [Math]::Min($filled, $bytes.Length - $filled)
                [Array]::Copy($bytes, 0, $bytes, $filled, $copyLength)
                $filled += $copyLength
            }
            $bytes
        }

        function New-HalfBytes([float[]] $Values) {
            $bytes = [byte[]]::new($Values.Count * 2)
            for ($i = 0; $i -lt $Values.Count; $i++) {
                $bits = [BitConverter]::GetBytes([BitConverter]::HalfToUInt16Bits([Half]$Values[$i]))
                $bytes[$i * 2] = $bits[0]
                $bytes[$i * 2 + 1] = $bits[1]
            }
            $bytes
        }

        if ($null -ne $AValues) {
            $aBytes = New-HalfBytes $AValues
            $bBytes = New-HalfBytes $BValues
        } else {
            $aBytes = New-RepeatingHalfBytes ([int]$aTensor.ElementCount) @([float]-2, [float]-1, [float]0, [float]1, [float]2)
            $bBytes = New-RepeatingHalfBytes ([int]$bTensor.ElementCount) @([float]-1, [float]0, [float]1)
        }

        function Write-Upload([IntPtr] $Resource, [byte[]] $Bytes) {
            $mappedOut = New-Block 8
            $map = $interop.GetComCall($Resource, 8, ([int]), @([uint32], [IntPtr], [IntPtr]))
            Check-HResult ($map.DynamicInvoke($Resource, [uint32]0, [IntPtr]::Zero, $mappedOut)) 'ID3D12Resource::Map(upload)'
            $mapped = [Runtime.InteropServices.Marshal]::ReadIntPtr($mappedOut)
            [Runtime.InteropServices.Marshal]::Copy($Bytes, 0, $mapped, $Bytes.Length)
            $writtenRange = New-Block 16
            W64 $writtenRange 0 0
            W64 $writtenRange 8 ([uint64]$Bytes.Length)
            $unmap = $interop.GetComCall($Resource, 9, ([void]), @([uint32], [IntPtr]))
            $unmap.DynamicInvoke($Resource, [uint32]0, $writtenRange)
        }
        Write-Upload $aUploadResource $aBytes
        Write-Upload $bUploadResource $bBytes

        $aBinding = New-Block 24
        WP $aBinding 0 $aResource; W64 $aBinding 8 0; W64 $aBinding 16 $aTensor.Bytes
        $bBinding = New-Block 24
        WP $bBinding 0 $bResource; W64 $bBinding 8 0; W64 $bBinding 16 $bTensor.Bytes
        $oBinding = New-Block 24
        WP $oBinding 0 $outputResource; W64 $oBinding 8 0; W64 $oBinding 16 $oTensor.Bytes

        # GEMM has three input slots. Optional C still occupies a binding slot
        # and must be represented explicitly as DML_BINDING_TYPE_NONE.
        $inputBindings = New-Block 48
        W32 $inputBindings 0 1;  WP $inputBindings 8 $aBinding
        W32 $inputBindings 16 1; WP $inputBindings 24 $bBinding
        W32 $inputBindings 32 0; WP $inputBindings 40 ([IntPtr]::Zero)
        $outputBinding = New-Block 16
        W32 $outputBinding 0 1; WP $outputBinding 8 $oBinding
        $bindInputs = $interop.GetComCall($bindingTable, 8, ([void]), @([uint32], [IntPtr]))
        $bindOutputs = $interop.GetComCall($bindingTable, 9, ([void]), @([uint32], [IntPtr]))
        $bindInputs.DynamicInvoke($bindingTable, [uint32]3, $inputBindings)
        $bindOutputs.DynamicInvoke($bindingTable, [uint32]1, $outputBinding)

        $queueDescription = New-Block 16
        W32 $queueDescription 0 0
        W32 $queueDescription 4 0
        W32 $queueDescription 8 0
        W32 $queueDescription 12 0
        $createQueue = $interop.GetComCall($d3d, 8, ([int]), @([IntPtr], [IntPtr], [IntPtr]))
        $out = New-Block 8
        Check-HResult ($createQueue.DynamicInvoke($d3d, $queueDescription, $iidCommandQueue, $out)) 'ID3D12Device::CreateCommandQueue'
        $queue = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($out))

        $createAllocator = $interop.GetComCall($d3d, 9, ([int]), @([uint32], [IntPtr], [IntPtr]))
        $out = New-Block 8
        Check-HResult ($createAllocator.DynamicInvoke($d3d, [uint32]0, $iidCommandAllocator, $out)) 'ID3D12Device::CreateCommandAllocator'
        $allocator = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($out))

        $createCommandList = $interop.GetComCall(
            $d3d, 12, ([int]), @([uint32], [uint32], [IntPtr], [IntPtr], [IntPtr], [IntPtr]))
        $out = New-Block 8
        Check-HResult ($createCommandList.DynamicInvoke(
            $d3d, [uint32]0, [uint32]0, $allocator, [IntPtr]::Zero, $iidCommandList, $out)) 'ID3D12Device::CreateCommandList'
        $commandList = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($out))

        $setDescriptorHeaps = $interop.GetComCall(
            $commandList, 28, ([void]), @([uint32], [IntPtr]))
        $recordDispatch = $interop.GetComCall($recorder, 8, ([void]), @([IntPtr], [IntPtr], [IntPtr]))

        # Every compiled operator must be initialized exactly once before its
        # first execution. A dedicated heap/table keeps initializer descriptors
        # alive and distinct from the execution descriptors in this command list.
        $initializerDescriptorHeaps = New-Block 8
        WP $initializerDescriptorHeaps 0 $initializerDescriptorHeap
        $setDescriptorHeaps.DynamicInvoke(
            $commandList, [uint32]1, $initializerDescriptorHeaps)
        $recordDispatch.DynamicInvoke(
            $recorder, $commandList, $initializer, $initializerBindingTable)

        $copyBuffer = $interop.GetComCall(
            $commandList, 15, ([void]), @([IntPtr], [uint64], [IntPtr], [uint64], [uint64]))
        $copyBuffer.DynamicInvoke(
            $commandList, $aResource, [uint64]0,
            $aUploadResource, [uint64]0, $aTensor.Bytes)
        $copyBuffer.DynamicInvoke(
            $commandList, $bResource, [uint64]0,
            $bUploadResource, [uint64]0, $bTensor.Bytes)

        $inputTransitions = New-Block 64
        WP $inputTransitions 8 $aResource
        W32 $inputTransitions 16 ([uint32]::MaxValue)
        W32 $inputTransitions 20 0x400 # COPY_DEST
        W32 $inputTransitions 24 0x8   # UNORDERED_ACCESS
        WP $inputTransitions 40 $bResource
        W32 $inputTransitions 48 ([uint32]::MaxValue)
        W32 $inputTransitions 52 0x400 # COPY_DEST
        W32 $inputTransitions 56 0x8   # UNORDERED_ACCESS
        $resourceBarrier = $interop.GetComCall($commandList, 26, ([void]), @([uint32], [IntPtr]))
        $resourceBarrier.DynamicInvoke($commandList, [uint32]2, $inputTransitions)

        # DirectML writes descriptors into the binding table, but it does not bind
        # the shader-visible descriptor heap to the D3D12 command list for us.
        $descriptorHeaps = New-Block 8
        WP $descriptorHeaps 0 $descriptorHeap
        $setDescriptorHeaps.DynamicInvoke($commandList, [uint32]1, $descriptorHeaps)

        $recordDispatch.DynamicInvoke($recorder, $commandList, $compiled, $bindingTable)

        $transition = New-Block 32
        W32 $transition 0 0           # D3D12_RESOURCE_BARRIER_TYPE_TRANSITION
        W32 $transition 4 0
        WP $transition 8 $outputResource
        W32 $transition 16 ([uint32]::MaxValue)
        W32 $transition 20 0x8       # UNORDERED_ACCESS
        W32 $transition 24 0x800     # COPY_SOURCE
        $resourceBarrier.DynamicInvoke($commandList, [uint32]1, $transition)

        $copyBuffer.DynamicInvoke(
            $commandList, $readbackResource, [uint64]0,
            $outputResource, [uint64]0, $oTensor.Bytes)

        $close = $interop.GetComCall($commandList, 9, ([int]), @())
        Check-HResult ($close.DynamicInvoke($commandList)) 'ID3D12GraphicsCommandList::Close'

        $commandLists = New-Block 8
        WP $commandLists 0 $commandList
        $execute = $interop.GetComCall($queue, 10, ([void]), @([uint32], [IntPtr]))
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $execute.DynamicInvoke($queue, [uint32]1, $commandLists)

        $createFence = $interop.GetComCall($d3d, 36, ([int]), @([uint64], [uint32], [IntPtr], [IntPtr]))
        $out = New-Block 8
        Check-HResult ($createFence.DynamicInvoke($d3d, [uint64]0, [uint32]0, $iidFence, $out)) 'ID3D12Device::CreateFence'
        $fence = Keep ([Runtime.InteropServices.Marshal]::ReadIntPtr($out))

        $createEvent = $interop.GetExportCall(
            'kernel32.dll', 'CreateEventW', ([IntPtr]), @([IntPtr], [bool], [bool], [IntPtr]))
        $wait = $interop.GetExportCall('kernel32.dll', 'WaitForSingleObject', ([uint32]), @([IntPtr], [uint32]))
        $closeHandle = $interop.GetExportCall('kernel32.dll', 'CloseHandle', ([bool]), @([IntPtr]))
        $eventHandle = $createEvent.Invoke([IntPtr]::Zero, $false, $false, [IntPtr]::Zero)
        if ($eventHandle -eq [IntPtr]::Zero) { throw 'CreateEventW failed.' }

        $signal = $interop.GetComCall($queue, 14, ([int]), @([IntPtr], [uint64]))
        Check-HResult ($signal.DynamicInvoke($queue, $fence, [uint64]1)) 'ID3D12CommandQueue::Signal'
        $completedValue = $interop.GetComCall($fence, 8, ([uint64]), @())
        if ([uint64]$completedValue.DynamicInvoke($fence) -lt 1) {
            $setEvent = $interop.GetComCall($fence, 9, ([int]), @([uint64], [IntPtr]))
            Check-HResult ($setEvent.DynamicInvoke($fence, [uint64]1, $eventHandle)) 'ID3D12Fence::SetEventOnCompletion'
            $waitResult = $wait.Invoke($eventHandle, [uint32]::MaxValue)
            if ($waitResult -ne 0) { throw "WaitForSingleObject failed: $waitResult" }
        }
        $stopwatch.Stop()

        $expected = [double[]]::new($M * $N)
        if ($null -ne $AValues) {
            # DirectML receives FP16, so the oracle uses the same rounded inputs.
            for ($row = 0; $row -lt $M; $row++) {
                for ($column = 0; $column -lt $N; $column++) {
                    [double]$sum = 0
                    for ($inner = 0; $inner -lt $K; $inner++) {
                        $a = [float][Half]$AValues[$row * $K + $inner]
                        $b = [float][Half]$BValues[$inner * $N + $column]
                        $sum += [double]$a * [double]$b
                    }
                    $expected[$row * $N + $column] = $sum
                }
            }
        } else {
            # The default generators repeat every 5 and 3 elements. Compute one
            # exact sum per row and B column class, then expand it so the large
            # correctness sweep does not spend its time in interpreted M*N*K.
            $expectedByRowClass = [double[]]::new($M * 3)
            for ($row = 0; $row -lt $M; $row++) {
                for ($columnClass = 0; $columnClass -lt 3; $columnClass++) {
                    [double]$sum = 0
                    for ($inner = 0; $inner -lt $K; $inner++) {
                        $a = (($row * $K + $inner) % 5) - 2
                        $b = (($inner * $N + $columnClass) % 3) - 1
                        $sum += [double]$a * [double]$b
                    }
                    $expectedByRowClass[$row * 3 + $columnClass] = $sum
                }
            }
            for ($row = 0; $row -lt $M; $row++) {
                for ($column = 0; $column -lt $N; $column++) {
                    $expected[$row * $N + $column] = $expectedByRowClass[$row * 3 + ($column % 3)]
                }
            }
        }

        $readRange = New-Block 16
        W64 $readRange 0 0; W64 $readRange 8 $oTensor.Bytes
        $mappedOut = New-Block 8
        $mapReadback = $interop.GetComCall($readbackResource, 8, ([int]), @([uint32], [IntPtr], [IntPtr]))
        Check-HResult ($mapReadback.DynamicInvoke($readbackResource, [uint32]0, $readRange, $mappedOut)) 'ID3D12Resource::Map(readback)'
        $mapped = [Runtime.InteropServices.Marshal]::ReadIntPtr($mappedOut)
        $maxError = 0.0
        $mismatch = -1
        $actualAtMismatch = 0.0
        $capturedOutput = if ($IncludeOutput) { [float[]]::new($expected.Length) } else { $null }
        for ($i = 0; $i -lt $expected.Length; $i++) {
            $actual = Read-Half $mapped ($i * 2)
            if ($IncludeOutput) { $capturedOutput[$i] = $actual }
            $error = [Math]::Abs($actual - $expected[$i])
            if ($error -gt $maxError) { $maxError = $error }
            if ($mismatch -lt 0 -and $error -gt $Tolerance) {
                $mismatch = $i
                $actualAtMismatch = $actual
            }
        }
        $unmapReadback = $interop.GetComCall($readbackResource, 9, ([void]), @([uint32], [IntPtr]))
        $unmapReadback.DynamicInvoke($readbackResource, [uint32]0, [IntPtr]::Zero)

        if ($mismatch -ge 0) {
            throw "FP16 GEMM mismatch at output[$mismatch]: expected=$($expected[$mismatch]), actual=$actualAtMismatch, tolerance=$Tolerance"
        }

        [PSCustomObject]@{
            Status = 'PASS'
            AdapterIndex = $AdapterIndex
            V340Ordinal = $Ordinal
            Adapter = $Name
            Shape = "[$M,$K] x [$K,$N]"
            RequiredDescriptors = $descriptorCount
            TemporaryBytes = $temporaryBytes
            PersistentBytes = $persistentBytes
            DispatchAndReadbackMilliseconds = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 3)
            MaxAbsoluteError = [Math]::Round($maxError, 6)
            OutputElementsVerified = $expected.Length
            MetaCommandsDisabled = $false
            P2000Excluded = $true
            Mode = 'No-build PowerShell COM/vtable dispatch'
            OutputValues = $capturedOutput
        }
    } finally {
        if ($eventHandle -ne [IntPtr]::Zero) {
            try {
                $closeHandle = $interop.GetExportCall('kernel32.dll', 'CloseHandle', ([bool]), @([IntPtr]))
                [void]$closeHandle.Invoke($eventHandle)
            } catch { }
        }
        for ($i = $com.Count - 1; $i -ge 0; $i--) { [void]$interop.ReleaseCom($com[$i]) }
    }
}

try {
    $createFactory = $interop.GetExportCall(
        'dxgi.dll', 'CreateDXGIFactory1', ([int]), @([IntPtr], [IntPtr]))
    $iidFactory1 = New-GuidBlock ([Guid]'770aae78-f26f-4dba-a829-253c83d1b387')
    $factoryOut = New-Block 8
    Check-HResult ($createFactory.Invoke($iidFactory1, $factoryOut)) 'CreateDXGIFactory1'
    $factory = [Runtime.InteropServices.Marshal]::ReadIntPtr($factoryOut)

    $enumAdapters = $interop.GetComCall($factory, 12, ([int]), @([uint32], [IntPtr]))
    $v340s = [Collections.Generic.List[object]]::new()
    $index = 0
    while ($true) {
        $adapterOut = New-Block 8
        $hr = $enumAdapters.DynamicInvoke($factory, [uint32]$index, $adapterOut)
        if ([BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$hr), 0) -eq 0x887A0002L) { break }
        Check-HResult $hr "IDXGIFactory1::EnumAdapters1($index)"
        $adapter = [Runtime.InteropServices.Marshal]::ReadIntPtr($adapterOut)
        $adapters.Add($adapter)

        $description = New-Block 312
        $getDescription = $interop.GetComCall($adapter, 10, ([int]), @([IntPtr]))
        Check-HResult ($getDescription.DynamicInvoke($adapter, $description)) "IDXGIAdapter1::GetDesc1($index)"
        $name = [Runtime.InteropServices.Marshal]::PtrToStringUni($description, 128).TrimEnd([char]0)
        $vendor = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($description, 256)
        $device = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($description, 260)
        if ($vendor -eq 0x1002 -and $device -eq 0x6864 -and $name -match 'V340') {
            $v340s.Add([PSCustomObject]@{ Adapter = $adapter; AdapterIndex = $index; Name = $name })
        }
        $index++
    }

    if ($v340s.Count -ne 4) { throw "Expected four V340 adapters; found $($v340s.Count)." }
    $targets = if ($V340Ordinal -ge 0) { @($v340s[$V340Ordinal]) } else { @($v340s) }
    $results = [Collections.Generic.List[object]]::new()
    foreach ($target in $targets) {
        $ordinal = $v340s.IndexOf($target)
        if (-not $Quiet) {
            Write-Host "[*] DirectML FP16 GEMM on V340[$ordinal] (DXGI $($target.AdapterIndex))..." -ForegroundColor Cyan
        }
        $result = @(Invoke-V340Gemm $target.Adapter $target.AdapterIndex $ordinal $target.Name) |
            Where-Object { $_ -is [PSCustomObject] -and $_.Status -eq 'PASS' } |
            Select-Object -Last 1
        if ($null -eq $result) { throw "V340[$ordinal] completed without returning a verification result." }
        $results.Add($result)
        if (-not $Quiet) {
            Write-Host "    PASS: $($result.OutputElementsVerified) outputs, max error $($result.MaxAbsoluteError)" -ForegroundColor Green
        }
    }
    if (-not $Quiet) {
        $results | Format-Table V340Ordinal, Shape, OutputElementsVerified, MaxAbsoluteError, DispatchAndReadbackMilliseconds -AutoSize | Out-Host
    }
    if ($V340Ordinal -ge 0) { $results[0] } else { $results.ToArray() }
} finally {
    for ($i = $adapters.Count - 1; $i -ge 0; $i--) { [void]$interop.ReleaseCom($adapters[$i]) }
    if ($factory -ne [IntPtr]::Zero) { [void]$interop.ReleaseCom($factory) }
    foreach ($pointer in $blocks) {
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($pointer) }
    }
    $interop.Dispose()
}
