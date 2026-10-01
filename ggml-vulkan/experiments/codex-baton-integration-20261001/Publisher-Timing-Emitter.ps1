<#
.SYNOPSIS
    Compiles and emits the standalone Antigravity.ProducerPublisher.dll assembly
    using CoreCLR's built-in PersistedAssemblyBuilder without Roslyn, MSBuild, or C++ rebuild.
#>

[CmdletBinding()]
param(
    [string] $OutputPath = 'C:\dev\V340L-Emancipated\scratch\antigravity-publisher-20261001\Antigravity.ProducerPublisher.dll'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([IntPtr]::Size -ne 8) { throw '64-bit PowerShell required.' }

$identity = [Reflection.AssemblyName]::new('Antigravity.ProducerPublisher')
$builder = [Reflection.Emit.PersistedAssemblyBuilder]::new($identity, [object].Assembly)
$module = $builder.DefineDynamicModule('Antigravity.ProducerPublisher.dll')

function Define-NativeDelegateType($mod, [string]$typeName, [Type]$returnType, [Type[]]$paramTypes) {
    $del = $mod.DefineType($typeName, [Reflection.TypeAttributes]'Public,Sealed', [MulticastDelegate])
    $ctor = $del.DefineConstructor(
        [Reflection.MethodAttributes]'Public,HideBySig,RTSpecialName',
        [Reflection.CallingConventions]::Standard,
        @([object], [IntPtr]))
    $ctor.SetImplementationFlags([Reflection.MethodImplAttributes]'Runtime,Managed')
    
    $inv = $del.DefineMethod(
        'Invoke',
        [Reflection.MethodAttributes]'Public,HideBySig,NewSlot,Virtual',
        $returnType,
        $paramTypes)
    $inv.SetImplementationFlags([Reflection.MethodImplAttributes]'Runtime,Managed')
    
    $attrCtor = [Runtime.InteropServices.UnmanagedFunctionPointerAttribute].GetConstructor(@([Runtime.InteropServices.CallingConvention]))
    $del.SetCustomAttribute([Reflection.Emit.CustomAttributeBuilder]::new($attrCtor, @([Runtime.InteropServices.CallingConvention]::Cdecl)))
    
    return $del.CreateType()
}

$delSetup = Define-NativeDelegateType $module 'Antigravity.SetupCallback' ([int]) @(
    [IntPtr], [IntPtr], [int], [IntPtr], [int], [uint64], [uint64]
)
$delPublish = Define-NativeDelegateType $module 'Antigravity.PublishBatchCallback' ([int]) @(
    [uint64], [int], [IntPtr], [IntPtr]
)
$delExtract = Define-NativeDelegateType $module 'Antigravity.ExtractTensorCallback' ([int]) @(
    [IntPtr], [IntPtr], [IntPtr]
)
$delGipa = Define-NativeDelegateType $module 'Antigravity.VkGetInstanceProcAddrCallback' ([IntPtr]) @(
    [IntPtr], [IntPtr]
)
$delCd = Define-NativeDelegateType $module 'Antigravity.VkCreateDeviceCallback' ([int]) @(
    [IntPtr], [IntPtr], [IntPtr], [IntPtr]
)

$type = $module.DefineType('Antigravity.ProducerPublisher', [Reflection.TypeAttributes]'Public,Abstract,Sealed')

# -----------------------------------------------------------------------------
# Static Fields
# -----------------------------------------------------------------------------
$fields = @{}

$fields['TimingQueryPool']=$type.DefineField('TimingQueryPool',[uint64],'Public,Static')
$fields['TimingWriteTimestamp']=$type.DefineField('TimingWriteTimestamp',[IntPtr],'Public,Static')
$fields['TimingResetQueries']=$type.DefineField('TimingResetQueries',[IntPtr],'Public,Static')
$fields['TimingRegionCount']=$type.DefineField('TimingRegionCount',[int],'Public,Static')
# Configuration and Device Handles
$fields['VkDevice'] = $type.DefineField('VkDevice', [IntPtr], 'Public,Static')
$fields['ComputeQueue'] = $type.DefineField('ComputeQueue', [IntPtr], 'Public,Static')
$fields['ComputeQueueFamily'] = $type.DefineField('ComputeQueueFamily', [int], 'Public,Static')
$fields['TransferQueue'] = $type.DefineField('TransferQueue', [IntPtr], 'Public,Static')
$fields['TransferQueueFamily'] = $type.DefineField('TransferQueueFamily', [int], 'Public,Static')
$fields['ApertureBuffer'] = $type.DefineField('ApertureBuffer', [uint64], 'Public,Static')
$fields['D3D12Semaphore'] = $type.DefineField('D3D12Semaphore', [uint64], 'Public,Static')

# Synchronizers & Command Buffers
$fields['SemComputeToTransfer'] = $type.DefineField('SemComputeToTransfer', [uint64], 'Public,Static')
$fields['SemTransferToCompute'] = $type.DefineField('SemTransferToCompute', [uint64], 'Public,Static')
$fields['PoolCompute'] = $type.DefineField('PoolCompute', [uint64], 'Public,Static')
$fields['PoolTransfer'] = $type.DefineField('PoolTransfer', [uint64], 'Public,Static')
$fields['CmdCompute'] = $type.DefineField('CmdCompute', [IntPtr], 'Public,Static')
$fields['CmdTransfer'] = $type.DefineField('CmdTransfer', [IntPtr], 'Public,Static')

# Resolved Vulkan Function Pointers
$fnList = @(
    'pfnCreateCommandPool',
    'pfnAllocateCommandBuffers',
    'pfnBeginCommandBuffer',
    'pfnEndCommandBuffer',
    'pfnCmdPipelineBarrier',
    'pfnCmdCopyBuffer',
    'pfnQueueSubmit',
    'pfnCreateSemaphore'
)
foreach ($fn in $fnList) {
    $fields[$fn] = $type.DefineField($fn, [IntPtr], 'Public,Static')
}

# Pre-allocated native submission memory blocks
$memList = @(
    'pBeginInfo',
    'pComputeBarriers',
    'pTransferAcquireBarriers',
    'pTransferReturnBarriers',
    'pCopyRegion',
    'pTransferRelBarrier',
    'pComputeMemBarrier',
    'pPublicationValue',
    'pD3D12FenceSubmitInfo',
    'pComputeSubmitInfo',
    'pTransferSubmitInfo',
    'pCmdComputeArray',
    'pCmdTransferArray',
    'pSemComputeToTransferArray',
    'pD3D12SemaphoreArray',
    'pStageTransferArray'
)
foreach ($m in $memList) {
    $fields[$m] = $type.DefineField($m, [IntPtr], 'Public,Static')
}

# Hook / Callback Function Pointers for Native Callers
$fields['HookSetupPtr'] = $type.DefineField('HookSetupPtr', [IntPtr], 'Public,Static')
$fields['HookPublishBatchPtr'] = $type.DefineField('HookPublishBatchPtr', [IntPtr], 'Public,Static')
$fields['HookExtractTensorPtr'] = $type.DefineField('HookExtractTensorPtr', [IntPtr], 'Public,Static')
$fields['HookGipaPtr'] = $type.DefineField('HookGipaPtr', [IntPtr], 'Public,Static')
$fields['HookCreateDevicePtr'] = $type.DefineField('HookCreateDevicePtr', [IntPtr], 'Public,Static')
$fields['RealVkGetInstanceProcAddr'] = $type.DefineField('RealVkGetInstanceProcAddr', [IntPtr], 'Public,Static')
$fields['RealVkCreateDevice'] = $type.DefineField('RealVkCreateDevice', [IntPtr], 'Public,Static')
$fields['CreatedDevice0'] = $type.DefineField('CreatedDevice0', [IntPtr], 'Public,Static')
$fields['CreatedDevice1'] = $type.DefineField('CreatedDevice1', [IntPtr], 'Public,Static')
$fields['DeviceCreateCount'] = $type.DefineField('DeviceCreateCount', [int], 'Public,Static')

# Rooted delegates to prevent GC collection
$fields['_delSetupRoot'] = $type.DefineField('_delSetupRoot', [object], 'Public,Static')
$fields['_delPublishRoot'] = $type.DefineField('_delPublishRoot', [object], 'Public,Static')
$fields['_delExtractRoot'] = $type.DefineField('_delExtractRoot', [object], 'Public,Static')
$fields['_delGipaRoot'] = $type.DefineField('_delGipaRoot', [object], 'Public,Static')
$fields['_delCdRoot'] = $type.DefineField('_delCdRoot', [object], 'Public,Static')

# State and Metrics
$fields['PublicationCount'] = $type.DefineField('PublicationCount', [long], 'Public,Static')
$fields['LastPublicationValue'] = $type.DefineField('LastPublicationValue', [uint64], 'Public,Static')
$fields['LastStatus'] = $type.DefineField('LastStatus', [int], 'Public,Static')
$fields['IsInitialized'] = $type.DefineField('IsInitialized', [int], 'Public,Static')

# Reflection cache for Marshal & NativeLibrary methods
$readInt32 = [Runtime.InteropServices.Marshal].GetMethod('ReadInt32', [Type[]]@([IntPtr], [int]))
$readInt64 = [Runtime.InteropServices.Marshal].GetMethod('ReadInt64', [Type[]]@([IntPtr], [int]))
$readIntPtr = [Runtime.InteropServices.Marshal].GetMethod('ReadIntPtr', [Type[]]@([IntPtr], [int]))
$writeInt32 = [Runtime.InteropServices.Marshal].GetMethod('WriteInt32', [Type[]]@([IntPtr], [int], [int]))
$writeInt64 = [Runtime.InteropServices.Marshal].GetMethod('WriteInt64', [Type[]]@([IntPtr], [int], [long]))
$writeIntPtr = [Runtime.InteropServices.Marshal].GetMethod('WriteIntPtr', [Type[]]@([IntPtr], [int], [IntPtr]))
$allocHGlobal = [Runtime.InteropServices.Marshal].GetMethod('AllocHGlobal', [Type[]]@([int]))
$freeHGlobal = [Runtime.InteropServices.Marshal].GetMethod('FreeHGlobal', [Type[]]@([IntPtr]))
$natLibLoad = [Runtime.InteropServices.NativeLibrary].GetMethod('Load', [Type[]]@([string]))
$natLibGetExp = [Runtime.InteropServices.NativeLibrary].GetMethod('GetExport', [Type[]]@([IntPtr], [string]))

# -----------------------------------------------------------------------------
# Helper: InjectExtensions(IntPtr pCreateInfo) -> IntPtr (newCreateInfo)
# -----------------------------------------------------------------------------
$mInjectExt = $type.DefineMethod('InjectExtensions', [Reflection.MethodAttributes]'Public,Static', [IntPtr], @([IntPtr]))
$ilExt = $mInjectExt.GetILGenerator()

$locExtCount = $ilExt.DeclareLocal([int])
$locPpExt = $ilExt.DeclareLocal([IntPtr])
$locNewPpExt = $ilExt.DeclareLocal([IntPtr])
$locNewCi = $ilExt.DeclareLocal([IntPtr])
$locI = $ilExt.DeclareLocal([int])

$strToAnsi = [Runtime.InteropServices.Marshal].GetMethod('StringToHGlobalAnsi', [Type[]]@([string]))

# int extCount = Marshal.ReadInt32(pCreateInfo, 48);
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 48)
$ilExt.Emit([Reflection.Emit.OpCodes]::Call, $readInt32)
$ilExt.Emit([Reflection.Emit.OpCodes]::Stloc, $locExtCount)

