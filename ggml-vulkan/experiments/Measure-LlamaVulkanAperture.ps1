<#
.SYNOPSIS
    Introspects and measures the V340L RyuJIT aperture pipe against stock llama.cpp.

.DESCRIPTION
    INSTRUMENTATION PROOF ONLY. This script demonstrates the aperture mechanism
    provided by this repository against a pinned stock llama.cpp Vulkan build.
    It is not the durable runtime architecture and Vulkan is not a production
    dependency of that roadmap.

    Mutates the live stock ggml backend interfaces from PowerShell. Selected
    cross-die cpy_tensor_async calls queue a producer blit into a permanent
    imported aperture and switch the real destination tensor to the matching
    imported mailbox offset. The consumer graph runs through its stock callback.

    There is no polling, added host wait, consumer blit, stock blocking-copy
    fallback, generated C#, or modification to llama.cpp. This bounded run
    does not recycle mailbox offsets; capacity exhaustion ends the process.
#>

[CmdletBinding()]
param(
    [ValidateSet('Compare', 'Aperture', 'Generate')]
    [string] $Scenario = 'Compare',
    [string] $LlamaBinDir = 'C:\bin\llama.cpp',
    [string] $Model = 'C:\Models\gemma-4-E4B-it-Q4_K_M.gguf',
    [string] $DeviceSelection = 'Vulkan1/Vulkan2',
    [string] $TensorSplit = '1/1',
    [int] $Prompt = 8,
    [int] $Generation = 4,
    [int] $Repetitions = 1,
    [uint64] $ApertureBytes = 0,
    [switch] $WarmupBeforeMeasure,
    [string] $OutputPrompt = '',
    [int] $OutputTokens = 32,
    [switch] $InternalChild,
    [string] $MetadataPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([IntPtr]::Size -ne 8) { throw '64-bit PowerShell is required.' }
if (-not (Test-Path -LiteralPath $Model -PathType Leaf)) { throw "Model not found: $Model" }
foreach ($name in @('ggml.dll', 'ggml-base.dll', 'llama-bench-impl.dll')) {
    $path = Join-Path $LlamaBinDir $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing runtime file: $path" }
}

# This proof mutates pinned private layouts. Refuse any unverified build/model
# instead of pretending ABI compatibility or risking an oversized payload.
$pinnedBuild = 11223
$pinnedCommit = '4da633776'
$modelProfiles = @(
    [PSCustomObject]@{
        Name = 'Gemma 4 E4B Q4_K_M'
        FileBytes = 4977169088L
        Sha256 = 'DFF0FFBA4C90B4082D70214D53CE9504A28D4D8D998276DCB3B8881A656C742A'
        # Batched prompt handoff: 5 MiB output plus twenty 512 KiB inputs and
        # small control tensors must remain live until the consumer graph.
        ApertureBytes = [uint64]32MB
    },
    [PSCustomObject]@{
        Name = 'Muse Glimmer 30B UD-Q2_K_XL'
        FileBytes = 12444212256L
        Sha256 = '3D63A1DAFF23FDC2A6927316151E855CACFFE89B5CB9B9397A5AEC0C412EC08D'
        ApertureBytes = [uint64]32MB
    }
)
$modelFileBytes = (Get-Item -LiteralPath $Model).Length
$modelProfile = $modelProfiles | Where-Object FileBytes -eq $modelFileBytes | Select-Object -First 1
if ($null -eq $modelProfile) { throw "Unsupported model size: $modelFileBytes bytes." }
if (-not $InternalChild) {
    $actualModelHash = (Get-FileHash -LiteralPath $Model -Algorithm SHA256).Hash
    if ($actualModelHash -ne $modelProfile.Sha256) {
        throw "Unsupported model hash: $actualModelHash"
    }
    $versionText = (& (Join-Path $LlamaBinDir 'llama-bench.exe') --version 2>&1) -join [Environment]::NewLine
    $versionMatch = [Text.RegularExpressions.Regex]::Match(
        $versionText, 'build\s+(\d+),\s+commit\s+([0-9a-fA-F]+)')
    if (-not $versionMatch.Success -or
        [int]$versionMatch.Groups[1].Value -ne $pinnedBuild -or
        $versionMatch.Groups[2].Value -ne $pinnedCommit) {
        throw "Unsupported llama.cpp build. Required build $pinnedBuild commit $pinnedCommit."
    }
}
if ($ApertureBytes -eq 0) { $ApertureBytes = [uint64]$modelProfile.ApertureBytes }
if ($ApertureBytes -lt [uint64]$modelProfile.ApertureBytes) {
    throw "$($modelProfile.Name) requires at least $($modelProfile.ApertureBytes) aperture bytes."
}

if ($Scenario -eq 'Compare') {
    $compareNames = @($DeviceSelection.Split('/'))
    if ($compareNames.Count -ne 2 -or $compareNames.Where({ [string]::IsNullOrWhiteSpace($_) }).Count) {
        throw 'The comparison requires exactly two selected devices.'
    }
    $benchExe = Join-Path $LlamaBinDir 'llama-bench.exe'
    if (-not (Test-Path -LiteralPath $benchExe -PathType Leaf)) { throw "Missing runtime file: $benchExe" }

    function Invoke-StockBenchmark([string] $Devices, [string] $Split) {
        $raw = & $benchExe @(
            '-m', $Model, '-ngl', '999', '-dev', $Devices, '-sm', 'layer', '-ts', $Split,
            '-ncmoe', '0', '-ctk', 'q4_0', '-ctv', 'q4_0', '-fa', 'on', '--no-host', '1',
            '-p', "$Prompt", '-n', "$Generation", '-r', "$Repetitions", '-o', 'json'
        )
        if ($LASTEXITCODE -ne 0) { throw "Stock llama-bench failed for $Devices with $LASTEXITCODE." }
        ($raw -join [Environment]::NewLine) | ConvertFrom-Json
    }

    $stockSingle = @(Invoke-StockBenchmark $compareNames[0] '1')
    $stockPair = @(Invoke-StockBenchmark $DeviceSelection $TensorSplit)

    $pwsh = (Get-Process -Id $PID).Path
    $metadataFile = Join-Path ([IO.Path]::GetTempPath()) ('v340l-aperture-' + [Guid]::NewGuid().ToString('N') + '.json')
    $stderrFile = Join-Path ([IO.Path]::GetTempPath()) ('v340l-aperture-' + [Guid]::NewGuid().ToString('N') + '.err')
    try {
        $childArguments = @(
            '-NoProfile', '-File', $PSCommandPath,
            '-Scenario', 'Aperture', '-LlamaBinDir', $LlamaBinDir, '-Model', $Model,
            '-DeviceSelection', $DeviceSelection, '-TensorSplit', $TensorSplit,
            '-Prompt', "$Prompt", '-Generation', "$Generation", '-Repetitions', "$Repetitions",
            '-ApertureBytes', "$ApertureBytes", '-InternalChild', '-MetadataPath', $metadataFile
        )
        $childRaw = & $pwsh @childArguments 2>$stderrFile
        if ($LASTEXITCODE -ne 0) {
            $childError = if (Test-Path -LiteralPath $stderrFile) { Get-Content -LiteralPath $stderrFile -Raw } else { '' }
            throw "Aperture child failed with $LASTEXITCODE.`n$childError"
        }
        $childText = $childRaw -join [Environment]::NewLine
        $jsonMatch = [Text.RegularExpressions.Regex]::Match($childText, '(?s)\[\s*\{.*\}\s*\]')
        if (-not $jsonMatch.Success -or -not (Test-Path -LiteralPath $metadataFile)) {
            throw "Could not parse the aperture child receipt.`n$childText"
        }
        $apertureRows = @($jsonMatch.Value | ConvertFrom-Json)
        $apertureMeta = Get-Content -LiteralPath $metadataFile -Raw | ConvertFrom-Json
    } finally {
        Remove-Item -LiteralPath $metadataFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }

    function New-ComparisonRow([string] $Name, [string] $Devices, [object[]] $Rows, [bool] $Approximate) {
        $promptRow = $Rows | Where-Object n_prompt -eq $Prompt | Select-Object -First 1
        $generationRow = $Rows | Where-Object n_gen -eq $Generation | Select-Object -First 1
        if ($null -eq $promptRow -or $null -eq $generationRow) {
            throw "Incomplete benchmark rows for $Name."
        }
        [PSCustomObject]@{
            Scenario = $Name
            Devices = $Devices
            PromptTokensPerSecond = [Math]::Round([double]$promptRow.avg_ts, 3)
            GenerationTokensPerSecond = [Math]::Round([double]$generationRow.avg_ts, 3)
            MillisecondsPerToken = [Math]::Round(1000.0 / [double]$generationRow.avg_ts, 3)
            ApproximatePayload = $Approximate
        }
    }

    $comparison = @(
        New-ComparisonRow 'Stock single die' $compareNames[0] $stockSingle $false
        New-ComparisonRow 'Stock two dies' $DeviceSelection $stockPair $false
        New-ComparisonRow 'Mailbox switch (output unverified)' $DeviceSelection $apertureRows $true
    )
    $stockPairRate = $comparison[1].GenerationTokensPerSecond
    $singleRate = $comparison[0].GenerationTokensPerSecond
    foreach ($row in $comparison) {
        $row | Add-Member NoteProperty SpeedupVsStockPair ([Math]::Round(
            $row.GenerationTokensPerSecond / $stockPairRate, 3))
        $row | Add-Member NoteProperty SpeedupVsSingleDie ([Math]::Round(
            $row.GenerationTokensPerSecond / $singleRate, 3))
    }
    $comparison | Format-Table -AutoSize | Out-Host
    [PSCustomObject]@{
        Status = 'PASS'
        BuildCommit = $apertureRows[0].build_commit
        Model = $apertureRows[0].model_type
        PromptTokens = $Prompt
        GeneratedTokens = $Generation
        Repetitions = $Repetitions
        HandledHandoffs = [long]$apertureMeta.HandledHandoffs
        HotPathPowerShell = $false
        BatchedProducerWaits = [long]$apertureMeta.BatchedProducerWaits
        BlockingFallback = $false
        PayloadContract = 'approximate mailbox read; semantic output must be checked separately'
    } | Format-List | Out-Host
    return
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$interop = & (Join-Path $repositoryRoot 'src\New-WindowsFunctionPointerBinder.ps1')
$callbacks = [Collections.Generic.List[Delegate]]::new()
$tensorBlocks = [Collections.Generic.List[IntPtr]]::new()
$bridgeBuffers = [Collections.Generic.List[IntPtr]]::new()
$patchedFactories = [Collections.Generic.List[object]]::new()
$oldPath = $env:PATH
$aperture = [IntPtr]::Zero
$pendingSources = [IntPtr]::Zero
$pendingDestinations = [IntPtr]::Zero
$pendingOffsets = [IntPtr]::Zero

function Add-Pointer([IntPtr] $Pointer, [long] $Offset) {
    [IntPtr]::new($Pointer.ToInt64() + $Offset)
}

function Pointer-Key([IntPtr] $Pointer) {
    $Pointer.ToInt64().ToString('X16')
}

function New-NativeDelegateType([Type] $ReturnType, [Type[]] $ParameterTypes) {
    $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
        [Reflection.AssemblyName]::new('V340L.NativeDelegate.' + [Guid]::NewGuid().ToString('N')),
        [Reflection.Emit.AssemblyBuilderAccess]::Run)
    $module = $assembly.DefineDynamicModule('NativeDelegate')
    $builder = $module.DefineType('NativeCallback', 'Public,Sealed', [MulticastDelegate])
    [void]$builder.DefineConstructor(
        'Public,HideBySig,RTSpecialName',
        [Reflection.CallingConventions]::Standard,
        @([object], [IntPtr])).SetImplementationFlags('Runtime,Managed')
    [void]$builder.DefineMethod(
        'Invoke',
        'Public,HideBySig,NewSlot,Virtual',
        $ReturnType,
        $ParameterTypes).SetImplementationFlags('Runtime,Managed')
    [void]$builder.SetCustomAttribute([Reflection.Emit.CustomAttributeBuilder]::new(
        [Runtime.InteropServices.UnmanagedFunctionPointerAttribute].GetConstructor(
            @([Runtime.InteropServices.CallingConvention])),
        @([Runtime.InteropServices.CallingConvention]::Cdecl)))
    $builder.CreateTypeInfo().AsType()
}

function New-BridgeTensor([IntPtr] $Buffer, [Delegate] $TensorAlloc) {
    $pointer = [Runtime.InteropServices.Marshal]::AllocHGlobal(512)
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new(512), 0, $pointer, 512)
    $tensorBlocks.Add($pointer)
    $length = [long]$ApertureBytes - 0x1000
    # One GGML_TYPE_I8 tensor spans the mailbox. The Vulkan copy uses the source
    # tensor's byte count; this destination layout is only fixed buffer metadata.
    [Runtime.InteropServices.Marshal]::WriteInt32($pointer, 0, 24)
    [Runtime.InteropServices.Marshal]::WriteInt64($pointer, 16, $length)
    [Runtime.InteropServices.Marshal]::WriteInt64($pointer, 24, 1)
    [Runtime.InteropServices.Marshal]::WriteInt64($pointer, 32, 1)
    [Runtime.InteropServices.Marshal]::WriteInt64($pointer, 40, 1)
    [Runtime.InteropServices.Marshal]::WriteInt64($pointer, 48, 1)
    [Runtime.InteropServices.Marshal]::WriteInt64($pointer, 56, $length)
    [Runtime.InteropServices.Marshal]::WriteInt64($pointer, 64, $length)
    [Runtime.InteropServices.Marshal]::WriteInt64($pointer, 72, $length)
    $status = [int]$TensorAlloc.DynamicInvoke($Buffer, $pointer, [IntPtr]::new(0x1000))
    if ($status -ne 0) { throw "Bridge tensor allocation failed with status $status." }
    $pointer
}

