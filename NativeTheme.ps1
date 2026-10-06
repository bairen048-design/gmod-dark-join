function Install-NativeTheme {
    $schemePath = Join-Path $game 'resource\SourceScheme.res'
    $nativeStateFile = Join-Path $backup 'native-theme-state.json'
    $nativeBackup = Join-Path $backup 'SourceScheme.original.res'
    $nativeState = $null
    if (Test-Path -LiteralPath $nativeStateFile) { $nativeState = [IO.File]::ReadAllText($nativeStateFile) | ConvertFrom-Json }
    if ($nativeState -and $nativeState.Active) {
        if ($nativeState.GamePath -ne $game) { throw 'Native theme backup belongs to another game.' }
        if ((Hash $schemePath) -eq $nativeState.InstalledHash) { return }
        throw 'Native menu theme changed since installation. Restore before reinstalling.'
    }
    if ((Test-Path -LiteralPath $nativeBackup) -and -not $nativeState) { throw 'Unknown native theme backup exists.' }
    $palette = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'payload\native-colors.json')) | ConvertFrom-Json
    $text = Read-BinaryText $schemePath
    $changes = New-Object 'System.Collections.Generic.List[object]'
    foreach ($property in $palette.PSObject.Properties) {
        $key = [regex]::Escape($property.Name)
        $pattern = '(?m)^(\s*"?' + $key + '"?\s+)"([^"\r\n]*)"([^\r\n]*)'
        $matches = [regex]::Matches($text, $pattern)
        if (-not $matches.Count) { throw "Native theme setting not found: $($property.Name). No native theme changed." }
        foreach ($match in $matches) {
            $before = $match.Value
            $after = $match.Groups[1].Value + '"' + $property.Value + '"' + $match.Groups[3].Value
            if ($before -ne $after) {
                $changes.Add([pscustomobject]@{ Before = $before; After = $after })
                $text = $text.Replace($before, $after)
            }
        }
    }
    Copy-Item -LiteralPath $schemePath -Destination $nativeBackup -Force
    $nativeState = [pscustomobject]@{ GamePath = $game; Active = $true; OriginalHash = Hash $schemePath; InstalledHash = ''; Changes = @($changes.ToArray()) }
    Save-State $nativeState $nativeStateFile
    Write-BinaryText $schemePath $text
    $nativeState.InstalledHash = Hash $schemePath
    Save-State $nativeState $nativeStateFile
}

function Restore-NativeTheme {
    $nativeStateFile = Join-Path $backup 'native-theme-state.json'
    if (-not (Test-Path -LiteralPath $nativeStateFile)) { return }
    $nativeState = [IO.File]::ReadAllText($nativeStateFile) | ConvertFrom-Json
    if (-not $nativeState.Active) { return }
    if ($nativeState.GamePath -ne $game) { throw 'Native theme backup belongs to another game.' }
    $schemePath = Join-Path $game 'resource\SourceScheme.res'
    $nativeBackup = Join-Path $backup 'SourceScheme.original.res'
    if (-not (Test-Path -LiteralPath $nativeBackup) -or (Hash $nativeBackup) -ne $nativeState.OriginalHash) { throw 'Native theme backup missing or damaged.' }
    if ((Hash $schemePath) -eq $nativeState.InstalledHash) {
        Copy-Item -LiteralPath $nativeBackup -Destination $schemePath -Force
    } else {
        Copy-Item -LiteralPath $schemePath -Destination (Join-Path $backup ('SourceScheme.before-restore.' + [Guid]::NewGuid().ToString('N') + '.res'))
        $text = Read-BinaryText $schemePath
        foreach ($change in $nativeState.Changes) { $text = $text.Replace($change.After, $change.Before) }
        Write-BinaryText $schemePath $text
    }
    $nativeState.Active = $false
    Save-State $nativeState $nativeStateFile
}
