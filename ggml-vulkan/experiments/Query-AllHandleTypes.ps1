$binder = & "c:\dev\V340L-Emancipated\src\New-WindowsFunctionPointerBinder.ps1"
$hVk = [Runtime.InteropServices.NativeLibrary]::Load('vulkan-1.dll')
$ci = [Runtime.InteropServices.Marshal]::AllocHGlobal(64)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(64), 0, $ci, 64)
[Runtime.InteropServices.Marshal]::WriteInt32($ci, 0, 1)
$outInst = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
$binder.GetCall($binder.GetExport($hVk, 'vkCreateInstance'), [int], @([IntPtr], [IntPtr], [IntPtr])).Invoke($ci, [IntPtr]::Zero, $outInst)
$inst = [Runtime.InteropServices.Marshal]::ReadIntPtr($outInst)

$outCount = [Runtime.InteropServices.Marshal]::AllocHGlobal(4)
$binder.GetCall($binder.GetExport($hVk, 'vkEnumeratePhysicalDevices'), [int], @([IntPtr], [IntPtr], [IntPtr])).Invoke($inst, $outCount, [IntPtr]::Zero)
$count = [Runtime.InteropServices.Marshal]::ReadInt32($outCount)
$outDevs = [Runtime.InteropServices.Marshal]::AllocHGlobal($count * 8)
$binder.GetCall($binder.GetExport($hVk, 'vkEnumeratePhysicalDevices'), [int], @([IntPtr], [IntPtr], [IntPtr])).Invoke($inst, $outCount, $outDevs)
$pDev = [Runtime.InteropServices.Marshal]::ReadIntPtr($outDevs, 0)

$fnExtProps = $binder.GetCall($binder.GetExport($hVk, 'vkGetPhysicalDeviceExternalSemaphoreProperties'), [void], @([IntPtr], [IntPtr], [IntPtr]))
$extInfo = [Runtime.InteropServices.Marshal]::AllocHGlobal(24)
$outProps = [Runtime.InteropServices.Marshal]::AllocHGlobal(32)

$types = @{
    "OPAQUE_WIN32" = 2
    "OPAQUE_WIN32_KMT" = 4
    "D3D12_FENCE" = 8
    "SYNC_FD" = 16
}

foreach ($name in $types.Keys) {
    $ht = $types[$name]
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new(24), 0, $extInfo, 24)
    [Runtime.InteropServices.Marshal]::WriteInt32($extInfo, 0, 1000076000)
    [Runtime.InteropServices.Marshal]::WriteInt32($extInfo, 16, $ht)
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new(32), 0, $outProps, 32)
    [Runtime.InteropServices.Marshal]::WriteInt32($outProps, 0, 1000076001)

    $fnExtProps.Invoke($pDev, $extInfo, $outProps)
    $exportable = [Runtime.InteropServices.Marshal]::ReadInt32($outProps, 16)
    $compat = [Runtime.InteropServices.Marshal]::ReadInt32($outProps, 20)
    $features = [Runtime.InteropServices.Marshal]::ReadInt32($outProps, 24)
    Write-Output "$name (0x$($ht.ToString('X'))): exportable=$($exportable -band 1), importable=$($exportable -band 2), features=$features"
}
