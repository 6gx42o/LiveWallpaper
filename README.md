# LiveWallpaper

A tiny native macOS menu bar app that plays a looping video as your desktop wallpaper — and stops decoding it the moment nobody can see it, so it barely touches your battery.

![LiveWallpaper window](docs/window.png)

## Features

- **Any video, converted automatically — at full quality.** Add a `.mov`, `.mp4`, `.m4v` (or, with ffmpeg installed, `.webm`, `.mkv`, `.avi`…) and it's re-encoded to a muted, hardware-decodable HEVC file at the highest quality, keeping its original resolution (only sources bigger than 4K / your display are scaled down).
- **Separate home and lock screen wallpapers.** The home screen plays the video; the lock screen shows a still frame you pick (see below for why).
- **Quality check.** Every video is compared with your display: you're told if it's low resolution, the wrong aspect ratio (and how much gets cropped), low bitrate or low frame rate.
- **Upscaling.** Low-resolution videos can be upscaled to cover your display with **Apple's on-device Super Resolution** model (macOS 26+, Apple silicon; macOS downloads the model once, with your permission), falling back to high-quality Lanczos scaling.
- **Editor.** Trim, playback speed, Fill/Fit framing with crop position, and the lock screen frame — all non-destructive, with a live preview shaped like your display.
- **Sits behind your desktop icons** on every display and every Space.
- **Pauses itself when it can't be seen:**
  - a full-screen app or maximized window covers the desktop
  - the display or the Mac goes to sleep
  - the screen is locked, or another user is switched in
  - Low Power Mode is on (unless you choose otherwise)
- **Drag & drop.** Drop videos onto the window and they're converted and added to your library, ready to pick.
- **Clear, diagnosable errors.** Anything that can't be used says why, in plain words, with the technical detail and a *Copy details* button:
  - *isn't compatible* — not a video (with the list of supported formats), or a format that needs ffmpeg
  - *is broken* — a damaged file that neither macOS nor ffmpeg can read
  - *couldn't be converted* — decoded but failed to re-encode or save
  - damaged videos already in the library, and videos that fail during playback, show a red *Broken* tile
- **Menu bar panel and a full app window** — same controls, one compact and one roomy (resizable, full-screen capable).
- **Settings:** play in Low Power Mode, pause when the desktop is covered, open at login.

## Why it's light on battery

| | |
|---|---|
| Hardware decoding | Every wallpaper is converted to HEVC, which Apple silicon decodes in dedicated media hardware. |
| No wasted pixels | Videos are capped near your screen's resolution (1080p or 4K) and stripped of audio. |
| Zero work while hidden | The player is paused — not just hidden — whenever the wallpaper isn't visible, so nothing is decoded. |
| No polling | Everything is driven by system notifications; there are no timers running in the background. |
| Display can still sleep | The player never holds a "keep display awake" assertion. |

## Supported formats

MP4, MOV and M4V work out of the box. With ffmpeg installed, WebM, MKV, AVI, FLV, WMV, MPEG, OGV and 3GP are converted too. Everything ends up as a muted HEVC `.mp4`.

## Requirements

- macOS 15 Sequoia or later (Apple silicon recommended; Super Resolution upscaling needs macOS 26)
- Swift 6 toolchain — Xcode 16+ or the Command Line Tools (`xcode-select --install`)
- Optional: [ffmpeg](https://ffmpeg.org) for formats macOS can't read natively (`brew install ffmpeg`)

## Build & run

```bash
git clone <this repo> && cd LiveWallpaper
./build.sh
open LiveWallpaper.app
```

`build.sh` compiles a release build and assembles an ad-hoc signed `LiveWallpaper.app` next to it. Move it to `/Applications` if you like.

## Usage

1. Click the ▶︎ icon in the menu bar (or open the app again to bring up its window).
2. **Drag videos onto the window**, click the drop area / **Add Video** to pick files, or use Finder's *Open With → LiveWallpaper*. Conversion runs in the background with a progress bar.
3. Click a thumbnail to make it your **home screen** wallpaper. The 🔒 button under it makes it your **lock screen** wallpaper; ✕ next to the lock name in the header restores your own picture.
4. The ⚙︎ (sliders) button opens the **editor**: trim, speed, framing, lock screen frame, quality report and **Upscale**. The 🗑 button moves a video to the Trash.

Converted videos live in `~/Library/Application Support/LiveWallpaper/Videos/`.

## About the lock screen

macOS doesn't let apps draw on the lock screen — only Apple's own aerial wallpapers animate there. What it does show is your desktop picture, so LiveWallpaper saves a full-quality still of the frame you choose (framed like your wallpaper) and sets it as the desktop picture; on the home screen the video covers it. Your original picture is remembered and put back when you remove the lock screen wallpaper.

## How pausing works

`PlaybackGate` keeps a set of reasons to pause (Low Power Mode, display asleep, screen locked, …) fed by `NSWorkspace`, `ProcessInfo` and distributed notifications, and plays only when that set is empty and the wallpaper isn't covered.

"Covered" is decided by checking whether any normal window covers a display's usable area (everything below the menu bar), using window bounds from `CGWindowListCopyWindowInfo` — no Screen Recording permission needed. It's re-checked whenever the active app or Space changes. (`NSWindow` occlusion state was tried first, but for desktop-level windows it gets stuck on "hidden" after leaving a full-screen Space.)

## Known limitations

- Maximizing or un-maximizing a window *without* switching apps isn't noticed until the next app or Space switch. Catching it without polling would require the Accessibility permission.
- The lock screen shows a still frame, not video (a macOS restriction, see above).
- The same video plays on every display.
- Builds are ad-hoc signed, so on another Mac Gatekeeper will ask you to confirm the first launch (right-click → Open).

## Project layout

```
Sources/LiveWallpaper/
  main.swift             app entry, menu bar panel & window
  AppModel.swift         state: home/lock wallpapers, editor, upscaling, settings
  PanelView.swift        SwiftUI UI used by both the panel and the window
  EditorView.swift       trim / speed / framing / lock frame / quality editor
  VideoInfo.swift        video facts, quality checks against the display, edit model
  Upscaler.swift         Apple Super Resolution upscaling with Lanczos fallback
  LockScreen.swift       lock screen still + restoring your own picture
  PlaybackGate.swift     all play/pause decisions
  Library.swift          import → convert (AVFoundation, ffmpeg fallback) → analysis, edits, upscale jobs
  WallpaperWindow.swift  desktop-level window that loops the video
Resources/AppIcon.icns   app icon (regenerate with scripts/make-icon.swift)
build.sh                 builds LiveWallpaper.app
```

## License

MIT — see [LICENSE](LICENSE).
