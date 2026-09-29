<#
.SYNOPSIS
    Executes a real stock ggml MUL_MAT graph through DirectML after mutating
    the live CPU backend graph_compute callback.

.DESCRIPTION
    Builds a small F32 GGML_OP_MUL_MAT graph with stock ggml, replaces the
    CPU backend graph_compute callback at the runtime-validated +104 / 0x68
    slot, reads the source tensors, executes the matrix multiplication as FP16
    on a selected V340 die through Test-DirectMLGemm.ps1, writes the returned
    GPU result into the ggml output tensor, and restores the original callback.

    The stock CPU graph_compute function is captured for restoration but is
    never invoked. No compiler, helper binary, or llama.cpp rebuild is used.
#>

[CmdletBinding()]
param(
    [string] $LlamaBinDir = 'C:\bin\llama.cpp',
    [string] $CpuDllName = 'ggml-cpu-x64.dll',
    [ValidateRange(0, 3)] [int] $V340Ordinal = 0,
    [switch] $Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([IntPtr]::Size -ne 8) { throw '64-bit PowerShell is required.' }

$interop = & (Join-Path $PSScriptRoot 'src\New-WindowsFunctionPointerBinder.ps1')
$context = [IntPtr]::Zero
$backend = [IntPtr]::Zero
$slot = [IntPtr]::Zero
$original = [IntPtr]::Zero
$mutated = $false
$blocks = [Collections.Generic.List[IntPtr]]::new()

function New-Block([int] $Bytes) {
    $pointer = [Runtime.InteropServices.Marshal]::AllocHGlobal($Bytes)
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new($Bytes), 0, $pointer, $Bytes)
    $blocks.Add($pointer)
    $pointer
}

