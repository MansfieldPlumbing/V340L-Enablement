$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$interop = & 'C:\dev\V340L-Emancipated\src\New-WindowsFunctionPointerBinder.ps1'
$vkCreateInstance = $interop.GetExportCall('C:\Windows\System32\vulkan-1.dll', 'vkCreateInstance', [int], @([IntPtr], [IntPtr], [IntPtr]))
$vkEnumeratePhysicalDevices = $interop.GetExportCall('C:\Windows\System32\vulkan-1.dll', 'vkEnumeratePhysicalDevices', [int], @([IntPtr], [IntPtr], [IntPtr]))
$vkGetPhysicalDeviceQueueFamilyProperties = $interop.GetExportCall('C:\Windows\System32\vulkan-1.dll', 'vkGetPhysicalDeviceQueueFamilyProperties', [void], @([IntPtr], [IntPtr], [IntPtr]))

$appInfo = [Runtime.InteropServices.Marshal]::AllocHGlobal(48)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(48), 0, $appInfo, 48)
[Runtime.InteropServices.Marshal]::WriteInt32($appInfo, 44, 0x00401000)
$instCi = [Runtime.InteropServices.Marshal]::AllocHGlobal(64)
[Runtime.InteropServices.Marshal]::Copy([byte[]]::new(64), 0, $instCi, 64)
[Runtime.InteropServices.Marshal]::WriteInt32($instCi, 0, 1)
[Runtime.InteropServices.Marshal]::WriteIntPtr($instCi, 24, $appInfo)
$outInst = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
$null = $vkCreateInstance.Invoke($instCi, [IntPtr]::Zero, $outInst)
$vkInstance = [Runtime.InteropServices.Marshal]::ReadIntPtr($outInst)

$outCount = [Runtime.InteropServices.Marshal]::AllocHGlobal(4)
$null = $vkEnumeratePhysicalDevices.Invoke($vkInstance, $outCount, [IntPtr]::Zero)
$physCount = [Runtime.InteropServices.Marshal]::ReadInt32($outCount)
$physList = [Runtime.InteropServices.Marshal]::AllocHGlobal($physCount * 8)
$null = $vkEnumeratePhysicalDevices.Invoke($vkInstance, $outCount, $physList)
$phys0 = [Runtime.InteropServices.Marshal]::ReadIntPtr($physList, 0)

$outC0 = [Runtime.InteropServices.Marshal]::AllocHGlobal(4)
$vkGetPhysicalDeviceQueueFamilyProperties.Invoke($phys0, $outC0, [IntPtr]::Zero)
$qfCount0 = [Runtime.InteropServices.Marshal]::ReadInt32($outC0)
$qfList0 = [Runtime.InteropServices.Marshal]::AllocHGlobal($qfCount0 * 24)
$vkGetPhysicalDeviceQueueFamilyProperties.Invoke($phys0, $outC0, $qfList0)

$res = for ($f = 0; $f -lt $qfCount0; $f++) {
    $flags = [Runtime.InteropServices.Marshal]::ReadInt32($qfList0, $f * 24)
    $count = [Runtime.InteropServices.Marshal]::ReadInt32($qfList0, $f * 24 + 4)
    [PSCustomObject]@{ Family = $f; FlagsHex = ('0x{0:X2}' -f $flags); FlagsDec = $flags; QueueCount = $count }
}
$res | Format-Table -AutoSize
