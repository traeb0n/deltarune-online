# Rebuilds the patcher and patches chapters from the vanilla Steam files into work\game,
# using a separate game name so the copy doesn't use the real save folder.
# Usage: build_test_copy.ps1 [-Chapters 1,2,3,4,5] [-SaveName DELTARUNE_MP_TEST]
param(
    [int[]]$Chapters = @(1, 2, 3, 4, 5),
    [string]$SaveName = "DELTARUNE_MP_TEST"
)
$root = if ($env:DRO_DEV_ROOT) { $env:DRO_DEV_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }   # the folder above mod-src
$steam = "C:\Program Files (x86)\Steam\steamapps\common\DELTARUNE"
$env:DOTNET_ROOT = "$root\tools\dotnet10"
$env:DOTNET_CLI_HOME = "$root\tools\dotnet_home"
$env:NUGET_PACKAGES = "$root\tools\nuget"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:DOTNET_NOLOGO = "1"
$env:DRM_SAVE_NAME = $SaveName

& "$root\tools\dotnet10\dotnet.exe" build "$root\mod-src\patcher\DRMPatcher.csproj" -c Release "-p:UTMTRoot=$root\tools\src\UndertaleModTool" -o "$root\mod-src\patcher\bin\out" -v q -nologo | Select-Object -Last 4
if ($LASTEXITCODE -ne 0) { "patcher build failed"; exit 1 }

$patcher = "$root\mod-src\patcher\bin\out\drm-patcher.exe"
foreach ($ch in $Chapters) {
    $source = "$steam\chapter${ch}_windows\data.win"
    $target = "$root\work\game\chapter${ch}_windows\data.win"
    $log = "$root\work\patch_ch$ch.log"
    & $patcher $source $target "$root\mod-src\mod" "$ch" > $log
    "Chapter $ch exit=$LASTEXITCODE size=$((Get-Item $target).Length)"
    Get-Content $log | Select-String -Pattern 'game name|ERROR|Compile errors' | ForEach-Object { "   $($_.Line.Trim())" }
}
