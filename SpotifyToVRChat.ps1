# Spotify -> VRChat Chatbox
# Zeigt den aktuell laufenden Spotify-Song in der VRChat-Chatbox an (via OSC).
# Panel: Doppelklick aufs Tray-Icon. Einstellungen in settings.json, Profile in profiles.json.
# Voraussetzung: In VRChat im Action Menu unter Options > OSC "Enabled" aktivieren.
#
# Dateien:  worker.ps1       Hintergrund-Thread (Spotify, Lyrics, OSC)
#           ui\*.xaml        Aussehen des Panels

param(
    [int]$Port = 0,          # nur zum Testen: anderen OSC-Port erzwingen
    [switch]$ShowPanel
)

# Nur eine Instanz gleichzeitig - ein zweiter Start oeffnet stattdessen das Panel der laufenden
$mutex = New-Object System.Threading.Mutex($false, "Global\SpotifyToVRChat")
$showEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', "Global\SpotifyToVRChat_Show")
if (-not $mutex.WaitOne(0)) { [void]$showEvent.Set(); exit }

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
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public static string ForegroundProcessName() {
        uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        try { return Process.GetProcessById((int)pid).ProcessName; } catch { return ""; }
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

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing, Microsoft.VisualBasic

$dir          = $PSScriptRoot
$cfgPath      = Join-Path $dir "settings.json"
$profilesPath = Join-Path $dir "profiles.json"
$historyPath  = Join-Path $dir "verlauf.txt"
$statsPath    = Join-Path $dir "statistik.json"
$lyricsDir    = Join-Path $dir "lyrics"
$startupLnk   = Join-Path ([Environment]::GetFolderPath('Startup')) "SpotifyToVRChat.lnk"
if (-not (Test-Path $lyricsDir)) { New-Item $lyricsDir -ItemType Directory | Out-Null }

# ============================== EINSTELLUNGEN ==============================
function New-DefaultConfig {
    [ordered]@{
        Enabled = $true; Interval = 3; NoBackground = $true; Compact = $false; HideWhenPaused = $false; ChangeOnly = $false; Sound = $false
        IconStyle = 0; GenreEmoji = $false; SmallCaps = $false; ArtistSuperscript = $false; Marquee = $false; SongNumber = $false; ShowAlbum = $false
        ShowBar = $true; Remaining = $false; BarStyle = 1; BarLength = 10
        Separator = " | "; BlankLine = $false; Stars = $false; Deco = $false
        ShowLyrics = $false; LyricsMode = $false; HideTitleAfterLyrics = $false; ChorusOnly = $false; LyricsSmallCaps = $false
        LyricsOffset = 0.0; Translate = $false; TranslateLang = "de"
        ShowClock = $false; ClockSeconds = $false; ShowDate = $false; CountdownOn = $false; CountdownTime = "23:00"; CountdownLabel = "gn8"
        Playtime = $false; InGameStatus = $false; WorldInfo = $false; PcStats = $false; GpuStats = $false
        Afk = $false; AutoAfk = $false; AfkMinutes = 5; WeatherOn = $false; WeatherCity = ""
        StatusText = ""
        HideWhileSpeaking = $false
        Theme = "dark"; Accent = "#1ED760"; AlwaysOnTop = $false; MiniPlayer = $false; AnyPlayer = $false
        OscHost = "127.0.0.1"; OscPort = 9000; MicThreshold = 0.04
        Notify = $false; History = $true; ScheduleOn = $false; Schedule = @()
    }
}
$cfg = New-DefaultConfig
function Import-ConfigValues($source) {
    foreach ($p in $source.PSObject.Properties) {
        if ($cfg.Contains($p.Name)) { $cfg[$p.Name] = if ($p.Name -eq 'Schedule') { @($p.Value) } else { $p.Value } }
    }
}
if (Test-Path $cfgPath) { try { Import-ConfigValues (Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {} }
function Save-Config { $cfg | ConvertTo-Json -Depth 4 | Set-Content $cfgPath -Encoding UTF8 }

# Profile: Name -> Einstellungen (ohne Verbindung/Token/Zeitplan)
$profileSkip = @('Enabled', 'Schedule', 'ScheduleOn', 'OscHost', 'OscPort')
$profiles = [ordered]@{}
if (Test-Path $profilesPath) {
    try { (Get-Content $profilesPath -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $profiles[$_.Name] = $_.Value } } catch {}
}
function Save-Profiles { $profiles | ConvertTo-Json -Depth 5 | Set-Content $profilesPath -Encoding UTF8 }

# ============================== HINTERGRUND-THREAD ==============================
$sync = [hashtable]::Synchronized(@{
    Cfg = $cfg; HistoryPath = $historyPath; StatsPath = $statsPath; LyricsDir = $lyricsDir; PortOverride = $Port
    Info = $null; SampleTime = [DateTime]::Now; Text = ""; VRChat = $false; SongCount = 0
    Cover = $null; CoverKey = $null; SongEvent = $null; Genre = $null; LyricsStatus = "-"
    World = $null; Players = 0; Weather = $null; HeartRate = $null; Speaking = $false; VrcAfk = $false
    ListenerStatus = "Aus"; ListenToday = 0.0
    Dirty = $true; SendNow = $false; Exit = $false
    Commands = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    UiEvents = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    Errors   = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
})

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

$themes = @{
    dark  = @{ Bg = '#0D0D10'; Side = '#111115'; Card = '#17171C'; Input = '#222229'; Hover = '#2B2B34'; Text = '#EDEDF2'; Dim = '#8A8A96'; Border = '#212128' }
    light = @{ Bg = '#F2F2F6'; Side = '#FFFFFF'; Card = '#FFFFFF'; Input = '#EBEBF0'; Hover = '#DEDEE6'; Text = '#16161C'; Dim = '#6A6A76'; Border = '#E1E1E8' }
}
$accents = [ordered]@{ 'Grün' = '#1ED760'; 'Rot' = '#FF3355'; 'Lila' = '#8B5CF6'; 'Blau' = '#3B82F6'; 'Pink' = '#EC4899'; 'Orange' = '#F97316'; 'Türkis' = '#14B8A6'; 'Gold' = '#EAB308' }
$bc = New-Object System.Windows.Media.BrushConverter
function New-Brush([string]$hex) { $b = $bc.ConvertFromString($hex); $b.Freeze(); $b }

function Apply-Theme {
    $t = $themes["$($cfg.Theme)"]; if (-not $t) { $t = $themes.dark }
    foreach ($k in $t.Keys) { $app.Resources["C.$k"] = New-Brush $t[$k] }
    $app.Resources['C.Accent'] = New-Brush $cfg.Accent
    # Schrift auf der Akzentfarbe: schwarz auf hellen, weiss auf dunklen Farben
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($cfg.Accent)
    $lum = (0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B) / 255
    $app.Resources['C.AccentText'] = New-Brush $(if ($lum -gt 0.6) { '#000000' } else { '#FFFFFF' })
}
Apply-Theme

function Load-Window([string]$file) {
    [xml]$x = Get-Content (Join-Path $dir "ui\$file") -Raw -Encoding UTF8
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    $names = @{}
    $x.SelectNodes("//*[@*[local-name()='Name']]") | ForEach-Object {
        $n = ($_.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1).Value
        $names[$n] = $w.FindName($n)
    }
    @{ Window = $w; UI = $names }
}
$main = Load-Window "panel.xaml"
$window = $main.Window; $ui = $main.UI
$mini = Load-Window "mini.xaml"
$miniWin = $mini.Window; $mu = $mini.UI

$state = @{
    Exiting = $false; Refreshing = $false; VolSync = $false; Page = $null; Title = $null; CoverKey = $null
    ScrollHome = 0; LastVol = [DateTime]::MinValue; LastSchedule = $null; StatsRange = 7; ErrCount = -1
}

# ============================== BAUSTEINE ==============================
$bound = New-Object System.Collections.ArrayList   # alle Einstellungs-Elemente, fuer Profile/Import neu setzen

function New-Text([string]$text, [double]$size = 13, [string]$color = 'C.Text', [string]$weight = 'Normal') {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text; $t.FontSize = $size; $t.FontWeight = $weight; $t.TextWrapping = 'Wrap'
    $t.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $color)
    $t
}
function New-Margin($l, $t, $r, $b) { New-Object System.Windows.Thickness($l, $t, $r, $b) }

$pages = @{}
function New-Page([string]$key) {
    $sv = New-Object System.Windows.Controls.ScrollViewer
    $sv.VerticalScrollBarVisibility = 'Auto'; $sv.Visibility = 'Collapsed'
    $root = New-Object System.Windows.Controls.StackPanel
    $root.Margin = New-Margin 30 4 22 26
    $full = New-Object System.Windows.Controls.StackPanel
    $grid = New-Object System.Windows.Controls.Grid
    foreach ($w in @(1, 14, 1)) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = if ($w -eq 14) { New-Object System.Windows.GridLength 14 } else { New-Object System.Windows.GridLength(1, 'Star') }
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

# Karte mit Titel; gibt den Inhaltsbereich zurueck
function New-Section($parent, [string]$title, [string]$desc = "") {
    $card = New-Object System.Windows.Controls.Border
    $card.Style = $app.Resources['Card']
    $sp = New-Object System.Windows.Controls.StackPanel
    $t = New-Text $title 14 'C.Text' 'SemiBold'
    [void]$sp.Children.Add($t)
    if ($desc) { $d = New-Text $desc 11.5 'C.Dim'; $d.Margin = New-Margin 0 2 0 4; [void]$sp.Children.Add($d) }
    $body = New-Object System.Windows.Controls.StackPanel
    $body.Margin = New-Margin 0 6 0 0
    [void]$sp.Children.Add($body)
    $card.Child = $sp
    [void]$parent.Children.Add($card)
    $body
}

function Add-Switch($panel, [string]$label, [string]$key, [string]$desc = "", [scriptblock]$after = $null) {
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Style = $app.Resources['Switch']
    $content = New-Object System.Windows.Controls.StackPanel
    [void]$content.Children.Add((New-Text $label 13))
    if ($desc) { $d = New-Text $desc 11 'C.Dim'; $d.Margin = New-Margin 0 1 0 0; [void]$content.Children.Add($d) }
    $cb.Content = $content
    $cb.Tag = @{ Key = $key; After = $after }
    $cb.IsChecked = [bool]$cfg[$key]
    $cb.add_Click({
        if ($state.Refreshing) { return }
        $cfg[$this.Tag.Key] = [bool]$this.IsChecked
        Save-Config; $sync.Dirty = $true
        if ($this.Tag.After) { & $this.Tag.After }
    })
    [void]$panel.Children.Add($cb)
    [void]$bound.Add(@{ Type = 'switch'; Control = $cb; Key = $key })
    $cb
}

# $options = @( @("Text", Wert), ... )
function Add-Pills($panel, [string]$label, [string]$key, $options, [scriptblock]$after = $null) {
    if ($label) { $l = New-Text $label 12 'C.Dim'; $l.Margin = New-Margin 0 10 0 6; [void]$panel.Children.Add($l) }
    $wrap = New-Object System.Windows.Controls.WrapPanel
    foreach ($o in $options) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.Style = $app.Resources['Pill']
        $rb.GroupName = $key + '_' + $panel.GetHashCode()
        $rb.Content = $o[0]
        $rb.Tag = @{ Key = $key; Value = $o[1]; After = $after }
        $rb.IsChecked = ("$($cfg[$key])" -eq "$($o[1])")
        $rb.add_Checked({
            if ($state.Refreshing) { return }
            $cfg[$this.Tag.Key] = $this.Tag.Value
            Save-Config; $sync.Dirty = $true
            if ($this.Tag.After) { & $this.Tag.After }
        })
        [void]$wrap.Children.Add($rb)
        [void]$bound.Add(@{ Type = 'pill'; Control = $rb; Key = $key; Value = $o[1] })
    }
    [void]$panel.Children.Add($wrap)
}

function Add-Slider($panel, [string]$label, [string]$key, [double]$min, [double]$max, [double]$step, [string]$unit) {
    $head = New-Object System.Windows.Controls.Grid
    $head.Margin = New-Margin 0 10 0 2
    [void]$head.Children.Add((New-Text $label 12 'C.Dim'))
    $val = New-Text "" 12 'C.Text' 'SemiBold'; $val.HorizontalAlignment = 'Right'
    [void]$head.Children.Add($val)
    [void]$panel.Children.Add($head)
    $s = New-Object System.Windows.Controls.Slider
    $s.Minimum = $min; $s.Maximum = $max; $s.SmallChange = $step; $s.TickFrequency = $step; $s.IsSnapToTickEnabled = $true
    $s.Value = [double]$cfg[$key]
    $s.Tag = @{ Key = $key; Label = $val; Unit = $unit }
    $val.Text = ("{0:+0.0;-0.0;0.0} $unit" -f $s.Value)
    $s.add_ValueChanged({
        $this.Tag.Label.Text = ("{0:+0.0;-0.0;0.0} $($this.Tag.Unit)" -f $this.Value)
        if ($state.Refreshing) { return }
        $cfg[$this.Tag.Key] = [Math]::Round($this.Value, 2)
        Save-Config; $sync.Dirty = $true
    })
    [void]$panel.Children.Add($s)
    [void]$bound.Add(@{ Type = 'slider'; Control = $s; Key = $key })
}

function Add-TextSetting($panel, [string]$label, [string]$key, [string]$hint = "", [switch]$Password) {
    if ($label) { $l = New-Text $label 12 'C.Dim'; $l.Margin = New-Margin 0 10 0 6; [void]$panel.Children.Add($l) }
    if ($Password) {
        $tb = New-Object System.Windows.Controls.PasswordBox
        $tb.Password = "$($cfg[$key])"; $tb.Tag = $key
        $tb.add_PasswordChanged({ if (-not $state.Refreshing) { $cfg[$this.Tag] = $this.Password; Save-Config; $sync.Dirty = $true } })
    } else {
        $tb = New-Object System.Windows.Controls.TextBox
        $tb.Text = "$($cfg[$key])"; $tb.Tag = $key
        $tb.add_TextChanged({ if (-not $state.Refreshing) { $cfg[$this.Tag] = $this.Text; Save-Config; $sync.Dirty = $true } })
    }
    [void]$panel.Children.Add($tb)
    if ($hint) { $h = New-Text $hint 11 'C.Dim'; $h.Margin = New-Margin 0 4 0 2; [void]$panel.Children.Add($h) }
    [void]$bound.Add(@{ Type = $(if ($Password) { 'password' } else { 'text' }); Control = $tb; Key = $key })
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
        $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $text; $t.VerticalAlignment = 'Center'
        [void]$sp.Children.Add($t)
        $b.Content = $sp
    } else { $b.Content = $text }
    $b.add_Click($onClick)
    [void]$panel.Children.Add($b)
    $b
}
function New-Row { $w = New-Object System.Windows.Controls.WrapPanel; $w.Margin = New-Margin 0 6 0 0; $w }

# Kleine Info-Kachel; gibt das Wert-Textfeld zurueck
function New-Tile($parent, [string]$label, [string]$icon) {
    $card = New-Object System.Windows.Controls.Border
    $card.Style = $app.Resources['Card']; $card.Padding = New-Margin 16 12 16 12; $card.Margin = New-Margin 0 0 10 10
    $sp = New-Object System.Windows.Controls.StackPanel
    $h = New-Object System.Windows.Controls.StackPanel; $h.Orientation = 'Horizontal'
    $i = New-Text $icon 12 'C.Accent'; $i.FontFamily = $app.Resources['Icons']; $i.Margin = New-Margin 0 1 7 0
    [void]$h.Children.Add($i); [void]$h.Children.Add((New-Text $label 11.5 'C.Dim'))
    $v = New-Text "-" 15 'C.Text' 'SemiBold'; $v.Margin = New-Margin 0 5 0 0; $v.TextTrimming = 'CharacterEllipsis'; $v.TextWrapping = 'NoWrap'
    [void]$sp.Children.Add($h); [void]$sp.Children.Add($v)
    $card.Child = $sp
    [void]$parent.Children.Add($card)
    $v
}

# Vorschau-Kasten (mehrere Seiten zeigen dieselbe Vorschau)
$previews = New-Object System.Collections.ArrayList
function Add-Preview($parent) {
    $card = New-Object System.Windows.Controls.Border
    $card.CornerRadius = 12; $card.Padding = New-Margin 16 18 16 18; $card.Margin = New-Margin 0 0 0 14; $card.MinHeight = 100
    $grad = New-Object System.Windows.Media.LinearGradientBrush
    $grad.StartPoint = '0,0'; $grad.EndPoint = '1,1'
    $grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.ColorConverter]::ConvertFromString('#1F2A36')), 0))
    $grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.ColorConverter]::ConvertFromString('#12161C')), 1))
    $card.Background = $grad
    $sp = New-Object System.Windows.Controls.StackPanel
    $cap = New-Object System.Windows.Controls.TextBlock
    $cap.Text = "VORSCHAU  " + [char]0x00B7 + "  SO STEHT ES ÜBER DEINEM KOPF"; $cap.FontSize = 10.5; $cap.FontWeight = 'Bold'
    $cap.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'C.Accent')
    $cap.HorizontalAlignment = 'Center'; $cap.Margin = New-Margin 0 0 0 10
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Foreground = [System.Windows.Media.Brushes]::White; $t.FontSize = 13.5; $t.TextAlignment = 'Center'; $t.TextWrapping = 'Wrap'; $t.LineHeight = 20
    [void]$sp.Children.Add($cap); [void]$sp.Children.Add($t)
    $card.Child = $sp
    [void]$parent.Children.Add($card)
    [void]$previews.Add($t)
}

