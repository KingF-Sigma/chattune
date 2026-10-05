# Hintergrund-Thread: fragt Spotify/VRChat ab, baut den Chatbox-Text und sendet ihn per OSC.
# Laeuft in einem eigenen Runspace, damit das Panel nie haengt. Austausch ueber $sync.

$cfg = $sync.Cfg

$lastError = @{ Msg = $null; At = [DateTime]::MinValue }
function Log-Error([string]$msg) {
    # Derselbe Fehler hoechstens einmal pro Minute, sonst ist das Log sofort voll
    if ($msg -eq $lastError.Msg -and ((Get-Date) - $lastError.At).TotalSeconds -lt 60) { return }
    $lastError.Msg = $msg; $lastError.At = Get-Date
    [void]$sync.Errors.Add("$(Get-Date -Format HH:mm:ss)  $msg")
    while ($sync.Errors.Count -gt 100) { $sync.Errors.RemoveAt(0) }
    $sync.ErrorVersion++
}

function E([int]$codepoint) { [char]::ConvertFromUtf32($codepoint) }

# Die wenigen Woerter, die direkt in der Chatbox stehen, in der App-Sprache
function L([string]$de, [string]$en) { if ($sync.Lang -eq 'de') { $de } else { $en } }
$emoji = @{
    Pause = E 0x23F8; Clock = E 0x1F552; Afk = E 0x1F4A4; Disc = E 0x1F4BF; Mic = E 0x1F3A4
    Timer = E 0x23F1; Globe = E 0x1F30D; Translate = E 0x1F310; Check = E 0x2705
}
$playIcons = @((E 0x1F3B5), (E 0x1F3A7), (E 0x266A), "")

# Kapitaelchen a-z (VRChat kann diese Zeichen darstellen, Fett/Kursiv-Unicode dagegen nicht)
$smallCaps = @(0x1D00, 0x299, 0x1D04, 0x1D05, 0x1D07, 0xA730, 0x262, 0x29C, 0x26A, 0x1D0A, 0x1D0B, 0x29F, 0x1D0D,
               0x274, 0x1D0F, 0x1D18, 0x1EB, 0x280, 0x73, 0x1D1B, 0x1D1C, 0x1D20, 0x1D21, 0x78, 0x28F, 0x1D22) | ForEach-Object { [char]$_ }
function To-SmallCaps([string]$s) {
    -join ($s.ToLower().ToCharArray() | ForEach-Object { if ($_ -ge 'a' -and $_ -le 'z') { $smallCaps[[int]$_ - 97] } else { $_ } })
}

# Hochgestellte Mini-Schrift (q gibt es nicht hochgestellt)
$superLetters = @(0x1D43, 0x1D47, 0x1D9C, 0x1D48, 0x1D49, 0x1DA0, 0x1D4D, 0x2B0, 0x2071, 0x2B2, 0x1D4F, 0x2E1, 0x1D50,
                  0x207F, 0x1D52, 0x1D56, 0x71, 0x2B3, 0x2E2, 0x1D57, 0x1D58, 0x1D5B, 0x2B7, 0x2E3, 0x2B8, 0x1DBB) | ForEach-Object { E $_ }
$superDigits = @(0x2070, 0xB9, 0xB2, 0xB3, 0x2074, 0x2075, 0x2076, 0x2077, 0x2078, 0x2079) | ForEach-Object { E $_ }
function To-Super([string]$s) {
    -join ($s.ToLower().ToCharArray() | ForEach-Object {
        if ($_ -ge 'a' -and $_ -le 'z') { $superLetters[[int]$_ - 97] }
        elseif ($_ -ge '0' -and $_ -le '9') { $superDigits[[int]$_ - 48] }
        else { [string]$_ }
    })
}

# Balken-Stile: gefuellt, Position (leer = keine), leer
$barStyles = @(
    @((E 0x25AC), (E 0x25CF), (E 0x25AC)),
    @((E 0x2501), (E 0x25C9), (E 0x2500)),
    @((E 0x2593), "",         (E 0x2591)),
    @((E 0x25A0), "",         (E 0x25A1)),
    @((E 0x2665), "",         (E 0x2661))
)