# IntPtr ppExt = Marshal.ReadIntPtr(pCreateInfo, 56);
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 56)
$ilExt.Emit([Reflection.Emit.OpCodes]::Call, $readIntPtr)
$ilExt.Emit([Reflection.Emit.OpCodes]::Stloc, $locPpExt)

# Allocate new pointer array: (extCount + 3) * 8 bytes
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locExtCount)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 3)
$ilExt.Emit([Reflection.Emit.OpCodes]::Add)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 8)
$ilExt.Emit([Reflection.Emit.OpCodes]::Mul)
$ilExt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilExt.Emit([Reflection.Emit.OpCodes]::Stloc, $locNewPpExt)

# Copy original extension pointers in a loop: for (i = 0; i < extCount; i++)
$loopStartExt = $ilExt.DefineLabel()
$loopCheckExt = $ilExt.DefineLabel()

$ilExt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilExt.Emit([Reflection.Emit.OpCodes]::Stloc, $locI)
$ilExt.Emit([Reflection.Emit.OpCodes]::Br, $loopCheckExt)

$ilExt.MarkLabel($loopStartExt)
# Marshal.WriteIntPtr(newPpExt, i * 8, Marshal.ReadIntPtr(ppExt, i * 8))
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locNewPpExt)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locI)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 8)
$ilExt.Emit([Reflection.Emit.OpCodes]::Mul)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locPpExt)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locI)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 8)
$ilExt.Emit([Reflection.Emit.OpCodes]::Mul)
$ilExt.Emit([Reflection.Emit.OpCodes]::Call, $readIntPtr)
$ilExt.Emit([Reflection.Emit.OpCodes]::Call, $writeIntPtr)

$ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locI)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilExt.Emit([Reflection.Emit.OpCodes]::Add)
$ilExt.Emit([Reflection.Emit.OpCodes]::Stloc, $locI)

$ilExt.MarkLabel($loopCheckExt)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locI)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locExtCount)
$ilExt.Emit([Reflection.Emit.OpCodes]::Blt, $loopStartExt)

# Append extension 1: VK_KHR_external_semaphore
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locNewPpExt)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locExtCount)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 8)
$ilExt.Emit([Reflection.Emit.OpCodes]::Mul)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldstr, 'VK_KHR_external_semaphore')
$ilExt.Emit([Reflection.Emit.OpCodes]::Call, $strToAnsi)
$ilExt.Emit([Reflection.Emit.OpCodes]::Call, $writeIntPtr)

# Append extension 2: VK_KHR_external_semaphore_win32
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locNewPpExt)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locExtCount)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilExt.Emit([Reflection.Emit.OpCodes]::Add)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 8)
$ilExt.Emit([Reflection.Emit.OpCodes]::Mul)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldstr, 'VK_KHR_external_semaphore_win32')
$ilExt.Emit([Reflection.Emit.OpCodes]::Call, $strToAnsi)
$ilExt.Emit([Reflection.Emit.OpCodes]::Call, $writeIntPtr)

# Append extension 3: VK_EXT_external_memory_host
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locNewPpExt)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locExtCount)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_2)
$ilExt.Emit([Reflection.Emit.OpCodes]::Add)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 8)
$ilExt.Emit([Reflection.Emit.OpCodes]::Mul)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldstr, 'VK_EXT_external_memory_host')
$ilExt.Emit([Reflection.Emit.OpCodes]::Call, $strToAnsi)
$ilExt.Emit([Reflection.Emit.OpCodes]::Call, $writeIntPtr)

# Allocate new VkDeviceCreateInfo (72 bytes) and copy original fields
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 72)
$ilExt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilExt.Emit([Reflection.Emit.OpCodes]::Stloc, $locNewCi)

