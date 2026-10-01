<#
.SYNOPSIS
    Compiles and emits the standalone V340L-LlamaBatonShim.dll managed assembly
    using CoreCLR's built-in PersistedAssemblyBuilder without Roslyn or MSBuild.
#>

[CmdletBinding()]
param(
    [string] $OutputPath = 'C:\dev\V340L-Emancipated\runtime-stock\V340L-LlamaBatonShim.dll'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([IntPtr]::Size -ne 8) { throw '64-bit PowerShell required.' }

$identity = [Reflection.AssemblyName]::new('V340L.LlamaBatonShim')
$builder = [Reflection.Emit.PersistedAssemblyBuilder]::new($identity, [object].Assembly)
$module = $builder.DefineDynamicModule('V340L.LlamaBatonShim.dll')

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

$delGipa = Define-NativeDelegateType $module 'V340L.VkGetInstanceProcAddrCallback' ([IntPtr]) @([IntPtr], [IntPtr])
$delCd = Define-NativeDelegateType $module 'V340L.VkCreateDeviceCallback' ([int]) @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
$delCpy = Define-NativeDelegateType $module 'V340L.CpyTensorAsyncCallback' ([bool]) @([IntPtr], [IntPtr], [IntPtr], [IntPtr])
$delInit = Define-NativeDelegateType $module 'V340L.InitBackendCallback' ([IntPtr]) @([IntPtr], [IntPtr])

$type = $module.DefineType('V340L.LlamaBatonShim', [Reflection.TypeAttributes]'Public,Abstract,Sealed')

# -----------------------------------------------------------------------------
# Fields
# -----------------------------------------------------------------------------
$fields = @{}
foreach ($name in @(
    'RealVkGetInstanceProcAddr',
    'RealVkCreateDevice',
    'HookCreateDevicePtr',
    'RealInitBackend0',
    'RealInitBackend1',
    'HookInitBackend0Ptr',
    'HookInitBackend1Ptr',
    'HookCpyTensorAsyncPtr',
    'SourceBackend',
    'DestinationBackend',
    'OriginalCpyTensorAsync',
    'VkQueueSubmit',
    'Dev0Queue',
    'Dev1Queue',
    'SigSubmitInfo',
    'WaitSubmitInfo',
    'SigFenceValPtr',
    'WaitFenceValPtr',
    'SourceBridge',
    'DestinationBuffer',
    'GgmlNBytesFn',
    'HookResolveWaitPtr',
    'CreatedPhysicalDevice0',
    'CreatedPhysicalDevice1'
)) {
    $fields[$name] = $type.DefineField($name, [IntPtr], 'Public,Static')
}

$fields['CurrentFenceValue'] = $type.DefineField('CurrentFenceValue', [uint64], 'Public,Static')
$fields['ApertureCursor'] = $type.DefineField('ApertureCursor', [long], 'Public,Static')
$fields['ApertureCapacity'] = $type.DefineField('ApertureCapacity', [uint64], 'Public,Static')
$fields['HandledHandoffs'] = $type.DefineField('HandledHandoffs', [long], 'Public,Static')
$fields['FallbackHandoffs'] = $type.DefineField('FallbackHandoffs', [long], 'Public,Static')
$fields['LastCreatedDevice'] = $type.DefineField('LastCreatedDevice', [IntPtr], 'Public,Static')
$fields['CreatedDevice0'] = $type.DefineField('CreatedDevice0', [IntPtr], 'Public,Static')
$fields['CreatedDevice1'] = $type.DefineField('CreatedDevice1', [IntPtr], 'Public,Static')
$fields['DeviceCreateCount'] = $type.DefineField('DeviceCreateCount', [int], 'Public,Static')

# -----------------------------------------------------------------------------
# Helper Methods: Native Marshaling & Extension Injection
# -----------------------------------------------------------------------------
# Helper: InjectExtensions(IntPtr pCreateInfo) -> IntPtr (newCreateInfo)
$mInjectExt = $type.DefineMethod('InjectExtensions', [Reflection.MethodAttributes]'Public,Static', [IntPtr], @([IntPtr]))
$ilExt = $mInjectExt.GetILGenerator()

# Local variables:
$locExtCount = $ilExt.DeclareLocal([int])
$locPpExt = $ilExt.DeclareLocal([IntPtr])
$locNewPpExt = $ilExt.DeclareLocal([IntPtr])
$locNewCi = $ilExt.DeclareLocal([IntPtr])
$locI = $ilExt.DeclareLocal([int])

# int extCount = Marshal.ReadInt32(pCreateInfo, 48);
$readInt32 = [Runtime.InteropServices.Marshal].GetMethod('ReadInt32', [Type[]]@([IntPtr], [int]))
$readIntPtr = [Runtime.InteropServices.Marshal].GetMethod('ReadIntPtr', [Type[]]@([IntPtr], [int]))
$writeInt32 = [Runtime.InteropServices.Marshal].GetMethod('WriteInt32', [Type[]]@([IntPtr], [int], [int]))
$writeIntPtr = [Runtime.InteropServices.Marshal].GetMethod('WriteIntPtr', [Type[]]@([IntPtr], [int], [IntPtr]))
$allocHGlobal = [Runtime.InteropServices.Marshal].GetMethod('AllocHGlobal', [Type[]]@([int]))
$strToAnsi = [Runtime.InteropServices.Marshal].GetMethod('StringToHGlobalAnsi', [Type[]]@([string]))

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
$loopStart = $ilExt.DefineLabel()
$loopCheck = $ilExt.DefineLabel()

$ilExt.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilExt.Emit([Reflection.Emit.OpCodes]::Stloc, $locI)
$ilExt.Emit([Reflection.Emit.OpCodes]::Br, $loopCheck)

$ilExt.MarkLabel($loopStart)
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

$ilExt.MarkLabel($loopCheck)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locI)
$ilExt.Emit([Reflection.Emit.OpCodes]::Ldloc, $locExtCount)
$ilExt.Emit([Reflection.Emit.OpCodes]::Blt, $loopStart)

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