# ---------------- Windows-Mediensteuerung ----------------
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
function Await($op, [Type]$type) {
    $task = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
    # Nie ewig warten: haengt der Player, soll nicht das ganze Tool stehen bleiben
    if (-not $task.Wait(5000)) { throw "Windows-Mediensteuerung antwortet nicht" }
    $task.Result
}
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
$null = [Windows.Media.MediaPlaybackAutoRepeatMode, Windows.Media, ContentType = WindowsRuntime]
$manager = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) `
                 ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])

$browserPattern = 'chrome|msedge|firefox|opera|brave|vivaldi|arc'
function Get-MediaSession {
    $sessions = @($manager.GetSessions())
    $spotify = $sessions | Where-Object { $_.SourceAppUserModelId -match 'Spotify' } | Select-Object -First 1
    if ($spotify -or -not $cfg.AnyPlayer) { return $spotify }
    # Andere Musik-Apps: laufende zuerst. Browser nur mit Album-Angabe -> YouTube Music ja, normale YouTube-Videos nein
    $candidates = foreach ($s in $sessions) {
        if ($s.SourceAppUserModelId -match $browserPattern) {
            $props = try { Await ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties]) } catch { $null }
            if (-not $props -or -not $props.AlbumTitle -or "$($props.PlaybackType)" -eq 'Video') { continue }
        }
        $s
    }
    $playing = $candidates | Where-Object { "$($_.GetPlaybackInfo().PlaybackStatus)" -eq 'Playing' } | Select-Object -First 1
    if ($playing) { $playing } else { $candidates | Select-Object -First 1 }
}

function Get-SpotifyInfo {
    $session = Get-MediaSession
    if (-not $session) { return $null }
    $props = Await ($session.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
    if (-not $props -or -not $props.Title) { return $null }
    $pb       = $session.GetPlaybackInfo()
    $playing  = $pb.PlaybackStatus -eq 'Playing'
    $timeline = $session.GetTimelineProperties()
    $length   = $timeline.EndTime - $timeline.StartTime
    $pos      = $timeline.Position
    # Die Position wird nur ab und zu gemeldet -> seit der letzten Meldung weiterzaehlen
    if ($playing) { $pos += [DateTimeOffset]::Now - $timeline.LastUpdatedTime }
    if ($pos -gt $length) { $pos = $length }
    [pscustomobject]@{
        Title = $props.Title; Artist = $props.Artist; Album = $props.AlbumTitle
        Playing = $playing; Pos = $pos; Length = $length; Thumbnail = $props.Thumbnail
        Shuffle = [bool]$pb.IsShuffleActive; Repeat = "$($pb.AutoRepeatMode)"
        Source = $session.SourceAppUserModelId
    }
}

function Get-CoverBytes($thumbnail) {
    if (-not $thumbnail) { return $null }
    $stream = Await ($thumbnail.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
    $net = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($stream)
    $ms = New-Object System.IO.MemoryStream
    try { $net.CopyTo($ms); $ms.ToArray() } finally { $net.Dispose(); $stream.Dispose(); $ms.Dispose() }
}

function Invoke-MediaCommand([string]$cmd) {
    $session = Get-MediaSession
    if (-not $session) { return }
    switch -Regex ($cmd) {
        '^playpause$' { [void](Await ($session.TryTogglePlayPauseAsync()) ([bool])) }
        '^next$'      { [void](Await ($session.TrySkipNextAsync()) ([bool])) }
        '^prev$'      { [void](Await ($session.TrySkipPreviousAsync()) ([bool])) }
        '^shuffle$'   { [void](Await ($session.TryChangeShuffleActiveAsync(-not [bool]$session.GetPlaybackInfo().IsShuffleActive)) ([bool])) }
        '^repeat$' {
            $next = switch ("$($session.GetPlaybackInfo().AutoRepeatMode)") { 'List' { 'Track' } 'Track' { 'None' } default { 'List' } }
            [void](Await ($session.TryChangeAutoRepeatModeAsync([Windows.Media.MediaPlaybackAutoRepeatMode]$next)) ([bool]))
        }
        '^seek:(.+)$' {
            $ticks = [long]([double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) * 10000000)
            [void](Await ($session.TryChangePlaybackPositionAsync($ticks)) ([bool]))
        }
    }
}

# ---------------- Hintergrund-Downloads (blockieren nie) ----------------
# Ein gemeinsamer Pool statt fuer jeden Download einen neuen Runspace (spart CPU und RAM)
$pool = [runspacefactory]::CreateRunspacePool(1, 4)
$pool.Open()
$jobs = @{}
$orphans = New-Object System.Collections.ArrayList   # ueberholte Downloads (z. B. schnelles Skippen), werden spaeter aufgeraeumt
function Start-Async([string]$name, [string]$tag, [scriptblock]$script, $argument) {
    if ($jobs[$name]) { [void]$orphans.Add($jobs[$name]); $jobs.Remove($name) }
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($script, $true).AddArgument($argument)
    $jobs[$name] = @{ Ps = $ps; Handle = $ps.BeginInvoke(); Tag = $tag }
}
function Clear-Orphans {
    foreach ($o in @($orphans)) {
        if (-not $o.Handle.IsCompleted) { continue }
        try { [void]$o.Ps.EndInvoke($o.Handle) } catch {}
        $o.Ps.Dispose(); $orphans.Remove($o)
    }
}
function Test-AsyncRunning([string]$name) { $jobs[$name] -and -not $jobs[$name].Handle.IsCompleted }
function Receive-Async([string]$name) {
    $j = $jobs[$name]
    if (-not $j -or -not $j.Handle.IsCompleted) { return $null }
    $jobs.Remove($name)
    try { $result = $j.Ps.EndInvoke($j.Handle) } catch { $result = $null; Log-Error "$name : $_" }
    $j.Ps.Dispose()
    [pscustomobject]@{ Tag = $j.Tag; Result = @($result) }
}

# ---------------- Text-Bausteine ----------------
function Format-Time([TimeSpan]$t) { "{0}:{1:00}" -f [int][Math]::Floor($t.TotalMinutes), $t.Seconds }
function Limit([string]$s, [int]$max) {
    if ($s.Length -le $max) { return $s }
    $cut = $max - 3
    if ($cut -gt 0 -and [char]::IsHighSurrogate($s[$cut - 1])) { $cut-- }   # Emoji nicht in der Mitte zerschneiden
    $s.Substring(0, $cut) + "..."
}
function Clean-Title([string]$t) { $t -replace '\s*[\(\[](feat|ft|with)\.?[^\)\]]*[\)\]]', '' }
# Fuer die Suche (Lyrics/Cover) zusaetzlich Zusaetze wie "- 2014 Remaster" oder "- Radio Edit" weg
function Search-Title([string]$t) {
    (Clean-Title $t) -replace '(?i)\s+-\s+[^-]*\b(remaster(ed)?|edit|version|live|mono|stereo|feat\.?|dirty|clean|explicit|single)\b.*$', ''
}
# VRChat erlaubt 144 Zeichen; ohne Hintergrund brauchen wir 2 davon fuer die Steuerzeichen
function Get-MaxLen { if ($cfg.NoBackground) { 142 } else { 144 } }

function Get-Bar($info) {
    $style = $barStyles[[int]$cfg.BarStyle]
    $len = [int]$cfg.BarLength
    $frac = $info.Pos.TotalSeconds / $info.Length.TotalSeconds
    if ($style[1]) {
        $filled = [int][Math]::Round($frac * ($len - 1))
        $bar = ($style[0] * $filled) + $style[1] + ($style[2] * ($len - 1 - $filled))
    } else {
        $filled = [int][Math]::Round($frac * $len)
        $bar = ($style[0] * $filled) + ($style[2] * ($len - $filled))
    }
    $end = if ($cfg.Remaining) { "-" + (Format-Time ($info.Length - $info.Pos)) } else { Format-Time $info.Length }
    "$(Format-Time $info.Pos) $bar $end"
}

function Show-Song($info) {
    if (-not $info) { return $false }
    if (-not $info.Playing -and $cfg.HideWhenPaused) { return $false }
    if ($cfg.ChangeOnly -and ((Get-Date) - $st.ChangedAt).TotalSeconds -gt 15) { return $false }
    $true
}

# Titel aufraeumen: Features "(feat. X)" und/oder Zusaetze wie "(Remastered)", "[Live]", "- Radio Edit" weg
function Get-DisplayTitle($info) {
    $t = "$($info.Title)"
    if ($cfg.HideFeat) { $t = $t -replace '(?i)\s*[\(\[](feat|ft|with)\.?\s[^\)\]]*[\)\]]', '' -replace '(?i)\s+(feat|ft)\.?\s.*$', '' }
    if ($cfg.HideBrackets) {
        $t = $t -replace '\s*[\(\[][^\)\]]*[\)\]]', ''
        $t = $t -replace '(?i)\s+-\s+[^-]*\b(remaster(ed)?|edit|version|live|mono|stereo|mix|remix|demo|acoustic|instrumental|dirty|clean|explicit|single|from)\b.*$', ''
    }
    $t = $t.Trim()
    if ($t) { $t } else { "$($info.Title)" }   # nie einen leeren Titel zeigen
}
# Kuenstler: auf Wunsch nur der erste ("Kanye West" statt "Kanye West, Ty Dolla $ign")
function Get-DisplayArtist($info) {
    $a = "$($info.Artist)".Trim()
    if ($cfg.MainArtistOnly -and $a) { $a = (($a -split ',|\s&\s|(?i)\s(feat|ft)\.?\s')[0]).Trim() }
    $a
}
# Album ausblenden, wenn es genauso heisst wie der Song (typisch bei Singles)
function Test-AlbumIsTitle($info) {
    $norm = { param($s) ("$s".ToLower() -replace '\s*[\(\[][^\)\]]*[\)\]]', '' -replace '(?i)\s+-\s+.*$', '' -replace '[^\p{L}\p{N}]', '') }
    $al = & $norm $info.Album
    $al -and $al -eq (& $norm $info.Title)
}

# Songzeile aus Titel und/oder Kuenstler - $null, wenn beides ausgeschaltet ist
function Get-SongLine($info, [int]$max) {
    $title = Get-DisplayTitle $info; $artist = Get-DisplayArtist $info
    # Manche Songs haben keinen Kuenstler -> dann zaehlt er als ausgeschaltet
    $useTitle = $cfg.ShowTitle -and $title
    $useArtist = $cfg.ShowArtist -and $artist
    if (-not $useTitle -and -not $useArtist) { return $null }
    $icon = if (-not $info.Playing) { $emoji.Pause } else { $playIcons[[int]$cfg.IconStyle] }
    if ($cfg.SmallCaps) { $title = To-SmallCaps $title; if (-not $cfg.ArtistSuperscript) { $artist = To-SmallCaps $artist } }
    $sep = if ("$($cfg.Separator)") { "$($cfg.Separator)" } else { " - " }
    $joint = if ($cfg.ArtistSuperscript) { " $(To-Super 'by') " } else { $sep }
    if ($cfg.ArtistSuperscript) { $artist = To-Super $artist }
    $song = if (-not $useArtist) { $title }
            elseif (-not $useTitle) { $artist }
            elseif ($cfg.ArtistOwnLine) { $title }   # Kuenstler kommt in eine eigene Zeile, siehe Get-ArtistLine
            else {
                # Zu lang? Dann den Titel kuerzen, der Kuenstler bleibt immer sichtbar
                $artist = Limit $artist 28
                $room = $max - $joint.Length - $artist.Length
                "$(Limit $title ([Math]::Max(12, $room)))$joint$artist"
            }
    "$icon $(Limit $song $max)".Trim()
}
# Eigene Kuenstler-Zeile (nur wenn Titel UND Kuenstler an sind und "Eigene Zeile" gewaehlt ist)
function Get-ArtistLine($info) {
    $artist = Get-DisplayArtist $info
    if (-not ($cfg.ArtistOwnLine -and $cfg.ShowTitle -and $cfg.ShowArtist -and $artist -and "$($info.Title)".Trim())) { return $null }
    if ($cfg.ArtistSuperscript) { return Limit "$(To-Super 'by') $(To-Super $artist)" 60 }
    if ($cfg.SmallCaps) { $artist = To-SmallCaps $artist }
    Limit "$(E 0x1F464) $artist" 60
}

function Get-StatusParts([bool]$short) {
    $parts = @()
    if ($cfg.ShowClock) { $parts += "$(if (-not $short) { "$($emoji.Clock) " })$(Get-Date -Format 'HH:mm')" }
    if ($cfg.Playtime) {
        try {
            $span = (Get-Date) - (Get-Process -Name VRChat | Select-Object -First 1).StartTime
            $parts += "$($emoji.Timer) {0}:{1:00} h" -f [int][Math]::Floor($span.TotalHours), $span.Minutes
        } catch {}
    }
    if ($cfg.WorldInfo -and $sync.World -and $sync.VRChat) { $parts += "$($emoji.Globe) $(Limit $sync.World 32) ($($sync.Players))" }
    if ($cfg.Afk) { $parts += "$($emoji.Afk) AFK" }
    elseif ($cfg.AutoAfk) {
        $idle = [Native]::IdleMinutes()
        if ($idle -ge $cfg.AfkMinutes) { $parts += "$($emoji.Afk) AFK ($([int]$idle) min)" }
    }
    # Mehrere Status-Texte mit ; getrennt -> wechseln alle 10 Sekunden
    $texts = @("$($cfg.StatusText)" -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($texts) { $parts += $texts[[int][Math]::Floor((Get-Date).TimeOfDay.TotalSeconds / 10) % $texts.Count] }
    ,$parts
}

function Get-Translation([string]$line) {
    if (-not $cfg.Translate -or -not $lyr.Trans -or -not $line) { return $null }
    $t = $lyr.Trans[$line.Trim()]
    if ($t -and $t -ne $line.Trim()) { $t } else { $null }
}

# Zeilen mit Wichtigkeit (P). Passt nicht alles rein, fliegen zuerst die unwichtigsten Zeilen raus -
# Songzeile (90) und Lyrics (100) bleiben immer. Reicht das nicht, wird die Songzeile gekuerzt.
function Join-Lines($list) { (@($list | ForEach-Object { $_.T }) -join "`n").Trim("`n") }
function Fit-Lines($items) {
    $list = New-Object System.Collections.ArrayList
    foreach ($i in $items) { if ($null -ne $i.T) { [void]$list.Add($i) } }
    $max = Get-MaxLen
    while ((Join-Lines $list).Length -gt $max) {
        $drop = $null
        foreach ($i in $list) { if ($i.P -lt 90 -and (-not $drop -or $i.P -le $drop.P)) { $drop = $i } }
        if (-not $drop) { break }
        $list.Remove($drop)
    }
    $over = (Join-Lines $list).Length - $max
    $song = $list | Where-Object { $_.P -eq 90 } | Select-Object -First 1
    if ($over -gt 0 -and $song) { $song.T = Limit $song.T ([Math]::Max(12, $song.T.Length - $over)) }
    Limit (Join-Lines $list) $max
}

function Build-ChatText($info) {
    if ($cfg.Compact) { return Build-CompactText $info }
    $showSong = Show-Song $info
    $lyricsOn = ($cfg.ShowLyrics -or $cfg.LyricsMode) -and $showSong -and $lyr.Lines -and $lyr.Key -eq $st.LastKey
    $hideTitle = $cfg.HideTitleAfterLyrics -and $lyricsOn -and ((Get-Date) - $st.ChangedAt).TotalSeconds -gt 10
    $items = New-Object System.Collections.ArrayList
    if ($showSong -and -not $hideTitle) {
        $line = Get-SongLine $info 60; if ($line) { [void]$items.Add(@{ T = $line; P = 90 }) }
        $aLine = Get-ArtistLine $info; if ($aLine) { [void]$items.Add(@{ T = $aLine; P = 70 }) }
    }

    if ($cfg.LyricsMode -and $lyricsOn) {
        # Karaoke: Song, aktuelle Zeile, darunter Uebersetzung oder naechste Zeile
        $pair = Find-LyricPair $info.Pos.TotalSeconds
        $st.LastLyric = $pair[0]
        $note = [string][char]0x266A
        $current = if ($pair[0]) { "$($emoji.Mic) $($pair[0])" } else { "$note  $note  $note" }
        [void]$items.Add(@{ T = $current; P = 100 })
        $tr = Get-Translation $pair[0]
        if ($tr) { [void]$items.Add(@{ T = "$($emoji.Translate) $tr"; P = 95 }) }
        elseif ($pair[1]) { [void]$items.Add(@{ T = "$([char]0x203A) $($pair[1])"; P = 50 }) }
        return Fit-Lines $items
    }

    $songLines = $items.Count
    if ($showSong) {
        if ($cfg.ShowAlbum -and $info.Album -and -not ($cfg.HideAlbumIfTitle -and (Test-AlbumIsTitle $info))) { [void]$items.Add(@{ T = (Limit "$($emoji.Disc) $($info.Album)" 40); P = 30 }); $songLines++ }
        if ($cfg.ShowBar -and $info.Length.TotalSeconds -gt 0) { [void]$items.Add(@{ T = (Get-Bar $info); P = 50 }); $songLines++ }
    }
    $rest = New-Object System.Collections.ArrayList
    $status = Get-StatusParts $false
    # Status (Uhrzeit, Welt usw.) ist wichtiger als Balken und Album - die fliegen bei Platzmangel zuerst raus
    if ($status) { [void]$rest.Add(@{ T = ($status -join $cfg.Separator); P = 60 }) }
    # Lyrics ganz unten, damit sie nicht zwischen festem Text stehen
    if ($lyricsOn) {
        $lyric = Find-Lyric $info.Pos.TotalSeconds
        $st.LastLyric = $lyric
        if ($lyric) {
            [void]$rest.Add(@{ T = "$($emoji.Mic) $lyric"; P = 100 })
            $tr = Get-Translation $lyric
            if ($tr) { [void]$rest.Add(@{ T = "$($emoji.Translate) $tr"; P = 95 }) }   # Uebersetzung soll immer bleiben
        }
    }
    if ($cfg.BlankLine -and $songLines -and $rest.Count) { [void]$items.Add(@{ T = ""; P = 10 }) }
    foreach ($r in $rest) { [void]$items.Add($r) }
    Fit-Lines $items
}

function Build-CompactText($info) {
    $parts = @()
    if (Show-Song $info) {
        $song = Get-SongLine $info 40
        if ($cfg.ShowBar -and $info.Length.TotalSeconds -gt 0) { $song = "$song $(Format-Time $info.Pos)/$(Format-Time $info.Length)".Trim() }
        if ($song) { $parts += $song }
    }
    $parts += Get-StatusParts $true
    Limit ($parts -join $cfg.Separator) (Get-MaxLen)
}

# ---------------- Lyrics (eigene Datei, Cache oder lrclib.net) ----------------
$lyr = @{ Key = $null; Lines = $null; Trans = $null; TransKey = $null; TransRetry = [DateTime]::MinValue; Retry = $null }

function Get-LyricsFileName($info) {
    $name = "$($info.Artist) - $(Clean-Title $info.Title).lrc" -replace '[\\/:*?"<>|]', '_'
    Join-Path $sync.LyricsDir $name
}

# Datei im cache-Ordner (Uebersetzungen als .json, geladene Lyrics als .lrc)
$md5 = [System.Security.Cryptography.MD5]::Create()
function Get-CacheFile([string]$key, [string]$ext = 'json') {
    $hash = -join ($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($key)) | ForEach-Object { $_.ToString('x2') })
    Join-Path $sync.CacheDir "$hash.$ext"
}

function Set-LyricLines([string]$lrc) {
    $lyr.Lines = @(@(foreach ($l in ($lrc -split "`r?`n")) {
        if ($l -match '^\[(\d+):(\d+(?:\.\d+)?)\]\s*(.*)$') {
            [pscustomobject]@{ T = [int]$Matches[1] * 60 + [double]::Parse($Matches[2], [Globalization.CultureInfo]::InvariantCulture); L = $Matches[3].Trim() }
        }
    }) | Sort-Object T)
    # fuer die Lyrics-Ansicht im Panel
    $sync.LyricLines = $lyr.Lines; $sync.LyricsKey = $lyr.Key
}

function Start-LyricsFetch($info) {
    $key = "$($info.Title)|$($info.Artist)"
    $lyr.Key = $key; $lyr.Lines = $null; $lyr.Trans = $null; $lyr.TransKey = $null; $lyr.TransRetry = [DateTime]::MinValue; $lyr.Retry = $null
    $sync.LyricLines = $null; $sync.LyricsKey = $key
    $file = Get-LyricsFileName $info
    if (Test-Path $file) {
        Set-LyricLines (Get-Content $file -Raw -Encoding UTF8)
        $sync.LyricsStatus = "Eigene Lyrics"
        return
    }
    # Schon mal geladen? Dann ohne Internet sofort da
    $cached = Get-CacheFile "lrc|$key" 'lrc'
    if (Test-Path $cached) {
        Set-LyricLines (Get-Content $cached -Raw -Encoding UTF8)
        $sync.LyricsStatus = "Gefunden"
        return
    }
    $sync.LyricsStatus = "Suche Lyrics..."
    $arg = New-Object object[] 3
    $arg[0] = Search-Title $info.Title; $arg[1] = ($info.Artist -split ',')[0].Trim(); $arg[2] = [double]$info.Length.TotalSeconds
    Start-Async 'lyrics' $key {
        param($a)
        $title = $a[0]; $artist = $a[1]; $len = [double]$a[2]
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Encoding = [System.Text.Encoding]::UTF8   # sonst wird aus "ß" ein "ÃŸ"
            $wc.Headers['User-Agent'] = 'SpotifyToVRChat (https://github.com)'
            $find = { param($u) $data = $wc.DownloadString($u) | ConvertFrom-Json; $data | Where-Object { $_.syncedLyrics } }
            $hits = @(& $find "https://lrclib.net/api/search?track_name=$([uri]::EscapeDataString($title))&artist_name=$([uri]::EscapeDataString($artist))")
            if (-not $hits) { $hits = @(& $find "https://lrclib.net/api/search?q=$([uri]::EscapeDataString("$artist $title"))") }
            # Die Version mit der passenden Laenge nehmen, sonst laufen die Lyrics neben der Musik her
            if ($len -gt 0 -and $hits) {
                $hits = @($hits | Sort-Object { [Math]::Abs([double]$_.duration - $len) })
                if ([Math]::Abs([double]$hits[0].duration - $len) -gt 20) { $hits = @() }
            }
            [pscustomobject]@{ Ok = $true; Lrc = $(if ($hits) { $hits[0].syncedLyrics } else { $null }) }
        } catch {
            [pscustomobject]@{ Ok = $false; Error = "$_" }
        }
    } $arg
}

# Gibt $true zurueck, wenn gerade neue Lyrics oder Uebersetzungen angekommen sind
function Update-Lyrics($info) {
    $key = "$($info.Title)|$($info.Artist)"
    if ($key -ne $lyr.Key) { Start-LyricsFetch $info; return [bool]$lyr.Lines }
    # Netzwerkfehler -> spaeter nochmal versuchen
    if ($lyr.Retry -and (Get-Date) -ge $lyr.Retry -and -not (Test-AsyncRunning 'lyrics')) { Start-LyricsFetch $info }
    $r = Receive-Async 'lyrics'
    if ($r -and $r.Tag -eq $lyr.Key) {
        $res = $r.Result | Select-Object -First 1
        if ($res -and $res.Ok -and $res.Lrc) {
            Set-LyricLines $res.Lrc
            try { $res.Lrc | Set-Content (Get-CacheFile "lrc|$($lyr.Key)" 'lrc') -Encoding UTF8 } catch {}
            $sync.LyricsStatus = "Gefunden"
            return $true
        }
        if ($res -and -not $res.Ok) {
            $lyr.Retry = (Get-Date).AddSeconds(30)
            $sync.LyricsStatus = "Keine Verbindung - neuer Versuch gleich"
            Log-Error "Lyrics: $($res.Error)"
        } else {
            $sync.LyricsStatus = "Keine Lyrics gefunden"
        }
    }
    # Uebersetzung nachladen (erst aus dem Cache, sonst aus dem Netz; bei Fehler spaeter nochmal)
    $wantKey = "$($lyr.Key)|$($cfg.TranslateLang)"
    if ($cfg.Translate -and $lyr.Lines -and $lyr.TransKey -ne $wantKey -and -not (Test-AsyncRunning 'translate') -and (Get-Date) -ge $lyr.TransRetry) {
        $lyr.TransKey = $wantKey
        $lyr.Trans = $null
        $cacheFile = Get-CacheFile $wantKey
        if (Test-Path $cacheFile) {
            $lyr.Trans = @{}
            try { (Get-Content $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $lyr.Trans[$_.Name] = $_.Value } } catch {}
            return $true
        }
        $lines = @($lyr.Lines | Where-Object { $_.L } | ForEach-Object { $_.L.Trim() } | Select-Object -Unique)
        $arg = New-Object object[] 2
        $arg[0] = $lines; $arg[1] = "$($cfg.TranslateLang)"
        Start-Async 'translate' $wantKey $translateScript $arg
    }
    $t = Receive-Async 'translate'
    if ($t -and $t.Tag -eq $lyr.TransKey) {
        $res = $t.Result | Select-Object -First 1
        if ($res -and $res.Ok) {
            $lyr.Trans = $res.Map
            try { $res.Map | ConvertTo-Json | Set-Content (Get-CacheFile $lyr.TransKey) -Encoding UTF8 } catch {}
            return $true
        }
        # Alle Dienste gerade blockiert -> in 20 Sekunden nochmal versuchen
        $lyr.TransKey = $null
        $lyr.TransRetry = (Get-Date).AddSeconds(20)
        Log-Error "Übersetzung: $($res.Error)"
    }
    $false
}

# Uebersetzt alle Zeilen. Zeilen werden gebuendelt (weniger Anfragen) und ueber die Zeilenumbrueche wieder zugeordnet.
# Mehrere Google-Zugaenge, weil einzelne manchmal wegen zu vieler Anfragen blockieren.
$translateScript = {
    param($a)
    $lines = @($a[0])
    $target = $a[1]
    $map = @{}

    function Get-Web([string]$url) {
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $wc.Headers['User-Agent'] = 'Mozilla/5.0'
        $wc.DownloadString($url)
    }
    # Gibt @(Uebersetzung, erkannte Sprache) zurueck
    function Invoke-Translate([string]$text) {
        $q = [uri]::EscapeDataString($text)
        try {
            $r = Get-Web "https://clients5.google.com/translate_a/t?client=dict-chrome-ex&sl=auto&tl=$target&q=$q" | ConvertFrom-Json
            $first = $r[0]
            if ($first -is [array]) { return ,@("$($first[0])", "$($first[1])") } else { return ,@("$first", "") }
        } catch {
            $r = Get-Web "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=$target&dt=t&q=$q" | ConvertFrom-Json
            return ,@(((@($r[0]) | ForEach-Object { "$($_[0])" }) -join ''), "$($r[2])")
        }
    }

    try {
        # Buendel mit hoechstens ~1200 Zeichen
        $chunks = New-Object System.Collections.ArrayList
        $cur = New-Object System.Collections.ArrayList; $len = 0
        foreach ($l in $lines) {
            if ($len + $l.Length -gt 1200 -and $cur.Count) { [void]$chunks.Add($cur); $cur = New-Object System.Collections.ArrayList; $len = 0 }
            [void]$cur.Add($l); $len += $l.Length + 1
        }
        if ($cur.Count) { [void]$chunks.Add($cur) }

        foreach ($chunk in $chunks) {
            $res = Invoke-Translate ($chunk -join "`n")
            if ($res[1] -eq $target) { continue }   # schon in der Zielsprache
            $out = @($res[0] -split "`n")
            if ($out.Count -eq $chunk.Count) {
                for ($i = 0; $i -lt $chunk.Count; $i++) { $map[$chunk[$i]] = $out[$i].Trim() }
            } else {
                # Zeilen passen nicht zusammen -> einzeln uebersetzen
                foreach ($l in $chunk) { $map[$l] = (Invoke-Translate $l)[0].Trim(); Start-Sleep -Milliseconds 150 }
            }
        }
        [pscustomobject]@{ Ok = $true; Map = $map }
    } catch {
        [pscustomobject]@{ Ok = $false; Map = $null; Error = "$_" }
    }
}

