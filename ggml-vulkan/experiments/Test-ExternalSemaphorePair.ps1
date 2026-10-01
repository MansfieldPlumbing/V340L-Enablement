function Format-Pointer([IntPtr]$p) { return '0x{0:X16}' -f [uint64]$p.ToInt64() }
$binder = & "c:\dev\V340L-Emancipated\src\New-WindowsFunctionPointerBinder.ps1"
$hVk = [Runtime.InteropServices.NativeLibrary]::Load('vulkan-1.dll')
$vkCreateInstance = $binder.GetExport($hVk, 'vkCreateInstance')
$vkEnumeratePhysicalDevices = $binder.GetExport($hVk, 'vkEnumeratePhysicalDevices')
$vkGetPhysicalDeviceProperties = $binder.GetExport($hVk, 'vkGetPhysicalDeviceProperties')
$vkCreateDevice = $binder.GetExport($hVk, 'vkCreateDevice')
$vkGetDeviceProcAddr = $binder.GetExport($hVk, 'vkGetDeviceProcAddr')

# Create instance
$ci = [Runtime.InteropServices.Marshal]::AllocHGlobal(64)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(64), 0, $ci, 64)
[Runtime.InteropServices.Marshal]::WriteInt32($ci, 0, 1)
$outInst = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
$binder.GetCall($vkCreateInstance, [int], @([IntPtr], [IntPtr], [IntPtr])).Invoke($ci, [IntPtr]::Zero, $outInst)
$inst = [Runtime.InteropServices.Marshal]::ReadIntPtr($outInst)

$outCount = [Runtime.InteropServices.Marshal]::AllocHGlobal(4)
$binder.GetCall($vkEnumeratePhysicalDevices, [int], @([IntPtr], [IntPtr], [IntPtr])).Invoke($inst, $outCount, [IntPtr]::Zero)
$count = [Runtime.InteropServices.Marshal]::ReadInt32($outCount)
$outDevs = [Runtime.InteropServices.Marshal]::AllocHGlobal($count * 8)
$binder.GetCall($vkEnumeratePhysicalDevices, [int], @([IntPtr], [IntPtr], [IntPtr])).Invoke($inst, $outCount, $outDevs)

$fnProps = $binder.GetCall($vkGetPhysicalDeviceProperties, [void], @([IntPtr], [IntPtr]))
$pProps = [Runtime.InteropServices.Marshal]::AllocHGlobal(1024)
$v340Phys = @()
for ($i = 0; $i -lt $count; $i++) {
    $pDev = [Runtime.InteropServices.Marshal]::ReadIntPtr($outDevs, $i * 8)
    $fnProps.Invoke($pDev, $pProps)
    $name = [Runtime.InteropServices.Marshal]::PtrToStringUTF8([IntPtr]::Add($pProps, 20))
    if ($name -match 'V340') { $v340Phys += $pDev }
}

Write-Output "Found $($v340Phys.Count) V340 dies."
if ($v340Phys.Count -lt 2) { throw "Need 2 dies" }

# Create Device 0 with external semaphore export, and Device 1 with import
# Extensions: VK_KHR_external_semaphore, VK_KHR_external_semaphore_win32, VK_KHR_timeline_semaphore
$exts = @(
    'VK_KHR_external_semaphore',
    'VK_KHR_external_semaphore_win32',
    'VK_KHR_timeline_semaphore'
)
$pExtNames = [Runtime.InteropServices.Marshal]::AllocHGlobal($exts.Count * 8)
for ($e = 0; $e -lt $exts.Count; $e++) {
    $pStr = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($exts[$e])
    [Runtime.InteropServices.Marshal]::WriteIntPtr($pExtNames, $e * 8, $pStr)
}

$fnCD = $binder.GetCall($vkCreateDevice, [int], @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
$qci = [Runtime.InteropServices.Marshal]::AllocHGlobal(40)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(40), 0, $qci, 40)
[Runtime.InteropServices.Marshal]::WriteInt32($qci, 0, 2) # sType = QUEUE_CREATE_INFO
[Runtime.InteropServices.Marshal]::WriteInt32($qci, 20, 0) # queueFamilyIndex = 0
[Runtime.InteropServices.Marshal]::WriteInt32($qci, 24, 1) # queueCount = 1
$pPrio = [Runtime.InteropServices.Marshal]::AllocHGlobal(4)
[Runtime.InteropServices.Marshal]::WriteInt32($pPrio, 0, 0x3F800000)
[Runtime.InteropServices.Marshal]::WriteIntPtr($qci, 32, $pPrio)