# Copy 72 bytes via 9 int64 reads/writes
for ($b = 0; $b -lt 72; $b += 8) {
    $readInt64 = [Runtime.InteropServices.Marshal].GetMethod('ReadInt64', [Type[]]@([IntPtr], [int]))
    $writeInt64 = [Runtime.InteropServices.Marshal].GetMethod('WriteInt64', [Type[]]@([IntPtr], [int], [long]))
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
$locRes = $ilCd.DeclareLocal([int])

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
$ilCd.Emit([Reflection.Emit.OpCodes]::Stloc, $locRes)

# if (res == 0) {
$skipRec = $ilCd.DefineLabel()
$lblNotDev0 = $ilCd.DefineLabel()
$lblDoneSave = $ilCd.DefineLabel()

$ilCd.Emit([Reflection.Emit.OpCodes]::Ldloc, $locRes)
$ilCd.Emit([Reflection.Emit.OpCodes]::Brtrue, $skipRec)

$locDevHandle = $ilCd.DeclareLocal([IntPtr])
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
$ilCd.Emit([Reflection.Emit.OpCodes]::Call, [Runtime.InteropServices.Marshal].GetMethod('ReadIntPtr', [Type[]]@([IntPtr])))
$ilCd.Emit([Reflection.Emit.OpCodes]::Stloc, $locDevHandle)

# LastCreatedDevice = devHandle
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldloc, $locDevHandle)
$ilCd.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.LastCreatedDevice)

# if (DeviceCreateCount == 0) { CreatedDevice0 = devHandle; }
# else if (DeviceCreateCount == 1) { CreatedDevice1 = devHandle; }
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.DeviceCreateCount)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilCd.Emit([Reflection.Emit.OpCodes]::Bne_Un, $lblNotDev0)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldloc, $locDevHandle)
$ilCd.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.CreatedDevice0)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilCd.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.CreatedPhysicalDevice0)
$ilCd.Emit([Reflection.Emit.OpCodes]::Br, $lblDoneSave)

$ilCd.MarkLabel($lblNotDev0)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.DeviceCreateCount)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilCd.Emit([Reflection.Emit.OpCodes]::Bne_Un, $lblDoneSave)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldloc, $locDevHandle)
$ilCd.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.CreatedDevice1)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilCd.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.CreatedPhysicalDevice1)

