param(
    [ValidateSet('Install', 'Restore')][string]$Action = 'Install',
    [string]$GamePath,
    [switch]$NonInteractive
)
$ErrorActionPreference = 'Stop'
$binaryText = [Text.Encoding]::GetEncoding(28591)
$marker = "`r`n// BEGIN GMOD_DARK_LOADING_V1`r`ncl_enable_loadingurl 0`r`n// END GMOD_DARK_LOADING_V1`r`n"

function Find-Game([string]$Path) {
    if (-not $Path) { return $null }
    $Path = $Path.Trim().Trim('"')
    foreach ($candidate in @($Path, (Join-Path $Path 'garrysmod'))) {
        if ((Test-Path -LiteralPath (Join-Path $candidate 'html\loading.html') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $candidate 'cfg') -PathType Container) -and
            (Test-Path -LiteralPath (Join-Path $candidate 'lua') -PathType Container)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Discover-Games {
    $roots = @()
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        $props = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($props.SteamPath) { $roots += $props.SteamPath }
        if ($props.InstallPath) { $roots += $props.InstallPath }
    }
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if ($base) { $roots += Join-Path $base 'Steam' }
    }
    $libraries = @($roots)
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem)) {
        if ($drive.Root -match '^[A-Za-z]:\\$') {
            foreach ($folder in @('SteamLibrary', 'Steam', 'Program Files (x86)\Steam', 'Program Files\Steam')) {
                $candidate = Join-Path $drive.Root $folder
                if (Test-Path -LiteralPath (Join-Path $candidate 'steamapps')) { $libraries += $candidate }
            }
        }
    }
    foreach ($root in ($roots | Select-Object -Unique)) {
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($match in [regex]::Matches([IO.File]::ReadAllText($vdf), '"path"\s+"([^"\r\n]+)"')) {
                $libraries += $match.Groups[1].Value.Replace('\\', '\')
            }
        }
    }
    $found = @()
    foreach ($library in ($libraries | Select-Object -Unique)) {
        $steamapps = Join-Path $library 'steamapps'
        $manifest = Join-Path $steamapps 'appmanifest_4000.acf'
        $name = 'GarrysMod'
        if (Test-Path -LiteralPath $manifest) {
            $match = [regex]::Match([IO.File]::ReadAllText($manifest), '"installdir"\s+"([^"\r\n]+)"')
            if ($match.Success) { $name = $match.Groups[1].Value }
        }
        $game = Find-Game (Join-Path (Join-Path $steamapps 'common') $name)
        if ($game) { $found += $game }
    }
    return @($found | Select-Object -Unique)
}

function Read-BinaryText([string]$Path) {
    if (Test-Path -LiteralPath $Path) { return $binaryText.GetString([IO.File]::ReadAllBytes($Path)) }
    return ''
}
function Write-BinaryText([string]$Path, [string]$Text) {
    [IO.File]::WriteAllBytes($Path, $binaryText.GetBytes($Text))
}
function Hash([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))).Replace('-', '') }
    finally { $sha.Dispose() }
}
function Save-State($State, [string]$Path) {
    [IO.File]::WriteAllText($Path, ($State | ConvertTo-Json), [Text.Encoding]::UTF8)
}

function Install-ServerTheme {
    $cssPath = Join-Path $game 'html\css\menu\Servers.css'
    $theme = Read-BinaryText (Join-Path $PSScriptRoot 'payload\server-dark.css')
    if (-not $theme.Contains('END GMOD_DARK_SERVER_LIST_V2')) { throw 'Missing server theme payload.' }
    if (-not (Test-Path -LiteralPath $cssPath)) { throw 'Server list CSS was not found.' }
    $themeStateFile = Join-Path $backup 'server-theme-state.json'
    $themeBackup = Join-Path $backup 'Servers.original.css'
    $currentCss = Read-BinaryText $cssPath
    $themeState = $null
    if (Test-Path -LiteralPath $themeStateFile) { $themeState = [IO.File]::ReadAllText($themeStateFile) | ConvertFrom-Json }
    if ($themeState -and $themeState.Active) {
        if ($themeState.GamePath -ne $game) { throw 'Server theme backup belongs to another game.' }
        if ($currentCss.Contains($theme)) { return }
        if ($themeState.Block -and $currentCss.Contains($themeState.Block)) {
            $currentCss = $currentCss.Replace($themeState.Block, '')
        }
        if ($currentCss.Contains('BEGIN GMOD_DARK_SERVER_LIST_V2')) { throw 'Server theme block was edited. Restore it before reinstalling.' }
    } else {
        if ($currentCss.Contains('BEGIN GMOD_DARK_SERVER_LIST_V2')) { throw 'Server theme marker exists without active backup. No CSS changed.' }
        if ((Test-Path -LiteralPath $themeBackup) -and -not $themeState) { throw 'Unknown server theme backup exists. Preserve it before continuing.' }
        Copy-Item -LiteralPath $cssPath -Destination $themeBackup -Force
        $themeState = [pscustomobject]@{ GamePath = $game; Active = $true; InstalledHash = ''; OriginalHash = Hash $cssPath; Block = $theme }
        Save-State $themeState $themeStateFile
    }
    Write-BinaryText $cssPath ($currentCss + $theme)
    $themeState.Block = $theme
    $themeState.InstalledHash = Hash $cssPath
    Save-State $themeState $themeStateFile
}

