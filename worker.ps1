# Hintergrund-Thread: fragt Spotify/VRChat ab, baut den Chatbox-Text und sendet ihn per OSC.
# Laeuft in einem eigenen Runspace, damit das Panel nie haengt. Austausch ueber $sync.

$cfg = $sync.Cfg

function Log-Error([string]$msg) {
    [void]$sync.Errors.Add("$(Get-Date -Format HH:mm:ss)  $msg")
    while ($sync.Errors.Count -gt 100) { $sync.Errors.RemoveAt(0) }
}

function E([int]$codepoint) { [char]::ConvertFromUtf32($codepoint) }
$emoji = @{
    Note = E 0x1F3B5; Pause = E 0x23F8; Clock = E 0x1F552; Afk = E 0x1F4A4; Disc = E 0x1F4BF
    Mic = E 0x1F3A4; Pc = E 0x1F4BB; Timer = E 0x23F1; Globe = E 0x1F30D; Heart = E 0x2764
    Date = E 0x1F4C5; Hourglass = E 0x23F3; Game = E 0x1F3AE; Translate = E 0x1F310
}
$playIcons = @((E 0x1F3B5), (E 0x1F3A7), (E 0x266A), "")
$decoChars = @((E 0x2726), (E 0x22C6), (E 0x2727), (E 0x2605), (E 0x2661), (E 0x2740), (E 0x273F), (E 0x2729))

# Genre (von iTunes) -> Emoji
$genreEmoji = [ordered]@{
    'hip.?hop|rap' = E 0x1F525; 'r&b|soul' = E 0x1F49C; 'dance|electro|house|techno' = E 0x1F3A7
    'rock' = E 0x1F3B8; 'metal' = E 0x1F918; 'pop' = E 0x2728; 'alternative|indie' = E 0x1F319
    'country' = E 0x1F920; 'classical|klassik' = E 0x1F3BB; 'jazz' = E 0x1F3B7; 'reggae' = E 0x1F334
    'latin' = E 0x1F483; 'soundtrack' = E 0x1F3AC; 'schlager' = E 0x1F37B
}

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
    [void]$task.Wait(-1)
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
    $net.CopyTo($ms); $net.Dispose()
    $ms.ToArray()
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
$jobs = @{}
function Start-Async([string]$name, [string]$tag, [scriptblock]$script, $argument) {
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script).AddArgument($argument)
    $jobs[$name] = @{ Ps = $ps; Handle = $ps.BeginInvoke(); Tag = $tag }
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
function Limit([string]$s, [int]$max) { if ($s.Length -gt $max) { $s.Substring(0, $max - 3) + "..." } else { $s } }
function Clean-Title([string]$t) { $t -replace '\s*[\(\[](feat|ft|with)\.?[^\)\]]*[\)\]]', '' }

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

function Get-SongLine($info, [int]$max) {
    $icon = if (-not $info.Playing) { $emoji.Pause }
            elseif ($cfg.GenreEmoji -and $st.GenreEmoji) { $st.GenreEmoji }
            else { $playIcons[[int]$cfg.IconStyle] }
    $title = $info.Title; $artist = $info.Artist
    if ($cfg.SmallCaps) { $title = To-SmallCaps $title; if (-not $cfg.ArtistSuperscript) { $artist = To-SmallCaps $artist } }
    $song = if ($cfg.ArtistSuperscript) { "$title $(To-Super 'by') $(To-Super $artist)" } else { "$title - $artist" }
    if ($cfg.Marquee -and $song.Length -gt $max) {
        $loop = "$song   " + [char]0x00B7 + "   "
        $offset = ($st.Scroll * 4) % $loop.Length
        $song = ($loop + $loop).Substring($offset, $max)
    } else {
        $song = Limit $song $max
    }
    if ($cfg.SongNumber) { $song += "  #$($sync.SongCount)" }
    "$icon $song".Trim()
}

