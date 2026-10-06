# Spotify -> VRChat Chatbox
# Zeigt den aktuell laufenden Spotify-Song in der VRChat-Chatbox an (via OSC).
# Panel: Doppelklick aufs Tray-Icon. Einstellungen in settings.json.
# Voraussetzung: In VRChat im Action Menu unter Options > OSC "Enabled" aktivieren.
#
# Dateien:  worker.ps1       Hintergrund-Thread (Spotify, Lyrics, OSC)
#           lang.ps1         Englische Texte fuers Panel
#           ui\*.xaml        Aussehen des Panels

param(
    [int]$Port = 0,          # nur zum Testen: anderen OSC-Port erzwingen
    [switch]$ShowPanel,
    [string]$Snapshot = ""   # Ordner: jede Seite als PNG speichern und beenden (fuer Screenshots im README)
)

# Nur eine Instanz gleichzeitig - ein zweiter Start oeffnet stattdessen das Panel der laufenden
$mutex = New-Object System.Threading.Mutex($false, "Global\SpotifyToVRChat")
$showEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', "Global\SpotifyToVRChat_Show")
if (-not $Snapshot -and -not $mutex.WaitOne(0)) { [void]$showEvent.Set(); exit }

Add-Type @"
using System; using System.Runtime.InteropServices; using System.Diagnostics; using System.Collections.Generic;
public static class Native {
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("shcore.dll")] static extern int SetProcessDpiAwareness(int v);
    public static void EnableDpi() {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch {}
        try { SetProcessDpiAwareness(2); } catch {}
    }
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static double IdleMinutes() {
        var i = new LASTINPUTINFO(); i.cbSize = (uint)Marshal.SizeOf(i);
        GetLastInputInfo(ref i);
        return ((uint)Environment.TickCount - i.dwTime) / 60000.0;
    }
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
    // Welches Programm ist gerade im Vordergrund? (fuer "Beim Sprechen ausblenden" nur in VRChat)
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public static string ForegroundProcessName() {
        uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        try { return Process.GetProcessById((int)pid).ProcessName; } catch { return ""; }
    }
    // Fensterrahmen von Windows 11: runde Ecken, dunkler Modus, Randfarbe
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int value, int size);
    public static void SetWindowFrame(IntPtr h, bool dark, int borderColorRef) {
        int v;
        try { v = 2; DwmSetWindowAttribute(h, 33, ref v, 4); } catch {}            // runde Ecken
        try { v = dark ? 1 : 0; DwmSetWindowAttribute(h, 20, ref v, 4); } catch {}  // dunkler Rahmen
        try { v = borderColorRef; DwmSetWindowAttribute(h, 34, ref v, 4); } catch {}
    }
}

// Lautstaerke einer einzelnen App (wie im Windows-Lautstaerkemixer)
public static class AppVolume {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator {}
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice dev);
    }
    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection { [PreserveSig] int GetCount(out int n); [PreserveSig] int Item(int i, out IMMDevice dev); }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice { [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); }
    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2 { int NotImpl1(); int NotImpl2(); [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator e); }
    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator { [PreserveSig] int GetCount(out int n); [PreserveSig] int GetSession(int i, out IAudioSessionControl2 s); }
    [ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2 {
        int N0(); int N1(); int N2(); int N3(); int N4(); int N5(); int N6(); int N7(); int N8();
        [PreserveSig] int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string s);
        [PreserveSig] int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string s);
        [PreserveSig] int GetProcessId(out uint pid);
    }
    [ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISimpleAudioVolume { [PreserveSig] int SetMasterVolume(float level, ref Guid ctx); [PreserveSig] int GetMasterVolume(out float level); }

    static List<ISimpleAudioVolume> Find(string processName) {
        var list = new List<ISimpleAudioVolume>();
        var pids = new HashSet<uint>();
        foreach (var p in Process.GetProcessesByName(processName)) pids.Add((uint)p.Id);
        if (pids.Count == 0) return list;
        var en = (IMMDeviceEnumerator)(new MMDeviceEnumerator());
        IMMDevice dev; if (en.GetDefaultAudioEndpoint(0, 1, out dev) != 0) return list;
        Guid iid = typeof(IAudioSessionManager2).GUID; object o;
        if (dev.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) return list;
        IAudioSessionEnumerator se; ((IAudioSessionManager2)o).GetSessionEnumerator(out se);
        int n; se.GetCount(out n);
        for (int i = 0; i < n; i++) {
            IAudioSessionControl2 c; se.GetSession(i, out c);
            uint pid; c.GetProcessId(out pid);
            if (pids.Contains(pid)) list.Add((ISimpleAudioVolume)c);
        }
        return list;
    }
    public static float Get(string processName) {
        try { foreach (var v in Find(processName)) { float f; v.GetMasterVolume(out f); return f; } } catch {}
        return -1;
    }
    public static void Set(string processName, float level) {
        try { var g = Guid.Empty; foreach (var v in Find(processName)) v.SetMasterVolume(level, ref g); } catch {}
    }

    // Lautester Pegel aller aktiven Mikrofone (0..1) - zum Erkennen, ob gerade gesprochen wird.
    // Alle, weil VRChat oft ein anderes Mikro nutzt als das Windows-Standardgeraet.
    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation { [PreserveSig] int GetPeakValue(out float peak); }
    static List<IAudioMeterInformation> mics;
    static DateTime micsAt;
    public static float MicLevel() {
        try {
            if (mics == null || (DateTime.Now - micsAt).TotalSeconds > 30) {   // regelmaessig neu holen, falls ein Mikro dazukommt
                mics = new List<IAudioMeterInformation>();
                var en = (IMMDeviceEnumerator)(new MMDeviceEnumerator());
                IMMDeviceCollection col; if (en.EnumAudioEndpoints(1, 1, out col) != 0) return -1;
                int n; col.GetCount(out n);
                for (int i = 0; i < n; i++) {
                    IMMDevice dev; col.Item(i, out dev);
                    Guid iid = typeof(IAudioMeterInformation).GUID; object o;
                    if (dev.Activate(ref iid, 23, IntPtr.Zero, out o) == 0) mics.Add((IAudioMeterInformation)o);
                }
                micsAt = DateTime.Now;
            }
            if (mics.Count == 0) return -1;
            float max = 0;
            foreach (var m in mics) { float p; if (m.GetPeakValue(out p) == 0 && p > max) max = p; }
            return max;
        } catch { mics = null; return -1; }
    }
    public static int MicCount() { MicLevel(); return mics == null ? 0 : mics.Count; }
}
"@
[Native]::EnableDpi()

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
# Musik im Mikrofon (eigene Audio-Engine, siehe MusicMic.cs)
try { Add-Type -Path (Join-Path $PSScriptRoot 'MusicMic.cs') } catch { }
$musicMicOk = [bool]('MusicMicAudio.MusicMic' -as [type])

$dir          = $PSScriptRoot
$programFiles = [Environment]::GetFolderPath('ProgramFiles').TrimEnd('\')
$dataDir      = if ($dir.TrimEnd('\').StartsWith($programFiles, [StringComparison]::OrdinalIgnoreCase)) { Join-Path $env:LOCALAPPDATA 'VRChatSpotify' } else { $dir }
$cfgPath      = Join-Path $dataDir "settings.json"
$historyPath  = Join-Path $dataDir "verlauf.txt"
$statsPath    = Join-Path $dataDir "statistik.json"
$lyricsDir    = Join-Path $dataDir "lyrics"
$cacheDir     = Join-Path $dataDir "cache"   # geladene Lyrics und Uebersetzungen
$startupLnk   = Join-Path ([Environment]::GetFolderPath('Startup')) "SpotifyToVRChat.lnk"
foreach ($folder in $dataDir, $lyricsDir, $cacheDir) { if (-not (Test-Path $folder)) { New-Item $folder -ItemType Directory | Out-Null } }

# ============================== EINSTELLUNGEN ==============================
function New-DefaultConfig {
    [ordered]@{
        Enabled = $true; Interval = 2; NoBackground = $true; Compact = $false; HideWhenPaused = $true; ChangeOnly = $false
        ShowTitle = $true; ShowArtist = $true; ArtistOwnLine = $false; ShowAlbum = $false; ShowBar = $true
        HideFeat = $false; HideBrackets = $false; MainArtistOnly = $false; HideAlbumIfTitle = $true
        IconStyle = 0; SmallCaps = $false; ArtistSuperscript = $false
        Remaining = $false; BarStyle = 1; BarLength = 10; Separator = " - "; BlankLine = $false
        ShowLyrics = $false; LyricsMode = $false; HideTitleAfterLyrics = $false; LyricsOffset = 0.0; Translate = $false; TranslateLang = "de"
        ShowClock = $false; Playtime = $false; WorldInfo = $false; Afk = $false; AutoAfk = $false; AfkMinutes = 5; StatusText = ""
        HideWhileSpeaking = $false; MicThreshold = 0.04
        Theme = "dark"; Accent = "#1ED760"; CoverColors = $true; ReduceMotion = $false; AlwaysOnTop = $false; AnyPlayer = $false
        OscHost = "127.0.0.1"; OscPort = 9000; Notify = $false; NotifyDesktop = $true; NotifyInVR = $true; PopupCoverBackground = $true; NotifyPosition = "bottom-right"; NotifyDuration = 5; History = $true; Language = "auto"
        ChatProfile = "custom"
        AvatarHeight = 1.6; CacheDays = 14
        MusicMic = $false; MusicMicVolume = 60; MicVoiceVolume = 100; MusicMicNormalize = $true; MusicMicDuck = $true; MusicMicVoice = $true; MusicMicDevice = ""; MusicMicCable = ""; MicGate = 50
    }
}
$cfg = New-DefaultConfig
function Import-ConfigValues($source) {
    # alte, entfernte Einstellungen werden einfach ignoriert
    foreach ($p in $source.PSObject.Properties) { if ($cfg.Contains($p.Name)) { $cfg[$p.Name] = $p.Value } }
}
if (Test-Path $cfgPath) { try { Import-ConfigValues (Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {} }
function Save-Config { if (-not $Snapshot) { $cfg | ConvertTo-Json -Depth 4 | Set-Content $cfgPath -Encoding UTF8 } }

# Sprache (Deutsch / Englisch)
. (Join-Path $dir "lang.ps1")
$lang = Resolve-Language $cfg.Language

# ============================== HINTERGRUND-THREAD ==============================
$sync = [hashtable]::Synchronized(@{
    Cfg = $cfg; Lang = $lang; HistoryPath = $historyPath; StatsPath = $statsPath; LyricsDir = $lyricsDir; CacheDir = $cacheDir; PortOverride = $Port
    Info = $null; SampleTime = [DateTime]::Now; Text = ""; VRChat = $false; OscOk = $null; SongCount = 0
    Cover = $null; CoverKey = $null; SongEvent = $null; Genre = $null; LyricsStatus = "-"
    World = $null; Players = 0; Speaking = $false; MicLevel = 0; ListenToday = 0.0; ErrorVersion = 0
    PauseUntil = [DateTime]::MinValue; TestResult = $null
    Dirty = $true; SendNow = $false; Exit = $false
    Commands = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    Errors   = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
})
if ($Snapshot) {
    # Screenshot-Modus: nichts an VRChat senden und keine echten Daten veraendern
    $sync.PortOverride = 9999
    $sync.HistoryPath = Join-Path $env:TEMP "svc_snapshot_verlauf.txt"
    $sync.StatsPath = Join-Path $env:TEMP "svc_snapshot_stats.json"
}

$rs = [runspacefactory]::CreateRunspace()
$rs.Open()
$rs.SessionStateProxy.SetVariable('sync', $sync)
$workerPs = [PowerShell]::Create()
$workerPs.Runspace = $rs
[void]$workerPs.AddScript((Get-Content (Join-Path $dir "worker.ps1") -Raw -Encoding UTF8))
$workerHandle = $workerPs.BeginInvoke()

# ============================== DESIGN ==============================
$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
$styles = [Windows.Markup.XamlReader]::Parse((Get-Content (Join-Path $dir "ui\styles.xaml") -Raw -Encoding UTF8))
$app.Resources.MergedDictionaries.Add($styles)

# Ruhige, feste Flaechen. Solid = fuer Dropdown-Listen und Tooltips.
$themes = @{
    dark  = @{ Bg = '#0A0A0D'; Side = '#0E0E12'; Card = '#141419'; Input = '#1C1C23'; Hover = '#26262F'; Text = '#F4F4F7'; Dim = '#8C8C99'; Border = '#1F1F27'; Solid = '#1C1C23' }
    light = @{ Bg = '#F4F4F7'; Side = '#FBFBFD'; Card = '#FFFFFF'; Input = '#EEEEF2'; Hover = '#E3E3EA'; Text = '#131318'; Dim = '#6B6B78'; Border = '#E4E4EA'; Solid = '#FFFFFF' }
}
$accents = [ordered]@{ 'Grün' = '#1ED760'; 'Rot' = '#FF3355'; 'Lila' = '#8B5CF6'; 'Blau' = '#3B82F6'; 'Pink' = '#EC4899'; 'Orange' = '#F97316'; 'Türkis' = '#14B8A6'; 'Gold' = '#EAB308' }
$bc = New-Object System.Windows.Media.BrushConverter
function New-Brush([string]$hex) { $b = $bc.ConvertFromString($hex); $b.Freeze(); $b }
$warnBrush = New-Brush '#F59E0B'

function Apply-Theme {
    $t = $themes["$($cfg.Theme)"]; if (-not $t) { $t = $themes.dark }
    foreach ($k in $t.Keys) { $app.Resources["C.$k"] = New-Brush $t[$k] }
    Update-Accent 0
    Update-WindowFrame
}

# ---------- Farben vom Song ----------
# $live: Farbe + Helligkeit des aktuellen Covers (oder $null). Die Akzentfarbe der App folgt dem Song, wenn eingeschaltet.
$live = @{ Accent = $null; Lum = $null }
function Get-ActiveAccent { if ($cfg.CoverColors -and $live.Accent) { $live.Accent } else { "$($cfg.Accent)" } }

# Pinsel in den App-Ressourcen weich auf eine neue Farbe ueberblenden (alle Stellen mit dieser Farbe aendern sich mit).
# App-Ressourcen muessen "eingefroren" sein, deshalb kein echtes WPF-Farb-Animieren: ein kurzer Timer setzt die Zwischenfarben.
# ::new statt New-Object: New-Object verpackt das Ergebnis, und so verpackt versteht WPF den Pinsel nicht
function New-ColorBrush([System.Windows.Media.Color]$c) { $b = [System.Windows.Media.SolidColorBrush]::new($c); $b.Freeze(); $b }
$colorFade = @{ Items = @{}; Timer = $null }
function Set-ResourceColor([string]$key, [System.Windows.Media.Color]$color, [int]$ms) {
    $cur = $app.Resources[$key]
    if ($ms -le 0 -or $cfg.ReduceMotion -or -not ($cur -is [System.Windows.Media.SolidColorBrush])) {
        $colorFade.Items.Remove($key); $app.Resources[$key] = New-ColorBrush $color; return
    }
    $colorFade.Items[$key] = @{ From = $cur.Color; To = $color; Start = [DateTime]::Now; Ms = $ms }
    if (-not $colorFade.Timer) {
        $colorFade.Timer = New-Object System.Windows.Threading.DispatcherTimer
        $colorFade.Timer.Interval = [TimeSpan]::FromMilliseconds(33)
        $colorFade.Timer.add_Tick({
            foreach ($k in @($colorFade.Items.Keys)) {
                $it = $colorFade.Items[$k]
                $t = [Math]::Min(1, ([DateTime]::Now - $it.Start).TotalMilliseconds / $it.Ms)
                $e = 1 - [Math]::Pow(1 - $t, 3)   # weich auslaufen
                $f = $it.From; $to = $it.To
                $c = [System.Windows.Media.Color]::FromArgb([byte]($f.A + ($to.A - $f.A) * $e), [byte]($f.R + ($to.R - $f.R) * $e), [byte]($f.G + ($to.G - $f.G) * $e), [byte]($f.B + ($to.B - $f.B) * $e))
                $app.Resources[$k] = New-ColorBrush $c
                if ($t -ge 1) { $colorFade.Items.Remove($k) }
            }
            if (-not $colorFade.Items.Count) { $this.Stop() }
        })
    }
    $colorFade.Timer.Start()
}

function Update-Accent([int]$ms = 0) {
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString((Get-ActiveAccent))
    Set-ResourceColor 'C.Accent' $c $ms
    $soft = $c; $soft.A = 0x33; Set-ResourceColor 'C.AccentSoft' $soft $ms
    # Schrift auf der Akzentfarbe: schwarz auf hellen, weiss auf dunklen Farben
    $lum = (0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B) / 255
    $app.Resources['C.AccentText'] = New-Brush $(if ($lum -gt 0.62) { '#000000' } else { '#FFFFFF' })
}

# Kraeftigste Farbe eines Covers finden (wie Apple Music) und so anpassen, dass sie im Design gut lesbar ist.
# Gibt @{ Accent = '#RRGGBB' oder $null (graues/schwarzes Cover); Lum = mittlere Helligkeit 0..1 } zurueck.
function Get-CoverPalette([byte[]]$bytes) {
    $img = New-CoverImage $bytes 32
    $bmp = New-Object System.Windows.Media.Imaging.FormatConvertedBitmap($img, [System.Windows.Media.PixelFormats]::Bgra32, $null, 0)
    $w = $bmp.PixelWidth; $h = $bmp.PixelHeight
    $px = New-Object byte[] ($w * $h * 4)
    $bmp.CopyPixels($px, $w * 4, 0)
    $buckets = @{}; $lumSum = 0.0; $n = 0
    for ($i = 0; $i -lt $px.Length; $i += 4) {
        $col = [System.Drawing.Color]::FromArgb($px[$i + 2], $px[$i + 1], $px[$i])
        $lumSum += (0.299 * $col.R + 0.587 * $col.G + 0.114 * $col.B) / 255; $n++
        $s = $col.GetSaturation(); $l = $col.GetBrightness()
        if ($s -lt 0.28 -or $l -lt 0.12 -or $l -gt 0.9) { continue }   # grau, fast schwarz oder fast weiss zaehlt nicht
        $k = [int][Math]::Floor($col.GetHue() / 20)
        $wgt = $s * (1 - [Math]::Abs($l - 0.5))
        if (-not $buckets[$k]) { $buckets[$k] = @{ W = 0.0; H = 0.0; S = 0.0 } }
        $buckets[$k].W += $wgt; $buckets[$k].H += $col.GetHue() * $wgt; $buckets[$k].S += $s * $wgt
    }
    $lumAvg = if ($n) { $lumSum / $n } else { 0.3 }
    $best = $buckets.Values | Sort-Object { $_.W } -Descending | Select-Object -First 1
    if (-not $best -or $best.W -lt $n * 0.04) { return @{ Accent = $null; Lum = $lumAvg } }
    # Lesbar machen: kraeftig genug und passende Helligkeit fuer das Design
    $hue = $best.H / $best.W
    $sat = [Math]::Min(0.9, [Math]::Max(0.55, $best.S / $best.W))
    $lig = if ("$($cfg.Theme)" -eq 'light') { 0.42 } else { 0.6 }
    @{ Accent = (ConvertFrom-Hsl $hue $sat $lig); Lum = $lumAvg }
}
function ConvertFrom-Hsl([double]$h, [double]$s, [double]$l) {
    $c = (1 - [Math]::Abs(2 * $l - 1)) * $s
    $x = $c * (1 - [Math]::Abs((($h / 60) % 2) - 1))
    $m = $l - $c / 2
    $rgb = switch ([int][Math]::Floor($h / 60) % 6) { 0 { $c, $x, 0 } 1 { $x, $c, 0 } 2 { 0, $c, $x } 3 { 0, $x, $c } 4 { $x, 0, $c } default { $c, 0, $x } }
    '#{0:X2}{1:X2}{2:X2}' -f [int](($rgb[0] + $m) * 255), [int](($rgb[1] + $m) * 255), [int](($rgb[2] + $m) * 255)
}

# Windows-11-Rahmen passend zum Design (runde Ecken, Randfarbe)
function Update-WindowFrame {
    if (-not (Get-Variable window -ErrorAction SilentlyContinue) -or -not $window) { return }
    $h = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
    if ($h -eq [IntPtr]::Zero) { return }
    $t = $themes["$($cfg.Theme)"]; if (-not $t) { $t = $themes.dark }
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($t.Border)
    [Native]::SetWindowFrame($h, "$($cfg.Theme)" -ne 'light', ([int]$c.B -shl 16) -bor ([int]$c.G -shl 8) -bor [int]$c.R)
}

[xml]$panelXml = Get-Content (Join-Path $dir "ui\panel.xaml") -Raw -Encoding UTF8
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $panelXml))
$appIconPath = Join-Path $dir 'assets\app.ico'
if (Test-Path $appIconPath) {
    $appIcon = New-Object System.Windows.Media.Imaging.BitmapImage
    $appIcon.BeginInit(); $appIcon.UriSource = New-Object System.Uri($appIconPath); $appIcon.CacheOption = 'OnLoad'; $appIcon.EndInit(); $appIcon.Freeze()
    $window.Icon = $appIcon
}
$ui = @{}
$panelXml.SelectNodes("//*[@*[local-name()='Name']]") | ForEach-Object {
    $n = ($_.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1).Value
    $ui[$n] = $window.FindName($n)
}
$window.add_SourceInitialized({ Update-WindowFrame })
Apply-Theme

$state = @{
    Exiting = $false; Refreshing = $false; VolSync = $false; Page = $null; Title = $null; CoverKey = $null
    ScrollHome = 0; LastVol = [DateTime]::MinValue; StatsRange = 7; ErrCount = -1; PausedShown = $false; TestAt = $null
    Playing = $null; Connected = $null; CacheVer = 0; PopClosed = $null
}

# ============================== ANIMATIONEN ==============================
$ease = New-Object System.Windows.Media.Animation.CubicEase
$ease.EasingMode = 'EaseOut'; $ease.Freeze()
# Eigenschaft weich auf einen Wert animieren ($from = $null: vom aktuellen Wert aus)
function Animate($target, $property, $to, [int]$ms = 250, $from = $null) {
    if ($cfg.ReduceMotion -or $ms -le 0) {
        $target.BeginAnimation($property, $null)
        $target.SetValue($property, $to)
        return
    }
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    if ($null -ne $from) { $a.From = $from }
    $a.To = $to
    $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($ms))
    $a.EasingFunction = $ease
    $target.BeginAnimation($property, $a)
}
# Einblenden mit kleinem Ruck nach oben (Seitenwechsel, neuer Song)
function Animate-In($element, [double]$offset = 14, [int]$ms = 320) {
    if (-not ($element.RenderTransform -is [System.Windows.Media.TranslateTransform])) { $element.RenderTransform = New-Object System.Windows.Media.TranslateTransform }
    Animate $element ([System.Windows.UIElement]::OpacityProperty) 1 ([int]($ms * 0.8)) 0
    Animate $element.RenderTransform ([System.Windows.Media.TranslateTransform]::YProperty) 0 $ms $offset
}
# Endlos-Animation (z. B. Equalizer), laeuft nur, wenn sie gebraucht wird
function New-Loop($target, $property, [double]$from, [double]$to, [int]$ms) {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.From = $from; $a.To = $to; $a.AutoReverse = $true
    $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($ms))
    $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $a.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($a, 30)   # schont die CPU
    @{ Target = $target; Property = $property; Anim = $a; Running = $false }
}
function Set-Loop($loop, [bool]$run) {
    if ($cfg.ReduceMotion) { $run = $false }
    if ($loop.Running -eq $run) { return }
    $loop.Running = $run
    if ($run) { $loop.Target.BeginAnimation($loop.Property, $loop.Anim) }
    else { Animate $loop.Target $loop.Property 1 300 }
}

# ============================== BAUSTEINE ==============================
$bound = New-Object System.Collections.ArrayList   # alle Einstellungs-Elemente, fuer Import/Reset und doppelte Schalter
$script:chatProfileKeys = @('Compact', 'ShowTitle', 'ShowArtist', 'ArtistOwnLine', 'ShowAlbum', 'ShowBar', 'ShowLyrics', 'LyricsMode', 'HideTitleAfterLyrics', 'SmallCaps', 'ShowClock', 'BlankLine')
function Mark-ChatProfileCustom([string]$key) {
    if ($key -notin $script:chatProfileKeys -or $cfg.ChatProfile -eq 'custom') { return }
    $cfg.ChatProfile = 'custom'
    Sync-Bound 'ChatProfile' $null
}

function New-Text([string]$text, [double]$size = 13, [string]$color = 'C.Text', [string]$weight = 'Normal') {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = T $text; $t.FontSize = $size; $t.FontWeight = $weight; $t.TextWrapping = 'Wrap'
    $t.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $color)
    $t
}
function New-Margin($l, $t, $r, $b) { New-Object System.Windows.Thickness($l, $t, $r, $b) }
function Icon([int]$code) { [string][char]$code }