for ($b = 0; $b -lt 72; $b += 8) {
    $ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locNewCi)
    $ilExt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, $b)
    $ilExt.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
    $ilExt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, $b)
    $ilExt.Emit([Reflection.Emit.OpCodes]::Call, $readInt64)
    $ilExt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)
}

# Update extension count (offset 48) = extCount + 3
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locNewCi)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 48)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locExtCount)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 3)
$ilExt.Emit([Reflection.Emit.OpCodes]::Add)
$ilExt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

# Update ppEnabledExtensionNames (offset 56) = newPpExt
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locNewCi)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 56)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locNewPpExt)
$ilExt.Emit([Reflection.Emit.OpCodes]::Call, $writeIntPtr)

$ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locNewCi)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ret)


# -----------------------------------------------------------------------------
# Hook Method: Hook_VkCreateDevice
# int (IntPtr physicalDevice, IntPtr pCreateInfo, IntPtr pAllocator, IntPtr pDevice)
# -----------------------------------------------------------------------------
$mCreateDev = $type.DefineMethod('Hook_VkCreateDevice', [Reflection.MethodAttributes]'Public,Static', [int], @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
$ilCd = $mCreateDev.GetILGenerator()
$locModCi = $ilCd.DeclareLocal([IntPtr])
$locResCd = $ilCd.DeclareLocal([int])
$locDevHandle = $ilCd.DeclareLocal([IntPtr])

# IntPtr modCi = InjectExtensions(pCreateInfo);
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
$ilCd.Emit([Reflection.Emit.OpCodes]::Call, $mInjectExt)
$ilCd.Emit([Reflection.Emit.OpCodes]::Stloc, $locModCi)

# int res = RealVkCreateDevice(physicalDevice, modCi, pAllocator, pDevice)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldloc, $locModCi)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.RealVkCreateDevice)
$ilCd.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [int], @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
$ilCd.Emit([Reflection.Emit.OpCodes]::Stloc, $locResCd)

# if (res == 0)
$skipRec = $ilCd.DefineLabel()
$lblNotDev0 = $ilCd.DefineLabel()
$lblDoneSave = $ilCd.DefineLabel()

$ilCd.Emit([Reflection.Emit.OpCodes]::Ldloc, $locResCd)
$ilCd.Emit([Reflection.Emit.OpCodes]::Brtrue, $skipRec)

$ilCd.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilCd.Emit([Reflection.Emit.OpCodes]::Call, $readIntPtr)
$ilCd.Emit([Reflection.Emit.OpCodes]::Stloc, $locDevHandle)

# if (DeviceCreateCount == 0) { CreatedDevice0 = devHandle; }
# else if (DeviceCreateCount == 1) { CreatedDevice1 = devHandle; }
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.DeviceCreateCount)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilCd.Emit([Reflection.Emit.OpCodes]::Bne_Un, $lblNotDev0)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldloc, $locDevHandle)
$ilCd.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.CreatedDevice0)
$ilCd.Emit([Reflection.Emit.OpCodes]::Br, $lblDoneSave)

$ilCd.MarkLabel($lblNotDev0)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.DeviceCreateCount)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilCd.Emit([Reflection.Emit.OpCodes]::Bne_Un, $lblDoneSave)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldloc, $locDevHandle)
$ilCd.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.CreatedDevice1)

$ilCd.MarkLabel($lblDoneSave)
# DeviceCreateCount++
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.DeviceCreateCount)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilCd.Emit([Reflection.Emit.OpCodes]::Add)
$ilCd.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.DeviceCreateCount)

$ilCd.MarkLabel($skipRec)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldloc, $locResCd)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ret)


# -----------------------------------------------------------------------------
# Hook Method: Hook_VkGetInstanceProcAddr
# IntPtr (IntPtr instance, IntPtr pName)
# -----------------------------------------------------------------------------
$mGipa = $type.DefineMethod('Hook_VkGetInstanceProcAddr', [Reflection.MethodAttributes]'Public,Static', [IntPtr], @([IntPtr], [IntPtr]))
$ilGipa = $mGipa.GetILGenerator()
$locNameStr = $ilGipa.DeclareLocal([string])
$lblPassThrough = $ilGipa.DefineLabel()

# if (pName == Zero) goto PassThrough
$ilGipa.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
$ilGipa.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblPassThrough)

# string name = Marshal.PtrToStringAnsi(pName)
$ilGipa.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
$ilGipa.Emit([Reflection.Emit.OpCodes]::Call, [Runtime.InteropServices.Marshal].GetMethod('PtrToStringAnsi', [Type[]]@([IntPtr])))
$ilGipa.Emit([Reflection.Emit.OpCodes]::Stloc, $locNameStr)

# if (name == "vkCreateDevice") return HookCreateDevicePtr
$ilGipa.Emit([Reflection.Emit.OpCodes]::Ldloc, $locNameStr)
$ilGipa.Emit([Reflection.Emit.OpCodes]::Ldstr, 'vkCreateDevice')
$strEquals = [string].GetMethod('Equals', [Type[]]@([string], [string]))
$ilGipa.Emit([Reflection.Emit.OpCodes]::Call, $strEquals)
$ilGipa.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblPassThrough)

# Match! Return HookCreateDevicePtr
$ilGipa.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.HookCreateDevicePtr)
$ilGipa.Emit([Reflection.Emit.OpCodes]::Ret)

# PassThrough: return RealVkGetInstanceProcAddr(instance, pName)
$ilGipa.MarkLabel($lblPassThrough)
$ilGipa.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilGipa.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
$ilGipa.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.RealVkGetInstanceProcAddr)
$ilGipa.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [IntPtr], @([IntPtr], [IntPtr]))
$ilGipa.Emit([Reflection.Emit.OpCodes]::Ret)


# -----------------------------------------------------------------------------
# Method: BindDefaultVulkanFunctions
# void BindDefaultVulkanFunctions()
# -----------------------------------------------------------------------------
$mBind = $type.DefineMethod('BindDefaultVulkanFunctions', [Reflection.MethodAttributes]'Public,Static', [void], [Type[]]@())
$ilB = $mBind.GetILGenerator()
$locHVk = $ilB.DeclareLocal([IntPtr])

# IntPtr hVk = NativeLibrary.Load("vulkan-1.dll");
$ilB.Emit([Reflection.Emit.OpCodes]::Ldstr, 'vulkan-1.dll')
$ilB.Emit([Reflection.Emit.OpCodes]::Call, $natLibLoad)
$ilB.Emit([Reflection.Emit.OpCodes]::Stloc, $locHVk)

$exportMap = @{
    'pfnCreateCommandPool'      = 'vkCreateCommandPool'
    'pfnAllocateCommandBuffers' = 'vkAllocateCommandBuffers'
    'pfnBeginCommandBuffer'     = 'vkBeginCommandBuffer'
    'pfnEndCommandBuffer'       = 'vkEndCommandBuffer'
    'pfnCmdPipelineBarrier'     = 'vkCmdPipelineBarrier'
    'pfnCmdCopyBuffer'          = 'vkCmdCopyBuffer'
    'pfnQueueSubmit'            = 'vkQueueSubmit'
    'pfnCreateSemaphore'        = 'vkCreateSemaphore'
}

