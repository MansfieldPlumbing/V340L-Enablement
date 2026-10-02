function Invoke-V340Tui {
    param([object[]]$InitialTargets,[int[]]$CoreOffsets,[int[]]$MemoryOffsets)
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        throw 'The TUI needs a terminal. Use V340L.cmd or -Mode Status for text output.'
    }
    $targets = $InitialTargets
    $presets = @('VeryLow','Low','Quiet','Balanced','Fast')
    $selected = 2
    $focus = 0
    $kind = 'none'
    $customCore = 0
    $customMemory = 0
    $status = 'Tab changes focus. Stage a preset or a custom ceiling, then press A.'
    $lastWidth = -1
    $lastHeight = -1
    $dirty = $true
    $oldCursor = [Console]::CursorVisible
    $oldControl = [Console]::TreatControlCAsInput
    [Console]::Write("`e[?1049h`e[?25l`e[2J")
    [Console]::CursorVisible = $false
    [Console]::TreatControlCAsInput = $true
    try {
        while ($true) {
            $w = [Math]::Max(1,[Console]::WindowWidth-1)
            $h = [Math]::Max(1,[Console]::WindowHeight)
            if ($w -ne $lastWidth -or $h -ne $lastHeight) { $dirty = $true; $lastWidth = $w; $lastHeight = $h }
            if ($dirty) {
                $lines = [Collections.Generic.List[object]]::new()
                $lines.Add(@('bar',(' V340L  POWERPLAY 8.1  |  '+$targets.Count+' present die(s)')))
                if ($w -lt 58 -or $h -lt 14) {
                    $lines.Add(@('error',' Enlarge the window to at least 59 x 14 cells.'))
                    $lines.Add(@('text'," Current: $w x $h"))
                    $lines.Add(@('text',' F5 refresh   Esc exit'))
                } else {
                    $lines.Add(@('accent',' Registry SPPT editor | one profile for every present die'))
                    if ($targets.Count -eq 0) { $lines.Add(@('error',' No present V340L device. F5 refreshes discovery.')) }
                    else {
                        foreach ($target in $targets) {
                            $part = $target.InstanceId.Split('\')[-1]
                            $lines.Add(@('text'," $part   $($target.Key.Split('\')[-1])"))
                        }
                        if ($null -ne $targets[0].Bytes) {
                            $lines.Add(@('bar',' P-state      Core MHz      Memory MHz      Voltage'))
                            for ($i=0; $i -lt 8; $i++) {
                                $c = Get-Clock $targets[0].Bytes $CoreOffsets[$i]
                                $m = if ($i -lt 4) { [string](Get-Clock $targets[0].Bytes $MemoryOffsets[$i]) } else { '-' }
                                $lines.Add(@('text',(' P{0,-2}         {1,-6}        {2,-6}          unchanged' -f $i,$c,$m)))
                            }
                        } else { $lines.Add(@('error',' No SPPT override on first die; editing needs a verified table.')) }
                    }
                    $lines.Add(@('text',''))
                    $lines.Add(@($(if($focus -eq 0){'selected'}else{'accent'})," PRESETS: 1 Floor  2 VeryLow  3 Low  4 Quiet  5 Balanced  6 Fast"))
                    $lines.Add(@($(if($focus -eq 1){'selected'}else{'text'})," CORE:   $(if($customCore){$customCore}else{'current'}) MHz max   | C edit"))
                    $lines.Add(@($(if($focus -eq 2){'selected'}else{'text'})," MEMORY: $(if($customMemory){$customMemory}else{'current'}) MHz max   | M edit"))
                    $lines.Add(@($(if($focus -eq 3){'selected'}else{'text'})," ACTIONS: A Apply   S Save profile   F5 Refresh   Esc Exit"))
                    $lines.Add(@('value'," Staged: $kind $(if($kind -eq 'preset'){$presets[$selected]}else{''})"))
                }
                while ($lines.Count -gt $h-2) { $lines.RemoveAt($lines.Count-1) }
                while ($lines.Count -lt $h-2) { $lines.Add(@('text','')) }
                $lines.Add(@('bar',' Tab focus   Up/Down choose   Enter edit/select   A apply'))
                $lines.Add(@('value',(' '+$status)))
                $colors = @{text='48;2;12;43;106;38;2;230;230;230';accent='48;2;12;43;106;38;2;120;220;255';bar='48;2;192;192;192;38;2;0;0;0';selected='48;2;230;230;230;38;2;0;0;0';value='48;2;12;43;106;38;2;255;255;85';error='48;2;12;43;106;38;2;255;90;90'}
                $frame = [Text.StringBuilder]::new("`e[H")
                for ($i=0; $i -lt [Math]::Min($h,$lines.Count); $i++) {
                    $line = $lines[$i]
                    $safe = ([string]$line[1] -replace '[\x00-\x1F\x7F]',' ')
                    [void]$frame.Append("`e[$($colors[$line[0]])m"+$safe.PadRight($w).Substring(0,$w)+$(if($i -lt $h-1){"`r`n"}else{''}))
                }
                [Console]::Write($frame.ToString())
                $dirty = $false
            }
            if (-not [Console]::KeyAvailable) { Start-Sleep -Milliseconds 120; continue }
            $key = [Console]::ReadKey($true)
            $dirty = $true
            if ($key.Key -in @('Escape','Q')) { return $null }
            if ($key.Key -eq 'Tab') { $focus = ($focus+1)%4; continue }
            if ($key.Key -eq 'F5') {
                $targets = @(Get-Targets)
                $status = "Refreshed: $($targets.Count) present die(s)."
                continue
            }
            if ($key.Key -in @('UpArrow','DownArrow') -and $focus -eq 0) {
                $selected = [Math]::Clamp($selected+$(if($key.Key -eq 'DownArrow'){1}else{-1}),0,4)
                $kind = 'preset'
                continue
            }
            if ($key.KeyChar -in @('1','2','3','4','5','6')) {
                if ($key.KeyChar -eq '1') { $kind='floor' }
                else { $selected=[int]::Parse([string]$key.KeyChar)-2; $kind='preset' }
                $status='Profile staged; A applies it to every present die.'
                continue
            }
            if ($key.Key -eq 'Enter' -and $focus -eq 0) { $kind='preset'; $status='Preset staged.'; continue }
            if ($key.KeyChar -in @('c','C','m','M') -or ($key.Key -eq 'Enter' -and $focus -in @(1,2))) {
                $domain = if($key.KeyChar -in @('m','M') -or $focus -eq 2){'Memory'}else{'Core'}
                [Console]::Write("`e[H`e[2J`e[0m$domain maximum MHz (Enter to accept): `e[?25h")
                $entry = [Console]::ReadLine()
                [Console]::Write("`e[?25l`e[2J")
                $number = 0
                if ([int]::TryParse($entry,[ref]$number)) {
                    if ($domain -eq 'Core' -and $number -ge 300 -and $number -le 1500) { $customCore=$number; $kind='custom'; $status="Core max $number MHz staged." }
                    elseif ($domain -eq 'Memory' -and $number -ge 167 -and $number -le 945) { $customMemory=$number; $kind='custom'; $status="Memory max $number MHz staged." }
                    else { $status='Value outside allowed range.' }
                } else { $status='No numeric value entered.' }
                continue
            }
            if ($key.KeyChar -in @('s','S')) {
                $folder = Join-Path $PSScriptRoot 'output\powerplay'
                [IO.Directory]::CreateDirectory($folder) | Out-Null
                $path = Join-Path $folder ('staged-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'.json')
                [pscustomobject]@{Mode=$kind;Preset=$presets[$selected];CoreMaxMHz=$customCore;MemoryMaxMHz=$customMemory;SavedUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $path
                $status="Saved $path"
                continue
            }
            if ($key.KeyChar -in @('a','A') -or ($key.Key -eq 'Enter' -and $focus -eq 3)) {
                if ($kind -eq 'none') { $status='Choose a preset or enter a custom ceiling first.'; continue }
                if ($kind -eq 'floor') { return [pscustomobject]@{Mode='Floor';Preset=$presets[$selected];CoreMaxMHz=0;MemoryMaxMHz=0} }
                if ($kind -eq 'preset') { return [pscustomobject]@{Mode='Preset';Preset=$presets[$selected];CoreMaxMHz=0;MemoryMaxMHz=0} }
                return [pscustomobject]@{Mode='Status';Preset=$presets[$selected];CoreMaxMHz=$customCore;MemoryMaxMHz=$customMemory}
            }
        }
    } finally {
        [Console]::Write("`e[0m`e[?25h`e[?1049l")
        [Console]::CursorVisible = $oldCursor
        [Console]::TreatControlCAsInput = $oldControl
    }
}