# Farbige Icon-Kacheln wie in den iOS-Einstellungen
$iosColors = @{
    red = '#FF453A'; orange = '#FF9F0A'; yellow = '#E6B800'; green = '#30D158'; teal = '#32ADE6'
    blue = '#0A84FF'; indigo = '#5E5CE6'; purple = '#BF5AF2'; pink = '#FF375F'; gray = '#8E8E93'
}
# Dezent eingefaerbt (Symbol in Farbe auf leicht getoentem Grund) statt knalliger Vollfarbe
function New-IconTile([int]$code, [string]$color) {
    $hex = "$(if ($iosColors[$color]) { $iosColors[$color] } else { $color })".TrimStart('#')
    $b = New-Object System.Windows.Controls.Border
    $b.Width = 30; $b.Height = 30; $b.CornerRadius = 9; $b.Margin = New-Margin 0 0 13 0; $b.VerticalAlignment = 'Center'
    $b.Background = New-Brush "#2E$hex"
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = Icon $code; $t.FontFamily = $app.Resources['Icons']; $t.FontSize = 14; $t.Foreground = New-Brush "#$hex"
    $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'
    $b.Child = $t
    $b
}
# Icon + Titel (+ Beschreibung) nebeneinander
function New-RowLabel([string]$label, [string]$desc = "", [int]$icon = 0, [string]$color = 'blue') {
    # Grid statt StackPanel: so bekommt der Text eine feste Breite und bricht sauber um
    $g = New-Object System.Windows.Controls.Grid
    foreach ($w in 'Auto', '*') {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = if ($w -eq '*') { New-Object System.Windows.GridLength(1, 'Star') } else { [System.Windows.GridLength]::Auto }
        [void]$g.ColumnDefinitions.Add($cd)
    }
    if ($icon) { [void]$g.Children.Add((New-IconTile $icon $color)) }
    $txt = New-Object System.Windows.Controls.StackPanel; $txt.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($txt, 1)
    [void]$txt.Children.Add((New-Text $label 13.5))
    if ($desc) { $d = New-Text $desc 11.5 'C.Dim'; $d.Margin = New-Margin 0 2 0 0; [void]$txt.Children.Add($d) }
    [void]$g.Children.Add($txt)
    $g
}
# Klickbare Zeile (iOS-Einstellungen): Icon, Text, Pfeil. -Danger = rote Schrift fuer z. B. "Beenden"
$dangerBrush = New-Brush '#FF453A'
function Add-ActionRow($panel, [string]$label, [scriptblock]$onClick, [int]$icon = 0, [string]$color = 'blue', [string]$desc = "", [switch]$Danger) {
    Add-Divider $panel ([bool]$icon)
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $app.Resources['RowBtn']
    $b.Content = New-RowLabel $label $desc $icon $color
    if ($Danger) { $b.Content.Children[$b.Content.Children.Count - 1].Children[0].Foreground = $dangerBrush }
    $b.add_Click($onClick)
    [void]$panel.Children.Add($b)
    $b
}
# Duenne Trennlinie zwischen zwei Zeilen einer Karte
function Add-Divider($panel, [bool]$inset = $true) {
    if ($panel.Children.Count -eq 0) { return }
    $b = New-Object System.Windows.Controls.Border
    $b.Height = 1; $b.Margin = New-Margin $(if ($inset) { 43 } else { 0 }) 0 0 0
    $b.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'C.Border')
    [void]$panel.Children.Add($b)
}

$pages = @{}
function New-Page([string]$key) {
    $sv = New-Object System.Windows.Controls.ScrollViewer
    $sv.VerticalScrollBarVisibility = 'Auto'; $sv.Visibility = 'Collapsed'
    $sv.RenderTransform = New-Object System.Windows.Media.TranslateTransform
    $root = New-Object System.Windows.Controls.StackPanel
    $root.Margin = New-Margin 32 4 24 28
    $full = New-Object System.Windows.Controls.StackPanel
    $grid = New-Object System.Windows.Controls.Grid
    foreach ($w in @(1, 18, 1)) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = if ($w -eq 18) { New-Object System.Windows.GridLength 18 } else { New-Object System.Windows.GridLength(1, 'Star') }
        [void]$grid.ColumnDefinitions.Add($cd)
    }
    $left = New-Object System.Windows.Controls.StackPanel
    $right = New-Object System.Windows.Controls.StackPanel
    [System.Windows.Controls.Grid]::SetColumn($right, 2)
    [void]$grid.Children.Add($left); [void]$grid.Children.Add($right)
    [void]$root.Children.Add($full); [void]$root.Children.Add($grid)
    $sv.Content = $root
    [void]$ui.Pages.Children.Add($sv)
    $p = @{ Root = $sv; Full = $full; Left = $left; Right = $right }
    $pages[$key] = $p
    $p
}

# Gruppe im iOS-Stil: kleine Ueberschrift ueber der Karte, Hinweis darunter. Gibt den Inhaltsbereich zurueck.
function New-Section($parent, [string]$title, [string]$footer = "") {
    $wrap = New-Object System.Windows.Controls.StackPanel
    $wrap.Margin = New-Margin 0 0 0 20
    if ($title) {
        $h = New-Text "" 11.5 'C.Dim' 'SemiBold'; $h.Text = (T $title).ToUpper(); $h.Margin = New-Margin 6 0 0 8
        [void]$wrap.Children.Add($h)
    }
    $card = New-Object System.Windows.Controls.Border
    $card.Style = $app.Resources['Card']; $card.Padding = New-Margin 18 6 18 6; $card.Margin = New-Margin 0
    $body = New-Object System.Windows.Controls.StackPanel
    $card.Child = $body
    [void]$wrap.Children.Add($card)
    if ($footer) { $f = New-Text $footer 11.5 'C.Dim'; $f.Margin = New-Margin 6 8 6 0; [void]$wrap.Children.Add($f) }
    [void]$parent.Children.Add($wrap)
    $body
}

# Alle anderen Elemente mit derselben Einstellung nachziehen
function Sync-Bound([string]$key, $except) {
    $state.Refreshing = $true
    foreach ($b in $bound) {
        if ($b.Key -ne $key -or $b.Control -eq $except) { continue }
        switch ($b.Type) {
            'switch' { $b.Control.IsChecked = [bool]$cfg[$key] }
            'pill'   { $b.Control.IsChecked = ("$($cfg[$key])" -eq "$($b.Value)") }
        }
    }
    $state.Refreshing = $false
}

function Add-Switch($panel, [string]$label, [string]$key, [string]$desc = "", [scriptblock]$after = $null, [int]$icon = 0, [string]$color = 'blue') {
    Add-Divider $panel ([bool]$icon)
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Style = $app.Resources['Switch']
    $cb.Content = New-RowLabel $label $desc $icon $color
    $cb.Tag = @{ Key = $key; After = $after }
    $cb.IsChecked = [bool]$cfg[$key]
    $cb.add_Click({
        if ($state.Refreshing) { return }
        $cfg[$this.Tag.Key] = [bool]$this.IsChecked
        Mark-ChatProfileCustom $this.Tag.Key
        Save-Config; $sync.Dirty = $true; $sync.SendNow = $true
        Sync-Bound $this.Tag.Key $this
        if ($this.Tag.After) { & $this.Tag.After }
    })
    [void]$panel.Children.Add($cb)
    [void]$bound.Add(@{ Type = 'switch'; Control = $cb; Key = $key })
}

# Segment-Leiste (iOS): $options = @( @("Text", Wert), ... ). Der farbige Hintergrund gleitet zur Auswahl.
# $onSelect bekommt den Wert in $this.Tag.Value
function New-Segmented($options, $selected, [scriptblock]$onSelect, [string]$group, [switch]$NoTranslate) {
    $track = New-Object System.Windows.Controls.Border
    $track.CornerRadius = 10; $track.Padding = New-Margin 3 3 3 3
    $track.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'C.Input')
    $grid = New-Object System.Windows.Controls.Grid
    $thumb = New-Object System.Windows.Controls.Border
    $thumb.CornerRadius = 8; $thumb.HorizontalAlignment = 'Left'
    $thumb.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'C.Accent')
    $thumb.RenderTransform = New-Object System.Windows.Media.TranslateTransform
    $ug = New-Object System.Windows.Controls.Primitives.UniformGrid; $ug.Rows = 1; $ug.Columns = @($options).Count
    [void]$grid.Children.Add($thumb); [void]$grid.Children.Add($ug)
    $info = @{ Thumb = $thumb; Count = @($options).Count; Buttons = New-Object System.Collections.ArrayList }
    $grid.Tag = $info
    $i = 0
    foreach ($o in $options) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.Style = $app.Resources['Seg']
        $rb.GroupName = $group
        $rb.Content = if ($o[0] -is [string] -and -not $NoTranslate) { T $o[0] } else { $o[0] }
        $rb.Tag = @{ Value = $o[1]; Index = $i; Info = $info; OnSelect = $onSelect }
        $rb.IsChecked = ("$selected" -eq "$($o[1])")
        $rb.add_Checked({
            $w = $this.Tag.Info.Thumb.Width
            if ($w -gt 0) { Animate $this.Tag.Info.Thumb.RenderTransform ([System.Windows.Media.TranslateTransform]::XProperty) ($this.Tag.Index * $w) 280 }
            if ($this.Tag.OnSelect) { & $this.Tag.OnSelect }
        })
        [void]$ug.Children.Add($rb); [void]$info.Buttons.Add($rb)
        $i++
    }
    # Breite des Hintergrunds an die Leiste anpassen (auch beim Vergroessern des Fensters)
    $grid.add_SizeChanged({
        $inf = $this.Tag
        $w = $this.ActualWidth / $inf.Count
        $inf.Thumb.Width = $w
        $sel = 0; foreach ($b in $inf.Buttons) { if ($b.IsChecked) { $sel = $b.Tag.Index } }
        $inf.Thumb.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
        $inf.Thumb.RenderTransform.X = $sel * $w
    })
    $track.Child = $grid
    @{ Element = $track; Buttons = $info.Buttons }
}

# Einstellung als Segment-Leiste in einer Karte
function Add-Segment($panel, [string]$label, [string]$key, $options, [scriptblock]$after = $null, [int]$icon = 0, [string]$color = 'blue', [string]$desc = "", [switch]$NoTranslate) {
    Add-Divider $panel ([bool]$icon)
    $row = New-Object System.Windows.Controls.StackPanel; $row.Margin = New-Margin 0 11 0 12
    if ($label) { $l = New-RowLabel $label $desc $icon $color; $l.Margin = New-Margin 0 0 0 10; [void]$row.Children.Add($l) }
    $seg = New-Segmented $options $cfg[$key] {
        if ($state.Refreshing) { return }
        $cfg[$this.Tag.Key] = $this.Tag.Value
        Mark-ChatProfileCustom $this.Tag.Key
        Save-Config; $sync.Dirty = $true; $sync.SendNow = $true
        if ($this.Tag.After) { & $this.Tag.After }
    } "$key$($panel.GetHashCode())" -NoTranslate:$NoTranslate
    foreach ($b in $seg.Buttons) {
        $b.Tag.Key = $key; $b.Tag.After = $after
        [void]$bound.Add(@{ Type = 'pill'; Control = $b; Key = $key; Value = $b.Tag.Value })
    }
    [void]$row.Children.Add($seg.Element)
    [void]$panel.Children.Add($row)
}

# Dropdown rechts in der Zeile: $options = @( @("Text", Wert), ... )
function Add-Dropdown($panel, [string]$label, [string]$key, $options, [int]$icon = 0, [string]$color = 'blue', [string]$desc = "", [scriptblock]$after = $null) {
    Add-Divider $panel ([bool]$icon)
    $g = New-Object System.Windows.Controls.Grid; $g.Margin = New-Margin 0 9 0 9
    [void]$g.Children.Add((New-RowLabel $label $desc $icon $color))
    $cb = New-Object System.Windows.Controls.ComboBox
    $cb.Width = 210; $cb.HorizontalAlignment = 'Right'; $cb.VerticalAlignment = 'Center'
    foreach ($o in $options) {
        $it = New-Object System.Windows.Controls.ComboBoxItem
        $it.Content = $o[0]; $it.Tag = $o[1]
        [void]$cb.Items.Add($it)
        if ("$($cfg[$key])" -eq "$($o[1])") { $cb.SelectedItem = $it }
    }
    $cb.Tag = @{ Key = $key; After = $after }
    $cb.add_SelectionChanged({
        if ($state.Refreshing -or -not $this.SelectedItem) { return }
        $cfg[$this.Tag.Key] = $this.SelectedItem.Tag
        Save-Config; $sync.Dirty = $true; $sync.SendNow = $true
        if ($this.Tag.After) { & $this.Tag.After }
    })
    [void]$g.Children.Add($cb)
    [void]$panel.Children.Add($g)
    [void]$bound.Add(@{ Type = 'combo'; Control = $cb; Key = $key })
}

function Add-Slider($panel, [string]$label, [string]$key, [double]$min, [double]$max, [double]$step, [string]$unit, [int]$icon = 0, [string]$color = 'blue', [string]$fmt = '{0:+0.0;-0.0;0.0}', [scriptblock]$after = $null) {
    Add-Divider $panel ([bool]$icon)
    $wrap = New-Object System.Windows.Controls.StackPanel; $wrap.Margin = New-Margin 0 11 0 12
    $head = New-Object System.Windows.Controls.Grid
    [void]$head.Children.Add((New-RowLabel $label "" $icon $color))
    $val = New-Text "" 13 'C.Accent' 'Bold'; $val.HorizontalAlignment = 'Right'; $val.VerticalAlignment = 'Center'
    [void]$head.Children.Add($val)
    [void]$wrap.Children.Add($head)
    $s = New-Object System.Windows.Controls.Slider
    $s.Minimum = $min; $s.Maximum = $max; $s.SmallChange = $step; $s.TickFrequency = $step; $s.IsSnapToTickEnabled = $true
    $s.Margin = New-Margin 0 10 0 0
    $s.Value = [double]$cfg[$key]
    $s.Tag = @{ Key = $key; Label = $val; Unit = $unit; Fmt = $fmt; After = $after }
    $val.Text = ("$fmt $unit" -f $s.Value)
    $s.add_ValueChanged({
        $this.Tag.Label.Text = ("$($this.Tag.Fmt) $($this.Tag.Unit)" -f $this.Value)
        if ($state.Refreshing) { return }
        $cfg[$this.Tag.Key] = [Math]::Round($this.Value, 2)
        Save-Config; $sync.Dirty = $true
        if ($this.Tag.After) { & $this.Tag.After }
    })
    [void]$wrap.Children.Add($s)
    [void]$panel.Children.Add($wrap)
    [void]$bound.Add(@{ Type = 'slider'; Control = $s; Key = $key })
}

function Add-TextSetting($panel, [string]$label, [string]$key, [string]$hint = "", [int]$icon = 0, [string]$color = 'blue') {
    Add-Divider $panel ([bool]$icon)
    $wrap = New-Object System.Windows.Controls.StackPanel; $wrap.Margin = New-Margin 0 11 0 12
    if ($label) { $l = New-RowLabel $label "" $icon $color; $l.Margin = New-Margin 0 0 0 9; [void]$wrap.Children.Add($l) }
    $tb = New-Object System.Windows.Controls.TextBox
    $tb.Text = "$($cfg[$key])"; $tb.Tag = $key
    $tb.add_TextChanged({ if (-not $state.Refreshing) { $cfg[$this.Tag] = $this.Text; Save-Config; $sync.Dirty = $true } })
    [void]$wrap.Children.Add($tb)
    if ($hint) { $h = New-Text $hint 11.5 'C.Dim'; $h.Margin = New-Margin 0 6 0 0; [void]$wrap.Children.Add($h) }
    [void]$panel.Children.Add($wrap)
    [void]$bound.Add(@{ Type = 'text'; Control = $tb; Key = $key })
    $tb
}

function Add-Button($panel, [string]$text, [scriptblock]$onClick, [switch]$Accent, [string]$icon = "") {
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $app.Resources[$(if ($Accent) { 'AccentBtn' } else { 'Btn' })]
    if ($icon) {
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
        $i = New-Object System.Windows.Controls.TextBlock
        $i.Text = $icon; $i.FontFamily = $app.Resources['Icons']; $i.FontSize = 13; $i.Margin = New-Margin 0 1 8 0; $i.VerticalAlignment = 'Center'
        [void]$sp.Children.Add($i)
        $t = New-Object System.Windows.Controls.TextBlock; $t.Text = T $text; $t.VerticalAlignment = 'Center'
        [void]$sp.Children.Add($t)
        $b.Content = $sp
    } else { $b.Content = T $text }
    $b.add_Click($onClick)
    [void]$panel.Children.Add($b)
    $b
}
# Knopf-Reihe in einer Karte
function New-Row($parent) {
    $w = New-Object System.Windows.Controls.WrapPanel; $w.Margin = New-Margin 0 12 0 4
    [void]$parent.Children.Add($w); $w
}
function Add-Hint($parent, [string]$text = "") { $h = New-Text $text 11.5 'C.Dim'; $h.Margin = New-Margin 0 4 0 10; [void]$parent.Children.Add($h); $h }

