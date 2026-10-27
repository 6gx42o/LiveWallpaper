# LiveWallpaper

A tiny native macOS menu bar app that plays a looping video as your desktop wallpaper — and stops decoding it the moment nobody can see it, so it barely touches your battery.

![LiveWallpaper window](docs/window.png)

## Features

- **Any video, converted automatically — at full quality.** Add a `.mov`, `.mp4`, `.m4v` (or, with ffmpeg installed, `.webm`, `.mkv`, `.avi`…) and it's re-encoded to a muted, hardware-decodable HEVC file at the highest quality, keeping its original resolution (only sources bigger than 4K / your display are scaled down).
- **Separate home and lock screen wallpapers.** The home screen plays the video; the lock screen shows a still frame you pick (see below for why).
- **Quality check.** Every video is compared with your display: you're told if it's low resolution, the wrong aspect ratio (and how much gets cropped), low bitrate or low frame rate.
- **Upscaling, with models only when you ask.** Nothing is bundled with the app. Each model downloads only when you press **Download** (Settings or the Upscale tab) or **Upscale** (after asking), with a progress bar showing size downloaded, time left and time elapsed. Engines:
  - **Real-ESRGAN, in four sizes** — the official weights, SHA-256-pinned, stored in LiveWallpaper's own folder and run on the GPU (Metal Performance Shaders Graph, half precision, in tiles so memory stays bounded). After each upscale you're asked whether to keep or delete the model; every model has **Delete…** (with confirmation).

    | Model | Weights | Best for | Speed on an M5 (10-core GPU) | Peak memory at 1080p |
    |---|---|---|---|---|
    | Small (`realesr-animevideov3`) | 2.5 MB | 8 GB Macs; animation, games, graphics | ~1.0 s/frame | ~1.2 GB |
    | Medium (`realesr-general-x4v3`) | 4.9 MB | most Macs; real-world footage | ~1.3 s/frame | ~1.2 GB |
    | Large 2× (`RealESRGAN_x2plus`) | 64 MB | Pro/Max chips; videos only a little too small | ~2.5 s/frame | ~0.8 GB |
    | Large 4× (`RealESRGAN_x4plus`) | 64 MB | Max/Ultra chips with 32 GB+; very small videos | ~14 s/frame | ~1.8 GB |

    The **Recommended** badge picks the largest model your chip, GPU core count and memory can run comfortably.
  - **Apple Super Resolution** — Apple's on-device model (macOS 26+). macOS downloads and manages it; it's protected by System Integrity Protection, so no app can delete it.
  - **Basic** — Lanczos scaling, no download.
