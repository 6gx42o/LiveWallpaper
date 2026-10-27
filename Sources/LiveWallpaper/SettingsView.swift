import AppKit
import SwiftUI

/// Settings: a grouped form like System Settings, with an ⓘ on every option explaining what it does.
struct SettingsPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs: Prefs
    @ObservedObject var updater: Updater

    init(model: AppModel) {
        self.model = model
        prefs = model.prefs
        updater = model.updater
    }

    var body: some View {
        Form {
            playback
            rotation
            appearance
            general
            importing
            upscaling
            Section {
                Picker(selection: bind(\.memoryRefreshSeconds)) {
                    Text("Every second").tag(1)
                    Text("Every 2 seconds").tag(2)
                    Text("Every 5 seconds").tag(5)
                } label: {
                    label("Refresh the Memory section", info: "How often the memory gauge and app list update while the Memory section is open. Slower refreshing uses a little less energy. Nothing is measured while it's closed.")
                }
            } header: { Text("Memory") }
            updates
            Section {
                HStack {
                    label("Restore default settings", "Your wallpapers, edits and downloaded models are kept.",
                          info: "Puts every option on this page back to how it was when you first installed LiveWallpaper. It doesn't touch your wallpapers, their edits, or downloaded models.")
                    Spacer()
                    Button("Restore Defaults…", action: confirmReset)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Sections

    private var playback: some View {
        Section("Playback") {
            Toggle(isOn: Binding(get: { model.gate.playsInLowPowerMode }, set: { model.gate.playsInLowPowerMode = $0 })) {
                label("Play in Low Power Mode", "Off saves battery: the wallpaper pauses in Low Power Mode.",
                      info: "When macOS Low Power Mode is on (System Settings › Battery), LiveWallpaper normally pauses to save energy. Turn this on to keep the video playing anyway.")
            }
            Toggle(isOn: Binding(get: { model.gate.pausesWhenCovered }, set: { model.gate.pausesWhenCovered = $0 })) {
                label("Pause when the desktop is covered", "Full-screen apps or maximized windows hide the wallpaper anyway.",
                      info: "If a full-screen app or a window filling the whole screen hides the desktop, there's no point decoding video nobody can see — the wallpaper pauses and resumes when the desktop shows again. Each display is checked separately.")
            }
            Toggle(isOn: bind(\.pauseOnBattery)) {
                label("Pause on battery power", "Play only while plugged in.",
                      info: "Stops the video whenever your Mac runs on battery and starts it again when you plug in. The wallpaper still shows its current frame.")
            }
            Picker(selection: bind(\.pauseBelowBattery)) {
                Text("Never").tag(0)
                ForEach([10, 20, 30, 50], id: \.self) { Text("Below \($0)%").tag($0) }
            } label: {
                label("Pause when the battery is low", info: "On battery power, pauses the video once the charge drops below this level, so the wallpaper never costs you the last of your battery.")
            }
            Picker(selection: bind(\.displays)) {
                ForEach(DisplayChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                label("Show the wallpaper on", info: "With more than one display, choose whether every display plays the wallpaper or only the main one (the display with the menu bar). Fewer displays means less work for your Mac.")
            }
            LabeledContent {
                HStack {
                    Slider(value: bind(\.dimming), in: 0...0.7).frame(maxWidth: 220)
                    Text("\(Int((prefs.dimming * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            } label: {
                label("Dim the wallpaper", info: "Darkens the video so desktop icons and text stay easy to read over bright or busy wallpapers. 0% shows it as it is.")
            }
        }
    }

    private var rotation: some View {
        Section {
            Picker(selection: bind(\.rotationMinutes)) {
                Text("Never").tag(0)
                Text("Every 15 minutes").tag(15)
                Text("Every 30 minutes").tag(30)
                Text("Every hour").tag(60)
                Text("Every 3 hours").tag(180)
                Text("Every day").tag(1440)
            } label: {
                label("Change the wallpaper", info: "Cycles through the wallpapers in your library automatically. Broken videos are skipped. You can also switch any time with Wallpaper › Next Wallpaper (⌘]).")
            }
            Picker(selection: bind(\.rotationOrder)) {
                ForEach(RotationOrder.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                label("Order", info: "In order follows the library's alphabetical order; Shuffle picks a different random wallpaper each time.")
            }
            HStack {
                label("Switch now", info: "Moves to the next wallpaper right away, using the order above.")
                Spacer()
                Button("Next Wallpaper") { model.nextWallpaper() }
                    .disabled(model.library.videos.count < 2)
            }
        } header: { Text("Rotation") }
    }

    private var appearance: some View {
        Section("Appearance") {
            Picker(selection: bind(\.theme)) {
                ForEach(Theme.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                label("Theme", info: "Light or Dark for LiveWallpaper's windows, or System to follow macOS. It doesn't change your wallpaper.")
            }
            .pickerStyle(.segmented)
            Picker(selection: bind(\.accent)) {
                ForEach(Accent.allCases, id: \.self) { accent in
                    Label { Text(accent.title) } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(accent.color ?? .accentColor)
                    }
                    .tag(accent)
                }
            } label: {
                label("Accent colour", info: "The highlight colour for selections, buttons and progress bars in LiveWallpaper. System uses the accent colour from System Settings › Appearance.")
            }
            Picker(selection: bind(\.menuBarIcon)) {
                ForEach(MenuBarIcon.allCases, id: \.self) { icon in
                    Label(icon.title, systemImage: icon.rawValue).tag(icon)
                }
            } label: {
                label("Menu bar icon", info: "The symbol LiveWallpaper shows in the menu bar. Click it any time for quick picks.")
            }
            Picker(selection: bind(\.tileSize)) {
                ForEach(TileSize.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                label("Library thumbnails", info: "How big wallpapers appear in the Library grid of this window.")
            }
            .pickerStyle(.segmented)
            Toggle(isOn: bind(\.showPreviews)) {
                label("Show screen previews", "The live Home Screen and Lock Screen miniatures.",
                      info: "The previews at the top of Wallpapers show your actual home screen (the wallpaper playing) and lock screen. They reuse the wallpaper's own video, but turning them off hides them for a simpler, more compact page.")
            }
            Toggle(isOn: bind(\.showShortcutHints)) {
                label("Show keyboard shortcut hints", info: "Shows shortcuts like ⌘1 next to sections in the sidebar. The shortcuts work either way.")
            }
        }
    }

    private var general: some View {
        Section("General") {
            Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 })) {
                label("Open at login", model.launchAtLoginNeedsApproval ? "Allow it in System Settings › General › Login Items." : "Start LiveWallpaper automatically.",
                      info: "Starts LiveWallpaper when you log in so your wallpaper is always playing. macOS may ask you to allow it in System Settings › General › Login Items.")
            }
            Toggle(isOn: bind(\.openWindowAtLaunch)) {
                label("Open this window at launch", info: "Normally LiveWallpaper starts quietly in the menu bar. Turn this on to also open this window every time it starts.")
            }
            Toggle(isOn: bind(\.confirmRemove)) {
                label("Ask before moving a wallpaper to the Trash", info: "Shows a confirmation before the trash button removes a wallpaper from your library. Removed wallpapers go to the Trash, so you can put them back.")
            }
        }
    }

    private var importing: some View {
        Section("Importing") {
            Picker(selection: bind(\.importLimit)) {
                ForEach(ImportLimit.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                label("Largest size to keep", info: "Videos bigger than this are scaled down when they're added. Smaller files use less disk space and less battery to play; anything larger than your display can't be seen anyway. Smaller videos are never enlarged here — that's what upscaling is for.")
            }
            Picker(selection: bind(\.youTubeQuality)) {
                ForEach(YouTubeQuality.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                label("YouTube download quality", info: "The highest resolution fetched from YouTube links. Match my display picks 4K for large displays and 1440p otherwise. Higher means sharper but bigger downloads.")
            }
            Toggle(isOn: bind(\.autoUpscale)) {
                label("Upscale low-resolution videos automatically", "Uses the upscaler below, if its model is already downloaded.",
                      info: "When a video you add would look soft on your display, it's upscaled right away instead of showing an Upscale button. Models are never downloaded without asking, so this only happens once the chosen upscaler is ready.")
            }
            Toggle(isOn: bind(\.showImportTips)) {
                label("Show tips after importing", info: "After adding a video, LiveWallpaper mentions small things worth knowing — slightly soft resolution, low frame rate, or a mismatched shape. Warnings about real problems always show.")
            }
        }
    }

    private var upscaling: some View {
        Section {
            Picker(selection: Binding(get: { model.resolution }, set: { model.resolution = $0 })) {
                ForEach(ResolutionChoice.allCases) { Text($0.title).tag($0) }
            } label: {
                label("Resolution", "Wallpapers are checked and upscaled for this.",
                      info: "The screen size wallpapers are judged and upscaled against. Native is your display's own pixel count, so upscaled wallpapers are as sharp as your screen can show.")
            }
            Picker(selection: Binding(get: { model.upscaler }, set: { model.upscaler = $0 })) {
                ForEach(Upscaler.Engine.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                label("Upscaler", info: "Which model the Upscale buttons use. Small models are fast and light; Large ones add more detail but need a powerful Mac and lots of time. The card below shows how it would run on this Mac.")
            }
            ModelList(model: model, input: ModelAdvisor.typicalInput, inputLabel: "a 1080p video", compact: true, engines: [model.upscaler])
            Toggle(isOn: Binding(get: { model.asksToDeleteModel }, set: { model.asksToDeleteModel = $0 })) {
                label("Ask after upscaling", "Offer to keep or delete the Real-ESRGAN model each time it's used.",
                      info: "After each upscale, asks whether to keep the model for next time or delete it to free disk space.")
            }
            Picker(selection: bind(\.upscaleTile)) {
                ForEach(TileChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                label("Work size", info: "Real-ESRGAN processes each frame in tiles. Smaller tiles use less memory (good for 8 GB Macs or the Large models) but take a little longer; larger tiles are faster if you have memory to spare.")
            }
            Toggle(isOn: bind(\.upscaleFullPrecision)) {
                label("Full-precision maths", "Slower; results look the same in almost every case.",
                      info: "Real-ESRGAN normally runs in half precision, which is much faster on Apple GPUs and is how its authors run it. Full precision is there if you ever see banding or odd colours.")
            }
            LabeledContent {
                HStack {
                    Slider(value: bind(\.upscaleQuality), in: 0.6...1).frame(maxWidth: 220)
                    Text("\(Int((prefs.upscaleQuality * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            } label: {
                label("Upscaled video quality", info: "How much detail the HEVC encoder keeps when saving an upscaled video. Higher looks better but makes bigger files. 85% is visually lossless for most wallpapers.")
            }
            LabeledContent {
                HStack {
                    Text(UpscaleStudio.outputDir.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary).frame(maxWidth: 260, alignment: .trailing)
                    Button("Choose…", action: chooseFolder)
                    if !prefs.upscaleFolder.isEmpty { Button("Reset") { prefs.upscaleFolder = "" } }
                }
            } label: {
                label("Save upscaled videos to", info: "Where the Upscale section saves its results. Wallpapers you upscale from the library stay in the library either way.")
            }
        } header: {
            Text("Upscaling")
        } footer: {
            Button("Compare all models…") { model.tab = .upscale }.buttonStyle(.link)
        }
    }

    private var updates: some View {
        Section("Updates") {
            HStack(alignment: .firstTextBaseline) {
                label("LiveWallpaper \(Updater.currentVersion)", updateStatus,
                      info: "LiveWallpaper checks GitHub for new versions. Updates download, are verified, and replace this app in place — your settings, wallpapers and models stay, and there's no second copy to delete.")
                Spacer()
                updateAction
            }
            if case .downloading(let fraction) = updater.state {
                ProgressView(value: fraction ?? 0).progressViewStyle(.linear)
            }
            Toggle(isOn: bind(\.autoCheckUpdates)) {
                label("Check for updates automatically", info: "Looks for a new release in the background on the schedule below. It only contacts GitHub and sends nothing about you.")
            }
            Picker(selection: bind(\.updateIntervalHours)) {
                Text("Daily").tag(24)
                Text("Weekly").tag(168)
            } label: {
                label("How often", info: "How often the automatic check runs.")
            }
            .disabled(!prefs.autoCheckUpdates)
            Toggle(isOn: bind(\.autoInstallUpdates)) {
                label("Install updates automatically", "Waits until nothing is converting or upscaling.",
                      info: "Downloads and installs new versions by itself, then reopens LiveWallpaper. It waits while you're converting, upscaling or editing. Turn it off to install with a click instead.")
            }
            .disabled(!prefs.autoCheckUpdates)
        }
    }

    private var updateStatus: String {
        switch updater.state {
        case .idle: updater.lastCheck.map { "Last checked \($0.formatted(.relative(presentation: .named)))." } ?? "Not checked yet."
        case .checking: "Checking…"
        case .upToDate: "You're up to date."
        case .available(let release): "Version \(release.version) is available."
        case .downloading: "Downloading the update…"
        case .installing: "Installing — LiveWallpaper will reopen."
        case .failed(let message): message
        }
    }

    @ViewBuilder private var updateAction: some View {
        switch updater.state {
        case .available(let release):
            Button("Install and Relaunch") { updater.install(release) }.keyboardShortcut(.defaultAction)
        case .failed:
            Button("Open Releases Page") {
                NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repository)/releases")!)
            }
            Button("Try Again") { updater.check(userInitiated: true) }
        case .checking, .downloading, .installing:
            ProgressView().controlSize(.small)
        default:
            Button("Check Now") { updater.check(userInitiated: true) }
        }
    }

    // MARK: Helpers

    private func bind<V>(_ keyPath: ReferenceWritableKeyPath<Prefs, V>) -> Binding<V> {
        Binding(get: { prefs[keyPath: keyPath] }, set: { prefs[keyPath: keyPath] = $0 })
    }

    /// A setting's title with its ⓘ, and an optional one-line description under it.
    private func label(_ title: String, _ detail: String? = nil, info: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title)
                InfoButton(info)
            }
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where upscaled videos are saved"
        if panel.runModal() == .OK, let url = panel.url { prefs.upscaleFolder = url.path }
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Restore default settings?"
        alert.informativeText = "Every option on this page goes back to its default. Your wallpapers, edits and downloaded models are kept."
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        prefs.resetAll()
        model.gate.playsInLowPowerMode = false
        model.gate.pausesWhenCovered = true
        model.asksToDeleteModel = true
    }
}