# Kleine Info-Kachel; gibt das Wert-Textfeld zurueck
function New-Tile($parent, [string]$label, [int]$icon, [string]$color) {
    $card = New-Object System.Windows.Controls.Border
    $card.Style = $app.Resources['Card']; $card.Padding = New-Margin 18 15 18 15; $card.Margin = New-Margin 0 0 14 14
    $sp = New-Object System.Windows.Controls.StackPanel
    $h = New-Object System.Windows.Controls.StackPanel; $h.Orientation = 'Horizontal'
    $ib = New-IconTile $icon $color; $ib.Width = 26; $ib.Height = 26; $ib.CornerRadius = 7; $ib.Margin = New-Margin 0 0 9 0
    $lbl = New-Text $label 12 'C.Dim'; $lbl.VerticalAlignment = 'Center'
    [void]$h.Children.Add($ib); [void]$h.Children.Add($lbl)
    $v = New-Text "-" 17 'C.Text' 'SemiBold'; $v.FontFamily = $app.Resources['Display']
    $v.Margin = New-Margin 0 10 0 0; $v.TextTrimming = 'CharacterEllipsis'; $v.TextWrapping = 'NoWrap'
    [void]$sp.Children.Add($h); [void]$sp.Children.Add($v)
    $card.Child = $sp
    [void]$parent.Children.Add($card)
    $v
}

# Vorschau: sieht aus wie die Chatbox in VRChat, mit Zeichenzaehler (mehrere Seiten zeigen dieselbe Vorschau)
$previews = New-Object System.Collections.ArrayList
function Add-Preview($parent) {
    $card = New-Object System.Windows.Controls.Border
    $card.CornerRadius = 16; $card.Padding = New-Margin 18 14 18 12; $card.Margin = New-Margin 0 0 0 20; $card.MinHeight = 118
    $grad = New-Object System.Windows.Media.LinearGradientBrush
    $grad.StartPoint = '0,0'; $grad.EndPoint = '1,1'
    $grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.ColorConverter]::ConvertFromString('#1B2433')), 0))
    $grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.ColorConverter]::ConvertFromString('#0D1017')), 1))
    $card.Background = $grad
    $sp = New-Object System.Windows.Controls.StackPanel
    $capBox = New-Object System.Windows.Controls.Border
    $capBox.CornerRadius = 8; $capBox.Padding = New-Margin 9 3 9 3; $capBox.HorizontalAlignment = 'Center'; $capBox.Margin = New-Margin 0 0 0 12
    $capBox.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'C.AccentSoft')
    $cap = New-Object System.Windows.Controls.TextBlock
    $cap.Text = (T "VORSCHAU") + "  " + [char]0x00B7 + "  " + (T "SO STEHT ES ÜBER DEINEM KOPF"); $cap.FontSize = 10; $cap.FontWeight = 'Bold'
    $cap.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'C.Accent')
    $capBox.Child = $cap
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Foreground = [System.Windows.Media.Brushes]::White; $t.FontSize = 14; $t.TextAlignment = 'Center'; $t.TextWrapping = 'Wrap'; $t.LineHeight = 21
    $count = New-Object System.Windows.Controls.TextBlock
    $count.FontSize = 10.5; $count.HorizontalAlignment = 'Right'; $count.Margin = New-Margin 0 10 0 0
    $count.Foreground = New-Brush '#6F7C8E'
    [void]$sp.Children.Add($capBox); [void]$sp.Children.Add($t); [void]$sp.Children.Add($count)
    $card.Child = $sp
    [void]$parent.Children.Add($card)
    [void]$previews.Add(@{ Text = $t; Count = $count })
}

# ============================== SEITEN ==============================
$nav = @(
    @{ Key = 'dash';     Icon = 0xE80F; Name = 'Dashboard';     Desc = 'Was gerade läuft und was über deinem Kopf steht' }
    @{ Key = 'chat';     Icon = 0xE8BD; Name = 'Chatbox';       Desc = 'Was in der Chatbox steht und wie es aussieht' }
    @{ Key = 'lyrics';   Icon = 0xE8D6; Name = 'Lyrics';        Desc = 'Live-Songtexte, Karaoke und Übersetzung' }
    @{ Key = 'status';   Icon = 0xE946; Name = 'Status';        Desc = 'Uhrzeit, AFK, VRChat-Infos und eigene Texte' }
    @{ Key = 'vrchat';   Icon = 0xE7FC; Name = 'VRChat';        Desc = 'Avatar-Größe und Speicherplatz' }
    @{ Key = 'mic';      Icon = 0xE720; Name = 'Musik im Mic';  Desc = 'Andere in VRChat hören deinen Song' }
    @{ Key = 'stats';    Icon = 0xE9D2; Name = 'Statistik';     Desc = 'Deine meistgehörten Songs und Künstler' }
    @{ Key = 'settings'; Icon = 0xE713; Name = 'Einstellungen'; Desc = 'Design, Verhalten und Programm' }
    @{ Key = 'advanced'; Icon = 0xEC7A; Name = 'Erweitert';     Desc = 'Verbindung, Lyrics-Timing und Fehler-Log' }
)
$navButtons = @{}
foreach ($n in $nav) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.Style = $app.Resources['NavItem']
    $rb.Content = T $n.Name; $rb.Tag = Icon $n.Icon; $rb.GroupName = 'nav'
    $rb.DataContext = $n.Key
    $rb.add_Checked({ Show-Page $this.DataContext })
    [void]$ui.Nav.Children.Add($rb)
    $navButtons[$n.Key] = $rb
}

# ---------------- Dashboard ----------------
$p = New-Page 'dash'
$heroXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="0,0,0,20">
  <Border CornerRadius="20" Background="{DynamicResource C.Card}" BorderBrush="{DynamicResource C.Border}" BorderThickness="1"/>
  <!-- Das Besondere am Dashboard: verschwommenes Cover als Hintergrund. Als Hintergrund-Pinsel, damit es die Kartengroesse
       nicht beeinflusst; Rand nach aussen, damit die Unschaerfe keine hellen Kanten macht. -->
  <Grid x:Name="HeroArt" Opacity="0">
    <Border x:Name="HeroImg" Margin="-80" Opacity="0.56">
      <Border.Effect><BlurEffect Radius="48" RenderingBias="Performance" KernelType="Gaussian"/></Border.Effect>
    </Border>
    <Border x:Name="HeroShade"/>
  </Grid>
  <Grid Margin="24">
    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
    <Border x:Name="CoverWrap" Width="164" Height="164" CornerRadius="14" Margin="0,0,26,0">
      <Border.Effect><DropShadowEffect BlurRadius="28" ShadowDepth="6" Opacity="0.45" Color="Black" RenderingBias="Performance"/></Border.Effect>
      <Border x:Name="Cover" CornerRadius="14" Background="{DynamicResource C.Input}">
        <TextBlock x:Name="CoverIcon" Text="&#x266B;" FontFamily="Segoe UI Symbol" FontSize="50" Foreground="{DynamicResource C.Dim}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
    </Border>
    <StackPanel Grid.Column="1" VerticalAlignment="Center">
      <StackPanel Orientation="Horizontal">
        <StackPanel x:Name="Eq" Orientation="Horizontal" Height="11" Margin="0,0,8,0" VerticalAlignment="Center">
          <Rectangle x:Name="Eq1" Width="3" Height="11" RadiusX="1.5" RadiusY="1.5" Fill="{DynamicResource C.Accent}" VerticalAlignment="Bottom" RenderTransformOrigin="0.5,1" Margin="0,0,2,0"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.4"/></Rectangle.RenderTransform></Rectangle>
          <Rectangle x:Name="Eq2" Width="3" Height="11" RadiusX="1.5" RadiusY="1.5" Fill="{DynamicResource C.Accent}" VerticalAlignment="Bottom" RenderTransformOrigin="0.5,1" Margin="0,0,2,0"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.7"/></Rectangle.RenderTransform></Rectangle>
          <Rectangle x:Name="Eq3" Width="3" Height="11" RadiusX="1.5" RadiusY="1.5" Fill="{DynamicResource C.Accent}" VerticalAlignment="Bottom" RenderTransformOrigin="0.5,1"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.5"/></Rectangle.RenderTransform></Rectangle>
        </StackPanel>
        <TextBlock x:Name="TxtGenre" FontSize="10.5" FontWeight="Bold" Foreground="{DynamicResource C.Accent}" VerticalAlignment="Center"/>
      </StackPanel>
      <StackPanel x:Name="SongText">
        <TextBlock x:Name="TxtTitle" FontFamily="{DynamicResource Display}" FontSize="28" FontWeight="Bold" Foreground="{DynamicResource C.Text}" TextTrimming="CharacterEllipsis" Margin="0,6,0,0"/>
        <TextBlock x:Name="TxtArtist" FontSize="15" Foreground="{DynamicResource C.Text}" Opacity="0.75" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
        <TextBlock x:Name="TxtAlbum" FontSize="12" Foreground="{DynamicResource C.Dim}" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
      </StackPanel>
      <Grid x:Name="ProgressTrack" Height="18" Margin="0,14,0,0" Background="Transparent" Cursor="Hand">
        <Border Height="5" CornerRadius="2.5" Background="{DynamicResource C.Hover}" VerticalAlignment="Center"/>
        <Border x:Name="Progress" Height="5" CornerRadius="2.5" Background="{DynamicResource C.Accent}" HorizontalAlignment="Left" VerticalAlignment="Center" Width="0"/>
      </Grid>
      <Grid>
        <TextBlock x:Name="TxtPos" Text="0:00" FontSize="11" Foreground="{DynamicResource C.Dim}"/>
        <TextBlock x:Name="TxtLen" Text="0:00" FontSize="11" Foreground="{DynamicResource C.Dim}" HorizontalAlignment="Right"/>
      </Grid>
      <Grid Margin="0,8,0,0">
        <StackPanel Orientation="Horizontal">
          <Button x:Name="BtnShuffle" Style="{DynamicResource IconBtn}" Content="&#xE8B1;"/>
          <Button x:Name="BtnPrev" Style="{DynamicResource IconBtn}" Content="&#xE892;" Margin="4,0"/>
          <Button x:Name="BtnPlay" Style="{DynamicResource PlayBtn}" Content="&#xE768;" Margin="4,0"/>
          <Button x:Name="BtnNext" Style="{DynamicResource IconBtn}" Content="&#xE893;" Margin="4,0"/>
          <Button x:Name="BtnRepeat" Style="{DynamicResource IconBtn}" Content="&#xE8EE;"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <TextBlock Text="&#xE767;" FontFamily="{DynamicResource Icons}" Foreground="{DynamicResource C.Dim}" VerticalAlignment="Center" Margin="0,0,10,0"/>
          <Slider x:Name="Volume" Width="130" Minimum="0" Maximum="100" VerticalAlignment="Center"/>
        </StackPanel>
      </Grid>
    </StackPanel>
  </Grid>
</Grid>
'@
$hero = [Windows.Markup.XamlReader]::Parse($heroXaml)
$d = @{}
foreach ($n in 'HeroArt', 'HeroImg', 'HeroShade', 'Cover', 'CoverIcon', 'Eq', 'Eq1', 'Eq2', 'Eq3', 'TxtGenre', 'SongText', 'TxtTitle', 'TxtArtist', 'TxtAlbum', 'ProgressTrack', 'Progress', 'TxtPos', 'TxtLen', 'BtnShuffle', 'BtnPrev', 'BtnPlay', 'BtnNext', 'BtnRepeat', 'Volume') { $d[$n] = $hero.FindName($n) }
$d.TxtGenre.Text = T "JETZT LÄUFT"; $d.TxtTitle.Text = T "Spotify spielt nichts"
$d.ProgressTrack.ToolTip = T "Klicken zum Spulen"; $d.BtnShuffle.ToolTip = T "Zufallswiedergabe"; $d.BtnRepeat.ToolTip = T "Wiederholen"
$ui.TxtSubtitle.Text = T "für VRChat"; $ui.TxtMenu.Text = T "MENÜ"
[void]$p.Full.Children.Add($hero)
# Hintergrundbild an die runden Ecken anpassen
$hero.add_SizeChanged({ $d.HeroArt.Clip = New-Object System.Windows.Media.RectangleGeometry((New-Object System.Windows.Rect(0, 0, $this.ActualWidth, $this.ActualHeight)), 20, 20) })
# Abdunkeln ueber dem Cover (Text bleibt lesbar), links leicht in der Songfarbe getoent
function New-ShadeBrush([int]$tintAlpha = 110, [int]$baseAlpha = 165) {
    $base = [System.Windows.Media.ColorConverter]::ConvertFromString($(if ("$($cfg.Theme)" -eq 'light') { '#FFFFFF' } else { '#000000' }))
    $tint = [System.Windows.Media.ColorConverter]::ConvertFromString((Get-ActiveAccent))
    $g = [System.Windows.Media.LinearGradientBrush]::new()
    $g.StartPoint = '0,0'; $g.EndPoint = '1,0.4'
    $c1 = [System.Windows.Media.Color]::FromArgb($tintAlpha, [byte](($base.R + $tint.R) / 2), [byte](($base.G + $tint.G) / 2), [byte](($base.B + $tint.B) / 2))
    $c2 = $base; $c2.A = $baseAlpha
    [void]$g.GradientStops.Add([System.Windows.Media.GradientStop]::new($c1, 0))
    [void]$g.GradientStops.Add([System.Windows.Media.GradientStop]::new($c2, 0.75))
    $g.Freeze()
    $g
}
function Update-HeroShade { $d.HeroShade.Background = New-ShadeBrush }
Update-HeroShade
# Equalizer neben "Jetzt laeuft" (huepft nur, wenn Musik laeuft)
$eqLoops = @(
    (New-Loop $d.Eq1.RenderTransform ([System.Windows.Media.ScaleTransform]::ScaleYProperty) 0.25 1 420),
    (New-Loop $d.Eq2.RenderTransform ([System.Windows.Media.ScaleTransform]::ScaleYProperty) 0.35 1 560),
    (New-Loop $d.Eq3.RenderTransform ([System.Windows.Media.ScaleTransform]::ScaleYProperty) 0.2 1 360)
)

Add-Preview $p.Full

$tiles = New-Object System.Windows.Controls.Primitives.UniformGrid
$tiles.Columns = 3; $tiles.Margin = New-Margin 0 0 -14 0
[void]$p.Full.Children.Add($tiles)
$tile = @{
    World  = New-Tile $tiles 'VRChat-Welt' 0xE909 'teal'
    People = New-Tile $tiles 'Spieler in der Welt' 0xE716 'indigo'
    Lyrics = New-Tile $tiles 'Lyrics' 0xE8D6 'pink'
    Today  = New-Tile $tiles 'Heute gehört' 0xE916 'orange'
    Songs  = New-Tile $tiles 'Songs (Sitzung)' 0xE8D6 'green'
    Time   = New-Tile $tiles 'VRChat-Spielzeit' 0xE823 'purple'
}

$d.BtnPrev.add_Click({ $sync.Commands.Enqueue('prev') })
$d.BtnPlay.add_Click({ $sync.Commands.Enqueue('playpause') })
$d.BtnNext.add_Click({ $sync.Commands.Enqueue('next') })
$d.BtnShuffle.add_Click({ $sync.Commands.Enqueue('shuffle') })
$d.BtnRepeat.add_Click({ $sync.Commands.Enqueue('repeat') })
$d.ProgressTrack.add_MouseLeftButtonDown({
    param($s, $e)
    $i = $sync.Info
    if (-not $i -or $this.ActualWidth -le 0) { return }
    $sec = $i.Length.TotalSeconds * ($e.GetPosition($this).X / $this.ActualWidth)
    $sync.Commands.Enqueue("seek:" + $sec.ToString([Globalization.CultureInfo]::InvariantCulture))
})
$d.Volume.add_ValueChanged({ if (-not $state.VolSync) { [AppVolume]::Set('Spotify', [float]($this.Value / 100)) } })

# ---------------- Chatbox ----------------
$p = New-Page 'chat'
Add-Preview $p.Full
$profileSection = New-Section $p.Full "Chatbox-Profile" "Ein Profil stellt mehrere Anzeigeoptionen gemeinsam ein. Du kannst danach jede Einstellung weiter anpassen."
Add-Segment $profileSection "Profil" 'ChatProfile' @(
    @((T "Eigen"), "custom"), @((T "Clean"), "clean"), @((T "Lyrics"), "lyrics"), @((T "Minimal"), "minimal")
) { Apply-ChatProfile } -icon 0xE8BD -color 'purple' -desc "Schnell zwischen typischen Chatbox-Stilen wechseln"
$s = New-Section $p.Left "Inhalt" "Jeden Teil der Chatbox einzeln an- und ausschalten."
Add-Switch $s "Songtitel" 'ShowTitle' -icon 0xE8D6 -color 'pink'
Add-Switch $s "Künstler" 'ShowArtist' -icon 0xE77B -color 'purple'
Add-Switch $s "Künstler in eigener Zeile" 'ArtistOwnLine' "Titel und Künstler stehen untereinander" -icon 0xE8FD -color 'indigo'
Add-Switch $s "Album" 'ShowAlbum' -icon 0xE93C -color 'blue'
Add-Switch $s "Fortschrittsbalken" 'ShowBar' -icon 0xE916 -color 'teal'
Add-Switch $s "Live-Lyrics" 'ShowLyrics' -icon 0xE8BD -color 'green'
Add-Switch $s "Uhrzeit" 'ShowClock' -icon 0xE823 -color 'orange'

$s = New-Section $p.Left "Aufräumen" "Macht lange Titel kürzer, damit mehr Platz für Lyrics und Status bleibt."
Add-Switch $s "Features ausblenden" 'HideFeat' "(feat. …) und (with …) aus dem Titel entfernen" -icon 0xE716 -color 'purple'
Add-Switch $s "Zusätze in Klammern ausblenden" 'HideBrackets' "z. B. (Remastered), [Live], - Radio Edit" -icon 0xE8C6 -color 'teal'
Add-Switch $s "Nur Hauptkünstler" 'MainArtistOnly' "Nur der erste Künstler statt aller Beteiligten" -icon 0xE77B -color 'pink'
Add-Switch $s "Album ausblenden, wenn es wie der Song heißt" 'HideAlbumIfTitle' "Bei Singles steht sonst zweimal dasselbe da" -icon 0xE93C -color 'blue'

$s = New-Section $p.Left "Verhalten"
Add-Switch $s "Ohne Hintergrund" 'NoBackground' "VRChat zeigt nur einen minimalen Kasten" -icon 0xE7B3 -color 'gray'
Add-Switch $s "Kompakt" 'Compact' "Alles in einer einzigen Zeile" -icon 0xE73F -color 'blue'
Add-Switch $s "Bei Pause ausblenden" 'HideWhenPaused' "Song verschwindet, wenn Spotify pausiert" -icon 0xE769 -color 'orange'
Add-Switch $s "Song nur kurz zeigen" 'ChangeOnly' "Nur 15 Sekunden nach einem Songwechsel" -icon 0xE916 -color 'yellow'
Add-Segment $s "Aktualisieren alle" 'Interval' @(@("1,5 s", 1.5), @("2 s", 2), @("3 s", 3), @("5 s", 5)) -icon 0xE72C -color 'green' -desc "1,5 s ist das Schnellste, was VRChat erlaubt"

$s = New-Section $p.Right "Song-Zeile"
Add-Segment $s "Song-Icon" 'IconStyle' @(@("$([char]::ConvertFromUtf32(0x1F3B5))", 0), @("$([char]::ConvertFromUtf32(0x1F3A7))", 1), @("$([char]0x266A)", 2), @("Keins", 3)) -icon 0xE8D6 -color 'pink'
Add-Switch $s "Künstler hochgestellt" 'ArtistSuperscript' "Titel ᵇʸ ᵏᵘⁿˢᵗˡᵉʳ" -icon 0xE8E9 -color 'purple'
Add-Switch $s "Kapitälchen-Schrift" 'SmallCaps' "ᴛɪᴛᴇʟ - ᴋüɴꜱᴛʟᴇʀ" -icon 0xE8D2 -color 'indigo'

$s = New-Section $p.Right "Trennzeichen" "Steht zwischen Titel und Künstler und zwischen den Teilen der Status-Zeile, z. B. Uhrzeit / Welt."
Add-Segment $s "" 'Separator' @(@("-", " - "), @("|", " | "), @([string][char]0x2022, " $([char]0x2022) "), @("/", " / "), @("~", " ~ ")) -NoTranslate
Add-Switch $s "Leerzeile vor der Status-Zeile" 'BlankLine' -icon 0xE8FD -color 'gray'

