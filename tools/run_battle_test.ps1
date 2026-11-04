# Two patched game instances on this PC, bots playing one battle in each chapter.
#   sync run: enemies have 8x HP, per-turn state compared between the two games
#   win run:  enemies have 1 HP, checks both games leave the battle without a Game Over
# Rooms and encounters come from the mod's tools/regress.sh. Windows are resized from outside
# because changing fullscreen inside the game writes to the player's real settings.
# Usage: run_battle_test.ps1 [-Chapters 1,2,3,4,5] [-SyncSeconds 100] [-WinSeconds 60]
param(
    [int[]]$Chapters = @(1, 2, 3, 4, 5),
    [string[]]$Modes = @("sync", "win"),
    [int]$SyncSeconds = 100,
    [int]$WinSeconds = 60,
    [int]$ClientChar = 2
)
$root = if ($env:DRO_DEV_ROOT) { $env:DRO_DEV_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }   # the folder above mod-src
$game = "$root\work\game"
$results = "$root\work\test"
$rooms = @{ 1 = "room_field1"; 2 = "room_dw_cyber_maze_virokun"; 3 = "room_dw_couch_overworld_02"; 4 = "room_dw_church_worshiproom"; 5 = "room_dw_garden_intro" }
$encs = @{ 1 = 13; 2 = 53; 3 = 110; 4 = 150; 5 = 200 }

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct RECT { public int L, T, R, B; }
public static class W {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
}
"@
[void][W]::SetProcessDPIAware()
$TOP = [IntPtr](-1); $NOTOP = [IntPtr](-2)
$SHOW = [uint32]0x0040; $NOMOVESIZE = [uint32]0x0003