function Format-Duration([double]$sec) {
    $ts = [TimeSpan]::FromSeconds($sec)
    if ($ts.TotalHours -ge 1) { "{0} h {1} min" -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes } else { "$([int]$ts.TotalMinutes) min" }
}

# ============================== SEITEN ==============================
$nav = @(
    @{ Key = 'dash';     Icon = [string][char]0xE80F; Name = 'Dashboard';     Title = 'Dashboard';     Desc = 'Was gerade läuft und was über deinem Kopf steht' }
    @{ Key = 'chat';     Icon = [string][char]0xE8BD; Name = 'Chatbox';       Title = 'Chatbox';       Desc = 'Aussehen und Aufbau der Chatbox' }
    @{ Key = 'lyrics';   Icon = [string][char]0xE8D6; Name = 'Lyrics';        Title = 'Lyrics';        Desc = 'Live-Songtexte, Karaoke und Übersetzung' }
    @{ Key = 'status';   Icon = [string][char]0xE946; Name = 'Status';        Title = 'Status-Zeile';  Desc = 'Uhrzeit, Wetter, PC-Werte, AFK und eigene Texte' }
    @{ Key = 'stats';    Icon = [string][char]0xE9D2; Name = 'Statistik';     Title = 'Statistik';     Desc = 'Deine meistgehörten Songs und Künstler' }
    @{ Key = 'profiles'; Icon = [string][char]0xE77B; Name = 'Profile';       Title = 'Profile';       Desc = 'Einstellungen speichern, wechseln und planen' }
    @{ Key = 'settings'; Icon = [string][char]0xE713; Name = 'Einstellungen'; Title = 'Einstellungen'; Desc = 'Design, Musik-Quelle und Programm' }
    @{ Key = 'advanced'; Icon = [string][char]0xEC7A; Name = 'Erweitert';     Title = 'Erweitert';     Desc = 'Verbindung, Tastenkürzel und Fehler-Log' }
)
$navButtons = @{}
foreach ($n in $nav) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.Style = $app.Resources['NavItem']
    $rb.Content = $n.Name; $rb.Tag = $n.Icon; $rb.GroupName = 'nav'
    $rb.DataContext = $n.Key
    $rb.add_Checked({ Show-Page $this.DataContext })
    [void]$ui.Nav.Children.Add($rb)
    $navButtons[$n.Key] = $rb
}