function Restore-ServerTheme {
    $themeStateFile = Join-Path $backup 'server-theme-state.json'
    if (-not (Test-Path -LiteralPath $themeStateFile)) { return }
    $themeState = [IO.File]::ReadAllText($themeStateFile) | ConvertFrom-Json
    if (-not $themeState.Active) { return }
    if ($themeState.GamePath -ne $game) { throw 'Server theme backup belongs to another game.' }
    $cssPath = Join-Path $game 'html\css\menu\Servers.css'
    $themeBackup = Join-Path $backup 'Servers.original.css'
    if (-not (Test-Path -LiteralPath $themeBackup) -or (Hash $themeBackup) -ne $themeState.OriginalHash) { throw 'Server theme backup is missing or damaged.' }
    if (-not (Test-Path -LiteralPath $cssPath)) { throw 'Current server list CSS is missing.' }
    $currentCss = Read-BinaryText $cssPath
    if ($currentCss.Contains($themeState.Block)) {
        Write-BinaryText $cssPath ($currentCss.Replace($themeState.Block, ''))
    } elseif ($currentCss.Contains('BEGIN GMOD_DARK_SERVER_LIST_V2')) {
        throw 'Server theme block was edited. Remove its BEGIN/END block manually and run Restore again.'
    }
    # If an update already removed the block, keep the updated CSS.
    $themeState.Active = $false
    Save-State $themeState $themeStateFile
}

. (Join-Path $PSScriptRoot 'NativeTheme.ps1')

