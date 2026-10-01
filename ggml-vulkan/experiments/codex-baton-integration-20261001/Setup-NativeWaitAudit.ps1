& 'C:\dev\V340L-Emancipated\scratch\codex-baton-integration-20261001\New-NativeWaitAuditAssembly.ps1' | Out-Host
$nativeAuditAsm=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes('C:\dev\V340L-Emancipated\scratch\codex-baton-integration-20261001\Codex.NativeWaitAudit.dll'))
$nativeAuditType=$nativeAuditAsm.GetType('Codex.NativeWaitAudit',$true)
$nativeBoundaryPhase=Block 8
$nativeAuditType.GetField('PhasePointer').SetValue($null,$nativeBoundaryPhase)
$nativeAuditLibrary=$interop.LoadLibrary('C:\Windows\System32\vulkan-1.dll')
foreach($name in @('GetDeviceProcAddr','WaitForFences','WaitSemaphores','QueueWaitIdle','DeviceWaitIdle','QueueSubmit','CmdDispatch','CmdDispatchIndirect','GetFenceStatus')){
 $nativeAuditType.GetField('Real'+$name).SetValue($null,$interop.GetExport($nativeAuditLibrary,'vk'+$name))
}
$nativeAuditRoots=[Collections.Generic.List[object]]::new()
foreach($spec in @(
 @{Method='Resolve';Delegate='ResolveCallback';Field=$null},
 @{Method='HookGetDeviceProcAddr';Delegate='DeviceProcCallback';Field='HookGetDeviceProcAddrPtr'},
 @{Method='HookWaitForFences';Delegate='FenceWaitCallback';Field='HookWaitForFencesPtr'},
 @{Method='HookWaitSemaphores';Delegate='SemaphoreWaitCallback';Field='HookWaitSemaphoresPtr'},
 @{Method='HookQueueWaitIdle';Delegate='IdleCallback';Field='HookQueueWaitIdlePtr'},
 @{Method='HookDeviceWaitIdle';Delegate='IdleCallback';Field='HookDeviceWaitIdlePtr'},
 @{Method='HookQueueSubmit';Delegate='SubmitCallback';Field='HookQueueSubmitPtr'},
 @{Method='HookCmdDispatch';Delegate='DispatchCallback';Field='HookCmdDispatchPtr'},
 @{Method='HookCmdDispatchIndirect';Delegate='DispatchIndirectCallback';Field='HookCmdDispatchIndirectPtr'},
 @{Method='HookGetFenceStatus';Delegate='FenceStatusCallback';Field='HookGetFenceStatusPtr'}
)){
 $auditMethod=$nativeAuditType.GetMethod($spec.Method)
 [Runtime.CompilerServices.RuntimeHelpers]::PrepareMethod($auditMethod.MethodHandle)
 $auditCallback=[Delegate]::CreateDelegate($nativeAuditAsm.GetType('Codex.'+$spec.Delegate),$auditMethod)
 $nativeAuditRoots.Add($auditCallback)
 $auditPointer=[Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($auditCallback)
 if($spec.Field){$nativeAuditType.GetField($spec.Field).SetValue($null,$auditPointer)}else{$shimType.GetField('HookResolveWaitPtr').SetValue($null,$auditPointer)}
}
Write-Host 'NATIVE_AUDIT: procedure-resolution guards installed before Vulkan device creation.'
