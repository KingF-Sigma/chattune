# 🎵 Spotify Chatbox for VRChat

**Show the song you're listening to on Spotify above your head in VRChat. With live lyrics, a progress bar, and no dark chatbox background.**

**🇩🇪 [Deutsche Version weiter unten](#-deutsch)**

![Dashboard](docs/dashboard.png)

```
🎵 In the End ᵇʸ ˡⁱⁿᵏⁱⁿ ᵖᵃʳᵏ
0:18 ━◉──── 3:36
🎤 It starts with one
```

## ✨ Features

**Chatbox**
- Song title, artist, album and progress bar (5 styles), each can be turned on or off. Artist can also go on its own line
- **No background:** the text floats in the air without the dark chatbox box
- Compact mode, small caps, superscript artist name
- Clean-up options: hide "(feat. …)", hide extras like "(Remastered)", main artist only, hide the album when it has the same name as the song
- Automatically hidden while you're talking in VRChat (detects your microphone, only while VRChat is in the foreground)
- Lines are prioritized: if the 144-character limit is reached, less important lines are dropped first, and lyrics are never cut off

**Lyrics**
- Live lyrics synced to the music, sent the moment each line is sung
- The right version is picked by song length, so lyrics stay in sync. Loaded lyrics are cached
- Karaoke mode: current line plus a preview of the next one
- Automatic translation into 35 languages
- Live lyrics view in the panel: the current line scrolls along, click a line to jump there
- Custom lyrics for songs that have none

**Pause**
- Hide the chatbox for 5, 15, 30 or any number of minutes. It comes back by itself (dashboard, tray menu or `Ctrl+Alt+P`)

**Status line**
- Clock, AFK and auto-AFK, VRChat play time, current world and player count
- Custom texts that rotate every 10 seconds

**Panel**
- Modern, animated iOS-style design. Dashboard with album cover, play/pause/skip, shuffle, repeat, click-to-seek, Spotify volume, VRChat world and player count
- Chatbox presets for clean, lyrics and minimal layouts; individual options remain editable
- Song popups with blurred cover art, four screen positions, adjustable duration and separate desktop / VR controls
- Live preview with a character counter
- Warns you when OSC is turned off in VRChat, and has a one-click connection test
- Statistics: weekly listening chart, top songs, top artists, listening time (only songs you actually listened to, skipped songs don't count)
- Dark or light theme with 8 accent colors, reduced-motion option, global hotkeys and tray icon

**Installer**
- Installs under `C:\Program Files\VRChatSpotify` and creates Desktop and Start Menu shortcuts with the app icon
- Keeps settings, listening history and lyrics in `%LOCALAPPDATA%\VRChatSpotify`
- Adds an uninstall entry in Windows Apps; uninstalling preserves your settings and lyrics

## 📦 Installation

1. **In VRChat, enable OSC:** Action Menu → Options → OSC → **Enabled** (only needed once)
2. Open PowerShell and run this command. Windows asks once for administrator permission to install into Program Files:

   ```powershell
   $p="$env:TEMP\VRChatSpotify-Install.ps1"; Invoke-WebRequest https://raw.githubusercontent.com/KingF-Sigma/vrchat-spotify-chatbox/main/Install.ps1 -OutFile $p; Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$p`""
   ```

3. Open **Spotify Chatbox** from the Desktop shortcut or Start Menu. Run the same command again to install updates.

The installer adds Desktop and Start Menu shortcuts. To remove the app, use **Windows Settings → Apps → Installed apps**; your settings and lyrics are kept in `%LOCALAPPDATA%\VRChatSpotify`.

**Requirements:** Windows 10/11, Spotify desktop app, VRChat. No Spotify login and no API keys needed.

The panel is in German or English (automatic, or choose under **Settings → Appearance**).

## ⌨️ Hotkeys

| Keys | Action |
|---|---|
| `Ctrl+Alt+M` | Chatbox on/off |
| `Ctrl+Alt+P` | Pause 15 min / resume |
| `Ctrl+Alt+↑` | Play / Pause |
| `Ctrl+Alt+→` / `←` | Next / previous song |
| `Ctrl+Alt+↓` | AFK on/off |

## ❓ FAQ

**Nobody can see the song.** OSC is probably disabled in VRChat. If so, the panel shows a warning in the sidebar. You can also try **Advanced → Test connection**.

**The panel opens behind VRChat.** VRChat is in fullscreen mode. Switch over with `Alt+Tab`.

**Some lyrics are missing.** Not every song has synced lyrics. You can write your own under **Lyrics → Custom lyrics**.

**Lyrics are a bit early or late.** Adjust the offset under **Advanced → Lyrics timing**.

**Does it work with the Quest standalone?** Yes, as long as your PC and Quest are on the same network. Enter the Quest's IP address under **Advanced → Connection**.

## 🙏 Credits

Lyrics: [LRCLIB](https://lrclib.net) · Covers & genres: iTunes Search API · Translation: Google Translate

---

## 🇩🇪 Deutsch

**Zeigt den Song, den du gerade auf Spotify hörst, in VRChat über deinem Kopf an. Mit Live-Lyrics, Fortschrittsbalken und ohne dunklen Chatbox-Hintergrund.**

### Funktionen

- **Chatbox:** Songtitel, Künstler, Album und Fortschrittsbalken (5 Stile), alles einzeln an- und ausschaltbar. Der Text schwebt **ohne Hintergrund-Kasten**. Dazu gibt es Kapitälchen, einen hochgestellten Künstlernamen und Aufräum-Optionen (Features, Klammer-Zusätze, nur Hauptkünstler, doppeltes Album ausblenden). Die Chatbox wird automatisch **ausgeblendet, während du sprichst**.
- **Lyrics:** Live-Songtexte synchron zur Musik. Die passende Version wird anhand der Songlänge gewählt. Dazu gibt es einen Karaoke-Modus, eine Übersetzung in 35 Sprachen, eine Live-Ansicht im Panel und eigene Lyrics.
- **Pause:** Die Chatbox 5, 15, 30 oder beliebig viele Minuten ausblenden, danach kommt sie von selbst zurück (`Strg+Alt+P`).
- **Status-Zeile:** Uhrzeit, AFK und Auto-AFK, Spielzeit, Welt und Spielerzahl sowie eigene wechselnde Texte.
- **Panel:** Dashboard mit Cover, Steuerung und Schnell-Schaltern, Vorschau mit Zeichenzähler, Warnung wenn OSC in VRChat aus ist, Verbindungstest und Statistik. Dazu Chatbox-Profile, reduzierbare Animationen und ein Song-Popup mit Cover-Hintergrund, wählbarer Position und Dauer.
- **Installation:** Ein PowerShell-Befehl installiert nach `C:\Program Files\VRChatSpotify`, erstellt Desktop- und Startmenü-Verknüpfungen mit App-Symbol und speichert persönliche Daten unter `%LOCALAPPDATA%\VRChatSpotify`.

### Installation

1. **In VRChat OSC einschalten:** Action Menu → Options → OSC → **Enabled** (nur einmal nötig)
2. Den PowerShell-Befehl aus dem Abschnitt **Installation** oben ausführen. Die Installation fragt einmalig nach Administratorrechten.
3. **Spotify Chatbox** über die Desktop-Verknüpfung oder das Startmenü öffnen. Für Updates denselben Befehl erneut ausführen.

Du brauchst Windows 10/11, die Spotify-Desktop-App und VRChat. Ein Spotify-Login oder API-Schlüssel ist nicht nötig. Die Deinstallation über **Windows-Einstellungen → Apps** behält Einstellungen und Lyrics.

---

MIT License
