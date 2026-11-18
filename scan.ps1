<#
  scan.ps1 - rebuilds games.json from your stores, the NAS and manual.json.

  Run from this folder:
      powershell -ExecutionPolicy Bypass -File .\scan.ps1
      powershell -ExecutionPolicy Bypass -File .\scan.ps1 -Push    # also commit and push games.json

  Sources:
    Steam      full owned list via the Steam Web API (steamApiKey in config.local.json),
               otherwise installed games only
    Epic       owned list from the Epic launcher's local catalog cache, plus installed games
    GOG        installed games (registry)
    Launchers  installed games from other launchers, matched by publisher (config.json)
    NAS        folders and ROM collections listed in config.json
    Manual     everything in manual.json

  A source that can't be read this time (NAS offline, Steam API down) keeps its
  entries from the previous games.json instead of dropping them.
#>
param([switch]$Push)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Read-TextFile([string]$Path) { [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }
function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    Read-TextFile $Path | ConvertFrom-Json
}

$config = Read-JsonFile (Join-Path $root 'config.json')
if (-not $config) { throw 'config.json not found next to scan.ps1' }
$localConfig = Read-JsonFile (Join-Path $root 'config.local.json')
$previous = $null
try { $previous = Read-JsonFile (Join-Path $root 'games.json') } catch { Write-Warning 'Previous games.json could not be read; starting fresh.' }

$games = @{}                                        # title key -> game
$reports = New-Object System.Collections.ArrayList  # one per source, counted at the end

# ---------------------------------------------------------------- helpers

function Get-TitleKey([string]$Title) {
    $t = $Title.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', ''
    ($t.ToLowerInvariant() -replace '&', 'and') -replace '[^\p{L}\p{N}]', ''
}

function ConvertTo-CleanTitle([string]$Title) {
    if (-not $Title) { return '' }
    (($Title -replace '[\u2122\u00AE\u00A9]', '') -replace '\s{2,}', ' ').Trim()
}

$hiddenKeys = @{}
foreach ($t in @($config.hideTitles)) { if ($t) { $hiddenKeys[(Get-TitleKey $t)] = $true } }

function Add-Copy {
    param(
        [string]$Title,
        [System.Collections.IDictionary]$Copy,
        [string]$Image,
        [string]$SteamAppId
    )
    $clean = ConvertTo-CleanTitle $Title
    if (-not $clean) { return }
    $key = Get-TitleKey $clean
    if (-not $key) { $key = $clean.ToLowerInvariant() }
    if ($hiddenKeys.ContainsKey($key)) { return }

    $game = $games[$key]
    if (-not $game) {
        $game = [ordered]@{ title = $clean; copies = (New-Object System.Collections.ArrayList) }
        $games[$key] = $game
    } elseif ($game.title -ceq $game.title.ToLowerInvariant() -and $clean -cne $clean.ToLowerInvariant()) {
        $game.title = $clean   # prefer "Celeste" over "celeste"
    }
    if ($Image -and -not $game.Contains('img')) { $game['img'] = $Image }
    if ($SteamAppId -and -not $game.Contains('steam')) { $game['steam'] = [int]$SteamAppId }

    # One copy per store + platform + where; merge extra details into an existing one.
    $sig = '{0}|{1}|{2}' -f $Copy['store'], $Copy['platform'], $Copy['where']
    foreach ($existing in $game.copies) {
        if (('{0}|{1}|{2}' -f $existing['store'], $existing['platform'], $existing['where']) -eq $sig) {
            foreach ($k in @($Copy.Keys)) { if (-not $existing.Contains($k)) { $existing[$k] = $Copy[$k] } }
            return
        }
    }
    [void]$game.copies.Add($Copy)
}

function Restore-PreviousCopies([string]$Store, [string]$Where, [switch]$DropInstalled) {
    $count = 0
    if (-not $previous) { return 0 }
    foreach ($g in @($previous.games)) {
        foreach ($c in @($g.copies)) {
            if ($c.store -ne $Store) { continue }
            if ($Where -and $c.where -ne $Where) { continue }
            $copy = [ordered]@{}
            foreach ($p in $c.PSObject.Properties) { $copy[$p.Name] = $p.Value }
            if ($DropInstalled) { $copy.Remove('installed') }
            Add-Copy -Title $g.title -Copy $copy -Image $g.img -SteamAppId $g.steam
            $count++
        }
    }
    $count
}

