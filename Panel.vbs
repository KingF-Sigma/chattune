' Startet Spotify -> VRChat unsichtbar und oeffnet das Panel (laeuft es schon, wird nur das Panel geoeffnet)
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\SpotifyToVRChat.ps1"" -ShowPanel", 0, False