foreach ($kv in $exportMap.GetEnumerator()) {
    $fName = $kv.Key
    $eName = $kv.Value
    # if (fields[fName] == Zero) fields[fName] = NativeLibrary.GetExport(hVk, eName)
    $lblSkip = $ilB.DefineLabel()
    $ilB.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields[$fName])
    $ilB.Emit([Reflection.Emit.OpCodes]::Brtrue, $lblSkip)

    $ilB.Emit([Reflection.Emit.OpCodes]::Ldloc, $locHVk)
    $ilB.Emit([Reflection.Emit.OpCodes]::Ldstr, $eName)
    $ilB.Emit([Reflection.Emit.OpCodes]::Call, $natLibGetExp)
    $ilB.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields[$fName])

    $ilB.MarkLabel($lblSkip)
}
$ilB.Emit([Reflection.Emit.OpCodes]::Ret)


# -----------------------------------------------------------------------------
# Method: SetFunctionPointers
# void SetFunctionPointers(IntPtr, IntPtr, IntPtr, IntPtr, IntPtr, IntPtr, IntPtr, IntPtr)
# -----------------------------------------------------------------------------
$mSetFp = $type.DefineMethod('SetFunctionPointers', [Reflection.MethodAttributes]'Public,Static', [void], @(
    [IntPtr], [IntPtr], [IntPtr], [IntPtr], [IntPtr], [IntPtr], [IntPtr], [IntPtr]
))
$ilSfp = $mSetFp.GetILGenerator()
for ($i = 0; $i -lt 8; $i++) {
    $ilSfp.Emit([Reflection.Emit.OpCodes]::Ldarg, $i)
    $ilSfp.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields[$fnList[$i]])
}
$ilSfp.Emit([Reflection.Emit.OpCodes]::Ret)


# -----------------------------------------------------------------------------
# Method 1: ExtractTensorBuffer
# int ExtractTensorBuffer(IntPtr pTensor, IntPtr pOutBuffer, IntPtr pOutOffset)
# -----------------------------------------------------------------------------
$mExtract = $type.DefineMethod('ExtractTensorBuffer', [Reflection.MethodAttributes]'Public,Static', [int], @(
    [IntPtr], [IntPtr], [IntPtr]
))
$ilEx = $mExtract.GetILGenerator()
$locBuf = $ilEx.DeclareLocal([IntPtr])
$locBufCtx = $ilEx.DeclareLocal([IntPtr])
$locDevBuf = $ilEx.DeclareLocal([IntPtr])
$locVkBuf = $ilEx.DeclareLocal([long])
$locViewSrc = $ilEx.DeclareLocal([IntPtr])
$locViewOffs = $ilEx.DeclareLocal([long])
$locData = $ilEx.DeclareLocal([IntPtr])
$locBasePtr = $ilEx.DeclareLocal([IntPtr])
$locTotalOffs = $ilEx.DeclareLocal([long])

# if (pTensor == Zero) return -1
$lblExValid = $ilEx.DefineLabel()
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilEx.Emit([Reflection.Emit.OpCodes]::Brtrue, $lblExValid)
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldc_I4_M1)
$ilEx.Emit([Reflection.Emit.OpCodes]::Ret)

$ilEx.MarkLabel($lblExValid)
# IntPtr buffer = Marshal.ReadIntPtr(pTensor, 8);
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 8)
$ilEx.Emit([Reflection.Emit.OpCodes]::Call, $readIntPtr)
$ilEx.Emit([Reflection.Emit.OpCodes]::Stloc, $locBuf)

# IntPtr bufCtx = Marshal.ReadIntPtr(buffer, 0x60);
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldloc, $locBuf)
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x60)
$ilEx.Emit([Reflection.Emit.OpCodes]::Call, $readIntPtr)
$ilEx.Emit([Reflection.Emit.OpCodes]::Stloc, $locBufCtx)

# IntPtr devBuf = Marshal.ReadIntPtr(bufCtx, 0x10);
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldloc, $locBufCtx)
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x10)
$ilEx.Emit([Reflection.Emit.OpCodes]::Call, $readIntPtr)
$ilEx.Emit([Reflection.Emit.OpCodes]::Stloc, $locDevBuf)

# long vkBuf = Marshal.ReadInt64(devBuf, 0);
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldloc, $locDevBuf)
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilEx.Emit([Reflection.Emit.OpCodes]::Call, $readInt64)
$ilEx.Emit([Reflection.Emit.OpCodes]::Stloc, $locVkBuf)

# IntPtr viewSrc = Marshal.ReadIntPtr(pTensor, 0xE8);
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0xE8)
$ilEx.Emit([Reflection.Emit.OpCodes]::Call, $readIntPtr)
$ilEx.Emit([Reflection.Emit.OpCodes]::Stloc, $locViewSrc)

# long viewOffs = Marshal.ReadInt64(pTensor, 0xF0);
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0xF0)
$ilEx.Emit([Reflection.Emit.OpCodes]::Call, $readInt64)
$ilEx.Emit([Reflection.Emit.OpCodes]::Stloc, $locViewOffs)

# IntPtr data = Marshal.ReadIntPtr(pTensor, 0xF8);
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0xF8)
$ilEx.Emit([Reflection.Emit.OpCodes]::Call, $readIntPtr)
$ilEx.Emit([Reflection.Emit.OpCodes]::Stloc, $locData)

# if (viewSrc != Zero) basePtr = Marshal.ReadIntPtr(viewSrc, 0xF8) else basePtr = data
$lblUseData = $ilEx.DefineLabel()
$lblGotBase = $ilEx.DefineLabel()
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldloc, $locViewSrc)
$ilEx.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblUseData)

$ilEx.Emit([Reflection.Emit.OpCodes]::Ldloc, $locViewSrc)
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0xF8)
$ilEx.Emit([Reflection.Emit.OpCodes]::Call, $readIntPtr)
$ilEx.Emit([Reflection.Emit.OpCodes]::Stloc, $locBasePtr)
$ilEx.Emit([Reflection.Emit.OpCodes]::Br, $lblGotBase)

$ilEx.MarkLabel($lblUseData)
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldloc, $locData)
$ilEx.Emit([Reflection.Emit.OpCodes]::Stloc, $locBasePtr)

$ilEx.MarkLabel($lblGotBase)
# totalOffs = (basePtr.ToInt64() - 0x1000) + viewOffs
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldloc, $locBasePtr)
$ilEx.Emit([Reflection.Emit.OpCodes]::Conv_I8)
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x1000)
$ilEx.Emit([Reflection.Emit.OpCodes]::Conv_I8)
$ilEx.Emit([Reflection.Emit.OpCodes]::Sub)
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldloc, $locViewOffs)
$ilEx.Emit([Reflection.Emit.OpCodes]::Add)
$ilEx.Emit([Reflection.Emit.OpCodes]::Stloc, $locTotalOffs)

# if (pOutBuffer != Zero) Marshal.WriteInt64(pOutBuffer, 0, vkBuf);
$lblSkipOutBuf = $ilEx.DefineLabel()
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
$ilEx.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblSkipOutBuf)
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldloc, $locVkBuf)
$ilEx.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)

$ilEx.MarkLabel($lblSkipOutBuf)
# if (pOutOffset != Zero) Marshal.WriteInt64(pOutOffset, 0, totalOffs);
$lblSkipOutOff = $ilEx.DefineLabel()
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
$ilEx.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblSkipOutOff)
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldloc, $locTotalOffs)
$ilEx.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)

$ilEx.MarkLabel($lblSkipOutOff)
$ilEx.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0) # return 0
$ilEx.Emit([Reflection.Emit.OpCodes]::Ret)


# -----------------------------------------------------------------------------
# Method 2: Setup
# int Setup(IntPtr vkDevice, IntPtr computeQueue, int computeQueueFamily, IntPtr transferQueue, int transferQueueFamily, uint64 apertureBuffer, uint64 d3d12Semaphore)
# -----------------------------------------------------------------------------
$mSetup = $type.DefineMethod('Setup', [Reflection.MethodAttributes]'Public,Static', [int], @(
    [IntPtr], [IntPtr], [int], [IntPtr], [int], [uint64], [uint64]
))
$ilSt = $mSetup.GetILGenerator()