function Get-StatusParts([bool]$short) {
    $parts = @()
    if ($cfg.ShowClock) {
        $fmt = if ($cfg.ClockSeconds) { 'HH:mm:ss' } else { 'HH:mm' }
        $parts += "$(if (-not $short) { "$($emoji.Clock) " })$(Get-Date -Format $fmt)"
    }
    if ($cfg.ShowDate) { $parts += "$(if (-not $short) { "$($emoji.Date) " })$(Get-Date -Format 'dd.MM.')" }
    if ($cfg.CountdownOn -and $cfg.CountdownTime -match '^(\d{1,2}):(\d{2})$') {
        $target = (Get-Date).Date.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2])
        if ($target -lt (Get-Date)) { $target = $target.AddDays(1) }
        $diff = $target - (Get-Date)
        $left = if ($diff.TotalHours -ge 1) { "{0}:{1:00} h" -f [int][Math]::Floor($diff.TotalHours), $diff.Minutes } else { "$([int][Math]::Ceiling($diff.TotalMinutes)) min" }
        $parts += "$($emoji.Hourglass) $($cfg.CountdownLabel) in $left".Replace('  ', ' ')
    }
    if ($cfg.Playtime) {
        try {
            $span = (Get-Date) - (Get-Process -Name VRChat | Select-Object -First 1).StartTime
            $parts += "$($emoji.Timer) {0}:{1:00} h" -f [int][Math]::Floor($span.TotalHours), $span.Minutes
        } catch {}
    }
    if ($cfg.InGameStatus) {
        $parts += if ([Native]::ForegroundProcessName() -eq 'VRChat') { "$($emoji.Game) Im Spiel" } else { "$($emoji.Pc) Am Desktop" }
    }
    if ($cfg.WorldInfo -and $sync.World) { $parts += "$($emoji.Globe) $(Limit $sync.World 24) ($($sync.Players))" }
    if ($cfg.WeatherOn -and $sync.Weather) { $parts += $sync.Weather }
    if ($cfg.PcStats -or $cfg.GpuStats) {
        $pc = @()
        if ($cfg.PcStats) {
            $cpu = [int](Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
            $os  = Get-CimInstance Win32_OperatingSystem
            $ram = [int](100 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize * 100)
            $pc += "CPU $cpu%"; $pc += "RAM $ram%"
        }
        if ($cfg.GpuStats -and $null -ne $st.Gpu) { $pc += "GPU $($st.Gpu)%" }
        if ($pc) { $parts += "$($emoji.Pc) $($pc -join ' ')" }
    }
    $idle = [Native]::IdleMinutes()
    if ($cfg.Afk) { $parts += "$($emoji.Afk) AFK" }
    elseif ($cfg.AutoAfk -and $idle -ge $cfg.AfkMinutes) { $parts += "$($emoji.Afk) AFK ($([int]$idle) min)" }
    # Mehrere Status-Texte mit ; getrennt -> wechseln alle 10 Sekunden
    $texts = @("$($cfg.StatusText)" -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($texts) { $parts += $texts[[int][Math]::Floor((Get-Date).TimeOfDay.TotalSeconds / 10) % $texts.Count] }
    ,$parts
}

# Rahmen, Deko und Zeichenlimit
function Finish-Text($lines) {
    $lines = @($lines | Where-Object { $null -ne $_ })
    if ($cfg.Stars) { $c = E 0x2605; $lines = $lines | ForEach-Object { if ($_) { "$c $_ $c" } else { $_ } } }
    elseif ($cfg.Deco -and $lines.Count -gt 0) { $lines[0] = "$($st.Deco) $($lines[0]) $($st.Deco)" }
    Limit (($lines -join "`n").Trim("`n")) 144   # VRChat-Limit
}

function Get-LyricDisplay([string]$line) {
    if ($cfg.LyricsSmallCaps) { To-SmallCaps $line } else { $line }
}
function Get-Translation([string]$line) {
    if (-not $cfg.Translate -or -not $lyr.Trans -or -not $line) { return $null }
    $t = $lyr.Trans[$line.Trim()]
    if ($t -and $t -ne $line.Trim()) { $t } else { $null }
}

# Zeilen mit Wichtigkeit (P). Passt nicht alles in die 144 Zeichen, fliegen zuerst die unwichtigsten
# Zeilen raus - Songzeile (90) und Lyrics (100) bleiben immer. Reicht das nicht, wird die Songzeile gekuerzt.
function Join-Lines($list) {
    $lines = @(foreach ($i in $list) { if ($cfg.Stars -and $i.T) { "$(E 0x2605) $($i.T) $(E 0x2605)" } else { $i.T } })
    if ($cfg.Deco -and -not $cfg.Stars -and $lines.Count -and $lines[0]) { $lines[0] = "$($st.Deco) $($lines[0]) $($st.Deco)" }
    ($lines -join "`n").Trim("`n")
}
function Fit-Lines($items) {
    $list = New-Object System.Collections.ArrayList
    foreach ($i in $items) { if ($null -ne $i.T) { [void]$list.Add($i) } }
    while ((Join-Lines $list).Length -gt 144) {
        $drop = $null
        foreach ($i in $list) { if ($i.P -lt 90 -and (-not $drop -or $i.P -le $drop.P)) { $drop = $i } }
        if (-not $drop) { break }
        $list.Remove($drop)
    }
    $over = (Join-Lines $list).Length - 144
    $song = $list | Where-Object { $_.P -eq 90 } | Select-Object -First 1
    if ($over -gt 0 -and $song) { $song.T = Limit $song.T ([Math]::Max(12, $song.T.Length - $over)) }
    Limit (Join-Lines $list) 144
}

function Build-ChatText($info) {
    $st.Scroll++
    if ($cfg.Compact) { return Build-CompactText $info }
    $showSong = Show-Song $info
    $lyricsOn = ($cfg.ShowLyrics -or $cfg.LyricsMode) -and $showSong -and $lyr.Lines -and $lyr.Key -eq $st.LastKey
    $hideTitle = $cfg.HideTitleAfterLyrics -and $lyricsOn -and ((Get-Date) - $st.ChangedAt).TotalSeconds -gt 10
    $items = New-Object System.Collections.ArrayList
    if ($showSong -and -not $hideTitle) { [void]$items.Add(@{ T = (Get-SongLine $info 60); P = 90 }) }

    if ($cfg.LyricsMode -and $lyricsOn) {
        # Karaoke: Song, aktuelle Zeile, darunter Uebersetzung oder naechste Zeile
        $pair = Find-LyricPair $info.Pos.TotalSeconds
        $st.LastLyric = $pair[0]
        $note = [string][char]0x266A
        $current = if ($pair[0]) { "$($emoji.Mic) $(Get-LyricDisplay $pair[0])" } else { "$note  $note  $note" }
        [void]$items.Add(@{ T = $current; P = 100 })
        $tr = Get-Translation $pair[0]
        if ($tr) { [void]$items.Add(@{ T = "$($emoji.Translate) $tr"; P = 60 }) }
        elseif ($pair[1]) { [void]$items.Add(@{ T = "$([char]0x203A) $(Get-LyricDisplay $pair[1])"; P = 50 }) }
        return Fit-Lines $items
    }

    $songLines = $items.Count
    if ($showSong) {
        if ($cfg.ShowAlbum -and $info.Album) { [void]$items.Add(@{ T = (Limit "$($emoji.Disc) $($info.Album)" 40); P = 30 }); $songLines++ }
        if ($cfg.ShowBar -and $info.Length.TotalSeconds -gt 0) { [void]$items.Add(@{ T = (Get-Bar $info); P = 50 }); $songLines++ }
    }
    $rest = New-Object System.Collections.ArrayList
    $status = Get-StatusParts $false
    if ($status) { [void]$rest.Add(@{ T = ($status -join $cfg.Separator); P = 40 }) }
    # Lyrics ganz unten, damit sie nicht zwischen festem Text stehen
    if ($lyricsOn) {
        $lyric = Find-Lyric $info.Pos.TotalSeconds
        $st.LastLyric = $lyric
        if ($lyric) {
            [void]$rest.Add(@{ T = "$($emoji.Mic) $(Get-LyricDisplay $lyric)"; P = 100 })
            $tr = Get-Translation $lyric
            if ($tr) { [void]$rest.Add(@{ T = "$($emoji.Translate) $tr"; P = 60 }) }
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
        if ($cfg.ShowBar -and $info.Length.TotalSeconds -gt 0) { $song += " $(Format-Time $info.Pos)/$(Format-Time $info.Length)" }
        $parts += $song
    }
    $parts += Get-StatusParts $true
    Finish-Text @($parts -join $cfg.Separator)
}

# ---------------- Lyrics (eigene Datei oder lrclib.net) ----------------
$lyr = @{ Key = $null; Lines = $null; Chorus = $null; Trans = $null; TransKey = $null }

function Get-LyricsFileName($info) {
    $name = "$($info.Artist) - $(Clean-Title $info.Title).lrc" -replace '[\\/:*?"<>|]', '_'
    Join-Path $sync.LyricsDir $name
}

function Set-LyricLines([string]$lrc) {
    $lyr.Lines = @(foreach ($l in ($lrc -split "`r?`n")) {
        if ($l -match '^\[(\d+):(\d+(?:\.\d+)?)\]\s*(.*)$') {
            [pscustomobject]@{ T = [int]$Matches[1] * 60 + [double]::Parse($Matches[2], [Globalization.CultureInfo]::InvariantCulture); L = $Matches[3].Trim() }
        }
    }) | Sort-Object T
    $lyr.Lines = @($lyr.Lines)
    # Refrain = Zeilen, die mehrfach vorkommen
    $lyr.Chorus = @{}
    $lyr.Lines | Where-Object { $_.L } | Group-Object { $_.L.ToLower() } | Where-Object { $_.Count -ge 2 } |
        ForEach-Object { $lyr.Chorus[$_.Name] = $true }
}

function Start-LyricsFetch($info) {
    $key = "$($info.Title)|$($info.Artist)"
    $lyr.Key = $key; $lyr.Lines = $null; $lyr.Trans = $null; $lyr.TransKey = $null
    $file = Get-LyricsFileName $info
    if (Test-Path $file) {
        Set-LyricLines (Get-Content $file -Raw -Encoding UTF8)
        $sync.LyricsStatus = "Eigene Lyrics"
        return
    }
    $sync.LyricsStatus = "Suche Lyrics..."
    $artist = ($info.Artist -split ',')[0].Trim()
    $url = "https://lrclib.net/api/search?track_name=$([uri]::EscapeDataString((Clean-Title $info.Title)))&artist_name=$([uri]::EscapeDataString($artist))"
    Start-Async 'lyrics' $key {
        param($u)
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8   # sonst wird aus "ß" ein "ÃŸ"
        $wc.Headers['User-Agent'] = 'SpotifyToVRChat'
        $data = $wc.DownloadString($u) | ConvertFrom-Json
        $data | Where-Object { $_.syncedLyrics } | Select-Object -First 1
    } $url
}

# Gibt $true zurueck, wenn gerade neue Lyrics angekommen sind
function Update-Lyrics($info) {
    $key = "$($info.Title)|$($info.Artist)"
    if ($key -ne $lyr.Key) { Start-LyricsFetch $info; return [bool]$lyr.Lines }
    $r = Receive-Async 'lyrics'
    if ($r -and $r.Tag -eq $lyr.Key) {
        $hit = $r.Result | Select-Object -First 1
        if ($hit -and $hit.syncedLyrics) {
            Set-LyricLines $hit.syncedLyrics
            $sync.LyricsStatus = "Gefunden"
            return $true
        }
        $sync.LyricsStatus = "Keine Lyrics gefunden"
    }
    # Uebersetzung nachladen
    if ($cfg.Translate -and $lyr.Lines -and $lyr.TransKey -ne "$($lyr.Key)|$($cfg.TranslateLang)" -and -not (Test-AsyncRunning 'translate')) {
        $lyr.TransKey = "$($lyr.Key)|$($cfg.TranslateLang)"
        $text = (@($lyr.Lines | Where-Object { $_.L } | ForEach-Object { $_.L }) | Select-Object -Unique) -join "`n"
        Start-Async 'translate' $lyr.TransKey {
            param($a)
            $wc = New-Object System.Net.WebClient
            $wc.Encoding = [System.Text.Encoding]::UTF8
            $wc.Headers['User-Agent'] = 'Mozilla/5.0'
            $u = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=$($a[1])&dt=t&q=$([uri]::EscapeDataString($a[0]))"
            $resp = $wc.DownloadString($u) | ConvertFrom-Json
            $map = @{}
            if ("$($resp[2])" -ne $a[1]) {
                foreach ($seg in $resp[0]) { if ($seg[1]) { $map[("$($seg[1])").Trim()] = ("$($seg[0])").Trim() } }
            }
            $map
        } @($text, $cfg.TranslateLang)
    }
    $t = Receive-Async 'translate'
    if ($t -and $t.Tag -eq $lyr.TransKey) { $lyr.Trans = $t.Result | Select-Object -First 1; return $true }
    $false
}

function Find-LyricPair([double]$seconds) {
    if (-not $lyr.Lines) { return ,@($null, $null) }
    $t = $seconds + 0.3 + [double]$cfg.LyricsOffset
    $idx = -1
    for ($i = 0; $i -lt $lyr.Lines.Count; $i++) { if ($lyr.Lines[$i].T -le $t) { $idx = $i } else { break } }
    $ok = { param($l) $l.L -and (-not $cfg.ChorusOnly -or $lyr.Chorus[$l.L.ToLower()]) }
    $current = if ($idx -ge 0 -and (& $ok $lyr.Lines[$idx])) { $lyr.Lines[$idx].L } else { $null }
    $next = $null
    for ($i = $idx + 1; $i -lt $lyr.Lines.Count; $i++) { if (& $ok $lyr.Lines[$i]) { $next = $lyr.Lines[$i].L; break } }
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
    $file = Get-ChildItem $dirLog -Filter 'output_log_*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $file) { return }
    if ($file.FullName -ne $vrLog.File) { $vrLog.File = $file.FullName; $vrLog.Pos = 0; $vrLog.Players.Clear() }
    if ($file.Length -le $vrLog.Pos) { return }
    $fs = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
    try {
        [void]$fs.Seek($vrLog.Pos, 'Begin')
        $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $chunk = $reader.ReadToEnd()
        $vrLog.Pos = $fs.Position
    } finally { $fs.Dispose() }
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

$udp = $null
function Send-Chatbox([string]$text) {
    $port = if ($sync.PortOverride) { $sync.PortOverride } else { [int]$cfg.OscPort }
    if (-not $udp -or $st.UdpTarget -ne "$($cfg.OscHost):$port") {
        if ($udp) { $udp.Close() }
        $script:udp = New-Object System.Net.Sockets.UdpClient
        $udp.Connect($cfg.OscHost, $port)
        $st.UdpTarget = "$($cfg.OscHost):$port"
    }
    # /chatbox/input <string> <true = sofort senden> <Benachrichtigungston ja/nein>
    $tags = if ($cfg.Sound -and $text) { ",sTT" } else { ",sTF" }
    # Diese zwei unsichtbaren Steuerzeichen am Ende lassen VRChat den dunklen Kasten weg
    if ($cfg.NoBackground -and $text) { $text = (Limit $text 142) + [char]0x03 + [char]0x1F }
    $packet = (Get-OscPaddedString "/chatbox/input") + (Get-OscPaddedString $tags) + (Get-OscPaddedString $text)
    [void]$udp.Send([byte[]]$packet, $packet.Length)
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
    LastKey = $null; Cleared = $true; Scroll = 0; ChangedAt = Get-Date; CoverKey = $null
    LastLyric = $null; LastSend = [DateTime]::MinValue; UdpTarget = $null; Deco = $decoChars[0]
    GenreEmoji = $null; Gpu = $null; LastVoice = [DateTime]::MinValue; ParamState = @{}
    WeatherCity = $null; WasSpeaking = $false; LastTick = [DateTime]::Now; StatsSaved = [DateTime]::Now; ListenerRetry = [DateTime]::MinValue
}
$minGap = 1.5   # Sekunden zwischen zwei Nachrichten, sonst sperrt VRChat die Chatbox kurz
$next = @{ Send = [DateTime]::MinValue; Info = [DateTime]::MinValue; World = [DateTime]::MinValue
           Weather = [DateTime]::MinValue; Heart = [DateTime]::MinValue; Gpu = [DateTime]::MinValue; VrCheck = [DateTime]::MinValue }

while (-not $sync.Exit) {
    try {
        $now = [DateTime]::Now

        # Knoepfe aus dem Panel / Tastenkuerzel / Avatar
        $cmd = $null
        while ($sync.Commands.TryDequeue([ref]$cmd)) {
            try { Invoke-MediaCommand $cmd } catch { Log-Error "Befehl $cmd : $_" }
            Start-Sleep -Milliseconds 200
            $sync.Dirty = $true
        }

        # VRChat laeuft?
        if ($now -ge $next.VrCheck) {
            $sync.VRChat = [bool](Get-Process -Name VRChat -ErrorAction SilentlyContinue)
            $next.VrCheck = $now.AddSeconds(2)
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
                    $st.Scroll = 0
                    $st.LastLyric = $null
                    $st.GenreEmoji = $null
                    $st.Deco = $decoChars[(Get-Random -Maximum $decoChars.Count)]
                    $sync.SongCount++
                    $sync.Genre = $null
                    $song = "$($info.Title) - $($info.Artist)"
                    if ($cfg.History) {
                        $line = "{0}`t{1}`t{2}`t{3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $info.Title, $info.Artist, [int]$info.Length.TotalSeconds
                        Add-Content $sync.HistoryPath $line -Encoding UTF8
                    }
                    $sync.SongEvent = $song
                    $sync.Cover = $null; $sync.CoverKey = "none|$key"; $st.CoverKey = $null
                    $sync.SendNow = $true
                    # Cover + Genre von iTunes
                    $query = @((($info.Artist -split ',')[0].Trim()), (Clean-Title $info.Title))
                    Start-Async 'itunes' $key {
                        param($q)
                        $artist = $q[0]; $title = $q[1]
                        $wc = New-Object System.Net.WebClient
                        $wc.Encoding = [System.Text.Encoding]::UTF8
                        $url = "https://itunes.apple.com/search?entity=song&limit=15&term=$([uri]::EscapeDataString("$artist $title"))"
                        $results = @(($wc.DownloadString($url) | ConvertFrom-Json).results)
                        # Nur Treffer vom richtigen Kuenstler - lieber kein Cover als ein falsches
                        $norm = { param($s) ("$s".ToLower() -replace '[^\p{L}\p{N}]', '') }
                        $a = & $norm $artist; $t = & $norm $title
                        $same = @($results | Where-Object { $n = & $norm $_.artistName; $n -and ($n.Contains($a) -or $a.Contains($n)) })
                        $hit = $same | Where-Object { (& $norm $_.trackName).StartsWith($t) -or $t.StartsWith((& $norm $_.trackName)) } | Select-Object -First 1
                        if (-not $hit) {
                            # Song nicht gefunden: kein Cover, aber das Genre des Kuenstlers
                            return [pscustomobject]@{ Bytes = $null; Genre = ($same | Select-Object -First 1).primaryGenreName }
                        }
                        $bytes = if ($hit.artworkUrl100) { $wc.DownloadData(($hit.artworkUrl100 -replace '100x100', '300x300')) } else { $null }
                        [pscustomobject]@{ Bytes = $bytes; Genre = $hit.primaryGenreName }
                    } $query
                }
                # Cover von Windows, falls der Player eins liefert
                if ($st.CoverKey -ne $key -and $info.Thumbnail) {
                    $bytes = try { Get-CoverBytes $info.Thumbnail } catch { $null }
                    if ($bytes -and $bytes.Length -gt 0) { $sync.Cover = $bytes; $sync.CoverKey = $key; $st.CoverKey = $key }
                }
            }
        }
        $info = $sync.Info

        # iTunes-Ergebnis
        $it = Receive-Async 'itunes'
        if ($it -and $it.Tag -eq $st.LastKey) {
            $res = $it.Result | Select-Object -First 1
            if ($res) {
                if ($res.Bytes -and $st.CoverKey -ne $st.LastKey) { $sync.Cover = [byte[]]$res.Bytes; $sync.CoverKey = $st.LastKey; $st.CoverKey = $st.LastKey }
                if ($res.Genre) {
                    $sync.Genre = $res.Genre
                    foreach ($k in $genreEmoji.Keys) { if ($res.Genre -match $k) { $st.GenreEmoji = $genreEmoji[$k]; break } }
                    if ($cfg.GenreEmoji) { $sync.SendNow = $true }
                }
            }
        }

        # Hoerzeit zaehlen
        if ($info -and $info.Playing) {
            $today = Get-Date -Format 'yyyy-MM-dd'
            $stats[$today] = [double]$stats[$today] + ($now - $st.LastTick).TotalSeconds
            $sync.ListenToday = $stats[$today]
        }
        $st.LastTick = $now
        if (($now - $st.StatsSaved).TotalSeconds -ge 60) { Save-Stats; $st.StatsSaved = $now }

        # Zusatz-Infos
        if ($cfg.WorldInfo -and $now -ge $next.World) { try { Update-WorldInfo } catch { Log-Error "VRChat-Log: $_" }; $next.World = $now.AddSeconds(2) }
        # Stadt geaendert -> 2 s nach dem letzten Tastendruck neu laden (nicht bei jedem Buchstaben)
        if ("$($cfg.WeatherCity)" -ne $st.WeatherCity) { $st.WeatherCity = "$($cfg.WeatherCity)"; $next.Weather = $now.AddSeconds(2); $sync.Weather = $null }
        if ($cfg.WeatherOn -and $cfg.WeatherCity -and $now -ge $next.Weather -and -not (Test-AsyncRunning 'weather')) {
            $next.Weather = $now.AddMinutes(15)
            Start-Async 'weather' '' {
                param($city)
                $wc = New-Object System.Net.WebClient
                $wc.Encoding = [System.Text.Encoding]::UTF8
                $g = ($wc.DownloadString("https://geocoding-api.open-meteo.com/v1/search?count=1&language=de&name=$([uri]::EscapeDataString($city))") | ConvertFrom-Json).results | Select-Object -First 1
                if (-not $g) { return "" }
                $w = ($wc.DownloadString("https://api.open-meteo.com/v1/forecast?latitude=$($g.latitude)&longitude=$($g.longitude)&current=temperature_2m,weather_code") | ConvertFrom-Json).current
                $c = [int]$w.weather_code
                $icon = if ($c -eq 0) { 0x2600 } elseif ($c -le 3) { 0x26C5 } elseif ($c -le 48) { 0x1F32B } elseif ($c -le 67) { 0x1F327 } elseif ($c -le 77) { 0x2744 } elseif ($c -le 82) { 0x1F326 } else { 0x26C8 }
                "$([char]::ConvertFromUtf32($icon)) $([Math]::Round([double]$w.temperature_2m))$([char]0x00B0)C"
            } $cfg.WeatherCity
        }
        $w = Receive-Async 'weather'
        if ($w) {
            $sync.Weather = "$($w.Result | Select-Object -First 1)"
            $sync.WeatherStatus = if ($sync.Weather) { "Aktuell: $($sync.Weather)" } else { "Stadt '$($cfg.WeatherCity)' nicht gefunden" }
            if (-not $sync.Weather) { $next.Weather = $now.AddMinutes(1) }   # bald nochmal versuchen
            $sync.SendNow = $true
        }

        if ($cfg.GpuStats -and $now -ge $next.Gpu -and -not (Test-AsyncRunning 'gpu')) {
            $next.Gpu = $now.AddSeconds(5)
            Start-Async 'gpu' '' {
                $sum = (Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like '*engtype_3D' } | Measure-Object UtilizationPercentage -Sum).Sum
                [int][Math]::Min(100, [double]$sum)
            } $null
        }
        $g = Receive-Async 'gpu'; if ($g) { $st.Gpu = $g.Result | Select-Object -First 1 }

        # Signale von VRChat (Sprechen, AFK, Avatar-Knoepfe)
        try { Update-Speaking } catch { Log-Error "Mikrofon: $_" }
        $speakingHide = $cfg.HideWhileSpeaking -and $sync.Speaking
        if ($speakingHide -ne $st.WasSpeaking) { $st.WasSpeaking = $speakingHide; $sync.SendNow = $true }

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
            $text = if (-not $cfg.Enabled -or $speakingHide) { "" } else { Build-ChatText $info }
            $sync.Text = $text

            if ($due) {
                $sync.SendNow = $false
                $next.Send = $now.AddSeconds([double]$cfg.Interval)
                if (-not $sync.VRChat) { $st.Cleared = $true }
                elseif ($text) { Send-Chatbox $text; $st.Cleared = $false; $st.LastSend = [DateTime]::Now }
                else { Clear-Chatbox }
            }
        }
    } catch {
        Log-Error "$_"
    }
    Start-Sleep -Milliseconds $(if (-not $sync.VRChat) { 400 } else { 100 })
}

# Beim Beenden: Statistik sichern, Chatbox leeren (ausser "stehen lassen" ist an)
Save-Stats
if ($sync.VRChat) { try { Send-Chatbox "" } catch {} }
if ($udp) { $udp.Close() }