$ilCd.MarkLabel($lblDoneSave)
# DeviceCreateCount++
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.DeviceCreateCount)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilCd.Emit([Reflection.Emit.OpCodes]::Add)
$ilCd.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.DeviceCreateCount)

$ilCd.MarkLabel($skipRec)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ldloc, $locRes)
$ilCd.Emit([Reflection.Emit.OpCodes]::Ret)


# -----------------------------------------------------------------------------
# Hook Method: Hook_VkGetInstanceProcAddr
# IntPtr (IntPtr instance, IntPtr pName)
# -----------------------------------------------------------------------------
$mGipa = $type.DefineMethod('Hook_VkGetInstanceProcAddr', [Reflection.MethodAttributes]'Public,Static', [IntPtr], @([IntPtr], [IntPtr]))
$ilGipa = $mGipa.GetILGenerator()
$locNameStr = $ilGipa.DeclareLocal([string])
$lblCheckCd = $ilGipa.DefineLabel()
$lblPassThrough = $ilGipa.DefineLabel()

# if (pName == Zero) goto PassThrough
$ilGipa.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
$ilGipa.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblPassThrough)

# string name = Marshal.PtrToStringAnsi(pName)
$ilGipa.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
$ilGipa.Emit([Reflection.Emit.OpCodes]::Call, [Runtime.InteropServices.Marshal].GetMethod('PtrToStringAnsi', [Type[]]@([IntPtr])))
$ilGipa.Emit([Reflection.Emit.OpCodes]::Stloc, $locNameStr)

# Native wait audit overrides are installed before creating either device.
$locAuditOverride = $ilGipa.DeclareLocal([IntPtr])
$ilGipa.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.HookResolveWaitPtr)
$ilGipa.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblCheckCd)
$ilGipa.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
$ilGipa.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.HookResolveWaitPtr)
$ilGipa.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [IntPtr], @([IntPtr]))
$ilGipa.Emit([Reflection.Emit.OpCodes]::Stloc, $locAuditOverride)
$ilGipa.Emit([Reflection.Emit.OpCodes]::Ldloc, $locAuditOverride)
$ilGipa.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblCheckCd)
$ilGipa.Emit([Reflection.Emit.OpCodes]::Ldloc, $locAuditOverride)
$ilGipa.Emit([Reflection.Emit.OpCodes]::Ret)
$ilGipa.MarkLabel($lblCheckCd)
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
# Hook Method: Hook_InitBackend0
# IntPtr (IntPtr dev, IntPtr pParams)
# -----------------------------------------------------------------------------
$mInit0 = $type.DefineMethod('Hook_InitBackend0', [Reflection.MethodAttributes]'Public,Static', [IntPtr], @([IntPtr], [IntPtr]))
$ilInit0 = $mInit0.GetILGenerator()
$locBackend0 = $ilInit0.DeclareLocal([IntPtr])

# IntPtr backend = RealInitBackend0(dev, pParams)
$ilInit0.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilInit0.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
$ilInit0.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.RealInitBackend0)
$ilInit0.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [IntPtr], @([IntPtr], [IntPtr]))
$ilInit0.Emit([Reflection.Emit.OpCodes]::Stloc, $locBackend0)

# SourceBackend = backend
$ilInit0.Emit([Reflection.Emit.OpCodes]::Ldloc, $locBackend0)
$ilInit0.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.SourceBackend)

# OriginalCpyTensorAsync = Marshal.ReadIntPtr(backend, 0x38)
$ilInit0.Emit([Reflection.Emit.OpCodes]::Ldloc, $locBackend0)
$ilInit0.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x38)
$ilInit0.Emit([Reflection.Emit.OpCodes]::Call, [Runtime.InteropServices.Marshal].GetMethod('ReadIntPtr', [Type[]]@([IntPtr], [int])))
$ilInit0.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.OriginalCpyTensorAsync)

# return backend
$ilInit0.Emit([Reflection.Emit.OpCodes]::Ldloc, $locBackend0)
$ilInit0.Emit([Reflection.Emit.OpCodes]::Ret)


