# Island

A Dynamic Island for the MacBook notch: a live timer and Now Playing (Spotify and Apple Music) with controls.

## Build and run

```bash
./build.sh --open
```

Installs to `~/Applications/Island.app`. Island has no menu bar icon: everything lives in the notch. Right-click the island for timers, the shelf, settings, and Quit.

## Using it

- **Hover the notch** to expand. Move away to collapse.
- **Music**: while Spotify or Music plays, album art and a waveform tinted from the art sit beside the camera. Expanded: play/pause, skip, drag the bar to seek, click the artwork to open the app.
- **Volume**: hover the waveform and it becomes a slider for the music app's volume. Click the speaker to mute.
- **Timer**: tap a preset (1m to 1h) in the expanded island. Pause, resume, cancel. When it ends the island opens and chimes until you stop or repeat it.
- **Pages**: three small glyphs beside the camera in the open island switch between the island, the file shelf, and settings.
- **File shelf**: drag files onto the island to park them. They stay until you take them off (the shelf remembers where the file is; it does not copy it). Click to open, drag back out to use.
- **Settings**: the gear glyph, or right-click the island.
- **Record**: the dot glyph opens the Record page. Pick the whole screen or one window, press record; a red dot and the time show beside the camera. Frame rate, size, codec, file type, pointer, sound and microphone are in Settings › Recording. Files go to `~/Movies/Island Recordings`.
- **Live activities**: calls (FaceTime, Zoom, Discord and others) with mute and leave, camera and microphone dots, and a second activity splitting off as a bubble.
- **Alerts**: headphones connecting with battery levels, low battery at 20% and 10%, rain on the way, and new Messages and Mail with a reply typed in the island. Every one has a switch in Settings › Live or Weather.
- Messages banners read the Messages database, which needs Full Disk Access for Island. Leaving a call needs Accessibility access.
- First time music plays, macOS asks to let Island control Spotify/Music. Allow it.

## Development

- `Island --snapshot shots` renders every state to PNG (no pointer or music needed).
- `Island --probe` prints what the sensors read (mic, camera, battery, weather); `Island --test-record 3` makes a short test recording.
- `Island --capture <home|shelf|settings> <file.png> [settings tab]` saves what the running island really draws.
- `open ~/Applications/Island.app --args --start-timer 1` starts a timer at launch.
- Sources: `IslandModel` (states and sizes), `IslandView` (shape, morph, compact), `MusicViews`, `TimerViews`, `NowPlaying` (AppleScript bridge), `NotchPanel` (window over the notch, hover tracking).

## Signing

`build.sh` signs with the "Island Local Signing" certificate in your login keychain (a self-signed, local-only certificate). Because the signature stays the same across rebuilds, macOS keeps Island's Accessibility and Automation permissions. To remove it, delete "Island Local Signing" in Keychain Access; builds then fall back to ad-hoc signing.
