# Emits a diagnostic variant; preserves the one-shot publisher source and binaries.
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot 'New-Publisher-OneShot.ps1'
$text=[IO.File]::ReadAllText($source)
$fieldAnchor='# Configuration and Device Handles'
$fields=@'
$fields['TimingQueryPool']=$type.DefineField('TimingQueryPool',[uint64],'Public,Static')
$fields['TimingWriteTimestamp']=$type.DefineField('TimingWriteTimestamp',[IntPtr],'Public,Static')
$fields['TimingResetQueries']=$type.DefineField('TimingResetQueries',[IntPtr],'Public,Static')
$fields['TimingRegionCount']=$type.DefineField('TimingRegionCount',[int],'Public,Static')
'@
$resetAnchor='$ilPb.MarkLabel($lblBeginTOk)'
$reset=@'
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
$ilPb.Emit([Reflection.Emit.OpCodes]::Stsfld,$fields.TimingRegionCount)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld,$fields.CmdTransfer)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld,$fields.TimingQueryPool)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4,0)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4,2)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld,$fields.TimingResetQueries)
$ilPb.EmitCalli([Reflection.Emit.OpCodes]::Calli,[Runtime.InteropServices.CallingConvention]::Cdecl,[void],@([IntPtr],[uint64],[uint32],[uint32]))
'@
function TimestampIL([int]$Index) {
 @'
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld,$fields.CmdTransfer)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4,0x10000)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld,$fields.TimingQueryPool)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldc_I4,INDEX_VALUE)
$ilPb.Emit([Reflection.Emit.OpCodes]::Ldsfld,$fields.TimingWriteTimestamp)
$ilPb.EmitCalli([Reflection.Emit.OpCodes]::Calli,[Runtime.InteropServices.CallingConvention]::Cdecl,[void],@([IntPtr],[uint32],[uint64],[uint32]))
'@.Replace('INDEX_VALUE',"$Index")
}
foreach($anchor in @($fieldAnchor,$resetAnchor,'# --- Batched Copy into Aperture Buffer Loop ---','# --- Release Barrier before D3D12 Fence Signal ---')){if(-not $text.Contains($anchor)){throw "Timing anchor absent: $anchor"}}
$text=$text.Replace($fieldAnchor,$fields+"`n"+$fieldAnchor)
$text=$text.Replace($resetAnchor,$resetAnchor+"`n"+$reset)
$text=$text.Replace('# --- Batched Copy into Aperture Buffer Loop ---',(TimestampIL 0)+"`n"+'# --- Batched Copy into Aperture Buffer Loop ---')
$text=$text.Replace('# --- Release Barrier before D3D12 Fence Signal ---',(TimestampIL 1)+"`n"+'# --- Release Barrier before D3D12 Fence Signal ---')
$scriptPath=Join-Path $PSScriptRoot 'Publisher-Timing-Emitter.ps1'
[IO.File]::WriteAllText($scriptPath,$text)
& $scriptPath -OutputPath (Join-Path $PSScriptRoot 'Publisher-Timing.dll')