# Ensure function pointers are bound
$lblFpBound = $ilSt.DefineLabel()
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pfnCreateSemaphore)
$ilSt.Emit([Reflection.Emit.OpCodes]::Brtrue, $lblFpBound)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $mBind)
$ilSt.MarkLabel($lblFpBound)

# Store configuration
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.VkDevice)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.ComputeQueue)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.ComputeQueueFamily)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.TransferQueue)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldarg_s, 4)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.TransferQueueFamily)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldarg_s, 5)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.ApertureBuffer)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldarg_s, 6)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.D3D12Semaphore)

# Allocate scratch blocks:
# pOut8 = AllocHGlobal(8)
$locOut8 = $ilSt.DeclareLocal([IntPtr])
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locOut8)

# 1. Create SemComputeToTransfer: vkCreateSemaphore(dev, &sci, null, outSem)
# sci: 24 bytes
$locSci = $ilSt.DeclareLocal([IntPtr])
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 24)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locSci)
for ($b = 0; $b -lt 24; $b += 4) {
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSci)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, $b)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)
}
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSci)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 9) # VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$locResSt = $ilSt.DeclareLocal([int])
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSci)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locOut8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pfnCreateSemaphore)
$ilSt.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [int], @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locResSt)

$lblSciOk = $ilSt.DefineLabel()
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locResSt)
$ilSt.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblSciOk)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locResSt)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ret)

$ilSt.MarkLabel($lblSciOk)
# SemComputeToTransfer = (ulong)Marshal.ReadInt64(locOut8, 0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locOut8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $readInt64)
$ilSt.Emit([Reflection.Emit.OpCodes]::Conv_U8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.SemComputeToTransfer)

# 2. Create SemTransferToCompute
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSci)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locOut8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pfnCreateSemaphore)
$ilSt.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [int], @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locResSt)

$lblSciOk2 = $ilSt.DefineLabel()
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locResSt)
$ilSt.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblSciOk2)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locResSt)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ret)

$ilSt.MarkLabel($lblSciOk2)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locOut8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $readInt64)
$ilSt.Emit([Reflection.Emit.OpCodes]::Conv_U8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.SemTransferToCompute)

# Free locSci
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSci)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $freeHGlobal)

# 3. Create Command Pools:
# cpci: 24 bytes
$locCpci = $ilSt.DeclareLocal([IntPtr])
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 24)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locCpci)
for ($b = 0; $b -lt 24; $b += 4) {
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCpci)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, $b)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)
}
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCpci)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 39) # VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCpci)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 16)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 2) # RESET_COMMAND_BUFFER_BIT
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

# Pool for ComputeQueueFamily
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCpci)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 20)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCpci)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locOut8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pfnCreateCommandPool)
$ilSt.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [int], @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locResSt)

$lblCpOk1 = $ilSt.DefineLabel()
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locResSt)
$ilSt.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblCpOk1)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locResSt)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ret)

$ilSt.MarkLabel($lblCpOk1)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locOut8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $readInt64)
$ilSt.Emit([Reflection.Emit.OpCodes]::Conv_U8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.PoolCompute)

# Pool for TransferQueueFamily
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCpci)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 20)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldarg_s, 4)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCpci)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locOut8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pfnCreateCommandPool)
$ilSt.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [int], @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locResSt)

$lblCpOk2 = $ilSt.DefineLabel()
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locResSt)
$ilSt.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblCpOk2)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locResSt)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ret)

$ilSt.MarkLabel($lblCpOk2)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locOut8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $readInt64)
$ilSt.Emit([Reflection.Emit.OpCodes]::Conv_U8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.PoolTransfer)

# Free locCpci
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCpci)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $freeHGlobal)

# 4. Allocate Command Buffers:
# cai: 32 bytes
$locCai = $ilSt.DeclareLocal([IntPtr])
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 32)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locCai)
for ($b = 0; $b -lt 32; $b += 4) {
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCai)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, $b)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)
}
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCai)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 40) # VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCai)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 28)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1) # commandBufferCount = 1
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

# CmdCompute
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCai)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 16)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.PoolCompute)
$ilSt.Emit([Reflection.Emit.OpCodes]::Conv_I8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCai)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locOut8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pfnAllocateCommandBuffers)
$ilSt.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [int], @([IntPtr], [IntPtr], [IntPtr]))
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locResSt)

$lblCbOk1 = $ilSt.DefineLabel()
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locResSt)
$ilSt.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblCbOk1)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locResSt)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ret)

$ilSt.MarkLabel($lblCbOk1)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locOut8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $readIntPtr)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.CmdCompute)

# CmdTransfer
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCai)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 16)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.PoolTransfer)
$ilSt.Emit([Reflection.Emit.OpCodes]::Conv_I8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCai)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locOut8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pfnAllocateCommandBuffers)
$ilSt.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [int], @([IntPtr], [IntPtr], [IntPtr]))
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locResSt)

$lblCbOk2 = $ilSt.DefineLabel()
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locResSt)
$ilSt.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblCbOk2)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locResSt)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ret)

$ilSt.MarkLabel($lblCbOk2)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locOut8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $readIntPtr)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.CmdTransfer)

# Free locCai and locOut8
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCai)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $freeHGlobal)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locOut8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $freeHGlobal)

# 5. Pre-allocate Native Submission Memory Blocks:
# pBeginInfo (32 bytes)
$locBI = $ilSt.DeclareLocal([IntPtr])
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 32)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locBI)
for ($b = 0; $b -lt 32; $b += 4) {
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locBI)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, $b)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)
}
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locBI)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 42) # VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locBI)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 16)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1) # VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locBI)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.pBeginInfo)

# Allocate barrier buffers (3584 bytes each for up to 64 regions)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 3584)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.pComputeBarriers)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 3584)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.pTransferAcquireBarriers)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 3584)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.pTransferReturnBarriers)

# pCopyRegion (24 bytes)
$locCR = $ilSt.DeclareLocal([IntPtr])
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 24)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locCR)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCR)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.pCopyRegion)

# pTransferRelBarrier (24 bytes)
$locTRB = $ilSt.DeclareLocal([IntPtr])
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 24)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locTRB)
for ($b = 0; $b -lt 24; $b += 4) {
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locTRB)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, $b)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)
}
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locTRB)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 46) # VK_STRUCTURE_TYPE_MEMORY_BARRIER
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locTRB)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 16)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x1000) # VK_ACCESS_TRANSFER_WRITE_BIT
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locTRB)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.pTransferRelBarrier)

# pComputeMemBarrier (24 bytes)
$locCMB = $ilSt.DeclareLocal([IntPtr])
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 24)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locCMB)
for ($b = 0; $b -lt 24; $b += 4) {
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCMB)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, $b)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)
}
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCMB)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 46)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCMB)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 16)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x40) # VK_ACCESS_SHADER_WRITE_BIT
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCMB)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 20)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x800) # VK_ACCESS_TRANSFER_READ_BIT
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCMB)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.pComputeMemBarrier)

# pPublicationValue (8 bytes)
$locPV = $ilSt.DeclareLocal([IntPtr])
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locPV)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locPV)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.pPublicationValue)