function New-RyuJitBatchedApertureCallbacks(
    [Type] $CopyDelegateType,
    [Type] $GraphDelegateType,
    [Type] $SyncDelegateType,
    [IntPtr] $NBytesPointer,
    [IntPtr] $MemcpyPointer,
    [IntPtr] $PendingSources,
    [IntPtr] $PendingDestinations,
    [IntPtr] $PendingOffsets,
    [uint64] $Capacity
) {
    $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
        [Reflection.AssemblyName]::new('V340L.RyuJitBatchedAperture.' + [Guid]::NewGuid().ToString('N')),
        [Reflection.Emit.AssemblyBuilderAccess]::Run)
    $module = $assembly.DefineDynamicModule('BatchedAperture')
    $builder = $module.DefineType('BatchedAperture', 'Public,Abstract,Sealed')
    $fields = @{}
    foreach ($name in @(
        'SourceBackend', 'DestinationBackend', 'SourceCopy', 'SourceSync',
        'SourceBridge', 'DestinationBridge', 'DestinationBuffer',
        'OriginalDestination', 'OriginalGraph', 'OriginalSync',
        'NBytes', 'Memcpy', 'PendingSources', 'PendingDestinations', 'PendingOffsets'
    )) {
        $fields[$name] = $builder.DefineField($name, [IntPtr], 'Public,Static')
    }
    $fields.ApertureBytes = $builder.DefineField('ApertureBytes', [uint64], 'Public,Static')
    $fields.Cursor = $builder.DefineField('Cursor', [long], 'Public,Static')
    $fields.PendingCount = $builder.DefineField('PendingCount', [int], 'Public,Static')
    $fields.DestinationKnownIdle = $builder.DefineField('DestinationKnownIdle', [int], 'Public,Static')
    $fields.Handled = $builder.DefineField('Handled', [long], 'Public,Static')
    $fields.ConsumerBlits = $builder.DefineField('ConsumerBlits', [long], 'Public,Static')
    $fields.BatchedProducerWaits = $builder.DefineField('BatchedProducerWaits', [long], 'Public,Static')
    $fields.SkippedIdleSyncs = $builder.DefineField('SkippedIdleSyncs', [long], 'Public,Static')
    $fields.Failed = $builder.DefineField('Failed', [int], 'Public,Static')

    $copyMethod = $builder.DefineMethod(
        'CopyTensorAsync', 'Public,Static', [bool],
        @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
    $il = $copyMethod.GetILGenerator()
    $stock = $il.DefineLabel()
    $failed = $il.DefineLabel()
    $capacityFailed = $il.DefineLabel()
    $index = $il.DeclareLocal([int])
    $bytes = $il.DeclareLocal([uint64])
    $cursor = $il.DeclareLocal([long])
    $next = $il.DeclareLocal([long])

    # This callback is installed only on die 2. Other traffic keeps stock behavior.
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.SourceBackend)
    $il.Emit([Reflection.Emit.OpCodes]::Bne_Un, $stock)

    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.PendingCount)
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $index)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $index)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 4096)
    $il.Emit([Reflection.Emit.OpCodes]::Bge, $capacityFailed)

    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.NBytes)
    $il.EmitCalli(
        [Reflection.Emit.OpCodes]::Calli,
        [Runtime.InteropServices.CallingConvention]::Cdecl,
        [uint64], @([IntPtr]))
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $bytes)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.Cursor)
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $cursor)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $cursor)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $bytes)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 255)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_U8)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I8, [long]-256)
    $il.Emit([Reflection.Emit.OpCodes]::And)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $next)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $next)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.ApertureBytes)
    $il.Emit([Reflection.Emit.OpCodes]::Bgt_Un, $capacityFailed)

    # Repoint the reusable producer bridge metadata to this batch's unique slot.
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.SourceBridge)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 248)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $cursor)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Stind_I)

    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.SourceBridge)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.SourceCopy)
    $il.EmitCalli(
        [Reflection.Emit.OpCodes]::Calli,
        [Runtime.InteropServices.CallingConvention]::Cdecl,
        [bool],
        @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
    $il.Emit([Reflection.Emit.OpCodes]::Brfalse, $failed)

    # Switch the destination tensor's storage to the consumer's imported view.
    # Its shape remains unchanged; only the backing buffer and offset change.
    foreach ($metadata in @(
        @{ Offset = 8; Kind = 'Pointer'; Field = $fields.DestinationBuffer },
        @{ Offset = 232; Kind = 'ZeroPointer' },
        @{ Offset = 240; Kind = 'ZeroInt64' },
        @{ Offset = 248; Kind = 'Offset' },
        @{ Offset = 320; Kind = 'ZeroPointer' }
    )) {
        $il.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
        $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, $metadata.Offset)
        $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
        $il.Emit([Reflection.Emit.OpCodes]::Add)
        switch ($metadata.Kind) {
            'Pointer' { $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $metadata.Field); $il.Emit([Reflection.Emit.OpCodes]::Stind_I) }
            'ZeroPointer' { $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0); $il.Emit([Reflection.Emit.OpCodes]::Conv_I); $il.Emit([Reflection.Emit.OpCodes]::Stind_I) }
            'ZeroInt64' { $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0); $il.Emit([Reflection.Emit.OpCodes]::Conv_I8); $il.Emit([Reflection.Emit.OpCodes]::Stind_I8) }
            'Offset' { $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $cursor); $il.Emit([Reflection.Emit.OpCodes]::Conv_I); $il.Emit([Reflection.Emit.OpCodes]::Stind_I) }
        }
    }

    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $next)
    $il.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.Cursor)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.Handled)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I8)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.Handled)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
    $il.Emit([Reflection.Emit.OpCodes]::Ret)

    $il.MarkLabel($capacityFailed)
    $il.MarkLabel($failed)
    # A false return enters ggml's blocking fallback. Terminate this isolated
    # proof process on failure instead of silently changing mechanisms.
    $il.Emit([Reflection.Emit.OpCodes]::Ldstr, 'V340L aperture copy failed or mailbox capacity exhausted')
    $il.Emit([Reflection.Emit.OpCodes]::Call, [Environment].GetMethod('FailFast', [Type[]]@([string])))
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
    $il.Emit([Reflection.Emit.OpCodes]::Ret)

    $il.MarkLabel($stock)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.OriginalDestination)
    $il.EmitCalli(
        [Reflection.Emit.OpCodes]::Calli,
        [Runtime.InteropServices.CallingConvention]::Cdecl,
        [bool],
        @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
    $il.Emit([Reflection.Emit.OpCodes]::Ret)

    $type = $builder.CreateTypeInfo().AsType()
    $type.GetField('NBytes').SetValue($null, $NBytesPointer)
    $type.GetField('Memcpy').SetValue($null, $MemcpyPointer)
    $type.GetField('PendingSources').SetValue($null, $PendingSources)
    $type.GetField('PendingDestinations').SetValue($null, $PendingDestinations)
    $type.GetField('PendingOffsets').SetValue($null, $PendingOffsets)
    $type.GetField('ApertureBytes').SetValue($null, $Capacity)
    $type.GetField('Cursor').SetValue($null, [long]0x1000)
    $methodMap = @(
        @{ Name = 'CopyTensorAsync'; DelegateType = $CopyDelegateType }
    )
    $result = @{ Type = $type }
    foreach ($entry in $methodMap) {
        $methodInfo = $type.GetMethod($entry.Name)
        [Runtime.CompilerServices.RuntimeHelpers]::PrepareMethod($methodInfo.MethodHandle)
        $delegate = [Delegate]::CreateDelegate($entry.DelegateType, $methodInfo)
        $callbacks.Add($delegate)
        $result[$entry.Name + 'Delegate'] = $delegate
        $result[$entry.Name + 'Pointer'] = [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($delegate)
    }
    [PSCustomObject]@{
        Type = $type
        CopyPointer = $result.CopyTensorAsyncPointer
    }
}

function New-RyuJitBackendFactory(
    [Type] $DelegateType,
    [IntPtr] $OriginalFactory,
    [Type] $ApertureType,
    [int] $DeviceSlot,
    [IntPtr] $ReplacementCopy
) {
    $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
        [Reflection.AssemblyName]::new('V340L.RyuJitFactory.' + [Guid]::NewGuid().ToString('N')),
        [Reflection.Emit.AssemblyBuilderAccess]::Run)
    $module = $assembly.DefineDynamicModule('Factory')
    $builder = $module.DefineType('Factory', 'Public,Abstract,Sealed')
    $originalFactoryField = $builder.DefineField('OriginalFactory', [IntPtr], 'Public,Static')
    $replacementCopyField = $builder.DefineField('ReplacementCopy', [IntPtr], 'Public,Static')
    $method = $builder.DefineMethod(
        'InitBackend', 'Public,Static', [IntPtr], @([IntPtr], [IntPtr]))
    $il = $method.GetILGenerator()
    $backendLocal = $il.DeclareLocal([IntPtr])
    $copySlotLocal = $il.DeclareLocal([IntPtr])
    $originalCopyLocal = $il.DeclareLocal([IntPtr])
    $returnZero = $il.DefineLabel()

    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $originalFactoryField)
    $il.EmitCalli(
        [Reflection.Emit.OpCodes]::Calli,
        [Runtime.InteropServices.CallingConvention]::Cdecl,
        [IntPtr], @([IntPtr], [IntPtr]))
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $backendLocal)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $backendLocal)
    $il.Emit([Reflection.Emit.OpCodes]::Brfalse, $returnZero)

    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $backendLocal)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x38)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $copySlotLocal)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $copySlotLocal)
    $il.Emit([Reflection.Emit.OpCodes]::Ldind_I)
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $originalCopyLocal)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $originalCopyLocal)
    $il.Emit([Reflection.Emit.OpCodes]::Brfalse, $returnZero)

    if ($DeviceSlot -eq 0) {
        $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $backendLocal)
        $il.Emit([Reflection.Emit.OpCodes]::Stsfld, $ApertureType.GetField('SourceBackend'))
        $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $originalCopyLocal)
        $il.Emit([Reflection.Emit.OpCodes]::Stsfld, $ApertureType.GetField('SourceCopy'))
    } else {
        $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $backendLocal)
        $il.Emit([Reflection.Emit.OpCodes]::Stsfld, $ApertureType.GetField('DestinationBackend'))
        $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $originalCopyLocal)
        $il.Emit([Reflection.Emit.OpCodes]::Stsfld, $ApertureType.GetField('OriginalDestination'))
        $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $copySlotLocal)
        $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $replacementCopyField)
        $il.Emit([Reflection.Emit.OpCodes]::Stind_I)
    }
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $backendLocal)
    $il.Emit([Reflection.Emit.OpCodes]::Ret)
    $il.MarkLabel($returnZero)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Ret)

    $type = $builder.CreateTypeInfo().AsType()
    $type.GetField('OriginalFactory').SetValue($null, $OriginalFactory)
    $type.GetField('ReplacementCopy').SetValue($null, $ReplacementCopy)
    $methodInfo = $type.GetMethod('InitBackend')
    [Runtime.CompilerServices.RuntimeHelpers]::PrepareMethod($methodInfo.MethodHandle)
    $delegate = [Delegate]::CreateDelegate($DelegateType, $methodInfo)
    $callbacks.Add($delegate)
    [PSCustomObject]@{
        Type = $type
        Delegate = $delegate
        Pointer = [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($delegate)
    }
}