# -----------------------------------------------------------------------------
# Hook Method: Hook_InitBackend1
# IntPtr (IntPtr dev, IntPtr pParams)
# -----------------------------------------------------------------------------
$mInit1 = $type.DefineMethod('Hook_InitBackend1', [Reflection.MethodAttributes]'Public,Static', [IntPtr], @([IntPtr], [IntPtr]))
$ilInit1 = $mInit1.GetILGenerator()
$locBackend1 = $ilInit1.DeclareLocal([IntPtr])

# IntPtr backend = RealInitBackend1(dev, pParams)
$ilInit1.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilInit1.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
$ilInit1.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.RealInitBackend1)
$ilInit1.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [IntPtr], @([IntPtr], [IntPtr]))
$ilInit1.Emit([Reflection.Emit.OpCodes]::Stloc, $locBackend1)

# DestinationBackend = backend
$ilInit1.Emit([Reflection.Emit.OpCodes]::Ldloc, $locBackend1)
$ilInit1.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.DestinationBackend)

# Marshal.WriteIntPtr(backend, 0x38, HookCpyTensorAsyncPtr)
$ilInit1.Emit([Reflection.Emit.OpCodes]::Ldloc, $locBackend1)
$ilInit1.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x38)
$ilInit1.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.HookCpyTensorAsyncPtr)
$ilInit1.Emit([Reflection.Emit.OpCodes]::Call, [Runtime.InteropServices.Marshal].GetMethod('WriteIntPtr', [Type[]]@([IntPtr], [int], [IntPtr])))

# return backend
$ilInit1.Emit([Reflection.Emit.OpCodes]::Ldloc, $locBackend1)
$ilInit1.Emit([Reflection.Emit.OpCodes]::Ret)


# -----------------------------------------------------------------------------
# Hook Method: Hook_CpyTensorAsync
# bool (IntPtr srcBackend, IntPtr dstBackend, IntPtr srcTensor, IntPtr dstTensor)
# -----------------------------------------------------------------------------
$mCpy = $type.DefineMethod('Hook_CpyTensorAsync', [Reflection.MethodAttributes]'Public,Static', [bool], @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
$ilCpy = $mCpy.GetILGenerator()

$lblSameDevice = $ilCpy.DefineLabel()
$lblFailed = $ilCpy.DefineLabel()
$locNBytes = $ilCpy.DeclareLocal([uint64])
$locCursor = $ilCpy.DeclareLocal([long])
$locNextCursor = $ilCpy.DeclareLocal([long])
$locFenceVal = $ilCpy.DeclareLocal([uint64])

# if (srcBackend == dstBackend) goto SameDevice
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Beq, $lblSameDevice)

# if (srcBackend != SourceBackend) goto SameDevice
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.SourceBackend)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Bne_Un, $lblSameDevice)

# --- Cross-Device Path ---
# 1. uint64 nbytes = GgmlNBytes(srcTensor)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.GgmlNBytesFn)
$ilCpy.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [uint64], @([IntPtr]))
$ilCpy.Emit([Reflection.Emit.OpCodes]::Stloc, $locNBytes)

# 2. Align to 256: nextCursor = (cursor + ((nbytes + 255) & ~255))
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.ApertureCursor)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Stloc, $locCursor)

$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCursor)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldloc, $locNBytes)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 255)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Conv_U8)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Add)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I8, [long]-256)
$ilCpy.Emit([Reflection.Emit.OpCodes]::And)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Add)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Stloc, $locNextCursor)

# Check capacity: if (nextCursor > ApertureCapacity) wrap around to 0x1000
$lblNoWrap = $ilCpy.DefineLabel()
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldloc, $locNextCursor)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.ApertureCapacity)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ble_Un, $lblNoWrap)

# Wrap around to 0x1000
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x1000)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Conv_I8)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Stloc, $locCursor)

$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCursor)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldloc, $locNBytes)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 255)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Conv_U8)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Add)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I8, [long]-256)
$ilCpy.Emit([Reflection.Emit.OpCodes]::And)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Add)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Stloc, $locNextCursor)

$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldloc, $locNextCursor)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.ApertureCapacity)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Bgt_Un, $lblFailed)

$ilCpy.MarkLabel($lblNoWrap)

# 3. Repoint SourceBridge->view_offs = cursor (offset 240, size_t)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.SourceBridge)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 240)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Add)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCursor)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Conv_I8)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Stind_I8)

