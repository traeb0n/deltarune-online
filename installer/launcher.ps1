# DELTARUNE Online launcher.
# Every start: looks in the shared update folder for a newer version of the mod, installs it,
# re-patches the game copy when the mod or the Steam game changed, then starts the game.
# Your Steam copy and normal saves are never changed.
param(
    [switch]$Setup,           # first install (run by Install.bat)
    [string]$GameDir = "",    # the Steam DELTARUNE folder, if it can't be found automatically
    [switch]$NoLaunch,        # update and patch, but don't start the game
    [switch]$NoUpdate         # skip the online check
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$root = if ($env:DRO_ROOT) { $env:DRO_ROOT } else { Join-Path $env:LOCALAPPDATA "DeltaruneOnline" }
$app = Join-Path $root "app"
$game = Join-Path $root "game"
$stateFile = Join-Path $root "state.txt"
$self = Join-Path $root "launcher.ps1"
Set-Location $root
$Host.UI.RawUI.WindowTitle = "DELTARUNE Online"

function Say($text, $color = "Gray") { Write-Host $text -ForegroundColor $color }

function Stop-WithProblem($text) {
    Write-Host ""
    Write-Host "PROBLEM: $text" -ForegroundColor Red
    Write-Host ""
    try { Read-Host "Press Enter to close" | Out-Null } catch { }
    exit 1
}

function Read-State {
    $s = @{}
    if (Test-Path $stateFile) {
        foreach ($line in Get-Content $stateFile) {
            $i = $line.IndexOf("=")
            if ($i -gt 0) { $s[$line.Substring(0, $i)] = $line.Substring($i + 1) }
        }
    }
    return $s
}

function Write-State($s) {
    $lines = foreach ($k in $s.Keys) { "$k=$($s[$k])" }
    Set-Content -Path $stateFile -Value $lines -Encoding UTF8
}

function Get-AppVersion {
    $f = Join-Path $app "version.txt"
    if (Test-Path $f) { return [int](Get-Content $f -Raw).Trim() }
    return 0
}

function Is-Game($dir) {
    return $dir -and (Test-Path (Join-Path $dir "chapter1_windows\data.win")) -and (Test-Path (Join-Path $dir "DELTARUNE.exe"))
}

# Steam can keep games on any drive: its library list says where.
function Find-Game {
    $roots = New-Object System.Collections.ArrayList
    foreach ($key in "HKCU:\Software\Valve\Steam", "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam", "HKLM:\SOFTWARE\Valve\Steam") {
        try {
            $p = Get-ItemProperty -Path $key -ErrorAction Stop
            if ($p.SteamPath) { [void]$roots.Add($p.SteamPath) }
            if ($p.InstallPath) { [void]$roots.Add($p.InstallPath) }
        } catch { }
    }
    [void]$roots.Add("${env:ProgramFiles(x86)}\Steam")
    foreach ($r in @($roots)) {
        $vdf = Join-Path $r "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                [void]$roots.Add($m.Groups[1].Value.Replace("\\", "\"))
            }
        }
    }
    foreach ($r in $roots) {
        $d = Join-Path $r "steamapps\common\DELTARUNE"
        if (Is-Game $d) { return $d }
    }
    return ""
}

# Changes whenever Steam updates the game.
function Get-GameStamp($dir) {
    $parts = foreach ($f in @("DELTARUNE.exe") + (1..9 | ForEach-Object { "chapter${_}_windows\data.win" })) {
        $p = Join-Path $dir $f
        if (Test-Path $p) { $i = Get-Item $p; "${f}:$($i.Length):$($i.LastWriteTimeUtc.Ticks)" }
    }
    return ($parts -join "|")
}

function Get-GameProcess {
    return @(Get-Process -Name DELTARUNE -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and $_.Path.StartsWith($game, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
    })
}

# ---------- updates ----------