# PhysicalDeviceTimelineSemaphoreFeatures
$tlFeatures = [Runtime.InteropServices.Marshal]::AllocHGlobal(32)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(32), 0, $tlFeatures, 32)
[Runtime.InteropServices.Marshal]::WriteInt32($tlFeatures, 0, 1000207000) # sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES
[Runtime.InteropServices.Marshal]::WriteInt32($tlFeatures, 16, 1) # timelineSemaphore = VK_TRUE

$dci = [Runtime.InteropServices.Marshal]::AllocHGlobal(72)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(72), 0, $dci, 72)
[Runtime.InteropServices.Marshal]::WriteInt32($dci, 0, 3) # sType = DEVICE_CREATE_INFO
[Runtime.InteropServices.Marshal]::WriteIntPtr($dci, 8, $tlFeatures) # pNext
[Runtime.InteropServices.Marshal]::WriteInt32($dci, 20, 1) # queueCreateInfoCount = 1
[Runtime.InteropServices.Marshal]::WriteIntPtr($dci, 24, $qci)
[Runtime.InteropServices.Marshal]::WriteInt32($dci, 48, $exts.Count)
[Runtime.InteropServices.Marshal]::WriteIntPtr($dci, 56, $pExtNames)

$pDev0 = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
$pDev1 = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
$res0 = $fnCD.Invoke($v340Phys[0], $dci, [IntPtr]::Zero, $pDev0)
$res1 = $fnCD.Invoke($v340Phys[1], $dci, [IntPtr]::Zero, $pDev1)
Write-Output "CreateDevice results: res0=$res0, res1=$res1"

$dev0 = [Runtime.InteropServices.Marshal]::ReadIntPtr($pDev0)
$dev1 = [Runtime.InteropServices.Marshal]::ReadIntPtr($pDev1)

$fnGPA = $binder.GetCall($vkGetDeviceProcAddr, [IntPtr], @([IntPtr], [string]))
$pGetWin32 = $fnGPA.Invoke($dev0, "vkGetSemaphoreWin32HandleKHR")
$pImportWin32 = $fnGPA.Invoke($dev1, "vkImportSemaphoreWin32HandleKHR")
$pCreateSem = $fnGPA.Invoke($dev0, "vkCreateSemaphore")

Write-Output "vkGetSemaphoreWin32HandleKHR: $(Format-Pointer $pGetWin32)"
Write-Output "vkImportSemaphoreWin32HandleKHR: $(Format-Pointer $pImportWin32)"
Write-Output "vkCreateSemaphore: $(Format-Pointer $pCreateSem)"

function Format-Pointer([IntPtr]$p) { return "0x{0:X16}" -f [uint64]$p.ToInt64() }



# 1. Create Exportable Timeline Semaphore on Dev 0
$expInfo = [Runtime.InteropServices.Marshal]::AllocHGlobal(24)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(24), 0, $expInfo, 24)
[Runtime.InteropServices.Marshal]::WriteInt32($expInfo, 0, 1000078000) # VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO
[Runtime.InteropServices.Marshal]::WriteInt32($expInfo, 16, 2) # VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_WIN32_BIT

$tlInfo = [Runtime.InteropServices.Marshal]::AllocHGlobal(32)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(32), 0, $tlInfo, 32)
[Runtime.InteropServices.Marshal]::WriteInt32($tlInfo, 0, 1000207002) # VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO
[Runtime.InteropServices.Marshal]::WriteIntPtr($tlInfo, 8, $expInfo) # pNext -> ExportInfo
[Runtime.InteropServices.Marshal]::WriteInt32($tlInfo, 16, 1) # VK_SEMAPHORE_TYPE_TIMELINE
[Runtime.InteropServices.Marshal]::WriteInt64($tlInfo, 24, 0) # initialValue = 0