function Find-LyricPair([double]$seconds) {
    if (-not $lyr.Lines) { return ,@($null, $null) }
    $t = $seconds + 0.3 + [double]$cfg.LyricsOffset
    $idx = -1
    for ($i = 0; $i -lt $lyr.Lines.Count; $i++) { if ($lyr.Lines[$i].T -le $t) { $idx = $i } else { break } }
    $current = if ($idx -ge 0 -and $lyr.Lines[$idx].L) { $lyr.Lines[$idx].L } else { $null }
    $next = $null
    for ($i = $idx + 1; $i -lt $lyr.Lines.Count; $i++) { if ($lyr.Lines[$i].L) { $next = $lyr.Lines[$i].L; break } }
    ,@($current, $next)
}
function Find-Lyric([double]$seconds) { (Find-LyricPair $seconds)[0] }

function Get-LivePos {
    $i = $sync.Info
    if (-not $i) { return 0 }
    $p = $i.Pos.TotalSeconds
    if ($i.Playing) { $p += ([DateTime]::Now - $sync.SampleTime).TotalSeconds }
    $p
}

# ---------------- VRChat-Log (Welt + Spielerzahl) ----------------
$vrLog = @{ File = $null; Pos = 0; Players = New-Object 'System.Collections.Generic.HashSet[string]' }
function Update-WorldInfo {
    $dirLog = Join-Path $env:USERPROFILE "AppData\LocalLow\VRChat\VRChat"
    # Nach Name sortieren (enthaelt Datum+Uhrzeit): Groesse und Aenderungszeit meldet Windows bei einer
    # Datei, in die VRChat gerade schreibt, oft veraltet (z. B. 0 Bytes) - deshalb nur die offene Datei fragen
    $file = Get-ChildItem $dirLog -Filter 'output_log_*.txt' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if (-not $file) { return }
    if ($file.FullName -ne $vrLog.File) { $vrLog.File = $file.FullName; $vrLog.Pos = 0; $vrLog.Players.Clear() }
    $fs = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite, Delete')
    try {
        if ($fs.Length -le $vrLog.Pos) { return }
        [void]$fs.Seek($vrLog.Pos, 'Begin')
        $bytes = New-Object byte[] ($fs.Length - $vrLog.Pos)
        $read = $fs.Read($bytes, 0, $bytes.Length)
    } finally { $fs.Dispose() }
    # Nur bis zum letzten Zeilenende lesen, eine halb geschriebene Zeile kommt beim naechsten Mal
    $end = [Array]::LastIndexOf($bytes, [byte]10, $read - 1)
    if ($end -lt 0) { return }
    $chunk = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $end + 1)
    $vrLog.Pos += $end + 1
    foreach ($line in ($chunk -split "`n")) {
        if ($line -match 'Entering Room: (.+?)\s*$') { $sync.World = $Matches[1]; $vrLog.Players.Clear() }
        elseif ($line -match 'OnPlayerJoined (.+?)(?: \(usr_[^)]*\))?\s*$') { [void]$vrLog.Players.Add($Matches[1]) }
        elseif ($line -match 'OnPlayerLeft (.+?)(?: \(usr_[^)]*\))?\s*$') { [void]$vrLog.Players.Remove($Matches[1]) }
    }
    $sync.Players = $vrLog.Players.Count
}

