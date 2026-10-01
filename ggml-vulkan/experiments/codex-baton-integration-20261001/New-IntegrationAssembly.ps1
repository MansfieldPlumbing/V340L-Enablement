param([string]$OutputPath = 'C:\dev\V340L-Emancipated\scratch\codex-baton-integration-20261001\Codex.BatonRuntime.dll', [bool]$Trace = $false)
$ErrorActionPreference='Stop'
$builder=[Reflection.Emit.PersistedAssemblyBuilder]::new([Reflection.AssemblyName]::new('Codex.BatonRuntime'),[object].Assembly)
$module=$builder.DefineDynamicModule('Codex.BatonRuntime')
$type=$module.DefineType('Codex.BatonRuntime','Public,Abstract,Sealed')
$fields=@{}
foreach($name in @('SourceDevice','DestinationDevice','DestinationBuffer','RealInit','RealCopy','RealGraph','RealSync','RealEventSync','HookCopyPtr','HookGraphPtr','HookSyncPtr','HookEventSyncPtr','Configurations','SourceQueue','TransferQueue','DestinationQueue','QueueSubmit','BeginCommand','EndCommand','CmdBarrier','NBytes','RealEventRecord','HookEventRecordPtr','EventRecords','NativeBoundaryPhase','SourceGpuSubmits','ConsumerGpuSubmits')){$fields[$name]=$type.DefineField($name,[IntPtr],'Public,Static')}
foreach($name in @('PublicationCount','PendingCount','LastGraphStage','MaxPublications','HandledCopies','BlockedBoundaryWaits','OtherCopies','SourceGraphs','DestinationGraphs','AllowedSyncs','EventRecordCount','MaxEventRecords','DeferredCompletedEventCleanups','SingleDieMode')){$fields[$name]=$type.DefineField($name,[int],'Public,Static')}
foreach($name in @('ApertureCursor','ApertureCapacity','SourceGraphTicks','ConsumerGraphTicks','PublicationTicks')){$fields[$name]=$type.DefineField($name,[long],'Public,Static')}
$op=[Reflection.Emit.OpCodes]
$fields['CoarseDecode']=$type.DefineField('CoarseDecode',[int],'Public,Static')
$fields['CoarseDecodeGraphs']=$type.DefineField('CoarseDecodeGraphs',[int],'Public,Static')
$marshal=[Runtime.InteropServices.Marshal]
$readPtr=$marshal.GetMethod('ReadIntPtr',[Type[]]@([IntPtr],[int]))
$read64=$marshal.GetMethod('ReadInt64',[Type[]]@([IntPtr],[int]))
$writePtr=$marshal.GetMethod('WriteIntPtr',[Type[]]@([IntPtr],[int],[IntPtr]))
$write64=$marshal.GetMethod('WriteInt64',[Type[]]@([IntPtr],[int],[long]))
$write32=$marshal.GetMethod('WriteInt32',[Type[]]@([IntPtr],[int],[int]))
function I($il,[int]$value){$il.Emit($op::Ldc_I4,$value)}
function L($il,[string]$name){$il.Emit($op::Ldsfld,$fields[$name])}
function S($il,[string]$name){$il.Emit($op::Stsfld,$fields[$name])}
function Inc($il,[string]$name){L $il $name; I $il 1; $il.Emit($op::Add); S $il $name}
function Arg($il,[int]$index){$il.Emit($op::Ldarg,[int16]$index)}
function ReadP($il,[int]$offset){I $il $offset; $il.Emit($op::Call,$readPtr)}
function Read64($il,[int]$offset){I $il $offset; $il.Emit($op::Call,$read64)}
function CallNative($il,[Type]$ret,[Type[]]$parameters){$il.EmitCalli($op::Calli,[Runtime.InteropServices.CallingConvention]::Cdecl,$ret,$parameters)}
function DelegateType([string]$name,[Type]$ret,[Type[]]$parameters){
 $dt=$module.DefineType('Codex.'+$name,'Public,Sealed',[MulticastDelegate])
 $ctor=$dt.DefineConstructor('Public,HideBySig,RTSpecialName',[Reflection.CallingConventions]::Standard,@([object],[IntPtr])); $ctor.SetImplementationFlags('Runtime,Managed')
 $invoke=$dt.DefineMethod('Invoke','Public,HideBySig,NewSlot,Virtual',$ret,$parameters); $invoke.SetImplementationFlags('Runtime,Managed')
 $attr=[Runtime.InteropServices.UnmanagedFunctionPointerAttribute].GetConstructor(@([Runtime.InteropServices.CallingConvention]))
 $dt.SetCustomAttribute([Reflection.Emit.CustomAttributeBuilder]::new($attr,@([Runtime.InteropServices.CallingConvention]::Cdecl)))
 $dt.CreateType() | Out-Null
}
DelegateType InitCallback ([IntPtr]) @([IntPtr],[IntPtr])
DelegateType CopyCallback ([byte]) @([IntPtr],[IntPtr],[IntPtr],[IntPtr])
DelegateType GraphCallback ([int]) @([IntPtr],[IntPtr])
DelegateType SyncCallback ([void]) @([IntPtr])
DelegateType EventSyncCallback ([void]) @([IntPtr],[IntPtr])
$fail=$type.DefineMethod('Fail','Public,Static',[void],@([string]))
$il=$fail.GetILGenerator(); Arg $il 0; $il.Emit($op::Call,[Console].GetMethod('WriteLine',[Type[]]@([string]))); I $il 91; $il.Emit($op::Call,[Environment].GetMethod('Exit',[Type[]]@([int]))); $il.Emit($op::Ret)
function Fail($il,[string]$reason){$il.Emit($op::Ldstr,'BATON_FAILURE: '+$reason); $il.Emit($op::Call,$fail)}
$timestamp=[Diagnostics.Stopwatch].GetMethod('GetTimestamp',[Type[]]@())
$checked=$type.DefineMethod('Check','Public,Static',[void],@([int]))
$il=$checked.GetILGenerator(); $ok=$il.DefineLabel(); Arg $il 0; $il.Emit($op::Brfalse,$ok); Fail $il 'native operation failed'; $il.MarkLabel($ok); $il.Emit($op::Ret)
function Check($il){$il.Emit($op::Call,$checked)}
$config=$type.DefineMethod('CurrentConfig','Public,Static',[IntPtr],[Type[]]@())
$il=$config.GetILGenerator(); $ok=$il.DefineLabel(); L $il PublicationCount; L $il MaxPublications; $il.Emit($op::Blt,$ok); Fail $il 'publication capacity exhausted'; $il.MarkLabel($ok); L $il Configurations; L $il PublicationCount; I $il 72; $il.Emit($op::Mul); $il.Emit($op::Conv_I); $il.Emit($op::Add); $il.Emit($op::Ret)