# pD3D12FenceSubmitInfo (48 bytes)
$locD3D = $ilSt.DeclareLocal([IntPtr])
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 48)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locD3D)
for ($b = 0; $b -lt 48; $b += 4) {
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locD3D)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, $b)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)
}
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locD3D)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 1000078002) # VK_STRUCTURE_TYPE_D3D12_FENCE_SUBMIT_INFO_KHR
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locD3D)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 32)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1) # signalSemaphoreValuesCount = 1
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locD3D)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 40)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locPV)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeIntPtr)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locD3D)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.pD3D12FenceSubmitInfo)

# Array pointers for submits
# pCmdComputeArray (8 bytes)
$locArrCC = $ilSt.DeclareLocal([IntPtr])
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locArrCC)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locArrCC)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.CmdCompute)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeIntPtr)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locArrCC)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.pCmdComputeArray)

# pCmdTransferArray (8 bytes)
$locArrCT = $ilSt.DeclareLocal([IntPtr])
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locArrCT)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locArrCT)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.CmdTransfer)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeIntPtr)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locArrCT)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.pCmdTransferArray)

# pSemComputeToTransferArray (8 bytes)
$locArrSCT = $ilSt.DeclareLocal([IntPtr])
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locArrSCT)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locArrSCT)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.SemComputeToTransfer)
$ilSt.Emit([Reflection.Emit.OpCodes]::Conv_I8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locArrSCT)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.pSemComputeToTransferArray)

# pD3D12SemaphoreArray (8 bytes)
$locArrD12 = $ilSt.DeclareLocal([IntPtr])
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locArrD12)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locArrD12)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldarg_s, 6) # D3D12Semaphore
$ilSt.Emit([Reflection.Emit.OpCodes]::Conv_I8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locArrD12)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.pD3D12SemaphoreArray)

# pStageTransferArray (4 bytes)
$locArrStg = $ilSt.DeclareLocal([IntPtr])
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 4)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locArrStg)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locArrStg)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x1000) # VK_PIPELINE_STAGE_TRANSFER_BIT
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locArrStg)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.pStageTransferArray)

# pComputeSubmitInfo (72 bytes)
$locSubC = $ilSt.DeclareLocal([IntPtr])
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 72)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locSubC)
for ($b = 0; $b -lt 72; $b += 4) {
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSubC)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, $b)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)
}
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSubC)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 4) # VK_STRUCTURE_TYPE_SUBMIT_INFO
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSubC)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 40)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1) # commandBufferCount = 1
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSubC)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 48)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locArrCC)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeIntPtr)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSubC)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 56)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1) # signalSemaphoreCount = 1
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSubC)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 64)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locArrSCT)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeIntPtr)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSubC)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.pComputeSubmitInfo)

# pTransferSubmitInfo (72 bytes)
$locSubT = $ilSt.DeclareLocal([IntPtr])
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 72)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $allocHGlobal)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stloc, $locSubT)
for ($b = 0; $b -lt 72; $b += 4) {
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSubT)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, $b)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
    $ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)
}
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSubT)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 4) # VK_STRUCTURE_TYPE_SUBMIT_INFO
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSubT)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 8)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locD3D) # pNext = pD3D12FenceSubmitInfo
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeIntPtr)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSubT)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 16)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1) # waitSemaphoreCount = 1
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSubT)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 24)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locArrSCT) # pWaitSemaphores
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeIntPtr)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSubT)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 32)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locArrStg) # pWaitDstStageMask
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeIntPtr)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSubT)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 40)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1) # commandBufferCount = 1
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSubT)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 48)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locArrCT) # pCommandBuffers
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeIntPtr)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSubT)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 56)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1) # signalSemaphoreCount = 1
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSubT)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 64)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locArrD12) # pSignalSemaphores (D3D12 fence)
$ilSt.Emit([Reflection.Emit.OpCodes]::Call, $writeIntPtr)
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSubT)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.pTransferSubmitInfo)

# Mark initialized
$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilSt.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.IsInitialized)

$ilSt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0) # return 0
$ilSt.Emit([Reflection.Emit.OpCodes]::Ret)


# -----------------------------------------------------------------------------
# Method 3: PublishBatch
# int PublishBatch(uint64 publicationValue, int regionCount, IntPtr pRegions, IntPtr pConsumerWaitOut)
# -----------------------------------------------------------------------------
$mPub = $type.DefineMethod('PublishBatch', [Reflection.MethodAttributes]'Public,Static', [int], @(
    [uint64], [int], [IntPtr], [IntPtr]
))
$ilPb = $mPub.GetILGenerator()
# Integration bound: each publisher owns one publication and unique command resources.
$oneShotOK = $ilPb.DefineLabel()
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.PublicationCount)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I8, [long]0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Beq, $oneShotOK)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, -1001)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ret)
$ilPb.MarkLabel($oneShotOK)
$regionsBoundOK = $ilPb.DefineLabel()
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 64)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ble, $regionsBoundOK)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, -1002)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ret)
$ilPb.MarkLabel($regionsBoundOK)

$locRes = $ilPb.DeclareLocal([int])
$locI = $ilPb.DeclareLocal([int])
$locCurBar = $ilPb.DeclareLocal([IntPtr])
$locCurReg = $ilPb.DeclareLocal([IntPtr])
$locSrcBuf = $ilPb.DeclareLocal([long])
$locSrcOff = $ilPb.DeclareLocal([long])
$locArenaOff = $ilPb.DeclareLocal([long])
$locBytes = $ilPb.DeclareLocal([long])

# Validate inputs: if (regionCount <= 0 || pRegions == Zero) return -1
$lblValidPb = $ilPb.DefineLabel()
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_1) # regionCount
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Bgt, $lblValidPb)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_M1)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ret)

$ilPb.MarkLabel($lblValidPb)
$lblRegPtrOk = $ilPb.DefineLabel()
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
$ilPb.Emit([Reflection.Emit.OpCodes]::Brtrue, $lblRegPtrOk)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_M1)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ret)

$ilPb.MarkLabel($lblRegPtrOk)

# -----------------------------------------------------------------------------
# STEP A: Record Producer Compute Command Buffer
# -----------------------------------------------------------------------------
# vkBeginCommandBuffer(CmdCompute, pBeginInfo)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.CmdCompute)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pBeginInfo)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pfnBeginCommandBuffer)
$ilPb.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [int], @([IntPtr], [IntPtr]))
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locRes)

$lblBeginCOk = $ilPb.DefineLabel()
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locRes)
$ilPb.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblBeginCOk)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locRes)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ret)

$ilPb.MarkLabel($lblBeginCOk)

# Check if ComputeQueueFamily != TransferQueueFamily
$lblSameQfC = $ilPb.DefineLabel()
$lblDoneBarrierC = $ilPb.DefineLabel()
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.ComputeQueueFamily)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.TransferQueueFamily)
$ilPb.Emit([Reflection.Emit.OpCodes]::Beq, $lblSameQfC)

# --- Exclusive ownership RELEASE loop on Compute Queue ---
$loopStartC = $ilPb.DefineLabel()
$loopCheckC = $ilPb.DefineLabel()

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locI)
$ilPb.Emit([Reflection.Emit.OpCodes]::Br, $loopCheckC)

$ilPb.MarkLabel($loopStartC)
# curBar = pComputeBarriers + i * 56
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pComputeBarriers)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locI)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 56)
$ilPb.Emit([Reflection.Emit.OpCodes]::Mul)
$ilPb.Emit([Reflection.Emit.OpCodes]::Add)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locCurBar)

# curReg = pRegions + i * 32
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locI)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 32)
$ilPb.Emit([Reflection.Emit.OpCodes]::Mul)
$ilPb.Emit([Reflection.Emit.OpCodes]::Add)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locCurReg)

# Read region fields
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurReg)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $readInt64)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locSrcBuf)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurReg)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 8)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $readInt64)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locSrcOff)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurReg)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 24)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $readInt64)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locBytes)