# ---------------- Dashboard ----------------
$p = New-Page 'dash'
$npXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Style="{DynamicResource Card}" Padding="20">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
    <Border x:Name="Cover" Width="140" Height="140" CornerRadius="12" Background="{DynamicResource C.Input}" Margin="0,0,22,0">
      <TextBlock x:Name="CoverIcon" Text="&#x266B;" FontFamily="Segoe UI Symbol" FontSize="46" Foreground="{DynamicResource C.Dim}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <StackPanel Grid.Column="1" VerticalAlignment="Center">
      <TextBlock x:Name="TxtGenre" Text="JETZT LÄUFT" FontSize="10.5" FontWeight="Bold" Foreground="{DynamicResource C.Accent}"/>
      <TextBlock x:Name="TxtTitle" Text="Spotify spielt nichts" FontSize="24" FontWeight="Bold" Foreground="{DynamicResource C.Text}" TextTrimming="CharacterEllipsis" Margin="0,3,0,0"/>
      <TextBlock x:Name="TxtArtist" FontSize="14" Foreground="{DynamicResource C.Dim}" TextTrimming="CharacterEllipsis"/>
      <TextBlock x:Name="TxtAlbum" FontSize="12" Foreground="{DynamicResource C.Dim}" Opacity="0.7" TextTrimming="CharacterEllipsis"/>
      <Grid x:Name="ProgressTrack" Height="16" Margin="0,12,0,0" Background="Transparent" Cursor="Hand" ToolTip="Klicken zum Spulen">
        <Border Height="4" CornerRadius="2" Background="{DynamicResource C.Input}" VerticalAlignment="Center"/>
        <Border x:Name="Progress" Height="4" CornerRadius="2" Background="{DynamicResource C.Accent}" HorizontalAlignment="Left" VerticalAlignment="Center" Width="0"/>
      </Grid>
      <Grid>
        <TextBlock x:Name="TxtPos" Text="0:00" FontSize="11" Foreground="{DynamicResource C.Dim}"/>
        <TextBlock x:Name="TxtLen" Text="0:00" FontSize="11" Foreground="{DynamicResource C.Dim}" HorizontalAlignment="Right"/>
      </Grid>
      <Grid Margin="0,6,0,0">
        <StackPanel Orientation="Horizontal">
          <Button x:Name="BtnShuffle" Style="{DynamicResource IconBtn}" Content="&#xE8B1;" ToolTip="Zufallswiedergabe"/>
          <Button x:Name="BtnPrev" Style="{DynamicResource IconBtn}" Content="&#xE892;" Margin="4,0"/>
          <Button x:Name="BtnPlay" Style="{DynamicResource PlayBtn}" Content="&#xE768;" Margin="4,0"/>
          <Button x:Name="BtnNext" Style="{DynamicResource IconBtn}" Content="&#xE893;" Margin="4,0"/>
          <Button x:Name="BtnRepeat" Style="{DynamicResource IconBtn}" Content="&#xE8EE;" ToolTip="Wiederholen"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <TextBlock Text="&#xE767;" FontFamily="{DynamicResource Icons}" Foreground="{DynamicResource C.Dim}" VerticalAlignment="Center" Margin="0,0,10,0"/>
          <Slider x:Name="Volume" Width="130" Minimum="0" Maximum="100" VerticalAlignment="Center"/>
        </StackPanel>
      </Grid>
    </StackPanel>
  </Grid>
