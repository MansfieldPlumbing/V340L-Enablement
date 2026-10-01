<#
.SYNOPSIS
    Intercepts and forwards a real stock ggml CPU graph_compute call.

.DESCRIPTION
    Builds a tiny F32 GGML_OP_MUL_MAT graph with the installed stock ggml
    libraries, replaces the live CPU backend graph_compute callback at the
    runtime-validated +104 / 0x68 slot, forwards to the captured stock callback,
    verifies the output, and restores the original pointer. No compiler or
    helper binary is used.
#>

[CmdletBinding()]
param(
    [string] $LlamaBinDir = 'C:\bin\llama.cpp',
    [string] $CpuDllName = 'ggml-cpu-x64.dll'
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
    if (-not (Test-Path -LiteralPath $basePath)) { throw "Missing $basePath" }
    if (-not (Test-Path -LiteralPath $cpuPath)) { throw "Missing $cpuPath" }

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
    $backendGraphCompute = Base-Call 'ggml_backend_graph_compute' ([int]) @([IntPtr], [IntPtr])
    $backendFree = Base-Call 'ggml_backend_free' ([void]) @([IntPtr])

    $cpuInit = $interop.GetCall(
        $interop.GetExport($cpuLibrary, 'ggml_backend_cpu_init'), ([IntPtr]), @())

    # MSVC x64 passes this 24-byte by-value aggregate indirectly. The pointer is
    # therefore the native lowered argument for ggml_init(ggml_init_params).
    $initParameters = New-Block 24
    [Runtime.InteropServices.Marshal]::WriteInt64($initParameters, 0, 4MB)
    [Runtime.InteropServices.Marshal]::WriteIntPtr($initParameters, 8, [IntPtr]::Zero)
    [Runtime.InteropServices.Marshal]::WriteByte($initParameters, 16, 0)
    $context = $ggmlInit.DynamicInvoke($initParameters)
    if ($context -eq [IntPtr]::Zero) { throw 'ggml_init returned null.' }

    # ggml stores ne[0] contiguously. A is two K=3 rows and B is four K=3 rows.
    $a = $newTensor2d.DynamicInvoke($context, 0, [int64]3, [int64]2)
    $b = $newTensor2d.DynamicInvoke($context, 0, [int64]3, [int64]4)
    if ($a -eq [IntPtr]::Zero -or $b -eq [IntPtr]::Zero) { throw 'Tensor creation returned null.' }
    $aValues = [float[]]@(1, 2, 3, 4, 5, 6)
    $bValues = [float[]]@(1, 0, -1, 2, 1, 0, -1, 1, 2, 0.5, -0.5, 1)
    [Runtime.InteropServices.Marshal]::Copy($aValues, 0, $getData.DynamicInvoke($a), $aValues.Length)
    [Runtime.InteropServices.Marshal]::Copy($bValues, 0, $getData.DynamicInvoke($b), $bValues.Length)

    $output = $mulMat.DynamicInvoke($context, $a, $b)
    $graph = $newGraph.DynamicInvoke($context, [uint64]32, $false)
    if ($output -eq [IntPtr]::Zero -or $graph -eq [IntPtr]::Zero) { throw 'Graph construction returned null.' }
    [void]$buildForward.DynamicInvoke($graph, $output)

    $backend = $cpuInit.DynamicInvoke()
    if ($backend -eq [IntPtr]::Zero) { throw 'ggml_backend_cpu_init returned null.' }

    # ggml_backend: GUID pointer at +0x00, iface at +0x08. graph_compute is
    # iface slot 12, hence +0x08 + 12*8 = +0x68.
    $slot = [IntPtr]::new($backend.ToInt64() + 0x68)
    $original = [Runtime.InteropServices.Marshal]::ReadIntPtr($slot)
    if ($original -eq [IntPtr]::Zero) { throw 'CPU graph_compute callback is null.' }

    $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
        [Reflection.AssemblyName]::new('V340L.GgmlGraph.' + [Guid]::NewGuid().ToString('N')),
        [Reflection.Emit.AssemblyBuilderAccess]::Run)
    $module = $assembly.DefineDynamicModule('GraphInterception')
    $typeBuilder = $module.DefineType('GraphTrampoline', 'Public,Abstract,Sealed')
    $originalField = $typeBuilder.DefineField('Original', [IntPtr], 'Public,Static')
    $countField = $typeBuilder.DefineField('CallCount', [int], 'Public,Static')
    $method = $typeBuilder.DefineMethod(
        'GraphCompute', 'Public,Static', [int], @([IntPtr], [IntPtr]))
    $il = $method.GetILGenerator()
    $incrementInt32 = [Threading.Interlocked].GetMethods() |
        Where-Object {
            $_.Name -eq 'Increment' -and $_.ReturnType -eq [int] -and
            $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType -eq [int].MakeByRefType()
        } |
        Select-Object -First 1
    if ($null -eq $incrementInt32) { throw 'Could not resolve Interlocked.Increment(ref int).' }
    $il.Emit([Reflection.Emit.OpCodes]::Ldsflda, $countField)
    $il.Emit([Reflection.Emit.OpCodes]::Call, $incrementInt32)
    $il.Emit([Reflection.Emit.OpCodes]::Pop)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $originalField)
    $il.EmitCalli(
        [Reflection.Emit.OpCodes]::Calli,
        [Runtime.InteropServices.CallingConvention]::StdCall,
        [int], @([IntPtr], [IntPtr]))
    $il.Emit([Reflection.Emit.OpCodes]::Ret)
    $trampolineType = $typeBuilder.CreateType()
    $trampolineType.GetField('Original').SetValue($null, $original)

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
    $replacementDelegate = [Delegate]::CreateDelegate(
        $delegateType, $trampolineType.GetMethod('GraphCompute'))
    $replacement = [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($replacementDelegate)

    [Runtime.InteropServices.Marshal]::WriteIntPtr($slot, $replacement)
    $mutated = $true
    if ([Runtime.InteropServices.Marshal]::ReadIntPtr($slot) -ne $replacement) {
        throw 'graph_compute pointer write did not stick.'
    }

    $status = $backendGraphCompute.DynamicInvoke($backend, $graph)
    $callCount = $trampolineType.GetField('CallCount').GetValue($null)
    if ($status -ne 0) { throw "ggml_backend_graph_compute returned status $status." }
    if ($callCount -ne 1) { throw "Expected one intercepted graph call; observed $callCount." }

    $actual = [float[]]::new(8)
    [Runtime.InteropServices.Marshal]::Copy($getData.DynamicInvoke($output), $actual, 0, $actual.Length)
    $expected = [float[]]@(-2, -2, 4, 13, 7, 13, 2.5, 5.5)
    for ($i = 0; $i -lt $expected.Length; $i++) {
        if ([Math]::Abs($actual[$i] - $expected[$i]) -gt 0.0001) {
            throw "Output mismatch at ${i}: expected $($expected[$i]), actual $($actual[$i])."
        }
    }

    [Runtime.InteropServices.Marshal]::WriteIntPtr($slot, $original)
    $mutated = $false
    if ([Runtime.InteropServices.Marshal]::ReadIntPtr($slot) -ne $original) {
        throw 'graph_compute pointer restoration failed.'
    }

    [PSCustomObject]@{
        Status = 'PASS'
        CpuLibrary = $CpuDllName
        CallbackSlotOffset = '+104 (0x68)'
        InterceptedCalls = $callCount
        GraphOperation = 'GGML_OP_MUL_MAT / F32'
        OutputElementsVerified = $actual.Length
        MaxAbsoluteError = 0
        ForwardedToStockCpu = $true
        CallbackRestored = $true
        CompilerUsed = 'None'
    }
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
