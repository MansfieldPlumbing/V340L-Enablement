<# Pinned llama-server experiment. The direct aperture route currently FAILS the output gate. #>
[CmdletBinding()]
param([switch]$ServerChild, [int]$Port = 19273, [string]$ControlName = '',
      [string]$Bin = 'C:\bin\llama.cpp',
      [string]$Model = 'C:\Models\gemma-4-E4B-it-Q4_K_M.gguf')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $ServerChild) {
    $ControlName = 'V340L-Roof-' + [Guid]::NewGuid().ToString('N')
    $controlMap = [IO.MemoryMappedFiles.MemoryMappedFile]::CreateOrOpen($ControlName, 4096)
    $control = $controlMap.CreateViewAccessor()
    $control.Write(0, [int]0)
    $out = Join-Path $env:TEMP ('v340l-roof-' + [Guid]::NewGuid().ToString('N') + '.out')
    $err = [IO.Path]::ChangeExtension($out, '.err')
    $pwsh = (Get-Process -Id $PID).Path
    $child = Start-Process -FilePath $pwsh -ArgumentList @(
        '-NoProfile', '-File', ('"' + $PSCommandPath + '"'), '-ServerChild',
        '-Port', "$Port", '-ControlName', $ControlName,
        '-Bin', ('"' + $Bin + '"'), '-Model', ('"' + $Model + '"')) `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
    try {
        $base = "http://127.0.0.1:$Port"
        $ready = $false
        for ($attempt = 0; $attempt -lt 120; $attempt++) {
            if ($child.HasExited) { throw "Server exited $($child.ExitCode): $(Get-Content -LiteralPath $err -Raw)" }
            try {
                if ((Invoke-RestMethod "$base/health" -TimeoutSec 2).status -eq 'ok') { $ready = $true; break }
            } catch { }
            Start-Sleep -Milliseconds 500
        }
        if (-not $ready) { throw "Server did not become ready: $(Get-Content -LiteralPath $err -Raw)" }
        $body = @{ prompt = 'Describe the Na\u0027vi of Pandora in a short paragraph.'; n_predict = 64;
                   temperature = 0; cache_prompt = $false } | ConvertTo-Json -Compress
        $previousCount = 0
        $baseline = $null
        for ($request = 1; $request -le 2; $request++) {
            $response = Invoke-RestMethod "$base/completion" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 120
            Start-Sleep -Milliseconds 300
            $all = @(Get-Content -LiteralPath $out -ErrorAction SilentlyContinue | Where-Object { $_ -match '^PAIR ' })
            $current = @($all | Select-Object -Skip $previousCount)
            $previousCount = $all.Count
            $bySource = @($current | ForEach-Object { ($_ -split ' ')[1] } | Sort-Object -Unique)
            Write-Output ([PSCustomObject]@{ Request = $request; Output = $response.content;
                Handoffs = $current.Count; UniqueSources = $bySource.Count;
                SourcePointers = ($bySource -join ',') })
            if ($request -eq 1) {
                $baseline = [string]$response.content
                $control.Write(0, [int]1)
            } else {
                $sameOutput = [string]$response.content -ceq $baseline
                Write-Output ([PSCustomObject]@{ ExactOutputMatch = $sameOutput })
                if (-not $sameOutput) { throw 'Direct aperture route failed the semantic output gate.' }
            }
        }
    } finally {
        if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force }
        $child.WaitForExit()
        $control.Dispose()
        $controlMap.Dispose()
        Write-Output "Probe logs: $out ; $err"
    }
    return
}

$binder = & (Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))) 'src\New-WindowsFunctionPointerBinder.ps1')
$controlMap = [IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting($ControlName)
$control = $controlMap.CreateViewAccessor()
$oldPath = $env:PATH
$env:PATH = "$Bin;$oldPath"
$callbacks = [Collections.Generic.List[Delegate]]::new()
$patched = [Collections.Generic.List[object]]::new()
try {
    $ggml = $binder.LoadLibrary((Join-Path $Bin 'ggml.dll'))
    $baseDll = $binder.LoadLibrary((Join-Path $Bin 'ggml-base.dll'))
    $serverDll = $binder.LoadLibrary((Join-Path $Bin 'llama-server-impl.dll'))
    $load = $binder.GetCall($binder.GetExport($ggml, 'ggml_backend_load_all_from_path'), [void], @([IntPtr]))
    $count = $binder.GetCall($binder.GetExport($ggml, 'ggml_backend_dev_count'), [uint64], @())
    $get = $binder.GetCall($binder.GetExport($ggml, 'ggml_backend_dev_get'), [IntPtr], @([uint64]))
    $name = $binder.GetCall($binder.GetExport($baseDll, 'ggml_backend_dev_name'), [IntPtr], @([IntPtr]))
    $nbytes = $binder.GetExport($baseDll, 'ggml_nbytes')
    $entry = $binder.GetCall($binder.GetExport($serverDll, '?llama_server@@YAHHPEAPEAD@Z'), [int], @([int], [IntPtr]))

    $ab = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
        [Reflection.AssemblyName]::new('V340L.RoofSpy.' + [Guid]::NewGuid().ToString('N')),
        [Reflection.Emit.AssemblyBuilderAccess]::Run)
    $mod = $ab.DefineDynamicModule('Spy')
    $tb = $mod.DefineType('Spy', 'Public,Abstract,Sealed')
    $factoryField = $tb.DefineField('OriginalFactory', [IntPtr], 'Public,Static')
    $sourceFactoryField = $tb.DefineField('OriginalSourceFactory', [IntPtr], 'Public,Static')
    $copyField = $tb.DefineField('OriginalCopy', [IntPtr], 'Public,Static')
    $graphField = $tb.DefineField('OriginalGraph', [IntPtr], 'Public,Static')
    $graphPtrField = $tb.DefineField('GraphPointer', [IntPtr], 'Public,Static')
    $graphCountField = $tb.DefineField('GraphCount', [IntPtr], 'Public,Static')
    $graphNodeField = $tb.DefineField('GraphNode', [IntPtr], 'Public,Static')
    $baseField = $tb.DefineField('BaseTensor', [IntPtr], 'Public,Static')
    $outputField = $tb.DefineField('OutputTensor', [IntPtr], 'Public,Static')
    $viewsField = $tb.DefineField('Views', [IntPtr[]], 'Public,Static')
    $viewCountField = $tb.DefineField('ViewCount', [int], 'Public,Static')
    $sourceBufferField = $tb.DefineField('SourceBuffer', [IntPtr], 'Public,Static')
    $destinationBufferField = $tb.DefineField('DestinationBuffer', [IntPtr], 'Public,Static')
    $controlField = $tb.DefineField('Control', [IO.MemoryMappedFiles.MemoryMappedViewAccessor], 'Public,Static')
    $routedField = $tb.DefineField('Routed', [int], 'Public,Static')
    $copyPtrField = $tb.DefineField('CopyPointer', [IntPtr], 'Public,Static')
    $nbytesField = $tb.DefineField('NBytes', [IntPtr], 'Public,Static')
    $bind = $tb.DefineMethod('Bind', 'Public,Static', [void], @([IntPtr],[IntPtr],[IntPtr]))
    $il = $bind.GetILGenerator()
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_8)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
    $il.Emit([Reflection.Emit.OpCodes]::Stind_I)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 248)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Stind_I)
    $il.Emit([Reflection.Emit.OpCodes]::Ret)
    $copy = $tb.DefineMethod('Copy', 'Public,Static', [bool], @([IntPtr],[IntPtr],[IntPtr],[IntPtr]))
    $il = $copy.GetILGenerator()
    $bytes = $il.DeclareLocal([uint64])
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $nbytesField)
    $il.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl,
        [uint64], @([IntPtr]))
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $bytes)
    $notOutput = $il.DefineLabel()
    $notView = $il.DefineLabel()
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $bytes)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I8, [long]10240)
    $il.Emit([Reflection.Emit.OpCodes]::Bne_Un, $notOutput)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Stsfld, $outputField)
    $il.MarkLabel($notOutput)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $bytes)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I8, [long]1024)
    $il.Emit([Reflection.Emit.OpCodes]::Bne_Un, $notView)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 232)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Ldind_I)
    $il.Emit([Reflection.Emit.OpCodes]::Stsfld, $baseField)
    $alreadyFull = $il.DefineLabel()
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $viewCountField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 20)
    $il.Emit([Reflection.Emit.OpCodes]::Bge, $alreadyFull)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $viewsField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $viewCountField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Stelem_I)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $viewCountField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Stsfld, $viewCountField)
    $il.MarkLabel($alreadyFull)
    $il.MarkLabel($notView)
    $stockLog = $il.DefineLabel()
    $routeOutput = $il.DefineLabel()
    $routeView = $il.DefineLabel()
    $routeBind = $il.DefineLabel()
    $routeData = $il.DeclareLocal([IntPtr])
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $controlField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I8)
    $il.Emit([Reflection.Emit.OpCodes]::Callvirt,
        [IO.MemoryMappedFiles.MemoryMappedViewAccessor].GetMethod('ReadInt32', [Type[]]@([long])))
    $il.Emit([Reflection.Emit.OpCodes]::Brfalse, $stockLog)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $bytes)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I8, [long]10240)
    $il.Emit([Reflection.Emit.OpCodes]::Bne_Un, $routeView)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $outputField)
    $il.Emit([Reflection.Emit.OpCodes]::Beq, $routeOutput)
    $il.Emit([Reflection.Emit.OpCodes]::Br, $stockLog)
    $il.MarkLabel($routeView)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $bytes)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I8, [long]1024)
    $il.Emit([Reflection.Emit.OpCodes]::Bne_Un, $stockLog)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 232)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Ldind_I)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $baseField)
    $il.Emit([Reflection.Emit.OpCodes]::Bne_Un, $stockLog)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 240)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Ldind_I8)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x1000)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I8)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $routeData)
    $il.Emit([Reflection.Emit.OpCodes]::Br, $routeBind)
    $il.MarkLabel($routeOutput)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x1000 + 43008)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $routeData)
    $il.MarkLabel($routeBind)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $routedField)
    $ready = $il.DefineLabel()
    $il.Emit([Reflection.Emit.OpCodes]::Brtrue, $ready)
    $il.Emit([Reflection.Emit.OpCodes]::Ldstr, 'Matched decode copy before producer aperture binding')
    $il.Emit([Reflection.Emit.OpCodes]::Call, [Environment].GetMethod('FailFast', [Type[]]@([string])))
    $il.MarkLabel($ready)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $destinationBufferField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $routeData)
    $il.Emit([Reflection.Emit.OpCodes]::Call, $bind)
    foreach ($offset in @(232,240,320)) {
        $il.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
        $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, $offset)
        $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
        $il.Emit([Reflection.Emit.OpCodes]::Add)
        $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
        $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
        $il.Emit([Reflection.Emit.OpCodes]::Stind_I)
    }
    $il.Emit([Reflection.Emit.OpCodes]::Ldstr, 'ROUTED')
    $il.Emit([Reflection.Emit.OpCodes]::Call, [Console].GetMethod('WriteLine', [Type[]]@([string])))
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
    $il.Emit([Reflection.Emit.OpCodes]::Ret)
    $il.MarkLabel($stockLog)
    $il.Emit([Reflection.Emit.OpCodes]::Ldstr, 'PAIR {0:X16} {1:X16} {2}')
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I8)
    $il.Emit([Reflection.Emit.OpCodes]::Box, [long])
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I8)
    $il.Emit([Reflection.Emit.OpCodes]::Box, [long])
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $bytes)
    $il.Emit([Reflection.Emit.OpCodes]::Box, [uint64])
    $il.Emit([Reflection.Emit.OpCodes]::Call, [Console].GetMethod('WriteLine', [Type[]]@([string],[object],[object],[object])))
    $il.Emit([Reflection.Emit.OpCodes]::Ldstr, 'VIEW {0:X16} {1}')
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 232)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Ldind_I)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I8)
    $il.Emit([Reflection.Emit.OpCodes]::Box, [long])
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 240)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Ldind_I8)
    $il.Emit([Reflection.Emit.OpCodes]::Box, [long])
    $il.Emit([Reflection.Emit.OpCodes]::Call, [Console].GetMethod('WriteLine', [Type[]]@([string],[object],[object])))
    $noBase = $il.DefineLabel()
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 232)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Ldind_I)
    $il.Emit([Reflection.Emit.OpCodes]::Brfalse, $noBase)
    $il.Emit([Reflection.Emit.OpCodes]::Ldstr, 'BASE {0}')
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 232)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Ldind_I)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $nbytesField)
    $il.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl,
        [uint64], @([IntPtr]))
    $il.Emit([Reflection.Emit.OpCodes]::Box, [uint64])
    $il.Emit([Reflection.Emit.OpCodes]::Call, [Console].GetMethod('WriteLine', [Type[]]@([string],[object])))
    $il.MarkLabel($noBase)
    $il.Emit([Reflection.Emit.OpCodes]::Call, [Console].GetProperty('Out').GetGetMethod())
    $il.Emit([Reflection.Emit.OpCodes]::Callvirt, [IO.TextWriter].GetMethod('Flush', [Type[]]@()))
    foreach ($i in 0..3) { $il.Emit([Reflection.Emit.OpCodes]::Ldarg, [int16]$i) }
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $copyField)
    $il.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl,
        [bool], @([IntPtr],[IntPtr],[IntPtr],[IntPtr]))
    $il.Emit([Reflection.Emit.OpCodes]::Ret)

    $graph = $tb.DefineMethod('Graph', 'Public,Static', [int], @([IntPtr],[IntPtr]))
    $il = $graph.GetILGenerator()
    $n = $il.DeclareLocal([int])
    $index = $il.DeclareLocal([int])
    $node = $il.DeclareLocal([IntPtr])
    $loop = $il.DefineLabel()
    $end = $il.DefineLabel()
    $notBase = $il.DefineLabel()
    $notOut = $il.DefineLabel()
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $graphCountField)
    $il.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl,
        [int], @([IntPtr]))
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $n)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $index)
    $il.MarkLabel($loop)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $index)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $n)
    $il.Emit([Reflection.Emit.OpCodes]::Bge, $end)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $index)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $graphNodeField)
    $il.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl,
        [IntPtr], @([IntPtr],[int]))
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $node)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $node)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $baseField)
    $il.Emit([Reflection.Emit.OpCodes]::Bne_Un, $notBase)
    $il.Emit([Reflection.Emit.OpCodes]::Ldstr, 'GRAPH_BASE')
    $il.Emit([Reflection.Emit.OpCodes]::Call, [Console].GetMethod('WriteLine', [Type[]]@([string])))
    $il.MarkLabel($notBase)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $node)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $outputField)
    $il.Emit([Reflection.Emit.OpCodes]::Bne_Un, $notOut)
    $il.Emit([Reflection.Emit.OpCodes]::Ldstr, 'GRAPH_OUTPUT')
    $il.Emit([Reflection.Emit.OpCodes]::Call, [Console].GetMethod('WriteLine', [Type[]]@([string])))
    $il.MarkLabel($notOut)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $index)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $index)
    $il.Emit([Reflection.Emit.OpCodes]::Br, $loop)
    $il.MarkLabel($end)
    $graphOriginal = $il.DefineLabel()
    $viewLoop = $il.DefineLabel()
    $viewEnd = $il.DefineLabel()
    $viewIndex = $il.DeclareLocal([int])
    $viewPtr = $il.DeclareLocal([IntPtr])
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $controlField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I8)
    $il.Emit([Reflection.Emit.OpCodes]::Callvirt,
        [IO.MemoryMappedFiles.MemoryMappedViewAccessor].GetMethod('ReadInt32', [Type[]]@([long])))
    $il.Emit([Reflection.Emit.OpCodes]::Brfalse, $graphOriginal)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
    $il.Emit([Reflection.Emit.OpCodes]::Stsfld, $routedField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $baseField)
    $il.Emit([Reflection.Emit.OpCodes]::Brfalse, $graphOriginal)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $outputField)
    $il.Emit([Reflection.Emit.OpCodes]::Brfalse, $graphOriginal)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $baseField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $nbytesField)
    $il.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl,
        [uint64], @([IntPtr]))
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I8, [long]43008)
    $il.Emit([Reflection.Emit.OpCodes]::Bne_Un, $graphOriginal)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $outputField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $nbytesField)
    $il.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl,
        [uint64], @([IntPtr]))
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I8, [long]10240)
    $il.Emit([Reflection.Emit.OpCodes]::Bne_Un, $graphOriginal)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $viewCountField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 20)
    $complete = $il.DefineLabel()
    $il.Emit([Reflection.Emit.OpCodes]::Beq, $complete)
    $il.Emit([Reflection.Emit.OpCodes]::Ldstr, 'Decode view inventory incomplete')
    $il.Emit([Reflection.Emit.OpCodes]::Call, [Environment].GetMethod('FailFast', [Type[]]@([string])))
    $il.MarkLabel($complete)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $baseField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $sourceBufferField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x1000)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Call, $bind)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $outputField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $sourceBufferField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x1000 + 43008)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Call, $bind)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $viewIndex)
    $il.MarkLabel($viewLoop)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $viewIndex)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 20)
    $il.Emit([Reflection.Emit.OpCodes]::Bge, $viewEnd)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $viewsField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $viewIndex)
    $il.Emit([Reflection.Emit.OpCodes]::Ldelem_I)
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $viewPtr)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $viewPtr)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $sourceBufferField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x1000)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $viewPtr)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 240)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Ldind_I)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Call, $bind)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $viewIndex)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $viewIndex)
    $il.Emit([Reflection.Emit.OpCodes]::Br, $viewLoop)
    $il.MarkLabel($viewEnd)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
    $il.Emit([Reflection.Emit.OpCodes]::Stsfld, $routedField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldstr, 'GRAPH_BOUND')
    $il.Emit([Reflection.Emit.OpCodes]::Call, [Console].GetMethod('WriteLine', [Type[]]@([string])))
    $il.MarkLabel($graphOriginal)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $graphField)
    $il.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl,
        [int], @([IntPtr],[IntPtr]))
    $il.Emit([Reflection.Emit.OpCodes]::Ret)

    $factory = $tb.DefineMethod('Factory', 'Public,Static', [IntPtr], @([IntPtr],[IntPtr]))
    $il = $factory.GetILGenerator()
    $backend = $il.DeclareLocal([IntPtr])
    $slot = $il.DeclareLocal([IntPtr])
    $done = $il.DefineLabel()
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $factoryField)
    $il.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl,
        [IntPtr], @([IntPtr],[IntPtr]))
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $backend)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $backend)
    $il.Emit([Reflection.Emit.OpCodes]::Brfalse, $done)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $backend)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x38)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $slot)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $slot)
    $il.Emit([Reflection.Emit.OpCodes]::Ldind_I)
    $il.Emit([Reflection.Emit.OpCodes]::Stsfld, $copyField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $slot)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $copyPtrField)
    $il.Emit([Reflection.Emit.OpCodes]::Stind_I)
    $il.MarkLabel($done)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $backend)
    $il.Emit([Reflection.Emit.OpCodes]::Ret)
    $sourceFactory = $tb.DefineMethod('SourceFactory', 'Public,Static', [IntPtr], @([IntPtr],[IntPtr]))
    $il = $sourceFactory.GetILGenerator()
    $sourceBackend = $il.DeclareLocal([IntPtr])
    $sourceSlot = $il.DeclareLocal([IntPtr])
    $sourceDone = $il.DefineLabel()
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $sourceFactoryField)
    $il.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl,
        [IntPtr], @([IntPtr],[IntPtr]))
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $sourceBackend)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $sourceBackend)
    $il.Emit([Reflection.Emit.OpCodes]::Brfalse, $sourceDone)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $sourceBackend)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x68)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $sourceSlot)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $sourceSlot)
    $il.Emit([Reflection.Emit.OpCodes]::Ldind_I)
    $il.Emit([Reflection.Emit.OpCodes]::Stsfld, $graphField)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $sourceSlot)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $graphPtrField)
    $il.Emit([Reflection.Emit.OpCodes]::Stind_I)
    $il.MarkLabel($sourceDone)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $sourceBackend)
    $il.Emit([Reflection.Emit.OpCodes]::Ret)
    $type = $tb.CreateTypeInfo().AsType()
    $type.GetField('NBytes').SetValue($null, $nbytes)
    $type.GetField('GraphCount').SetValue($null, $binder.GetExport($baseDll, 'ggml_graph_n_nodes'))
    $type.GetField('GraphNode').SetValue($null, $binder.GetExport($baseDll, 'ggml_graph_node'))
    $type.GetField('Views').SetValue($null, [IntPtr[]]::new(20))
    $type.GetField('Control').SetValue($null, $control)

    function Delegate-Type([Type]$return, [Type[]]$parameterTypes) {
        $dt = $mod.DefineType('D' + [Guid]::NewGuid().ToString('N'), 'Public,Sealed', [MulticastDelegate])
        [void]$dt.DefineConstructor('Public,HideBySig,RTSpecialName',
            [Reflection.CallingConventions]::Standard, @([object],[IntPtr])).SetImplementationFlags('Runtime,Managed')
        [void]$dt.DefineMethod('Invoke', 'Public,HideBySig,NewSlot,Virtual', $return, $parameterTypes).SetImplementationFlags('Runtime,Managed')
        $dt.CreateTypeInfo().AsType()
    }
    $copyDel = [Delegate]::CreateDelegate((Delegate-Type ([bool]) @([IntPtr],[IntPtr],[IntPtr],[IntPtr])), $type.GetMethod('Copy'))
    $factoryDel = [Delegate]::CreateDelegate((Delegate-Type ([IntPtr]) @([IntPtr],[IntPtr])), $type.GetMethod('Factory'))
    $sourceFactoryDel = [Delegate]::CreateDelegate((Delegate-Type ([IntPtr]) @([IntPtr],[IntPtr])), $type.GetMethod('SourceFactory'))
    $graphDel = [Delegate]::CreateDelegate((Delegate-Type ([int]) @([IntPtr],[IntPtr])), $type.GetMethod('Graph'))
    $callbacks.Add($copyDel)
    $callbacks.Add($factoryDel)
    $callbacks.Add($sourceFactoryDel)
    $callbacks.Add($graphDel)
    $type.GetField('CopyPointer').SetValue($null, [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($copyDel))
    $type.GetField('GraphPointer').SetValue($null, [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($graphDel))

    $path = [Runtime.InteropServices.Marshal]::StringToCoTaskMemUTF8($Bin)
    try { $load.DynamicInvoke($path) } finally { [Runtime.InteropServices.Marshal]::FreeCoTaskMem($path) }
    $virtualAlloc = $binder.GetExportCall('kernel32.dll', 'VirtualAlloc', [IntPtr],
        @([IntPtr],[uint64],[uint32],[uint32]))
    $import = $binder.GetCall($binder.GetExport($baseDll, 'ggml_backend_dev_buffer_from_host_ptr'),
        [IntPtr], @([IntPtr],[IntPtr],[uint64],[uint64]))
    $aperture = $virtualAlloc.DynamicInvoke([IntPtr]::Zero, [uint64]2MB, [uint32]0x3000, [uint32]4)
    if ($aperture -eq [IntPtr]::Zero) { throw 'VirtualAlloc failed.' }
    $found = $false
    for ([uint64]$i = 0; $i -lt [uint64]$count.DynamicInvoke(); $i++) {
        $dev = $get.DynamicInvoke($i)
        $deviceName = [Runtime.InteropServices.Marshal]::PtrToStringUTF8($name.DynamicInvoke($dev))
        if ($deviceName -ne 'Vulkan1' -and $deviceName -ne 'Vulkan2') { continue }
        $imported = $import.DynamicInvoke($dev, $aperture, [uint64]2MB, [uint64]2MB)
        if ($imported -eq [IntPtr]::Zero) { throw "Aperture import failed on $deviceName." }
        if ($deviceName -eq 'Vulkan1') {
            $type.GetField('SourceBuffer').SetValue($null, $imported)
        } else {
            $type.GetField('DestinationBuffer').SetValue($null, $imported)
        }
        $slot = [IntPtr]::new($dev.ToInt64() + 0x28)
        $original = [Runtime.InteropServices.Marshal]::ReadIntPtr($slot)
        if ($deviceName -eq 'Vulkan1') {
            $type.GetField('OriginalSourceFactory').SetValue($null, $original)
            $replacement = [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($sourceFactoryDel)
        } else {
            $type.GetField('OriginalFactory').SetValue($null, $original)
            $replacement = [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($factoryDel)
        }
        [Runtime.InteropServices.Marshal]::WriteIntPtr($slot, $replacement)
        $patched.Add([PSCustomObject]@{ Slot = $slot; Original = $original })
        if ($deviceName -eq 'Vulkan2') { $found = $true }
    }
    if (-not $found) { throw 'Vulkan2 not found.' }

    $args = @('llama-server.exe', '-m', $Model, '-ngl', '999', '-dev', 'Vulkan1,Vulkan2',
        '-sm', 'layer', '-ts', '1,1', '-ncmoe', '0', '-ctk', 'q4_0', '-ctv', 'q4_0',
        '-fa', 'on', '--no-host', '--host', '127.0.0.1', '--port', "$Port", '-c', '2048')
    $pointers = [Collections.Generic.List[IntPtr]]::new()
    $argv = [IntPtr]::Zero
    try {
        foreach ($arg in $args) { $pointers.Add([Runtime.InteropServices.Marshal]::StringToCoTaskMemUTF8($arg)) }
        $argv = [Runtime.InteropServices.Marshal]::AllocHGlobal($pointers.Count * [IntPtr]::Size)
        for ($i = 0; $i -lt $pointers.Count; $i++) {
            [Runtime.InteropServices.Marshal]::WriteIntPtr($argv, $i * [IntPtr]::Size, $pointers[$i])
        }
        [void]$entry.DynamicInvoke($pointers.Count, $argv)
    } finally {
        if ($argv -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($argv) }
        foreach ($pointer in $pointers) { [Runtime.InteropServices.Marshal]::FreeCoTaskMem($pointer) }
    }
} finally {
    foreach ($item in $patched) { [Runtime.InteropServices.Marshal]::WriteIntPtr($item.Slot, $item.Original) }
    $env:PATH = $oldPath
    $control.Dispose()
    $controlMap.Dispose()
    $binder.Dispose()
}