function Add-Report([string]$Name, [string]$Store, [string]$Where, [string]$Note) {
    [void]$reports.Add([ordered]@{ name = $Name; store = $Store; where = $Where; note = $Note })
}

function Test-UnderAny([string]$Path, [string[]]$Roots) {
    if (-not $Path) { return $false }
    foreach ($r in $Roots) { if ($r -and $Path.StartsWith($r.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    $false
}

# ---------------------------------------------------------------- Steam

$steamLibraries = @()
$steamRoot = $null
try {
    $steamRoot = (Get-ItemProperty 'HKCU:\Software\Valve\Steam').SteamPath -replace '/', '\'
    $vdf = Read-TextFile (Join-Path $steamRoot 'steamapps\libraryfolders.vdf')
    $steamLibraries = @([regex]::Matches($vdf, '"path"\s+"([^"]+)"') | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' })
} catch { $steamRoot = $null }

if ($steamRoot) {
    $hideIds = @{}
    foreach ($id in @($config.steam.hideAppIds)) { $hideIds["$id"] = $true }

    $installed = @{}
    foreach ($lib in $steamLibraries) {
        $apps = Join-Path $lib 'steamapps'
        if (-not (Test-Path -LiteralPath $apps)) { continue }
        foreach ($m in Get-ChildItem -LiteralPath $apps -Filter 'appmanifest_*.acf') {
            $t = Read-TextFile $m.FullName
            $id = [regex]::Match($t, '"appid"\s+"(\d+)"').Groups[1].Value
            if (-not $id) { continue }
            $installed[$id] = @{
                name = [regex]::Match($t, '"name"\s+"([^"]+)"').Groups[1].Value
                path = Join-Path $apps ('common\' + [regex]::Match($t, '"installdir"\s+"([^"]+)"').Groups[1].Value)
            }
        }
    }

    $steamId = $null
    if ($localConfig -and $localConfig.steamId) { $steamId = "$($localConfig.steamId)" }
    if (-not $steamId) {
        $lu = Join-Path $steamRoot 'config\loginusers.vdf'
        if (Test-Path -LiteralPath $lu) {
            $m = [regex]::Match((Read-TextFile $lu), '"(\d{17})"\s*\{[^}]*?"MostRecent"\s+"1"')
            if ($m.Success) { $steamId = $m.Groups[1].Value }
        }
    }
    if (-not $steamId) {
        $ud = @(Get-ChildItem -LiteralPath (Join-Path $steamRoot 'userdata') -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d+$' -and $_.Name -ne '0' })
        if ($ud.Count -eq 1) { $steamId = ([int64]76561197960265728 + [int64]$ud[0].Name).ToString() }
    }

    $apiKey = $env:STEAM_API_KEY
    if ($localConfig -and $localConfig.steamApiKey) { $apiKey = "$($localConfig.steamApiKey)" }

    $owned = $null
    $note = $null
    if ($apiKey -and $steamId) {
        try {
            $url = 'https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/?key={0}&steamid={1}&include_appinfo=1&include_played_free_games=1&format=json' -f $apiKey, $steamId
            $resp = Invoke-RestMethod -Uri $url -UseBasicParsing -TimeoutSec 60
            $owned = @($resp.response.games | Where-Object { $_ })
            if ($owned.Count -eq 0) {
                $owned = $null
                $note = 'Steam returned no games. In Steam > Profile > Privacy, set Game details to Public'
            }
        } catch {
            $owned = $null
            $note = 'Steam API call failed: ' + ($_.Exception.Message -replace [regex]::Escape($apiKey), '***')
        }
    } elseif (-not $apiKey) {
        $note = 'Installed games only. Add steamApiKey to config.local.json for your full library'
    } else {
        $note = 'Could not work out your Steam ID. Add steamId to config.local.json'
    }

    $steamImage = 'https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps/{0}/header.jpg'
    $seen = @{}
    if ($owned) {
        foreach ($g in $owned) {
            $id = "$($g.appid)"
            if ($hideIds.ContainsKey($id)) { continue }
            $copy = [ordered]@{ store = 'Steam'; platform = 'PC' }
            if ($installed.ContainsKey($id)) { $copy['installed'] = $installed[$id].path }
            if ($g.playtime_forever -gt 0) { $copy['hours'] = [math]::Round($g.playtime_forever / 60, 1) }
            Add-Copy -Title $g.name -Copy $copy -Image ($steamImage -f $id) -SteamAppId $id
            $seen[$id] = $true
        }
    } elseif ($previous) {
        $n = Restore-PreviousCopies -Store 'Steam' -DropInstalled
        if ($n -gt 0 -and $apiKey) { $note += " (kept $n entries from the last scan)" }
    }
    foreach ($id in $installed.Keys) {
        if ($seen.ContainsKey($id) -or $hideIds.ContainsKey($id)) { continue }
        $copy = [ordered]@{ store = 'Steam'; platform = 'PC'; installed = $installed[$id].path }
        Add-Copy -Title $installed[$id].name -Copy $copy -Image ($steamImage -f $id) -SteamAppId $id
    }
    Add-Report -Name 'Steam' -Store 'Steam' -Note $note
}

# ---------------------------------------------------------------- Epic

$epicData = 'C:\ProgramData\Epic\EpicGamesLauncher\Data'
$epicInstalled = @{}
$epicDirs = @()
if (Test-Path -LiteralPath "$epicData\Manifests") {
    foreach ($f in Get-ChildItem -LiteralPath "$epicData\Manifests" -Filter '*.item') {
        try { $m = Read-JsonFile $f.FullName } catch { continue }
        if (@($m.AppCategories) -notcontains 'games') { continue }
        if ($m.MainGameCatalogItemId -and $m.MainGameCatalogItemId -ne $m.CatalogItemId) { continue }
        $epicInstalled[$m.CatalogItemId] = $m
        $epicDirs += $m.InstallLocation
    }
}

$epicCache = "$epicData\Catalog\catcache.bin"
if ((Test-Path -LiteralPath $epicCache) -or $epicInstalled.Count) {
    $note = $null
    $matched = @{}
    try {
        $raw = (Read-TextFile $epicCache).Trim()
        $items = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($raw)) | ConvertFrom-Json
        foreach ($it in $items) {
            $cats = @($it.categories | ForEach-Object { $_.path })
            if ($cats -notcontains 'games') { continue }
            if ($it.mainGameItem -and $it.mainGameItem.id) { continue }   # DLC
            $img = @($it.keyImages | Where-Object { $_.type -eq 'DieselGameBox' })[0].url
            if ($img) { $img += '?h=120&w=256&resize=1' }
            $copy = [ordered]@{ store = 'Epic'; platform = 'PC' }
            if ($epicInstalled.ContainsKey($it.id)) {
                $copy['installed'] = $epicInstalled[$it.id].InstallLocation
                $matched[$it.id] = $true
            }
            Add-Copy -Title $it.title -Copy $copy -Image $img
        }
    } catch {
        $note = 'Could not read the Epic library cache; open the Epic launcher once and rescan'
        $null = Restore-PreviousCopies -Store 'Epic' -DropInstalled
    }
    foreach ($id in $epicInstalled.Keys) {
        if ($matched.ContainsKey($id)) { continue }
        $m = $epicInstalled[$id]
        Add-Copy -Title $m.DisplayName -Copy ([ordered]@{ store = 'Epic'; platform = 'PC'; installed = $m.InstallLocation })
    }
    Add-Report -Name 'Epic' -Store 'Epic' -Note $note
}

# ---------------------------------------------------------------- GOG (installed)

$gogKey = 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games'
if (Test-Path $gogKey) {
    foreach ($k in Get-ChildItem $gogKey) {
        $p = Get-ItemProperty $k.PSPath
        if ($p.gameName) { Add-Copy -Title $p.gameName -Copy ([ordered]@{ store = 'GOG'; platform = 'PC'; installed = $p.path }) }
    }
    Add-Report -Name 'GOG' -Store 'GOG' -Note 'Installed games only'
}

# ---------------------------------------------------------------- Other launchers (installed)

$uninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$entries = foreach ($k in $uninstallKeys) { Get-ItemProperty -Path $k -ErrorAction SilentlyContinue }
$skipLaunchers = @{}
foreach ($n in @($config.launcherSkip)) { $skipLaunchers[(Get-TitleKey $n)] = $true }
$storeDirs = @($steamLibraries) + $epicDirs

foreach ($l in @($config.launchers)) {
    $found = 0
    foreach ($e in $entries) {
        if (-not $e.DisplayName -or -not $e.Publisher) { continue }
        if ($e.Publisher -notlike "*$($l.publisher)*") { continue }
        if ($skipLaunchers.ContainsKey((Get-TitleKey $e.DisplayName))) { continue }
        if (Test-UnderAny $e.InstallLocation $storeDirs) { continue }   # bought on Steam/Epic
        $copy = [ordered]@{ store = $l.store; platform = 'PC' }
        if ($e.InstallLocation) { $copy['installed'] = $e.InstallLocation.TrimEnd('\') } else { $copy['installed'] = $true }
        Add-Copy -Title $e.DisplayName -Copy $copy
        $found++
    }
    if ($found) { Add-Report -Name $l.store -Store $l.store -Note 'Installed games only' }
}

# ---------------------------------------------------------------- NAS

$skipNames = @{}
foreach ($n in @($config.skipNames)) { $skipNames[$n.ToLowerInvariant()] = $true }
$skipExt = @{}
foreach ($e in @($config.skipExtensions)) { $skipExt[$e.ToLowerInvariant()] = $true }
$stripNumbers = @{}
foreach ($n in @($config.romStripLeadingNumbers)) { $stripNumbers[$n] = $true }

function Test-SkipItem($Item) {
    $n = $Item.Name
    if ($n.StartsWith('.') -or $skipNames.ContainsKey($n.ToLowerInvariant())) { return $true }
    if (-not $Item.PSIsContainer -and $skipExt.ContainsKey($Item.Extension.ToLowerInvariant())) { return $true }
    $false
}

function ConvertTo-FolderTitle([string]$Name) {
    $t = $Name
    foreach ($p in @($config.stripPatterns)) { $t = $t -replace $p, '' }
    $t.Trim()
}

function ConvertTo-RomTitle([string]$Name, [bool]$StripNumbers) {
    $t = $Name -replace '_', ' '
    $t = $t -replace '\s*[\(\[][^\)\]]*[\)\]]', ''                    # (USA) [!] (Disc 1) [01007BB00FC8]
    $t = $t -replace '\s+(?:USA|EUR|JPN|NTSC|PAL)(?:\s+\S+)*$', ''      # scene names: "... NTSC PS2-Group"
    $t = $t -replace '\s+[A-Z]{4}\d{5}\b.*$', ''                        # disc serials: BLES00875
    $t = $t -replace '\s+v\d+(?:\.\d+)*\b.*$', ''                       # versions: "v1.2.0 v131072"
    if ($StripNumbers) { $t = $t -replace '^\d+\s+(?:-\s+)?', '' }     # "01 Hook", "0028 - Kirby"
    $t = $t -replace '^(.+?), The\b(.*)$', 'The $1$2'                  # "Legend of Zelda, The" -> "The Legend of Zelda"
    ($t -replace '\s{2,}', ' ').Trim([char[]]' -.')
}

foreach ($src in @($config.nas)) {
    $name = '{0} {1}s' -f $src.store, $src.where
    if (-not (Test-Path -LiteralPath $src.path)) {
        $n = Restore-PreviousCopies -Store $src.store -Where $src.where
        Add-Report -Name $name -Store $src.store -Where $src.where -Note "Not reachable at scan time; kept $n entries from the last scan"
        continue
    }
    if ($src.type -eq 'roms') {
        $skipFolders = @{}
        foreach ($s in @($src.skipFolders)) { $skipFolders[$s.ToLowerInvariant()] = $true }
        foreach ($dir in Get-ChildItem -LiteralPath $src.path -Directory) {
            if ($skipFolders.ContainsKey($dir.Name.ToLowerInvariant()) -or (Test-SkipItem $dir)) { continue }
            $platform = $config.romPlatforms.($dir.Name)
            if (-not $platform) { $platform = $dir.Name }
            foreach ($item in Get-ChildItem -LiteralPath $dir.FullName -Force) {
                if (Test-SkipItem $item) { continue }
                $base = if ($item.PSIsContainer) { $item.Name } else { [IO.Path]::GetFileNameWithoutExtension($item.Name) }
                $title = ConvertTo-RomTitle $base $stripNumbers.ContainsKey($dir.Name)
                Add-Copy -Title $title -Copy ([ordered]@{ store = $src.store; platform = $platform; where = $src.where; path = $item.FullName })
            }
        }
    } else {
        # Each folder or file (installer, archive) directly inside the path is one game.
        foreach ($item in Get-ChildItem -LiteralPath $src.path -Force) {
            if (Test-SkipItem $item) { continue }
            $base = if ($item.PSIsContainer) { $item.Name } else { [IO.Path]::GetFileNameWithoutExtension($item.Name) }
            $copy = [ordered]@{ store = $src.store; platform = $src.platform; where = $src.where; path = $item.FullName }
            Add-Copy -Title (ConvertTo-FolderTitle $base) -Copy $copy
        }
    }
    Add-Report -Name $name -Store $src.store -Where $src.where
}

# ---------------------------------------------------------------- Manual

$manual = Read-JsonFile (Join-Path $root 'manual.json')
$manualCount = 0
foreach ($m in @($manual.games)) {
    if (-not $m -or -not $m.title) { continue }
    $store = if ($m.store) { "$($m.store)" } else { 'Other' }
    $platform = if ($m.platform) { "$($m.platform)" } else { 'PC' }
    $copy = [ordered]@{ store = $store; platform = $platform }
    foreach ($f in 'where', 'installed', 'path', 'note') { if ($m.$f) { $copy[$f] = $m.$f } }
    Add-Copy -Title $m.title -Copy $copy -Image $m.img
    $manualCount++
}

# ---------------------------------------------------------------- write games.json

$sourcesOut = New-Object System.Collections.ArrayList
Write-Host ''
foreach ($r in $reports) {
    $count = 0
    foreach ($g in $games.Values) {
        foreach ($c in $g.copies) {
            if ($c['store'] -eq $r.store -and (-not $r.where -or $c['where'] -eq $r.where)) { $count++; break }
        }
    }
    if ($count -eq 0 -and $r.note -eq 'Installed games only') { continue }   # e.g. a launcher with nothing left after filtering
    $o = [ordered]@{ name = $r.name; count = $count }
    if ($r.note) { $o['note'] = $r.note }
    [void]$sourcesOut.Add($o)
    $line = '  {0,-18} {1,5}' -f $r.name, $count
    if ($r.note) { $line += "   $($r.note)" }
    Write-Host $line
}
if ($manualCount) {
    [void]$sourcesOut.Add([ordered]@{ name = 'manual.json'; count = $manualCount })
    Write-Host ('  {0,-18} {1,5}' -f 'manual.json', $manualCount)
}

$sorted = $games.GetEnumerator() | Sort-Object Name | ForEach-Object { $_.Value }
$lines = foreach ($g in $sorted) { ConvertTo-Json -InputObject $g -Depth 6 -Compress }
$head = ConvertTo-Json -InputObject ([ordered]@{ generated = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'); sources = $sourcesOut }) -Depth 6 -Compress
$text = $head.Substring(0, $head.Length - 1) + ",`n""games"":[`n" + ($lines -join ",`n") + "`n]}`n"
[IO.File]::WriteAllText((Join-Path $root 'games.json'), $text, $utf8NoBom)

$copyCount = ($games.Values | ForEach-Object { $_.copies.Count } | Measure-Object -Sum).Sum
Write-Host ''
Write-Host ("Wrote games.json: {0} games, {1} copies." -f $games.Count, $copyCount)

# ---------------------------------------------------------------- push

if ($Push) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Warning 'git is not installed, so nothing was pushed.'; return }
    Push-Location $root
    try {
        git add games.json
        git diff --cached --quiet
        if ($LASTEXITCODE -ne 0) {
            git commit -m ("Library scan {0}" -f (Get-Date -Format 'yyyy-MM-dd')) | Out-Null
            git push
            Write-Host 'Pushed games.json to GitHub.'
        } else {
            Write-Host 'No changes to push.'
        }
    } finally { Pop-Location }
}
