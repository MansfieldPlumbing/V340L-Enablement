param([string]$OutputPath='C:\dev\V340L-Emancipated\scratch\codex-baton-integration-20261001\Codex.NativeWaitAudit.dll')
$ErrorActionPreference='Stop'
$op=[Reflection.Emit.OpCodes]
$builder=[Reflection.Emit.PersistedAssemblyBuilder]::new([Reflection.AssemblyName]::new('Codex.NativeWaitAudit'),[object].Assembly)
$module=$builder.DefineDynamicModule('Codex.NativeWaitAudit')
$type=$module.DefineType('Codex.NativeWaitAudit','Public,Abstract,Sealed')
$fields=@{}
foreach($name in @('PhasePointer','RealGetDeviceProcAddr','HookGetDeviceProcAddrPtr','HookWaitForFencesPtr','HookWaitSemaphoresPtr','HookQueueWaitIdlePtr','HookDeviceWaitIdlePtr','RealWaitForFences','RealWaitSemaphores','RealQueueWaitIdle','RealDeviceWaitIdle','RealQueueSubmit','HookQueueSubmitPtr','RealCmdDispatch','HookCmdDispatchPtr','RealCmdDispatchIndirect','HookCmdDispatchIndirectPtr')){$fields[$name]=$type.DefineField($name,[IntPtr],'Public,Static')}
foreach($name in @('BoundaryWaitRequests','ResolveHits','WaitForFencesCalls','WaitSemaphoresCalls','QueueWaitIdleCalls','DeviceWaitIdleCalls','WaitForFencesProfileCalls','WaitSemaphoresProfileCalls','QueueWaitIdleProfileCalls','DeviceWaitIdleProfileCalls','SourceDispatchCalls','ConsumerDispatchCalls','SourceIndirectDispatchCalls','ConsumerIndirectDispatchCalls','SourceSubmitCalls','ConsumerSubmitCalls')){$fields[$name]=$type.DefineField($name,[int],'Public,Static')}
foreach($name in @('WaitForFencesTicks','WaitSemaphoresTicks','QueueWaitIdleTicks','DeviceWaitIdleTicks','SourceWorkgroups','ConsumerWorkgroups','SourceSubmitTicks','ConsumerSubmitTicks')){$fields[$name]=$type.DefineField($name,[long],'Public,Static')}
foreach($name in @('RealGetFenceStatus','HookGetFenceStatusPtr')){$fields[$name]=$type.DefineField($name,[IntPtr],'Public,Static')}
foreach($name in @('WaitForFences','WaitSemaphores','QueueWaitIdle','DeviceWaitIdle','GetFenceStatus')){
 foreach($phaseIndex in 0..3){$fields[$name+'Phase'+$phaseIndex+'Calls']=$type.DefineField($name+'Phase'+$phaseIndex+'Calls',[int],'Public,Static');$fields[$name+'Phase'+$phaseIndex+'Ticks']=$type.DefineField($name+'Phase'+$phaseIndex+'Ticks',[long],'Public,Static')}
}
foreach($name in @('GetFenceStatusCalls','GetFenceStatusProfileCalls')){$fields[$name]=$type.DefineField($name,[int],'Public,Static')}
$fields.GetFenceStatusTicks=$type.DefineField('GetFenceStatusTicks',[long],'Public,Static')
function I($il,[int]$v){$il.Emit($op::Ldc_I4,$v)}
function Arg($il,[int]$v){$il.Emit($op::Ldarg,[int16]$v)}
function LoadF($il,[string]$name){$il.Emit($op::Ldsfld,$fields[$name])}
function IncF($il,[string]$name){LoadF $il $name; I $il 1; $il.Emit($op::Add); $il.Emit($op::Stsfld,$fields[$name])}
function NativeCall($il,[Type]$ret,[Type[]]$params){$il.EmitCalli($op::Calli,[Runtime.InteropServices.CallingConvention]::Cdecl,$ret,$params)}
function DefineAuditDelegate([string]$name,[Type]$ret,[Type[]]$params){
 $d=$module.DefineType('Codex.'+$name,'Public,Sealed',[MulticastDelegate])
 $c=$d.DefineConstructor('Public,HideBySig,RTSpecialName',[Reflection.CallingConventions]::Standard,@([object],[IntPtr])); $c.SetImplementationFlags('Runtime,Managed')
 $invoke=$d.DefineMethod('Invoke','Public,HideBySig,NewSlot,Virtual',$ret,$params); $invoke.SetImplementationFlags('Runtime,Managed')
 $attr=[Runtime.InteropServices.UnmanagedFunctionPointerAttribute].GetConstructor(@([Runtime.InteropServices.CallingConvention]))
 $d.SetCustomAttribute([Reflection.Emit.CustomAttributeBuilder]::new($attr,@([Runtime.InteropServices.CallingConvention]::Cdecl)))
 $d.CreateType() | Out-Null
}
DefineAuditDelegate ResolveCallback ([IntPtr]) @([IntPtr])
DefineAuditDelegate DeviceProcCallback ([IntPtr]) @([IntPtr],[IntPtr])
DefineAuditDelegate FenceWaitCallback ([int]) @([IntPtr],[uint32],[IntPtr],[uint32],[uint64])
DefineAuditDelegate SemaphoreWaitCallback ([int]) @([IntPtr],[IntPtr],[uint64])
DefineAuditDelegate IdleCallback ([int]) @([IntPtr])
DefineAuditDelegate SubmitCallback ([int]) @([IntPtr],[uint32],[IntPtr],[uint64])
DefineAuditDelegate DispatchCallback ([void]) @([IntPtr],[uint32],[uint32],[uint32])
DefineAuditDelegate DispatchIndirectCallback ([void]) @([IntPtr],[uint64],[uint64])
DefineAuditDelegate FenceStatusCallback ([int]) @([IntPtr],[uint64])
$check=$type.DefineMethod('CheckBoundary','Public,Static',[void],@([string]))
$il=$check.GetILGenerator(); $ok=$il.DefineLabel(); LoadF $il PhasePointer; $il.Emit($op::Brfalse,$ok); LoadF $il PhasePointer; $il.Emit($op::Call,[Runtime.InteropServices.Marshal].GetMethod('ReadInt32',[Type[]]@([IntPtr]))); I $il 1; $il.Emit($op::Bne_Un,$ok); IncF $il BoundaryWaitRequests; $il.Emit($op::Ldstr,'NATIVE_BOUNDARY_WAIT:'); $il.Emit($op::Call,[Console].GetMethod('WriteLine',[Type[]]@([string]))); Arg $il 0; $il.Emit($op::Call,[Console].GetMethod('WriteLine',[Type[]]@([string]))); I $il 92; $il.Emit($op::Call,[Environment].GetMethod('Exit',[Type[]]@([int]))); $il.MarkLabel($ok); $il.Emit($op::Ret)
foreach($spec in @(
 @{Name='WaitForFences';Delegate='FenceWaitCallback';Params=[Type[]]@([IntPtr],[uint32],[IntPtr],[uint32],[uint64])},
 @{Name='WaitSemaphores';Delegate='SemaphoreWaitCallback';Params=[Type[]]@([IntPtr],[IntPtr],[uint64])},
 @{Name='QueueWaitIdle';Delegate='IdleCallback';Params=[Type[]]@([IntPtr])},
 @{Name='DeviceWaitIdle';Delegate='IdleCallback';Params=[Type[]]@([IntPtr])},
 @{Name='GetFenceStatus';Delegate='FenceStatusCallback';Params=[Type[]]@([IntPtr],[uint64])}
)){
 $method=$type.DefineMethod('Hook'+$spec.Name,'Public,Static',[int],$spec.Params)
 $il=$method.GetILGenerator(); $waitStart=$il.DeclareLocal([long]); $waitProfile=$il.DeclareLocal([int]); $waitPhase=$il.DeclareLocal([int]); IncF $il ($spec.Name+'Calls'); $il.Emit($op::Ldstr,'vk'+$spec.Name); $il.Emit($op::Call,$check)
 LoadF $il PhasePointer; $il.Emit($op::Call,[Runtime.InteropServices.Marshal].GetMethod('ReadInt32',[Type[]]@([IntPtr]))); $il.Emit($op::Stloc,$waitPhase)
 $il.Emit($op::Call,[Diagnostics.Stopwatch].GetMethod('GetTimestamp',[Type[]]@())); $il.Emit($op::Stloc,$waitStart); LoadF $il PhasePointer; I $il 4; $il.Emit($op::Call,[Runtime.InteropServices.Marshal].GetMethod('ReadInt32',[Type[]]@([IntPtr],[int]))); $il.Emit($op::Stloc,$waitProfile)
 for($i=0;$i -lt $spec.Params.Length;$i++){Arg $il $i}
 LoadF $il ('Real'+$spec.Name); NativeCall $il ([int]) $spec.Params;
 $profileDone=$il.DefineLabel(); $il.Emit($op::Ldloc,$waitProfile); $il.Emit($op::Brfalse,$profileDone); IncF $il ($spec.Name+'ProfileCalls'); LoadF $il ($spec.Name+'Ticks'); $il.Emit($op::Call,[Diagnostics.Stopwatch].GetMethod('GetTimestamp',[Type[]]@())); $il.Emit($op::Ldloc,$waitStart); $il.Emit($op::Sub); $il.Emit($op::Add); $il.Emit($op::Stsfld,$fields[$spec.Name+'Ticks'])
 foreach($phaseIndex in 0..3){
  $nextPhase=$il.DefineLabel(); $il.Emit($op::Ldloc,$waitPhase); I $il $phaseIndex; $il.Emit($op::Bne_Un,$nextPhase)
  IncF $il ($spec.Name+'Phase'+$phaseIndex+'Calls'); LoadF $il ($spec.Name+'Phase'+$phaseIndex+'Ticks'); $il.Emit($op::Call,[Diagnostics.Stopwatch].GetMethod('GetTimestamp',[Type[]]@())); $il.Emit($op::Ldloc,$waitStart); $il.Emit($op::Sub); $il.Emit($op::Add); $il.Emit($op::Stsfld,$fields[$spec.Name+'Phase'+$phaseIndex+'Ticks']); $il.MarkLabel($nextPhase)
 }
 $il.MarkLabel($profileDone); $il.Emit($op::Ret)
}
$phase=$type.DefineMethod('ReadPhase','Public,Static',[int],[Type[]]@())
$il=$phase.GetILGenerator(); LoadF $il PhasePointer; I $il 0; $il.Emit($op::Call,[Runtime.InteropServices.Marshal].GetMethod('ReadInt32',[Type[]]@([IntPtr],[int]))); $il.Emit($op::Ret)
foreach($dispatchSpec in @(@{Name='CmdDispatch';Params=[Type[]]@([IntPtr],[uint32],[uint32],[uint32]);Indirect=$false},@{Name='CmdDispatchIndirect';Params=[Type[]]@([IntPtr],[uint64],[uint64]);Indirect=$true})){
 $method=$type.DefineMethod('Hook'+$dispatchSpec.Name,'Public,Static',[void],$dispatchSpec.Params)
 $il=$method.GetILGenerator(); $consumer=$il.DefineLabel(); $native=$il.DefineLabel(); $il.Emit($op::Call,$phase); I $il 2; $il.Emit($op::Bne_Un,$consumer)
 $dispatchSuffix=if($dispatchSpec.Indirect){'IndirectDispatchCalls'}else{'DispatchCalls'}
 IncF $il ('Source'+$dispatchSuffix)
 if(-not $dispatchSpec.Indirect){LoadF $il SourceWorkgroups; Arg $il 1; $il.Emit($op::Conv_I8); Arg $il 2; $il.Emit($op::Conv_I8); $il.Emit($op::Mul); Arg $il 3; $il.Emit($op::Conv_I8); $il.Emit($op::Mul); $il.Emit($op::Add); $il.Emit($op::Stsfld,$fields.SourceWorkgroups)}
 $il.Emit($op::Br,$native); $il.MarkLabel($consumer); $il.Emit($op::Call,$phase); I $il 3; $il.Emit($op::Bne_Un,$native)
 IncF $il ('Consumer'+$dispatchSuffix)
 if(-not $dispatchSpec.Indirect){LoadF $il ConsumerWorkgroups; Arg $il 1; $il.Emit($op::Conv_I8); Arg $il 2; $il.Emit($op::Conv_I8); $il.Emit($op::Mul); Arg $il 3; $il.Emit($op::Conv_I8); $il.Emit($op::Mul); $il.Emit($op::Add); $il.Emit($op::Stsfld,$fields.ConsumerWorkgroups)}
 $il.MarkLabel($native); for($i=0;$i -lt $dispatchSpec.Params.Length;$i++){Arg $il $i}; LoadF $il ('Real'+$dispatchSpec.Name); NativeCall $il ([void]) $dispatchSpec.Params; $il.Emit($op::Ret)
}
$submit=$type.DefineMethod('HookQueueSubmit','Public,Static',[int],@([IntPtr],[uint32],[IntPtr],[uint64]))
$il=$submit.GetILGenerator(); $start=$il.DeclareLocal([long]); $recordPhase=$il.DeclareLocal([int]); $consumer=$il.DefineLabel(); $done=$il.DefineLabel(); $il.Emit($op::Call,$phase); $il.Emit($op::Stloc,$recordPhase); $il.Emit($op::Call,[Diagnostics.Stopwatch].GetMethod('GetTimestamp',[Type[]]@())); $il.Emit($op::Stloc,$start); foreach($i in 0..3){Arg $il $i}; LoadF $il RealQueueSubmit; NativeCall $il ([int]) @([IntPtr],[uint32],[IntPtr],[uint64]); $il.Emit($op::Ldloc,$recordPhase); I $il 2; $il.Emit($op::Bne_Un,$consumer); IncF $il SourceSubmitCalls; LoadF $il SourceSubmitTicks; $il.Emit($op::Call,[Diagnostics.Stopwatch].GetMethod('GetTimestamp',[Type[]]@())); $il.Emit($op::Ldloc,$start); $il.Emit($op::Sub); $il.Emit($op::Add); $il.Emit($op::Stsfld,$fields.SourceSubmitTicks); $il.Emit($op::Br,$done); $il.MarkLabel($consumer); $il.Emit($op::Ldloc,$recordPhase); I $il 3; $il.Emit($op::Bne_Un,$done); IncF $il ConsumerSubmitCalls; LoadF $il ConsumerSubmitTicks; $il.Emit($op::Call,[Diagnostics.Stopwatch].GetMethod('GetTimestamp',[Type[]]@())); $il.Emit($op::Ldloc,$start); $il.Emit($op::Sub); $il.Emit($op::Add); $il.Emit($op::Stsfld,$fields.ConsumerSubmitTicks); $il.MarkLabel($done); $il.Emit($op::Ret)
$resolve=$type.DefineMethod('Resolve','Public,Static',[IntPtr],@([IntPtr]))
$il=$resolve.GetILGenerator(); $name=$il.DeclareLocal([string]); $done=$il.DefineLabel(); Arg $il 0; $il.Emit($op::Brfalse,$done); Arg $il 0; $il.Emit($op::Call,[Runtime.InteropServices.Marshal].GetMethod('PtrToStringAnsi',[Type[]]@([IntPtr]))); $il.Emit($op::Stloc,$name)
foreach($entry in @(@{Name='vkGetDeviceProcAddr';Field='HookGetDeviceProcAddrPtr'},@{Name='vkGetFenceStatus';Field='HookGetFenceStatusPtr'},@{Name='vkWaitForFences';Field='HookWaitForFencesPtr'},@{Name='vkWaitSemaphores';Field='HookWaitSemaphoresPtr'},@{Name='vkWaitSemaphoresKHR';Field='HookWaitSemaphoresPtr'},@{Name='vkQueueWaitIdle';Field='HookQueueWaitIdlePtr'},@{Name='vkDeviceWaitIdle';Field='HookDeviceWaitIdlePtr'},@{Name='vkQueueSubmit';Field='HookQueueSubmitPtr'},@{Name='vkCmdDispatch';Field='HookCmdDispatchPtr'},@{Name='vkCmdDispatchIndirect';Field='HookCmdDispatchIndirectPtr'})){
 $next=$il.DefineLabel(); $il.Emit($op::Ldloc,$name); $il.Emit($op::Ldstr,$entry.Name); $il.Emit($op::Call,[string].GetMethod('Equals',[Type[]]@([string],[string]))); $il.Emit($op::Brfalse,$next); IncF $il ResolveHits; LoadF $il $entry.Field; $il.Emit($op::Ret); $il.MarkLabel($next)
}
$il.MarkLabel($done); I $il 0; $il.Emit($op::Conv_I); $il.Emit($op::Ret)
$gdpa=$type.DefineMethod('HookGetDeviceProcAddr','Public,Static',[IntPtr],@([IntPtr],[IntPtr]))
$il=$gdpa.GetILGenerator(); $p=$il.DeclareLocal([IntPtr]); $native=$il.DefineLabel(); Arg $il 1; $il.Emit($op::Call,$resolve); $il.Emit($op::Stloc,$p); $il.Emit($op::Ldloc,$p); $il.Emit($op::Brfalse,$native); $il.Emit($op::Ldloc,$p); $il.Emit($op::Ret); $il.MarkLabel($native); Arg $il 0; Arg $il 1; LoadF $il RealGetDeviceProcAddr; NativeCall $il ([IntPtr]) @([IntPtr],[IntPtr]); $il.Emit($op::Ret)
$type.CreateType() | Out-Null
$builder.Save($OutputPath)
Write-Output "Emitted $OutputPath"