$s = New-Section $p.Right "Fortschrittsbalken"
Add-Switch $s "Restzeit statt Länge" 'Remaining' -icon 0xE916 -color 'teal'
function E([int]$c) { [char]::ConvertFromUtf32($c) }
Add-Segment $s "Stil" 'BarStyle' @(
    @(((E 0x25AC) * 2 + (E 0x25CF) + (E 0x25AC) * 2), 0), @(((E 0x2501) * 2 + (E 0x25C9) + (E 0x2500) * 2), 1),
    @(((E 0x2593) * 3 + (E 0x2591) * 2), 2), @(((E 0x25A0) * 3 + (E 0x25A1) * 2), 3), @(((E 0x2665) * 3 + (E 0x2661) * 2), 4)) -icon 0xE790 -color 'blue' -NoTranslate
Add-Segment $s "Länge" 'BarLength' @(@("Kurz", 6), @("Mittel", 10), @("Lang", 14)) -icon 0xE9A6 -color 'indigo'

$s = New-Section $p.Right "Beim Sprechen ausblenden" "Zählt nur, wenn VRChat im Vordergrund ist. Redest du z. B. in Discord, bleibt die Chatbox stehen."
Add-Switch $s "Beim Sprechen ausblenden" 'HideWhileSpeaking' -icon 0xE720 -color 'red'
Add-Segment $s "Empfindlichkeit" 'MicThreshold' @(@("Niedrig", 0.1), @("Mittel", 0.04), @("Hoch", 0.015)) -icon 0xE9D9 -color 'orange'
$micText = Add-Hint $s

# ---------------- Lyrics ----------------
$p = New-Page 'lyrics'
Add-Preview $p.Full
$s = New-Section $p.Left "Lyrics" "Kommen die Lyrics zu früh oder zu spät? Unter Erweitert > Lyrics-Timing einstellen."
Add-Switch $s "Live-Lyrics" 'ShowLyrics' "Aktuelle Zeile unten in der Chatbox" -icon 0xE8BD -color 'green'
Add-Switch $s "Karaoke-Modus" 'LyricsMode' "Nur Song, aktuelle und nächste Zeile" -icon 0xE720 -color 'pink'
Add-Switch $s "Titel ausblenden, wenn Lyrics laufen" 'HideTitleAfterLyrics' "Nach 10 Sekunden nur noch die Lyrics" -icon 0xE8D6 -color 'purple'
$lyricsStatus = Add-Hint $s

# Uebersetzung: ~35 Sprachen (Code, Deutsch, Englisch)
$translateLangs = @(
    @('de', 'Deutsch', 'German'), @('en', 'Englisch', 'English'), @('ar', 'Arabisch', 'Arabic'), @('bg', 'Bulgarisch', 'Bulgarian'),
    @('zh-CN', 'Chinesisch (vereinfacht)', 'Chinese (Simplified)'), @('zh-TW', 'Chinesisch (traditionell)', 'Chinese (Traditional)'),
    @('da', 'Dänisch', 'Danish'), @('tl', 'Filipino', 'Filipino'), @('fi', 'Finnisch', 'Finnish'), @('fr', 'Französisch', 'French'),
    @('el', 'Griechisch', 'Greek'), @('he', 'Hebräisch', 'Hebrew'), @('hi', 'Hindi', 'Hindi'), @('id', 'Indonesisch', 'Indonesian'),
    @('it', 'Italienisch', 'Italian'), @('ja', 'Japanisch', 'Japanese'), @('ko', 'Koreanisch', 'Korean'), @('hr', 'Kroatisch', 'Croatian'),
    @('nl', 'Niederländisch', 'Dutch'), @('no', 'Norwegisch', 'Norwegian'), @('fa', 'Persisch', 'Persian'), @('pl', 'Polnisch', 'Polish'),
    @('pt', 'Portugiesisch', 'Portuguese'), @('ro', 'Rumänisch', 'Romanian'), @('ru', 'Russisch', 'Russian'), @('sv', 'Schwedisch', 'Swedish'),
    @('sr', 'Serbisch', 'Serbian'), @('sk', 'Slowakisch', 'Slovak'), @('es', 'Spanisch', 'Spanish'), @('th', 'Thailändisch', 'Thai'),
    @('cs', 'Tschechisch', 'Czech'), @('tr', 'Türkisch', 'Turkish'), @('uk', 'Ukrainisch', 'Ukrainian'), @('hu', 'Ungarisch', 'Hungarian'),
    @('vi', 'Vietnamesisch', 'Vietnamese')
)
$langOptions = @($translateLangs | ForEach-Object { ,@($(if ($lang -eq 'de') { $_[1] } else { $_[2] }), $_[0]) })
$langOptions = @(@($langOptions[0..1]) + @($langOptions[2..($langOptions.Count - 1)] | Sort-Object { $_[0] }))   # Deutsch/Englisch oben, Rest alphabetisch
$s = New-Section $p.Left "Übersetzung"
Add-Switch $s "Lyrics übersetzen" 'Translate' "Zeigt die Übersetzung unter der Zeile" -icon 0xE8C1 -color 'blue'
Add-Dropdown $s "Sprache" 'TranslateLang' $langOptions -icon 0xE774 -color 'teal'

$s = New-Section $p.Left "Eigene Lyrics" "Für Songs, zu denen keine Lyrics gefunden werden. Mit der Vorlage schreibst du sie selbst."
[void](Add-ActionRow $s "Lyrics-Ordner öffnen" { Start-Process explorer.exe $lyricsDir } 0xE838 'blue')
[void](Add-ActionRow $s "Vorlage für aktuellen Song" {
    $i = $sync.Info
    if (-not $i) { return }
    $clean = $i.Title -replace '\s*[\(\[](feat|ft|with)\.?[^\)\]]*[\)\]]', ''
    $name = ($i.Artist + " - " + $clean + ".lrc") -replace '[\\/:*?<>|"]', '_'
    $file = Join-Path $lyricsDir $name
    if (-not (Test-Path $file)) {
        "[ar:$($i.Artist)]`r`n[ti:$($i.Title)]`r`n[00:00.00] Erste Zeile (Zeit = Minuten:Sekunden)`r`n[00:05.50] Zweite Zeile" | Set-Content $file -Encoding UTF8
    }
    Start-Process notepad.exe "`"$file`""
} 0xE710 'green' "Öffnet eine Datei, in die du die Lyrics mit Zeitangaben schreibst")

# Live-Ansicht: alle Zeilen, die aktuelle leuchtet und scrollt weich mit. Klick auf eine Zeile spult dorthin.
$s = New-Section $p.Right "Live-Ansicht" "Klick auf eine Zeile springt im Song dorthin."
$lvScroll = New-Object System.Windows.Controls.ScrollViewer
$lvScroll.Height = 420; $lvScroll.VerticalScrollBarVisibility = 'Hidden'; $lvScroll.Margin = New-Margin 0 8 0 8
$lvStack = New-Object System.Windows.Controls.StackPanel
$lvStack.Margin = New-Margin 0 170 0 200   # Platz oben/unten, damit auch die erste/letzte Zeile mittig stehen kann
$lvScroll.Content = $lvStack
[void]$s.Children.Add($lvScroll)
$lv = @{ Lines = $null; Blocks = @(); Index = -2; Target = 0.0 }
$lvTimer = New-Object System.Windows.Threading.DispatcherTimer
$lvTimer.Interval = [TimeSpan]::FromMilliseconds(16)
$lvTimer.add_Tick({
    $cur = $lvScroll.VerticalOffset
    $diff = $lv.Target - $cur
    if ([Math]::Abs($diff) -lt 0.6) { $lvScroll.ScrollToVerticalOffset($lv.Target); $lvTimer.Stop(); return }
    $lvScroll.ScrollToVerticalOffset($cur + $diff * 0.16)
})
function Update-LyricsView([double]$pos) {
    $lines = $sync.LyricLines
    if (-not [object]::ReferenceEquals($lines, $lv.Lines)) {
        $lv.Lines = $lines; $lv.Index = -2; $lvStack.Children.Clear()
        $blocks = New-Object System.Collections.ArrayList
        if ($lines) {
            foreach ($l in $lines) {
                if (-not $l.L) { continue }
                $t = New-Text "" 17 'C.Dim' 'Bold'; $t.Text = $l.L; $t.FontFamily = $app.Resources['Display']
                $t.Margin = New-Margin 0 6 0 6; $t.Cursor = 'Hand'; $t.Opacity = 0.55; $t.Tag = $l.T
                $t.add_MouseLeftButtonUp({ $sync.Commands.Enqueue("seek:" + ([Math]::Max(0, [double]$this.Tag - [double]$cfg.LyricsOffset)).ToString([Globalization.CultureInfo]::InvariantCulture)) })
                [void]$lvStack.Children.Add($t); [void]$blocks.Add($t)
            }
        } else {
            $t = New-Text $(if ($cfg.ShowLyrics -or $cfg.LyricsMode) { "Keine Lyrics für diesen Song" } else { "Live-Lyrics sind aus" }) 14 'C.Dim'
            $t.HorizontalAlignment = 'Center'; [void]$lvStack.Children.Add($t)
        }
        $lv.Blocks = $blocks.ToArray()
        $lvScroll.ScrollToVerticalOffset(0)
        Animate-In $lvStack 12 400
        return   # erst im naechsten Durchlauf scrollen, wenn die Zeilen ihre Groesse haben
    }
    if (-not $lv.Blocks.Count) { return }
    $t = $pos + 0.3 + [double]$cfg.LyricsOffset
    $idx = -1
    for ($i = 0; $i -lt $lv.Blocks.Count; $i++) { if ([double]$lv.Blocks[$i].Tag -le $t) { $idx = $i } else { break } }
    if ($idx -ne $lv.Index) {
        if ($lv.Index -ge 0 -and $lv.Index -lt $lv.Blocks.Count) {
            $old = $lv.Blocks[$lv.Index]; $old.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'C.Dim')
            Animate $old ([System.Windows.UIElement]::OpacityProperty) 0.55 300
        }
        $lv.Index = $idx
        if ($idx -ge 0) { $cur = $lv.Blocks[$idx]; $cur.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'C.Text'); Animate $cur ([System.Windows.UIElement]::OpacityProperty) 1 300 }
    }
    # aktuelle Zeile weich in die Mitte scrollen
    $target = if ($idx -ge 0) { $lv.Blocks[$idx] } else { $lv.Blocks[0] }
    if ($target.ActualHeight -le 0) { return }
    $y = $target.TranslatePoint((New-Object System.Windows.Point(0, 0)), $lvStack).Y + $lvStack.Margin.Top
    $lv.Target = [Math]::Max(0, $y - $lvScroll.ViewportHeight / 2 + $target.ActualHeight / 2)
    if ([Math]::Abs($lv.Target - $lvScroll.VerticalOffset) -gt 1 -and -not $lvTimer.IsEnabled) { $lvTimer.Start() }
}

# ---------------- Status ----------------
$p = New-Page 'status'
Add-Preview $p.Full
$s = New-Section $p.Left "Uhrzeit & AFK"
Add-Switch $s "Uhrzeit" 'ShowClock' -icon 0xE823 -color 'orange'
Add-Switch $s "AFK" 'Afk' "Zeigt AFK in der Chatbox" -icon 0xE708 -color 'indigo'
Add-Switch $s "Auto-AFK" 'AutoAfk' "Wenn Maus und Tastatur nicht benutzt werden (nur Desktop-Modus sinnvoll)" -icon 0xE916 -color 'purple'
Add-Segment $s "Auto-AFK nach" 'AfkMinutes' @(@("2 min", 2), @("5 min", 5), @("10 min", 10), @("15 min", 15)) -icon 0xE81C -color 'gray'

$s = New-Section $p.Right "VRChat"
Add-Switch $s "Welt und Spielerzahl" 'WorldInfo' "Name der Welt und wie viele Leute da sind" -icon 0xE909 -color 'teal'
Add-Switch $s "Spielzeit" 'Playtime' "Wie lange VRChat schon läuft" -icon 0xE7FC -color 'green'
$s = New-Section $p.Right "Eigener Text" "Mehrere Texte mit ; trennen, sie wechseln alle 10 Sekunden."
[void](Add-TextSetting $s "" 'StatusText')

# ---------------- VRChat ----------------
# OSC-Nachricht mit einer Zahl, z. B. /avatar/eyeheight 1.6
function ConvertTo-OscBytes([string]$s) {
    $b = [System.Text.Encoding]::UTF8.GetBytes($s)
    $out = New-Object byte[] ([Math]::Floor($b.Length / 4) * 4 + 4)
    [Array]::Copy($b, $out, $b.Length); $out
}
function Send-OscFloat([string]$address, [single]$value) {
    $oscPort = 0
    if ($sync.PortOverride) { $oscPort = [int]$sync.PortOverride }
    elseif (-not [int]::TryParse("$($cfg.OscPort)", [ref]$oscPort) -or $oscPort -lt 1 -or $oscPort -gt 65535) { $oscPort = 9000 }
    $oscHost = "$($cfg.OscHost)".Trim(); if (-not $oscHost) { $oscHost = "127.0.0.1" }
    $f = [BitConverter]::GetBytes($value); [Array]::Reverse($f)   # OSC will Big-Endian
    $packet = [byte[]]((ConvertTo-OscBytes $address) + (ConvertTo-OscBytes ',f') + $f)
    $u = New-Object System.Net.Sockets.UdpClient
    try { [void]$u.Send($packet, $packet.Length, $oscHost, $oscPort) } catch { [void]$sync.Errors.Add("OSC: $_") } finally { $u.Close() }
}

# Avatar-Groesse: Regler ist logarithmisch, damit 1 cm bis 10 km auf eine Leiste passen
$heightMin = [double]0.01; $heightMax = [double]10000   # double, sonst rundet [Math]::Min auf ganze Zahlen
function ConvertTo-HeightPos([double]$m) { 1000 * ([Math]::Log10([Math]::Min($heightMax, [Math]::Max($heightMin, $m))) + 2) / 6 }
function ConvertFrom-HeightPos([double]$pos) { [Math]::Pow(10, $pos / 1000 * 6 - 2) }
function Format-Height([double]$m) {
    if ($m -lt 0.1) { return ("{0:0.#} cm" -f ($m * 100)) }
    if ($m -lt 1) { return ("{0:0} cm" -f ($m * 100)) }
    if ($m -lt 10) { return ("{0:0.00} m" -f $m) }
    if ($m -lt 1000) { return ("{0:0} m" -f $m) }
    ("{0:0.#} km" -f ($m / 1000))
}
function Set-AvatarHeight([double]$m, [switch]$FromSlider) {
    $m = [Math]::Min($heightMax, [Math]::Max($heightMin, $m))
    # Saubere Werte: unter 1 m auf cm, darueber auf 3 gueltige Stellen runden
    $digits = [Math]::Max(0, 2 - [Math]::Floor([Math]::Log10($m)))
    $m = [Math]::Round($m, [int][Math]::Min(4, $digits))
    $cfg.AvatarHeight = $m; Save-Config
    $heightUi.Value.Text = Format-Height $m
    if ($heightUi.Box) { $heightUi.Box.Text = Format-Height $m }
    $heightUi.Warn.Visibility = if ($m -lt 0.1 -or $m -gt 100) { 'Visible' } else { 'Collapsed' }
    if (-not $FromSlider) { $state.Refreshing = $true; $heightUi.Slider.Value = ConvertTo-HeightPos $m; $state.Refreshing = $false }
    Send-OscFloat '/avatar/eyeheight' $m
}

$p = New-Page 'vrchat'
$s = New-Section $p.Full "Avatar-Größe" "Geht über OSC von 1 cm bis 10 km, auch über die Grenzen vom Action-Menü hinaus. Manche Welten sperren die Größe."
$hWrap = New-Object System.Windows.Controls.StackPanel; $hWrap.Margin = New-Margin 0 14 0 14
$hHead = New-Object System.Windows.Controls.Grid
[void]$hHead.Children.Add((New-RowLabel "Augenhöhe" "So groß bist du in VRChat" 0xE1D9 'teal'))
$hVal = New-Text "" 30 'C.Accent' 'Bold'; $hVal.FontFamily = $app.Resources['Display']
$hVal.HorizontalAlignment = 'Right'; $hVal.VerticalAlignment = 'Center'
[void]$hHead.Children.Add($hVal)
[void]$hWrap.Children.Add($hHead)
$hSlider = New-Object System.Windows.Controls.Slider
$hSlider.Minimum = 0; $hSlider.Maximum = 1000; $hSlider.Margin = New-Margin 0 14 0 0
$hSlider.Value = ConvertTo-HeightPos ([double]$cfg.AvatarHeight)
$hSlider.add_ValueChanged({ if (-not $state.Refreshing) { Set-AvatarHeight (ConvertFrom-HeightPos $this.Value) -FromSlider } })
[void]$hWrap.Children.Add($hSlider)
# Skala unter dem Regler
$scale = New-Object System.Windows.Controls.Grid; $scale.Margin = New-Margin 0 4 0 0
# 12 gleich breite Spalten: jede Beschriftung ueberspannt zwei, so liegt ihre Mitte genau auf der Zehnerpotenz
for ($c = 0; $c -lt 12; $c++) { [void]$scale.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)) }
$i = 0
foreach ($m in @('1 cm', '10 cm', '1 m', '10 m', '100 m', '1 km', '10 km')) {
    $t = New-Text $m 10.5 'C.Dim'; $t.TextWrapping = 'NoWrap'
    if ($i -eq 0) { $t.HorizontalAlignment = 'Left' }
    elseif ($i -eq 6) { $t.HorizontalAlignment = 'Right'; [System.Windows.Controls.Grid]::SetColumn($t, 11) }
    else { $t.HorizontalAlignment = 'Center'; [System.Windows.Controls.Grid]::SetColumn($t, 2 * $i - 1); [System.Windows.Controls.Grid]::SetColumnSpan($t, 2) }
    [void]$scale.Children.Add($t); $i++
}
[void]$hWrap.Children.Add($scale)
$hWarn = New-Text "Außerhalb von 10 cm bis 100 m zeigt VRChat dir einen Warnhinweis an. Das ist normal." 11.5 'C.Dim'
$hWarn.Margin = New-Margin 0 10 0 0; $hWarn.Visibility = 'Collapsed'
[void]$hWrap.Children.Add($hWarn)
# Schnellwahl
$hRow = New-Object System.Windows.Controls.WrapPanel; $hRow.Margin = New-Margin 0 14 0 0
foreach ($preset in @(@('1 cm', 0.01), @('10 cm', 0.1), @('50 cm', 0.5), @('Normal', 1.6), @('5 m', 5), @('100 m', 100), @('1 km', 1000), @('10 km', 10000))) {
    $b = Add-Button $hRow $preset[0] { Set-AvatarHeight $this.Tag }
    $b.Tag = [double]$preset[1]; $b.Margin = New-Margin 0 0 8 8
}
# Feinschritte
foreach ($step in @(@(0xE738, 0.8, "Kleiner"), @(0xE710, 1.25, "Größer"))) {
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $app.Resources['Btn']; $b.Content = Icon $step[0]; $b.FontFamily = $app.Resources['Icons']
    $b.Tag = [double]$step[1]; $b.ToolTip = T $step[2]; $b.Margin = New-Margin 0 0 8 8
    $b.add_Click({ Set-AvatarHeight ([double]$cfg.AvatarHeight * $this.Tag) })
    [void]$hRow.Children.Add($b)
}
[void]$hWrap.Children.Add($hRow)
[void]$s.Children.Add($hWrap)
# Eigene Groesse eintippen: "1,75", "175 cm", "2.5 km" ...
function ConvertFrom-HeightText([string]$text) {
    if ("$text".Trim() -notmatch '^([\d]+(?:[.,]\d+)?)\s*(cm|m|km)?$') { return $null }
    $v = [double]::Parse(($Matches[1] -replace ',', '.'), [Globalization.CultureInfo]::InvariantCulture)
    switch ($Matches[2]) { 'cm' { $v / 100 } 'km' { $v * 1000 } default { $v } }
}
Add-Divider $s $true
$hc = New-Object System.Windows.Controls.Grid; $hc.Margin = New-Margin 0 10 0 10
[void]$hc.Children.Add((New-RowLabel "Eigene Größe" "z. B. 1,75 m, 30 cm oder 2 km" 0xE70F 'purple'))
$hcr = New-Object System.Windows.Controls.StackPanel; $hcr.Orientation = 'Horizontal'; $hcr.HorizontalAlignment = 'Right'; $hcr.VerticalAlignment = 'Center'
$heightBox = New-Object System.Windows.Controls.TextBox; $heightBox.Width = 120; $heightBox.TextAlignment = 'Center'; $heightBox.VerticalAlignment = 'Center'
$heightBox.Text = Format-Height ([double]$cfg.AvatarHeight); $heightBox.Margin = New-Margin 0 0 10 0
$applyHeight = {
    $m = ConvertFrom-HeightText $heightBox.Text
    if ($null -eq $m -or $m -le 0) { $heightBox.Focus() | Out-Null; $heightBox.SelectAll(); return }
    Set-AvatarHeight $m
}
$heightBox.add_KeyDown({ if ($_.Key -eq 'Return') { & $applyHeight } })
[void]$hcr.Children.Add($heightBox)
$hb = Add-Button $hcr "Setzen" $applyHeight -Accent; $hb.Margin = New-Margin 0
[void]$hc.Children.Add($hcr)
[void]$s.Children.Add($hc)
$heightUi = @{ Value = $hVal; Slider = $hSlider; Warn = $hWarn; Box = $heightBox }
$hVal.Text = Format-Height ([double]$cfg.AvatarHeight)
$hWarn.Visibility = if ([double]$cfg.AvatarHeight -lt 0.1 -or [double]$cfg.AvatarHeight -gt 100) { 'Visible' } else { 'Collapsed' }

# Cache: VRChat speichert jeden Avatar und jede Welt, die du je gesehen hast
$vrDataDir = Join-Path $env:USERPROFILE "AppData\LocalLow\VRChat\VRChat"
$vrConfigPath = Join-Path $vrDataDir "config.json"
function Get-VrConfig {
    try { if (Test-Path $vrConfigPath) { $c = Get-Content $vrConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json; if ($c) { return $c } } } catch { }
    New-Object PSObject
}
function Get-VrCacheDir {
    $c = Get-VrConfig
    $base = if ($c.cache_directory) { "$($c.cache_directory)" -replace '/', '\' } else { $vrDataDir }
    Join-Path $base 'Cache-WindowsPlayer'
}
function Test-VrClosed {
    if (Get-Process VRChat -ErrorAction SilentlyContinue) {
        [void][System.Windows.MessageBox]::Show((T "Bitte schließe zuerst VRChat. Solange es läuft, sind die Dateien gesperrt."), "VRChat", 'OK', 'Information')
        return $false
    }
    $true
}
$cacheJob = [hashtable]::Synchronized(@{ Busy = $false; Version = 0; Size = -1L; Count = 0; OldSize = 0L; OldCount = 0; Freed = 0L; Mode = ''; PS = $null; Next = $null })
$cacheScript = {
    param($job, [string]$dir, [string]$mode, [int]$days)
    try {
        $limit = [DateTime]::Now.AddDays(-$days)
        $size = 0L; $count = 0; $oldSize = 0L; $oldCount = 0; $freed = 0L
        if ([System.IO.Directory]::Exists($dir)) {
            foreach ($d in ([System.IO.DirectoryInfo]$dir).EnumerateDirectories()) {
                $s = 0L; $last = $d.LastWriteTime
                try { foreach ($f in $d.EnumerateFiles('*', 'AllDirectories')) { $s += $f.Length; if ($f.LastWriteTime -gt $last) { $last = $f.LastWriteTime } } } catch { }
                $isOld = $last -lt $limit
                if ($mode -eq 'all' -or ($mode -eq 'old' -and $isOld) -or ($mode -eq 'new' -and -not $isOld)) {
                    try { $d.Delete($true); $freed += $s; continue } catch { }
                }
                $size += $s; $count++
                if ($isOld) { $oldSize += $s; $oldCount++ }
            }
        }
        $job.Size = $size; $job.Count = $count; $job.OldSize = $oldSize; $job.OldCount = $oldCount; if ($mode -ne 'scan') { $job.Freed = $freed }
    } catch { } finally { $job.Busy = $false; $job.Version++ }
}
function Start-CacheJob([string]$mode, [string]$dir = "") {
    if ($cacheJob.Busy) { return }
    if (-not $dir) { $dir = Get-VrCacheDir }
    if ($cacheJob.PS) { $cacheJob.PS.Dispose(); $cacheJob.PS = $null }
    $cacheJob.Busy = $true; $cacheJob.Mode = $mode
    if ($mode -ne 'scan') { $cacheJob.Freed = 0L }
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($cacheScript.ToString()).AddArgument($cacheJob).AddArgument($dir).AddArgument($mode).AddArgument([int]$cfg.CacheDays)
    [void]$ps.BeginInvoke(); $cacheJob.PS = $ps
    $cacheUi.Size.Text = T $(if ($mode -eq 'scan') { "Wird berechnet..." } else { "Wird gelöscht..." })
}
function Format-Bytes([double]$b) { if ($b -ge 1GB) { "{0:0.0} GB" -f ($b / 1GB) } else { "{0:0} MB" -f ($b / 1MB) } }
function Update-CacheUi {
    $j = $cacheJob
    $where = if ((Get-VrCacheDir).StartsWith($vrDataDir, 'OrdinalIgnoreCase')) { "C:" } else { (Get-VrCacheDir).Substring(0, 2) }
    $cacheUi.Size.Text = "$(Format-Bytes $j.Size)  $([char]0x00B7)  $($j.Count) $(T 'Avatare & Welten')  $([char]0x00B7)  $(T 'auf') $where"
    $days = [int]$cfg.CacheDays
    $newCount = $j.Count - $j.OldCount; $newSize = $j.Size - $j.OldSize
    $cacheUi.OldRow.Content.Children[1].Children[0].Text = (T "Älter als {0} Tage löschen") -f $days
    $cacheUi.NewRow.Content.Children[1].Children[0].Text = (T "Neuer als {0} Tage löschen") -f $days
    $cacheUi.Old.Text = if ($j.OldCount -gt 0) { "$($j.OldCount) $(T 'Einträge'), $(Format-Bytes $j.OldSize)  $([char]0x00B7)  $(T 'lange nicht gesehen')" } else { T "Nichts gefunden" }
    $cacheUi.New.Text = if ($newCount -gt 0) { "$newCount $(T 'Einträge'), $(Format-Bytes $newSize)  $([char]0x00B7)  $(T 'kürzlich gesehen')" } else { T "Nichts gefunden" }
    if ($j.Freed -gt 0) { $cacheUi.Size.Text = "$(T 'Frei geworden:') $(Format-Bytes $j.Freed)  $([char]0x00B7)  " + $cacheUi.Size.Text }
    $onD = $where -ne "C:"
    $cacheUi.Move.Content.Children[1].Children[0].Text = T $(if ($onD) { "Cache zurück auf C: legen" } else { "Cache auf Laufwerk D: verschieben" })
    $cacheUi.Move.Content.Children[1].Children[1].Text = T $(if ($onD) { "Gespeichert in" } else { "Spart Platz auf C:. Avatare laden von D: etwas langsamer." })
    if ($onD) { $cacheUi.Move.Content.Children[1].Children[1].Text += " $(Split-Path (Get-VrCacheDir))" }
}
function Set-VrCacheLocation([string]$base) {
    $c = Get-VrConfig
    if ($base) { $c | Add-Member -NotePropertyName cache_directory -NotePropertyValue ($base -replace '\\', '/') -Force }
    else { [void]$c.PSObject.Properties.Remove('cache_directory') }
    $json = if (@($c.PSObject.Properties).Count) { $c | ConvertTo-Json -Depth 6 } else { "{}" }
    [System.IO.File]::WriteAllText($vrConfigPath, $json, (New-Object System.Text.UTF8Encoding $false))
}

$s = New-Section $p.Left "Speicherplatz" "VRChat speichert jeden Avatar und jede Welt, die du gesehen hast. Gelöschtes lädt VRChat beim nächsten Mal einfach neu herunter."
$sizeRow = New-RowLabel "VRChat-Cache" "Wird berechnet..." 0xEDA2 'blue'; $sizeRow.Margin = New-Margin 0 11 0 11
[void]$s.Children.Add($sizeRow)
Add-Segment $s "Zeitraum" 'CacheDays' @(@("3 Tage", 3), @("7 Tage", 7), @("14 Tage", 14), @("30 Tage", 30)) { if ($cacheJob.Version -gt 0) { Start-CacheJob 'scan' } } -icon 0xE787 -color 'teal' -desc "Wann du einen Avatar oder eine Welt zuletzt gesehen hast"
$oldRow = Add-ActionRow $s "Älter als 14 Tage löschen" {
    if (-not (Test-VrClosed)) { return }
    Start-CacheJob 'old'
} 0xE81C 'orange' "..."
$newRow = Add-ActionRow $s "Neuer als 14 Tage löschen" {
    if (-not (Test-VrClosed)) { return }
    Start-CacheJob 'new'
} 0xE74D 'yellow' "..."
$cacheUi = @{ Size = $sizeRow.Children[1].Children[1]; OldRow = $oldRow; NewRow = $newRow; Old = $oldRow.Content.Children[1].Children[1]; New = $newRow.Content.Children[1].Children[1]; Move = $null }
[void](Add-ActionRow $s "Ganzen Cache löschen" {
    if (-not (Test-VrClosed)) { return }
    $r = [System.Windows.MessageBox]::Show((T "Alle gespeicherten Avatare und Welten löschen? VRChat lädt sie bei Bedarf neu herunter."), (T "Cache löschen"), 'YesNo', 'Question')
    if ($r -eq 'Yes') { Start-CacheJob 'all' }
} 0xE74D 'red' -Danger)

$s = New-Section $p.Right "Cache-Ort" "VRChat muss dafür geschlossen sein. Der alte Cache wird dabei gelöscht, damit er keinen Platz mehr belegt."
$cacheUi.Move = Add-ActionRow $s "Cache auf Laufwerk D: verschieben" {
    if (-not (Test-VrClosed)) { return }
    $old = Get-VrCacheDir
    $toD = $old.StartsWith($vrDataDir, 'OrdinalIgnoreCase')
    if ($toD -and -not (Test-Path 'D:\')) { [void][System.Windows.MessageBox]::Show((T "Laufwerk D: wurde nicht gefunden."), "VRChat", 'OK', 'Warning'); return }
    $r = [System.Windows.MessageBox]::Show((T "Speicherort ändern? Der alte Cache wird gelöscht und VRChat lädt Avatare und Welten am neuen Ort neu herunter."), (T "Cache-Ort"), 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    try { Set-VrCacheLocation $(if ($toD) { 'D:\VRChatCache' } else { '' }) } catch { [void]$sync.Errors.Add("VRChat config.json: $_"); return }
    $cacheJob.Next = 'scan'
    Start-CacheJob 'all' $old
} 0xE8DE 'indigo' "..."
[void](Add-ActionRow $s "Cache-Ordner öffnen" {
    $d = Get-VrCacheDir; if (-not (Test-Path $d)) { $d = Split-Path $d }
    if (Test-Path $d) { Start-Process explorer.exe $d }
} 0xE838 'teal')

# ---------------- Musik im Mic ----------------
$MM = if ($musicMicOk) { [MusicMicAudio.MusicMic] } else { $null }
# Einstellungen an die Audio-Engine geben und sie passend starten/stoppen
function Sync-MusicMic {
    if (-not $MM -or $Snapshot) { return }
    $MM::MusicVolume = [float]([double]$cfg.MusicMicVolume / 100)
    $MM::VoiceVolume = [float]([double]$cfg.MicVoiceVolume / 100)
    $MM::GateStrength = [float]([double]$cfg.MicGate / 100)
    $MM::Normalize = [bool]$cfg.MusicMicNormalize; $MM::Duck = [bool]$cfg.MusicMicDuck; $MM::UseVoice = [bool]$cfg.MusicMicVoice
    if ("$($cfg.MusicMicCable)" -and -not ((Get-DeviceOptions 0 "") | Where-Object { "$($_[1])" -eq "$($cfg.MusicMicCable)" })) { $cfg.MusicMicCable = ""; Save-Config }
    $MM::MicId = "$($cfg.MusicMicDevice)"; $MM::CableId = "$($cfg.MusicMicCable)"
    if ($cfg.MusicMic -and -not $MM::IsRunning) { $MM::Start() }
    elseif (-not $cfg.MusicMic -and $MM::IsRunning) { $MM::Stop() }
}
# $flow 0 = nur virtuelle Kabel (Ziel), 1 = echte Mikrofone (ohne Kabel, sonst Rueckkopplung)
function Get-DeviceOptions([int]$flow, [string]$first) {
    $o = @(,@((T $first), ""))
    if ($MM) {
        foreach ($d in $MM::GetDevices($flow)) {
            $x = $d -split "`t", 2
            $isCable = $MM::IsCableName($x[1]) -or $x[1] -match '(?i)cable output|voicemeeter out'
            if (($flow -eq 0) -eq $isCable) { $o += ,@($x[1], $x[0]) }
        }
    }
    ,$o
}
# Pegelanzeige: schmale Leiste, die sich mit der Lautstaerke fuellt
function New-Meter($panel, [string]$label, [int]$icon, [string]$color) {
    Add-Divider $panel $true
    $g = New-Object System.Windows.Controls.Grid; $g.Margin = New-Margin 0 10 0 10
    foreach ($w in 'Auto', '*') {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = if ($w -eq '*') { New-Object System.Windows.GridLength(1, 'Star') } else { New-Object System.Windows.GridLength 190 }
        [void]$g.ColumnDefinitions.Add($cd)
    }
    [void]$g.Children.Add((New-RowLabel $label "" $icon $color))
    $track = New-Object System.Windows.Controls.Border
    $track.Height = 8; $track.CornerRadius = 4; $track.VerticalAlignment = 'Center'
    $track.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'C.Input')
    [System.Windows.Controls.Grid]::SetColumn($track, 1)
    $fill = New-Object System.Windows.Controls.Border
    $fill.CornerRadius = 4; $fill.HorizontalAlignment = 'Left'; $fill.Width = 0
    $fill.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'C.Accent')
    $track.Child = $fill
    [void]$g.Children.Add($track)
    [void]$panel.Children.Add($g)
    @{ Track = $track; Fill = $fill }
}

