# DELTARUNE Online installer. Puts the mod in %LOCALAPPDATA%\DeltaruneOnline, copies your own DELTARUNE
# next to it and patches the copy. Your Steam copy and your normal save files are never changed.
# After this, start the game with the "DELTARUNE Online" shortcut: it installs mod updates by itself.
param([string]$GameDir = "")
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = if ($env:DRO_ROOT) { $env:DRO_ROOT } else { Join-Path $env:LOCALAPPDATA "DeltaruneOnline" }
$app = Join-Path $root "app"

Write-Host "DELTARUNE Online installer"
Write-Host "--------------------------"
if (-not (Test-Path (Join-Path $here "patcher\drm-patcher.exe"))) {
    Write-Host "PROBLEM: drm-patcher.exe is missing. Unzip the whole download first, then run Install.bat from the unzipped folder." -ForegroundColor Red
    exit 1
}
if ((Resolve-Path $here).Path.TrimEnd("\") -ne $app.TrimEnd("\")) {
    New-Item -ItemType Directory -Force $root | Out-Null
    & robocopy $here $app /MIR /NFL /NDL /NJH /NJS /NP /R:2 /W:2 /XF "Play DELTARUNE Online.bat" | Out-Null
    if ($LASTEXITCODE -ge 8) { Write-Host "PROBLEM: copying the mod to $app failed (robocopy code $LASTEXITCODE)." -ForegroundColor Red; exit 1 }
}
Copy-Item (Join-Path $app "launcher.ps1") (Join-Path $root "launcher.ps1") -Force

& (Join-Path $root "launcher.ps1") -Setup -NoLaunch -GameDir $GameDir
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Host ""
Write-Host "Done! Start the game with the 'DELTARUNE Online' shortcut on your desktop (or in the Start menu)." -ForegroundColor Green
Write-Host "It checks for mod updates every time it starts, so you never need to download this again."
Write-Host "You can delete this unzipped folder now."
