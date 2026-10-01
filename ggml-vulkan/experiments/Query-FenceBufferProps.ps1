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

$fnFenceProps = $binder.GetCall($binder.GetExport($hVk, 'vkGetPhysicalDeviceExternalFenceProperties'), [void], @([IntPtr], [IntPtr], [IntPtr]))
$fnBufProps = $binder.GetCall($binder.GetExport($hVk, 'vkGetPhysicalDeviceExternalBufferProperties'), [void], @([IntPtr], [IntPtr], [IntPtr]))

$extInfo = [Runtime.InteropServices.Marshal]::AllocHGlobal(24)
$outProps = [Runtime.InteropServices.Marshal]::AllocHGlobal(32)

$types = @{ "OPAQUE_WIN32" = 2; "OPAQUE_WIN32_KMT" = 4; "D3D12_FENCE" = 8; "HOST_ALLOCATION" = 0x80 }

Write-Output "--- FENCE PROPERTIES ---"
foreach ($name in $types.Keys) {
    $ht = $types[$name]
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new(24), 0, $extInfo, 24)
    [Runtime.InteropServices.Marshal]::WriteInt32($extInfo, 0, 1000112000) # VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_FENCE_INFO
    [Runtime.InteropServices.Marshal]::WriteInt32($extInfo, 16, $ht)
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new(32), 0, $outProps, 32)
    [Runtime.InteropServices.Marshal]::WriteInt32($outProps, 0, 1000112001) # VK_STRUCTURE_TYPE_EXTERNAL_FENCE_PROPERTIES

    $fnFenceProps.Invoke($pDev, $extInfo, $outProps)
    $exportable = [Runtime.InteropServices.Marshal]::ReadInt32($outProps, 16)
    $features = [Runtime.InteropServices.Marshal]::ReadInt32($outProps, 24)
    Write-Output "Fence $name (0x$($ht.ToString('X'))): exportable=$($exportable -band 1), importable=$($exportable -band 2), features=$features"
}

Write-Output "--- BUFFER PROPERTIES ---"
foreach ($name in $types.Keys) {
    $ht = $types[$name]
    # VkPhysicalDeviceExternalBufferInfo: sType=1000071000, flags=0, usage=3 (TRANSFER_SRC|TRANSFER_DST), handleType=ht
    $bufInfo = [Runtime.InteropServices.Marshal]::AllocHGlobal(32)
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new(32), 0, $bufInfo, 32)
    [Runtime.InteropServices.Marshal]::WriteInt32($bufInfo, 0, 1000071000)
    [Runtime.InteropServices.Marshal]::WriteInt32($bufInfo, 20, 3)
    [Runtime.InteropServices.Marshal]::WriteInt32($bufInfo, 24, $ht)

    $bufOut = [Runtime.InteropServices.Marshal]::AllocHGlobal(48)
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new(48), 0, $bufOut, 48)
    [Runtime.InteropServices.Marshal]::WriteInt32($bufOut, 0, 1000071001)

    $fnBufProps.Invoke($pDev, $bufInfo, $bufOut)
    $exportable = [Runtime.InteropServices.Marshal]::ReadInt32($bufOut, 16)
    $features = [Runtime.InteropServices.Marshal]::ReadInt32($bufOut, 24)
    Write-Output "Buffer $name (0x$($ht.ToString('X'))): exportable=$($exportable -band 1), importable=$($exportable -band 2), features=$features"
}