$init=$type.DefineMethod('HookInit','Public,Static',[IntPtr],@([IntPtr],[IntPtr]))
$il=$init.GetILGenerator(); $backend=$il.DeclareLocal([IntPtr]); Arg $il 0; Arg $il 1; L $il RealInit; CallNative $il ([IntPtr]) @([IntPtr],[IntPtr]); $il.Emit($op::Stloc,$backend)
foreach($pair in @(@{Offset=0x38;Field='HookCopyPtr'},@{Offset=0x68;Field='HookGraphPtr'},@{Offset=0x40;Field='HookSyncPtr'},@{Offset=0x70;Field='HookEventRecordPtr'})){$il.Emit($op::Ldloc,$backend); I $il $pair.Offset; L $il $pair.Field; $il.Emit($op::Call,$writePtr)}
$il.Emit($op::Ldloc,$backend); $il.Emit($op::Ret)

$copy=$type.DefineMethod('HookCopy','Public,Static',[byte],@([IntPtr],[IntPtr],[IntPtr],[IntPtr]))
$il=$copy.GetILGenerator(); $other=$il.DefineLabel(); $capacity=$il.DefineLabel(); $regionOK=$il.DefineLabel(); $boundsOK=$il.DefineLabel(); $sizeOK=$il.DefineLabel(); $nonzero=$il.DefineLabel()
$n=$il.DeclareLocal([long]); $cursor=$il.DeclareLocal([long]); $next=$il.DeclareLocal([long]); $region=$il.DeclareLocal([IntPtr]); $nativeBuffer=$il.DeclareLocal([IntPtr]); $offset=$il.DeclareLocal([long]); $view=$il.DeclareLocal([IntPtr])
Arg $il 0; ReadP $il 0x88; L $il SourceDevice; $il.Emit($op::Bne_Un,$other)
Arg $il 1; ReadP $il 0x88; L $il DestinationDevice; $il.Emit($op::Bne_Un,$other)
Arg $il 2; L $il NBytes; CallNative $il ([long]) @([IntPtr]); $il.Emit($op::Stloc,$n); $il.Emit($op::Ldloc,$n); $il.Emit($op::Brtrue,$nonzero); I $il 1; $il.Emit($op::Ret); $il.MarkLabel($nonzero)
L $il PendingCount; I $il 64; $il.Emit($op::Blt,$regionOK); Fail $il 'region capacity exceeded'; $il.MarkLabel($regionOK)
L $il ApertureCursor; $il.Emit($op::Stloc,$cursor); $il.Emit($op::Ldloc,$cursor); $il.Emit($op::Ldloc,$n); I $il 255; $il.Emit($op::Conv_I8); $il.Emit($op::Add); $il.Emit($op::Ldc_I8,[long]-256); $il.Emit($op::And); $il.Emit($op::Add); $il.Emit($op::Stloc,$next)
$il.Emit($op::Ldloc,$next); L $il ApertureCapacity; $il.Emit($op::Ble,$capacity); Fail $il 'arena exhausted; no unsafe wrap permitted'; $il.MarkLabel($capacity)
Arg $il 2; ReadP $il 8; ReadP $il 0x60; ReadP $il 0x10; $il.Emit($op::Stloc,$nativeBuffer)
Arg $il 2; ReadP $il 0xE8; $il.Emit($op::Stloc,$view); $viewPresent=$il.DefineLabel(); $addressDone=$il.DefineLabel(); $il.Emit($op::Ldloc,$view); $il.Emit($op::Brtrue,$viewPresent); Arg $il 2; ReadP $il 0xF8; $il.Emit($op::Br,$addressDone); $il.MarkLabel($viewPresent); $il.Emit($op::Ldloc,$view); ReadP $il 0xF8; $il.MarkLabel($addressDone); $il.Emit($op::Conv_I8); $il.Emit($op::Ldc_I8,[long]4096); $il.Emit($op::Sub); Arg $il 2; Read64 $il 0xF0; $il.Emit($op::Add); $il.Emit($op::Stloc,$offset)
$il.Emit($op::Ldloc,$offset); $il.Emit($op::Ldc_I8,[long]0); $il.Emit($op::Bge,$boundsOK); Fail $il 'negative source offset'; $il.MarkLabel($boundsOK)
$il.Emit($op::Ldloc,$offset); $il.Emit($op::Ldloc,$n); $il.Emit($op::Add); $il.Emit($op::Ldloc,$nativeBuffer); Read64 $il 0x20; $il.Emit($op::Ble_Un,$sizeOK); Fail $il 'source copy exceeds native buffer'; $il.MarkLabel($sizeOK)
$il.Emit($op::Call,$config); ReadP $il 32; L $il PendingCount; I $il 32; $il.Emit($op::Mul); $il.Emit($op::Conv_I); $il.Emit($op::Add); $il.Emit($op::Stloc,$region)
foreach($entry in @(0,8,16,24)){$il.Emit($op::Ldloc,$region); I $il $entry; switch($entry){0{$il.Emit($op::Ldloc,$nativeBuffer);Read64 $il 0}8{$il.Emit($op::Ldloc,$offset)}16{$il.Emit($op::Ldloc,$cursor)}24{$il.Emit($op::Ldloc,$n)}}; $il.Emit($op::Call,$write64)}
Arg $il 3; I $il 8; L $il DestinationBuffer; $il.Emit($op::Call,$writePtr)
Arg $il 3; I $il 0xE8; I $il 0; $il.Emit($op::Conv_I); $il.Emit($op::Call,$writePtr)
Arg $il 3; I $il 0xF0; $il.Emit($op::Ldc_I8,[long]0); $il.Emit($op::Call,$write64)
Arg $il 3; I $il 0xF8; $il.Emit($op::Ldloc,$cursor); $il.Emit($op::Ldc_I8,[long]4096); $il.Emit($op::Add); $il.Emit($op::Conv_I); $il.Emit($op::Call,$writePtr)
Arg $il 3; I $il 0x140; I $il 0; $il.Emit($op::Conv_I); $il.Emit($op::Call,$writePtr)
$il.Emit($op::Ldloc,$next); S $il ApertureCursor; Inc $il PendingCount; Inc $il HandledCopies; I $il 1; $il.Emit($op::Ret)
$il.MarkLabel($other); Inc $il OtherCopies;
if($Trace){$il.Emit($op::Ldstr,'BATON_OTHER_COPY: source tensor'); $il.Emit($op::Call,[Console].GetMethod('WriteLine',[Type[]]@([string])));
Arg $il 2; I $il 256; $il.Emit($op::Conv_I); $il.Emit($op::Add); $il.Emit($op::Call,$marshal.GetMethod('PtrToStringUTF8',[Type[]]@([IntPtr]))); $il.Emit($op::Call,[Console].GetMethod('WriteLine',[Type[]]@([string])));
foreach($index in 0..1){Arg $il $index; ReadP $il 0x88; $il.Emit($op::Conv_I8); $il.Emit($op::Call,[Console].GetMethod('WriteLine',[Type[]]@([long])))};
}foreach($index in 0..3){Arg $il $index}; L $il RealCopy; CallNative $il ([byte]) @([IntPtr],[IntPtr],[IntPtr],[IntPtr]); $il.Emit($op::Ret)