# Zero out 56 bytes of barrier
for ($b = 0; $b -lt 56; $b += 4) {
    $ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
    $ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, $b)
    $ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
    $ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)
}

# sType = 44 (VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 44)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

# srcAccessMask = 0x40 (VK_ACCESS_SHADER_WRITE_BIT)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 16)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x40)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

# dstAccessMask = 0
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 20)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

# srcQueueFamilyIndex = ComputeQueueFamily
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 24)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.ComputeQueueFamily)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

# dstQueueFamilyIndex = TransferQueueFamily
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 28)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.TransferQueueFamily)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

# buffer = srcBuf
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 32)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSrcBuf)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)

# offset = srcOff
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 40)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSrcOff)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)

# size = byteCount
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 48)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locBytes)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)

# i++
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locI)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilPb.Emit([Reflection.Emit.OpCodes]::Add)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locI)

# loopCheckC
$ilPb.MarkLabel($loopCheckC)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locI)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_1) # regionCount
$ilPb.Emit([Reflection.Emit.OpCodes]::Blt, $loopStartC)

# vkCmdPipelineBarrier(CmdCompute, COMPUTE_SHADER (0x800), BOTTOM_OF_PIPE (0x2000), 0, 0, null, regionCount, pComputeBarriers, 0, null)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.CmdCompute)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x800)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x2000)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_1) # regionCount
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pComputeBarriers)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pfnCmdPipelineBarrier)
$ilPb.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [void], @(
    [IntPtr], [uint32], [uint32], [uint32], [uint32], [IntPtr], [uint32], [IntPtr], [uint32], [IntPtr]
))
$ilPb.Emit([Reflection.Emit.OpCodes]::Br, $lblDoneBarrierC)

# Same Qf branch:
$ilPb.MarkLabel($lblSameQfC)
# vkCmdPipelineBarrier(CmdCompute, COMPUTE_SHADER (0x800), TRANSFER (0x1000), 0, 1, pComputeMemBarrier, 0, null, 0, null)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.CmdCompute)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x800)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x1000)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pComputeMemBarrier)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pfnCmdPipelineBarrier)
$ilPb.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [void], @(
    [IntPtr], [uint32], [uint32], [uint32], [uint32], [IntPtr], [uint32], [IntPtr], [uint32], [IntPtr]
))

$ilPb.MarkLabel($lblDoneBarrierC)

# End Compute Command Buffer
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.CmdCompute)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pfnEndCommandBuffer)
$ilPb.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [int], @([IntPtr]))
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locRes)

$lblEndCOk = $ilPb.DefineLabel()
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locRes)
$ilPb.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblEndCOk)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locRes)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ret)

$ilPb.MarkLabel($lblEndCOk)

# Submit Compute Queue: vkQueueSubmit(ComputeQueue, 1, pComputeSubmitInfo, 0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.ComputeQueue)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pComputeSubmitInfo)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Conv_U8)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pfnQueueSubmit)
$ilPb.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [int], @([IntPtr], [uint32], [IntPtr], [uint64]))
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locRes)

$lblSubCOk = $ilPb.DefineLabel()
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locRes)
$ilPb.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblSubCOk)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locRes)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ret)

$ilPb.MarkLabel($lblSubCOk)

# -----------------------------------------------------------------------------
# STEP B: Record Dedicated Transfer Command Buffer
# -----------------------------------------------------------------------------
# vkBeginCommandBuffer(CmdTransfer, pBeginInfo)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.CmdTransfer)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pBeginInfo)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pfnBeginCommandBuffer)
$ilPb.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [int], @([IntPtr], [IntPtr]))
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locRes)

$lblBeginTOk = $ilPb.DefineLabel()
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locRes)
$ilPb.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblBeginTOk)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locRes)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ret)

$ilPb.MarkLabel($lblBeginTOk)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stsfld,$fields.TimingRegionCount)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld,$fields.CmdTransfer)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld,$fields.TimingQueryPool)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4,0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4,2)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld,$fields.TimingResetQueries)
$ilPb.EmitCalli([Reflection.Emit.OpCodes]::Calli,[Runtime.InteropServices.CallingConvention]::Cdecl,[void],@([IntPtr],[uint64],[uint32],[uint32]))

# Check if ComputeQueueFamily != TransferQueueFamily for ACQUIRE barrier
$lblSkipAcqT = $ilPb.DefineLabel()
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.ComputeQueueFamily)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.TransferQueueFamily)
$ilPb.Emit([Reflection.Emit.OpCodes]::Beq, $lblSkipAcqT)

# --- Exclusive ownership ACQUIRE loop on Transfer Queue ---
$loopStartTAcq = $ilPb.DefineLabel()
$loopCheckTAcq = $ilPb.DefineLabel()

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locI)
$ilPb.Emit([Reflection.Emit.OpCodes]::Br, $loopCheckTAcq)

$ilPb.MarkLabel($loopStartTAcq)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pTransferAcquireBarriers)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locI)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 56)
$ilPb.Emit([Reflection.Emit.OpCodes]::Mul)
$ilPb.Emit([Reflection.Emit.OpCodes]::Add)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locCurBar)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locI)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 32)
$ilPb.Emit([Reflection.Emit.OpCodes]::Mul)
$ilPb.Emit([Reflection.Emit.OpCodes]::Add)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locCurReg)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurReg)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $readInt64)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locSrcBuf)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurReg)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 8)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $readInt64)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locSrcOff)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurReg)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 24)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $readInt64)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locBytes)

for ($b = 0; $b -lt 56; $b += 4) {
    $ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
    $ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, $b)
    $ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
    $ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)
}

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 44)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

# srcAccessMask = 0
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 16)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

# dstAccessMask = 0x800 (VK_ACCESS_TRANSFER_READ_BIT)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 20)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x800)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 24)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.ComputeQueueFamily)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 28)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.TransferQueueFamily)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 32)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSrcBuf)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 40)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSrcOff)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 48)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locBytes)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locI)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilPb.Emit([Reflection.Emit.OpCodes]::Add)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locI)

# loopCheckTAcq
$ilPb.MarkLabel($loopCheckTAcq)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locI)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
$ilPb.Emit([Reflection.Emit.OpCodes]::Blt, $loopStartTAcq)

# vkCmdPipelineBarrier(CmdTransfer, TRANSFER (0x1000), TRANSFER (0x1000), 0, 0, null, regionCount, pTransferAcquireBarriers, 0, null)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.CmdTransfer)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x1000)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x1000)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_1) # regionCount
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pTransferAcquireBarriers)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pfnCmdPipelineBarrier)
$ilPb.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [void], @(
    [IntPtr], [uint32], [uint32], [uint32], [uint32], [IntPtr], [uint32], [IntPtr], [uint32], [IntPtr]
))

$ilPb.MarkLabel($lblSkipAcqT)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld,$fields.CmdTransfer)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4,0x10000)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld,$fields.TimingQueryPool)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4,0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld,$fields.TimingWriteTimestamp)
$ilPb.EmitCalli([Reflection.Emit.OpCodes]::Calli,[Runtime.InteropServices.CallingConvention]::Cdecl,[void],@([IntPtr],[uint32],[uint64],[uint32]))
# --- Batched Copy into Aperture Buffer Loop ---
$loopStartCopy = $ilPb.DefineLabel()
$loopCheckCopy = $ilPb.DefineLabel()

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locI)
$ilPb.Emit([Reflection.Emit.OpCodes]::Br, $loopCheckCopy)