</Border>
'@
$np = [Windows.Markup.XamlReader]::Parse($npXaml)
$d = @{}
foreach ($n in 'Cover', 'CoverIcon', 'TxtGenre', 'TxtTitle', 'TxtArtist', 'TxtAlbum', 'ProgressTrack', 'Progress', 'TxtPos', 'TxtLen', 'BtnShuffle', 'BtnPrev', 'BtnPlay', 'BtnNext', 'BtnRepeat', 'Volume') { $d[$n] = $np.FindName($n) }
[void]$p.Full.Children.Add($np)
Add-Preview $p.Left
$tiles = New-Object System.Windows.Controls.Primitives.UniformGrid
$tiles.Columns = 2
[void]$p.Right.Children.Add($tiles)
$tile = @{
    Lyrics = New-Tile $tiles 'Lyrics' ([string][char]0xE8D6)
    World  = New-Tile $tiles 'VRChat-Welt' ([string][char]0xE909)
    Today  = New-Tile $tiles 'Heute gehört' ([string][char]0xE916)
    Songs  = New-Tile $tiles 'Songs (Sitzung)' ([string][char]0xE8D6)
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
$volumeSliders = New-Object System.Collections.ArrayList
function Register-Volume($slider) {
    [void]$volumeSliders.Add($slider)
    $slider.add_ValueChanged({
        if ($state.VolSync) { return }
        [AppVolume]::Set('Spotify', [float]($this.Value / 100))
        $state.VolSync = $true
        foreach ($o in $volumeSliders) { if ($o -ne $this) { $o.Value = $this.Value } }
        $state.VolSync = $false
    })
}
Register-Volume $d.Volume

# ---------------- Chatbox ----------------
$p = New-Page 'chat'
Add-Preview $p.Full
$s = New-Section $p.Left "Grundlagen" "Wie und wann die Chatbox gesendet wird"
[void](Add-Switch $s "Ohne Hintergrund" 'NoBackground' "Text schwebt ohne dunklen Kasten")
[void](Add-Switch $s "Kompakt" 'Compact' "Alles in einer einzigen Zeile")
[void](Add-Switch $s "Bei Pause ausblenden" 'HideWhenPaused')
[void](Add-Switch $s "Song nur kurz zeigen" 'ChangeOnly' "Nur 15 Sekunden nach einem Songwechsel")
[void](Add-Switch $s "VRChat-Sound beim Senden" 'Sound')
Add-Pills $s "Aktualisieren alle" 'Interval' @(@("2 s", 2), @("3 s", 3), @("5 s", 5), @("10 s", 10))

$s = New-Section $p.Left "Beim Sprechen ausblenden" "Solange du redest, verschwindet die Chatbox"
[void](Add-Switch $s "Beim Sprechen ausblenden" 'HideWhileSpeaking')
Add-Pills $s "Empfindlichkeit" 'MicThreshold' @(@("Niedrig", 0.1), @("Mittel", 0.04), @("Hoch", 0.015))
$micText = New-Text "" 11.5 'C.Dim'; $micText.Margin = New-Margin 0 2 0 0
[void]$s.Children.Add($micText)

$s = New-Section $p.Left "Layout & Deko"
Add-Pills $s "Trennzeichen" 'Separator' @(@("|", " | "), @([string][char]0x2022, " $([char]0x2022) "), @([string][char]0x250A, " $([char]0x250A) "), @("~", " ~ "), @("/", " / "))
[void](Add-Switch $s "Leerzeile zwischen Song und Status" 'BlankLine')
[void](Add-Switch $s "Sterne-Rahmen" 'Stars' "$([char]0x2605) an jeder Zeile")
[void](Add-Switch $s "Zufällige Deko" 'Deco' "$([char]0x2726) $([char]0x22C6) $([char]0x2727) um die erste Zeile, neu bei jedem Song")

$s = New-Section $p.Right "Song-Zeile"
Add-Pills $s "Song-Icon" 'IconStyle' @(@("$([char]::ConvertFromUtf32(0x1F3B5)) Note", 0), @("$([char]::ConvertFromUtf32(0x1F3A7)) Kopfhörer", 1), @("$([char]0x266A) Einfach", 2), @("Keins", 3))
[void](Add-Switch $s "Genre-Emoji statt Icon" 'GenreEmoji' "z. B. $([char]::ConvertFromUtf32(0x1F525)) für Rap, $([char]::ConvertFromUtf32(0x1F3B8)) für Rock")
[void](Add-Switch $s "Kapitälchen-Schrift" 'SmallCaps' "ᴛɪᴛᴇʟ - ᴋüɴꜱᴛʟᴇʀ")
[void](Add-Switch $s "Künstler hochgestellt" 'ArtistSuperscript' "Titel ᵇʸ ᵏᵘⁿˢᵗˡᵉʳ")
[void](Add-Switch $s "Lauftext für lange Titel" 'Marquee')
[void](Add-Switch $s "Songnummer anzeigen" 'SongNumber' "#12 = zwölfter Song in dieser Sitzung")
[void](Add-Switch $s "Album anzeigen" 'ShowAlbum')

$s = New-Section $p.Right "Fortschrittsbalken"
[void](Add-Switch $s "Fortschrittsbalken" 'ShowBar')
[void](Add-Switch $s "Restzeit statt Länge" 'Remaining')
function E([int]$c) { [char]::ConvertFromUtf32($c) }
Add-Pills $s "Stil" 'BarStyle' @(
    @(((E 0x25AC) * 3 + (E 0x25CF) + (E 0x25AC) * 3), 0), @(((E 0x2501) * 3 + (E 0x25C9) + (E 0x2500) * 3), 1),
    @(((E 0x2593) * 4 + (E 0x2591) * 3), 2), @(((E 0x25A0) * 4 + (E 0x25A1) * 3), 3), @(((E 0x2665) * 4 + (E 0x2661) * 3), 4))
Add-Pills $s "Länge" 'BarLength' @(@("Kurz", 6), @("Mittel", 10), @("Lang", 14))

# ---------------- Lyrics ----------------
$p = New-Page 'lyrics'
Add-Preview $p.Full
$s = New-Section $p.Left "Lyrics" "Songtexte synchron zur Musik"
[void](Add-Switch $s "Live-Lyrics" 'ShowLyrics' "Aktuelle Zeile unten in der Chatbox")
[void](Add-Switch $s "Karaoke-Modus" 'LyricsMode' "Nur Song, aktuelle und nächste Zeile")
[void](Add-Switch $s "Titel ausblenden, wenn Lyrics laufen" 'HideTitleAfterLyrics' "Nach 10 Sekunden nur noch die Lyrics")
[void](Add-Switch $s "Nur den Refrain" 'ChorusOnly' "Zeigt nur Zeilen, die mehrfach vorkommen")
[void](Add-Switch $s "Lyrics in Kapitälchen" 'LyricsSmallCaps')

$s = New-Section $p.Left "Timing"
$lyricsStatus = New-Text "-" 12.5 'C.Text'
[void]$s.Children.Add((New-Text "Status" 12 'C.Dim')); [void]$s.Children.Add($lyricsStatus)
Add-Slider $s "Versatz (wenn Lyrics zu früh/spät kommen)" 'LyricsOffset' -3 3 0.1 "s"

$s = New-Section $p.Right "Übersetzung"
[void](Add-Switch $s "Lyrics übersetzen" 'Translate' "Zeigt die Übersetzung unter der Zeile")
Add-Pills $s "Sprache" 'TranslateLang' @(@("Deutsch", "de"), @("Englisch", "en"), @("Türkisch", "tr"), @("Spanisch", "es"), @("Französisch", "fr"), @("Russisch", "ru"), @("Arabisch", "ar"), @("Polnisch", "pl"))

$s = New-Section $p.Right "Eigene Lyrics" "Für Songs, zu denen keine Lyrics gefunden werden. Mit der Vorlage schreibst du sie selbst."
$row = New-Row
[void](Add-Button $row "Ordner öffnen" { Start-Process explorer.exe $lyricsDir } -icon ([string][char]0xE838))
[void](Add-Button $row "Vorlage für aktuellen Song" {
    $i = $sync.Info
    if (-not $i) { return }
    $clean = $i.Title -replace '\s*[\(\[](feat|ft|with)\.?[^\)\]]*[\)\]]', ''
    $name = ($i.Artist + " - " + $clean + ".lrc") -replace '[\\/:*?<>|"]', '_'
    $file = Join-Path $lyricsDir $name
    if (-not (Test-Path $file)) {
        "[ar:$($i.Artist)]`r`n[ti:$($i.Title)]`r`n[00:00.00] Erste Zeile (Zeit = Minuten:Sekunden)`r`n[00:05.50] Zweite Zeile" | Set-Content $file -Encoding UTF8
    }
    Start-Process notepad.exe "`"$file`""
} -icon ([string][char]0xE710))
[void]$s.Children.Add($row)

# ---------------- Status ----------------
$p = New-Page 'status'
Add-Preview $p.Full
$s = New-Section $p.Left "Zeit"
[void](Add-Switch $s "Uhrzeit" 'ShowClock')
[void](Add-Switch $s "Mit Sekunden" 'ClockSeconds')
[void](Add-Switch $s "Datum" 'ShowDate')
$s = New-Section $p.Left "Countdown" "z. B. $([char]::ConvertFromUtf32(0x23F3)) gn8 in 1:20 h"
[void](Add-Switch $s "Countdown anzeigen" 'CountdownOn')
[void](Add-TextSetting $s "Uhrzeit (HH:mm)" 'CountdownTime')
[void](Add-TextSetting $s "Text" 'CountdownLabel')
$s = New-Section $p.Left "AFK"
[void](Add-Switch $s "AFK" 'Afk')
[void](Add-Switch $s "Auto-AFK" 'AutoAfk' "Wenn Maus und Tastatur nicht benutzt werden (nur Desktop-Modus sinnvoll)")
Add-Pills $s "Auto-AFK nach" 'AfkMinutes' @(@("2 min", 2), @("5 min", 5), @("10 min", 10), @("15 min", 15))

$s = New-Section $p.Right "VRChat"
[void](Add-Switch $s "Spielzeit" 'Playtime' "Wie lange VRChat schon läuft")
[void](Add-Switch $s "Im Spiel / Am Desktop" 'InGameStatus' "Ob VRChat gerade im Vordergrund ist")
[void](Add-Switch $s "Welt und Spielerzahl" 'WorldInfo' "Name der Welt und wie viele Leute da sind")
$s = New-Section $p.Right "PC"
[void](Add-Switch $s "CPU und RAM" 'PcStats')
[void](Add-Switch $s "Grafikkarte" 'GpuStats' "Auslastung der Grafikkarte")
$s = New-Section $p.Right "Wetter"
[void](Add-Switch $s "Wetter anzeigen" 'WeatherOn')
[void](Add-TextSetting $s "Stadt" 'WeatherCity' "z. B. Berlin")
$weatherStatus = New-Text "" 11.5 'C.Dim'; $weatherStatus.Margin = New-Margin 0 4 0 0
[void]$s.Children.Add($weatherStatus)
$s = New-Section $p.Full "Eigener Text" "Mehrere Texte mit ; trennen, sie wechseln alle 10 Sekunden"
[void](Add-TextSetting $s "" 'StatusText')

# ---------------- Statistik ----------------
$p = New-Page 'stats'
$statTiles = New-Object System.Windows.Controls.Primitives.UniformGrid; $statTiles.Columns = 4
[void]$p.Full.Children.Add($statTiles)
$st2 = @{
    Today = New-Tile $statTiles 'Heute gehört' ([string][char]0xE916)
    Week  = New-Tile $statTiles '7 Tage gehört' ([string][char]0xE787)
    Total = New-Tile $statTiles 'Songs im Verlauf' ([string][char]0xE8D6)
    Fav   = New-Tile $statTiles 'Lieblings-Künstler' ([string][char]0xE734)
}
$rangeRow = New-Row
foreach ($r in @(@("7 Tage", 7), @("30 Tage", 30), @("Gesamt", 0))) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.Style = $app.Resources['Pill']; $rb.GroupName = 'range'; $rb.Content = $r[0]; $rb.Tag = $r[1]
    $rb.IsChecked = ($r[1] -eq 7)
    $rb.add_Checked({ $state.StatsRange = $this.Tag; Update-Stats })
    [void]$rangeRow.Children.Add($rb)
}
[void]$p.Full.Children.Insert(0, $rangeRow)
$topSongs = New-Section $p.Left "Top-Songs"
$topArtists = New-Section $p.Right "Top-Künstler"
$recent = New-Section $p.Right "Zuletzt gehört"
$s = New-Section $p.Left "Teilen"
$row = New-Row
[void](Add-Button $row "Song kopieren" { $i = $sync.Info; if ($i) { [System.Windows.Clipboard]::SetText("$($i.Title) - $($i.Artist)") } } -icon ([string][char]0xE8C8))
[void](Add-Button $row "Spotify-Link kopieren" {
    $i = $sync.Info
    if ($i) { [System.Windows.Clipboard]::SetText("https://open.spotify.com/search/$([uri]::EscapeDataString("$($i.Title) $($i.Artist)"))") }
} -icon ([string][char]0xE71B))
[void](Add-Button $row "Verlauf öffnen" {
    if (-not (Test-Path $historyPath)) { New-Item $historyPath -ItemType File | Out-Null }
    Start-Process notepad.exe "`"$historyPath`""
} -icon ([string][char]0xE81C))
[void]$s.Children.Add($row)

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

function Add-ListRow($panel, [string]$rank, [string]$text, [string]$right) {
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = New-Margin 0 4 0 4
    foreach ($w in @('Auto', '*', 'Auto')) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = if ($w -eq '*') { New-Object System.Windows.GridLength(1, 'Star') } else { [System.Windows.GridLength]::Auto }
        [void]$g.ColumnDefinitions.Add($cd)
    }
    $a = New-Text $rank 12.5 'C.Accent' 'Bold'; $a.Width = 28
    $b = New-Text $text 12.5 'C.Text'; $b.TextTrimming = 'CharacterEllipsis'; $b.TextWrapping = 'NoWrap'
    $c = New-Text $right 12 'C.Dim'; $c.Margin = New-Margin 10 0 0 0
    [System.Windows.Controls.Grid]::SetColumn($b, 1); [System.Windows.Controls.Grid]::SetColumn($c, 2)
    [void]$g.Children.Add($a); [void]$g.Children.Add($b); [void]$g.Children.Add($c)
    [void]$panel.Children.Add($g)
}

