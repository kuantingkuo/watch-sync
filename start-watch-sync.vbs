' ==============================================================================
' Watch-Sync Silent Background Launcher
' Launches watch-sync-tray.ps1 in the background without a console window.
' ==============================================================================
Option Explicit
Dim FSO, WshShell, BaseDir, ScriptPath

Set FSO = CreateObject("Scripting.FileSystemObject")
Set WshShell = CreateObject("WScript.Shell")

BaseDir = FSO.GetParentFolderName(WScript.ScriptFullName)
ScriptPath = FSO.BuildPath(BaseDir, "watch-sync-tray.ps1")

WshShell.Run "pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & ScriptPath & """", 0, False