$sci = [Runtime.InteropServices.Marshal]::AllocHGlobal(24)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(24), 0, $sci, 24)
[Runtime.InteropServices.Marshal]::WriteInt32($sci, 0, 9) # VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
[Runtime.InteropServices.Marshal]::WriteIntPtr($sci, 8, $tlInfo) # pNext -> TimelineInfo

$pSem0 = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
$fnCreateSem = $binder.GetCall($pCreateSem, [int], @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
$res = $fnCreateSem.Invoke($dev0, $sci, [IntPtr]::Zero, $pSem0)
$sem0 = [Runtime.InteropServices.Marshal]::ReadIntPtr($pSem0)
Write-Output "Create exportable timeline semaphore on Dev0: res=$res, sem=$(Format-Pointer $sem0)"

# 2. Export Win32 Handle from Dev 0
$hInfo = [Runtime.InteropServices.Marshal]::AllocHGlobal(32)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(32), 0, $hInfo, 32)
[Runtime.InteropServices.Marshal]::WriteInt32($hInfo, 0, 1000078001) # VK_STRUCTURE_TYPE_SEMAPHORE_GET_WIN32_HANDLE_INFO_KHR
[Runtime.InteropServices.Marshal]::WriteIntPtr($hInfo, 16, $sem0)
[Runtime.InteropServices.Marshal]::WriteInt32($hInfo, 24, 2) # VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_WIN32_BIT

$pHandle = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
$fnGetWin32 = $binder.GetCall($pGetWin32, [int], @([IntPtr], [IntPtr], [IntPtr]))
$resExport = $fnGetWin32.Invoke($dev0, $hInfo, $pHandle)
$winHandle = [Runtime.InteropServices.Marshal]::ReadIntPtr($pHandle)
Write-Output "Export Win32 handle: res=$resExport, HANDLE=$(Format-Pointer $winHandle)"

# 3. Create Timeline Semaphore on Dev 1 and Import Handle
$tlInfo1 = [Runtime.InteropServices.Marshal]::AllocHGlobal(32)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(32), 0, $tlInfo1, 32)
[Runtime.InteropServices.Marshal]::WriteInt32($tlInfo1, 0, 1000207002)
[Runtime.InteropServices.Marshal]::WriteInt32($tlInfo1, 16, 1) # VK_SEMAPHORE_TYPE_TIMELINE
[Runtime.InteropServices.Marshal]::WriteInt64($tlInfo1, 24, 0)

$sci1 = [Runtime.InteropServices.Marshal]::AllocHGlobal(24)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(24), 0, $sci1, 24)
[Runtime.InteropServices.Marshal]::WriteInt32($sci1, 0, 9)
[Runtime.InteropServices.Marshal]::WriteIntPtr($sci1, 8, $tlInfo1)

$pSem1 = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
$pCreateSem1 = $fnGPA.Invoke($dev1, "vkCreateSemaphore")
$fnCreateSem1 = $binder.GetCall($pCreateSem1, [int], @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
$res = $fnCreateSem1.Invoke($dev1, $sci1, [IntPtr]::Zero, $pSem1)
$sem1 = [Runtime.InteropServices.Marshal]::ReadIntPtr($pSem1)
Write-Output "Create timeline semaphore on Dev1: res=$res, sem=$(Format-Pointer $sem1)"

# Import into Dev 1
$impInfo = [Runtime.InteropServices.Marshal]::AllocHGlobal(40)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(40), 0, $impInfo, 40)
[Runtime.InteropServices.Marshal]::WriteInt32($impInfo, 0, 1000078002) # VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_WIN32_HANDLE_INFO_KHR
[Runtime.InteropServices.Marshal]::WriteIntPtr($impInfo, 16, $sem1)
[Runtime.InteropServices.Marshal]::WriteInt32($impInfo, 24, 2) # VK_SEMAPHORE_IMPORT_TEMPORARY_BIT (or 0 for permanent)
[Runtime.InteropServices.Marshal]::WriteInt32($impInfo, 28, 2) # VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_WIN32_BIT
[Runtime.InteropServices.Marshal]::WriteIntPtr($impInfo, 32, $winHandle)

$fnImportWin32 = $binder.GetCall($pImportWin32, [int], @([IntPtr], [IntPtr]))
$resImport = $fnImportWin32.Invoke($dev1, $impInfo)
Write-Output "Import Win32 handle into Dev1: res=$resImport (0=VK_SUCCESS)"