function Update-Stats {
    $all = @(Get-History)
    $from = if ($state.StatsRange -gt 0) { (Get-Date).AddDays(-$state.StatsRange) } else { [datetime]::MinValue }
    $range = @($all | Where-Object { $_.Time -ge $from })
    $topSongs.Children.Clear(); $topArtists.Children.Clear(); $recent.Children.Clear()
    $i = 0
    foreach ($g in ($range | Group-Object { "$($_.Title) - $($_.Artist)" } | Sort-Object Count -Descending | Select-Object -First 10)) {
        $i++; Add-ListRow $topSongs "$i" $g.Name "$($g.Count)x"
    }
    if (-not $i) { [void]$topSongs.Children.Add((New-Text "Noch keine Songs im Verlauf" 12 'C.Dim')) }
    $i = 0
    $artists = $range | Group-Object { ($_.Artist -split ',')[0].Trim() } | Sort-Object Count -Descending
    foreach ($g in ($artists | Select-Object -First 10)) { $i++; Add-ListRow $topArtists "$i" $g.Name "$($g.Count)x" }
    foreach ($h in ($all | Select-Object -Last 12 | Sort-Object Time -Descending)) { Add-ListRow $recent "" "$($h.Title) - $($h.Artist)" ($h.Time.ToString('dd.MM. HH:mm')) }
    $days = @{}
    if (Test-Path $statsPath) { try { (Get-Content $statsPath -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $days[$_.Name] = [double]$_.Value } } catch {} }
    $days[(Get-Date -Format 'yyyy-MM-dd')] = [double]$sync.ListenToday
    $week = 0.0; for ($n = 0; $n -lt 7; $n++) { $week += [double]$days[(Get-Date).AddDays(-$n).ToString('yyyy-MM-dd')] }
    $st2.Today.Text = Format-Duration $sync.ListenToday
    $st2.Week.Text = Format-Duration $week
    $st2.Total.Text = "$($all.Count)"
    $st2.Fav.Text = if ($artists) { @($artists)[0].Name } else { "-" }
}

# ---------------- Profile ----------------
$p = New-Page 'profiles'
$s = New-Section $p.Left "Profil speichern" "Speichert alle aktuellen Einstellungen unter einem Namen"
$profName = New-Object System.Windows.Controls.TextBox
[void]$s.Children.Add($profName)
$row = New-Row
[void](Add-Button $row "Speichern" {
    $name = $profName.Text.Trim()
    if (-not $name) { return }
    $snap = [ordered]@{}
    foreach ($k in $cfg.Keys) { if ($profileSkip -notcontains $k) { $snap[$k] = $cfg[$k] } }
    $profiles[$name] = [pscustomobject]$snap
    Save-Profiles; Update-ProfileList; $profName.Text = ""
} -Accent -icon ([string][char]0xE74E))
[void]$s.Children.Add($row)
$profileList = New-Section $p.Left "Gespeicherte Profile"

$s = New-Section $p.Right "Zeitplan" "Wechselt das Profil automatisch zur eingestellten Uhrzeit"
[void](Add-Switch $s "Zeitplan aktiv" 'ScheduleOn')
$schedGrid = New-Object System.Windows.Controls.Grid
foreach ($w in @(90, 8, '*')) {
    $cd = New-Object System.Windows.Controls.ColumnDefinition
    $cd.Width = if ($w -eq '*') { New-Object System.Windows.GridLength(1, 'Star') } else { New-Object System.Windows.GridLength $w }
    [void]$schedGrid.ColumnDefinitions.Add($cd)
}
$schedTime = New-Object System.Windows.Controls.TextBox; $schedTime.Text = "20:00"
$schedProf = New-Object System.Windows.Controls.TextBox; $schedProf.Text = "Profilname"
[System.Windows.Controls.Grid]::SetColumn($schedProf, 2)
[void]$schedGrid.Children.Add($schedTime); [void]$schedGrid.Children.Add($schedProf)
$schedGrid.Margin = New-Margin 0 8 0 0
[void]$s.Children.Add($schedGrid)
$row = New-Row
[void](Add-Button $row "Hinzufügen" {
    if ($schedTime.Text -notmatch '^\d{1,2}:\d{2}$' -or -not $schedProf.Text.Trim()) { return }
    $cfg.Schedule = @($cfg.Schedule) + "$($schedTime.Text)|$($schedProf.Text.Trim())"
    Save-Config; Update-ScheduleList
} -icon ([string][char]0xE710))
[void]$s.Children.Add($row)
$scheduleList = New-Object System.Windows.Controls.StackPanel
[void]$s.Children.Add($scheduleList)