# Ensure SourceBridge->data = 0x1000 (offset 248, sentinel pointer vk_ptr_base)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.SourceBridge)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 248)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Add)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x1000)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Stind_I)

# 4. Queue asynchronous copy on Die 0: OriginalCpy(srcBackend, srcBackend, srcTensor, SourceBridge)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.SourceBridge)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.OriginalCpyTensorAsync)
$ilCpy.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [bool], @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
$ilCpy.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblFailed)

# 5. Hardware Baton: Increment CurrentFenceValue
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.CurrentFenceValue)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Conv_U8)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Add)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Dup)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.CurrentFenceValue)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Stloc, $locFenceVal)

# Update SigFenceValPtr and WaitFenceValPtr
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.SigFenceValPtr)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldloc, $locFenceVal)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Call, [Runtime.InteropServices.Marshal].GetMethod('WriteInt64', [Type[]]@([IntPtr], [long])))

$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.WaitFenceValPtr)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldloc, $locFenceVal)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Call, [Runtime.InteropServices.Marshal].GetMethod('WriteInt64', [Type[]]@([IntPtr], [long])))

# 6. Submit Die 0 SDMA Signal: vkQueueSubmit(Dev0Queue, 1, SigSubmitInfo, 0)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.Dev0Queue)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.SigSubmitInfo)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Conv_U8)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.VkQueueSubmit)
$ilCpy.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [int], @([IntPtr], [uint32], [IntPtr], [uint64]))
$ilCpy.Emit([Reflection.Emit.OpCodes]::Pop) # Discard VkResult

# 7. Submit Die 1 Compute Wait: vkQueueSubmit(Dev1Queue, 1, WaitSubmitInfo, 0)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.Dev1Queue)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.WaitSubmitInfo)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Conv_U8)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.VkQueueSubmit)
$ilCpy.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [int], @([IntPtr], [uint32], [IntPtr], [uint64]))
$ilCpy.Emit([Reflection.Emit.OpCodes]::Pop) # Discard VkResult

# 8. Repoint Destination Tensor metadata:
# dstTensor + 8 (buffer) = DestinationBuffer
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 8)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Add)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.DestinationBuffer)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Stind_I)

# dstTensor + 232 (view_src) = 0
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 232)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Add)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Stind_I)

# dstTensor + 240 (view_offs) = cursor
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 240)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Add)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldloc, $locCursor)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Conv_I8)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Stind_I8)

# dstTensor + 248 (data) = 0x1000 (sentinel pointer vk_ptr_base)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 248)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Add)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x1000)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Stind_I)

# dstTensor + 320 (extra) = 0
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 320)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Add)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Conv_I)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Stind_I)

# Advance cursor and record handled handoff
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldloc, $locNextCursor)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.ApertureCursor)

$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.HandledHandoffs)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Conv_I8)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Add)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.HandledHandoffs)

# Return true (1) -> ggml skips ggml_backend_synchronize()!
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ret)

# Same-Device Path: call OriginalCpy(srcBackend, dstBackend, srcTensor, dstTensor)
$ilCpy.MarkLabel($lblSameDevice)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldarg_2)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldarg_3)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.OriginalCpyTensorAsync)
$ilCpy.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::Cdecl, [bool], @([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ret)

# Failed Path: increment FallbackHandoffs and return false (0)
$ilCpy.MarkLabel($lblFailed)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldsfld, $fields.FallbackHandoffs)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Conv_I8)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Add)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Stsfld, $fields.FallbackHandoffs)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
$ilCpy.Emit([Reflection.Emit.OpCodes]::Ret)

# -----------------------------------------------------------------------------
# Save Assembly to Disk
# -----------------------------------------------------------------------------
$type.CreateType() | Out-Null

$dir = Split-Path $OutputPath
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$stream = [IO.FileStream]::new($OutputPath, [IO.FileMode]::Create, [IO.FileAccess]::Write)
try {
    $builder.Save($stream)
} finally {
    $stream.Dispose()
}

Write-Host "Emitted assembly successfully saved to: $OutputPath ($((Get-Item $OutputPath).Length) bytes)" -ForegroundColor Green
