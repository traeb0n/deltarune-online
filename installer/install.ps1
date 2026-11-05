# DELTARUNE Online installer. Copies your own DELTARUNE to a separate folder and patches the copy.
# Your Steam copy and your normal save files are never changed. To uninstall, delete the folder.
param([string]$GameDir = "")
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dest = Join-Path $env:LOCALAPPDATA "DeltaruneOnline\game"
$patcher = Join-Path $here "patcher\drm-patcher.exe"
$mod = Join-Path $here "mod"

function Fail($text) {
    Write-Host ""
    Write-Host "PROBLEM: $text" -ForegroundColor Red
    exit 1
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

Write-Host "DELTARUNE Online installer"
Write-Host "--------------------------"
if (-not (Test-Path $patcher)) { Fail "drm-patcher.exe is missing. Unzip the whole download first, then run Install.bat from the unzipped folder." }
if ($GameDir -eq "") { $GameDir = Find-Game }
if (-not (Is-Game $GameDir)) {
    Write-Host "Couldn't find DELTARUNE automatically."
    $GameDir = Read-Host "Paste the path of your DELTARUNE folder (the one with DELTARUNE.exe in it)"
    $GameDir = $GameDir.Trim('"', ' ')
}
if (-not (Is-Game $GameDir)) { Fail "'$GameDir' isn't a DELTARUNE folder. It needs DELTARUNE.exe and chapter1_windows." }
Write-Host "Your game:     $GameDir"
Write-Host "Installing to: $dest"

$needGB = 1.2
$drive = (Get-Item $env:LOCALAPPDATA).PSDrive
if ($drive.Free -lt ($needGB * 1GB)) { Fail "Not enough disk space: it needs about $needGB GB free on drive $($drive.Name):." }

Write-Host ""
Write-Host "Copying the game (this leaves your Steam copy alone)..."
New-Item -ItemType Directory -Force $dest | Out-Null
& robocopy $GameDir $dest /MIR /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
if ($LASTEXITCODE -ge 8) { Fail "Copying the game failed (robocopy code $LASTEXITCODE). Is the game running? Close it and try again." }

# A separate game name keeps this mod's saves apart from your normal ones.
$env:DRM_SAVE_NAME = "DELTARUNE_ONLINE"
$failed = 0
$done = 0
foreach ($ch in 1..9) {
    $src = Join-Path $GameDir "chapter${ch}_windows\data.win"
    $out = Join-Path $dest "chapter${ch}_windows\data.win"
    if (-not (Test-Path $src)) { continue }
    Write-Host "Patching Chapter $ch..."
    $log = Join-Path $dest "patch_chapter$ch.log"
    & $patcher $src $out $mod "$ch" > $log 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Chapter $ch failed. Details: $log" -ForegroundColor Red
        Copy-Item $src $out -Force
        $failed++
    } else {
        $done++
    }
}
if ($done -eq 0) { Fail "No chapter could be patched. Your game may be a different version than this mod was made for." }

$play = Join-Path $here "Play DELTARUNE Online.bat"
Set-Content -Path $play -Encoding ASCII -Value "@echo off`r`ncd /d `"$dest`"`r`nstart `"`" `"$dest\DELTARUNE.exe`"`r`n"

Write-Host ""
if ($failed -gt 0) {
    Write-Host "Done, but $failed chapter(s) failed and will play without multiplayer." -ForegroundColor Yellow
} else {
    Write-Host "Done! All $done chapters are ready." -ForegroundColor Green
}
Write-Host "Start the game with 'Play DELTARUNE Online.bat' in this folder, then press F9 in game."
Write-Host "Everyone playing together must use the same version of this mod and of DELTARUNE."
