<# Diagnostic probe: dumps exact tensor names, ops, backends, and views during server execution #>
[CmdletBinding()]
param([switch]$ServerChild, [int]$Port = 19274,
      [string]$Bin = 'C:\bin\llama.cpp',
      [string]$Model = 'C:\Models\gemma-4-E4B-it-Q4_K_M.gguf')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $ServerChild) {
    $out = Join-Path $env:TEMP ('v340l-probe-' + [Guid]::NewGuid().ToString('N') + '.out')
    $err = [IO.Path]::ChangeExtension($out, '.err')
    $pwsh = (Get-Process -Id $PID).Path
    $child = Start-Process -FilePath $pwsh -ArgumentList @(
        '-NoProfile', '-File', ('"' + $PSCommandPath + '"'), '-ServerChild',
        '-Port', "$Port", '-Bin', ('"' + $Bin + '"'), '-Model', ('"' + $Model + '"')) `
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
        $body = @{ prompt = 'Describe the Na\u0027vi of Pandora in a short paragraph.'; n_predict = 4;
                   temperature = 0; cache_prompt = $false } | ConvertTo-Json -Compress
        $response = Invoke-RestMethod "$base/completion" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 120
        Write-Output ([PSCustomObject]@{ Output = $response.content })
    } finally {
        if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force }
        $child.WaitForExit()
        Write-Output "Probe logs: $out ; $err"
    }
    return
}

$binder = & (Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))) 'src\New-WindowsFunctionPointerBinder.ps1')
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
    $getName = $binder.GetExport($baseDll, 'ggml_get_name')
    $getBackendName = $binder.GetExport($baseDll, 'ggml_backend_name')
    $entry = $binder.GetCall($binder.GetExport($serverDll, '?llama_server@@YAHHPEAPEAD@Z'), [int], @([int], [IntPtr]))

    $ab = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
        [Reflection.AssemblyName]::new('V340L.ProbeSpy.' + [Guid]::NewGuid().ToString('N')),
        [Reflection.Emit.AssemblyBuilderAccess]::Run)
    $mod = $ab.DefineDynamicModule('Spy')
    $tb = $mod.DefineType('Spy', 'Public,Abstract,Sealed')
    $factoryField = $tb.DefineField('OriginalFactory', [IntPtr], 'Public,Static')
    $copyField = $tb.DefineField('OriginalCopy', [IntPtr], 'Public,Static')
    $copyPtrField = $tb.DefineField('CopyPointer', [IntPtr], 'Public,Static')
    $nbytesField = $tb.DefineField('NBytes', [IntPtr], 'Public,Static')
    $getNameField = $tb.DefineField('GetName', [IntPtr], 'Public,Static')
    $getBackendNameField = $tb.DefineField('GetBackendName', [IntPtr], 'Public,Static')

    # Copy method logs detailed info and forwards to original copy
    $copy = $tb.DefineMethod('Copy', 'Public,Static', [bool], @([IntPtr],[IntPtr],[IntPtr],[IntPtr]))
    $il = $copy.GetILGenerator()
    $bytes = $il.DeclareLocal([uint64])
    $srcName = $il.DeclareLocal([string])
    $dstName = $il.DeclareLocal([string])
    $fromBackend = $il.DeclareLocal([string])
    $toBackend = $il.DeclareLocal([string])
    $viewSrcName = $il.DeclareLocal([string])
    $viewOffs = $il.DeclareLocal([long])

    # bytes = ggml_nbytes(src)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $nbytesField)
    $il.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl,
        [uint64], @([IntPtr]))
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $bytes)

    # fromBackend = Marshal.PtrToStringUTF8(ggml_backend_name(backend_src))
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $getBackendNameField)
    $il.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl,
        [IntPtr], @([IntPtr]))
    $il.Emit([Reflection.Emit.OpCodes]::Call, [Runtime.InteropServices.Marshal].GetMethod('PtrToStringUTF8', [Type[]]@([IntPtr])))
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $fromBackend)

    # toBackend = Marshal.PtrToStringUTF8(ggml_backend_name(backend_dst))
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $getBackendNameField)
    $il.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl,
        [IntPtr], @([IntPtr]))
    $il.Emit([Reflection.Emit.OpCodes]::Call, [Runtime.InteropServices.Marshal].GetMethod('PtrToStringUTF8', [Type[]]@([IntPtr])))
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $toBackend)

    # srcName = Marshal.PtrToStringUTF8(ggml_get_name(src))
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $getNameField)
    $il.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl,
        [IntPtr], @([IntPtr]))
    $il.Emit([Reflection.Emit.OpCodes]::Call, [Runtime.InteropServices.Marshal].GetMethod('PtrToStringUTF8', [Type[]]@([IntPtr])))
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $srcName)

    # dstName = Marshal.PtrToStringUTF8(ggml_get_name(dst))
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $getNameField)
    $il.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl,
        [IntPtr], @([IntPtr]))
    $il.Emit([Reflection.Emit.OpCodes]::Call, [Runtime.InteropServices.Marshal].GetMethod('PtrToStringUTF8', [Type[]]@([IntPtr])))
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $dstName)

    # viewOffs = src->view_offs
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 240)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Ldind_I8)
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $viewOffs)

    # viewSrcName = src->view_src ? Marshal.PtrToStringUTF8(ggml_get_name(src->view_src)) : "none"
    $hasView = $il.DefineLabel()
    $noView = $il.DefineLabel()
    $viewSrcPtr = $il.DeclareLocal([IntPtr])
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 232)
    $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    $il.Emit([Reflection.Emit.OpCodes]::Add)
    $il.Emit([Reflection.Emit.OpCodes]::Ldind_I)
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $viewSrcPtr)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $viewSrcPtr)
    $il.Emit([Reflection.Emit.OpCodes]::Brtrue, $hasView)
    $il.Emit([Reflection.Emit.OpCodes]::Ldstr, 'none')
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $viewSrcName)
    $il.Emit([Reflection.Emit.OpCodes]::Br, $noView)
    $il.MarkLabel($hasView)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $viewSrcPtr)
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $getNameField)
    $il.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl,
        [IntPtr], @([IntPtr]))
    $il.Emit([Reflection.Emit.OpCodes]::Call, [Runtime.InteropServices.Marshal].GetMethod('PtrToStringUTF8', [Type[]]@([IntPtr])))
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $viewSrcName)
    $il.MarkLabel($noView)

    # Console.WriteLine("XFER {0} -> {1} | src={2} dst={3} bytes={4} view_src={5} view_offs={6}",
    #     fromBackend, toBackend, srcName, dstName, bytes, viewSrcName, viewOffs)
    $il.Emit([Reflection.Emit.OpCodes]::Ldstr, 'XFER {0} -> {1} | src={2} dst={3} bytes={4} view_src={5} view_offs={6}')
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_7)
    $il.Emit([Reflection.Emit.OpCodes]::Newarr, [object])
    $arr = $il.DeclareLocal([object[]])
    $il.Emit([Reflection.Emit.OpCodes]::Stloc, $arr)

    # arr[0] = fromBackend
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $arr)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $fromBackend)
    $il.Emit([Reflection.Emit.OpCodes]::Stelem_Ref)

    # arr[1] = toBackend
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $arr)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $toBackend)
    $il.Emit([Reflection.Emit.OpCodes]::Stelem_Ref)

    # arr[2] = srcName
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $arr)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_2)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $srcName)
    $il.Emit([Reflection.Emit.OpCodes]::Stelem_Ref)

    # arr[3] = dstName
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $arr)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_3)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $dstName)
    $il.Emit([Reflection.Emit.OpCodes]::Stelem_Ref)

    # arr[4] = (object)bytes
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $arr)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_4)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $bytes)
    $il.Emit([Reflection.Emit.OpCodes]::Box, [uint64])
    $il.Emit([Reflection.Emit.OpCodes]::Stelem_Ref)

    # arr[5] = viewSrcName
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $arr)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_5)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $viewSrcName)
    $il.Emit([Reflection.Emit.OpCodes]::Stelem_Ref)

    # arr[6] = (object)viewOffs
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $arr)
    $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_6)
    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $viewOffs)
    $il.Emit([Reflection.Emit.OpCodes]::Box, [long])
    $il.Emit([Reflection.Emit.OpCodes]::Stelem_Ref)

    $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $arr)
    $il.Emit([Reflection.Emit.OpCodes]::Call, [Console].GetMethod('WriteLine', [Type[]]@([string],[object[]])))
    $il.Emit([Reflection.Emit.OpCodes]::Call, [Console].GetProperty('Out').GetGetMethod())
    $il.Emit([Reflection.Emit.OpCodes]::Callvirt, [IO.TextWriter].GetMethod('Flush', [Type[]]@()))

    # Forward to original copy
    foreach ($i in 0..3) { $il.Emit([Reflection.Emit.OpCodes]::Ldarg, [int16]$i) }
    $il.Emit([Reflection.Emit.OpCodes]::Ldsfld, $copyField)
    $il.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl,
        [bool], @([IntPtr],[IntPtr],[IntPtr],[IntPtr]))
    $il.Emit([Reflection.Emit.OpCodes]::Ret)

    # Factory method for Vulkan2 (destination)
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

    $type = $tb.CreateTypeInfo().AsType()
    $type.GetField('NBytes').SetValue($null, $nbytes)
    $type.GetField('GetName').SetValue($null, $getName)
    $type.GetField('GetBackendName').SetValue($null, $getBackendName)

    function Delegate-Type([Type]$return, [Type[]]$parameterTypes) {
        $dt = $mod.DefineType('D' + [Guid]::NewGuid().ToString('N'), 'Public,Sealed', [MulticastDelegate])
        [void]$dt.DefineConstructor('Public,HideBySig,RTSpecialName',
            [Reflection.CallingConventions]::Standard, @([object],[IntPtr])).SetImplementationFlags('Runtime,Managed')
        [void]$dt.DefineMethod('Invoke', 'Public,HideBySig,NewSlot,Virtual', $return, $parameterTypes).SetImplementationFlags('Runtime,Managed')
        $dt.CreateTypeInfo().AsType()
    }
    $copyDel = [Delegate]::CreateDelegate((Delegate-Type ([bool]) @([IntPtr],[IntPtr],[IntPtr],[IntPtr])), $type.GetMethod('Copy'))
    $factoryDel = [Delegate]::CreateDelegate((Delegate-Type ([IntPtr]) @([IntPtr],[IntPtr])), $type.GetMethod('Factory'))
    $callbacks.Add($copyDel)
    $callbacks.Add($factoryDel)
    $type.GetField('CopyPointer').SetValue($null, [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($copyDel))

    $path = [Runtime.InteropServices.Marshal]::StringToCoTaskMemUTF8($Bin)
    try { $load.DynamicInvoke($path) } finally { [Runtime.InteropServices.Marshal]::FreeCoTaskMem($path) }

    $found = $false
    for ([uint64]$i = 0; $i -lt [uint64]$count.DynamicInvoke(); $i++) {
        $dev = $get.DynamicInvoke($i)
        $deviceName = [Runtime.InteropServices.Marshal]::PtrToStringUTF8($name.DynamicInvoke($dev))
        if ($deviceName -ne 'Vulkan2') { continue }
        $slot = [IntPtr]::new($dev.ToInt64() + 0x28)
        $original = [Runtime.InteropServices.Marshal]::ReadIntPtr($slot)
        $type.GetField('OriginalFactory').SetValue($null, $original)
        $replacement = [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($factoryDel)
        [Runtime.InteropServices.Marshal]::WriteIntPtr($slot, $replacement)
        $patched.Add([PSCustomObject]@{ Slot = $slot; Original = $original })
        $found = $true
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
    $binder.Dispose()
}
