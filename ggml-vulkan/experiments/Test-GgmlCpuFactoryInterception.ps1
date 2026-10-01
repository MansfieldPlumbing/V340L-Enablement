<#
.SYNOPSIS
    Intercepts stock ggml CPU backend creation before a backend instance exists.

.DESCRIPTION
    Loads the stock CPU backend registration, replaces the CPU device's
    init_backend factory callback, creates a normal CPU backend through the
    public ggml device API, and verifies that the returned backend already has
    its graph_compute callback replaced. A real F32 MUL_MAT graph is forwarded
    through the captured stock callback, verified, and all mutated pointers and
    registry state are restored.

    This is the seam used to catch the CPU backend that a future llama context
    creates internally. No private llama context traversal is required.
#>

[CmdletBinding()]
param(
    [string] $LlamaBinDir = 'C:\bin\llama.cpp',
    [string] $CpuDllName = 'ggml-cpu-x64.dll',
    [switch] $Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([IntPtr]::Size -ne 8) { throw '64-bit PowerShell is required.' }

$interop = & (Join-Path $PSScriptRoot 'src\New-WindowsFunctionPointerBinder.ps1')
$blocks = [Collections.Generic.List[IntPtr]]::new()
$callbacks = [Collections.Generic.List[Delegate]]::new()
$context = [IntPtr]::Zero
$backend = [IntPtr]::Zero
$cpuRegistration = [IntPtr]::Zero
$cpuDevice = [IntPtr]::Zero
$factorySlot = [IntPtr]::Zero
$originalFactoryPointer = [IntPtr]::Zero
$backendGraphSlot = [IntPtr]::Zero
$originalGraphPointer = [IntPtr]::Zero
$factoryMutated = $false
$graphMutated = $false

function New-Block([int] $Bytes) {
    $pointer = [Runtime.InteropServices.Marshal]::AllocHGlobal($Bytes)
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new($Bytes), 0, $pointer, $Bytes)
    $blocks.Add($pointer)
    $pointer
}