$ilPb.MarkLabel($loopStartCopy)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locI)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 32)
$ilPb.Emit([Reflection.Emit.OpCodes]::Mul)
$ilPb.Emit([Reflection.Emit.OpCodes]::Add)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locCurReg)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurReg)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $readInt64)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locSrcBuf)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurReg)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 8)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $readInt64)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locSrcOff)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurReg)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 16)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $readInt64)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locArenaOff)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurReg)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 24)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $readInt64)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locBytes)

# Fill pCopyRegion (24 bytes): srcOffset at 0, dstOffset at 8, size at 16
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pCopyRegion)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSrcOff)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pCopyRegion)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 8)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locArenaOff)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pCopyRegion)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 16)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locBytes)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)

# vkCmdCopyBuffer(CmdTransfer, srcBuf, ApertureBuffer, 1, pCopyRegion)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.CmdTransfer)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSrcBuf)
$ilPb.Emit([Reflection.Emit.OpCodes]::Conv_U8)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.ApertureBuffer)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pCopyRegion)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pfnCmdCopyBuffer)
$ilPb.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [void], @(
    [IntPtr], [uint64], [uint64], [uint32], [IntPtr]
))

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locI)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilPb.Emit([Reflection.Emit.OpCodes]::Add)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locI)

# loopCheckCopy
$ilPb.MarkLabel($loopCheckCopy)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locI)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
$ilPb.Emit([Reflection.Emit.OpCodes]::Blt, $loopStartCopy)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld,$fields.CmdTransfer)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4,0x10000)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld,$fields.TimingQueryPool)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4,1)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld,$fields.TimingWriteTimestamp)
$ilPb.EmitCalli([Reflection.Emit.OpCodes]::Calli,[Runtime.InteropServices.CallingConvention]::Cdecl,[void],@([IntPtr],[uint32],[uint64],[uint32]))
# --- Release Barrier before D3D12 Fence Signal ---
# vkCmdPipelineBarrier(CmdTransfer, TRANSFER (0x1000), BOTTOM_OF_PIPE (0x2000), 0, 1, pTransferRelBarrier, 0, null, 0, null)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.CmdTransfer)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x1000)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x2000)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pTransferRelBarrier)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pfnCmdPipelineBarrier)
$ilPb.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [void], @(
    [IntPtr], [uint32], [uint32], [uint32], [uint32], [IntPtr], [uint32], [IntPtr], [uint32], [IntPtr]
))

# --- Transfer-to-Compute Return Dependency Barrier ---
$lblSkipRetT = $ilPb.DefineLabel()
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.ComputeQueueFamily)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.TransferQueueFamily)
$ilPb.Emit([Reflection.Emit.OpCodes]::Beq, $lblSkipRetT)

$loopStartTRet = $ilPb.DefineLabel()
$loopCheckTRet = $ilPb.DefineLabel()

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locI)
$ilPb.Emit([Reflection.Emit.OpCodes]::Br, $loopCheckTRet)

$ilPb.MarkLabel($loopStartTRet)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pTransferReturnBarriers)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locI)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 56)
$ilPb.Emit([Reflection.Emit.OpCodes]::Mul)
$ilPb.Emit([Reflection.Emit.OpCodes]::Add)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locCurBar)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locI)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 32)
$ilPb.Emit([Reflection.Emit.OpCodes]::Mul)
$ilPb.Emit([Reflection.Emit.OpCodes]::Add)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locCurReg)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurReg)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $readInt64)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locSrcBuf)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurReg)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 8)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $readInt64)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locSrcOff)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurReg)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 24)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $readInt64)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locBytes)

for ($b = 0; $b -lt 56; $b += 4) {
    $ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
    $ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, $b)
    $ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
    $ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)
}

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 44)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

# srcAccessMask = 0x800 (VK_ACCESS_TRANSFER_READ_BIT)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 16)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x800)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

# dstAccessMask = 0
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 20)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

# srcQueueFamilyIndex = TransferQueueFamily
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 24)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.TransferQueueFamily)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

# dstQueueFamilyIndex = ComputeQueueFamily
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 28)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.ComputeQueueFamily)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 32)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSrcBuf)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 40)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locSrcOff)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCurBar)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 48)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locBytes)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locI)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilPb.Emit([Reflection.Emit.OpCodes]::Add)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locI)

# loopCheckTRet
$ilPb.MarkLabel($loopCheckTRet)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locI)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
$ilPb.Emit([Reflection.Emit.OpCodes]::Blt, $loopStartTRet)

# vkCmdPipelineBarrier(CmdTransfer, TRANSFER (0x1000), BOTTOM_OF_PIPE (0x2000), 0, 0, null, regionCount, pTransferReturnBarriers, 0, null)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.CmdTransfer)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x1000)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x2000)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pTransferReturnBarriers)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pfnCmdPipelineBarrier)
$ilPb.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [void], @(
    [IntPtr], [uint32], [uint32], [uint32], [uint32], [IntPtr], [uint32], [IntPtr], [uint32], [IntPtr]
))

$ilPb.MarkLabel($lblSkipRetT)

# End Transfer Command Buffer
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.CmdTransfer)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pfnEndCommandBuffer)
$ilPb.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [int], @([IntPtr]))
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locRes)

$lblEndTOk = $ilPb.DefineLabel()
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locRes)
$ilPb.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblEndTOk)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locRes)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ret)

$ilPb.MarkLabel($lblEndTOk)

# -----------------------------------------------------------------------------
# STEP C: Submit Dedicated Transfer Queue
# -----------------------------------------------------------------------------
# Update publication value in pPublicationValue
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pPublicationValue)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_0) # publicationValue
$ilPb.Emit([Reflection.Emit.OpCodes]::Conv_I8)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)

# vkQueueSubmit(TransferQueue, 1, pTransferSubmitInfo, 0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.TransferQueue)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pTransferSubmitInfo)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Conv_U8)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.pfnQueueSubmit)
$ilPb.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [int], @([IntPtr], [uint32], [IntPtr], [uint64]))
$ilPb.Emit([Reflection.Emit.OpCodes]::Stloc, $locRes)

$lblSubTOk = $ilPb.DefineLabel()
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locRes)
$ilPb.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblSubTOk)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldloc, $locRes)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ret)

$ilPb.MarkLabel($lblSubTOk)

# -----------------------------------------------------------------------------
# STEP D: Populate Consumer Wait Requirement
# -----------------------------------------------------------------------------
# if (pConsumerWaitOut != Zero)
$lblSkipWaitOut = $ilPb.DefineLabel()
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
$ilPb.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblSkipWaitOut)

# D3D12FenceSemaphore at offset 0
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.D3D12Semaphore)
$ilPb.Emit([Reflection.Emit.OpCodes]::Conv_I8)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)

# PublicationValue at offset 8
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 8)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Conv_I8)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt64)

# WaitStageMask = 0x800 (COMPUTE_SHADER) at offset 16
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 16)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x800)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

# Status = 0 (VK_SUCCESS) at offset 20
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 20)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Call, $writeInt32)

$ilPb.MarkLabel($lblSkipWaitOut)

# Update metrics
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.LastStatus)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.LastPublicationValue)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.PublicationCount)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilPb.Emit([Reflection.Emit.OpCodes]::Conv_I8)
$ilPb.Emit([Reflection.Emit.OpCodes]::Add)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.PublicationCount)

$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0) # return 0
$ilPb.Emit([Reflection.Emit.OpCodes]::Ret)

# Bake Type
$createdType = $type.CreateType()
Write-Host "Created type: $($createdType.FullName)" -ForegroundColor Cyan

# Save assembly
$builder.Save($OutputPath)
$bytes = (Get-Item -LiteralPath $OutputPath).Length
Write-Host "Emitted publisher assembly successfully saved to: $OutputPath ($bytes bytes)" -ForegroundColor Green
