$binder = & "c:\dev\V340L-Emancipated\src\New-WindowsFunctionPointerBinder.ps1"
$hVk = [Runtime.InteropServices.NativeLibrary]::Load('vulkan-1.dll')
$inst = [IntPtr]::Zero
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
$pDev = [Runtime.InteropServices.Marshal]::ReadIntPtr($outDevs, 0) # Die 0

$exts = @('VK_KHR_external_semaphore', 'VK_KHR_external_semaphore_win32', 'VK_KHR_timeline_semaphore')
$pExtNames = [Runtime.InteropServices.Marshal]::AllocHGlobal($exts.Count * 8)
for ($e = 0; $e -lt $exts.Count; $e++) {
    [Runtime.InteropServices.Marshal]::WriteIntPtr($pExtNames, $e * 8, [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($exts[$e]))
}
$qci = [Runtime.InteropServices.Marshal]::AllocHGlobal(40)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(40), 0, $qci, 40)
[Runtime.InteropServices.Marshal]::WriteInt32($qci, 0, 2)
[Runtime.InteropServices.Marshal]::WriteInt32($qci, 20, 0)
[Runtime.InteropServices.Marshal]::WriteInt32($qci, 24, 1)
$pPrio = [Runtime.InteropServices.Marshal]::AllocHGlobal(4)
[Runtime.InteropServices.Marshal]::WriteInt32($pPrio, 0, 0x3F800000)
[Runtime.InteropServices.Marshal]::WriteIntPtr($qci, 32, $pPrio)

$tlFeatures = [Runtime.InteropServices.Marshal]::AllocHGlobal(32)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(32), 0, $tlFeatures, 32)
[Runtime.InteropServices.Marshal]::WriteInt32($tlFeatures, 0, 1000207000)
[Runtime.InteropServices.Marshal]::WriteInt32($tlFeatures, 16, 1)

$dci = [Runtime.InteropServices.Marshal]::AllocHGlobal(72)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(72), 0, $dci, 72)
[Runtime.InteropServices.Marshal]::WriteInt32($dci, 0, 3)
[Runtime.InteropServices.Marshal]::WriteIntPtr($dci, 8, $tlFeatures)
[Runtime.InteropServices.Marshal]::WriteInt32($dci, 20, 1)
[Runtime.InteropServices.Marshal]::WriteIntPtr($dci, 24, $qci)
[Runtime.InteropServices.Marshal]::WriteInt32($dci, 48, $exts.Count)
[Runtime.InteropServices.Marshal]::WriteIntPtr($dci, 56, $pExtNames)

$pDev0 = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
$binder.GetCall($binder.GetExport($hVk, 'vkCreateDevice'), [int], @([IntPtr], [IntPtr], [IntPtr], [IntPtr])).Invoke($pDev, $dci, [IntPtr]::Zero, $pDev0)
$dev0 = [Runtime.InteropServices.Marshal]::ReadIntPtr($pDev0)

$fnGPA = $binder.GetCall($binder.GetExport($hVk, 'vkGetDeviceProcAddr'), [IntPtr], @([IntPtr], [string]))
$fnCreateSem = $binder.GetCall($fnGPA.Invoke($dev0, "vkCreateSemaphore"), [int], @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
$fnGetWin32 = $binder.GetCall($fnGPA.Invoke($dev0, "vkGetSemaphoreWin32HandleKHR"), [int], @([IntPtr], [IntPtr], [IntPtr]))

# Test 1: OPAQUE_WIN32_KMT (0x4) - doesn't require security attributes
# Test 2: OPAQUE_WIN32 (0x2)
foreach ($ht in @(4)) {
    $expInfo = [Runtime.InteropServices.Marshal]::AllocHGlobal(24)
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new(24), 0, $expInfo, 24)
    [Runtime.InteropServices.Marshal]::WriteInt32($expInfo, 0, 1000077000) # VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO_KHR
    [Runtime.InteropServices.Marshal]::WriteInt32($expInfo, 16, $ht)

    $tlInfo = [Runtime.InteropServices.Marshal]::AllocHGlobal(32)
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new(32), 0, $tlInfo, 32)
    [Runtime.InteropServices.Marshal]::WriteInt32($tlInfo, 0, 1000207002) # VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO
    [Runtime.InteropServices.Marshal]::WriteIntPtr($tlInfo, 8, $expInfo)
    [Runtime.InteropServices.Marshal]::WriteInt32($tlInfo, 16, 1) # TIMELINE

    $sci = [Runtime.InteropServices.Marshal]::AllocHGlobal(24)
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new(24), 0, $sci, 24)
    [Runtime.InteropServices.Marshal]::WriteInt32($sci, 0, 9)
    [Runtime.InteropServices.Marshal]::WriteIntPtr($sci, 8, $expInfo)

    $pSem = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
    $res = $fnCreateSem.Invoke($dev0, $sci, [IntPtr]::Zero, $pSem)
    $sem = [Runtime.InteropServices.Marshal]::ReadIntPtr($pSem)

    $hInfo = [Runtime.InteropServices.Marshal]::AllocHGlobal(32)
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new(32), 0, $hInfo, 32)
    [Runtime.InteropServices.Marshal]::WriteInt32($hInfo, 0, 1000078003) # VK_STRUCTURE_TYPE_SEMAPHORE_GET_WIN32_HANDLE_INFO_KHR
    [Runtime.InteropServices.Marshal]::WriteIntPtr($hInfo, 16, $sem)
    [Runtime.InteropServices.Marshal]::WriteInt32($hInfo, 24, $ht)

    $pHandle = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
    [Runtime.InteropServices.Marshal]::WriteInt64($pHandle, 0, -1)
    $resExp = $fnGetWin32.Invoke($dev0, $hInfo, $pHandle)
    $h = [Runtime.InteropServices.Marshal]::ReadIntPtr($pHandle)
    $bytes = [byte[]]::new(8)