$flush=$type.DefineMethod('Flush','Public,Static',[void],[Type[]]@())
$il=$flush.GetILGenerator(); $publicationStart=$il.DeclareLocal([long]); $done=$il.DefineLabel(); $cfg=$il.DeclareLocal([IntPtr]); $cmd=$il.DeclareLocal([IntPtr]); $bars=$il.DeclareLocal([IntPtr]); $i=$il.DeclareLocal([int]); $bar=$il.DeclareLocal([IntPtr]); $loop=$il.DefineLabel(); $test=$il.DefineLabel()
L $il PendingCount; $il.Emit($op::Brfalse,$done); $il.Emit($op::Call,$timestamp); $il.Emit($op::Stloc,$publicationStart); $il.Emit($op::Call,$config); $il.Emit($op::Stloc,$cfg)
$il.Emit($op::Ldc_I8,[long]1); L $il PendingCount; $il.Emit($op::Ldloc,$cfg); ReadP $il 32; $il.Emit($op::Ldloc,$cfg); ReadP $il 56; $il.Emit($op::Ldloc,$cfg); ReadP $il 0; CallNative $il ([int]) @([uint64],[int],[IntPtr],[IntPtr]); Check $il
if($Trace){$il.Emit($op::Ldstr,'BATON_TRACE: publication submitted'); $il.Emit($op::Call,[Console].GetMethod('WriteLine',[Type[]]@([string])))}
$il.Emit($op::Ldloc,$cfg); ReadP $il 16; $il.Emit($op::Stloc,$cmd); $il.Emit($op::Ldloc,$cfg); ReadP $il 64; $il.Emit($op::Stloc,$bars)
$il.Emit($op::Ldloc,$cmd); $il.Emit($op::Ldloc,$cfg); ReadP $il 8; L $il BeginCommand; CallNative $il ([int]) @([IntPtr],[IntPtr]); Check $il
I $il 0; $il.Emit($op::Stloc,$i); $il.Emit($op::Br,$test); $il.MarkLabel($loop)
$il.Emit($op::Ldloc,$bars); $il.Emit($op::Ldloc,$i); I $il 56; $il.Emit($op::Mul); $il.Emit($op::Conv_I); $il.Emit($op::Add); $il.Emit($op::Stloc,$bar)
$il.Emit($op::Ldloc,$bar); I $il 16; I $il 0; $il.Emit($op::Call,$write32)
$il.Emit($op::Ldloc,$bar); I $il 20; I $il 0x18000; $il.Emit($op::Call,$write32)
$il.Emit($op::Ldloc,$i); I $il 1; $il.Emit($op::Add); $il.Emit($op::Stloc,$i); $il.MarkLabel($test); $il.Emit($op::Ldloc,$i); L $il PendingCount; $il.Emit($op::Blt,$loop)
$il.Emit($op::Ldloc,$cmd); I $il 1; I $il 0x10000; I $il 0; I $il 0; I $il 0; $il.Emit($op::Conv_I); L $il PendingCount; $il.Emit($op::Ldloc,$bars); I $il 0; I $il 0; $il.Emit($op::Conv_I); L $il CmdBarrier; CallNative $il ([void]) @([IntPtr],[uint32],[uint32],[uint32],[uint32],[IntPtr],[uint32],[IntPtr],[uint32],[IntPtr])
$il.Emit($op::Ldloc,$cmd); L $il EndCommand; CallNative $il ([int]) @([IntPtr]); Check $il
# Signal local return semaphore on transfer after the publisher's actual copy submission.
if($Trace){$il.Emit($op::Ldstr,'BATON_TRACE: submitting transfer return signal'); $il.Emit($op::Call,[Console].GetMethod('WriteLine',[Type[]]@([string])))}
L $il TransferQueue; I $il 1; $il.Emit($op::Ldloc,$cfg); ReadP $il 48; $il.Emit($op::Ldc_I8,[long]0); L $il QueueSubmit; CallNative $il ([int]) @([IntPtr],[uint32],[IntPtr],[uint64]); Check $il
# Acquire source ownership before subsequent producer work.
if($Trace){$il.Emit($op::Ldstr,'BATON_TRACE: submitting compute return acquire'); $il.Emit($op::Call,[Console].GetMethod('WriteLine',[Type[]]@([string])))}
L $il SourceQueue; I $il 1; $il.Emit($op::Ldloc,$cfg); ReadP $il 24; $il.Emit($op::Ldc_I8,[long]0); L $il QueueSubmit; CallNative $il ([int]) @([IntPtr],[uint32],[IntPtr],[uint64]); Check $il
# Consumer uses its own imported semaphore; value pointer is configured at this slot.
if($Trace){$il.Emit($op::Ldstr,'BATON_TRACE: submitting consumer fence wait'); $il.Emit($op::Call,[Console].GetMethod('WriteLine',[Type[]]@([string])))}
L $il DestinationQueue; I $il 1; $il.Emit($op::Ldloc,$cfg); ReadP $il 40; $il.Emit($op::Ldc_I8,[long]0); L $il QueueSubmit; CallNative $il ([int]) @([IntPtr],[uint32],[IntPtr],[uint64]); Check $il
if($Trace){$il.Emit($op::Ldstr,'BATON_TRACE: return and consumer waits submitted'); $il.Emit($op::Call,[Console].GetMethod('WriteLine',[Type[]]@([string])))}
L $il PublicationTicks; $il.Emit($op::Call,$timestamp); $il.Emit($op::Ldloc,$publicationStart); $il.Emit($op::Sub); $il.Emit($op::Add); S $il PublicationTicks; Inc $il PublicationCount; I $il 0; S $il PendingCount; $il.MarkLabel($done); $il.Emit($op::Ret)