$s = New-Section $p.Right "Sichern & Zurücksetzen"
$row = New-Row
[void](Add-Button $row "Exportieren" {
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.FileName = "spotify-chatbox-einstellungen.json"; $dlg.Filter = "JSON|*.json"
    if ($dlg.ShowDialog()) { @{ Settings = $cfg; Profiles = $profiles } | ConvertTo-Json -Depth 6 | Set-Content $dlg.FileName -Encoding UTF8 }
} -icon ([string][char]0xEDE1))
[void](Add-Button $row "Importieren" {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = "JSON|*.json"
    if ($dlg.ShowDialog()) {
        try {
            $data = Get-Content $dlg.FileName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($data.Settings) { Import-ConfigValues $data.Settings }
            if ($data.Profiles) { $data.Profiles.PSObject.Properties | ForEach-Object { $profiles[$_.Name] = $_.Value } }
            Save-Config; Save-Profiles; Refresh-All
        } catch { [void]$sync.Errors.Add("Import: $_") }
    }
} -icon ([string][char]0xE8B5))
[void](Add-Button $row "Auf Standard zurücksetzen" {
    $r = [System.Windows.MessageBox]::Show("Alle Einstellungen auf Standard zurücksetzen? Profile bleiben erhalten.", "Zurücksetzen", 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    $def = New-DefaultConfig
    foreach ($k in @($def.Keys)) { $cfg[$k] = $def[$k] }
    Save-Config; Refresh-All
} -icon ([string][char]0xE72C))
[void]$s.Children.Add($row)

function Load-Profile([string]$name) {
    $prof = $profiles[$name]
    if (-not $prof) { return }
    foreach ($pp in $prof.PSObject.Properties) { if ($cfg.Contains($pp.Name) -and $profileSkip -notcontains $pp.Name) { $cfg[$pp.Name] = $pp.Value } }
    Save-Config; Refresh-All
    $tray.ShowBalloonTip(2000, "Profil geladen", $name, 'None')
}

function Update-ProfileList {
    $profileList.Children.Clear()
    if (-not $profiles.Count) { [void]$profileList.Children.Add((New-Text "Noch keine Profile gespeichert" 12 'C.Dim')); return }
    foreach ($name in @($profiles.Keys)) {
        $g = New-Object System.Windows.Controls.DockPanel; $g.Margin = New-Margin 0 2 0 2
        $btns = New-Object System.Windows.Controls.StackPanel; $btns.Orientation = 'Horizontal'
        [System.Windows.Controls.DockPanel]::SetDock($btns, 'Right')
        $b1 = Add-Button $btns "Laden" { Load-Profile $this.Tag } -Accent; $b1.Tag = $name; $b1.Margin = New-Margin 0 0 6 0
        $b2 = Add-Button $btns "Löschen" { $profiles.Remove($this.Tag); Save-Profiles; Update-ProfileList }; $b2.Tag = $name; $b2.Margin = New-Margin 0 0 0 0
        [void]$g.Children.Add($btns)
        $t = New-Text $name 13 'C.Text' 'SemiBold'; $t.VerticalAlignment = 'Center'
        [void]$g.Children.Add($t)
        [void]$profileList.Children.Add($g)
    }
}
function Update-ScheduleList {
    $scheduleList.Children.Clear()
    foreach ($e in @($cfg.Schedule)) {
        $parts = "$e" -split '\|', 2
        $g = New-Object System.Windows.Controls.DockPanel; $g.Margin = New-Margin 0 4 0 0
        $b = Add-Button $g "Entfernen" { $cfg.Schedule = @($cfg.Schedule | Where-Object { $_ -ne $this.Tag }); Save-Config; Update-ScheduleList }
        $b.Tag = "$e"; $b.Margin = New-Margin 0 0 0 0
        [System.Windows.Controls.DockPanel]::SetDock($b, 'Right')
        $t = New-Text "$($parts[0])  $([char]0x2192)  $($parts[1])" 13 'C.Text'; $t.VerticalAlignment = 'Center'
        [void]$g.Children.Add($t)
        [void]$scheduleList.Children.Add($g)
    }
}

# ---------------- Einstellungen ----------------
$p = New-Page 'settings'
$s = New-Section $p.Left "Aussehen"
Add-Pills $s "Design" 'Theme' @(@("Dunkel", "dark"), @("Hell", "light")) { Apply-Theme }
$accentOptions = foreach ($k in $accents.Keys) {
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
    $el = New-Object System.Windows.Shapes.Ellipse; $el.Width = 10; $el.Height = 10; $el.Margin = New-Margin 0 0 7 0
    $el.Fill = New-Brush $accents[$k]; $el.VerticalAlignment = 'Center'
    $tx = New-Object System.Windows.Controls.TextBlock; $tx.Text = $k
    [void]$sp.Children.Add($el); [void]$sp.Children.Add($tx)
    ,@($sp, $accents[$k])
}
Add-Pills $s "Akzentfarbe" 'Accent' $accentOptions { Apply-Theme; Update-EnabledButton }
[void](Add-Switch $s "Panel immer im Vordergrund" 'AlwaysOnTop' "" { $window.Topmost = [bool]$cfg.AlwaysOnTop })
[void](Add-Switch $s "Mini-Player" 'MiniPlayer' "Kleines Fenster mit Cover und Knöpfen, immer oben" { Update-MiniPlayer })

$s = New-Section $p.Left "Musik-Quelle"
[void](Add-Switch $s "Andere Musik-Apps erlauben" 'AnyPlayer' "Wenn Spotify nicht läuft: Apple Music, Amazon Music, Deezer, YouTube Music usw. Normale YouTube-Videos werden ignoriert.")

$s = New-Section $p.Right "Verhalten"
# Autostart ist keine normale Einstellung, sondern eine Verknuepfung im Autostart-Ordner
$cbAuto = New-Object System.Windows.Controls.CheckBox
$cbAuto.Style = $app.Resources['Switch']
$cbAuto.Content = New-Text "Mit Windows starten" 13
$cbAuto.IsChecked = Test-Path $startupLnk
[void]$s.Children.Add($cbAuto)
$cbAuto.add_Click({
    if ($this.IsChecked) {
        $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($startupLnk)
        $lnk.TargetPath = "wscript.exe"; $lnk.Arguments = "`"$(Join-Path $dir 'StartHidden.vbs')`""; $lnk.WorkingDirectory = $dir
        $lnk.Save()
    } elseif (Test-Path $startupLnk) { Remove-Item $startupLnk }
})
[void](Add-Switch $s "Benachrichtigung bei Songwechsel" 'Notify')
[void](Add-Switch $s "Song-Verlauf speichern" 'History' "Wird für die Statistik gebraucht")

$s = New-Section $p.Left "Programm"
$row = New-Row
[void](Add-Button $row "EXE + Desktop-Verknüpfung" { Build-Exe } -Accent -icon ([string][char]0xE7B8))
[void](Add-Button $row "Ordner öffnen" { Start-Process explorer.exe $dir } -icon ([string][char]0xE838))
[void](Add-Button $row "Tool beenden" { Exit-App } -icon ([string][char]0xE7E8))
[void]$s.Children.Add($row)
$exeStatus = New-Text "" 11.5 'C.Dim'; [void]$s.Children.Add($exeStatus)

# ---------------- Erweitert ----------------
$p = New-Page 'advanced'
$s = New-Section $p.Left "Verbindung" "Nur ändern, wenn VRChat auf einem anderen Gerät läuft (z. B. Quest über WLAN)"
[void](Add-TextSetting $s "IP-Adresse" 'OscHost')
[void](Add-TextSetting $s "Port" 'OscPort')

$s = New-Section $p.Left "Tastenkürzel"
$hotkeyText = New-Text "" 12 'C.Text'; $hotkeyText.LineHeight = 21
[void]$s.Children.Add($hotkeyText)

$s = New-Section $p.Right "Fehler-Log"
$errBox = New-Object System.Windows.Controls.TextBox
$errBox.IsReadOnly = $true; $errBox.Height = 130; $errBox.TextWrapping = 'Wrap'; $errBox.VerticalScrollBarVisibility = 'Auto'; $errBox.FontSize = 11.5
$errBox.FontFamily = New-Object System.Windows.Media.FontFamily "Consolas"
[void]$s.Children.Add($errBox)
$row = New-Row
[void](Add-Button $row "Leeren" { $sync.Errors.Clear(); $state.ErrCount = -1 })
[void]$s.Children.Add($row)

# ============================== AKTIONEN ==============================
function Show-Page([string]$key) {
    foreach ($k in $pages.Keys) { $pages[$k].Root.Visibility = if ($k -eq $key) { 'Visible' } else { 'Collapsed' } }
    $n = $nav | Where-Object { $_.Key -eq $key }
    $ui.PageTitle.Text = $n.Title; $ui.PageDesc.Text = $n.Desc
    $state.Page = $key
    $pages[$key].Root.ScrollToHome()
    if ($key -eq 'stats') { Update-Stats }
    if ($key -eq 'profiles') { Update-ProfileList; Update-ScheduleList }
}

function Refresh-All {
    $state.Refreshing = $true
    foreach ($b in $bound) {
        switch ($b.Type) {
            'switch'   { if ($b.Key) { $b.Control.IsChecked = [bool]$cfg[$b.Key] } }
            'pill'     { $b.Control.IsChecked = ("$($cfg[$b.Key])" -eq "$($b.Value)") }
            'slider'   { $b.Control.Value = [double]$cfg[$b.Key] }
            'text'     { $b.Control.Text = "$($cfg[$b.Key])" }
            'password' { $b.Control.Password = "$($cfg[$b.Key])" }
        }
    }
    $state.Refreshing = $false
    Apply-Theme; Update-EnabledButton; Update-MiniPlayer; Update-ScheduleList
    $window.Topmost = [bool]$cfg.AlwaysOnTop
    $sync.Dirty = $true; $sync.SendNow = $true
}

function Update-EnabledButton {
    if ($cfg.Enabled) {
        $ui.BtnEnabled.Content = "$([char]0x25CF)  Chatbox AN"
        $ui.BtnEnabled.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'C.Accent')
        $ui.BtnEnabled.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'C.AccentText')
    } else {
        $ui.BtnEnabled.Content = "$([char]0x25CB)  Chatbox AUS"
        $ui.BtnEnabled.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'C.Input')
        $ui.BtnEnabled.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'C.Text')
    }
}

function Set-Enabled([bool]$on) {
    $cfg.Enabled = $on
    $miEnabled.Checked = $on
    $tray.Icon = if ($on) { $iconOn } else { $iconOff }
    Update-EnabledButton
    Save-Config
    $sync.Dirty = $true; $sync.SendNow = $true
    if (-not $window.IsVisible) { $tray.ShowBalloonTip(1500, "Spotify Chatbox", "Chatbox $(if ($on) { 'an' } else { 'aus' })", 'None') }
}

function Show-Panel {
    $wasVisible = $window.IsVisible
    $window.Show()
    if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }
    $window.Topmost = $true
    [void]$window.Activate()
    $window.Topmost = [bool]$cfg.AlwaysOnTop
    if (-not $wasVisible) { [System.Windows.Input.Keyboard]::ClearFocus(); $state.ScrollHome = 6 }
}

function Update-MiniPlayer {
    if ($cfg.MiniPlayer) {
        if (-not $miniWin.IsVisible) {
            $wa = [System.Windows.SystemParameters]::WorkArea
            $miniWin.Left = $wa.Right - $miniWin.Width - 20; $miniWin.Top = $wa.Top + 20
            $miniWin.Show()
        }
    } elseif ($miniWin.IsVisible) { $miniWin.Hide() }
}

function Exit-App {
    $state.Exiting = $true
    $sync.Exit = $true
    [void]$workerHandle.AsyncWaitHandle.WaitOne(3000)   # Hintergrund-Thread leert noch die Chatbox
    foreach ($hk in $hotkeys) { $hk.Release() }
    $tray.Visible = $false
    $tray.Dispose()
    $miniWin.Close()
    $window.Close()
    $app.Shutdown()
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

function Build-Exe {
    try {
        # .ico mit eingebettetem PNG (256 px)
        $png = New-Object System.IO.MemoryStream
        (New-IconBitmap 256 ([System.Drawing.ColorTranslator]::FromHtml($cfg.Accent))).Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngBytes = $png.ToArray()
        $ico = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter $ico
        $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)
        $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$pngBytes.Length); $bw.Write([uint32]22)
        $bw.Write($pngBytes); $bw.Flush()
        $icoPath = Join-Path $dir "icon.ico"
        [System.IO.File]::WriteAllBytes($icoPath, $ico.ToArray())

        $code = @"
using System; using System.Diagnostics; using System.IO;
class Launcher {
    [STAThread] static void Main() {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        var psi = new ProcessStartInfo("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + Path.Combine(dir, "SpotifyToVRChat.ps1") + "\" -ShowPanel");
        psi.CreateNoWindow = true; psi.UseShellExecute = false; psi.WindowStyle = ProcessWindowStyle.Hidden;
        Process.Start(psi);
    }
}
"@
        $exePath = Join-Path $dir "Spotify Chatbox.exe"
        $prov = New-Object Microsoft.CSharp.CSharpCodeProvider
        $cp = New-Object System.CodeDom.Compiler.CompilerParameters
        $cp.GenerateExecutable = $true; $cp.OutputAssembly = $exePath
        $cp.CompilerOptions = "/target:winexe /win32icon:`"$icoPath`""
        [void]$cp.ReferencedAssemblies.Add("System.dll")
        $res = $prov.CompileAssemblyFromSource($cp, $code)
        if ($res.Errors.HasErrors) { throw ((@($res.Errors) | ForEach-Object { $_.ErrorText }) -join '; ') }

        $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) "Spotify Chatbox.lnk"))
        $lnk.TargetPath = $exePath; $lnk.WorkingDirectory = $dir; $lnk.IconLocation = $icoPath
        $lnk.Save()
        $exeStatus.Text = "Fertig: 'Spotify Chatbox.exe' im Ordner und Verknüpfung auf dem Desktop."
    } catch {
        $exeStatus.Text = "Fehler: $_"
        [void]$sync.Errors.Add("EXE: $_")
    }
}

