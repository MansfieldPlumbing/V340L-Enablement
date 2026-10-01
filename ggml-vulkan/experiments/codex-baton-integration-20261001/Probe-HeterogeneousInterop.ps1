$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$interop = & 'C:\dev\V340L-Emancipated\src\New-WindowsFunctionPointerBinder.ps1'
$vk = 'C:\Windows\System32\vulkan-1.dll'
function Alloc([int]$n) { $interop.Allocate($n) }
function W32([IntPtr]$p,[int]$o,[int]$v) { [Runtime.InteropServices.Marshal]::WriteInt32($p,$o,$v) }
function WP([IntPtr]$p,[int]$o,[IntPtr]$v) { [Runtime.InteropServices.Marshal]::WriteIntPtr($p,$o,$v) }
function R32([IntPtr]$p,[int]$o) { [Runtime.InteropServices.Marshal]::ReadInt32($p,$o) }
function Check([int]$v,[string]$name) { if ($v -ne 0) { throw "$name VkResult=$v" } }
$create = $interop.GetExportCall($vk,'vkCreateInstance',[int],@([IntPtr],[IntPtr],[IntPtr]))
$enum = $interop.GetExportCall($vk,'vkEnumeratePhysicalDevices',[int],@([IntPtr],[IntPtr],[IntPtr]))
$props = $interop.GetExportCall($vk,'vkGetPhysicalDeviceProperties',[void],@([IntPtr],[IntPtr]))
$exts = $interop.GetExportCall($vk,'vkEnumerateDeviceExtensionProperties',[int],@([IntPtr],[IntPtr],[IntPtr],[IntPtr]))
$queues = $interop.GetExportCall($vk,'vkGetPhysicalDeviceQueueFamilyProperties',[void],@([IntPtr],[IntPtr],[IntPtr]))
$sems = $interop.GetExportCall($vk,'vkGetPhysicalDeviceExternalSemaphoreProperties',[void],@([IntPtr],[IntPtr],[IntPtr]))
$destroy = $interop.GetExportCall($vk,'vkDestroyInstance',[void],@([IntPtr],[IntPtr]))
$app = Alloc 48; W32 $app 0 0; W32 $app 44 ((1 -shl 22) -bor (3 -shl 12))
$ci = Alloc 64; W32 $ci 0 1; WP $ci 24 $app
$out = Alloc 8; Check ($create.Invoke($ci,[IntPtr]::Zero,$out)) 'vkCreateInstance'
$instance = [Runtime.InteropServices.Marshal]::ReadIntPtr($out)
$count = Alloc 4
Check ($enum.Invoke($instance,$count,[IntPtr]::Zero)) 'vkEnumeratePhysicalDevices(count)'
$handles = Alloc ((R32 $count 0)*8)
Check ($enum.Invoke($instance,$count,$handles)) 'vkEnumeratePhysicalDevices'
$rows = @()
for ($d=0; $d -lt (R32 $count 0); $d++) {
    $physical = [Runtime.InteropServices.Marshal]::ReadIntPtr($handles,$d*8)
    $p = Alloc 4096; $props.Invoke($physical,$p)
    $name = [Runtime.InteropServices.Marshal]::PtrToStringAnsi([IntPtr]::Add($p,20))
    $api = R32 $p 0
    $ec = Alloc 4; Check ($exts.Invoke($physical,[IntPtr]::Zero,$ec,[IntPtr]::Zero)) 'extensions(count)'
    $ep = Alloc ((R32 $ec 0)*260); Check ($exts.Invoke($physical,[IntPtr]::Zero,$ec,$ep)) 'extensions'
    $extensionNames = @(for ($i=0;$i -lt (R32 $ec 0);$i++) { [Runtime.InteropServices.Marshal]::PtrToStringAnsi([IntPtr]::Add($ep,$i*260)) })
    $qc = Alloc 4; $queues.Invoke($physical,$qc,[IntPtr]::Zero)
    $qp = Alloc ((R32 $qc 0)*24); $queues.Invoke($physical,$qc,$qp)
    $qrows = @(for ($i=0;$i -lt (R32 $qc 0);$i++) { [ordered]@{ Family=$i; Flags=R32 $qp ($i*24); Count=R32 $qp ($i*24+4); TimestampValidBits=R32 $qp ($i*24+8) } })
    $si = Alloc 24; W32 $si 0 1000076000; W32 $si 16 8
    $sp = Alloc 32; W32 $sp 0 1000076001; $sems.Invoke($physical,$si,$sp)
    $rows += [ordered]@{
        EnumerationIndex=$d; Name=$name; VendorID=R32 $p 8; DeviceID=R32 $p 12
        ApiVersion=('{0}.{1}.{2}' -f (($api -shr 22) -band 127),(($api -shr 12) -band 1023),($api -band 4095))
        ExternalHostMemory=($extensionNames -contains 'VK_EXT_external_memory_host')
        ExternalSemaphore=($extensionNames -contains 'VK_KHR_external_semaphore')
        ExternalSemaphoreWin32=($extensionNames -contains 'VK_KHR_external_semaphore_win32')
        D3D12Fence=[ordered]@{ Features=R32 $sp 24; Importable=(((R32 $sp 24) -band 2) -ne 0); Exportable=(((R32 $sp 24) -band 1) -ne 0); CompatibleHandleTypes=R32 $sp 20 }
        QueueFamilies=$qrows
    }
}
$destroy.Invoke($instance,[IntPtr]::Zero)
$receipt = [ordered]@{ CapturedUtc=[DateTime]::UtcNow.ToString('o'); VulkanLoader=$vk; Devices=$rows }
$json = $receipt | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'heterogeneous-capabilities.json'),$json)
$json