$fixView=$type.DefineMethod('FixView','Public,Static',[void],@([IntPtr]))
$il=$fixView.GetILGenerator(); $done=$il.DefineLabel(); $parent=$il.DeclareLocal([IntPtr]); Arg $il 0; $il.Emit($op::Brfalse,$done); Arg $il 0; ReadP $il 0xE8; $il.Emit($op::Stloc,$parent); $il.Emit($op::Ldloc,$parent); $il.Emit($op::Brfalse,$done); $il.Emit($op::Ldloc,$parent); $il.Emit($op::Call,$fixView); $il.Emit($op::Ldloc,$parent); ReadP $il 8; L $il DestinationBuffer; $il.Emit($op::Bne_Un,$done); Arg $il 0; I $il 8; L $il DestinationBuffer; $il.Emit($op::Call,$writePtr); Arg $il 0; I $il 0xF8; $il.Emit($op::Ldloc,$parent); ReadP $il 0xF8; Arg $il 0; Read64 $il 0xF0; $il.Emit($op::Conv_I); $il.Emit($op::Add); $il.Emit($op::Call,$writePtr); $il.MarkLabel($done); $il.Emit($op::Ret)
$fixGraph=$type.DefineMethod('FixGraphViews','Public,Static',[void],@([IntPtr]))
$il=$fixGraph.GetILGenerator(); $node=$il.DeclareLocal([IntPtr]); $nodes=$il.DeclareLocal([IntPtr]); $count=$il.DeclareLocal([int]); $i=$il.DeclareLocal([int]); $loop=$il.DefineLabel(); $test=$il.DefineLabel(); Arg $il 0; I $il 4; $il.Emit($op::Call,$marshal.GetMethod('ReadInt32',[Type[]]@([IntPtr],[int]))); $il.Emit($op::Stloc,$count); Arg $il 0; ReadP $il 16; $il.Emit($op::Stloc,$nodes); I $il 0; $il.Emit($op::Stloc,$i); $il.Emit($op::Br,$test); $il.MarkLabel($loop); $il.Emit($op::Ldloc,$nodes); $il.Emit($op::Ldloc,$i); I $il 8; $il.Emit($op::Mul); $il.Emit($op::Call,$readPtr); $il.Emit($op::Stloc,$node); $il.Emit($op::Ldloc,$node); $il.Emit($op::Call,$fixView); foreach($srcIndex in 0..9){$il.Emit($op::Ldloc,$node); ReadP $il (0x98+$srcIndex*8); $il.Emit($op::Call,$fixView)}; $il.Emit($op::Ldloc,$i); I $il 1; $il.Emit($op::Add); $il.Emit($op::Stloc,$i); $il.MarkLabel($test); $il.Emit($op::Ldloc,$i); $il.Emit($op::Ldloc,$count); $il.Emit($op::Blt,$loop); $il.Emit($op::Ret)
$setPhase=$type.DefineMethod('SetNativeBoundaryPhase','Public,Static',[void],@([int]))
$il=$setPhase.GetILGenerator(); $done=$il.DefineLabel(); L $il NativeBoundaryPhase; $il.Emit($op::Brfalse,$done); L $il NativeBoundaryPhase; I $il 0; Arg $il 0; $il.Emit($op::Call,$write32); L $il NativeBoundaryPhase; I $il 4; I $il 1; $il.Emit($op::Call,$write32); $il.MarkLabel($done); $il.Emit($op::Ret)
$gpuMarker=$type.DefineMethod('SubmitGpuMarker','Public,Static',[void],@([int],[int]))
$il=$gpuMarker.GetILGenerator(); $done=$il.DefineLabel(); $consumer=$il.DefineLabel(); $submit=$il.DefineLabel(); $table=$il.DeclareLocal([IntPtr]); $queue=$il.DeclareLocal([IntPtr]); $graphIndex=$il.DeclareLocal([int]); L $il SourceGpuSubmits; $il.Emit($op::Brfalse,$done); Arg $il 0; I $il 2; $il.Emit($op::Beq,$consumer); L $il SourceGpuSubmits; $il.Emit($op::Stloc,$table); L $il SourceQueue; $il.Emit($op::Stloc,$queue); L $il SourceGraphs; I $il 1; $il.Emit($op::Sub); $il.Emit($op::Stloc,$graphIndex); $il.Emit($op::Br,$submit); $il.MarkLabel($consumer); L $il ConsumerGpuSubmits; $il.Emit($op::Stloc,$table); L $il DestinationQueue; $il.Emit($op::Stloc,$queue); L $il DestinationGraphs; I $il 1; $il.Emit($op::Sub); $il.Emit($op::Stloc,$graphIndex); $il.MarkLabel($submit); $il.Emit($op::Ldloc,$queue); I $il 1; $il.Emit($op::Ldloc,$table); $il.Emit($op::Ldloc,$graphIndex); I $il 16; $il.Emit($op::Mul); Arg $il 1; I $il 8; $il.Emit($op::Mul); $il.Emit($op::Add); $il.Emit($op::Call,$readPtr); $il.Emit($op::Ldc_I8,[long]0); L $il QueueSubmit; CallNative $il ([int]) @([IntPtr],[uint32],[IntPtr],[uint64]); Check $il; $il.MarkLabel($done); $il.Emit($op::Ret)
$coarse=$type.DefineMethod('ApplyCoarseDecode','Public,Static',[void],@([IntPtr]))
$il=$coarse.GetILGenerator(); $done=$il.DefineLabel(); $consumer=$il.DefineLabel(); $apply=$il.DefineLabel()
L $il CoarseDecode; $il.Emit($op::Brfalse,$done)
Arg $il 0; ReadP $il 0x88; L $il DestinationDevice; $il.Emit($op::Beq,$consumer)
L $il SourceGraphs; I $il 4; $il.Emit($op::Blt,$done); $il.Emit($op::Br,$apply)
$il.MarkLabel($consumer); L $il DestinationGraphs; I $il 4; $il.Emit($op::Blt,$done)
$il.MarkLabel($apply)
# Exact stock ABI: graph RVA 36B0, divide-by-40 load at 3F67, writeback at 58B5.
Arg $il 0; ReadP $il 0x90; I $il 0x130; $il.Emit($op::Ldc_I8,[long]8000000000000); $il.Emit($op::Call,$write64)
Inc $il CoarseDecodeGraphs; $il.MarkLabel($done); $il.Emit($op::Ret)
$graph=$type.DefineMethod('HookGraph','Public,Static',[int],@([IntPtr],[IntPtr]))
$il=$graph.GetILGenerator(); Arg $il 0; $il.Emit($op::Call,$coarse); $graphStart=$il.DeclareLocal([long]); $src=$il.DefineLabel(); Arg $il 0; ReadP $il 0x88; L $il DestinationDevice; $il.Emit($op::Bne_Un,$src); if($Trace){$il.Emit($op::Ldstr,'BATON_TRACE: consumer graph publication'); $il.Emit($op::Call,[Console].GetMethod('WriteLine',[Type[]]@([string])));} if($Trace){L $il PublicationCount; $il.Emit($op::Call,[Console].GetMethod('WriteLine',[Type[]]@([int])));} $il.Emit($op::Call,$flush); if($Trace){$il.Emit($op::Ldstr,'BATON_TRACE: fixing consumer views'); $il.Emit($op::Call,[Console].GetMethod('WriteLine',[Type[]]@([string])));} Arg $il 1; $il.Emit($op::Call,$fixGraph); if($Trace){$il.Emit($op::Ldstr,'BATON_TRACE: consumer views fixed'); $il.Emit($op::Call,[Console].GetMethod('WriteLine',[Type[]]@([string])));} I $il 2; S $il LastGraphStage; Inc $il DestinationGraphs; $call=$il.DefineLabel(); $il.Emit($op::Br,$call); $il.MarkLabel($src); if($Trace){$il.Emit($op::Ldstr,'BATON_TRACE: producer graph'); $il.Emit($op::Call,[Console].GetMethod('WriteLine',[Type[]]@([string])));} I $il 1; S $il LastGraphStage; Inc $il SourceGraphs; $il.MarkLabel($call); if($Trace){$il.Emit($op::Ldstr,'BATON_TRACE: entering native graph'); $il.Emit($op::Call,[Console].GetMethod('WriteLine',[Type[]]@([string])));} L $il LastGraphStage; I $il 1; $il.Emit($op::Add); $il.Emit($op::Call,$setPhase); L $il LastGraphStage; I $il 0; $il.Emit($op::Call,$gpuMarker); $il.Emit($op::Call,$timestamp); $il.Emit($op::Stloc,$graphStart); Arg $il 0; Arg $il 1; L $il RealGraph; CallNative $il ([int]) @([IntPtr],[IntPtr]); $tickConsumer=$il.DefineLabel(); $tickDone=$il.DefineLabel(); L $il LastGraphStage; I $il 2; $il.Emit($op::Beq,$tickConsumer); L $il SourceGraphTicks; $il.Emit($op::Call,$timestamp); $il.Emit($op::Ldloc,$graphStart); $il.Emit($op::Sub); $il.Emit($op::Add); S $il SourceGraphTicks; $il.Emit($op::Br,$tickDone); $il.MarkLabel($tickConsumer); L $il ConsumerGraphTicks; $il.Emit($op::Call,$timestamp); $il.Emit($op::Ldloc,$graphStart); $il.Emit($op::Sub); $il.Emit($op::Add); S $il ConsumerGraphTicks; $il.MarkLabel($tickDone); L $il LastGraphStage; I $il 1; $il.Emit($op::Call,$gpuMarker); I $il 0; $il.Emit($op::Call,$setPhase);$phaseDone=$il.DefineLabel(); L $il LastGraphStage; I $il 1; $il.Emit($op::Bne_Un,$phaseDone); L $il SingleDieMode; $il.Emit($op::Brtrue,$phaseDone); I $il 1; $il.Emit($op::Call,$setPhase); $il.MarkLabel($phaseDone); if($Trace){$il.Emit($op::Ldstr,'BATON_TRACE: native graph returned'); $il.Emit($op::Call,[Console].GetMethod('WriteLine',[Type[]]@([string])));} $il.Emit($op::Ret)
# Completion certificates come only from the existing terminal readback sync.
# Deferred events and their command buffers remain owned by the native event object.
$findEvent=$type.DefineMethod('FindEventRecord','Public,Static',[IntPtr],@([IntPtr]))
$il=$findEvent.GetILGenerator(); $i=$il.DeclareLocal([int]); $p=$il.DeclareLocal([IntPtr]); $loop=$il.DefineLabel(); $test=$il.DefineLabel(); $next=$il.DefineLabel()
I $il 0; $il.Emit($op::Stloc,$i); $il.Emit($op::Br,$test); $il.MarkLabel($loop); L $il EventRecords; $il.Emit($op::Ldloc,$i); I $il 32; $il.Emit($op::Mul); $il.Emit($op::Conv_I); $il.Emit($op::Add); $il.Emit($op::Stloc,$p); $il.Emit($op::Ldloc,$p); ReadP $il 0; Arg $il 0; $il.Emit($op::Bne_Un,$next); $il.Emit($op::Ldloc,$p); $il.Emit($op::Ret); $il.MarkLabel($next); $il.Emit($op::Ldloc,$i); I $il 1; $il.Emit($op::Add); $il.Emit($op::Stloc,$i); $il.MarkLabel($test); $il.Emit($op::Ldloc,$i); L $il EventRecordCount; $il.Emit($op::Blt,$loop); I $il 0; $il.Emit($op::Conv_I); $il.Emit($op::Ret)
$record=$type.DefineMethod('HookEventRecord','Public,Static',[void],@([IntPtr],[IntPtr]))
$il=$record.GetILGenerator(); $p=$il.DeclareLocal([IntPtr]); $done=$il.DefineLabel(); $found=$il.DefineLabel(); $capacity=$il.DefineLabel(); Arg $il 0; Arg $il 1; L $il RealEventRecord; CallNative $il ([void]) @([IntPtr],[IntPtr]); Arg $il 0; ReadP $il 0x88; L $il DestinationDevice; $il.Emit($op::Bne_Un,$done); Arg $il 1; $il.Emit($op::Call,$findEvent); $il.Emit($op::Stloc,$p); $il.Emit($op::Ldloc,$p); $il.Emit($op::Brtrue,$found); L $il EventRecordCount; L $il MaxEventRecords; $il.Emit($op::Blt,$capacity); Fail $il 'event certificate capacity exhausted'; $il.MarkLabel($capacity); L $il EventRecords; L $il EventRecordCount; I $il 32; $il.Emit($op::Mul); $il.Emit($op::Conv_I); $il.Emit($op::Add); $il.Emit($op::Stloc,$p); $il.Emit($op::Ldloc,$p); I $il 0; Arg $il 1; $il.Emit($op::Call,$writePtr); Inc $il EventRecordCount; $il.MarkLabel($found); $il.Emit($op::Ldloc,$p); I $il 8; Arg $il 0; $il.Emit($op::Call,$writePtr); $il.Emit($op::Ldloc,$p); I $il 16; Arg $il 1; ReadP $il 8; Read64 $il 72; $il.Emit($op::Call,$write64); $il.MarkLabel($done); $il.Emit($op::Ret)
$certify=$type.DefineMethod('CertifyCompletedBackendEvents','Public,Static',[void],@([IntPtr]))
$il=$certify.GetILGenerator(); $i=$il.DeclareLocal([int]); $p=$il.DeclareLocal([IntPtr]); $loop=$il.DefineLabel(); $test=$il.DefineLabel(); $next=$il.DefineLabel(); I $il 0; $il.Emit($op::Stloc,$i); $il.Emit($op::Br,$test); $il.MarkLabel($loop); L $il EventRecords; $il.Emit($op::Ldloc,$i); I $il 32; $il.Emit($op::Mul); $il.Emit($op::Conv_I); $il.Emit($op::Add); $il.Emit($op::Stloc,$p); $il.Emit($op::Ldloc,$p); ReadP $il 8; Arg $il 0; $il.Emit($op::Bne_Un,$next); $il.Emit($op::Ldloc,$p); I $il 24; $il.Emit($op::Ldloc,$p); Read64 $il 16; $il.Emit($op::Call,$write64); $il.MarkLabel($next); $il.Emit($op::Ldloc,$i); I $il 1; $il.Emit($op::Add); $il.Emit($op::Stloc,$i); $il.MarkLabel($test); $il.Emit($op::Ldloc,$i); L $il EventRecordCount; $il.Emit($op::Blt,$loop); $il.Emit($op::Ret)
$guard=$type.DefineMethod('GuardBoundaryWait','Public,Static',[void],[Type[]]@())
$il=$guard.GetILGenerator(); $ok=$il.DefineLabel(); L $il SingleDieMode; $il.Emit($op::Brtrue,$ok); L $il LastGraphStage; I $il 1; $il.Emit($op::Bne_Un,$ok); Inc $il BlockedBoundaryWaits; foreach($name in @('SourceGraphs','DestinationGraphs','PendingCount','HandledCopies','OtherCopies')){$il.Emit($op::Ldstr,"BATON_STATE: $name"); $il.Emit($op::Call,[Console].GetMethod('WriteLine',[Type[]]@([string]))); L $il $name; $il.Emit($op::Call,[Console].GetMethod('WriteLine',[Type[]]@([int])))}; Fail $il 'host synchronization requested between producer and consumer'; $il.MarkLabel($ok); $il.Emit($op::Ret)
$sync=$type.DefineMethod('HookSync','Public,Static',[void],@([IntPtr]))
$il=$sync.GetILGenerator(); if($Trace){$il.Emit($op::Ldstr,'BATON_TRACE: backend synchronize'); $il.Emit($op::Call,[Console].GetMethod('WriteLine',[Type[]]@([string])));} $il.Emit($op::Call,$guard); Inc $il AllowedSyncs; Arg $il 0; L $il RealSync; CallNative $il ([void]) @([IntPtr]); Arg $il 0; $il.Emit($op::Call,$certify); $il.Emit($op::Ret)
$event=$type.DefineMethod('HookEventSync','Public,Static',[void],@([IntPtr],[IntPtr]))
$il=$event.GetILGenerator(); $native=$il.DefineLabel(); $guarded=$il.DefineLabel(); $p=$il.DeclareLocal([IntPtr]); Arg $il 1; ReadP $il 8; I $il 56; $il.Emit($op::Call,$marshal.GetMethod('ReadByte',[Type[]]@([IntPtr],[int]))); $il.Emit($op::Brfalse,$native); L $il LastGraphStage; I $il 1; $il.Emit($op::Bne_Un,$native); Arg $il 0; L $il DestinationDevice; $il.Emit($op::Bne_Un,$guarded); Arg $il 1; $il.Emit($op::Call,$findEvent); $il.Emit($op::Stloc,$p); $il.Emit($op::Ldloc,$p); $il.Emit($op::Brfalse,$guarded); $il.Emit($op::Ldloc,$p); Read64 $il 24; Arg $il 1; ReadP $il 8; Read64 $il 72; $il.Emit($op::Blt_Un,$guarded); Inc $il DeferredCompletedEventCleanups; $il.Emit($op::Ret); $il.MarkLabel($guarded); $il.Emit($op::Call,$guard); $il.MarkLabel($native); Arg $il 0; Arg $il 1; L $il RealEventSync; CallNative $il ([void]) @([IntPtr],[IntPtr]); $il.Emit($op::Ret)
$type.CreateType() | Out-Null
$builder.Save($OutputPath)
Write-Output "Emitted $OutputPath"
