[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if ([IntPtr]::Size -ne 8) { throw '64-bit PowerShell required.' }
$api = & 'C:\dev\V340L-Emancipated\src\New-WindowsFunctionPointerBinder.ps1'
$blocks = [Collections.Generic.List[IntPtr]]::new()
function New-ZeroBlock([int]$Size) {
    $block = [Runtime.InteropServices.Marshal]::AllocHGlobal($Size)
    $blocks.Add($block)
    [Runtime.InteropServices.Marshal]::Copy([byte[]]::new($Size), 0, $block, $Size)
    return $block
}
function W32([IntPtr]$Block, [int]$Offset, [int]$Value) {
    [Runtime.InteropServices.Marshal]::WriteInt32($Block, $Offset, $Value)
}
function R32([IntPtr]$Block, [int]$Offset) {
    [Runtime.InteropServices.Marshal]::ReadInt32($Block, $Offset)
}
function WP([IntPtr]$Block, [int]$Offset, [IntPtr]$Value) {
    [Runtime.InteropServices.Marshal]::WriteIntPtr($Block, $Offset, $Value)
}
function Fn([string]$Name, [Type]$ReturnType, [Type[]]$ParameterTypes) {
    $api.GetExportCall('C:\Windows\System32\vulkan-1.dll', $Name, $ReturnType, $ParameterTypes)
}
function Check([int]$Result, [string]$Operation) {
    if ($Result -ne 0) { throw "$Operation returned VkResult=$Result" }
}
$ptr = [IntPtr]
$create = Fn 'vkCreateInstance' ([int]) @($ptr,$ptr,$ptr)
$destroy = Fn 'vkDestroyInstance' ([void]) @($ptr,$ptr)
$enumerate = Fn 'vkEnumeratePhysicalDevices' ([int]) @($ptr,$ptr,$ptr)
$getProperties = Fn 'vkGetPhysicalDeviceProperties' ([void]) @($ptr,$ptr)
$getSemaphoreProperties = Fn 'vkGetPhysicalDeviceExternalSemaphoreProperties' ([void]) @($ptr,$ptr,$ptr)
$getExtensions = Fn 'vkEnumerateDeviceExtensionProperties' ([int]) @($ptr,$ptr,$ptr,$ptr)
$getQueueFamilies = Fn 'vkGetPhysicalDeviceQueueFamilyProperties' ([void]) @($ptr,$ptr,$ptr)
$instance = [IntPtr]::Zero
try {
    $application = New-ZeroBlock 48
    W32 $application 0 0
    W32 $application 44 0x00401000 # Vulkan 1.1
    $createInfo = New-ZeroBlock 64
    W32 $createInfo 0 1
    WP $createInfo 24 $application
    $outInstance = New-ZeroBlock 8
    Check ($create.Invoke($createInfo, [IntPtr]::Zero, $outInstance)) 'vkCreateInstance'
    $instance = [Runtime.InteropServices.Marshal]::ReadIntPtr($outInstance)
    $count = New-ZeroBlock 4
    Check ($enumerate.Invoke($instance, $count, [IntPtr]::Zero)) 'physical device count'
    $deviceCount = R32 $count 0
    $deviceList = New-ZeroBlock ($deviceCount * 8)
    Check ($enumerate.Invoke($instance, $count, $deviceList)) 'physical devices'
    $rows = [Collections.Generic.List[object]]::new()
    for ($ordinal = 0; $ordinal -lt $deviceCount; $ordinal++) {
        $physical = [Runtime.InteropServices.Marshal]::ReadIntPtr($deviceList, $ordinal * 8)
        $properties = New-ZeroBlock 1024
        $getProperties.Invoke($physical, $properties)
        $name = [Runtime.InteropServices.Marshal]::PtrToStringUTF8([IntPtr]::Add($properties,20))
        if ((R32 $properties 8) -ne 0x1002 -or $name -notmatch 'V340') { continue }
        Check ($getExtensions.Invoke($physical, [IntPtr]::Zero, $count, [IntPtr]::Zero)) 'extension count'
        $extensionCount = R32 $count 0
        $extensionList = New-ZeroBlock ($extensionCount * 260)
        Check ($getExtensions.Invoke($physical, [IntPtr]::Zero, $count, $extensionList)) 'extensions'
        $extensions = @()
        for ($extension = 0; $extension -lt $extensionCount; $extension++) {
            $extensionName = [Runtime.InteropServices.Marshal]::PtrToStringUTF8([IntPtr]::Add($extensionList,$extension * 260))
            if ($extensionName -match 'external_(memory_host|semaphore)|timeline_semaphore|vulkan_memory_model') { $extensions += $extensionName }
        }
        $getQueueFamilies.Invoke($physical,$count,[IntPtr]::Zero)
        $queueCount = R32 $count 0
        $queueList = New-ZeroBlock ($queueCount * 24)
        $getQueueFamilies.Invoke($physical,$count,$queueList)
        $queues = @()
        for($family = 0; $family -lt $queueCount; $family++) {
            $queues += [ordered]@{ Family=$family; Flags=(R32 $queueList ($family * 24)); Count=(R32 $queueList ($family * 24 + 4)) }
        }
        $semaphores = @()
        foreach ($kind in @('Binary','Timeline')) {
            foreach ($handle in @(@{Name='OPAQUE_WIN32';Bit=2},@{Name='OPAQUE_WIN32_KMT';Bit=4},@{Name='D3D12_FENCE';Bit=8})) {
                $info = New-ZeroBlock 24
                W32 $info 0 1000076000
                W32 $info 16 $handle.Bit
                if ($kind -eq 'Timeline') {
                    $typeInfo = New-ZeroBlock 32
                    W32 $typeInfo 0 1000207002
                    W32 $typeInfo 16 1
                    WP $info 8 $typeInfo
                }
                $semaphoreProperties = New-ZeroBlock 32
                W32 $semaphoreProperties 0 1000076001
                $getSemaphoreProperties.Invoke($physical,$info,$semaphoreProperties)
                $features = R32 $semaphoreProperties 24
                $semaphores += [ordered]@{
                    Kind=$kind; Handle=$handle.Name; Features=$features
                    Exportable=[bool]($features -band 1); Importable=[bool]($features -band 2)
                    ExportFromImportedHandleTypes=(R32 $semaphoreProperties 16)
                    CompatibleHandleTypes=(R32 $semaphoreProperties 20)
                }
            }
        }
        $rows.Add([ordered]@{PhysicalOrdinal=$ordinal;Name=$name;DriverVersion=(R32 $properties 4);Extensions=$extensions;QueueFamilies=$queues;Semaphores=$semaphores})
    }
    $rows.ToArray() | ConvertTo-Json -Depth 6
} finally {
    if ($instance -ne [IntPtr]::Zero) { $destroy.Invoke($instance,[IntPtr]::Zero) }
    foreach ($block in $blocks) { [Runtime.InteropServices.Marshal]::FreeHGlobal($block) }
}
