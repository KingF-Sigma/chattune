# ChatTune installieren - ein Befehl in CMD reicht:
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/KingF-Sigma/chattune/main/Install.ps1 | iex"
# Installiert nur fuer deinen Windows-Benutzer (keine Adminrechte noetig). Nochmal ausfuehren = Update,
# deine Einstellungen, Statistik und Lyrics bleiben dabei erhalten.
# Deinstallieren: Windows-Einstellungen > Apps > ChatTune, oder Install.ps1 -Uninstall

# Kein param()-Block, damit es auch per 'irm | iex' laeuft
$Uninstall = $args -contains '-Uninstall'

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Download sonst sehr langsam
$appName    = 'ChatTune'
$repo       = 'KingF-Sigma/chattune'
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\ChatTune'
$desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ChatTune.lnk'
$startLnk   = Join-Path ([Environment]::GetFolderPath('Programs')) 'ChatTune.lnk'
$autoLnk    = Join-Path ([Environment]::GetFolderPath('Startup')) 'SpotifyToVRChat.lnk'
$uninstKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ChatTune'
# Diese Dateien gehoeren zum Programm; alles andere im Ordner (Einstellungen usw.) bleibt unangetastet
$runtime    = @('SpotifyToVRChat.ps1', 'worker.ps1', 'lang.ps1', 'MusicMic.cs', 'Start.bat', 'Panel.vbs', 'StartHidden.vbs', 'Install.ps1', 'ui', 'assets')

function Stop-ChatTune {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$installDir*SpotifyToVRChat.ps1*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

if ($Uninstall) {
    Add-Type -AssemblyName System.Windows.Forms
    $r = [System.Windows.Forms.MessageBox]::Show("ChatTune deinstallieren?`n`nDeine Einstellungen, Statistik und Lyrics werden dabei mit geloescht.", 'ChatTune', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    Stop-ChatTune; Start-Sleep -Milliseconds 500
    foreach ($l in $desktopLnk, $startLnk, $autoLnk) { if (Test-Path $l) { Remove-Item -LiteralPath $l -Force } }
    if (Test-Path $uninstKey) { Remove-Item -LiteralPath $uninstKey -Recurse -Force }
    # Sicherheitscheck: nur genau unseren Ordner loeschen
    if ((Test-Path $installDir) -and ((Split-Path $installDir -Leaf) -eq 'ChatTune')) {
        Set-Location $env:TEMP
        Remove-Item -LiteralPath $installDir -Recurse -Force
    }
    [void][System.Windows.Forms.MessageBox]::Show('ChatTune wurde entfernt.', 'ChatTune')
    return
}

Write-Host ''
Write-Host '  ChatTune wird installiert...' -ForegroundColor Green
$stage = Join-Path $env:TEMP ('ChatTune-Setup-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $zip = Join-Path $stage 'chattune.zip'
    Write-Host '  - Lade herunter'
    Invoke-WebRequest -Uri "https://github.com/$repo/archive/refs/heads/main.zip" -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force
    $src = Get-ChildItem $stage -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'SpotifyToVRChat.ps1') } | Select-Object -First 1
    if (-not $src) { throw 'Download unvollstaendig.' }

    Write-Host '  - Kopiere Dateien'
    Stop-ChatTune; Start-Sleep -Milliseconds 500   # laufende alte Version beenden
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    foreach ($name in $runtime) {
        $from = Join-Path $src.FullName $name
        if (Test-Path $from) { Copy-Item -LiteralPath $from -Destination $installDir -Recurse -Force }
    }
    # Aus dem Internet geladene Skripte freigeben, sonst fragt Windows bei jedem Start nach
    Get-ChildItem $installDir -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

    Write-Host '  - Lege Verknuepfungen an'
    $icon = Join-Path $installDir 'assets\app.ico'
    $shell = New-Object -ComObject WScript.Shell
    foreach ($path in $desktopLnk, $startLnk) {
        $l = $shell.CreateShortcut($path)
        $l.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
        $l.Arguments = '"{0}"' -f (Join-Path $installDir 'Panel.vbs')
        $l.WorkingDirectory = $installDir
        if (Test-Path $icon) { $l.IconLocation = "$icon,0" }
        $l.Description = 'Spotify in der VRChat-Chatbox'
        $l.Save()
    }

    # Eintrag unter Einstellungen > Apps (zum Deinstallieren)
    New-Item -Path $uninstKey -Force | Out-Null
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $props = @{
        DisplayName = $appName; DisplayVersion = '1.1.0'; Publisher = 'KingF-Sigma'; InstallLocation = $installDir
        DisplayIcon = $icon; URLInfoAbout = "https://github.com/$repo"; NoModify = 1; NoRepair = 1
        UninstallString = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $installDir 'Install.ps1')`" -Uninstall"
    }
    foreach ($k in $props.Keys) { Set-ItemProperty -Path $uninstKey -Name $k -Value $props[$k] }

    Write-Host ''
    Write-Host '  Fertig! ChatTune startet jetzt.' -ForegroundColor Green
    Write-Host '  Spaeter oeffnen: Desktop-Verknuepfung oder Startmenue > ChatTune'
    Write-Host ''
    Start-Process (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"{0}"' -f (Join-Path $installDir 'Panel.vbs'))
}
catch {
    Write-Host ''
    Write-Host "  Installation fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
