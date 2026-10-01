param([switch]$SingleDie,[switch]$Mutation,[string]$DeviceSelection='Vulkan0,Vulkan1',[switch]$AllowGraphicsQueue,[int]$MaxNodes=100)
$ErrorActionPreference='Stop'
if($AllowGraphicsQueue){$env:GGML_VK_ALLOW_GRAPHICS_QUEUE='1'}else{Remove-Item Env:\GGML_VK_ALLOW_GRAPHICS_QUEUE -ErrorAction SilentlyContinue}
$env:GGML_VK_MAX_NODES_PER_SUBMIT="$MaxNodes"
Write-Host "QUEUE_DIAGNOSTIC: graphics=$([bool]$AllowGraphicsQueue), maxNodes=$MaxNodes, devices=$DeviceSelection, single=$([bool]$SingleDie), mutation=$([bool]$Mutation)"
if($Mutation){
    & "$PSScriptRoot\Launch-Integration.ps1" -DeviceSelection $DeviceSelection.Replace(',','/') -SingleDie:$SingleDie -Tokens 32 -MaxPublications 35 -GpuProfile
}else{
    & "$PSScriptRoot\Launch-StockControl.ps1" -DeviceSelection $DeviceSelection -SingleDie:$SingleDie -Tokens 32
}