# ---------------- OSC senden ----------------
function Get-OscPaddedString([string]$s) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($s)
    $buf = New-Object byte[] ([Math]::Ceiling(($bytes.Length + 1) / 4) * 4)
    [Array]::Copy($bytes, $buf, $bytes.Length)
    ,$buf
}

function Get-OscPort {
    $port = 0
    if ($sync.PortOverride) { return [int]$sync.PortOverride }
    if (-not [int]::TryParse("$($cfg.OscPort)", [ref]$port) -or $port -lt 1 -or $port -gt 65535) { $port = 9000 }   # Tippfehler im Panel
    $port
}

$udp = $null
function Send-Chatbox([string]$text) {
    $port = Get-OscPort
    $oscHost = "$($cfg.OscHost)".Trim(); if (-not $oscHost) { $oscHost = "127.0.0.1" }
    if (-not $udp -or $st.UdpTarget -ne "${oscHost}:$port") {
        if ($udp) { $udp.Close() }
        $script:udp = New-Object System.Net.Sockets.UdpClient
        $udp.Connect($oscHost, $port)
        $st.UdpTarget = "${oscHost}:$port"
    }
    # /chatbox/input <string> <true = sofort senden> <false = kein Benachrichtigungston>
    $tags = ",sTF"
    # Diese zwei unsichtbaren Steuerzeichen am Ende lassen VRChat den dunklen Kasten weg
    if ($cfg.NoBackground -and $text) { $text = (Limit $text 142) + [char]0x03 + [char]0x1F }
    $packet = (Get-OscPaddedString "/chatbox/input") + (Get-OscPaddedString $tags) + (Get-OscPaddedString $text)
    [void]$udp.Send([byte[]]$packet, $packet.Length)
    $st.LastSend = [DateTime]::Now
}
function Clear-Chatbox { if (-not $st.Cleared) { Send-Chatbox ""; $st.Cleared = $true } }

