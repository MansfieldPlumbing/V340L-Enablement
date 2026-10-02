[CmdletBinding()]
param(
    [switch]$Help,
    [switch]$List,
    [ValidateSet('Status','Floor','Preset','Tui','HBCC')][string]$Mode='Status',
    [ValidateSet('VeryLow','Low','Quiet','Balanced','Fast')][string]$Preset='Balanced',
    [Nullable[int]]$CoreMaxMHz,
    [Nullable[int]]$MemoryMaxMHz,
    [Alias('CoreLevelsMHz')][string]$CoreLevelsCsv,
    [Alias('MemoryLevelsMHz')][string]$MemoryLevelsCsv,
    [switch]$Apply,
    [switch]$Restart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$CoreLevelsMHz = @()
$MemoryLevelsMHz = @()
if (-not [string]::IsNullOrWhiteSpace($CoreLevelsCsv)) {
    $CoreLevelsMHz = @($CoreLevelsCsv.Split(',') | ForEach-Object { [int]::Parse($_.Trim()) })
}
if (-not [string]::IsNullOrWhiteSpace($MemoryLevelsCsv)) {
    $MemoryLevelsMHz = @($MemoryLevelsCsv.Split(',') | ForEach-Object { [int]::Parse($_.Trim()) })
}
$valueName = 'PP_PhmSoftPowerPlayTable'
$bootDir = 'C:\ProgramData\V340L-PowerPlay'
$bootTable = Join-Path $bootDir 'V340L-low-first-half-max.bin'
$bootScript = Join-Path $bootDir 'Apply-V340L-PowerPlayAtBoot.ps1'
$coreOffsets = @()
$memoryOffsets = @()

function Show-Help {
    @'
V340L - DISCOVERED DIES, ONE SHARED PROFILE

  V340L.cmd                                Show help and current tables
  V340L.cmd -Mode Tui                      Interactive editor (Tab/F5/Enter)
  V340L.cmd -Mode Floor                    Preview emergency floor
  V340L.cmd -Mode Floor -Apply             Apply floor to every present die
  V340L.cmd -Mode Preset -Preset Fast      Preview one of five presets
  V340L.cmd -Mode Preset -Preset Fast -Apply
  V340L.cmd -CoreMaxMHz 1200 -Apply        Custom core ceiling only
  V340L.cmd -MemoryMaxMHz 700 -Apply       Custom memory ceiling only
  V340L.cmd -CoreLevelsMHz 300,400,560,775,900,1000,1100,1200 -Apply
  V340L.cmd -MemoryLevelsMHz 167,300,500,700 -Apply
  V340L.cmd -Mode HBCC                      Inspect 12 GiB / 8 GiB KMD values
  V340L.cmd -Mode HBCC -Apply               Set HBCC-off values on present dies

Combine core and memory arguments to change both. -Apply writes the same
PowerPlay table to every present V340L die. The script discovers driver
class keys; it does not assume a fixed die count or key number.
Restart Windows afterward. -Restart adds an immediate reboot.

Limits: core 300-1500 MHz; memory 167-945 MHz. Clocks must ascend.
Voltages are not changed by this script.
'@ | Write-Host
}

function Get-Hash([byte[]]$bytes) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}
function Get-Clock([byte[]]$bytes, [int]$offset) {
    [int]([BitConverter]::ToUInt32($bytes,$offset) / 100)
}
function Set-Clock([byte[]]$bytes, [int]$offset, [int]$mhz) {
    $encoded = [BitConverter]::GetBytes([uint32]($mhz * 100))
    [Array]::Copy($encoded,0,$bytes,$offset,4)
}
function Check-Table([byte[]]$bytes) {
    if ($bytes.Length -lt 128 -or $bytes.Length -gt 4096 -or [BitConverter]::ToUInt16($bytes,0) -ne $bytes.Length -or
        $bytes[2] -ne 8 -or $bytes[3] -ne 1) {
        throw 'Unexpected table length or PowerPlay revision; no writes made.'
    }
    $gfx = [BitConverter]::ToUInt16($bytes,58)
    $mem = [BitConverter]::ToUInt16($bytes,56)
    if ($gfx -lt 92 -or $mem -lt 92 -or $gfx+2+8*13 -gt $bytes.Length -or
        $mem+2+4*7 -gt $bytes.Length -or $bytes[$gfx] -ne 1 -or $bytes[$gfx+1] -ne 8 -or
        $bytes[$mem] -ne 1 -or $bytes[$mem+1] -ne 4) {
        throw 'Unsupported Vega 10 dependency layout; no writes made.'
    }
    $script:coreOffsets = @(0..7 | ForEach-Object { $gfx+2+13*$_ })
    $script:memoryOffsets = @(0..3 | ForEach-Object { $mem+2+7*$_ })
    foreach ($offset in ($coreOffsets + $memoryOffsets)) {
        if ($offset + 4 -gt $bytes.Length) { throw 'Clock offset is outside table.' }
    }
}
function Check-Levels([int[]]$levels, [int]$count, [int]$minimum, [int]$maximum, [string]$domain) {
    if ($levels.Count -ne $count) { throw "$domain needs exactly $count levels." }
    for ($i=0; $i -lt $levels.Count; $i++) {
        if ($levels[$i] -lt $minimum -or $levels[$i] -gt $maximum) {
            throw "$domain level $i must be $minimum-$maximum MHz."
        }
        if ($i -gt 0 -and $levels[$i] -lt $levels[$i-1]) {
            throw "$domain clocks must be nondecreasing."
        }
    }
}
function Get-Targets {
    $devices = @(Get-PnpDevice -PresentOnly -Class Display | Where-Object {
        $_.InstanceId -match '^PCI\\VEN_1002&DEV_6864&SUBSYS_0C001002&'
    })
    @(foreach ($device in $devices) {
        $driver = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName DEVPKEY_Device_Driver).Data
        if ($driver -notmatch '^\{4d36e968-e325-11ce-bfc1-08002be10318\}\\\d{4}$') {
            throw "Unexpected display driver key for $($device.InstanceId): $driver"
        }
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\' + $driver
        $item = Get-ItemProperty -LiteralPath $key
        if ($item.DriverDesc -notmatch 'V340L') { throw "Unexpected driver at $key" }
        $property = $item.PSObject.Properties[$valueName]
        $bytes = if ($null -ne $property) { [byte[]]$property.Value } else { $null }
        if ($null -ne $bytes) { Check-Table $bytes }
        [pscustomobject]@{
            Name=$device.FriendlyName; InstanceId=$device.InstanceId; Key=$key
            Bytes=$bytes; Hash=$(if ($null -ne $bytes) { Get-Hash $bytes } else { $null })
        }
    })
}