function Start-Instance($dir, $out, $name, $extra, $tokens) {
    $a = @("-game", "data.win") + $extra + @("-mptest", $tokens, "-output", "`"$out\$name.log`"", "-debugoutput", "`"$out\$name.debug.log`"")
    Start-Process -FilePath "$game\DELTARUNE.exe" -WorkingDirectory $dir -ArgumentList $a -PassThru
}

function Place($proc, $x) {
    $proc.Refresh()
    if ($proc.MainWindowHandle -ne 0) { [void][W]::SetWindowPos($proc.MainWindowHandle, $NOTOP, $x, 40, 1000, 750, $SHOW) }
}

function Snap($proc, $path) {
    $proc.Refresh()
    if ($proc.HasExited -or $proc.MainWindowHandle -eq 0) { return "no window (exited=$($proc.HasExited))" }
    [void][W]::SetWindowPos($proc.MainWindowHandle, $TOP, 0, 0, 0, 0, $NOMOVESIZE)
    Start-Sleep -Milliseconds 250
    $r = New-Object RECT
    [void][W]::GetWindowRect($proc.MainWindowHandle, [ref]$r)
    $bmp = New-Object System.Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    [void][W]::SetWindowPos($proc.MainWindowHandle, $NOTOP, 0, 0, 0, 0, $NOMOVESIZE)
    return "ok"
}

function Turns($path) {
    $d = @{}
    if (Test-Path $path) {
        foreach ($line in [IO.File]::ReadAllLines($path)) {
            if ($line.StartsWith("[MPLOG]")) { $d[$line.Split(" ")[1]] = $line.Trim() }
        }
    }
    return $d
}

function Run-Test($ch, $mode, $seconds) {
    $dir = "$game\chapter${ch}_windows"
    $out = "$results\ch$ch\$mode"
    New-Item -ItemType Directory -Force $out | Out-Null
    Remove-Item "$out\*" -Force -ErrorAction SilentlyContinue
    $strength = if ($mode -eq "win") { "weak,watchplot" } else { "tough,watchplot" }
    $tok = "party,room:$($rooms[$ch]),plot:100,bot,botrand,log,$strength"
    # spectate run: the second player stands still and goes down while the host keeps dodging.
    $clientTok = if ($mode -eq "spectate") { "$tok,nododge,revive:150" } else { $tok }
    $hostTok = if ($mode -eq "spectate") { "$tok,immortal" } else { $tok }
    $h = Start-Instance $dir $out "host" @("-mphost", "-mpname", "Host", "-mpchar", "1") "$hostTok,battle:$($encs[$ch])"
    Start-Sleep -Seconds 4
    $c = Start-Instance $dir $out "client" @("-mpjoin", "127.0.0.1", "-mpname", "P2", "-mpchar", "$ClientChar") $clientTok
    Start-Sleep -Seconds 4
    Place $h 10; Place $c 1030
    $elapsed = 8
    $shots = @([int]($seconds / 3), [int]($seconds * 2 / 3), $seconds)
    if ($mode -eq "spectate") { $shots = @(); for ($s = 20; $s -le $seconds; $s += 4) { $shots += $s } }
    $snapState = ""
    foreach ($t in $shots) {
        Start-Sleep -Seconds ([math]::Max(0, $t - $elapsed))
        $elapsed = $t
        Place $h 10; Place $c 1030
        $snapState = "host " + (Snap $h "$out\host_$t.png") + ", client " + (Snap $c "$out\client_$t.png")
    }
    $h.Refresh(); $c.Refresh()
    $early = "hostExited=$($h.HasExited) clientExited=$($c.HasExited)"
    foreach ($p in @($h, $c)) { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$game\*" } | Stop-Process -Force
    Start-Sleep -Seconds 2

    $ht = Turns "$out\host.log"; $ct = Turns "$out\client.log"
    $shared = @($ht.Keys | Where-Object { $ct.ContainsKey($_) })
    $diff = @($shared | Where-Object { $ht[$_] -ne $ct[$_] })
    $text = (Get-Content "$out\host.log", "$out\client.log" -ErrorAction SilentlyContinue) -join "`n"
    $crash = ([regex]::Matches($text, '(?i)MPCRASH|FATAL ERROR|SCENE-IN-BATTLE')).Count
    $joined = $text -match 'Joined the session'
    $over = $text -match 'room_gameover'
    "ch$ch $mode : joined=$joined turns host=$($ht.Count) client=$($ct.Count) shared=$($shared.Count) mismatched=$($diff.Count) crashLines=$crash gameOver=$over $early shots[$snapState]"
    foreach ($n in "host", "client") {
        $w = Select-String -Path "$out\$n.log" -Pattern '\[watch\]' -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($w) { "   $n last watch: " + ($w.Line -replace '^.*\[watch\] ', '').Substring(0, [math]::Min(90, ($w.Line -replace '^.*\[watch\] ', '').Length)) }
    }
    foreach ($k in $diff | Select-Object -First 3) { "   host  : $($ht[$k])"; "   client: $($ct[$k])" }
}

foreach ($ch in $Chapters) {
    # The chapters stream music from mus\ relative to the working directory (see mod tools/mkgamedir.sh).
    $link = "$game\chapter${ch}_windows\mus"
    if (-not (Test-Path $link)) { [void](New-Item -ItemType Junction -Path $link -Target "$game\mus") }
    if ($Modes -contains "sync") { Run-Test $ch "sync" $SyncSeconds }
    if ($Modes -contains "win") { Run-Test $ch "win" $WinSeconds }
    if ($Modes -contains "spectate") { Run-Test $ch "spectate" $SyncSeconds }
}

"--- save folder vs baseline ---"
$s = "$env:LOCALAPPDATA\DELTARUNE"
$base = Import-Csv "$root\backups\saves_baseline.csv"
$now = Get-ChildItem $s -Recurse -File | ForEach-Object { [pscustomobject]@{ Path = $_.FullName.Substring($s.Length); Hash = (Get-FileHash $_.FullName).Hash } }
$cmp = Compare-Object $base $now -Property Path, Hash
if ($cmp) { $cmp | ForEach-Object { "$($_.SideIndicator) $($_.Path)" } } else { "no differences" }