try {
    $env:PATH = "$LlamaBinDir;$env:PATH"
    $basePath = Join-Path $LlamaBinDir 'ggml-base.dll'
    $cpuPath = Join-Path $LlamaBinDir $CpuDllName
    $directMlScript = Join-Path $PSScriptRoot 'Test-DirectMLGemm.ps1'
    if (-not (Test-Path -LiteralPath $basePath)) { throw "Missing $basePath" }
    if (-not (Test-Path -LiteralPath $cpuPath)) { throw "Missing $cpuPath" }
    if (-not (Test-Path -LiteralPath $directMlScript)) { throw "Missing $directMlScript" }

    $baseLibrary = $interop.LoadLibrary($basePath)
    $cpuLibrary = $interop.LoadLibrary($cpuPath)

    function Base-Call([string] $Name, [Type] $ReturnType, [Type[]] $Parameters) {
        $interop.GetCall($interop.GetExport($baseLibrary, $Name), $ReturnType, $Parameters)
    }

    $ggmlInit = Base-Call 'ggml_init' ([IntPtr]) @([IntPtr])
    $ggmlFree = Base-Call 'ggml_free' ([void]) @([IntPtr])
    $newTensor2d = Base-Call 'ggml_new_tensor_2d' ([IntPtr]) @([IntPtr], [int], [int64], [int64])
    $mulMat = Base-Call 'ggml_mul_mat' ([IntPtr]) @([IntPtr], [IntPtr], [IntPtr])
    $newGraph = Base-Call 'ggml_new_graph_custom' ([IntPtr]) @([IntPtr], [uint64], [bool])
    $buildForward = Base-Call 'ggml_build_forward_expand' ([void]) @([IntPtr], [IntPtr])
    $getData = Base-Call 'ggml_get_data' ([IntPtr]) @([IntPtr])
    $graphNodeCount = Base-Call 'ggml_graph_n_nodes' ([int]) @([IntPtr])
    $graphNode = Base-Call 'ggml_graph_node' ([IntPtr]) @([IntPtr], [int])
    $opDescription = Base-Call 'ggml_op_desc' ([IntPtr]) @([IntPtr])
    $backendGraphCompute = Base-Call 'ggml_backend_graph_compute' ([int]) @([IntPtr], [IntPtr])
    $backendFree = Base-Call 'ggml_backend_free' ([void]) @([IntPtr])
    $cpuInit = $interop.GetCall(
        $interop.GetExport($cpuLibrary, 'ggml_backend_cpu_init'), ([IntPtr]), @())

    # MSVC x64 lowers the 24-byte ggml_init_params value to an indirect pointer.
    $initParameters = New-Block 24
    [Runtime.InteropServices.Marshal]::WriteInt64($initParameters, 0, 4MB)
    [Runtime.InteropServices.Marshal]::WriteIntPtr($initParameters, 8, [IntPtr]::Zero)
    [Runtime.InteropServices.Marshal]::WriteByte($initParameters, 16, 0)
    $context = $ggmlInit.DynamicInvoke($initParameters)
    if ($context -eq [IntPtr]::Zero) { throw 'ggml_init returned null.' }

    # ggml A is M rows of K values. ggml B is N rows of K values. DirectML
    # GEMM consumes row-major A[M,K] and B[K,N], so B is transposed below.
    [int]$m = 2
    [int]$k = 3
    [int]$n = 4
    $a = $newTensor2d.DynamicInvoke($context, 0, [int64]$k, [int64]$m)
    $b = $newTensor2d.DynamicInvoke($context, 0, [int64]$k, [int64]$n)
    if ($a -eq [IntPtr]::Zero -or $b -eq [IntPtr]::Zero) { throw 'Tensor creation returned null.' }

    $aValues = [float[]]@(1, 2, 3, 4, 5, 6)
    $bGgmlValues = [float[]]@(1, 0, -1, 2, 1, 0, -1, 1, 2, 0.5, -0.5, 1)
    [Runtime.InteropServices.Marshal]::Copy($aValues, 0, $getData.DynamicInvoke($a), $aValues.Length)
    [Runtime.InteropServices.Marshal]::Copy($bGgmlValues, 0, $getData.DynamicInvoke($b), $bGgmlValues.Length)

    $output = $mulMat.DynamicInvoke($context, $a, $b)
    $graph = $newGraph.DynamicInvoke($context, [uint64]32, $false)
    if ($output -eq [IntPtr]::Zero -or $graph -eq [IntPtr]::Zero) { throw 'Graph construction returned null.' }
    [void]$buildForward.DynamicInvoke($graph, $output)
    $outputData = $getData.DynamicInvoke($output)
    if ($outputData -eq [IntPtr]::Zero) { throw 'ggml output tensor has no host data pointer.' }

    $backend = $cpuInit.DynamicInvoke()
    if ($backend -eq [IntPtr]::Zero) { throw 'ggml_backend_cpu_init returned null.' }

    # ggml_backend: GUID pointer at +0x00, interface at +0x08. graph_compute is
    # interface slot 12, hence +0x08 + 12*8 = +0x68.
    $slot = [IntPtr]::new($backend.ToInt64() + 0x68)
    $original = [Runtime.InteropServices.Marshal]::ReadIntPtr($slot)
    if ($original -eq [IntPtr]::Zero) { throw 'CPU graph_compute callback is null.' }

    $state = [hashtable]::Synchronized(@{
        Calls = 0
        Error = $null
        DispatchMilliseconds = 0.0
        OutputsWritten = 0
        GraphNodesDecoded = 0
        DecodedOperation = $null
    })

    $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
        [Reflection.AssemblyName]::new('V340L.GgmlDirectML.' + [Guid]::NewGuid().ToString('N')),
        [Reflection.Emit.AssemblyBuilderAccess]::Run)
    $module = $assembly.DefineDynamicModule('GgmlDirectMLInterception')
    $delegateBuilder = $module.DefineType(
        'GraphComputeDelegate', 'Public,Sealed', [MulticastDelegate])
    [void]$delegateBuilder.DefineConstructor(
        'Public,HideBySig,RTSpecialName', [Reflection.CallingConventions]::Standard,
        @([object], [IntPtr])).SetImplementationFlags('Runtime,Managed')
    [void]$delegateBuilder.DefineMethod(
        'Invoke', 'Public,HideBySig,NewSlot,Virtual', [int],
        @([IntPtr], [IntPtr])).SetImplementationFlags('Runtime,Managed')
    [void]$delegateBuilder.SetCustomAttribute([Reflection.Emit.CustomAttributeBuilder]::new(
        [Runtime.InteropServices.UnmanagedFunctionPointerAttribute].GetConstructor(
            @([Runtime.InteropServices.CallingConvention])),
        @([Runtime.InteropServices.CallingConvention]::StdCall)))
    $delegateType = $delegateBuilder.CreateType()

    $callbackScript = {
        param([IntPtr] $callbackBackend, [IntPtr] $callbackGraph)
        $state.Calls++
        try {
            if ($callbackBackend -ne $backend) { throw 'Callback received an unexpected backend pointer.' }
            if ($callbackGraph -ne $graph) { throw 'Callback received an unexpected graph pointer.' }

            $nodeCount = $graphNodeCount.DynamicInvoke($callbackGraph)
            if ($nodeCount -ne 1) { throw "Expected one graph node; received $nodeCount." }
            $node = $graphNode.DynamicInvoke($callbackGraph, 0)
            if ($node -ne $output) { throw 'Graph node pointer does not match the expected output tensor.' }
            $operation = [Runtime.InteropServices.Marshal]::PtrToStringAnsi(
                $opDescription.DynamicInvoke($node))
            if ($operation -ne 'MUL_MAT') { throw "Expected MUL_MAT; received $operation." }

            # Exact ggml_tensor layout from the matching upstream ABI:
            # op at +80, src[0] at +152, src[1] at +160, data at +248.
            $sourceA = [Runtime.InteropServices.Marshal]::ReadIntPtr($node, 152)
            $sourceB = [Runtime.InteropServices.Marshal]::ReadIntPtr($node, 160)
            $nodeData = [Runtime.InteropServices.Marshal]::ReadIntPtr($node, 248)
            if ($sourceA -ne $a -or $sourceB -ne $b -or $nodeData -ne $outputData) {
                throw 'Decoded ggml tensor pointers do not match the constructed graph.'
            }

            $callbackAValues = [float[]]::new($m * $k)
            $callbackBGgmlValues = [float[]]::new($n * $k)
            [Runtime.InteropServices.Marshal]::Copy(
                $getData.DynamicInvoke($sourceA), $callbackAValues, 0, $callbackAValues.Length)
            [Runtime.InteropServices.Marshal]::Copy(
                $getData.DynamicInvoke($sourceB), $callbackBGgmlValues, 0, $callbackBGgmlValues.Length)
            $callbackBDmlValues = [float[]]::new($k * $n)
            for ($inner = 0; $inner -lt $k; $inner++) {
                for ($column = 0; $column -lt $n; $column++) {
                    $callbackBDmlValues[$inner * $n + $column] =
                        $callbackBGgmlValues[$column * $k + $inner]
                }
            }

            $dmlResult = & $directMlScript -V340Ordinal $V340Ordinal -M $m -K $k -N $n `
                -AValues $callbackAValues -BValues $callbackBDmlValues -IncludeOutput -Quiet
            if ($dmlResult.Status -ne 'PASS' -or $dmlResult.OutputValues.Count -ne ($m * $n)) {
                throw 'DirectML did not return the expected verified output.'
            }

            # DirectML output is row-major [M,N]. ggml output storage is N rows
            # with ne[0]=M, so transpose the host-visible result back to ggml.
            $ggmlValues = [float[]]::new($m * $n)
            for ($column = 0; $column -lt $n; $column++) {
                for ($row = 0; $row -lt $m; $row++) {
                    $ggmlValues[$column * $m + $row] =
                        $dmlResult.OutputValues[$row * $n + $column]
                }
            }
            [Runtime.InteropServices.Marshal]::Copy(
                $ggmlValues, 0, $outputData, $ggmlValues.Length)
            $state.DispatchMilliseconds = $dmlResult.DispatchAndReadbackMilliseconds
            $state.OutputsWritten = $ggmlValues.Length
            $state.GraphNodesDecoded = $nodeCount
            $state.DecodedOperation = $operation
            return 0
        } catch {
            $state.Error = $_.Exception.ToString()
            return 1
        }
    }.GetNewClosure()

    $replacementDelegate = [Management.Automation.LanguagePrimitives]::ConvertTo(
        $callbackScript, $delegateType)
    $replacement = [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate(
        $replacementDelegate)
    [Runtime.InteropServices.Marshal]::WriteIntPtr($slot, $replacement)
    $mutated = $true
    if ([Runtime.InteropServices.Marshal]::ReadIntPtr($slot) -ne $replacement) {
        throw 'graph_compute pointer write did not stick.'
    }

    $status = $backendGraphCompute.DynamicInvoke($backend, $graph)
    if ($status -ne 0) {
        throw "Intercepted graph_compute returned status $status. $($state.Error)"
    }
    if ($state.Calls -ne 1) { throw "Expected one intercepted graph call; observed $($state.Calls)." }
    if ($null -ne $state.Error) { throw "DirectML callback failed: $($state.Error)" }

    $actual = [float[]]::new($m * $n)
    [Runtime.InteropServices.Marshal]::Copy($outputData, $actual, 0, $actual.Length)
    $expected = [float[]]@(-2, -2, 4, 13, 7, 13, 2.5, 5.5)
    [double]$maxError = 0
    for ($i = 0; $i -lt $expected.Length; $i++) {
        $absoluteError = [Math]::Abs($actual[$i] - $expected[$i])
        if ($absoluteError -gt $maxError) { $maxError = $absoluteError }
        if ($absoluteError -gt 0.05) {
            throw "Output mismatch at ${i}: expected $($expected[$i]), actual $($actual[$i])."
        }
    }

    [Runtime.InteropServices.Marshal]::WriteIntPtr($slot, $original)
    $mutated = $false
    if ([Runtime.InteropServices.Marshal]::ReadIntPtr($slot) -ne $original) {
        throw 'graph_compute pointer restoration failed.'
    }

    $result = [PSCustomObject]@{
        Status = 'PASS'
        CpuLibrary = $CpuDllName
        CallbackSlotOffset = '+104 (0x68)'
        InterceptedCalls = $state.Calls
        GraphOperation = 'GGML_OP_MUL_MAT / F32 inputs -> DirectML FP16 GEMM'
        GraphNodesDecoded = $state.GraphNodesDecoded
        DecodedOperation = $state.DecodedOperation
        V340Ordinal = $V340Ordinal
        InputElementsReadFromGgml = $aValues.Length + $bGgmlValues.Length
        OutputElementsWrittenToGgml = $state.OutputsWritten
        MaxAbsoluteError = [Math]::Round($maxError, 6)
        DirectMLDispatchAndReadbackMilliseconds = $state.DispatchMilliseconds
        ForwardedToStockCpu = $false
        CallbackRestored = $true
        CompilerUsed = 'None'
    }
    if ($Json) { $result | ConvertTo-Json -Compress } else { $result }
}
finally {
    if ($mutated -and $slot -ne [IntPtr]::Zero -and $original -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::WriteIntPtr($slot, $original)
    }
    if ($backend -ne [IntPtr]::Zero) {
        try { $backendFree.DynamicInvoke($backend) } catch { }
    }
    if ($context -ne [IntPtr]::Zero) {
        try { $ggmlFree.DynamicInvoke($context) } catch { }
    }
    foreach ($pointer in $blocks) {
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($pointer) }
    }
    $interop.Dispose()
}
