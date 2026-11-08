@echo off
rem Removes the patched copy of the game. The mod's own saves are kept unless you delete them yourself:
rem %LOCALAPPDATA%\DELTARUNE_ONLINE
setlocal
echo This deletes the patched copy in %LOCALAPPDATA%\DeltaruneOnline.
echo Your Steam copy and normal saves were never changed.
set /p "OK=Type YES to delete it: "
if /i not "%OK%"=="YES" goto :end
rmdir /s /q "%LOCALAPPDATA%\DeltaruneOnline"
del "%~dp0Play DELTARUNE Online.bat" 2>nul
del "%USERPROFILE%\Desktop\DELTARUNE Online.lnk" 2>nul
del "%APPDATA%\Microsoft\Windows\Start Menu\Programs\DELTARUNE Online.lnk" 2>nul
for /f "usebackq delims=" %%D in (`powershell -NoProfile -Command "[Environment]::GetFolderPath('Desktop')"`) do del "%%D\DELTARUNE Online.lnk" 2>nul
echo Done.
:end
pause