$p = New-Page 'mic'
if (-not $musicMicOk) { Add-Hint $p.Full "Die Audio-Engine konnte nicht geladen werden (MusicMic.cs fehlt?)." | Out-Null }
$s = New-Section $p.Full "" "Spotify hörst du selbst ganz normal weiter. VRChat-Sounds und andere Spieler kommen nicht mit ins Mikrofon, nur Spotify."
Add-Switch $s "Song über dein Mikrofon abspielen" 'MusicMic' "Aus" { Sync-MusicMic } -icon 0xE720 -color 'green'
$micUi = @{ Status = $s.Children[$s.Children.Count - 1].Content.Children[1].Children[1] }
$micUi.Music = New-Meter $s "Spotify" 0xE8D6 'green'
$micUi.Voice = New-Meter $s "Deine Stimme" 0xE720 'blue'
$micUi.Out = New-Meter $s "Das hören die anderen" 0xE767 'orange'

$s = New-Section $p.Left "Lautstärke" "Rauschsperre: Dein Mikro ist stumm, solange du nicht sprichst. Rauscht es noch, höher stellen. Werden Wörter abgeschnitten, niedriger. 0 = aus."
Add-Slider $s "Musik" 'MusicMicVolume' 0 200 5 "%" -icon 0xE8D6 -color 'green' -fmt '{0:0}' -after { Sync-MusicMic }
Add-Slider $s "Stimme" 'MicVoiceVolume' 0 200 5 "%" -icon 0xE720 -color 'blue' -fmt '{0:0}' -after { Sync-MusicMic }
Add-Slider $s "Rauschsperre" 'MicGate' 0 100 5 "%" -icon 0xE7BA -color 'red' -fmt '{0:0}' -after { Sync-MusicMic }
Add-Switch $s "Lautstärke angleichen" 'MusicMicNormalize' "Jeder Song kommt gleich laut an" { Sync-MusicMic } -icon 0xE9E9 -color 'purple'
Add-Switch $s "Musik leiser, wenn du sprichst" 'MusicMicDuck' "Damit man dich immer versteht" { Sync-MusicMic } -icon 0xE767 -color 'orange'
Add-Switch $s "Stimme mitschicken" 'MusicMicVoice' "Aus = nur Musik, du bist dann stumm" { Sync-MusicMic } -icon 0xE720 -color 'teal'

$s = New-Section $p.Right "Geräte"
Add-Dropdown $s "Mikrofon" 'MusicMicDevice' (Get-DeviceOptions 1 "Windows-Standard") -icon 0xE720 -color 'blue' -after { Sync-MusicMic }
Add-Dropdown $s "Kabel" 'MusicMicCable' (Get-DeviceOptions 0 "Automatisch finden") -icon 0xE7F6 -color 'indigo' -after { Sync-MusicMic }

$s = New-Section $p.Right "Einrichtung (einmalig)" "Am Ende hört VRChat auf das Kabel und das Tool mischt dort Musik und Stimme zusammen."
[void](Add-ActionRow $s "1. VB-CABLE installieren" { Start-Process "https://vb-audio.com/Cable/" } 0xE896 'green' "Kostenloses virtuelles Mikrofon. Danach PC neu starten.")
Add-Divider $s $true
$st2 = New-RowLabel "2. In VRChat als Mikrofon wählen" "Einstellungen > Audio > Mikrofon: CABLE Output" 0xE7FC 'indigo'; $st2.Margin = New-Margin 0 11 0 11
[void]$s.Children.Add($st2)
Add-Divider $s $true
$st3 = New-RowLabel "3. Rauschunterdrückung aus" "In VRChat bei Audio > Mikrofon. Sonst filtert VRChat die Musik weg." 0xE7BA 'orange'; $st3.Margin = New-Margin 0 11 0 11
[void]$s.Children.Add($st3)
[void](Add-ActionRow $s "Windows-Soundeinstellungen" { Start-Process "ms-settings:sound" } 0xE767 'gray')

function Update-MicPage {
    if (-not $MM) { return }
    $run = $MM::IsRunning; $st = "$($MM::Status)"
    $txt = if (-not $cfg.MusicMic) { T "Aus" }
        elseif ($st -eq 'nocable') { T "Kein virtuelles Kabel gefunden, siehe Einrichtung" }
        elseif ($st -eq 'error') { "$(T 'Fehler'): $($MM::Error)" }
        elseif ($st -eq 'ok' -and $MM::MusicAttached) { "$(T 'Läuft') $([char]0x2192) $($MM::CableName)" }
        elseif ($st -eq 'ok') { "$(T 'Wartet auf Spotify') $([char]0x2192) $($MM::CableName)" }
        else { T "Startet..." }
    if ($st -eq 'ok' -and $cfg.MusicMicVoice -and $cfg.MicGate -gt 0) { $txt += "  $([char]0x00B7)  " + $(if ($MM::VoiceOpen) { T "Mikro offen" } else { T "Mikro stumm (Rauschsperre)" }) }
    if ($st -eq 'ok' -and "$($MM::Error)") { $txt += "  $([char]0x00B7)  $($MM::Error)" }
    $micUi.Status.Text = $txt
    foreach ($m in @(@($micUi.Music, $MM::MusicLevel), @($micUi.Voice, $MM::VoiceLevel), @($micUi.Out, $MM::OutLevel))) {
        $lvl = if ($run) { [Math]::Min(1, [Math]::Sqrt([double]$m[1])) } else { 0 }   # Wurzel: leise Pegel sichtbarer
        $m[0].Fill.Width = [Math]::Max(0, $m[0].Track.ActualWidth * $lvl)
    }
}
# Pegel fluessig anzeigen (eigener schneller Timer, arbeitet nur auf dieser Seite)
$micTimer = New-Object System.Windows.Threading.DispatcherTimer
$micTimer.Interval = [TimeSpan]::FromMilliseconds(50)
$micTimer.add_Tick({ if ($state.Page -eq 'mic' -and $window.IsVisible) { try { Update-MicPage } catch { } } })
$micTimer.Start()
Sync-MusicMic