function New-Callback([Type] $ReturnType, [Type[]] $ParameterTypes, [scriptblock] $Body) {
    $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
        [Reflection.AssemblyName]::new('V340L.FactoryCallback.' + [Guid]::NewGuid().ToString('N')),
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
    $delegate = [Management.Automation.LanguagePrimitives]::ConvertTo($Body, $type)
    $callbacks.Add($delegate)
    [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($delegate)
}

try {
    $env:PATH = "$LlamaBinDir;$env:PATH"
    $registryPath = Join-Path $LlamaBinDir 'ggml.dll'
    $basePath = Join-Path $LlamaBinDir 'ggml-base.dll'
    $cpuPath = Join-Path $LlamaBinDir $CpuDllName
    foreach ($path in @($registryPath, $basePath, $cpuPath)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Missing $path" }
    }
    $registryLibrary = $interop.LoadLibrary($registryPath)
    $baseLibrary = $interop.LoadLibrary($basePath)

    function Registry-Call([string] $Name, [Type] $ReturnType, [Type[]] $Parameters) {
        $interop.GetCall($interop.GetExport($registryLibrary, $Name), $ReturnType, $Parameters)
    }
    function Base-Call([string] $Name, [Type] $ReturnType, [Type[]] $Parameters) {
        $interop.GetCall($interop.GetExport($baseLibrary, $Name), $ReturnType, $Parameters)
    }

    $backendLoad = Registry-Call 'ggml_backend_load' ([IntPtr]) @([IntPtr])
    $backendUnload = Registry-Call 'ggml_backend_unload' ([void]) @([IntPtr])
    $deviceByType = Registry-Call 'ggml_backend_dev_by_type' ([IntPtr]) @([int])
    $deviceInit = Base-Call 'ggml_backend_dev_init' ([IntPtr]) @([IntPtr], [IntPtr])
    $backendFree = Base-Call 'ggml_backend_free' ([void]) @([IntPtr])
    $backendGraphCompute = Base-Call 'ggml_backend_graph_compute' ([int]) @([IntPtr], [IntPtr])
    $ggmlInit = Base-Call 'ggml_init' ([IntPtr]) @([IntPtr])
    $ggmlFree = Base-Call 'ggml_free' ([void]) @([IntPtr])
    $newTensor2d = Base-Call 'ggml_new_tensor_2d' ([IntPtr]) @([IntPtr], [int], [int64], [int64])
    $mulMat = Base-Call 'ggml_mul_mat' ([IntPtr]) @([IntPtr], [IntPtr], [IntPtr])
    $newGraph = Base-Call 'ggml_new_graph_custom' ([IntPtr]) @([IntPtr], [uint64], [bool])
    $buildForward = Base-Call 'ggml_build_forward_expand' ([void]) @([IntPtr], [IntPtr])
    $getData = Base-Call 'ggml_get_data' ([IntPtr]) @([IntPtr])

    $cpuPathAnsi = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($cpuPath)
    $blocks.Add($cpuPathAnsi)
    $cpuRegistration = $backendLoad.DynamicInvoke($cpuPathAnsi)
    if ($cpuRegistration -eq [IntPtr]::Zero) { throw "ggml_backend_load failed for $cpuPath" }
    $cpuDevice = $deviceByType.DynamicInvoke(0) # GGML_BACKEND_DEVICE_TYPE_CPU
    if ($cpuDevice -eq [IntPtr]::Zero) { throw 'Stock CPU device was not registered.' }

    # ggml_backend_device_i::init_backend is interface slot 5 at +40.
    $factorySlot = [IntPtr]::new($cpuDevice.ToInt64() + 40)
    $originalFactoryPointer = [Runtime.InteropServices.Marshal]::ReadIntPtr($factorySlot)
    if ($originalFactoryPointer -eq [IntPtr]::Zero) { throw 'CPU init_backend callback is null.' }
    $originalFactoryCall = $interop.GetCall(
        $originalFactoryPointer, ([IntPtr]), @([IntPtr], [IntPtr]))

    $state = [hashtable]::Synchronized(@{
        FactoryCalls = 0
        GraphCalls = 0
        Error = $null
        Backend = [IntPtr]::Zero
        OriginalGraphPointer = [IntPtr]::Zero
        OriginalGraphCall = $null
    })

    $graphCallbackPointer = New-Callback ([int]) @([IntPtr], [IntPtr]) {
        param([IntPtr] $CallbackBackend, [IntPtr] $Graph)
        $state.GraphCalls++
        try {
            if ($CallbackBackend -ne $state.Backend) {
                throw 'graph_compute received an unexpected backend pointer.'
            }
            if ($null -eq $state.OriginalGraphCall) {
                throw 'Original graph_compute call was not bound.'
            }
            return $state.OriginalGraphCall.DynamicInvoke($CallbackBackend, $Graph)
        } catch {
            $state.Error = $_.Exception.ToString()
            return 1
        }
    }

    $factoryCallbackPointer = New-Callback ([IntPtr]) @([IntPtr], [IntPtr]) {
        param([IntPtr] $Device, [IntPtr] $Parameters)
        $state.FactoryCalls++
        try {
            $created = $originalFactoryCall.DynamicInvoke($Device, $Parameters)
            if ($created -eq [IntPtr]::Zero) { throw 'Stock CPU factory returned null.' }
            $slot = [IntPtr]::new($created.ToInt64() + 0x68)
            $captured = [Runtime.InteropServices.Marshal]::ReadIntPtr($slot)
            if ($captured -eq [IntPtr]::Zero) { throw 'Created backend graph_compute is null.' }
            $state.Backend = $created
            $state.OriginalGraphPointer = $captured
            [Runtime.InteropServices.Marshal]::WriteIntPtr($slot, $graphCallbackPointer)
            return $created
        } catch {
            $state.Error = $_.Exception.ToString()
            return [IntPtr]::Zero
        }
    }

    [Runtime.InteropServices.Marshal]::WriteIntPtr($factorySlot, $factoryCallbackPointer)
    $factoryMutated = $true
    $backend = $deviceInit.DynamicInvoke($cpuDevice, [IntPtr]::Zero)
    if ($backend -eq [IntPtr]::Zero) { throw "Intercepted CPU backend creation failed. $($state.Error)" }
    if ($state.FactoryCalls -ne 1 -or $state.Backend -ne $backend) {
        throw 'CPU backend factory interception did not observe the created backend.'
    }
    $backendGraphSlot = [IntPtr]::new($backend.ToInt64() + 0x68)
    $originalGraphPointer = $state.OriginalGraphPointer
    if ([Runtime.InteropServices.Marshal]::ReadIntPtr($backendGraphSlot) -ne $graphCallbackPointer) {
        throw 'Factory did not install the graph_compute callback.'
    }
    $graphMutated = $true
    $state.OriginalGraphCall = $interop.GetCall(
        $originalGraphPointer, ([int]), @([IntPtr], [IntPtr]))

    $initParameters = New-Block 24
    [Runtime.InteropServices.Marshal]::WriteInt64($initParameters, 0, 4MB)
    $context = $ggmlInit.DynamicInvoke($initParameters)
    if ($context -eq [IntPtr]::Zero) { throw 'ggml_init returned null.' }

    $a = $newTensor2d.DynamicInvoke($context, 0, [int64]3, [int64]2)
    $b = $newTensor2d.DynamicInvoke($context, 0, [int64]3, [int64]4)
    $aValues = [float[]]@(1, 2, 3, 4, 5, 6)
    $bValues = [float[]]@(1, 0, -1, 2, 1, 0, -1, 1, 2, 0.5, -0.5, 1)
    [Runtime.InteropServices.Marshal]::Copy($aValues, 0, $getData.DynamicInvoke($a), $aValues.Length)
    [Runtime.InteropServices.Marshal]::Copy($bValues, 0, $getData.DynamicInvoke($b), $bValues.Length)
    $output = $mulMat.DynamicInvoke($context, $a, $b)
    $graph = $newGraph.DynamicInvoke($context, [uint64]32, $false)
    [void]$buildForward.DynamicInvoke($graph, $output)

    $status = $backendGraphCompute.DynamicInvoke($backend, $graph)
    if ($status -ne 0) { throw "graph_compute returned $status. $($state.Error)" }
    if ($state.GraphCalls -ne 1) { throw "Expected one graph callback; observed $($state.GraphCalls)." }
    $actual = [float[]]::new(8)
    [Runtime.InteropServices.Marshal]::Copy($getData.DynamicInvoke($output), $actual, 0, $actual.Length)
    $expected = [float[]]@(-2, -2, 4, 13, 7, 13, 2.5, 5.5)
    for ($i = 0; $i -lt $expected.Length; $i++) {
        if ([Math]::Abs($actual[$i] - $expected[$i]) -gt 0.0001) {
            throw "Output mismatch at ${i}: expected $($expected[$i]), actual $($actual[$i])."
        }
    }

    [Runtime.InteropServices.Marshal]::WriteIntPtr($backendGraphSlot, $originalGraphPointer)
    $graphMutated = $false
    [Runtime.InteropServices.Marshal]::WriteIntPtr($factorySlot, $originalFactoryPointer)
    $factoryMutated = $false

    $result = [PSCustomObject]@{
        Status = 'PASS'
        CpuLibrary = $CpuDllName
        FactorySlotOffset = '+40 (0x28)'
        GraphCallbackSlotOffset = '+104 (0x68)'
        FactoryCalls = $state.FactoryCalls
        GraphCalls = $state.GraphCalls
        OutputElementsVerified = $actual.Length
        FactoryRestored = $true
        GraphCallbackRestored = $true
        CompilerUsed = 'None'
    }
    if ($Json) { $result | ConvertTo-Json -Compress } else { $result }
}
finally {
    if ($graphMutated -and $backendGraphSlot -ne [IntPtr]::Zero -and $originalGraphPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::WriteIntPtr($backendGraphSlot, $originalGraphPointer)
    }
    if ($factoryMutated -and $factorySlot -ne [IntPtr]::Zero -and $originalFactoryPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::WriteIntPtr($factorySlot, $originalFactoryPointer)
    }
    if ($backend -ne [IntPtr]::Zero) {
        try { [void]$backendFree.DynamicInvoke($backend) } catch { }
    }
    if ($context -ne [IntPtr]::Zero) {
        try { [void]$ggmlFree.DynamicInvoke($context) } catch { }
    }
    if ($cpuRegistration -ne [IntPtr]::Zero) {
        try { [void]$backendUnload.DynamicInvoke($cpuRegistration) } catch { }
    }
    $callbacks.Clear()
    for ($i = $blocks.Count - 1; $i -ge 0; $i--) {
        if ($blocks[$i] -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::FreeHGlobal($blocks[$i])
        }
    }
    $interop.Dispose()
}