function Test-Administrator {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Request-Elevation {
    param([string]$RequestedMode,[string]$RequestedPreset,[object]$CallerArguments)
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',('"'+$PSCommandPath+'"'),'-Mode',$RequestedMode)
    if ($RequestedMode -eq 'Preset') { $arguments += @('-Preset',$RequestedPreset) }
    foreach ($name in @('CoreMaxMHz','MemoryMaxMHz','CoreLevelsCsv','MemoryLevelsCsv')) {
        if ($CallerArguments.ContainsKey($name)) {
            $value = $CallerArguments[$name]
            $arguments += "-$name"
            $arguments += $(if ($value -is [array]) { $value -join ',' } else { [string]$value })
        }
    }
    $arguments += '-Apply'
    if ($Restart) { $arguments += '-Restart' }
    Write-Host 'Requesting Administrator access...'
    Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList ($arguments -join ' ')
}
if ($Help -or ($Mode -eq 'Status' -and -not $Apply)) { Show-Help }
$targets = @(Get-Targets)
if ($Mode -ne 'Tui') {
Write-Host "Discovered $($targets.Count) present V340L die(s)."
foreach ($target in $targets) {
    if ($Mode -eq 'HBCC') { continue }
    if (-not $List -and ($Mode -ne 'Status' -or $PSBoundParameters.ContainsKey('CoreMaxMHz') -or
        $PSBoundParameters.ContainsKey('MemoryMaxMHz') -or $CoreLevelsMHz.Count -gt 0 -or $MemoryLevelsMHz.Count -gt 0)) {
        Write-Host "  $($target.Key.Split('\')[-1]) $($target.InstanceId.Split('\')[-1]) core-max=$(if($null -ne $target.Bytes){Get-Clock $target.Bytes $coreOffsets[-1]}else{'no-table'})"
        continue
    }
    Write-Host "  $($target.InstanceId)"
    Write-Host "    $($target.Key)"
    if ($null -ne $target.Bytes) {
        Write-Host "    PowerPlay 8.1 SHA256 $($target.Hash)"
        Write-Host "    Core MHz: $(@(foreach ($offset in $coreOffsets) { Get-Clock $target.Bytes $offset }) -join ', ')"
        Write-Host "    Memory MHz: $(@(foreach ($offset in $memoryOffsets) { Get-Clock $target.Bytes $offset }) -join ', ')"
    } else { Write-Host '    No SPPT override installed; supply a verified Vega 10 8.1 table before editing.' }
}
}
if ($Mode -eq 'Status' -and -not $Apply -and -not $PSBoundParameters.ContainsKey('CoreMaxMHz') -and
    -not $PSBoundParameters.ContainsKey('MemoryMaxMHz') -and $CoreLevelsMHz.Count -eq 0 -and
    $MemoryLevelsMHz.Count -eq 0) { return }
if ($Mode -eq 'HBCC') {
    $names = @('KMD_EnablePageMigration','KMD_VirtualSegmentSize')
    foreach ($target in $targets) {
        $item = Get-ItemProperty -LiteralPath $target.Key
        foreach ($name in $names) {
            $p = $item.PSObject.Properties[$name]
            Write-Host "  $($target.Key.Split('\')[-1]) $name=$(if ($null -eq $p) { '<absent>' } else { $p.Value })"
        }
    }
    if (-not $Apply) { Write-Host 'Preview only. -Apply sets both values to DWORD 0; reboot afterward.'; return }
    if ($targets.Count -eq 0) { throw 'No present V340L dies; no writes made.' }
    if (-not (Test-Administrator)) { Request-Elevation 'HBCC' $Preset $PSBoundParameters; return }
    $backupDir = Join-Path $bootDir 'backups'
    [IO.Directory]::CreateDirectory($backupDir) | Out-Null
    $backup = @(foreach ($target in $targets) {
        $item = Get-ItemProperty -LiteralPath $target.Key
        [pscustomobject]@{InstanceId=$target.InstanceId;Key=$target.Key;Values=@(foreach ($name in $names) {
            $p=$item.PSObject.Properties[$name]
            [pscustomobject]@{Name=$name;Present=($null -ne $p);Value=$(if($null -ne $p){$p.Value}else{$null});Kind=$(if($null -ne $p){(Get-Item -LiteralPath $target.Key).GetValueKind($name).ToString()}else{$null})}
        })}
    })
    $backupPath = Join-Path $backupDir ('hbcc-before-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'.json')
    $backup | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $backupPath
    try {
        foreach ($target in $targets) {
            foreach ($name in $names) { New-ItemProperty -LiteralPath $target.Key -Name $name -PropertyType DWord -Value 0 -Force | Out-Null }
        }
        foreach ($target in $targets) {
            foreach ($name in $names) {
                if ((Get-ItemPropertyValue -LiteralPath $target.Key -Name $name) -ne 0) { throw "HBCC readback failed at $($target.Key) $name" }
            }
        }
    } catch {
        foreach ($entry in $backup) {
            foreach ($value in $entry.Values) {
                if ($value.Present) { New-ItemProperty -LiteralPath $entry.Key -Name $value.Name -PropertyType $value.Kind -Value $value.Value -Force | Out-Null }
                else { Remove-ItemProperty -LiteralPath $entry.Key -Name $value.Name -ErrorAction SilentlyContinue }
            }
        }
        throw
    }
    Write-Host "HBCC KMD overrides verified on $($targets.Count) die(s). Backup: $backupPath"
    Write-Host 'Reboot, then check Task Manager dedicated memory (expected about 8 GiB per die).'
    if ($Restart) { Restart-Computer -Force }
    return
}
if ($Mode -eq 'Tui') {
    . (Join-Path $PSScriptRoot 'V340L-TUI.ps1')
    $choice = Invoke-V340Tui $targets $coreOffsets $memoryOffsets
    if ($null -eq $choice) { return }
    $Mode = $choice.Mode
    $Preset = $choice.Preset
    if ($choice.CoreMaxMHz -gt 0) { $CoreMaxMHz = [int]$choice.CoreMaxMHz; $PSBoundParameters['CoreMaxMHz'] = $CoreMaxMHz }
    if ($choice.MemoryMaxMHz -gt 0) { $MemoryMaxMHz = [int]$choice.MemoryMaxMHz; $PSBoundParameters['MemoryMaxMHz'] = $MemoryMaxMHz }
    $Apply = $true
}
if ($targets.Count -eq 0) { throw 'No present V340L dies; no writes made.' }
if (@($targets | Where-Object { $null -eq $_.Bytes }).Count -gt 0) { throw 'A present die lacks an SPPT override; no writes made.' }
$hashes = @($targets | Select-Object -ExpandProperty Hash -Unique)
if ($hashes.Count -ne 1) { throw 'Present registry tables differ. Resolve this before applying one shared profile.' }

$candidate = [byte[]]$targets[0].Bytes.Clone()
$core = @(foreach ($offset in $coreOffsets) { Get-Clock $candidate $offset })
$memory = @(foreach ($offset in $memoryOffsets) { Get-Clock $candidate $offset })
if ($Mode -eq 'Floor') {
    $core = @(300,300,300,300,300,300,300,300)
    $memory = @(167,167,167,167)
}
if ($Mode -eq 'Preset') {
    $ceiling = switch ($Preset) {
        'VeryLow' { @(600,300) }
        'Low' { @(750,470) }
        'Quiet' { @(900,600) }
        'Balanced' { @(1050,700) }
        'Fast' { @(1200,800) }
    }
    $core = @($core | ForEach-Object { [Math]::Min($_,$ceiling[0]) })
    $memory = @($memory | ForEach-Object { [Math]::Min($_,$ceiling[1]) })
    $core[7] = $ceiling[0]
    $memory[3] = $ceiling[1]
}
if ($CoreLevelsMHz.Count -gt 0 -and $PSBoundParameters.ContainsKey('CoreMaxMHz')) {
    throw 'Use either -CoreMaxMHz or -CoreLevelsMHz.'
}
if ($MemoryLevelsMHz.Count -gt 0 -and $PSBoundParameters.ContainsKey('MemoryMaxMHz')) {
    throw 'Use either -MemoryMaxMHz or -MemoryLevelsMHz.'
}
if ($CoreLevelsMHz.Count -gt 0) { $core = $CoreLevelsMHz }
elseif ($PSBoundParameters.ContainsKey('CoreMaxMHz')) { $core[7] = [int]$CoreMaxMHz }
if ($MemoryLevelsMHz.Count -gt 0) { $memory = $MemoryLevelsMHz }
elseif ($PSBoundParameters.ContainsKey('MemoryMaxMHz')) { $memory[3] = [int]$MemoryMaxMHz }
Check-Levels $core 8 300 1500 'Core'
Check-Levels $memory 4 167 945 'Memory'
for ($i=0; $i -lt 8; $i++) { Set-Clock $candidate $coreOffsets[$i] $core[$i] }
for ($i=0; $i -lt 4; $i++) { Set-Clock $candidate $memoryOffsets[$i] $memory[$i] }
$newHash = Get-Hash $candidate
Write-Host "Target core MHz: $($core -join ', ')"
Write-Host "Target memory MHz: $($memory -join ', ')"
Write-Host "Target SHA256: $newHash"
if (-not $Apply) { Write-Host 'Preview only. Add -Apply to install this profile on every present die.'; return }
if (-not ($Mode -in @('Floor','Preset') -or $PSBoundParameters.ContainsKey('CoreMaxMHz') -or
    $PSBoundParameters.ContainsKey('MemoryMaxMHz') -or $CoreLevelsMHz.Count -gt 0 -or $MemoryLevelsMHz.Count -gt 0)) {
    throw '-Apply requires a clock argument.'
}
if ($newHash -eq $hashes[0]) { Write-Host 'All present tables already match the requested profile.'; return }

if (-not (Test-Administrator)) { Request-Elevation $Mode $Preset $PSBoundParameters; return }

$bootManaged = (Test-Path -LiteralPath $bootTable) -and (Test-Path -LiteralPath $bootScript)
if ($bootManaged) {
    $oldBootBytes = [IO.File]::ReadAllBytes($bootTable)
    $oldBootHash = Get-Hash $oldBootBytes
    if ($oldBootHash -ne $hashes[0]) { throw 'Boot profile differs from the present registry tables; no writes made.' }
    $oldBootScript = [IO.File]::ReadAllText($bootScript)
    $expectedText = "`$expectedHash = '$oldBootHash'"
    if (-not $oldBootScript.Contains($expectedText)) { throw 'Boot task hash guard differs from installed profile; no writes made.' }
    $newBootScript = $oldBootScript.Replace($expectedText, "`$expectedHash = '$newHash'")
}
$backupDir = Join-Path $bootDir 'backups'
[IO.Directory]::CreateDirectory($backupDir) | Out-Null
$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$backupFile = Join-Path $backupDir "before-$stamp.json"
$backup = @($targets | ForEach-Object { [pscustomobject]@{InstanceId=$_.InstanceId;Key=$_.Key;BinaryBase64=[Convert]::ToBase64String($_.Bytes)} })
$backup | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $backupFile
$written = @()
try {
    foreach ($target in $targets) {
        $written += $target
        New-ItemProperty -LiteralPath $target.Key -Name $valueName -PropertyType Binary -Value $candidate -Force | Out-Null
        $readback = [byte[]](Get-ItemPropertyValue -LiteralPath $target.Key -Name $valueName)
        if ((Get-Hash $readback) -ne $newHash) { throw "Readback mismatch at $($target.Key)" }
    }
    if ($bootManaged) {
        [IO.File]::WriteAllBytes($bootTable,$candidate)
        [IO.File]::WriteAllText($bootScript,$newBootScript,[Text.UTF8Encoding]::new($false))
        if ((Get-Hash ([IO.File]::ReadAllBytes($bootTable))) -ne $newHash) { throw 'Boot table readback mismatch.' }
        if (-not ([IO.File]::ReadAllText($bootScript)).Contains("`$expectedHash = '$newHash'")) { throw 'Boot script readback mismatch.' }
    }
} catch {
    foreach ($target in $written) {
        New-ItemProperty -LiteralPath $target.Key -Name $valueName -PropertyType Binary -Value $target.Bytes -Force | Out-Null
    }
    if ($bootManaged) {
        [IO.File]::WriteAllBytes($bootTable,$oldBootBytes)
        [IO.File]::WriteAllText($bootScript,$oldBootScript,[Text.UTF8Encoding]::new($false))
    }
    throw
}
Write-Host "Applied identical registry tables to $($targets.Count) present die(s). Backup: $backupFile"
if (-not $bootManaged) { Write-Warning 'No managed boot task was found; this tool did not create one. Reapply after new device installation if needed.' }
Write-Host 'The driver loads the new clocks after a Windows restart.'
if ($Restart) { Restart-Computer -Force }