# ---------------- Statistik ----------------
$p = New-Page 'stats'
$rangeSeg = New-Segmented @(@("7 Tage", 7), @("30 Tage", 30), @("Gesamt", 0)) 7 { $state.StatsRange = $this.Tag.Value; Update-Stats } 'range'
$rangeSeg.Element.Width = 320; $rangeSeg.Element.HorizontalAlignment = 'Left'; $rangeSeg.Element.Margin = New-Margin 0 0 0 16
[void]$p.Full.Children.Add($rangeSeg.Element)
$statTiles = New-Object System.Windows.Controls.Primitives.UniformGrid; $statTiles.Columns = 4; $statTiles.Margin = New-Margin 0 0 -14 6
[void]$p.Full.Children.Add($statTiles)
$st2 = @{
    Today = New-Tile $statTiles 'Heute gehört' 0xE916 'orange'
    Week  = New-Tile $statTiles '7 Tage gehört' 0xE787 'blue'
    Total = New-Tile $statTiles 'Songs im Verlauf' 0xE8D6 'pink'
    Fav   = New-Tile $statTiles 'Lieblings-Künstler' 0xE734 'yellow'
}
# Wochen-Diagramm: Hoerzeit der letzten 7 Tage
$s = New-Section $p.Full "Diese Woche"
$chart = New-Object System.Windows.Controls.Primitives.UniformGrid; $chart.Rows = 1; $chart.Columns = 7; $chart.Height = 170; $chart.Margin = New-Margin 0 12 0 8
[void]$s.Children.Add($chart)
$topSongs = New-Section $p.Left "Top-Songs"
$topArtists = New-Section $p.Right "Top-Künstler"
$recent = New-Section $p.Right "Zuletzt gehört"
$s = New-Section $p.Left "Teilen"
[void](Add-ActionRow $s "Song kopieren" { $i = $sync.Info; if ($i) { [System.Windows.Clipboard]::SetText("$($i.Title) - $($i.Artist)") } } 0xE8C8 'blue')
[void](Add-ActionRow $s "Spotify-Link kopieren" {
    $i = $sync.Info
    if ($i) { [System.Windows.Clipboard]::SetText("https://open.spotify.com/search/$([uri]::EscapeDataString("$($i.Title) $($i.Artist)"))") }
} 0xE71B 'green')
[void](Add-ActionRow $s "Verlauf öffnen" {
    if (-not (Test-Path $historyPath)) { New-Item $historyPath -ItemType File | Out-Null }
    Start-Process notepad.exe "`"$historyPath`""
} 0xE81C 'orange')

function Get-History {
    if (-not (Test-Path $historyPath)) { return @() }
    foreach ($line in (Get-Content $historyPath -Encoding UTF8)) {
        if ($line -match "^(\d{4}-\d\d-\d\d \d\d:\d\d)\t(.*)\t(.*)\t(\d+)$") {
            [pscustomobject]@{ Time = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm', $null); Title = $Matches[2]; Artist = $Matches[3] }
        } elseif ($line -match "^(\d{4}-\d\d-\d\d \d\d:\d\d)  (.+) - (.+)$") {
            [pscustomobject]@{ Time = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm', $null); Title = $Matches[2]; Artist = $Matches[3] }
        }
    }
}

# Listenzeile; bei Ranglisten mit kleinem Balken, der die Anzahl zeigt
function Add-ListRow($panel, [string]$rank, [string]$text, [string]$right, [double]$share = -1) {
    Add-Divider $panel $false
    $wrap = New-Object System.Windows.Controls.StackPanel
    $wrap.Margin = New-Margin 0 9 0 9
    $g = New-Object System.Windows.Controls.Grid
    foreach ($w in @('Auto', '*', 'Auto')) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = if ($w -eq '*') { New-Object System.Windows.GridLength(1, 'Star') } else { [System.Windows.GridLength]::Auto }
        [void]$g.ColumnDefinitions.Add($cd)
    }
    $a = New-Text $rank 12.5 'C.Accent' 'Bold'; $a.Width = $(if ($rank) { 26 } else { 0 })
    $b = New-Text $text 13 'C.Text'; $b.TextTrimming = 'CharacterEllipsis'; $b.TextWrapping = 'NoWrap'
    $c = New-Text $right 12 'C.Dim'; $c.Margin = New-Margin 10 0 0 0
    [System.Windows.Controls.Grid]::SetColumn($b, 1); [System.Windows.Controls.Grid]::SetColumn($c, 2)
    [void]$g.Children.Add($a); [void]$g.Children.Add($b); [void]$g.Children.Add($c)
    [void]$wrap.Children.Add($g)
    if ($share -ge 0) {
        $bar = New-Object System.Windows.Controls.Border
        $bar.Height = 3; $bar.CornerRadius = 1.5; $bar.HorizontalAlignment = 'Left'; $bar.Margin = New-Margin 26 6 0 0
        $bar.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'C.Accent')
        $bar.Opacity = 0.75; $bar.Width = 0
        $bar.Tag = $share
        $bar.add_Loaded({ Animate $this ([System.Windows.FrameworkElement]::WidthProperty) ([Math]::Max(4, ($this.Parent.ActualWidth - 26) * $this.Tag)) 600 0 })
        [void]$wrap.Children.Add($bar)
    }
    [void]$panel.Children.Add($wrap)
}

function Format-Short([double]$sec) {
    if ($sec -ge 3600) { "{0:0.#} h" -f ($sec / 3600) } else { "$([int]($sec / 60)) min" }
}

function Update-Stats {
    $all = @(Get-History)
    $from = if ($state.StatsRange -gt 0) { (Get-Date).AddDays(-$state.StatsRange) } else { [datetime]::MinValue }
    $range = @($all | Where-Object { $_.Time -ge $from })
    $topSongs.Children.Clear(); $topArtists.Children.Clear(); $recent.Children.Clear()
    $i = 0
    $songs = @($range | Group-Object { "$($_.Title) - $($_.Artist)" } | Sort-Object Count -Descending | Select-Object -First 10)
    foreach ($g in $songs) { $i++; Add-ListRow $topSongs "$i" $g.Name (Format-Count $g.Count) ($g.Count / $songs[0].Count) }
    if (-not $i) { $n = New-Text "Noch keine Songs im Verlauf" 12 'C.Dim'; $n.Margin = New-Margin 0 10 0 10; [void]$topSongs.Children.Add($n) }
    $i = 0
    $artists = @($range | Where-Object { "$($_.Artist)".Trim() } | Group-Object { ($_.Artist -split ',')[0].Trim() } | Sort-Object Count -Descending)
    foreach ($g in ($artists | Select-Object -First 10)) { $i++; Add-ListRow $topArtists "$i" $g.Name (Format-Count $g.Count) ($g.Count / $artists[0].Count) }
    foreach ($h in ($all | Select-Object -Last 10 | Sort-Object Time -Descending)) { Add-ListRow $recent "" "$($h.Title) - $($h.Artist)" ($h.Time.ToString('dd.MM. HH:mm')) }
    $days = @{}
    if (Test-Path $statsPath) { try { (Get-Content $statsPath -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $days[$_.Name] = [double]$_.Value } } catch {} }
    if ($sync.ListenToday -gt 0) { $days[(Get-Date -Format 'yyyy-MM-dd')] = [double]$sync.ListenToday }
    $week = 0.0; for ($n = 0; $n -lt 7; $n++) { $week += [double]$days[(Get-Date).AddDays(-$n).ToString('yyyy-MM-dd')] }
    $st2.Today.Text = Format-Duration $days[(Get-Date -Format 'yyyy-MM-dd')]
    $st2.Week.Text = Format-Duration $week
    $st2.Total.Text = "$($all.Count)"
    $st2.Fav.Text = if ($artists) { $artists[0].Name } else { "-" }

    # Wochen-Diagramm (Balken wachsen animiert)
    $chart.Children.Clear()
    $culture = [Globalization.CultureInfo]::GetCultureInfo($(if ($lang -eq 'de') { 'de-DE' } else { 'en-US' }))
    $vals = @(for ($n = 6; $n -ge 0; $n--) { [double]$days[(Get-Date).AddDays(-$n).ToString('yyyy-MM-dd')] })
    $max = [Math]::Max(60, ($vals | Measure-Object -Maximum).Maximum)
    for ($n = 6; $n -ge 0; $n--) {
        $v = $vals[6 - $n]
        $col = New-Object System.Windows.Controls.Grid
        foreach ($h in 'Auto', '*', 'Auto') { $rd = New-Object System.Windows.Controls.RowDefinition; $rd.Height = if ($h -eq '*') { New-Object System.Windows.GridLength(1, 'Star') } else { [System.Windows.GridLength]::Auto }; [void]$col.RowDefinitions.Add($rd) }
        $lbl = New-Text "" 10.5 'C.Dim'; $lbl.Text = if ($v -ge 60) { Format-Short $v } else { "" }; $lbl.HorizontalAlignment = 'Center'; $lbl.Margin = New-Margin 0 0 0 5
        $bar = New-Object System.Windows.Controls.Border
        $bar.Width = 30; $bar.CornerRadius = 8; $bar.VerticalAlignment = 'Bottom'; $bar.Height = 0
        $bar.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, $(if ($n -eq 0) { 'C.Accent' } else { 'C.AccentSoft' }))
        $bar.Tag = [Math]::Max(4, 110 * $v / $max)
        $bar.add_Loaded({ Animate $this ([System.Windows.FrameworkElement]::HeightProperty) $this.Tag 700 0 })
        $day = New-Text "" 11.5 $(if ($n -eq 0) { 'C.Text' } else { 'C.Dim' }) 'SemiBold'; $day.Text = (Get-Date).AddDays(-$n).ToString('ddd', $culture); $day.HorizontalAlignment = 'Center'; $day.Margin = New-Margin 0 7 0 0
        [System.Windows.Controls.Grid]::SetRow($bar, 1); [System.Windows.Controls.Grid]::SetRow($day, 2)
        [void]$col.Children.Add($lbl); [void]$col.Children.Add($bar); [void]$col.Children.Add($day)
        [void]$chart.Children.Add($col)
    }
}

# ---------------- Einstellungen ----------------
$p = New-Page 'settings'
$s = New-Section $p.Left "Aussehen"
Add-Segment $s "Sprache der App" 'Language' @(@((T "Automatisch"), "auto"), @("Deutsch", "de"), @("English", "en")) { Restart-App } -icon 0xE774 -color 'blue' -desc "Das Panel startet nach dem Wechsel kurz neu" -NoTranslate
Add-Segment $s "Design" 'Theme' @(@("Dunkel", "dark"), @("Hell", "light")) { Apply-Theme; Update-HeroShade } -icon 0xE793 -color 'indigo'
Add-Switch $s "Animationen reduzieren" 'ReduceMotion' "Schaltet Bewegungen und weiche Übergänge weitgehend ab" { foreach ($l in $eqLoops) { Set-Loop $l (-not $cfg.ReduceMotion -and [bool]$state.Playing) }; foreach ($l in $dotLoop) { Set-Loop $l (-not $cfg.ReduceMotion -and [bool]$state.Connected) } } -icon 0xE71A -color 'teal'
# Akzentfarbe als Farbkreise
Add-Divider $s $true
$accRow = New-Object System.Windows.Controls.StackPanel; $accRow.Margin = New-Margin 0 11 0 10
$al = New-RowLabel "Akzentfarbe" "Wird genutzt, wenn ein Song kein farbiges Cover hat" 0xE790 'pink'; $al.Margin = New-Margin 0 0 0 8
[void]$accRow.Children.Add($al)
$dots = New-Object System.Windows.Controls.WrapPanel; $dots.Margin = New-Margin 38 0 0 0
foreach ($k in $accents.Keys) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.Style = $app.Resources['ColorDot']; $rb.GroupName = 'accent'
    $rb.Background = New-Brush $accents[$k]; $rb.ToolTip = T $k
    $rb.Tag = @{ Key = 'Accent'; Value = $accents[$k] }
    $rb.IsChecked = ("$($cfg.Accent)" -eq $accents[$k])
    $rb.add_Checked({
        if ($state.Refreshing) { return }
        $cfg.Accent = $this.Tag.Value
        Save-Config; Apply-Theme; Update-HeroShade; Update-EnabledButton; Update-TrayIcon
    })
    [void]$dots.Children.Add($rb)
    [void]$bound.Add(@{ Type = 'pill'; Control = $rb; Key = 'Accent'; Value = $accents[$k] })
}
[void]$accRow.Children.Add($dots)
[void]$s.Children.Add($accRow)
Add-Switch $s "Farben vom Song übernehmen" 'CoverColors' "Akzentfarbe passt sich dem Albumcover an" { Update-Accent 600; Update-HeroShade } -icon 0xE7F4 -color 'purple'
Add-Switch $s "Panel immer im Vordergrund" 'AlwaysOnTop' "" { $window.Topmost = [bool]$cfg.AlwaysOnTop } -icon 0xE718 -color 'gray'

$s = New-Section $p.Left "Musik-Quelle"
Add-Switch $s "Andere Musik-Apps erlauben" 'AnyPlayer' "Wenn Spotify nicht läuft: Apple Music, Amazon Music, Deezer, YouTube Music usw. Normale YouTube-Videos werden ignoriert." -icon 0xE8D6 -color 'green'

$s = New-Section $p.Right "Start & Verlauf"
# Autostart ist keine normale Einstellung, sondern eine Verknuepfung im Autostart-Ordner
$cbAuto = New-Object System.Windows.Controls.CheckBox
$cbAuto.Style = $app.Resources['Switch']
$cbAuto.Content = New-RowLabel "Mit Windows starten" "" 0xE7E8 'green'
$cbAuto.IsChecked = Test-Path $startupLnk
[void]$s.Children.Add($cbAuto)
$cbAuto.add_Click({
    if ($this.IsChecked) {
        $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($startupLnk)
        $lnk.TargetPath = "wscript.exe"; $lnk.Arguments = "`"$(Join-Path $dir 'StartHidden.vbs')`""; $lnk.WorkingDirectory = $dir
        $lnk.Save()
    } elseif (Test-Path $startupLnk) { Remove-Item $startupLnk }
})
$s = New-Section $p.Right "Songwechsel-Popup"
Add-Switch $s "Benachrichtigung bei Songwechsel" 'Notify' "Dezentes Popup auf dem Desktop und in VR über XSOverlay" { if ($cfg.Notify) { Show-SongToast -Force } } -icon 0xEA8F -color 'red'
Add-Switch $s "Desktop-Popup" 'NotifyDesktop' "Songkarte auf deinem Bildschirm anzeigen" -icon 0xE7F4 -color 'blue'
Add-Switch $s "In-VR-Benachrichtigung" 'NotifyInVR' "Songwechsel über XSOverlay in VR anzeigen, falls installiert" -icon 0xE7F4 -color 'purple'
Add-Switch $s "Cover im Popup-Hintergrund" 'PopupCoverBackground' "Albumcover weichgezeichnet hinter der Songkarte anzeigen" -icon 0xE91B -color 'pink'
Add-Dropdown $s "Popup-Position" 'NotifyPosition' @(
    @((T "Unten rechts"), "bottom-right"), @((T "Unten links"), "bottom-left"),
    @((T "Oben rechts"), "top-right"), @((T "Oben links"), "top-left")
) -icon 0xE8A7 -color 'purple' -desc "Wo das Song-Popup auf dem Bildschirm erscheint"
Add-Segment $s "Popup-Dauer" 'NotifyDuration' @(@("3 s", 3), @("5 s", 5), @("8 s", 8)) -icon 0xE823 -color 'teal' -desc "Wie lange das Popup sichtbar bleibt"
$s = New-Section $p.Right "Daten"
Add-Switch $s "Song-Verlauf speichern" 'History' "Wird für die Statistik gebraucht" -icon 0xE81C -color 'orange'

$s = New-Section $p.Right "Programm"
$shortcutRow = Add-ActionRow $s "Desktop-Verknüpfung erstellen" { Build-Shortcut } 0xE7B8 'blue' "Mit dem Spotify-Chatbox-App-Symbol"
$exeStatus = $shortcutRow.Content.Children[1].Children[1]   # Beschreibung zeigt danach das Ergebnis
[void](Add-ActionRow $s "Programm-Ordner öffnen" { Start-Process explorer.exe $dir } 0xE838 'teal')
[void](Add-ActionRow $s "Tool beenden" { Exit-App } 0xE7E8 'red' -Danger)

$s = New-Section $p.Right "Sichern & Zurücksetzen"
[void](Add-ActionRow $s "Einstellungen exportieren" {
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.FileName = "spotify-chatbox-einstellungen.json"; $dlg.Filter = "JSON|*.json"
    if ($dlg.ShowDialog()) { @{ Settings = $cfg } | ConvertTo-Json -Depth 6 | Set-Content $dlg.FileName -Encoding UTF8 }
} 0xEDE1 'green')
[void](Add-ActionRow $s "Einstellungen importieren" {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = "JSON|*.json"
    if ($dlg.ShowDialog()) {
        try {
            $data = Get-Content $dlg.FileName -Raw -Encoding UTF8 | ConvertFrom-Json
            Import-ConfigValues $(if ($data.Settings) { $data.Settings } else { $data })
            Save-Config; Refresh-All
        } catch { [void]$sync.Errors.Add("Import: $_") }
    }
} 0xE8B5 'indigo')
[void](Add-ActionRow $s "Auf Standard zurücksetzen" {
    $r = [System.Windows.MessageBox]::Show((T "Alle Einstellungen auf Standard zurücksetzen?"), (T "Zurücksetzen"), 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    $def = New-DefaultConfig
    foreach ($k in @($def.Keys)) { $cfg[$k] = $def[$k] }
    Save-Config; Refresh-All
} 0xE72C 'red' -Danger)

# ---------------- Erweitert ----------------
$p = New-Page 'advanced'
$s = New-Section $p.Left "Verbindung" "Nur ändern, wenn VRChat auf einem anderen Gerät läuft (z. B. Quest über WLAN)."
[void](Add-TextSetting $s "IP-Adresse" 'OscHost' "Standard: 127.0.0.1" -icon 0xE968 -color 'blue')
[void](Add-TextSetting $s "Port" 'OscPort' "Standard: 9000" -icon 0xE8CE -color 'indigo')
$testRow = Add-ActionRow $s "Verbindung testen" {
    $sync.TestResult = $null; $state.TestAt = Get-Date
    $sync.Commands.Enqueue('test')
    $testStatus.Text = T "Sende Testnachricht..."
} 0xE724 'green' "Schickt eine kurze Nachricht in die Chatbox"
$testStatus = $testRow.Content.Children[1].Children[1]   # Beschreibung zeigt das Ergebnis

$s = New-Section $p.Left "Lyrics-Timing" "Plus = Lyrics kommen früher, Minus = später."
Add-Slider $s "Versatz" 'LyricsOffset' -3 3 0.1 "s" -icon 0xE916 -color 'green'

$s = New-Section $p.Right "Hilfe & Diagnose" "Nur bei Verbindungsproblemen relevant."
$errBox = New-Object System.Windows.Controls.TextBox
$errBox.IsReadOnly = $true; $errBox.Height = 160; $errBox.TextWrapping = 'Wrap'; $errBox.VerticalScrollBarVisibility = 'Auto'; $errBox.FontSize = 11.5
$errBox.FontFamily = New-Object System.Windows.Media.FontFamily "Cascadia Mono, Consolas"; $errBox.Margin = New-Margin 0 12 0 10
[void]$s.Children.Add($errBox)
[void](Add-ActionRow $s "Log leeren" { $sync.Errors.Clear(); $state.ErrCount = -1 } 0xE74D 'gray')

# ============================== AKTIONEN ==============================
function Show-Page([string]$key) {
    foreach ($k in $pages.Keys) { $pages[$k].Root.Visibility = if ($k -eq $key) { 'Visible' } else { 'Collapsed' } }
    $index = 0; for ($i = 0; $i -lt $nav.Count; $i++) { if ($nav[$i].Key -eq $key) { $index = $i } }
    $n = $nav[$index]
    $ui.PageTitle.Text = T $n.Name; $ui.PageDesc.Text = T $n.Desc
    $first = -not $state.Page
    $state.Page = $key
    $pages[$key].Root.ScrollToHome()
    # Markierung gleitet zum neuen Eintrag, Seite blendet von unten ein
    Animate $ui.NavIndicator.RenderTransform ([System.Windows.Media.TranslateTransform]::YProperty) ($index * 45) $(if ($first) { 1 } else { 340 })
    Animate-In $pages[$key].Root
    if ($key -eq 'stats') { Update-Stats }
    if ($key -eq 'vrchat' -and $cacheJob.Version -eq 0) { Start-CacheJob 'scan' }
}

function Refresh-All {
    $state.Refreshing = $true
    foreach ($b in $bound) {
        switch ($b.Type) {
            'switch' { $b.Control.IsChecked = [bool]$cfg[$b.Key] }
            'pill'   { $b.Control.IsChecked = ("$($cfg[$b.Key])" -eq "$($b.Value)") }
            'slider' { $b.Control.Value = [double]$cfg[$b.Key] }
            'text'   { $b.Control.Text = "$($cfg[$b.Key])" }
            'combo'  { foreach ($it in $b.Control.Items) { if ("$($it.Tag)" -eq "$($cfg[$b.Key])") { $b.Control.SelectedItem = $it } } }
        }
    }
    $state.Refreshing = $false
    Apply-Theme; Update-EnabledButton; Update-TrayIcon
    $window.Topmost = [bool]$cfg.AlwaysOnTop
    $sync.Dirty = $true; $sync.SendNow = $true
}

function Apply-ChatProfile {
    $values = switch ("$($cfg.ChatProfile)") {
        'clean'   { @{ Compact = $false; ShowTitle = $true; ShowArtist = $true; ArtistOwnLine = $false; ShowAlbum = $false; ShowBar = $true; ShowLyrics = $false; LyricsMode = $false; HideTitleAfterLyrics = $false; SmallCaps = $false; ShowClock = $false; BlankLine = $false } }
        'lyrics'  { @{ Compact = $false; ShowTitle = $true; ShowArtist = $false; ArtistOwnLine = $false; ShowAlbum = $false; ShowBar = $false; ShowLyrics = $true; LyricsMode = $true; HideTitleAfterLyrics = $true; SmallCaps = $false; ShowClock = $false; BlankLine = $false } }
        'minimal' { @{ Compact = $true; ShowTitle = $true; ShowArtist = $true; ArtistOwnLine = $false; ShowAlbum = $false; ShowBar = $false; ShowLyrics = $false; LyricsMode = $false; HideTitleAfterLyrics = $false; SmallCaps = $false; ShowClock = $false; BlankLine = $false } }
        default { $null }
    }
    if (-not $values) { return }
    foreach ($key in $values.Keys) { $cfg[$key] = $values[$key] }
    Save-Config
    Refresh-All
}

function Test-Paused { [DateTime]::Now -lt $sync.PauseUntil }

function Update-EnabledButton {
    $state.PausedShown = Test-Paused
    if ($cfg.Enabled -and $state.PausedShown) {
        $ui.BtnEnabled.Content = "$([char]0x23F8)  $(T 'Pausiert bis') $($sync.PauseUntil.ToString('HH:mm'))"
        $ui.BtnEnabled.Background = $warnBrush; $ui.BtnEnabled.BorderBrush = $warnBrush; $ui.BtnEnabled.Foreground = [System.Windows.Media.Brushes]::Black
    } elseif ($cfg.Enabled) {
        $ui.BtnEnabled.Content = "$([char]0x25CF)  $(T 'Chatbox AN')"
        foreach ($pr in [System.Windows.Controls.Control]::BackgroundProperty, [System.Windows.Controls.Control]::BorderBrushProperty) { $ui.BtnEnabled.SetResourceReference($pr, 'C.Accent') }
        $ui.BtnEnabled.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'C.AccentText')
    } else {
        $ui.BtnEnabled.Content = "$([char]0x25CB)  $(T 'Chatbox AUS')"
        $ui.BtnEnabled.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'C.Input')
        $ui.BtnEnabled.SetResourceReference([System.Windows.Controls.Control]::BorderBrushProperty, 'C.Border')
        $ui.BtnEnabled.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'C.Text')
    }
}