# Sprechen erkennen: Mikrofon-Pegel direkt messen
function Update-Speaking {
    if (-not $cfg.HideWhileSpeaking) { $sync.Speaking = $false; $sync.MicLevel = 0; return }
    $level = [AppVolume]::MicLevel()
    $sync.MicLevel = $level
    if ($level -ge [double]$cfg.MicThreshold) { $st.LastVoice = Get-Date }
    # kurz nachlaufen lassen, damit die Chatbox nicht zwischen zwei Woertern aufblitzt
    $sync.Speaking = ((Get-Date) - $st.LastVoice).TotalSeconds -lt 2
}

# ---------------- Hoerzeit-Statistik ----------------
$stats = @{}
if (Test-Path $sync.StatsPath) {
    try { (Get-Content $sync.StatsPath -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $stats[$_.Name] = [double]$_.Value } } catch {}
}
function Save-Stats { try { $stats | ConvertTo-Json | Set-Content $sync.StatsPath -Encoding UTF8 } catch {} }

# ---------------- Schleife ----------------
$st = @{
    LastKey = $null; Cleared = $true; ChangedAt = Get-Date; LastLyric = $null
    CoverSource = $null; ThumbHash = $null; ThumbTries = 0; ThumbAt = [DateTime]::MinValue
    LastSend = [DateTime]::MinValue; UdpTarget = $null; LastVoice = [DateTime]::MinValue; WasSpeaking = $false
    WasPaused = $false; LastTick = [DateTime]::Now; StatsSaved = [DateTime]::Now; Played = 0.0; LogPending = $null; LogNeed = 30
}
$minGap = 1.5   # Sekunden zwischen zwei Nachrichten, sonst sperrt VRChat die Chatbox kurz
$next = @{ Send = [DateTime]::MinValue; Info = [DateTime]::MinValue; World = [DateTime]::MinValue; VrCheck = [DateTime]::MinValue; Focus = [DateTime]::MinValue }

