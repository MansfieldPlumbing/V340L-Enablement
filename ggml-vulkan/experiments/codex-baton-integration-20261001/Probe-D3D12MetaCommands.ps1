param([string]$OutputPath="$PSScriptRoot\d3d12-metacommand-census.json")
$ErrorActionPreference='Stop'
$interop=& 'C:\dev\V340L-Emancipated\src\New-WindowsFunctionPointerBinder.ps1'
$blocks=[Collections.Generic.List[IntPtr]]::new()
$objects=[Collections.Generic.List[IntPtr]]::new()
function Block([int]$n){$p=[Runtime.InteropServices.Marshal]::AllocHGlobal($n); [Runtime.InteropServices.Marshal]::Copy([byte[]]::new($n),0,$p,$n); $blocks.Add($p); $p}
function GuidBlock([string]$s){$p=Block 16; [Runtime.InteropServices.Marshal]::Copy(([Guid]$s).ToByteArray(),0,$p,16); $p}
function Check([int]$hr,[string]$name){if($hr -lt 0){throw ('{0}: HRESULT 0x{1:X8}' -f $name,([BitConverter]::ToUInt32([BitConverter]::GetBytes($hr),0)))}}
function ReadP([IntPtr]$p,[int]$o=0){[Runtime.InteropServices.Marshal]::ReadIntPtr($p,$o)}
function Read32([IntPtr]$p,[int]$o=0){[Runtime.InteropServices.Marshal]::ReadInt32($p,$o)}
function Keep([IntPtr]$p){$objects.Add($p); $p}
try{
 Write-Host 'CENSUS: create factory'
 $create=$interop.GetExportCall('dxgi.dll','CreateDXGIFactory1',[int],@([IntPtr],[IntPtr]))
 $out=Block 8
 Check ($create.Invoke((GuidBlock '770aae78-f26f-4dba-a829-253c83d1b387'),$out)) 'CreateDXGIFactory1'
 $factory=Keep (ReadP $out)
 $enumerate=$interop.GetComCall($factory,12,[int],@([uint32],[IntPtr]))
 $createDevice=$interop.GetExportCall('d3d12.dll','D3D12CreateDevice',[int],@([IntPtr],[uint32],[IntPtr],[IntPtr]))
 $iidDevice=GuidBlock '189819f1-1db6-4b57-be54-1821339b85f7'
 $iidDevice5=GuidBlock '8b4f173b-2fea-4b80-8f58-4307191ab95d'
 $rows=@(for($index=0;;$index++){
  Write-Host "CENSUS: enumerate adapter $index"
  $hr=$enumerate.Invoke($factory,[uint32]$index,$out)
  if($hr -eq -2005270526){break}
  Check $hr 'EnumAdapters1'
  $adapter=Keep (ReadP $out); $desc=Block 312
  Check ($interop.GetComCall($adapter,10,[int],@([IntPtr])).Invoke($adapter,$desc)) 'GetDesc1'
  $name=[Runtime.InteropServices.Marshal]::PtrToStringUni($desc,128).TrimEnd([char]0)
  if((Read32 $desc 304) -band 2){continue}
  Write-Host "CENSUS: create device $name"
  $hr=$createDevice.Invoke($adapter,[uint32]0xB000,$iidDevice,$out)
  if($hr -lt 0){[pscustomobject]@{Adapter=$index;Name=$name;DeviceHResult=$hr};continue}
  $device=Keep (ReadP $out)
  Write-Host 'CENSUS: QueryInterface device5'
  $hr=$interop.GetComCall($device,0,[int],@([IntPtr],[IntPtr])).Invoke($device,$iidDevice5,$out)
  if($hr -lt 0){[pscustomobject]@{Adapter=$index;Name=$name;Device5HResult=$hr};continue}
  $device5=Keep (ReadP $out); $count=Block 4
  # Slots 59/60: SDK conditional return-value declarations occupy one slot each.
  $enumMeta=$interop.GetComCall($device5,59,[int],@([IntPtr],[IntPtr]))
  Write-Host 'CENSUS: enumerate metacommands'
  Check ($enumMeta.Invoke($device5,$count,[IntPtr]::Zero)) 'EnumerateMetaCommands count'
  $n=Read32 $count; $commands=@()
  if($n -gt 0){
   $meta=Block ($n*32)
   Check ($enumMeta.Invoke($device5,$count,$meta)) 'EnumerateMetaCommands descriptors'
   $enumParams=$interop.GetComCall($device5,60,[int],@([IntPtr],[uint32],[IntPtr],[IntPtr],[IntPtr]))
   $commands=@(for($i=0;$i -lt (Read32 $count);$i++){
    $p=[IntPtr]($meta.ToInt64()+$i*32); $guidBytes=[byte[]]::new(16); [Runtime.InteropServices.Marshal]::Copy($p,$guidBytes,0,16)
    $stages=@(for($stage=0;$stage -lt 3;$stage++){
     $total=Block 4; $pc=Block 4
     Check ($enumParams.Invoke($device5,$p,[uint32]$stage,$total,$pc,[IntPtr]::Zero)) 'EnumerateMetaCommandParameters count'
     $pn=Read32 $pc; $parameters=@()
     if($pn -gt 0){
      $pd=Block ($pn*24)
      Check ($enumParams.Invoke($device5,$p,[uint32]$stage,$total,$pc,$pd)) 'EnumerateMetaCommandParameters descriptors'
      $parameters=@(for($j=0;$j -lt (Read32 $pc);$j++){
       $pp=[IntPtr]($pd.ToInt64()+$j*24)
       [pscustomobject]@{Name=[Runtime.InteropServices.Marshal]::PtrToStringUni((ReadP $pp));Type=Read32 $pp 8;Flags=Read32 $pp 12;RequiredResourceState=Read32 $pp 16;StructureOffset=Read32 $pp 20}
      })
     }
     [pscustomobject]@{Stage=$stage;StructureSize=Read32 $total;Parameters=$parameters}
    })
    [pscustomobject]@{Id=([Guid]::new($guidBytes)).ToString();Name=[Runtime.InteropServices.Marshal]::PtrToStringUni((ReadP $p 16));InitializationDirtyState=Read32 $p 24;ExecutionDirtyState=Read32 $p 28;Stages=$stages}
   })
  }
  [pscustomobject]@{Adapter=$index;Name=$name;Device5HResult=$hr;MetaCommandCount=$n;Commands=$commands}
 })
 $rows | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath
 $rows | Select-Object Adapter,Name,Device5HResult,MetaCommandCount | Format-Table | Out-Host
}finally{
 for($i=$objects.Count-1;$i -ge 0;$i--){$interop.ReleaseCom($objects[$i]) | Out-Null}
 foreach($p in $blocks){[Runtime.InteropServices.Marshal]::FreeHGlobal($p)}
 $interop.Dispose()
}