function Set-Enabled([bool]$on) {
    $cfg.Enabled = $on
    $miEnabled.Checked = $on
    if ($on) { $sync.PauseUntil = [DateTime]::MinValue }
    Update-TrayIcon; Update-EnabledButton
    Save-Config
    $sync.Dirty = $true; $sync.SendNow = $true
    if (-not $window.IsVisible) { $tray.ShowBalloonTip(1500, "ChatTune", (T $(if ($on) { 'Chatbox eingeschaltet' } else { 'Chatbox ausgeschaltet' })), 'None') }
}

# Pause in Minuten (0 = Pause beenden)
function Set-Pause([int]$minutes) {
    if ($minutes -gt 0 -and -not $cfg.Enabled) { Set-Enabled $true }
    $sync.PauseUntil = if ($minutes -gt 0) { [DateTime]::Now.AddMinutes($minutes) } else { [DateTime]::MinValue }
    Update-EnabledButton
    $sync.Dirty = $true; $sync.SendNow = $true
    if (-not $window.IsVisible) {
        $msg = if ($minutes -gt 0) { "$(T 'Pausiert bis') $($sync.PauseUntil.ToString('HH:mm'))" } else { T 'Chatbox läuft wieder' }
        $tray.ShowBalloonTip(1500, "ChatTune", $msg, 'None')
    }
}

function Show-Panel {
    $wasVisible = $window.IsVisible
    $window.Show()
    if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }
    $window.Topmost = $true
    [void]$window.Activate()
    $window.Topmost = [bool]$cfg.AlwaysOnTop
    if (-not $wasVisible) {
        [System.Windows.Input.Keyboard]::ClearFocus(); $state.ScrollHome = 6
        # sanft aufzoomen
        Animate $ui.Root ([System.Windows.UIElement]::OpacityProperty) 1 220 0
        Animate $ui.Root.RenderTransform ([System.Windows.Media.ScaleTransform]::ScaleXProperty) 1 320 0.97
        Animate $ui.Root.RenderTransform ([System.Windows.Media.ScaleTransform]::ScaleYProperty) 1 320 0.97
    }
}

function Exit-App {
    $state.Exiting = $true
    $sync.Exit = $true
    if ($MM) { try { $MM::Stop() } catch { } }
    [void]$workerHandle.AsyncWaitHandle.WaitOne(3000)   # Hintergrund-Thread leert noch die Chatbox
    foreach ($hk in $hotkeys) { $hk.Release() }
    $tray.Visible = $false
    $tray.Dispose()
    $window.Close()
    $app.Shutdown()
}

# Neu starten (z. B. nach Sprachwechsel): neue Instanz startet, sobald diese beendet ist
function Restart-App {
    Save-Config
    $script = Join-Path $dir "SpotifyToVRChat.ps1"
    Start-Process powershell -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-Command',
        "Start-Sleep -Seconds 4; & '$($script.Replace("'", "''"))' -ShowPanel")
    Exit-App
}

# Icon-Bild (Kreis in Akzentfarbe mit Note)
function New-IconBitmap([int]$size, [System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $color), 1, 1, $size - 2, $size - 2)
    $font = New-Object System.Drawing.Font('Segoe UI Symbol', [float]($size * 0.58), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $g.DrawString([string][char]0x266B, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, ($size * 0.03), $size, $size), $fmt)
    $g.Dispose()
    $bmp
}