# update.txt holds the shared Google Drive folder link (or a local folder, for testing).
function Get-Feed {
    $f = Join-Path $app "update.txt"
    if (-not (Test-Path $f)) { return $null }
    foreach ($line in Get-Content $f) {
        $l = $line.Trim()
        if ($l -eq "" -or $l.StartsWith("#")) { continue }
        return $l
    }
    return $null
}

# Returns the files in the update folder: @{ Name; Version; Id or Path }
function Get-Releases($feed) {
    $list = @()
    if (Test-Path $feed -ErrorAction SilentlyContinue) {
        foreach ($z in Get-ChildItem $feed -Filter "DeltaruneOnline-v*.zip") {
            if ($z.Name -match '^DeltaruneOnline-v(\d+)\.zip$') {
                $list += @{ Name = $z.Name; Version = [int]$Matches[1]; Path = $z.FullName }
            }
        }
        return $list
    }
    $m = [regex]::Match($feed, '(?:folders/|[?&]id=)([\w-]{10,})')
    if (-not $m.Success) { throw "update.txt doesn't hold a Google Drive folder link" }
    $id = $m.Groups[1].Value
    # A public folder's file list, no sign-in needed.
    $html = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 "https://drive.google.com/embeddedfolderview?id=$id").Content
    $entries = [regex]::Matches($html, 'id="entry-([\w-]+)"')
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $start = $entries[$i].Index
        $end = if ($i + 1 -lt $entries.Count) { $entries[$i + 1].Index } else { $html.Length }
        $chunk = $html.Substring($start, $end - $start)
        $t = [regex]::Match($chunk, 'flip-entry-title">([^<]+)<')
        if ($t.Success) {
            $name = [Net.WebUtility]::HtmlDecode($t.Groups[1].Value).Trim()
            if ($name -match '^DeltaruneOnline-v(\d+)\.zip$') {
                $list += @{ Name = $name; Version = [int]$Matches[1]; Id = $entries[$i].Groups[1].Value }
            }
        }
    }
    return $list
}

# Like Expand-Archive, but retries a file an antivirus is still scanning instead of giving up.
function Expand-Zip($zip, $dest) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        foreach ($e in $z.Entries) {
            $out = [IO.Path]::GetFullPath((Join-Path $dest $e.FullName))
            if (-not $out.StartsWith([IO.Path]::GetFullPath($dest))) { throw "bad path in zip: $($e.FullName)" }
            if ($e.FullName.EndsWith("/") -or $e.FullName.EndsWith("\")) { New-Item -ItemType Directory -Force $out | Out-Null; continue }
            New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
            for ($try = 1; ; $try++) {
                try { [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true); break }
                catch { if ($try -ge 20) { throw }; Start-Sleep -Milliseconds 500 }
            }
        }
    } finally { $z.Dispose() }
}

function Test-Zip($path) {
    $b = New-Object byte[] 2
    $fs = [IO.File]::OpenRead($path)
    try { [void]$fs.Read($b, 0, 2) } finally { $fs.Close() }
    return ($b[0] -eq 0x50 -and $b[1] -eq 0x4B)   # "PK"
}

function Get-Release($rel, $out) {
    if ($rel.Path) { Copy-Item $rel.Path $out -Force; return }
    $wc = New-Object Net.WebClient
    $wc.DownloadFile("https://drive.usercontent.google.com/download?id=$($rel.Id)&export=download&confirm=t", $out)
    if (Test-Zip $out) { return }
    # Big files get a "can't scan for viruses" page first: submit its form to get the file.
    $page = Get-Content $out -Raw
    $form = [regex]::Match($page, '<form[^>]*id="download-form"[^>]*action="([^"]+)"')
    if (-not $form.Success) { throw "Google Drive didn't send the file (is the folder shared as 'Anyone with the link'?)" }
    $q = foreach ($inp in [regex]::Matches($page, '<input type="hidden" name="([^"]+)" value="([^"]*)"')) {
        "$($inp.Groups[1].Value)=$([Uri]::EscapeDataString([Net.WebUtility]::HtmlDecode($inp.Groups[2].Value)))"
    }
    $wc.DownloadFile([Net.WebUtility]::HtmlDecode($form.Groups[1].Value) + "?" + ($q -join "&"), $out)
    if (-not (Test-Zip $out)) { throw "Google Drive sent a web page instead of the update" }
}