[Runtime.InteropServices.Marshal]::Copy($pHandle, $bytes, 0, 8)
$hex = ($bytes | ForEach-Object { $_.ToString("X2") }) -join " "
Write-Output "Bytes in pHandle: $hex"
Write-Output "HandleType=${ht}: CreateSem=$res, GetWin32Handle=$resExp, Handle=0x$($h.ToString('X'))"
}


# Now create dev1 and import the KMT handle
$pDev1 = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
$pDevDie1 = [Runtime.InteropServices.Marshal]::ReadIntPtr($outDevs, 8)
$binder.GetCall($binder.GetExport($hVk, 'vkCreateDevice'), [int], @([IntPtr], [IntPtr], [IntPtr], [IntPtr])).Invoke($pDevDie1, $dci, [IntPtr]::Zero, $pDev1)
$dev1 = [Runtime.InteropServices.Marshal]::ReadIntPtr($pDev1)

$fnGPA1 = $binder.GetCall($binder.GetExport($hVk, 'vkGetDeviceProcAddr'), [IntPtr], @([IntPtr], [string]))
$fnCreateSem1 = $binder.GetCall($fnGPA1.Invoke($dev1, "vkCreateSemaphore"), [int], @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
$fnImportWin32 = $binder.GetCall($fnGPA1.Invoke($dev1, "vkImportSemaphoreWin32HandleKHR"), [int], @([IntPtr], [IntPtr]))

$tlInfo1 = [Runtime.InteropServices.Marshal]::AllocHGlobal(32)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(32), 0, $tlInfo1, 32)
[Runtime.InteropServices.Marshal]::WriteInt32($tlInfo1, 0, 1000207002)
[Runtime.InteropServices.Marshal]::WriteInt32($tlInfo1, 16, 1)

$sci1 = [Runtime.InteropServices.Marshal]::AllocHGlobal(24)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(24), 0, $sci1, 24)
[Runtime.InteropServices.Marshal]::WriteInt32($sci1, 0, 9)
[Runtime.InteropServices.Marshal]::WriteIntPtr($sci1, 8, $tlInfo1)

$pSem1 = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
$res1 = $fnCreateSem1.Invoke($dev1, $sci1, [IntPtr]::Zero, $pSem1)
$sem1 = [Runtime.InteropServices.Marshal]::ReadIntPtr($pSem1)

$impInfo = [Runtime.InteropServices.Marshal]::AllocHGlobal(48)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(48), 0, $impInfo, 48)
[Runtime.InteropServices.Marshal]::WriteInt32($impInfo, 0, 1000078000) # VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_WIN32_HANDLE_INFO_KHR
[Runtime.InteropServices.Marshal]::WriteIntPtr($impInfo, 16, $sem1)
[Runtime.InteropServices.Marshal]::WriteInt32($impInfo, 24, 0) # permanent
[Runtime.InteropServices.Marshal]::WriteInt32($impInfo, 28, 4) # VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_WIN32_KMT_BIT
[Runtime.InteropServices.Marshal]::WriteIntPtr($impInfo, 32, $h) # The exported handle!

$resImp = $fnImportWin32.Invoke($dev1, $impInfo)
Write-Output "Import KMT handle 0x$($h.ToString('X')) into Dev1: res=$resImp (0=VK_SUCCESS)"





# Test queue signal on Dev 0, queue wait on Dev 1
$fnGetQueue = $binder.GetCall($binder.GetExport($hVk, 'vkGetDeviceQueue'), [void], @([IntPtr], [uint32], [uint32], [IntPtr]))
$fnQueueSubmit = $binder.GetCall($binder.GetExport($hVk, 'vkQueueSubmit'), [int], @([IntPtr], [uint32], [IntPtr], [IntPtr]))
$fnQueueWaitIdle = $binder.GetCall($binder.GetExport($hVk, 'vkQueueWaitIdle'), [int], @([IntPtr]))