$selectedNames = @($DeviceSelection.Split('/'))
if ($selectedNames.Count -ne 2 -or $selectedNames.Where({ [string]::IsNullOrWhiteSpace($_) }).Count) {
    throw 'The unsynchronized aperture proof requires exactly two selected devices.'
}
$deviceName = $null
$deviceDescription = $null
$bufferFromHost = $null
$bufferFree = $null
$tensorAlloc = $null
$tensorBytes = $null
$bench = $null
$virtualFree = $null
$apertureCallbacks = $null

function Get-DeviceName([IntPtr] $Device) {
    [Runtime.InteropServices.Marshal]::PtrToStringUTF8($deviceName.DynamicInvoke($Device))
}

try {
    $resolvedBin = (Resolve-Path -LiteralPath $LlamaBinDir).Path
    $env:PATH = "$resolvedBin;$oldPath"
    $registryLibrary = $interop.LoadLibrary((Join-Path $resolvedBin 'ggml.dll'))
    $baseLibrary = $interop.LoadLibrary((Join-Path $resolvedBin 'ggml-base.dll'))
    $benchLibrary = $interop.LoadLibrary((Join-Path $resolvedBin 'llama-bench-impl.dll'))

    function Registry-Call([string] $Name, [Type] $ReturnType, [Type[]] $Parameters) {
        $interop.GetCall($interop.GetExport($registryLibrary, $Name), $ReturnType, $Parameters)
    }
    function Base-Call([string] $Name, [Type] $ReturnType, [Type[]] $Parameters) {
        $interop.GetCall($interop.GetExport($baseLibrary, $Name), $ReturnType, $Parameters)
    }

    $loadAll = Registry-Call 'ggml_backend_load_all_from_path' ([void]) @([IntPtr])
    $deviceCount = Registry-Call 'ggml_backend_dev_count' ([uint64]) @()
    $deviceGet = Registry-Call 'ggml_backend_dev_get' ([IntPtr]) @([uint64])
    $deviceName = Base-Call 'ggml_backend_dev_name' ([IntPtr]) @([IntPtr])
    $deviceDescription = Base-Call 'ggml_backend_dev_description' ([IntPtr]) @([IntPtr])
    $bufferFromHost = Base-Call 'ggml_backend_dev_buffer_from_host_ptr' ([IntPtr]) @([IntPtr], [IntPtr], [uint64], [uint64])
    $bufferFree = Base-Call 'ggml_backend_buffer_free' ([void]) @([IntPtr])
    $tensorAlloc = Base-Call 'ggml_backend_tensor_alloc' ([int]) @([IntPtr], [IntPtr], [IntPtr])
    $tensorBytesPointer = $interop.GetExport($baseLibrary, 'ggml_nbytes')
    $crtLibrary = $interop.LoadLibrary('ucrtbase.dll')
    $memcpyPointer = $interop.GetExport($crtLibrary, 'memcpy')
    $virtualAlloc = $interop.GetExportCall('kernel32.dll', 'VirtualAlloc', ([IntPtr]), @([IntPtr], [uint64], [uint32], [uint32]))
    $virtualFree = $interop.GetExportCall('kernel32.dll', 'VirtualFree', ([bool]), @([IntPtr], [uint64], [uint32]))
    $bench = $interop.GetCall(
        $interop.GetExport($benchLibrary, '?llama_bench@@YAHHPEAPEAD@Z'),
        ([int]), @([int], [IntPtr]))
    $entryPoint = $bench

    $aperture = $virtualAlloc.DynamicInvoke(
        [IntPtr]::Zero, [uint64]$ApertureBytes, [uint32]0x3000, [uint32]4)
    if ($aperture -eq [IntPtr]::Zero) { throw 'VirtualAlloc failed for the activation mailbox.' }

    $pendingSources = [Runtime.InteropServices.Marshal]::AllocHGlobal(4096 * [IntPtr]::Size)
    $pendingDestinations = [Runtime.InteropServices.Marshal]::AllocHGlobal(4096 * [IntPtr]::Size)
    $pendingOffsets = [Runtime.InteropServices.Marshal]::AllocHGlobal(4096 * 8)

    $asyncDelegateType = New-NativeDelegateType ([bool]) @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
    $graphDelegateType = New-NativeDelegateType ([int]) @([IntPtr], [IntPtr])
    $syncDelegateType = New-NativeDelegateType ([void]) @([IntPtr])
    $initDelegateType = New-NativeDelegateType ([IntPtr]) @([IntPtr], [IntPtr])
    $apertureCallbacks = New-RyuJitBatchedApertureCallbacks `
        $asyncDelegateType $graphDelegateType $syncDelegateType `
        $tensorBytesPointer $memcpyPointer `
        $pendingSources $pendingDestinations $pendingOffsets $ApertureBytes
    $apertureType = $apertureCallbacks.Type

    $pathPointer = [Runtime.InteropServices.Marshal]::StringToCoTaskMemUTF8($resolvedBin)
    try { $loadAll.DynamicInvoke($pathPointer) } finally { [Runtime.InteropServices.Marshal]::FreeCoTaskMem($pathPointer) }

    $found = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $count = [uint64]$deviceCount.DynamicInvoke()
    for ([uint64]$deviceOrdinal = 0; $deviceOrdinal -lt $count; $deviceOrdinal++) {
        $device = $deviceGet.DynamicInvoke($deviceOrdinal)
        $name = Get-DeviceName $device
        $deviceSlot = -1
        for ($candidateSlot = 0; $candidateSlot -lt 2; $candidateSlot++) {
            if ([string]::Equals($name, $selectedNames[$candidateSlot], [StringComparison]::OrdinalIgnoreCase)) {
                $deviceSlot = $candidateSlot
                break
            }
        }
        if ($deviceSlot -lt 0) { continue }
        $description = [Runtime.InteropServices.Marshal]::PtrToStringUTF8($deviceDescription.DynamicInvoke($device))
        if (-not $name.StartsWith('Vulkan', [StringComparison]::OrdinalIgnoreCase) -or
            $description.IndexOf('V340', [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "Selected device is not a V340 Vulkan die: $name / $description"
        }
        $slot = Add-Pointer $device 0x28
        $originalPointer = [Runtime.InteropServices.Marshal]::ReadIntPtr($slot)
        if ($originalPointer -eq [IntPtr]::Zero) { throw "Null init_backend callback for $name." }

        # Import the fixed payload aperture before backend creation. The emitted
        # factory callback only captures native pointers and patches die 2; it is
        # safe when llama invokes backend construction from a native worker.
        $buffer = $bufferFromHost.DynamicInvoke(
            $device, $aperture, [uint64]$ApertureBytes, [uint64]$ApertureBytes)
        if ($buffer -eq [IntPtr]::Zero) { throw "$name could not import the permanent aperture." }
        $bridgeBuffers.Add($buffer)
        if ($deviceSlot -eq 0) {
            $bridge = New-BridgeTensor $buffer $tensorAlloc
            $apertureType.GetField('SourceBridge').SetValue($null, $bridge)
        } else {
            $bridge = New-BridgeTensor $buffer $tensorAlloc
            $apertureType.GetField('DestinationBridge').SetValue($null, $bridge)
            $apertureType.GetField('DestinationBuffer').SetValue($null, $buffer)
        }

        $factoryCallback = New-RyuJitBackendFactory `
            $initDelegateType $originalPointer $apertureType $deviceSlot `
            $apertureCallbacks.CopyPointer
        [Runtime.InteropServices.Marshal]::WriteIntPtr($slot, $factoryCallback.Pointer)
        $patchedFactories.Add([PSCustomObject]@{ Slot = $slot; Original = $originalPointer })
        [void]$found.Add($name)
    }
    foreach ($name in $selectedNames) {
        if (-not $found.Contains($name)) { throw "Selected backend device not found: $name" }
    }

    if ($Scenario -eq 'Aperture') {
        $programArguments = @(
            'llama-bench.exe', '-m', $Model,
            '-ngl', '999', '-dev', $DeviceSelection, '-sm', 'layer', '-ts', $TensorSplit,
            '-ncmoe', '0', '-ctk', 'q4_0', '-ctv', 'q4_0', '-fa', 'on', '--no-host', '1',
            '-p', "$Prompt", '-n', "$Generation", '-r', "$Repetitions", '-o', 'json'
        )
    } else {
        if ([string]::IsNullOrEmpty($OutputPrompt)) {
            throw 'Generate requires -OutputPrompt.'
        }
        if ($WarmupBeforeMeasure) { throw 'Output generation does not use the benchmark warmup switch.' }
        $cliLibrary = $interop.LoadLibrary((Join-Path $resolvedBin 'llama-cli-impl.dll'))
        $entryPoint = $interop.GetCall(
            $interop.GetExport($cliLibrary, '?llama_cli@@YAHHPEAPEAD@Z'),
            ([int]), @([int], [IntPtr]))
        $cliDevices = $DeviceSelection.Replace('/', ',')
        $cliTensorSplit = $TensorSplit.Replace('/', ',')
        $programArguments = @(
            'llama-cli.exe', '-m', $Model,
            '-ngl', '999', '-dev', $cliDevices, '-sm', 'layer', '-ts', $cliTensorSplit,
            '-ncmoe', '0', '-ctk', 'q4_0', '-ctv', 'q4_0', '-fa', 'on', '--no-host',
            '-p', $OutputPrompt, '-n', "$OutputTokens", '-s', '1234', '--temp', '0',
            '--no-display-prompt', '--simple-io', '--single-turn', '--log-disable'
        )
    }

    function Invoke-Benchmark([string[]] $Values) {
        $pointers = [Collections.Generic.List[IntPtr]]::new()
        $vector = [IntPtr]::Zero
        try {
            foreach ($value in $Values) { $pointers.Add([Runtime.InteropServices.Marshal]::StringToCoTaskMemUTF8($value)) }
            $vector = [Runtime.InteropServices.Marshal]::AllocHGlobal($pointers.Count * [IntPtr]::Size)
            for ($argumentIndex = 0; $argumentIndex -lt $pointers.Count; $argumentIndex++) {
                [Runtime.InteropServices.Marshal]::WriteIntPtr(
                    $vector, $argumentIndex * [IntPtr]::Size, $pointers[$argumentIndex])
            }
            [int]$entryPoint.DynamicInvoke($pointers.Count, $vector)
        } finally {
            if ($vector -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($vector) }
            foreach ($pointer in $pointers) { [Runtime.InteropServices.Marshal]::FreeCoTaskMem($pointer) }
        }
    }

    if ($WarmupBeforeMeasure) {
        $warmupResult = Invoke-Benchmark $programArguments
        if ($warmupResult -ne 0) { throw "Warmup failed closed: return=$warmupResult" }
        $apertureType.GetField('Handled').SetValue($null, [long]0)
        $apertureType.GetField('ConsumerBlits').SetValue($null, [long]0)
        $apertureType.GetField('BatchedProducerWaits').SetValue($null, [long]0)
        $apertureType.GetField('SkippedIdleSyncs').SetValue($null, [long]0)
        $apertureType.GetField('Failed').SetValue($null, [int]0)
    }

    $result = Invoke-Benchmark $programArguments
    if ($result -ne 0) { throw "The in-process llama entry point returned $result." }
    $handled = [long]$apertureType.GetField('Handled').GetValue($null)
    $consumerBlits = [long]$apertureType.GetField('ConsumerBlits').GetValue($null)
    $batchedProducerWaits = [long]$apertureType.GetField('BatchedProducerWaits').GetValue($null)
    $skippedIdleSyncs = [long]$apertureType.GetField('SkippedIdleSyncs').GetValue($null)
    $failed = [int]$apertureType.GetField('Failed').GetValue($null)
    if ($failed -ne 0) { throw 'The batched aperture route failed closed.' }
    if ($handled -eq 0) { throw 'No die-1 to die-2 aperture handoffs were observed.' }
    $metadata = [PSCustomObject]@{
        Status = 'MECHANISM_SUBMITTED_OUTPUT_UNVERIFIED'
        Mode = 'RyuJitMailboxSwitch'
        HandledHandoffs = $handled
        ApertureBytes = $ApertureBytes
        HotPathPowerShell = $false
        BatchedProducerWaits = $batchedProducerWaits
        ConsumerBlits = $consumerBlits
        SkippedIdleDestinationSyncs = $skippedIdleSyncs
        EmbeddedCSharp = $false
        BlockingFallback = $false
        DestinationScratchCopy = $false
        GraphCallbackWrapped = $false
        SynchronizeCallbackWrapped = $false
    }
    if ($InternalChild) {
        if (-not [string]::IsNullOrWhiteSpace($MetadataPath)) {
            [IO.File]::WriteAllText($MetadataPath, ($metadata | ConvertTo-Json -Compress))
        }
    } else {
        $metadata | Format-List | Out-Host
    }
}
finally {
    for ([int]$factoryIndex = $patchedFactories.Count - 1; $factoryIndex -ge 0; $factoryIndex--) {
        $entry = $patchedFactories[$factoryIndex]
        if ($entry.Slot -ne [IntPtr]::Zero -and $entry.Original -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::WriteIntPtr($entry.Slot, $entry.Original)
        }
    }
    foreach ($buffer in $bridgeBuffers) {
        if ($buffer -ne [IntPtr]::Zero -and $null -ne $bufferFree) {
            try { $bufferFree.DynamicInvoke([IntPtr]$buffer) } catch { }
        }
    }
    foreach ($pointer in @($pendingSources, $pendingDestinations, $pendingOffsets)) {
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::FreeHGlobal($pointer)
        }
    }
    if ($aperture -ne [IntPtr]::Zero -and $null -ne $virtualFree) {
        try { [void]$virtualFree.DynamicInvoke($aperture, [uint64]0, [uint32]0x8000) } catch { }
    }
    for ([int]$tensorIndex = $tensorBlocks.Count - 1; $tensorIndex -ge 0; $tensorIndex--) {
        if ($tensorBlocks[$tensorIndex] -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::FreeHGlobal($tensorBlocks[$tensorIndex])
        }
    }
    $callbacks.Clear()
    $env:PATH = $oldPath
    if ($null -ne $interop) { $interop.Dispose() }
}
