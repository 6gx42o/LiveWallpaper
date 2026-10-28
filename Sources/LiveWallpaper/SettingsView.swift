import AppKit
import SwiftUI

/// Settings: a grouped form like System Settings, with an ⓘ on every option explaining what it does.
struct SettingsPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs: Prefs
    @ObservedObject var updater: Updater
    @ObservedObject var scheduler: Scheduler

    init(model: AppModel) {
        self.model = model
        prefs = model.prefs
        updater = model.updater
        scheduler = model.scheduler
    }

    var body: some View {
        Form {
            playback
            schedule
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

    private var schedule: some View {
        Section("Schedule") {
            Picker(selection: Binding(get: { scheduler.mode }, set: { scheduler.mode = $0 })) {
                ForEach(Scheduler.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                label("Change the wallpaper", info: "Switch the wallpaper automatically: at times you choose, at sunrise and sunset where you are, or along with macOS's Light and Dark appearance (handy if your Mac switches to Dark at night). It sets the default wallpaper; displays you've given their own keep it. Rotation pauses while a schedule is on.")
            }
            switch scheduler.mode {
            case .off:
                EmptyView()
            case .times:
                ForEach(Array(scheduler.rules.enumerated()), id: \.offset) { index, rule in
                    HStack {
                        DatePicker("From", selection: Binding(
                            get: { Calendar.current.date(byAdding: .minute, value: rule.minutes, to: Calendar.current.startOfDay(for: .now))! },
                            set: { scheduler.rules[index].minutes = Scheduler.minutes(of: $0) }), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                        Text("show").foregroundStyle(.secondary)
                        wallpaperPicker(Binding(get: { rule.wallpaper }, set: { scheduler.rules[index].wallpaper = $0 }))
                        Spacer()
                        Button { scheduler.rules.remove(at: index) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove this time")
                    }
                }
                Button("Add a Time") {
                    let last = scheduler.rules.map(\.minutes).max() ?? 7 * 60 - 60
                    scheduler.rules.append(.init(minutes: min(last + 60, 23 * 60 + 59), wallpaper: model.library.videos.first?.lastPathComponent ?? ""))
                }
            case .sun, .appearance:
                LabeledContent {
                    wallpaperPicker(Binding(get: { scheduler.dayWallpaper }, set: { scheduler.dayWallpaper = $0 }))
                } label: {
                    label(scheduler.mode == .sun ? "Daytime" : "Light mode", info: scheduler.mode == .sun ? "Shown from sunrise to sunset." : "Shown while macOS is in Light appearance.")
                }
                LabeledContent {
                    wallpaperPicker(Binding(get: { scheduler.nightWallpaper }, set: { scheduler.nightWallpaper = $0 }))
                } label: {
                    label(scheduler.mode == .sun ? "Night" : "Dark mode", info: scheduler.mode == .sun ? "Shown from sunset to sunrise." : "Shown while macOS is in Dark appearance.")
                }
                if scheduler.mode == .sun { sunLocation }
            }
        }
    }

    @ViewBuilder private var sunLocation: some View {
        HStack {
            label("Location", sunSummary,
                  info: "Sunrise and sunset depend on where you are. Use My Location asks macOS once for your approximate position (rounded to about a kilometre and kept only on this Mac), or type a latitude and longitude.")
            Spacer()
            TextField("Latitude", value: Binding(get: { scheduler.latitude }, set: { scheduler.latitude = $0 }), format: .number.precision(.fractionLength(0...2)))
                .frame(width: 80).textFieldStyle(.roundedBorder)
            TextField("Longitude", value: Binding(get: { scheduler.longitude }, set: { scheduler.longitude = $0 }), format: .number.precision(.fractionLength(0...2)))
                .frame(width: 90).textFieldStyle(.roundedBorder)
            Button("Use My Location") { scheduler.useCurrentLocation() }
        }
        if let message = scheduler.locationMessage {
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var sunSummary: String {
        guard let lat = scheduler.latitude, let lon = scheduler.longitude else { return "Not set yet — daytime wallpaper is used until it is." }
        guard let sun = Scheduler.sunTimes(on: .now, latitude: lat, longitude: lon) else { return "No sunrise or sunset today at this latitude." }
        return "Today: sunrise \(sun.sunrise.formatted(date: .omitted, time: .shortened)), sunset \(sun.sunset.formatted(date: .omitted, time: .shortened))."
    }

    private func wallpaperPicker(_ selection: Binding<String>) -> some View {
        Picker("Wallpaper", selection: selection) {
            Text("Choose…").tag("")
            ForEach(model.library.videos, id: \.self) { Text($0.deletingPathExtension().lastPathComponent).tag($0.lastPathComponent) }
        }
        .labelsHidden().frame(maxWidth: 220)
    }

    private var rotation: some View {
        Section {
            if scheduler.isActive {
                Text("Paused while a schedule is on.").font(.caption).foregroundStyle(.secondary)
            }
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
            Toggle(isOn: bind(\.rotationFavoritesOnly)) {
                label("Only favorites", "Rotate between starred wallpapers.",
                      info: "Star wallpapers in the library (hover a thumbnail and click the star) and rotation — and Next Wallpaper — will only pick from those. Needs at least two favorites; otherwise the whole library is used.")
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
            Toggle(isOn: bind(\.showImportTips)) {
                label("Show tips after importing", info: "After adding a video, LiveWallpaper mentions small things worth knowing — slightly soft resolution, low frame rate, or a mismatched shape. Warnings about real problems always show.")
            }
        }
    }

    private var upscaling: some View {
        Section("Upscaling") {
            HStack {
                label("Upscaling options", "Model, resolution, quality and where results go are in the Upscale section.",
                      info: "Everything about upscaling — which model, its speed and quality picks for this Mac, the resolution, work size, video quality and the folder for results — lives in the Upscale section, next to the models themselves.")
                Spacer()
                Button("Open Upscale") { model.tab = .upscale }
            }
        }
    }

    private var updates: some View {
        Section("Updates") {
            Picker(selection: bind(\.autoCheckUpdates)) {
                Text("Automatically").tag(true)
                Text("Manually").tag(false)
            } label: {
                label("Check for updates", prefs.autoCheckUpdates ? "LiveWallpaper looks for new versions on its own." : "Only when you click Check Now (or LiveWallpaper › Check for Updates…).",
                      info: "Automatically looks for a new release in the background on the schedule below. Manually never checks on its own — use Check Now here or Check for Updates… in the LiveWallpaper menu. Checking only contacts GitHub and sends nothing about you.")
            }
            .pickerStyle(.segmented)
            HStack(alignment: .firstTextBaseline) {
                label("LiveWallpaper \(Updater.currentVersion)", updateStatus,
                      info: "Updates download, are verified, and replace this app in place — your settings, wallpapers and models stay, and there's no second copy to delete.")
                Spacer()
                updateAction
            }
            if case .downloading(let fraction) = updater.state {
                ProgressView(value: fraction ?? 0).progressViewStyle(.linear)
            }
            if prefs.autoCheckUpdates {
                Picker(selection: bind(\.updateIntervalHours)) {
                    Text("Daily").tag(24)
                    Text("Weekly").tag(168)
                } label: {
                    label("How often", info: "How often the automatic check runs.")
                }
                Toggle(isOn: bind(\.autoInstallUpdates)) {
                    label("Install updates automatically", "Waits until nothing is converting or upscaling.",
                          info: "Downloads and installs new versions by itself, then reopens LiveWallpaper. It waits while you're converting, upscaling or editing. Turn it off to be asked first: the update shows here with an Install and Relaunch button.")
                }
            }
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

    private func label(_ title: String, _ detail: String? = nil, info: String) -> some View {
        SettingLabel(title: title, detail: detail, info: info)
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

/// A setting's title with its ⓘ, and an optional one-line description under it.
struct SettingLabel: View {
    let title: String
    var detail: String?
    let info: String

    var body: some View {
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
}

/// The upscaling options, shown in the Upscale section next to the models (each with its ⓘ).
struct UpscaleSettingsCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs: Prefs

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row {
                SettingLabel(title: "Resolution", detail: "Wallpapers are checked and upscaled for this.",
                             info: "The screen size wallpapers are judged and upscaled against. Native is your display's own pixel count, so upscaled wallpapers are as sharp as your screen can show.")
            } control: {
                Picker("Resolution", selection: Binding(get: { model.resolution }, set: { model.resolution = $0 })) {
                    ForEach(ResolutionChoice.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 320)
            }
            row {
                SettingLabel(title: "Work size", info: "Models process each frame in tiles. Smaller tiles use less memory (good for 8 GB Macs or the big models) but take a little longer; larger tiles are faster if you have memory to spare. Automatic uses bigger tiles on 64 GB+ Macs.")
            } control: {
                Picker("Work size", selection: bind(\.upscaleTile)) {
                    ForEach(TileChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 240)
            }
            row {
                SettingLabel(title: "Full-precision maths", detail: "Slower; results look the same in almost every case.",
                             info: "Models normally run in half precision, which is much faster on Apple GPUs and is how their authors run them. Full precision is there if you ever see banding or odd colours.")
            } control: {
                Toggle("Full-precision maths", isOn: bind(\.upscaleFullPrecision)).labelsHidden().toggleStyle(.switch)
            }
            row {
                SettingLabel(title: "Upscaled video quality", info: "How much detail the HEVC encoder keeps when saving an upscaled video. Higher looks better but makes bigger files. 85% is visually lossless for most wallpapers.")
            } control: {
                HStack {
                    Slider(value: bind(\.upscaleQuality), in: 0.6...1).frame(maxWidth: 200)
                    Text("\(Int((prefs.upscaleQuality * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
            row {
                SettingLabel(title: "Save results to", info: "Where this section saves upscaled videos. Wallpapers you upscale from the library stay in the library either way.")
            } control: {
                HStack {
                    Text(UpscaleStudio.outputDir.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary).frame(maxWidth: 240, alignment: .trailing)
                    Button("Choose…", action: chooseFolder)
                    if !prefs.upscaleFolder.isEmpty { Button("Reset") { prefs.upscaleFolder = "" } }
                }
            }
            row {
                SettingLabel(title: "Upscale low-resolution imports automatically", detail: "Only when the chosen model is already downloaded.",
                             info: "When a video you add would look soft on your display, it's upscaled right away instead of showing an Upscale button. Models are never downloaded without asking, so this only happens once the chosen upscaler is ready.")
            } control: {
                Toggle("Upscale automatically", isOn: bind(\.autoUpscale)).labelsHidden().toggleStyle(.switch)
            }
            row(last: true) {
                SettingLabel(title: "Ask after upscaling", detail: "Offer to keep or delete the downloaded model each time it's used.",
                             info: "After each upscale, asks whether to keep the model for next time or delete it to free disk space.")
            } control: {
                Toggle("Ask after upscaling", isOn: Binding(get: { model.asksToDeleteModel }, set: { model.asksToDeleteModel = $0 }))
                    .labelsHidden().toggleStyle(.switch)
            }
        }
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row<Label: View, Control: View>(last: Bool = false, @ViewBuilder _ label: () -> Label,
                                                  @ViewBuilder control: () -> Control) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                label()
                Spacer(minLength: 12)
                control()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if !last { Divider().padding(.leading, 14) }
        }
    }

    private func bind<V>(_ keyPath: ReferenceWritableKeyPath<Prefs, V>) -> Binding<V> {
        Binding(get: { prefs[keyPath: keyPath] }, set: { prefs[keyPath: keyPath] = $0 })
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
}