# ============================== FENSTER-KNÖPFE ==============================
$ui.BtnEnabled.add_Click({ Set-Enabled (-not $cfg.Enabled) })
$ui.BtnMin.add_Click({ $window.WindowState = 'Minimized' })
$ui.BtnClose.add_Click({ $window.Hide() })
$ui.TitleBar.add_MouseLeftButtonDown({ $window.DragMove() })
$ui.Brand.add_MouseLeftButtonDown({ $window.DragMove() })
$window.add_Closing({ if (-not $state.Exiting) { $_.Cancel = $true; $window.Hide() } })
$window.Topmost = [bool]$cfg.AlwaysOnTop
# Nicht automatisch zu Elementen mit Fokus springen
foreach ($pg in $pages.Values) { $pg.Root.Content.add_RequestBringIntoView({ $_.Handled = $true }) }

$mu.Root.add_MouseLeftButtonDown({ $miniWin.DragMove() })
$mu.MPrev.add_Click({ $sync.Commands.Enqueue('prev') })
$mu.MPlay.add_Click({ $sync.Commands.Enqueue('playpause') })
$mu.MNext.add_Click({ $sync.Commands.Enqueue('next') })
$mu.Root.add_MouseRightButtonUp({ Show-Panel })

# ============================== TRAY ==============================
$iconOn  = [System.Drawing.Icon]::FromHandle((New-IconBitmap 64 ([System.Drawing.Color]::FromArgb(30, 215, 96))).GetHicon())
$iconOff = [System.Drawing.Icon]::FromHandle((New-IconBitmap 64 ([System.Drawing.Color]::Gray)).GetHicon())
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = if ($cfg.Enabled) { $iconOn } else { $iconOff }
$tray.Text = "Spotify Chatbox"
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
function Add-MenuItem([string]$text, [scriptblock]$onClick) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $text
    if ($onClick) { $item.add_Click($onClick) }
    [void]$menu.Items.Add($item)
    $item
}
$miPanel = Add-MenuItem "Panel öffnen" { Show-Panel }
$miPanel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miSong = Add-MenuItem "Spotify spielt nichts" $null
$miSong.Enabled = $false
[void](Add-MenuItem "Play / Pause" { $sync.Commands.Enqueue('playpause') })
[void](Add-MenuItem "Nächster Song" { $sync.Commands.Enqueue('next') })
[void](Add-MenuItem "Vorheriger Song" { $sync.Commands.Enqueue('prev') })
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miEnabled = Add-MenuItem "Chatbox anzeigen" { Set-Enabled (-not $cfg.Enabled) }
$miEnabled.Checked = $cfg.Enabled
$miProfiles = New-Object System.Windows.Forms.ToolStripMenuItem "Profil laden"
[void]$menu.Items.Add($miProfiles)
$menu.add_Opening({
    $miProfiles.DropDownItems.Clear()
    foreach ($name in @($profiles.Keys)) {
        $it = New-Object System.Windows.Forms.ToolStripMenuItem $name
        $it.Tag = $name
        $it.add_Click({ Load-Profile $this.Tag })
        [void]$miProfiles.DropDownItems.Add($it)
    }
    $miProfiles.Enabled = $profiles.Count -gt 0
})
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void](Add-MenuItem "Beenden" { Exit-App })
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
    @{ Action = 'toggle';    Name = 'Chatbox an/aus'; Keys = @(@(0x4003, 0x4D, "Strg+Alt+M"), @(0x4007, 0x4D, "Strg+Alt+Shift+M"), @(0x4003, 0x78, "Strg+Alt+F9")) }
    @{ Action = 'playpause'; Name = 'Play / Pause';   Keys = @(@(0x4003, 0x26, "Strg+Alt+Pfeil hoch")) }
    @{ Action = 'next';      Name = 'Nächster Song';  Keys = @(@(0x4003, 0x27, "Strg+Alt+Pfeil rechts")) }
    @{ Action = 'prev';      Name = 'Vorheriger Song'; Keys = @(@(0x4003, 0x25, "Strg+Alt+Pfeil links")) }
    @{ Action = 'afk';       Name = 'AFK an/aus';     Keys = @(@(0x4003, 0x28, "Strg+Alt+Pfeil runter")) }
)
$hotkeys = New-Object System.Collections.ArrayList
$hotkeyLines = @()
foreach ($plan in $hotkeyPlan) {
    $done = $false
    foreach ($k in $plan.Keys) {
        $hk = New-Object HotkeyWindow($k[0], $k[1])
        if ($hk.Registered) {
            $hk.Action = $plan.Action
            $hk.add_Pressed({
                switch ($this.Action) {
                    'toggle' { Set-Enabled (-not $cfg.Enabled) }
                    'afk'    { $cfg.Afk = -not $cfg.Afk; Save-Config; Refresh-All }
                    default  { $sync.Commands.Enqueue($this.Action) }
                }
            })
            [void]$hotkeys.Add($hk)
            $hotkeyLines += "$($k[2])   $([char]0x2192)   $($plan.Name)"
            if ($plan.Action -eq 'toggle') { $miEnabled.Text = "Chatbox anzeigen   ($($k[2]))" }
            $done = $true; break
        }
        $hk.Release()
    }
    if (-not $done) { $hotkeyLines += "(belegt)   $([char]0x2192)   $($plan.Name)" }
}
$hotkeyText.Text = $hotkeyLines -join "`n"