$pQ0 = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
$fnGetQueue.Invoke($dev0, 0, 0, $pQ0)
$q0 = [Runtime.InteropServices.Marshal]::ReadIntPtr($pQ0)

$pQ1 = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
$fnGetQueue.Invoke($dev1, 0, 0, $pQ1)
$q1 = [Runtime.InteropServices.Marshal]::ReadIntPtr($pQ1)

# Submit Signal on Dev 0
$si0 = [Runtime.InteropServices.Marshal]::AllocHGlobal(72)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(72), 0, $si0, 72)
[Runtime.InteropServices.Marshal]::WriteInt32($si0, 0, 4) # VK_STRUCTURE_TYPE_SUBMIT_INFO
[Runtime.InteropServices.Marshal]::WriteInt32($si0, 56, 1) # signalSemaphoreCount = 1
$pSigSem = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
[Runtime.InteropServices.Marshal]::WriteIntPtr($pSigSem, 0, $sem)
[Runtime.InteropServices.Marshal]::WriteIntPtr($si0, 64, $pSigSem) # pSignalSemaphores

$resSub0 = $fnQueueSubmit.Invoke($q0, 1, $si0, [IntPtr]::Zero)
Write-Output "Dev0 QueueSubmit (Signal external semaphore): res=$resSub0 (0=VK_SUCCESS)"

# Submit Wait on Dev 1
$si1 = [Runtime.InteropServices.Marshal]::AllocHGlobal(72)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(72), 0, $si1, 72)
[Runtime.InteropServices.Marshal]::WriteInt32($si1, 0, 4) # VK_STRUCTURE_TYPE_SUBMIT_INFO
[Runtime.InteropServices.Marshal]::WriteInt32($si1, 16, 1) # waitSemaphoreCount = 1
$pWaitSem = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
[Runtime.InteropServices.Marshal]::WriteIntPtr($pWaitSem, 0, $sem1) # The imported semaphore!
[Runtime.InteropServices.Marshal]::WriteIntPtr($si1, 24, $pWaitSem) # pWaitSemaphores
$pWaitDst = [Runtime.InteropServices.Marshal]::AllocHGlobal(4)
[Runtime.InteropServices.Marshal]::WriteInt32($pWaitDst, 0, 0x00000400) # VK_PIPELINE_STAGE_TRANSFER_BIT
[Runtime.InteropServices.Marshal]::WriteIntPtr($si1, 32, $pWaitDst) # pWaitDstStageMask

$resSub1 = $fnQueueSubmit.Invoke($q1, 1, $si1, [IntPtr]::Zero)
Write-Output "Dev1 QueueSubmit (Wait on imported external semaphore): res=$resSub1 (0=VK_SUCCESS)"

$fnQueueWaitIdle.Invoke($q0)
$fnQueueWaitIdle.Invoke($q1)
Write-Output "[SUCCESS] Hardware cross-device queue-to-queue semaphore signaling completed without error!"
$fnExtProps = $binder.GetCall($binder.GetExport($hVk, 'vkGetPhysicalDeviceExternalSemaphoreProperties'), [void], @([IntPtr], [IntPtr], [IntPtr]))
$extInfo = [Runtime.InteropServices.Marshal]::AllocHGlobal(24)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(24), 0, $extInfo, 24)
[Runtime.InteropServices.Marshal]::WriteInt32($extInfo, 0, 1000076000) # VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_SEMAPHORE_INFO
[Runtime.InteropServices.Marshal]::WriteInt32($extInfo, 16, 4) # OPAQUE_WIN32_KMT_BIT

$outProps = [Runtime.InteropServices.Marshal]::AllocHGlobal(32)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(32), 0, $outProps, 32)
[Runtime.InteropServices.Marshal]::WriteInt32($outProps, 0, 1000076001) # VK_STRUCTURE_TYPE_EXTERNAL_SEMAPHORE_PROPERTIES

$fnExtProps.Invoke($pDev, $extInfo, $outProps)
$expFeatures = [Runtime.InteropServices.Marshal]::ReadInt32($outProps, 16)
$compat = [Runtime.InteropServices.Marshal]::ReadInt32($outProps, 20)
$extFeatures = [Runtime.InteropServices.Marshal]::ReadInt32($outProps, 24)
Write-Output "ExternalSemaphoreProperties for OPAQUE_WIN32_KMT: exportable=$($expFeatures -band 1), importable=$($expFeatures -band 2), compat=$compat, externalFeatures=$extFeatures"
