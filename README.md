# 🎵 ChatTune

**Show the Spotify song you're listening to above your head in VRChat, with live lyrics, a progress bar and no dark chatbox background. You can even play the song through your mic so everyone around you hears it.**

**🇩🇪 [Deutsche Version weiter unten](#-deutsch)**

![Dashboard](docs/dashboard.png)

## 📦 Install (one command)

Open **CMD** (Windows key → type `cmd` → Enter), paste this and press Enter:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/KingF-Sigma/chattune/main/Install.ps1 | iex"
```

That's it. ChatTune opens right away, and there is a **ChatTune** shortcut on your Desktop and in the Start Menu.

- No admin rights needed, installs only for your Windows user (`%LOCALAPPDATA%\Programs\ChatTune`)
- **Update:** run the same command again. Your settings, statistics and lyrics are kept
- **Uninstall:** Windows Settings → Apps → Installed apps → ChatTune
- **In VRChat, enable OSC once:** Action Menu → Options → OSC → **Enabled**

**Requirements:** Windows 10/11, the Spotify desktop app and VRChat. No Spotify login or API keys.

## ✨ Features

**Chatbox**
- Song title, artist, album and progress bar (5 styles), each can be turned on or off. The artist can go on its own line
- **No background:** the text floats in the air without the dark chatbox box
- Clean-up options: hide "(feat. …)", hide extras like "(Remastered)", main artist only, hide the album when it equals the song title
- Hidden automatically while you talk (only while VRChat is in the foreground)

**Lyrics**
- Live lyrics synced to the music, karaoke mode and translation into 35 languages
- Live lyrics view in the panel (click a line to jump there) and custom lyrics for songs that have none

**Music in your mic** 🎤
- Plays **only Spotify** into your VRChat microphone. No VRChat sounds, no echo of other players
- Your voice is mixed in, with a **noise gate** against mic hiss and **auto-ducking** (music gets quieter while you talk)
- **Even out volume:** every song arrives equally loud, even if you turn Spotify down for yourself
- Needs the free [VB-CABLE](https://vb-audio.com/Cable/). The setup steps are shown right in the app

**VRChat**
- **Avatar size from 1 cm to 10 km** via OSC: slider, presets or type your own size
- **Clean up the VRChat cache:** delete avatars and worlds older or newer than 3 to 30 days, or move the cache to another drive
- World name, player count and play time in the dashboard and in the chatbox

**More**
- Song popup when a new song starts (blurred cover, four screen positions), also shown in VR via XSOverlay
- Pause the chatbox for 5 to 60 minutes or any duration, from the title bar
- Clock, AFK, auto-AFK and your own rotating status texts
- Statistics: weekly chart, top songs and artists, listening time
- Dark or light theme, accent color taken from the album cover, global hotkeys and tray icon

<p>
  <img src="docs/popup.png" alt="Song popup" height="110">
</p>

## ⌨️ Hotkeys

| Keys | Action |
|---|---|
| `Ctrl+Alt+M` | Chatbox on/off |
| `Ctrl+Alt+P` | Pause 15 min / resume |
| `Ctrl+Alt+↑` | Play / Pause |
| `Ctrl+Alt+→` / `←` | Next / previous song |
| `Ctrl+Alt+↓` | AFK on/off |

## ❓ FAQ

**Nobody can see the song.** OSC is probably off in VRChat. The app then shows a warning in the sidebar. You can also try **Advanced → Test connection**.

**Others don't hear the music.** In VRChat, choose **CABLE Output** as your microphone and turn off noise suppression (Settings → Audio).

**I hear myself / everything twice.** Under **Music in mic → Devices**, "Cable" must be the virtual cable, never your headphones. ChatTune only offers virtual cables there.

**Some lyrics are missing.** Not every song has synced lyrics. You can add your own under **Lyrics → Custom lyrics**.

**Does it work with a standalone Quest?** Yes, if the PC and Quest are on the same network. Enter the Quest's IP under **Advanced → Connection**.

## 🙏 Credits

Lyrics: [LRCLIB](https://lrclib.net) · Covers: iTunes Search API, Deezer · Translation: Google Translate

---

## 🇩🇪 Deutsch

**Zeigt den Spotify-Song, den du gerade hörst, in VRChat über deinem Kopf an, mit Live-Lyrics, Fortschrittsbalken und ohne dunklen Chatbox-Kasten. Auf Wunsch spielt ChatTune den Song sogar über dein Mikrofon ab, damit alle um dich herum mithören.**

### Installation (ein Befehl)

**CMD** öffnen (Windows-Taste → `cmd` eintippen → Enter), das hier einfügen und Enter drücken:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/KingF-Sigma/chattune/main/Install.ps1 | iex"
```

Fertig. ChatTune startet sofort, und auf dem Desktop und im Startmenü liegt eine Verknüpfung **ChatTune**.

- Keine Adminrechte nötig. ChatTune wird nur für deinen Windows-Benutzer installiert
- **Update:** denselben Befehl nochmal ausführen. Einstellungen, Statistik und Lyrics bleiben erhalten
- **Deinstallieren:** Windows-Einstellungen → Apps → Installierte Apps → ChatTune
- **In VRChat einmal OSC einschalten:** Action Menu → Options → OSC → **Enabled**

### Funktionen

- **Chatbox:** Songtitel, Künstler, Album und Fortschrittsbalken, alles einzeln schaltbar. Der Text schwebt **ohne Hintergrund-Kasten**. Dazu gibt es Aufräum-Optionen (Features, Klammer-Zusätze, nur Hauptkünstler), und die Chatbox wird **ausgeblendet, während du sprichst**.
- **Lyrics:** Live-Songtexte synchron zur Musik, Karaoke-Modus, Übersetzung in 35 Sprachen und eigene Lyrics.
- **Musik im Mic:** Nur Spotify geht in dein VRChat-Mikrofon, ohne VRChat-Sounds und ohne Echo. Deine Stimme wird mit **Rauschsperre** dazugemischt, die Musik wird leiser, wenn du sprichst, und jeder Song kommt gleich laut an. Dafür brauchst du das kostenlose [VB-CABLE](https://vb-audio.com/Cable/). Die Schritte stehen in der App.
- **VRChat:** **Avatar-Größe von 1 cm bis 10 km** per Regler, Schnellwahl oder eigener Eingabe. Dazu kannst du den **VRChat-Cache aufräumen** (Avatare und Welten älter oder neuer als 3 bis 30 Tage löschen, oder den Cache auf ein anderes Laufwerk verschieben). Welt, Spielerzahl und Spielzeit siehst du im Dashboard.
- **Außerdem:** Song-Popup beim Songwechsel (auch in VR über XSOverlay), Pause aus der Titelleiste, Uhrzeit, AFK, eigene Status-Texte, Statistik, helles und dunkles Design mit Akzentfarbe vom Albumcover, Hotkeys und Tray-Symbol.

---

MIT License
