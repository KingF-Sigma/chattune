param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$appName = 'Spotify Chatbox for VRChat'
$installDir = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'VRChatSpotify'
$dataDir = Join-Path $env:LOCALAPPDATA 'VRChatSpotify'
$desktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Spotify Chatbox.lnk'
$programsDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'Spotify Chatbox'
$startLink = Join-Path $programsDir 'Spotify Chatbox.lnk'
$uninstallKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\VRChatSpotify'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if (-not $PSCommandPath) { throw 'Speichere Install.ps1 zuerst als Datei, damit Windows Administratorrechte anfordern kann.' }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"{1}' -f $PSCommandPath, $(if ($Uninstall) { ' -Uninstall' } else { '' })
    $process = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -Wait -PassThru -ArgumentList $arguments
    exit $process.ExitCode
}

if ($Uninstall) {
    Add-Type -AssemblyName System.Windows.Forms
    $choice = [System.Windows.Forms.MessageBox]::Show(
        "Spotify Chatbox entfernen? Deine Einstellungen und Lyrics unter $dataDir bleiben erhalten.",
        'Spotify Chatbox deinstallieren', 'YesNo', 'Question')
    if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }

    foreach ($link in $desktopLink, $startLink) { if (Test-Path $link) { Remove-Item -LiteralPath $link -Force } }
    if (Test-Path $programsDir) { Remove-Item -LiteralPath $programsDir -Force }
    if (Test-Path $uninstallKey) { Remove-Item -LiteralPath $uninstallKey -Recurse -Force }
    if (Test-Path $installDir) {
        $resolvedInstallDir = [System.IO.Path]::GetFullPath($installDir).TrimEnd('\')
        $expectedInstallDir = [System.IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'VRChatSpotify')).TrimEnd('\')
        if ($resolvedInstallDir -ne $expectedInstallDir) { throw "Unerwarteter Installationspfad: $resolvedInstallDir" }
        Remove-Item -LiteralPath $resolvedInstallDir -Recurse -Force
    }
    Write-Output "Spotify Chatbox wurde entfernt. Deine Nutzerdaten bleiben in $dataDir."
    exit 0
}

if (-not $PSCommandPath) { throw 'Bitte Install.ps1 als Datei starten, nicht direkt mit Invoke-Expression.' }
$stageDir = Join-Path $env:TEMP ('VRChatSpotify-Setup-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stageDir | Out-Null
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $archive = Join-Path $stageDir 'source.zip'
    $sourceUrl = 'https://github.com/KingF-Sigma/vrchat-spotify-chatbox/archive/refs/heads/main.zip'
    Invoke-WebRequest -Uri $sourceUrl -OutFile $archive -UseBasicParsing
    Expand-Archive -LiteralPath $archive -DestinationPath $stageDir -Force
    $sourceDir = Join-Path $stageDir 'vrchat-spotify-chatbox-main'
    if (-not (Test-Path (Join-Path $sourceDir 'SpotifyToVRChat.ps1'))) { throw 'Das heruntergeladene Projekt ist unvollständig.' }

    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    $currentSettings = Join-Path $dataDir 'settings.json'
    if (-not (Test-Path $currentSettings)) {
        foreach ($name in @('settings.json', 'profiles.json', 'verlauf.txt', 'statistik.json', 'lyrics', 'cache')) {
            $legacy = Join-Path $installDir $name
            if ((Test-Path $legacy) -and -not (Test-Path (Join-Path $dataDir $name))) {
                Copy-Item -LiteralPath $legacy -Destination $dataDir -Recurse -Force
            }
        }
    }
    $runtimeFiles = @('SpotifyToVRChat.ps1', 'worker.ps1', 'lang.ps1', 'MusicMic.cs', 'Start.bat', 'Panel.vbs', 'StartHidden.vbs', 'ui', 'assets')
    foreach ($name in $runtimeFiles) {
        $source = Join-Path $sourceDir $name
        if (-not (Test-Path $source)) { throw "Installationsdatei fehlt: $name" }
        Copy-Item -LiteralPath $source -Destination $installDir -Recurse -Force
    }

    $iconPath = Join-Path $installDir 'assets\app.ico'
    $launcher = Join-Path $installDir 'Panel.vbs'
    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($startLink)) -Force | Out-Null
    foreach ($path in $desktopLink, $startLink) {
        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
        $shortcut.TargetPath = $wscript
        $shortcut.Arguments = '"{0}"' -f $launcher
        $shortcut.WorkingDirectory = $installDir
        $shortcut.IconLocation = '{0},0' -f $iconPath
        $shortcut.Description = $appName
        $shortcut.Save()
    }

    New-Item -Path $uninstallKey -Force | Out-Null
    Set-ItemProperty -Path $uninstallKey -Name DisplayName -Value $appName
    Set-ItemProperty -Path $uninstallKey -Name DisplayVersion -Value '1.0.0'
    Set-ItemProperty -Path $uninstallKey -Name Publisher -Value 'VRChatSpotify'
    Set-ItemProperty -Path $uninstallKey -Name InstallLocation -Value $installDir
    Set-ItemProperty -Path $uninstallKey -Name DisplayIcon -Value $iconPath
    Set-ItemProperty -Path $uninstallKey -Name UninstallString -Value ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -Uninstall' -f (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'), (Join-Path $installDir 'Install.ps1'))
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $installDir 'Install.ps1') -Force

    Write-Output 'Installation abgeschlossen.'
    Write-Output "Programm: $installDir"
    Write-Output 'Verknüpfungen: Desktop und Startmenü'
    Write-Output "Einstellungen und Lyrics: $dataDir"
    Write-Output 'Du kannst Spotify Chatbox jetzt über die Desktop-Verknüpfung öffnen.'
}
finally {
    if (Test-Path $stageDir) { Remove-Item -LiteralPath $stageDir -Recurse -Force }
}