while (-not $sync.Exit) {
    try {
        $now = [DateTime]::Now

        # Knoepfe aus dem Panel / Tastenkuerzel
        $cmd = $null
        while ($sync.Commands.TryDequeue([ref]$cmd)) {
            if ($cmd -eq 'test') {
                # Verbindungstest: kurze Nachricht, dann normal weiter
                try {
                    Send-Chatbox "$($emoji.Check) Spotify Chatbox: $(L 'Verbindung OK' 'Connection OK')"
                    $st.Cleared = $false; $next.Send = $now.AddSeconds(4)
                    $sync.TestResult = 'ok'
                } catch { $sync.TestResult = "$_"; Log-Error "Test: $_" }
                continue
            }
            try { Invoke-MediaCommand $cmd } catch { Log-Error "Befehl $cmd : $_" }
            Start-Sleep -Milliseconds 200
            $sync.Dirty = $true
        }

        # VRChat laeuft?
        if ($now -ge $next.VrCheck) {
            $sync.VRChat = [bool](Get-Process -Name VRChat -ErrorAction SilentlyContinue)
            $next.VrCheck = $now.AddSeconds(2)
            # OSC an? VRChat lauscht dann auf dem Port. Nur pruefbar, wenn VRChat auf diesem PC laeuft.
            $sync.OscOk = if ($sync.VRChat -and "$($cfg.OscHost)".Trim() -in '', '127.0.0.1', 'localhost') {
                $port = Get-OscPort
                [bool]([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveUdpListeners() | Where-Object { $_.Port -eq $port })
            } else { $null }
        }
        $eco = -not $sync.VRChat

        # Spotify abfragen (Energiesparmodus: seltener, wenn VRChat zu ist)
        if ($now -ge $next.Info -or $sync.Dirty -or $sync.SendNow) {
            $next.Info = $now.AddSeconds($(if ($eco) { 5 } else { 1 }))
            $info = try { Get-SpotifyInfo } catch { $null }
            $sync.Info = $info
            $sync.SampleTime = $now

            if ($info) {
                $key = "$($info.Title)|$($info.Artist)"
                if ($key -ne $st.LastKey) {
                    $st.LastKey = $key
                    $st.ChangedAt = Get-Date
                    $st.LastLyric = $null
                    $sync.SongCount++
                    $sync.Genre = $null
                    # Erst in den Verlauf, wenn der Song wirklich gehoert wurde (nicht beim Durchskippen)
                    $st.Played = 0.0
                    $st.LogPending = "{0}`t{1}`t{2}`t{3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $info.Title, $info.Artist, [int]$info.Length.TotalSeconds
                    $st.LogNeed = if ($info.Length.TotalSeconds -gt 0) { [Math]::Min(30, $info.Length.TotalSeconds / 2) } else { 30 }
                    $sync.SongEvent = "$($info.Title) - $($info.Artist)"
                    $sync.Cover = $null; $sync.CoverKey = "none|$key"
                    # Spotify meldet direkt nach dem Wechsel oft noch das alte Cover -> kurz warten und spaeter nochmal pruefen
                    $st.CoverSource = $null; $st.ThumbHash = $null; $st.ThumbTries = 0; $st.ThumbAt = $now.AddMilliseconds(1200); $st.WebCover = $null
                    $sync.SendNow = $true
                    # Cover + Genre aus dem Netz (iTunes, dann Deezer, notfalls Kuenstlerbild) - nur fuers Panel
                    $query = @((($info.Artist -split ',')[0].Trim()), (Search-Title $info.Title))
                    Start-Async 'cover' $key {
                        param($q)
                        $artist = $q[0]; $title = $q[1]
                        $wc = New-Object System.Net.WebClient
                        $wc.Encoding = [System.Text.Encoding]::UTF8
                        $norm = { param($s) ("$s".ToLower() -replace '[^\p{L}\p{N}]', '') }
                        $a = & $norm $artist; $t = & $norm $title
                        $sameArtist = { param($n) $n = & $norm $n; $n -and $a -and ($n.Contains($a) -or $a.Contains($n)) }
                        $sameTitle = { param($n) $n = & $norm $n; $n -and $t -and ($n.StartsWith($t) -or $t.StartsWith($n)) }
                        $genre = $null; $url = $null; $isArtistPic = $false
                        # 1) iTunes (liefert auch das Genre)
                        try {
                            $r = $wc.DownloadString("https://itunes.apple.com/search?entity=song&limit=15&term=$([uri]::EscapeDataString("$artist $title"))") | ConvertFrom-Json
                            $same = @($r.results | Where-Object { & $sameArtist $_.artistName })
                            $genre = ($same | Select-Object -First 1).primaryGenreName
                            $hit = $same | Where-Object { & $sameTitle $_.trackName } | Select-Object -First 1
                            if ($hit) { $genre = $hit.primaryGenreName; if ($hit.artworkUrl100) { $url = $hit.artworkUrl100 -replace '100x100', '400x400' } }
                        } catch {}
                        # 2) Deezer (hat viele Songs, die bei iTunes fehlen)
                        if (-not $url) {
                            try {
                                $dq = 'artist:"' + $artist + '" track:"' + $title + '"'
                                $r = $wc.DownloadString("https://api.deezer.com/search?q=" + [uri]::EscapeDataString($dq)) | ConvertFrom-Json
                                $hit = @($r.data) | Where-Object { (& $sameArtist $_.artist.name) -and (& $sameTitle $_.title) } | Select-Object -First 1
                                if ($hit) { $url = $hit.album.cover_xl }
                            } catch {}
                        }
                        # 3) Kein Cover gefunden -> Bild vom Kuenstler
                        if (-not $url) {
                            try {
                                $r = $wc.DownloadString("https://api.deezer.com/search/artist?q=$([uri]::EscapeDataString($artist))") | ConvertFrom-Json
                                $hit = @($r.data) | Where-Object { (& $norm $_.name) -eq $a } | Select-Object -First 1
                                if ($hit -and $hit.picture_xl -and $hit.picture_xl -notmatch '/artist//') { $url = $hit.picture_xl; $isArtistPic = $true }
                            } catch {}
                        }
                        $bytes = if ($url) { try { $wc.DownloadData($url) } catch { $null } } else { $null }
                        [pscustomobject]@{ Bytes = $bytes; Genre = $genre; ArtistPic = $isArtistPic }
                    } $query
                }
                # Cover von Spotify selbst (bestes Bild): erst nach kurzer Wartezeit, dann noch einmal pruefen
                if ($info.Thumbnail -and $st.ThumbTries -lt 3 -and $now -ge $st.ThumbAt) {
                    $st.ThumbTries++; $st.ThumbAt = $now.AddSeconds(2.5)
                    $bytes = try { Get-CoverBytes $info.Thumbnail } catch { $null }
                    if ($bytes -and $bytes.Length -gt 100) {
                        $hash = [Convert]::ToBase64String($md5.ComputeHash($bytes))
                        if ($hash -ne $st.ThumbHash) {
                            $st.ThumbHash = $hash; $st.CoverSource = 'spotify'
                            $sync.Cover = $bytes; $sync.CoverKey = "$key|spotify|$($st.ThumbTries)"
                        }
                    }
                }
            }
        }
        $info = $sync.Info

        # Cover/Genre aus dem Netz - nur nehmen, wenn Spotify selbst kein Bild geliefert hat
        $it = Receive-Async 'cover'
        if ($it -and $it.Tag -eq $st.LastKey) {
            $res = $it.Result | Select-Object -First 1
            if ($res) {
                if ($res.Bytes -and $st.CoverSource -ne 'spotify') { $st.CoverSource = 'web'; $sync.Cover = [byte[]]$res.Bytes; $sync.CoverKey = "$($st.LastKey)|web" }
                if ($res.Genre) { $sync.Genre = $res.Genre }
            }
        }
        Clear-Orphans

        # Hoerzeit zaehlen
        if ($info -and $info.Playing) {
            # Hoechstens 5 s pro Runde - sonst zaehlt z. B. Standby als Hoerzeit
            $delta = [Math]::Min(5, ($now - $st.LastTick).TotalSeconds)
            $today = Get-Date -Format 'yyyy-MM-dd'
            $stats[$today] = [double]$stats[$today] + $delta
            $sync.ListenToday = $stats[$today]
            $st.Played += $delta
            if ($st.LogPending -and $st.Played -ge $st.LogNeed) {
                if ($cfg.History) { try { Add-Content $sync.HistoryPath $st.LogPending -Encoding UTF8 } catch { Log-Error "Verlauf: $_" } }
                $st.LogPending = $null
            }
        }
        $st.LastTick = $now
        if (($now - $st.StatsSaved).TotalSeconds -ge 60) { Save-Stats; $st.StatsSaved = $now }

        # Welt + Spielerzahl immer mitlesen, solange VRChat laeuft (fuers Dashboard und die Chatbox)
        if ($sync.VRChat -and $now -ge $next.World) { try { Update-WorldInfo } catch { Log-Error "VRChat-Log: $_" }; $next.World = $now.AddSeconds(3) }

        # Sprechen / Pause -> sofort aus- bzw. wieder einblenden.
        # Sprechen zaehlt nur, wenn VRChat das aktive Fenster ist (sonst redest du z. B. gerade in Discord)
        try { Update-Speaking } catch { Log-Error "Mikrofon: $_" }
        if ($now -ge $next.Focus) { $sync.VrFocused = [Native]::ForegroundProcessName() -eq 'VRChat'; $next.Focus = $now.AddSeconds(1) }
        $speakingHide = $cfg.HideWhileSpeaking -and $sync.Speaking -and $sync.VrFocused
        if ($speakingHide -ne $st.WasSpeaking) { $st.WasSpeaking = $speakingHide; $sync.SendNow = $true }
        $paused = $now -lt $sync.PauseUntil
        if ($paused -ne $st.WasPaused) { $st.WasPaused = $paused; $sync.SendNow = $true }

        # Lyrics: sofort laden, sofort zeigen und jede neue Zeile direkt senden
        if (-not $eco -and ($cfg.ShowLyrics -or $cfg.LyricsMode) -and -not $cfg.Compact -and $cfg.Enabled -and (Show-Song $info)) {
            if (Update-Lyrics $info) { $sync.SendNow = $true }
            if ($info.Playing -and (Find-Lyric (Get-LivePos)) -ne $st.LastLyric) { $sync.SendNow = $true }
        }

        $gapOk = ($now - $st.LastSend).TotalSeconds -ge $minGap
        $due = ($now -ge $next.Send) -or ($sync.SendNow -and $gapOk)
        if ($due -or $sync.Dirty) {
            $sync.Dirty = $false
            if ($due -and $info) {
                # frische Position fuer genaue Lyrics und Balken
                $fresh = try { Get-SpotifyInfo } catch { $null }
                if ($fresh) { $info = $fresh; $sync.Info = $fresh; $sync.SampleTime = [DateTime]::Now }
            }
            $text = if (-not $cfg.Enabled -or $speakingHide -or $paused) { "" } else { Build-ChatText $info }
            $sync.Text = $text

            if ($due) {
                $sync.SendNow = $false
                $next.Send = $now.AddSeconds([double]$cfg.Interval)
                if (-not $sync.VRChat) { $st.Cleared = $true }
                elseif ($text) { Send-Chatbox $text; $st.Cleared = $false }
                else { Clear-Chatbox }
            }
        }
    } catch {
        Log-Error "$_"
    }
    Start-Sleep -Milliseconds $(if (-not $sync.VRChat) { 400 } else { 100 })
}

# Beim Beenden: Statistik sichern, Chatbox leeren
Save-Stats
if ($sync.VRChat) { try { Send-Chatbox "" } catch {} }
if ($udp) { $udp.Close() }
$md5.Dispose()
try { $pool.Close() } catch {}