try {
    if (Get-Process -Name 'gmod', 'hl2', 'gmod_win64', 'hl2_win64' -ErrorAction SilentlyContinue) {
        throw 'Close Garry''s Mod before installing or restoring.'
    }
    if ($GamePath) {
        $game = Find-Game $GamePath
        if (-not $game) { throw 'Invalid game folder. Select the GarrysMod folder or its garrysmod subfolder.' }
    } else {
        $games = @(Discover-Games)
        if ($games.Count -eq 1) { $game = $games[0] }
        elseif ($NonInteractive) { throw 'Use -GamePath to specify a game folder.' }
        else {
            foreach ($entry in $games) { Write-Host "Found: $entry" }
            Write-Host 'Steam > Garry''s Mod > Manage > Browse local files.'
            $game = Find-Game (Read-Host 'Paste that folder path here')
            if (-not $game) { throw 'No valid Garry''s Mod folder was selected.' }
        }
    }
    Write-Host "Game: $game"
    $loading = Join-Path $game 'html\loading.html'
    $autoexec = Join-Path $game 'cfg\autoexec.cfg'
    $config = Join-Path $game 'cfg\config.cfg'
    $backup = Join-Path $game 'dark_loading_backup_v1'
    $stateFile = Join-Path $backup 'state.json'
    $state = $null
    if (Test-Path -LiteralPath $stateFile) {
        $state = [IO.File]::ReadAllText($stateFile) | ConvertFrom-Json
        if ($state.GamePath -ne $game) { throw 'Backup belongs to another game folder. No files changed.' }
    }

    if ($Action -eq 'Install') {
        if (-not (Test-Path -LiteralPath (Join-Path $game 'resource\SourceScheme.res'))) { throw 'Native menu theme was not found. No files changed.' }
        if (-not (Test-Path -LiteralPath (Join-Path $game 'html\css\menu\Servers.css'))) { throw 'Server list CSS was not found. No files changed.' }
        $payload = Join-Path $PSScriptRoot 'payload\loading.html'
        if (-not (Test-Path -LiteralPath $payload)) { throw 'Missing payload. Extract the entire ZIP first.' }
        $payloadHash = Hash $payload
        if ($state -and $state.Active) {
            if ((Hash $loading) -ne $state.OriginalHash -and (Hash $loading) -ne $state.InstalledHash) {
                throw 'Loading page has changed since installation. Preserve your changes before restoring/reinstalling.'
            }
            $current = Read-BinaryText $autoexec
            if (-not $current.Contains($marker) -and $current.Contains('BEGIN GMOD_DARK_LOADING_V1')) {
                throw 'Managed configuration was edited. Restore it before reinstalling.'
            }
            Copy-Item -LiteralPath $payload -Destination $loading -Force
            if (-not $current.Contains($marker)) {
                Write-BinaryText $autoexec ($current + $marker)
            }
            $state.InstalledHash = $payloadHash
            Save-State $state $stateFile
        } else {
            if ((Read-BinaryText $autoexec).Contains('BEGIN GMOD_DARK_LOADING_V1')) {
                throw 'A previous configuration block exists without an active backup. No files changed.'
            }
            if ((Test-Path -LiteralPath $backup) -and -not $state) {
                throw 'Backup folder already exists without valid state. Preserve it before continuing.'
            }
            New-Item -ItemType Directory -Path $backup -Force | Out-Null
            Copy-Item -LiteralPath $loading -Destination (Join-Path $backup 'loading.original') -Force
            $autoExisted = Test-Path -LiteralPath $autoexec
            if ($autoExisted) { Copy-Item -LiteralPath $autoexec -Destination (Join-Path $backup 'autoexec.original') -Force }
            $configText = Read-BinaryText $config
            $matches = [regex]::Matches($configText, '(?im)^\s*cl_enable_loadingurl\s+"?([01])"?[^\r\n]*')
            $previous = '1'
            if ($matches.Count) { $previous = $matches[$matches.Count - 1].Groups[1].Value }
            $state = [pscustomobject]@{
                GamePath = $game; Active = $true; AutoExisted = [bool]$autoExisted
                OriginalHash = Hash $loading; InstalledHash = $payloadHash
                PreviousLoadingURL = $previous; InstalledAutoHash = ''
            }
            # Save recovery data before modifying game files.
            Save-State $state $stateFile
            try {
                Copy-Item -LiteralPath $payload -Destination $loading -Force
                Write-BinaryText $autoexec ((Read-BinaryText $autoexec) + $marker)
                $state.InstalledAutoHash = Hash $autoexec
                Save-State $state $stateFile
            } catch {
                Copy-Item -LiteralPath (Join-Path $backup 'loading.original') -Destination $loading -Force
                if ($autoExisted) {
                    Copy-Item -LiteralPath (Join-Path $backup 'autoexec.original') -Destination $autoexec -Force
                } elseif (Test-Path -LiteralPath $autoexec) {
                    Remove-Item -LiteralPath $autoexec
                }
                $state.Active = $false
                Save-State $state $stateFile
                throw
            }
        }
        Install-ServerTheme
        Install-NativeTheme
        Write-Host 'Installed V2.2: dark loading, server list, footer AND native dialogs. Restart GMod.' -ForegroundColor Green
        Write-Host "Backup: $backup"
    } else {
        if (-not $state -or -not $state.Active) { throw 'No active installation backup was found.' }
        $original = Join-Path $backup 'loading.original'
        if (-not (Test-Path -LiteralPath $original) -or (Hash $original) -ne $state.OriginalHash) {
            throw 'Loading page backup is missing or damaged. No files changed.'
        }
        if ($state.AutoExisted -and -not (Test-Path -LiteralPath (Join-Path $backup 'autoexec.original'))) {
            throw 'Original autoexec backup is missing. No files changed.'
        }
        $current = Read-BinaryText $autoexec
        if ($current.Contains('BEGIN GMOD_DARK_LOADING_V1') -and -not $current.Contains($marker)) {
            throw 'Managed configuration was edited. Remove its BEGIN/END block manually before restoring.'
        }
        $currentHash = Hash $loading
        if ($currentHash -ne $state.InstalledHash -and $currentHash -ne $state.OriginalHash) {
            $preserved = Join-Path $backup ('loading.before-restore.' + [Guid]::NewGuid().ToString('N') + '.html')
            Copy-Item -LiteralPath $loading -Destination $preserved
            Write-Host "Preserved changed loading page: $preserved"
        }
        Copy-Item -LiteralPath $original -Destination $loading -Force
        if (Test-Path -LiteralPath $autoexec) {
            if ($state.InstalledAutoHash -and (Hash $autoexec) -eq $state.InstalledAutoHash) {
                if ($state.AutoExisted) {
                    Copy-Item -LiteralPath (Join-Path $backup 'autoexec.original') -Destination $autoexec -Force
                } else { Remove-Item -LiteralPath $autoexec }
            } elseif ($current.Contains($marker)) {
                Write-BinaryText $autoexec ($current.Replace($marker, ''))
            }
        }
        # GMod can persist this convar in config.cfg after it has run.
        if (Test-Path -LiteralPath $config) {
            Copy-Item -LiteralPath $config -Destination (Join-Path $backup ('config.before-restore.' + [Guid]::NewGuid().ToString('N') + '.cfg'))
            $text = Read-BinaryText $config
            $pattern = '(?im)^(\s*cl_enable_loadingurl\s+)"?[01]"?([^\r\n]*)'
            if ([regex]::IsMatch($text, $pattern)) {
                $replacement = '${1}"' + $state.PreviousLoadingURL + '"${2}'
                Write-BinaryText $config ([regex]::Replace($text, $pattern, $replacement))
            }
        }
        Restore-ServerTheme
        Restore-NativeTheme
        $state.Active = $false
        Save-State $state $stateFile
        Write-Host 'Restored. Backup files have been kept.' -ForegroundColor Green
    }
    exit 0
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'If access is denied, run the BAT as administrator after reviewing Setup.ps1.'
    exit 1
}