# Returns $true when a newer version was installed.
function Update-App {
    $feed = Get-Feed
    if (-not $feed) { return $false }
    $have = Get-AppVersion
    Say "Checking for updates..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $newest = Get-Releases $feed | Sort-Object { $_.Version } | Select-Object -Last 1
    } catch {
        Say "  Couldn't check ($($_.Exception.Message.Split([char]10)[0].Trim())). Starting the version you have." "Yellow"
        return $false
    }
    if (-not $newest -or $newest.Version -le $have) { Say "  Up to date (version $have)."; return $false }
    if (Get-GameProcess) { Say "  Version $($newest.Version) is out, but the game is running. Close it and start again to update." "Yellow"; return $false }

    Say "  Version $($newest.Version) is out (you have $have). Downloading..." "Cyan"
    $zip = Join-Path $root "download.zip"
    $staging = Join-Path $root "staging"
    try {
        Get-Release $newest $zip
        if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
        Expand-Zip $zip $staging
        $ver = Get-ChildItem $staging -Recurse -Filter version.txt | Select-Object -First 1
        if (-not $ver -or -not (Test-Path (Join-Path $ver.DirectoryName "patcher\drm-patcher.exe"))) { throw "the download is missing files" }
        $old = Join-Path $root "app.old"
        if (Test-Path $old) { Remove-Item $old -Recurse -Force }
        if (Test-Path $app) { Rename-Item $app "app.old" }
        Move-Item $ver.DirectoryName $app
        if (Test-Path $old) { Remove-Item $old -Recurse -Force -ErrorAction SilentlyContinue }
    } catch {
        Say "  Update failed: $($_.Exception.Message.Split([char]10)[0].Trim())" "Red"
        Say "  Starting the version you have."
        $old = Join-Path $root "app.old"
        if (-not (Test-Path $app) -and (Test-Path $old)) { Rename-Item $old "app" }
        return $false
    } finally {
        Remove-Item $zip, $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    Say "  Updated to version $(Get-AppVersion)." "Green"
    return $true
}

# ---------- patching ----------

function Update-GameCopy($gameDir) {
    if (Get-GameProcess) { Stop-WithProblem "The game is running. Close DELTARUNE Online and start it again." }
    $patcher = Join-Path $app "patcher\drm-patcher.exe"
    $mod = Join-Path $app "mod"
    if (-not (Test-Path $patcher)) { Stop-WithProblem "drm-patcher.exe is missing. Your antivirus may have removed it: restore it or reinstall." }
    $drive = (Get-Item $root).PSDrive
    if (-not (Test-Path $game) -and $drive.Free -lt 1.2GB) { Stop-WithProblem "Not enough disk space: it needs about 1.2 GB free on drive $($drive.Name):." }

    Say ""
    Say "Copying the game (your Steam copy is left alone)..."
    New-Item -ItemType Directory -Force $game | Out-Null
    & robocopy $gameDir $game /MIR /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
    if ($LASTEXITCODE -ge 8) { Stop-WithProblem "Copying the game failed (robocopy code $LASTEXITCODE). Is the game running? Close it and try again." }

    # A separate game name keeps this mod's saves apart from your normal ones.
    $env:DRM_SAVE_NAME = "DELTARUNE_ONLINE"
    $failed = 0
    $done = 0
    foreach ($ch in 1..9) {
        $src = Join-Path $gameDir "chapter${ch}_windows\data.win"
        $out = Join-Path $game "chapter${ch}_windows\data.win"
        if (-not (Test-Path $src)) { continue }
        Say "Patching Chapter $ch..."
        $log = Join-Path $root "patch_chapter$ch.log"
        $code = 0
        try {
            & $patcher $src $out $mod "$ch" > $log 2>&1
            $code = $LASTEXITCODE
        } catch {
            Copy-Item $src $out -Force
            Stop-WithProblem "Windows or your antivirus wouldn't let the patcher start ($($_.Exception.Message.Split([char]10)[0].Trim())).`nAllow '$patcher' in your antivirus (or restore it from quarantine), then start again."
        }
        if ($code -ne 0) {
            Say "  Chapter $ch failed. Details: $log" "Red"
            Copy-Item $src $out -Force
            $failed++
        } else {
            $done++
        }
    }
    if ($done -eq 0) { Stop-WithProblem "No chapter could be patched. Your game may be a different version than this mod was made for." }
    if ($failed -gt 0) {
        Say "$failed chapter(s) failed and will play without multiplayer." "Yellow"
        Start-Sleep -Seconds 4
    } else {
        Say "All $done chapters are ready." "Green"
    }
}

