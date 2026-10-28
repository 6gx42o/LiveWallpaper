# LiveWallpaper

A tiny native macOS menu bar app that plays a looping video as your desktop wallpaper — and stops decoding it the moment nobody can see it, so it barely touches your battery.

![LiveWallpaper window](docs/window.png)

## Features

- **Any video, converted automatically — at full quality.** Add a `.mov`, `.mp4`, `.m4v` (or, with ffmpeg installed, `.webm`, `.mkv`, `.avi`…) and it's re-encoded to a muted, hardware-decodable HEVC file at the highest quality, keeping its original resolution (only sources bigger than 4K / your display are scaled down).
- **Separate home and lock screen wallpapers.** The home screen plays the video; the lock screen shows a still frame you pick (see below for why).
- **Quality check.** Every video is compared with your display: you're told if it's low resolution, the wrong aspect ratio (and how much gets cropped), low bitrate or low frame rate.
- **Upscaling, with models only when you ask.** Nothing is bundled with the app. Each model downloads only when you press **Download** (Settings or the Upscale tab) or **Upscale** (after asking), with a progress bar showing size downloaded, time left and time elapsed. Engines:
  - **Fourteen models, small to very large** — official Real-ESRGAN (BSD-3), SwinIR (Apache-2.0) and HAT (Apache-2.0) weights, SHA-256-pinned, stored in LiveWallpaper's own folder and run on the GPU (Metal Performance Shaders Graph, half precision with a float32 residual stream where needed, in tiles so memory stays bounded). Every network is checked against PyTorch: outputs match within 1–3 levels out of 255. After each upscale you're asked whether to keep or delete the model; every model has **Delete…**.

    | Model | Weights | Best for | Seconds per 1080p frame on an M5 (10-core GPU) | Needs |
    |---|---|---|---|---|
    | Real-ESRGAN Small | 2.5 MB | 8 GB Macs; animation, games | ~0.5 | 8 GB |
    | Real-ESRGAN Medium | 4.9 MB | most Macs; real-world footage | ~0.7 | 8 GB |
    | Real-ESRGAN Anime | 18 MB | anime and cartoons | ~3.4 | 8 GB |
    | Real-ESRGAN Large 2× | 64 MB | videos only a little too small | ~2.3 | 8 GB |
    | Real-ESRGAN Large 4× | 64 MB | small videos | ~10.6 | 8 GB |
    | Real-ESRGAN Large 4× Smooth | 64 MB | fewer invented details (faces, text) | ~10.1 | 8 GB |
    | SwinIR Medium 2× / 4× | 67 MB | transformer detail; Pro chips | ~30 | 16 GB |
    | SwinIR Large 4× | 142 MB | the most detail; Max and Ultra chips | ~61 | 32 GB |
    | SwinIR Large 4× Smooth | 142 MB | the same transformer, fewer invented details | ~61 | 32 GB |
    | HAT 4× / HAT 4× Sharper | 170 MB | the strongest single model; Max and Ultra chips | ~56 | 48 GB |
    | HAT 4× Ensemble | (HAT's file) | the very biggest Macs: HAT as is and mirrored, averaged | ~111 | 128 GB |
    | SwinIR Large 4× Ensemble | (SwinIR Large's file) | the biggest Macs: each frame upscaled as is and mirrored, averaged — steadier detail | ~122 | 96 GB |

  - **Three picks for your Mac.** Worked out from your GPU core count, memory and the video:
    - **Recommended for speed** — the sharpest model that's still quick on your Mac (~1.5 s a frame or less). It's a balance, not just the fastest: a 24 GB Pro gets Large 2× where an 8 GB Air gets Medium.
    - **Recommended for quality** — the best results within a reasonable time (~15 s a frame).
    - **Max for this Mac** — the biggest model it can handle: Large 2× on 8–16 GB Macs, SwinIR Medium from 16 GB with a fast enough GPU, SwinIR Large from 32 GB (Max and Ultra chips), HAT from 48 GB, SwinIR Large Ensemble from 96 GB and HAT Ensemble from 128 GB, each on Macs fast enough to run it. Anything beyond is **greyed out** with the reason (not enough memory, or it would take over 30 s a frame). On 64 GB+ Macs, Automatic work size also uses bigger tiles (2× at 64 GB, 4× at 128 GB and up).
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
- **Menu bar panel and a full Mac window.** The panel is for quick picks. The window puts its sections (Wallpapers, Upscale, Memory, Settings) as tabs in the toolbar — a pill glides to the one you pick and pages slide in the direction you move (a cross-fade with Reduce Motion) — with each section's actions beside them, playback status on the left, and live miniatures of your home screen (the wallpaper actually playing) and lock screen (with the clock drawn over it). It's resizable and full-screen capable.
- **Keyboard shortcuts:** ⌘1–⌘3 switch sections, ⌘, opens Settings, ⌘O adds a video, ⌘L adds from YouTube, ⇧⌘F finds videos on this Mac, ⌥⌘P pauses or resumes.
- **A different wallpaper on each display.** With more than one display, Wallpapers shows a live preview per display: drag a wallpaper onto one (or use its Show menu, or right-click a thumbnail › Use on Display) to give it its own video; the rest show the default. Choices are remembered per display, even after unplugging, and rotation moves every display along.
- **Favorites, search and sorting.** Star wallpapers (hover a thumbnail), search the library, filter to favorites, and sort by name, newest, resolution, length or favorites first. Rotation can be limited to favorites.
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
  WindowView.swift       the window: toolbar tabs, page transitions, home/lock previews
  SettingsView.swift     Settings, with an ⓘ on every option
  Prefs.swift            every customisation, stored in UserDefaults
  Updater.swift          checks GitHub releases, verifies and installs updates in place
  PanelView.swift        the menu bar panel + shared tile, notice and drop-zone views
  EditorView.swift       trim / speed / framing / lock frame / quality editor
  VideoInfo.swift        video facts, quality checks against the display, edit model
  Upscaler.swift         upscaling engines (Real-ESRGAN, Apple Super Resolution, Lanczos) + frame pipeline
  RealESRGAN.swift       the ten models: download/verify/delete, PyTorch weight reader, Real-ESRGAN + SwinIR on Metal (MPSGraph)
  UpscalerModel.swift    reports Apple's macOS-managed model
  VideoScanner.swift     "Find Videos" scan + results sheet
  ModelAdvisor.swift     per-Mac time and memory estimates, can-it-run reasons, speed/quality/max picks
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

Real-ESRGAN upscaling uses the model weights published by Xintao Wang et al. under the BSD-3-Clause license (https://github.com/xinntao/Real-ESRGAN), SwinIR the weights published by Jingyun Liang et al. under the Apache-2.0 license (https://github.com/JingyunLiang/SwinIR), and HAT the weights published by Xiangyu Chen et al. under the Apache-2.0 license (https://github.com/XPixelGroup/HAT, downloaded from the authors' Google Drive); they're downloaded on request, not included in this repository.