- **Advice for your Mac.** Each model shows how much RAM it needs for the video, roughly how long each frame takes on your GPU, whether it runs on your chip, why not if it can't (too much RAM, unsupported chip/macOS/resolution), and which one is **Recommended** for your chip and memory.
- **Memory tab.** See RAM in use, the apps using the most, quit the ones you pick (or all others) after a confirmation — apps still ask to save — and **Clean Memory** (clears macOS's file cache with `purge`; macOS asks for your password).
- **Resolution.** Choose what wallpapers are checked and upscaled for; the default is your display's true native resolution, detected on any Mac or monitor.
- **Upscale tab.** Upscale any video, GIF or image without making it a wallpaper; results go to Movies › LiveWallpaper Upscaled, with *Use as Wallpaper* one click away.
- **More ways to add wallpapers.** Paste a **YouTube** link (uses [yt-dlp](https://github.com/yt-dlp/yt-dlp): `brew install yt-dlp`; video only, up to your display's resolution — only use videos you have the right to download), or drag **GIFs, animated WebP/PNG, images or links** straight from a browser — they're downloaded and converted automatically.
- **Find Videos.** Scans Movies, Downloads, Desktop, Documents and Pictures for videos that could be wallpapers, grades each against your display (Great fit / Good fit / Low resolution), and lets you tick the ones to add — nothing is added automatically.
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
- **Menu bar panel and a full Mac window.** The panel is for quick picks. The window has a sidebar (Wallpapers, Upscale, Memory, Settings), each section's actions in the toolbar, and live miniatures of your home screen (the wallpaper actually playing) and lock screen (with the clock drawn over it). It's resizable and full-screen capable.
- **Keyboard shortcuts:** ⌘1–⌘3 switch sections, ⌘, opens Settings, ⌘O adds a video, ⌘L adds from YouTube, ⇧⌘F finds videos on this Mac, ⌥⌘P pauses or resumes.
- **ⓘ on everything.** Every setting, section and model has an ⓘ button that explains what it does.
- **Lots of settings** (each with an ⓘ):
  - *Playback* — Low Power Mode, pause when covered, pause on battery, pause below a battery level, all displays or only the main one, dim the wallpaper
  - *Rotation* — change the wallpaper every 15 minutes to every day, in order or shuffled; **Next Wallpaper** (⌘])
  - *Appearance* — light/dark theme, accent colour, menu bar icon, thumbnail size, screen previews, shortcut hints
  - *General* — open at login, open the window at launch, ask before trashing
  - *Importing* — largest size to keep (display / 4K / 1080p), YouTube quality, upscale low-resolution videos automatically, import tips
  - *Upscaling* — resolution, upscaler, work (tile) size, full-precision maths, output quality, output folder
  - *Memory* — refresh rate; *Updates* — see below; and **Restore Defaults**
- **Updates itself in place.** Choose **Automatically** (daily or weekly) or **Manually** (only when you click **Check Now** or **Check for Updates…**); LiveWallpaper checks GitHub's latest release. A new version is downloaded, its checksum, bundle ID, version and code signature are verified, and it **replaces the app where it is** — same name, same folder — then reopens. Your settings, wallpapers, edits, models and login item stay; there's no second copy to delete. Turn off automatic installing to update with a click instead.

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

### Releases

Every push to `main` that changes the app runs [`.github/workflows/release.yml`](.github/workflows/release.yml): it builds on a macOS runner with version `1.<run number>`, zips the app and publishes a GitHub release. Installed copies pick it up through the updater above. (Local builds are version 1.0, so they update to the next release too.)

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
  WindowView.swift       the window: sidebar, toolbar, home/lock previews
  SettingsView.swift     Settings, with an ⓘ on every option
  Prefs.swift            every customisation, stored in UserDefaults
  Updater.swift          checks GitHub releases, verifies and installs updates in place
  PanelView.swift        the menu bar panel + shared tile, notice and drop-zone views
  EditorView.swift       trim / speed / framing / lock frame / quality editor
  VideoInfo.swift        video facts, quality checks against the display, edit model
  Upscaler.swift         upscaling engines (Real-ESRGAN, Apple Super Resolution, Lanczos) + frame pipeline
  RealESRGAN.swift       the four models: download/verify/delete, PyTorch weight reader, networks on Metal (MPSGraph)
  UpscalerModel.swift    reports Apple's macOS-managed model
  VideoScanner.swift     "Find Videos" scan + results sheet
  ModelAdvisor.swift     per-Mac RAM estimates, can-it-run reasons, recommendation
  ModelList.swift        model cards (download/delete, RAM, availability) + download consent
  SystemInfo.swift       chip, RAM, free memory, native display resolution, resolution setting
  MemoryCleaner.swift    Memory tab: usage, quit apps, purge
  UpscaleStudio.swift    the standalone Upscale tab
  AnimatedImage.swift    GIF / animated WebP / image → video (ImageIO)
  WebImport.swift        link downloads and YouTube (yt-dlp) with progress
  TransferProgress.swift size / time-left progress model and card
  LockScreen.swift       lock screen still + restoring your own picture
  PlaybackGate.swift     all play/pause decisions
  Library.swift          import → convert (AVFoundation, ffmpeg fallback) → analysis, edits, upscale jobs
  WallpaperWindow.swift  desktop-level window that loops the video
Resources/AppIcon.icns   app icon (regenerate with scripts/make-icon.swift)
build.sh                 builds LiveWallpaper.app (VERSION=… stamps a version)
.github/workflows/       release on every push to main
```

## License

MIT — see [LICENSE](LICENSE).

Real-ESRGAN upscaling uses the model weights published by Xintao Wang et al. under the BSD-3-Clause license (https://github.com/xinntao/Real-ESRGAN); they're downloaded on request, not included in this repository.