# ============================== LAUFENDE AKTUALISIERUNG ==============================
function Set-CoverImage($border, $iconBlock, [byte[]]$bytes) {
    if ($bytes) {
        $img = New-Object System.Windows.Media.Imaging.BitmapImage
        $img.BeginInit(); $img.StreamSource = New-Object System.IO.MemoryStream(, $bytes)
        $img.CacheOption = 'OnLoad'; $img.DecodePixelWidth = 280; $img.EndInit(); $img.Freeze()
        $brush = New-Object System.Windows.Media.ImageBrush $img; $brush.Stretch = 'UniformToFill'
        $border.Background = $brush; $iconBlock.Visibility = 'Collapsed'
    } else {
        $border.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'C.Input'); $iconBlock.Visibility = 'Visible'
    }
}

$fmtTime = { param([double]$s) "{0}:{1:00}" -f [int][Math]::Floor($s / 60), [int][Math]::Floor($s % 60) }

$uiTimer = New-Object System.Windows.Threading.DispatcherTimer
$uiTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$uiTimer.add_Tick({
    try {
        $now = Get-Date
        if ($showEvent.WaitOne(0)) { Show-Panel }
        $ev = $null
        while ($sync.UiEvents.TryDequeue([ref]$ev)) { if ($ev -eq 'toggle') { Set-Enabled (-not $cfg.Enabled) } }

        # Zeitplan fuer Profile
        if ($cfg.ScheduleOn) {
            $hm = $now.ToString('HH:mm')
            foreach ($e in @($cfg.Schedule)) {
                $parts = "$e" -split '\|', 2
                if ([datetime]::ParseExact($parts[0].PadLeft(5, '0'), 'HH:mm', $null).ToString('HH:mm') -eq $hm -and $state.LastSchedule -ne "$($now.Date)|$e") {
                    $state.LastSchedule = "$($now.Date)|$e"
                    Load-Profile $parts[1]
                }
            }
        }

        # Songwechsel -> Tray + Benachrichtigung
        $songEvent = $sync.SongEvent
        if ($songEvent) {
            $sync.SongEvent = $null
            $miSong.Text = if ($songEvent.Length -gt 55) { $songEvent.Substring(0, 52) + "..." } else { $songEvent }
            $tip = "$($sync.SongCount) Songs | $songEvent"
            $tray.Text = if ($tip.Length -gt 63) { $tip.Substring(0, 60) + "..." } else { $tip }
            if ($cfg.Notify) { $tray.ShowBalloonTip(3000, "Jetzt läuft", $songEvent, 'None') }
        }

        $info = $sync.Info
        $pos = 0; $len = 0
        if ($info) {
            $len = $info.Length.TotalSeconds
            $pos = $info.Pos.TotalSeconds
            if ($info.Playing) { $pos += ($now - $sync.SampleTime).TotalSeconds }
            if ($pos -gt $len) { $pos = $len }
        }
        $frac = if ($len -gt 0) { $pos / $len } else { 0 }

        # Mini-Player
        if ($miniWin.IsVisible) {
            $mu.MTitle.Text = if ($info) { $info.Title } else { "Nichts läuft" }
            $mu.MArtist.Text = if ($info) { $info.Artist } else { "" }
            $mu.MProgress.Width = [Math]::Max(0, $mu.MTrack.ActualWidth * $frac)
            $mu.MPlay.Content = if ($info -and $info.Playing) { [string][char]0xE769 } else { [string][char]0xE768 }
        }
        if ($sync.CoverKey -ne $state.CoverKey) {
            $state.CoverKey = $sync.CoverKey
            Set-CoverImage $d.Cover $d.CoverIcon $sync.Cover
            Set-CoverImage $mu.MCover $mu.MCoverIcon $sync.Cover
        }

        if (-not $window.IsVisible) { return }
        if ($state.ScrollHome -gt 0) { $state.ScrollHome--; if ($state.Page) { $pages[$state.Page].Root.ScrollToHome() } }

        # Seitenleiste
        $ui.Dot.Fill = if ($sync.VRChat) { $app.Resources['C.Accent'] } else { [System.Windows.Media.Brushes]::Gray }
        $ui.TxtVr.Text = if ($sync.VRChat) { "VRChat verbunden" } else { "VRChat nicht gestartet" }
        $ui.TxtSide2.Text = if ($sync.Speaking -and $cfg.HideWhileSpeaking) { "Du sprichst - Chatbox pausiert" } elseif ($info) { "$($info.Title) - $($info.Artist)" } else { "Spotify spielt nichts" }

        # Vorschau
        $preview = if (-not $cfg.Enabled) { "Chatbox ist aus" } elseif ($sync.Text) { $sync.Text } else { "(nichts zu zeigen)" }
        foreach ($pv in $previews) { if ($pv.Text -ne $preview -and $pv.IsVisible) { $pv.Text = $preview } }

        switch ($state.Page) {
            'dash' {
                if ($info) {
                    if ($state.Title -ne "$($info.Title)|$($info.Artist)") {
                        $state.Title = "$($info.Title)|$($info.Artist)"
                        $d.TxtTitle.Text = $info.Title; $d.TxtArtist.Text = $info.Artist; $d.TxtAlbum.Text = $info.Album
                    }
                    $d.Progress.Width = [Math]::Max(0, $d.ProgressTrack.ActualWidth * $frac)
                    $d.TxtPos.Text = & $fmtTime $pos
                    $d.TxtLen.Text = & $fmtTime $len
                    $d.BtnPlay.Content = if ($info.Playing) { [string][char]0xE769 } else { [string][char]0xE768 }
                    $d.BtnShuffle.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, $(if ($info.Shuffle) { 'C.Accent' } else { 'C.Dim' }))
                    $d.BtnRepeat.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, $(if ($info.Repeat -ne 'None' -and $info.Repeat) { 'C.Accent' } else { 'C.Dim' }))
                    $d.BtnRepeat.Content = if ($info.Repeat -eq 'Track') { [string][char]0xE8ED } else { [string][char]0xE8EE }
                } elseif ($state.Title) {
                    $state.Title = $null
                    $d.TxtTitle.Text = "Spotify spielt nichts"; $d.TxtArtist.Text = ""; $d.TxtAlbum.Text = ""
                    $d.Progress.Width = 0; $d.TxtPos.Text = "0:00"; $d.TxtLen.Text = "0:00"
                }
                $d.TxtGenre.Text = if ($sync.Genre) { "JETZT LÄUFT  " + [char]0x00B7 + "  $($sync.Genre.ToUpper())" } else { "JETZT LÄUFT" }
                $tile.Lyrics.Text = if ($cfg.ShowLyrics -or $cfg.LyricsMode) { $sync.LyricsStatus -replace ' \(.*\)$', '' } else { "aus" }
                $tile.World.Text = if ($sync.World) { "$($sync.World) ($($sync.Players))" } elseif ($cfg.WorldInfo) { "-" } else { "aus" }
                $tile.Today.Text = Format-Duration $sync.ListenToday
                $tile.Songs.Text = "$($sync.SongCount)"
            }
            'lyrics'   { $lyricsStatus.Text = $sync.LyricsStatus }
            'status'   { $weatherStatus.Text = if (-not $cfg.WeatherOn) { "" } elseif ($sync.WeatherStatus) { $sync.WeatherStatus } else { "Lädt..." } }
            'chat' {
                $micText.Text = if (-not $cfg.HideWhileSpeaking) { "" }
                    elseif ($sync.MicLevel -lt 0) { "Kein Mikrofon gefunden" }
                    else { "Mikrofon: $([int]([double]$sync.MicLevel * 100))%" + $(if ($sync.Speaking) { "   " + [char]0x00B7 + "   du sprichst - Chatbox ausgeblendet" } else { "" }) }
            }
            'advanced' {
                if ($sync.Errors.Count -ne $state.ErrCount) {
                    $state.ErrCount = $sync.Errors.Count
                    $errBox.Text = if ($sync.Errors.Count) { ($sync.Errors.ToArray() -join "`r`n") } else { "Keine Fehler" }
                    $errBox.ScrollToEnd()
                }
            }
        }

        # Lautstaerke von Spotify uebernehmen (falls im Mixer geaendert)
        if (($now - $state.LastVol).TotalSeconds -ge 2 -and $state.Page -eq 'dash') {
            $state.LastVol = $now
            $v = [AppVolume]::Get('Spotify')
            if ($v -ge 0) {
                $state.VolSync = $true
                foreach ($s in $volumeSliders) { if (-not $s.IsMouseCaptureWithin) { $s.Value = [Math]::Round($v * 100) } }
                $state.VolSync = $false
            }
        }
    } catch {
        if ($sync.Errors.Count -lt 100) { [void]$sync.Errors.Add("$(Get-Date -Format HH:mm:ss)  Panel: $_") }
    }
})

# ============================== START ==============================
Update-EnabledButton
Update-MiniPlayer
$navButtons['dash'].IsChecked = $true
$uiTimer.Start()
if ($ShowPanel) { Show-Panel }

try {
    [void]$app.Run()
}
finally {
    $sync.Exit = $true
    $tray.Visible = $false
    $mutex.ReleaseMutex()
}
