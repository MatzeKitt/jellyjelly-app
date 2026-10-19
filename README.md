# JellyJelly

A native macOS client for Jellyfin, modeled on [JellyGoose](https://jellygoose.app) and built around a YouTube library stored as series (one series per channel).

## Features

- **Subscription feed on Home**: new and unwatched videos from all channels, newest upload first (Jellyfin `PremiereDate`, falling back to the date added), with a channel strip to filter and unwatched counts.
- **Direct Play only**: the player always requests the original file (`/Videos/{id}/stream?static=true`), and the server never transcodes. Stats show the server's reported play method, so transcoding would be visible immediately.
- **Two engines**, picked per file:
  - AVPlayer for MP4/MOV with H.264/HEVC and native audio
  - libmpv for everything else (MKV, WebM, VP9, AV1, Opus, PGS, …)
- **Buffering**: configurable read-ahead (default 3 minutes), an in-memory cache, pre-buffering before start, automatic HTTP reconnects, and an adaptive refill target that grows after stalls.
- **Resume**: progress is reported every 10 seconds, on pause and seek, on close, and when the app quits. You choose whether to always resume or to be asked.
- **Picture in picture** (press `P`, or ⌥⌘P from anywhere in the app): the video moves into a small floating window that stays on top, across Spaces and next to full-screen apps, so you can keep browsing the library or use other apps. Drag it anywhere, resize it from its edges, and hover over it for play/pause, skipping, and the progress bar. Double-click or press Esc to return to the full player. It works with both engines, and app-rendered subtitles and the segment skip button carry over. By default, a playing video also moves into picture in picture when you switch to another app and returns to the full player when you come back (Settings → Playback).
- **Stats overlay** (press `I`): play method, file, codecs, decoder (hardware or software), dropped frames, buffer level and graph, download rate, and stalls.
- **Downloads for offline viewing**: right-click any movie, episode, or video, or use the download button on its page. Seasons, series, and channels download in one go, with the option to fetch only unwatched items. The original file is stored together with subtitles, chapters, media segments, and artwork in `~/Library/Application Support/JellyJelly/Downloads`. Downloaded items always play from disk. Progress made offline is synced to the server once it can be reached again. Downloading requires the "Allow media downloading" permission on your Jellyfin user.
- Chapters, trickplay scrub previews, skipping intros, credits, and sponsors via Jellyfin media segments, Up Next with autoplay, subtitles, audio tracks, playback speed, Now Playing and media keys.
- Six color schemes (Violet Signal, Ember, Evergreen, Blue Hour, Rose Noir, True Black), channel pages, library browsing with sort, filter, and A–Z index, search, favorites, and Quick Connect.

## Requirements

- macOS 15 or later, Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Jellyfin 10.10 or later (tested against the 12.2 API)
- mpv, for anything AVPlayer can't open:

  ```sh
  brew install mpv
  ```

  libmpv is loaded at runtime from `JellyJelly.app/Contents/Frameworks`, `/opt/homebrew/lib`, or `/usr/local/lib`. Without it, the app still runs and plays MP4/MOV files with AVPlayer.

## Build

```sh
xcodegen generate
xcodebuild -project JellyJelly.xcodeproj -scheme JellyJelly -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/JellyJelly.app
```

Or open `JellyJelly.xcodeproj` in Xcode after running `xcodegen generate`.

## YouTube libraries

Libraries with "YouTube" in their name are detected automatically. To choose them explicitly, go to Settings → YouTube.

## Keyboard shortcuts (player)

| Keys | Action |
|---|---|
| Space / K | Play/pause |
| ← / → (⇧ for 1 min) | Skip 10 seconds |
| ↑ / ↓ | Volume |
| F, double-click | Full screen |
| P (⌥⌘P anywhere) | Picture in picture |
| I | Stats |
| C | Cycle subtitles |
| [ / ] / = | Speed down/up/reset |
| S or Return | Skip segment |
| N | Next video |
| Esc | Leave full screen or picture in picture, then close |