function New-Shortcuts($gameDir) {
    $sh = New-Object -ComObject WScript.Shell
    $menu = Join-Path ([Environment]::GetFolderPath("Programs")) "DELTARUNE Online.lnk"
    $desk = Join-Path ([Environment]::GetFolderPath("Desktop")) "DELTARUNE Online.lnk"
    foreach ($p in $desk, $menu) {
        $l = $sh.CreateShortcut($p)
        $l.TargetPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        $l.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$self`""
        $l.WorkingDirectory = $root
        $l.IconLocation = "$(Join-Path $gameDir 'DELTARUNE.exe'),0"
        $l.Description = "Play DELTARUNE online with friends (checks for mod updates first)"
        $l.Save()
    }
}

# ---------- main ----------

Say "DELTARUNE Online" "White"
Say "----------------"
$state = Read-State

if ($GameDir -eq "") { $GameDir = $state["gamedir"] }
if (-not (Is-Game $GameDir)) { $GameDir = Find-Game }
if (-not (Is-Game $GameDir)) {
    Say "Couldn't find DELTARUNE automatically."
    $GameDir = (Read-Host "Paste the path of your DELTARUNE folder (the one with DELTARUNE.exe in it)").Trim('"', ' ')
}
if (-not (Is-Game $GameDir)) { Stop-WithProblem "'$GameDir' isn't a DELTARUNE folder. It needs DELTARUNE.exe and chapter1_windows." }
$state["gamedir"] = $GameDir

if (-not $NoUpdate -and -not $Setup) {
    if (Update-App) {
        # The new version may come with a new launcher: run that one.
        $new = Join-Path $app "launcher.ps1"
        if ((Test-Path $new) -and ((Get-FileHash $new).Hash -ne (Get-FileHash $self).Hash)) {
            Copy-Item $new $self -Force
            Write-State $state
            $a = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $self, "-NoUpdate")
            if ($NoLaunch) { $a += "-NoLaunch" }
            & powershell.exe @a
            exit $LASTEXITCODE
        }
    }
}

$version = Get-AppVersion
$stamp = Get-GameStamp $GameDir
$exe = Join-Path $game "DELTARUNE.exe"
if ($state["patched"] -ne "$version" -or $state["gamestamp"] -ne $stamp -or -not (Test-Path $exe)) {
    if ($state["gamestamp"] -and $state["gamestamp"] -ne $stamp -and $state["patched"] -eq "$version") { Say "DELTARUNE itself was updated on Steam: patching it again." "Cyan" }
    Update-GameCopy $GameDir
    $state["patched"] = "$version"
    $state["gamestamp"] = $stamp
}
Write-State $state
if ($Setup -and -not $env:DRO_ROOT) { New-Shortcuts $GameDir }   # DRO_ROOT = test install: leave the desktop alone

if ($NoLaunch) { exit 0 }
if (Get-GameProcess) { Say "The game is already running."; Start-Sleep -Seconds 2; exit 0 }
Say ""
Say "Starting DELTARUNE Online (version $version)..." "Green"
Start-Process -FilePath $exe -WorkingDirectory $game
Start-Sleep -Seconds 2