function Build-Shortcut {
    try {
        $icoPath = Join-Path $dir 'assets\app.ico'
        if (-not (Test-Path $icoPath)) { throw "App-Symbol fehlt: $icoPath" }

        $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) "ChatTune.lnk"))
        $lnk.TargetPath = "wscript.exe"; $lnk.Arguments = "`"$(Join-Path $dir 'Panel.vbs')`""
        $lnk.WorkingDirectory = $dir; $lnk.IconLocation = $icoPath
        $lnk.Save()
        $exeStatus.Text = T "Fertig: Verknüpfung 'ChatTune' auf dem Desktop."
    } catch {
        $exeStatus.Text = "Fehler: $_"
        [void]$sync.Errors.Add("Verknüpfung: $_")
    }
}

# ============================== FENSTER-KNÖPFE ==============================
$ui.BtnEnabled.add_Click({ if ($cfg.Enabled -and (Test-Paused)) { Set-Pause 0 } else { Set-Enabled (-not $cfg.Enabled) } })

# Pause-Menue: klappt unter dem Pause-Knopf oben rechts auf
$ui.BtnPause.Content = "$(Icon 0xE769)"; $ui.BtnPause.FontFamily = $app.Resources['Icons']; $ui.BtnPause.ToolTip = T "Chatbox pausieren"
$pausePop = New-Object System.Windows.Controls.Primitives.Popup
$pausePop.PlacementTarget = $ui.BtnPause; $pausePop.Placement = 'Bottom'; $pausePop.StaysOpen = $false
$pausePop.AllowsTransparency = $true; $pausePop.PopupAnimation = 'Fade'; $pausePop.VerticalOffset = -4
$popCard = New-Object System.Windows.Controls.Border
$popCard.Style = $app.Resources['Card']; $popCard.Width = 300; $popCard.Margin = New-Margin 14 14 14 18; $popCard.Padding = New-Margin 18 16 18 12
$popCard.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'C.Solid')
$sh = New-Object System.Windows.Media.Effects.DropShadowEffect; $sh.BlurRadius = 22; $sh.ShadowDepth = 4; $sh.Opacity = 0.35; $sh.Direction = 270
$popCard.Effect = $sh
# eigene Schrift setzen, sonst erbt das Menue die Symbol-Schrift vom Pause-Knopf
[System.Windows.Documents.TextElement]::SetFontFamily($popCard, $app.Resources['Body']); [System.Windows.Documents.TextElement]::SetFontSize($popCard, 13.0)
$pp = New-Object System.Windows.Controls.StackPanel
[void]$pp.Children.Add((New-Text "Chatbox pausieren" 14.5 'C.Text' 'SemiBold'))
$pd = New-Text "Die Chatbox verschwindet und kommt danach von selbst zurück." 11.5 'C.Dim'; $pd.Margin = New-Margin 0 3 0 12
[void]$pp.Children.Add($pd)
$popResume = New-Object System.Windows.Controls.Grid; $popResume.Margin = New-Margin 0 0 0 12
$popUntil = New-Text "" 13 'C.Text' 'SemiBold'; $popUntil.VerticalAlignment = 'Center'
[void]$popResume.Children.Add($popUntil)
$rb = Add-Button $popResume "Weiter" { Set-Pause 0; $pausePop.IsOpen = $false } -Accent; $rb.HorizontalAlignment = 'Right'; $rb.Margin = New-Margin 0
[void]$pp.Children.Add($popResume)
$qg = New-Object System.Windows.Controls.Primitives.UniformGrid; $qg.Rows = 1; $qg.Columns = 4; $qg.Margin = New-Margin 0 0 -8 0
foreach ($m in 5, 15, 30, 60) { $b = Add-Button $qg "$m min" { Set-Pause $this.Tag; $pausePop.IsOpen = $false }; $b.Tag = $m; $b.Padding = New-Margin 0 8 0 8 }
[void]$pp.Children.Add($qg)
$cr = New-Object System.Windows.Controls.Grid; $cr.Margin = New-Margin 0 4 0 4
$cl = New-Text "Eigene Dauer" 13 'C.Text'; $cl.VerticalAlignment = 'Center'
[void]$cr.Children.Add($cl)
$crr = New-Object System.Windows.Controls.StackPanel; $crr.Orientation = 'Horizontal'; $crr.HorizontalAlignment = 'Right'
$pauseBox = New-Object System.Windows.Controls.TextBox; $pauseBox.Width = 56; $pauseBox.Text = "45"; $pauseBox.TextAlignment = 'Center'; $pauseBox.VerticalAlignment = 'Center'
$pl = New-Text "min" 13 'C.Dim'; $pl.VerticalAlignment = 'Center'; $pl.Margin = New-Margin 8 0 10 0
$startPause = { $m = 0; if ([int]::TryParse($pauseBox.Text.Trim(), [ref]$m) -and $m -gt 0 -and $m -le 1440) { Set-Pause $m; $pausePop.IsOpen = $false } else { $pauseBox.Focus() | Out-Null; $pauseBox.SelectAll() } }
[void]$crr.Children.Add($pauseBox); [void]$crr.Children.Add($pl)
$sb = Add-Button $crr "Start" $startPause -Accent; $sb.Margin = New-Margin 0
$pauseBox.add_KeyDown({ if ($_.Key -eq 'Return') { & $startPause } })
[void]$cr.Children.Add($crr)
[void]$pp.Children.Add($cr)
$popCard.Child = $pp
$pausePop.Child = $popCard
$ui.BtnPause.add_Click({
    $popResume.Visibility = if (Test-Paused) { 'Visible' } else { 'Collapsed' }
    $popUntil.Text = "$(T 'Pausiert bis') $($sync.PauseUntil.ToString('HH:mm'))"
    # rechtsbuendig unter dem Knopf, damit das Menue nicht aus dem Fenster ragt
    $pausePop.HorizontalOffset = $ui.BtnPause.ActualWidth - 328 + 14
    # Klick auf den Knopf bei offenem Menue schliesst es (das Popup hat sich dann gerade selbst geschlossen)
    if ($state.PopClosed -and ((Get-Date) - $state.PopClosed).TotalMilliseconds -lt 300) { return }
    $pausePop.IsOpen = $true
})
$pausePop.add_Closed({ $state.PopClosed = Get-Date })
$ui.BtnMin.add_Click({ $window.WindowState = 'Minimized' })
$ui.BtnClose.add_Click({ $window.Hide() })
$ui.TitleBar.add_MouseLeftButtonDown({ $window.DragMove() })
$ui.Brand.add_MouseLeftButtonDown({ $window.DragMove() })
$window.add_Closing({ if (-not $state.Exiting) { $_.Cancel = $true; $window.Hide() } })
$window.Topmost = [bool]$cfg.AlwaysOnTop
# Nicht automatisch zu Elementen mit Fokus springen
foreach ($pg in $pages.Values) { $pg.Root.Content.add_RequestBringIntoView({ $_.Handled = $true }) }
# Endlos-Animationen anhalten, solange das Fenster versteckt ist
$window.add_IsVisibleChanged({ if (-not $window.IsVisible) { foreach ($l in $eqLoops + $dotLoop) { Set-Loop $l $false }; $state.Playing = $null; $state.Connected = $null } })

# Pulsierender Punkt "VRChat verbunden"
$dotLoop = New-Loop $ui.DotGlow.RenderTransform ([System.Windows.Media.ScaleTransform]::ScaleXProperty) 1 2.3 1100
$dotLoopY = New-Loop $ui.DotGlow.RenderTransform ([System.Windows.Media.ScaleTransform]::ScaleYProperty) 1 2.3 1100
$dotLoop = @($dotLoop, $dotLoopY)

# ============================== TRAY ==============================
# Tray-Icon in der Akzentfarbe (grau = Chatbox aus)
function New-TrayIcon([System.Drawing.Color]$color) {
    $bmp = New-IconBitmap 64 $color
    $h = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($h).Clone()
    [void][Native]::DestroyIcon($h); $bmp.Dispose()
    $icon
}
$trayIcons = @{ Key = $null; Icon = $null }
function Update-TrayIcon {
    $key = if ($cfg.Enabled) { "$($cfg.Accent)" } else { 'off' }
    if ($trayIcons.Key -eq $key) { return }
    $color = if ($cfg.Enabled) { try { [System.Drawing.ColorTranslator]::FromHtml($cfg.Accent) } catch { [System.Drawing.Color]::FromArgb(30, 215, 96) } } else { [System.Drawing.Color]::Gray }
    $old = $trayIcons.Icon
    $trayIcons.Icon = New-TrayIcon $color; $trayIcons.Key = $key
    $tray.Icon = $trayIcons.Icon
    if ($old) { $old.Dispose() }
}
$tray = New-Object System.Windows.Forms.NotifyIcon
Update-TrayIcon
$tray.Text = "ChatTune"
$tray.Visible = -not $Snapshot
$menu = New-Object System.Windows.Forms.ContextMenuStrip
function Add-MenuItem($parent, [string]$text, [scriptblock]$onClick) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem (T $text)
    if ($onClick) { $item.add_Click($onClick) }
    if ($parent -is [System.Windows.Forms.ToolStripMenuItem]) { [void]$parent.DropDownItems.Add($item) } else { [void]$parent.Items.Add($item) }
    $item
}
$miPanel = Add-MenuItem $menu "Panel öffnen" { Show-Panel }
$miPanel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miSong = Add-MenuItem $menu "Spotify spielt nichts" $null
$miSong.Enabled = $false
[void](Add-MenuItem $menu "Play / Pause" { $sync.Commands.Enqueue('playpause') })
[void](Add-MenuItem $menu "Nächster Song" { $sync.Commands.Enqueue('next') })
[void](Add-MenuItem $menu "Vorheriger Song" { $sync.Commands.Enqueue('prev') })
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miEnabled = Add-MenuItem $menu "Chatbox anzeigen" { Set-Enabled (-not $cfg.Enabled) }
$miEnabled.Checked = $cfg.Enabled
$miPause = Add-MenuItem $menu "Pausieren" $null
foreach ($m in 5, 15, 30) { $it = Add-MenuItem $miPause "$m min" { Set-Pause $this.Tag }; $it.Tag = $m }
$miResume = Add-MenuItem $miPause "Weiter" { Set-Pause 0 }
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void](Add-MenuItem $menu "Beenden" { Exit-App })
$menu.add_Opening({ $miResume.Enabled = Test-Paused })
$tray.ContextMenuStrip = $menu
$tray.add_DoubleClick({ Show-Panel })
$tray.add_BalloonTipClicked({ Show-Panel })

# ============================== TASTENKÜRZEL ==============================
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;
public class HotkeyWindow : NativeWindow {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mod, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    public event EventHandler Pressed;
    public bool Registered;
    public string Action;
    public HotkeyWindow(uint mod, uint vk) { CreateHandle(new CreateParams()); Registered = RegisterHotKey(Handle, 1, mod, vk); }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && Pressed != null) Pressed(this, EventArgs.Empty);
        base.WndProc(ref m);
    }
    public void Release() { UnregisterHotKey(Handle, 1); DestroyHandle(); }
}
"@
# Modifier: 1 = Alt, 2 = Strg, 4 = Shift, 0x4000 = keine Wiederholung. Pro Aktion: erstes freies Kuerzel
$hotkeyPlan = @(
    @{ Action = 'toggle';    Name = 'Chatbox an/aus';     Keys = @(@(0x4003, 0x4D, "Strg+Alt+M"), @(0x4007, 0x4D, "Strg+Alt+Shift+M"), @(0x4003, 0x78, "Strg+Alt+F9")) }
    @{ Action = 'pause';     Name = '15 min pausieren / weiter'; Keys = @(@(0x4003, 0x50, "Strg+Alt+P"), @(0x4007, 0x50, "Strg+Alt+Shift+P")) }
    @{ Action = 'playpause'; Name = 'Play / Pause';       Keys = @(,@(0x4003, 0x26, "Strg+Alt+Pfeil hoch")) }
    @{ Action = 'next';      Name = 'Nächster Song';      Keys = @(,@(0x4003, 0x27, "Strg+Alt+Pfeil rechts")) }
    @{ Action = 'prev';      Name = 'Vorheriger Song';    Keys = @(,@(0x4003, 0x25, "Strg+Alt+Pfeil links")) }
    @{ Action = 'afk';       Name = 'AFK an/aus';         Keys = @(,@(0x4003, 0x28, "Strg+Alt+Pfeil runter")) }
)
$hotkeys = New-Object System.Collections.ArrayList
foreach ($plan in $hotkeyPlan) {
    foreach ($k in $plan.Keys) {
        if ($Snapshot) { break }
        $hk = New-Object HotkeyWindow($k[0], $k[1])
        if ($hk.Registered) {
            $hk.Action = $plan.Action
            $hk.add_Pressed({
                switch ($this.Action) {
                    'toggle' { Set-Enabled (-not $cfg.Enabled) }
                    'pause'  { if (Test-Paused) { Set-Pause 0 } else { Set-Pause 15 } }
                    'afk'    { $cfg.Afk = -not $cfg.Afk; Save-Config; Sync-Bound 'Afk' $null; $sync.SendNow = $true }
                    default  { $sync.Commands.Enqueue($this.Action) }
                }
            })
            [void]$hotkeys.Add($hk)
            if ($plan.Action -eq 'toggle') { $miEnabled.Text = "$(T 'Chatbox anzeigen')   ($(T $k[2]))" }
            break
        }
        $hk.Release()
    }
}

# ============================== LAUFENDE AKTUALISIERUNG ==============================
function New-CoverImage([byte[]]$bytes, [int]$width) {
    $img = New-Object System.Windows.Media.Imaging.BitmapImage
    $img.BeginInit(); $img.StreamSource = New-Object System.IO.MemoryStream(, $bytes)
    $img.CacheOption = 'OnLoad'; $img.DecodePixelWidth = $width; $img.EndInit(); $img.Freeze()
    $img
}
function Set-Cover([byte[]]$bytes) {
    if ($bytes) {
        $brush = New-Object System.Windows.Media.ImageBrush (New-CoverImage $bytes 330); $brush.Stretch = 'UniformToFill'
        $d.Cover.Background = $brush; $d.CoverIcon.Visibility = 'Collapsed'
        if ($toast.Win.IsVisible) {
            $toast.Art.Background = $brush
            $toast.Backdrop.Background = if ($cfg.PopupCoverBackground) { $brush } else { New-Brush (Get-ActiveAccent) }
        }
        # Dashboard-Hintergrund: dasselbe Cover, klein geladen (wird eh verschwommen) und weich eingeblendet
        $bg = New-Object System.Windows.Media.ImageBrush (New-CoverImage $bytes 120); $bg.Stretch = 'UniformToFill'
        $d.HeroImg.Background = $bg
        Animate $d.HeroArt ([System.Windows.UIElement]::OpacityProperty) 1 800 0.3
        Animate $d.Cover ([System.Windows.UIElement]::OpacityProperty) 1 450 0
        # Akzentfarbe der App an den Song anpassen (weich ueberblenden)
        $pal = try { Get-CoverPalette $bytes } catch { $null }
        $live.Accent = if ($pal) { $pal.Accent } else { $null }; $live.Lum = if ($pal) { $pal.Lum } else { $null }
    } else {
        $d.Cover.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'C.Input'); $d.CoverIcon.Visibility = 'Visible'
        Animate $d.HeroArt ([System.Windows.UIElement]::OpacityProperty) 0 400
        $live.Accent = $null; $live.Lum = $null
    }
    Update-Accent 900
    Update-HeroShade
}

# Songwechsel-Hinweis: eigenes kleines Fenster unten rechts (Windows-Benachrichtigungen werden beim Spielen
# oft von "Nicht stoeren" verschluckt) und - falls XSOverlay laeuft - zusaetzlich direkt in VR
$toastXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True" ShowInTaskbar="False"
        ShowActivated="False" ResizeMode="NoResize" Width="436" Height="132" FontFamily="{DynamicResource Body}">
  <!-- Nur 10 px Rand fuer den Schatten, alles andere ist die Karte selbst -->
  <Grid x:Name="Box" Margin="10" Cursor="Hand">
    <Grid.RenderTransform><TranslateTransform/></Grid.RenderTransform>
    <Border CornerRadius="20" Background="{DynamicResource C.Solid}">
      <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="3" Direction="270" Opacity="0.38"/></Border.Effect>
    </Border>
    <Grid x:Name="Inner">
      <Border x:Name="Backdrop" Margin="-60">
        <Border.Effect><BlurEffect Radius="45" RenderingBias="Performance" KernelType="Gaussian"/></Border.Effect>
      </Border>
      <Border x:Name="Shade"/>
      <Grid Margin="12">
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
        <Border x:Name="Art" Width="88" Height="88" CornerRadius="14" Background="{DynamicResource C.Input}">
          <Border.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="2" Direction="270" Opacity="0.45"/></Border.Effect>
        </Border>
        <StackPanel Grid.Column="1" Margin="16,0,10,0" VerticalAlignment="Center">
          <TextBlock x:Name="Cap" FontSize="10" FontWeight="Bold" Foreground="{DynamicResource C.Accent}"/>
          <TextBlock x:Name="Song" FontFamily="{DynamicResource Display}" FontSize="18" FontWeight="Bold" Foreground="{DynamicResource C.Text}" TextTrimming="CharacterEllipsis" Margin="0,4,0,0"/>
          <TextBlock x:Name="Artist" FontSize="13" Foreground="{DynamicResource C.Text}" Opacity="0.72" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
        </StackPanel>
      </Grid>
      <!-- Restzeit als duenne Linie ganz unten an der Kante -->
      <Border x:Name="ProgressTrack" Height="3" VerticalAlignment="Bottom" Background="#1AFFFFFF">
        <Border x:Name="Progress" Width="0" HorizontalAlignment="Left" Background="{DynamicResource C.Accent}"/>
      </Border>
    </Grid>
    <Border CornerRadius="20" BorderBrush="#22FFFFFF" BorderThickness="1" IsHitTestVisible="False"/>
  </Grid>
</Window>
'@
$toast = @{ Win = [Windows.Markup.XamlReader]::Parse($toastXaml); DueAt = $null; HideAt = $null; EnterX = 0; EnterY = 0 }
foreach ($n in 'Box', 'Inner', 'Art', 'Cap', 'Song', 'Artist', 'Progress', 'ProgressTrack', 'Backdrop', 'Shade') { $toast[$n] = $toast.Win.FindName($n) }
# Unschaerfe und Fortschrittslinie an den runden Ecken abschneiden
$toast.Inner.add_SizeChanged({ $this.Clip = New-Object System.Windows.Media.RectangleGeometry((New-Object System.Windows.Rect(0, 0, $this.ActualWidth, $this.ActualHeight)), 20, 20) })
$toast.Box.add_MouseLeftButtonUp({ $toast.Win.Hide(); Show-Panel })
function Send-XSOverlay([string]$title, [string]$content) {
    $json = @{ messageType = 1; index = 0; timeout = 3.0; height = 120.0; opacity = 1.0; volume = 0.0; audioPath = ""
               title = $title; content = $content; useBase64Icon = $false; icon = "default"; sourceApp = "ChatTune" } | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $u = New-Object System.Net.Sockets.UdpClient
    try { [void]$u.Send($bytes, $bytes.Length, "127.0.0.1", 42069) } catch { } finally { $u.Close() }
}
function Show-SongToast([switch]$Force) {
    $i = $sync.Info
    if (-not $i -or -not "$($i.Title)".Trim()) { return }
    if ($cfg.NotifyInVR -and (Get-Process XSOverlay -ErrorAction SilentlyContinue)) { Send-XSOverlay "$(T 'Läuft gerade')" "$($i.Title) - $($i.Artist)" }
    if (-not $cfg.NotifyDesktop) { return }
    if ($window.IsActive -and -not $Force) { return }   # Panel ist offen und im Vordergrund: dort sieht man es eh
    $toast.Cap.Text = (T "JETZT LÄUFT")
    $toast.Song.Text = $i.Title; $toast.Artist.Text = $i.Artist
    $toast.Shade.Background = New-ShadeBrush 120 175
    if ($d.Cover.Background -is [System.Windows.Media.ImageBrush]) {
        $toast.Art.Background = $d.Cover.Background
        if ($cfg.PopupCoverBackground) { $toast.Backdrop.Background = $d.Cover.Background }
        else { $toast.Backdrop.Background = New-Brush (Get-ActiveAccent) }
    } else {
        $toast.Art.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'C.Input')
        $toast.Backdrop.Background = New-Brush (Get-ActiveAccent)
    }
    $wa = [System.Windows.SystemParameters]::WorkArea
    $left = "$($cfg.NotifyPosition)".EndsWith('left')
    $top = "$($cfg.NotifyPosition)".StartsWith('top')
    $toast.Win.Left = if ($left) { $wa.Left + 8 } else { $wa.Right - $toast.Win.Width - 8 }
    $toast.Win.Top = if ($top) { $wa.Top + 8 } else { $wa.Bottom - $toast.Win.Height - 8 }
    if ($Snapshot) { $toast.Win.Left = -20000; $toast.Win.Top = -20000 }   # Testbilder nie sichtbar aufpoppen lassen
    $toast.EnterX = if ($left) { -34 } else { 34 }; $toast.EnterY = if ($top) { -18 } else { 18 }
    $toast.Box.RenderTransform.X = $toast.EnterX; $toast.Box.RenderTransform.Y = $toast.EnterY
    $toast.Box.Opacity = 0
    $toast.Win.Show()
    $toast.Win.UpdateLayout()
    Animate $toast.Box ([System.Windows.UIElement]::OpacityProperty) 1 300 0
    Animate $toast.Box.RenderTransform ([System.Windows.Media.TranslateTransform]::XProperty) 0 360 $toast.EnterX
    Animate $toast.Box.RenderTransform ([System.Windows.Media.TranslateTransform]::YProperty) 0 360 $toast.EnterY
    $duration = [Math]::Max(3, [Math]::Min(8, [int]$cfg.NotifyDuration))
    $toast.Progress.BeginAnimation([System.Windows.FrameworkElement]::WidthProperty, $null)
    $toast.Progress.Width = [Math]::Max(1, $toast.ProgressTrack.ActualWidth)
    Animate $toast.Progress ([System.Windows.FrameworkElement]::WidthProperty) 0 ($duration * 1000)
    $toast.HideAt = (Get-Date).AddSeconds($duration)
}

$fmtTime = { param([double]$s)"{0}:{1:00}" -f [int][Math]::Floor($s / 60), [int][Math]::Floor($s % 60) }

$uiTimer = New-Object System.Windows.Threading.DispatcherTimer
$uiTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$uiTimer.add_Tick({
    try {
        $now = Get-Date
        if ($showEvent.WaitOne(0)) { Show-Panel }
        if ((Test-Paused) -ne $state.PausedShown) { Update-EnabledButton }   # Pause abgelaufen

        # Cache-Berechnung/Loeschen im Hintergrund fertig
        if (-not $cacheJob.Busy -and $cacheJob.Version -ne $state.CacheVer) {
            $state.CacheVer = $cacheJob.Version
            Update-CacheUi
            if ($cacheJob.Next) { $next = $cacheJob.Next; $cacheJob.Next = $null; Start-CacheJob $next }
        }

        # Songwechsel -> Tray + Benachrichtigung
        $songEvent = $sync.SongEvent
        if ($songEvent) {
            $sync.SongEvent = $null
            $miSong.Text = if ($songEvent.Length -gt 55) { $songEvent.Substring(0, 52) + "..." } else { $songEvent }
            $tip = "$($sync.SongCount) $(T 'Songs') | $songEvent"
            $tray.Text = if ($tip.Length -gt 63) { $tip.Substring(0, 60) + "..." } else { $tip }
            # kurz warten, damit das Cover schon geladen ist
            if ($cfg.Notify) { $toast.DueAt = $now.AddSeconds(2.5) }
        }
        if ($toast.DueAt -and $now -ge $toast.DueAt) { $toast.DueAt = $null; Show-SongToast }
        if ($toast.HideAt -and $now -ge $toast.HideAt) {
            $toast.HideAt = $null
            Animate $toast.Box ([System.Windows.UIElement]::OpacityProperty) 0 350
            Animate $toast.Box.RenderTransform ([System.Windows.Media.TranslateTransform]::XProperty) $toast.EnterX 300
            Animate $toast.Box.RenderTransform ([System.Windows.Media.TranslateTransform]::YProperty) $toast.EnterY 300
            $toast.CloseAt = $now.AddMilliseconds(400)
        }
        if ($toast.CloseAt -and $now -ge $toast.CloseAt) { $toast.CloseAt = $null; $toast.Win.Hide() }

        $info = $sync.Info
        $pos = 0; $len = 0
        if ($info) {
            $len = $info.Length.TotalSeconds
            $pos = $info.Pos.TotalSeconds
            if ($info.Playing) { $pos += ($now - $sync.SampleTime).TotalSeconds }
            if ($pos -gt $len) { $pos = $len }
        }
        $frac = if ($len -gt 0) { $pos / $len } else { 0 }

        if ($sync.CoverKey -ne $state.CoverKey) { $state.CoverKey = $sync.CoverKey; Set-Cover $sync.Cover }

        if (-not $window.IsVisible) { return }
        if ($state.ScrollHome -gt 0) { $state.ScrollHome--; if ($state.Page) { $pages[$state.Page].Root.ScrollToHome() } }

        # Seitenleiste: VRChat-Status, inkl. Warnung wenn OSC in VRChat aus ist
        $connected = $sync.VRChat -and $sync.OscOk -ne $false
        if ($sync.VRChat -and $sync.OscOk -eq $false) {
            $ui.Dot.Fill = $warnBrush; $ui.DotGlow.Fill = $warnBrush
            $ui.TxtVr.Text = T "OSC in VRChat ist aus"
            $ui.TxtSide2.Text = T "Action Menu > Options > OSC > Enabled"
        } else {
            $ui.Dot.Fill = if ($sync.VRChat) { $app.Resources['C.Accent'] } else { [System.Windows.Media.Brushes]::Gray }
            $ui.DotGlow.Fill = $ui.Dot.Fill
            $ui.TxtVr.Text = T $(if ($sync.VRChat) { "VRChat verbunden" } else { "VRChat nicht gestartet" })
            $ui.TxtSide2.Text = if ($sync.Speaking -and $cfg.HideWhileSpeaking) { T "Du sprichst - Chatbox pausiert" }
                elseif (Test-Paused) { "$(T 'Pausiert bis') $($sync.PauseUntil.ToString('HH:mm'))" }
                elseif ($info) { "$($info.Title) - $($info.Artist)" } else { T "Spotify spielt nichts" }
        }
        if ($connected -ne $state.Connected) {
            $state.Connected = $connected
            foreach ($l in $dotLoop) { Set-Loop $l $connected }
            $ui.DotGlow.Opacity = if ($connected) { 0.3 } else { 0 }
        }

        # Vorschau mit Zeichenzaehler
        $preview = if (-not $cfg.Enabled) { T "Chatbox ist aus" } elseif (Test-Paused) { T "Chatbox ist pausiert" }
            elseif ($sync.Text) { $sync.Text } else { T "(nichts zu zeigen)" }
        $maxLen = if ($cfg.NoBackground) { 142 } else { 144 }
        $countText = "$("$($sync.Text)".Length) / $maxLen $(T 'Zeichen')"
        foreach ($pv in $previews) {
            if (-not $pv.Text.IsVisible) { continue }
            if ($pv.Text.Text -ne $preview) { $pv.Text.Text = $preview; Animate $pv.Text ([System.Windows.UIElement]::OpacityProperty) 1 260 0.35 }
            $pv.Count.Text = $countText
        }

        switch ($state.Page) {
            'dash' {
                if ($info) {
                    if ($state.Title -ne "$($info.Title)|$($info.Artist)") {
                        $state.Title = "$($info.Title)|$($info.Artist)"
                        $d.TxtTitle.Text = $info.Title; $d.TxtArtist.Text = $info.Artist; $d.TxtAlbum.Text = $info.Album
                        Animate-In $d.SongText 10 380
                    }
                    # Fortschritt gleitet weich mit (springt nur beim Spulen)
                    $w = [Math]::Max(0, $d.ProgressTrack.ActualWidth * $frac)
                    if ($cfg.ReduceMotion -or [Math]::Abs($w - $d.Progress.ActualWidth) -gt 40) { $d.Progress.BeginAnimation([System.Windows.FrameworkElement]::WidthProperty, $null); $d.Progress.Width = $w }
                    else {
                        $a = New-Object System.Windows.Media.Animation.DoubleAnimation($w, (New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(260))))
                        $d.Progress.BeginAnimation([System.Windows.FrameworkElement]::WidthProperty, $a)
                    }
                    $d.TxtPos.Text = & $fmtTime $pos
                    $d.TxtLen.Text = & $fmtTime $len
                    $d.BtnPlay.Content = if ($info.Playing) { [string][char]0xE769 } else { [string][char]0xE768 }
                    $d.BtnShuffle.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, $(if ($info.Shuffle) { 'C.Accent' } else { 'C.Dim' }))
                    $d.BtnRepeat.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, $(if ($info.Repeat -ne 'None' -and $info.Repeat) { 'C.Accent' } else { 'C.Dim' }))
                    $d.BtnRepeat.Content = if ($info.Repeat -eq 'Track') { [string][char]0xE8ED } else { [string][char]0xE8EE }
                } elseif ($state.Title) {
                    $state.Title = $null
                    $d.TxtTitle.Text = T "Spotify spielt nichts"; $d.TxtArtist.Text = ""; $d.TxtAlbum.Text = ""
                    $d.Progress.BeginAnimation([System.Windows.FrameworkElement]::WidthProperty, $null); $d.Progress.Width = 0
                    $d.TxtPos.Text = "0:00"; $d.TxtLen.Text = "0:00"
                }
                $playing = [bool]($info -and $info.Playing)
                if ($playing -ne $state.Playing) { $state.Playing = $playing; foreach ($l in $eqLoops) { Set-Loop $l $playing } }
                $d.TxtGenre.Text = if ($sync.Genre) { (T "JETZT LÄUFT") + "  " + [char]0x00B7 + "  $($sync.Genre.ToUpper())" } else { T "JETZT LÄUFT" }
                $tile.Lyrics.Text = if ($cfg.ShowLyrics -or $cfg.LyricsMode) { T $sync.LyricsStatus } else { T "aus" }
                # Welt + Spieler werden immer gelesen, solange VRChat laeuft (auch wenn sie nicht in der Chatbox stehen)
                $tile.World.Text = if ($sync.VRChat -and $sync.World) { $sync.World } elseif ($sync.VRChat) { T "Lädt..." } else { T "VRChat aus" }
                $tile.World.ToolTip = $tile.World.Text
                $tile.People.Text = if ($sync.VRChat -and $sync.World) { "$($sync.Players)" } else { "-" }
                $tile.Today.Text = Format-Duration $sync.ListenToday
                $tile.Songs.Text = "$($sync.SongCount)"
                if (-not $sync.VRChat) { $state.VrStart = $null }
                elseif (-not $state.VrStart) { $state.VrStart = try { (Get-Process -Name VRChat -ErrorAction Stop | Select-Object -First 1).StartTime } catch { $null } }
                $tile.Time.Text = if ($state.VrStart) { $span = $now - $state.VrStart; "{0}:{1:00} h" -f [int][Math]::Floor($span.TotalHours), $span.Minutes } else { "-" }
            }
            'lyrics' {
                $lyricsStatus.Text = "$(T 'Status'): $(T $sync.LyricsStatus)"
                Update-LyricsView $pos
            }
            'chat' {
                $micText.Text = if (-not $cfg.HideWhileSpeaking) { "" }
                    elseif ($sync.MicLevel -lt 0) { T "Kein Mikrofon gefunden" }
                    else { "$(T 'Mikrofon'): $([int]([double]$sync.MicLevel * 100))%" + $(if ($sync.Speaking) { "   " + [char]0x00B7 + "   " + (T "du sprichst - Chatbox ausgeblendet") } else { "" }) }
            }
            'advanced' {
                $errKey = "$($sync.Errors.Count)|$($sync.ErrorVersion)"   # Anzahl allein reicht nicht: bei 100 Eintraegen bleibt sie gleich
                if ($errKey -ne $state.ErrCount) {
                    $state.ErrCount = $errKey
                    $errBox.Text = if ($sync.Errors.Count) { ($sync.Errors.ToArray() -join "`r`n") } else { T "Keine Fehler" }
                    $errBox.ScrollToEnd()
                }
                if ($state.TestAt -and $sync.TestResult) {
                    $state.TestAt = $null
                    $testStatus.Text = if ($sync.TestResult -ne 'ok') { "$(T 'Fehler'): $($sync.TestResult)" }
                        elseif (-not $sync.VRChat) { T "Gesendet, aber VRChat läuft gerade nicht." }
                        elseif ($sync.OscOk -eq $false) { T "Gesendet, aber OSC ist in VRChat aus: Action Menu > Options > OSC > Enabled." }
                        else { T "Gesendet - in VRChat sollte jetzt 'Verbindung OK' über deinem Kopf stehen." }
                }
            }
        }

        # Lautstaerke von Spotify uebernehmen (falls im Mixer geaendert)
        if (($now - $state.LastVol).TotalSeconds -ge 2 -and $state.Page -eq 'dash' -and -not $d.Volume.IsMouseCaptureWithin) {
            $state.LastVol = $now
            $v = [AppVolume]::Get('Spotify')
            if ($v -ge 0) { $state.VolSync = $true; $d.Volume.Value = [Math]::Round($v * 100); $state.VolSync = $false }
        }
    } catch {
        if ($sync.Errors.Count -lt 100) { [void]$sync.Errors.Add("$(Get-Date -Format HH:mm:ss)  Panel: $_") }
    }
})

# ============================== SCREENSHOT-MODUS ==============================
# Rendert jede Seite als PNG (ohne das Fenster auf dem Bildschirm zu zeigen) und beendet sich dann
function Start-Snapshot {
    if (-not (Test-Path $Snapshot)) { New-Item $Snapshot -ItemType Directory | Out-Null }
    $window.WindowStartupLocation = 'Manual'; $window.Left = -5000; $window.Top = 0
    $window.ShowActivated = $false; $window.ShowInTaskbar = $false
    $window.Show()
    $script:snap = @{ Index = -6; Timer = New-Object System.Windows.Threading.DispatcherTimer }   # erst ~5 s auf Daten warten
    $snap.Timer.Interval = [TimeSpan]::FromMilliseconds(900)
    $snap.Timer.add_Tick({
        try {
            function Save-Snap($el, [string]$name) {
                $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$el.ActualWidth, [int]$el.ActualHeight, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
                $rtb.Render($el)
                $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
                $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
                $fs = [System.IO.File]::Create((Join-Path $Snapshot "$name.png")); $enc.Save($fs); $fs.Close()
            }
            if ($snap.Index -ge 1 -and $snap.Index -le $nav.Count) { Save-Snap $ui.Root $nav[$snap.Index - 1].Key }
            # zum Schluss noch Pause-Menue und Songwechsel-Fenster
            if ($snap.Index -eq $nav.Count) {
                $navButtons['dash'].IsChecked = $true
                # Testbilder ausserhalb des Bildschirms zeichnen, damit beim Nutzer nichts kurz aufblitzt
                # Pause-Menue nicht oeffnen (Popups landen immer sichtbar am Bildschirmrand), sondern frei zeichnen
                $pausePop.Child = $null
                $popCard.Measure((New-Object System.Windows.Size(328, [double]::PositiveInfinity)))
                $popCard.Arrange((New-Object System.Windows.Rect($popCard.DesiredSize)))
                Show-SongToast -Force
                $snap.Index++; return
            }
            if ($snap.Index -gt $nav.Count) {
                Save-Snap $popCard 'pause-menu'
                # Popup in voller Fenstergroesse (inkl. Schattenrand) auf dunklem Grund
                $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$toast.Win.Width, [int]$toast.Win.Height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
                $dv = New-Object System.Windows.Media.DrawingVisual; $dc = $dv.RenderOpen()
                $dc.DrawRectangle((New-Brush '#3A3F4A'), $null, (New-Object System.Windows.Rect(0, 0, $toast.Win.Width, $toast.Win.Height))); $dc.Close()
                $rtb.Render($dv); $rtb.Render($toast.Win.Content)
                $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
                $fs = [System.IO.File]::Create((Join-Path $Snapshot 'toast.png')); $enc.Save($fs); $fs.Close()
                $snap.Timer.Stop()
                Set-Content (Join-Path $Snapshot "errors.txt") ($sync.Errors.ToArray() -join "`r`n") -Encoding UTF8
                Exit-App; return
            }
            if ($snap.Index -ge 0) { $navButtons[$nav[$snap.Index].Key].IsChecked = $true }
            $snap.Index++
        } catch { [void]$sync.Errors.Add("Snapshot: $_") }
    })
    $snap.Timer.Start()
}

# ============================== START ==============================
Update-EnabledButton
$navButtons['dash'].IsChecked = $true
$uiTimer.Start()
if ($Snapshot) { Start-Snapshot }
elseif ($ShowPanel) { Show-Panel }

try {
    [void]$app.Run()
}
finally {
    $sync.Exit = $true
    $tray.Visible = $false
    try { $mutex.ReleaseMutex() } catch {}
}
