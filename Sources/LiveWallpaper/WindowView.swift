import AVFoundation
import SwiftUI

/// The app window: a sidebar of sections, each section's actions in the toolbar.
struct WindowView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(model.tab.rawValue)
                .overlay { if model.isDropTargeted { DropOverlay(tab: model.tab).transition(dropTransition) } }
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 1), value: model.isDropTargeted)
        }
        .frame(minWidth: 860, minHeight: 580)
        .sheet(isPresented: Binding(get: { model.editor != nil }, set: { if !$0 { model.closeEditor(save: false) } })) {
            if let editor = model.editor {
                EditorView(
                    editor: editor,
                    upscaleMethod: model.upscaleMethod(for: editor.url).name,
                    upscale: { model.upscale(editor.url) },
                    useForLockScreen: { model.useEditorFrameForLockScreen() },
                    close: { model.closeEditor(save: $0) }
                )
            }
        }
        .sheet(isPresented: Binding(get: { model.scanner != nil }, set: { if !$0 { model.finishScan(adding: []) } })) {
            if let scanner = model.scanner {
                ScanView(scanner: scanner) { model.finishScan(adding: $0) }
            }
        }
    }

    private var dropTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98))
    }

    @ViewBuilder private var detail: some View {
        switch model.tab {
        case .wallpapers:
            ScrollView { WallpapersPane(model: model).padding(24) }
                .toolbar { wallpaperToolbar }
        case .upscale:
            ScrollView { UpscaleView(studio: model.studio, model: model).padding(24) }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { model.studio.choose() } label: { Label("Choose File", systemImage: "plus") }
                            .help("Choose a video, GIF or image to upscale (⌘O)")
                            .disabled(model.studio.isBusy)
                    }
                }
        case .memory:
            MemoryView(cleaner: model.memory, needed: memoryNeed).padding(24)
        case .settings:
            SettingsPane(model: model)
        }
    }

    @ToolbarContentBuilder private var wallpaperToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.gate.userPaused.toggle() } label: {
                Label(model.gate.userPaused ? "Resume" : "Pause", systemImage: model.gate.userPaused ? "play.fill" : "pause.fill")
            }
            .disabled(model.current == nil || model.isCurrentBroken)
            .help(model.gate.userPaused ? "Resume the wallpaper (⌥⌘P)" : "Pause the wallpaper (⌥⌘P)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.addFromYouTube() } label: { Label("YouTube", systemImage: "play.rectangle") }
                .help("Add a wallpaper from a YouTube link (⌘L)")
            Button { model.startScan() } label: { Label("Find Videos", systemImage: "magnifyingglass") }
                .help("Find videos on this Mac that could be wallpapers (⇧⌘F)")
            Button { model.addVideos() } label: { Label("Add Video", systemImage: "plus") }
                .help("Add a video or GIF (⌘O)")
        }
    }

    /// What the chosen upscaler needs, shown in Memory.
    private var memoryNeed: (name: String, bytes: Int64)? {
        let engine = model.studio.info != nil ? model.studio.engine : model.upscaler
        guard engine != .basic else { return nil }
        let input = model.studio.info?.size ?? ModelAdvisor.typicalInput
        return (engine.title, ModelAdvisor.estimatedMemory(engine, input: input))
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: Binding<AppModel.Tab?>(get: { model.tab }, set: { if let tab = $0 { model.tab = tab } })) {
            Section {
                ForEach([AppModel.Tab.wallpapers, .upscale, .memory], id: \.self, content: row)
            }
            Section {
                row(.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            let status = model.status
            HStack(spacing: 6) {
                Circle().fill(status.color).frame(width: 7, height: 7)
                Text(status.text).lineLimit(1).truncationMode(.tail)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .accessibilityIdentifier("status")
        }
    }

    private func row(_ tab: AppModel.Tab) -> some View {
        HStack {
            Label(tab.rawValue, systemImage: tab.symbol)
            Spacer()
            Text(tab == .settings ? "⌘," : "⌘\((AppModel.Tab.allCases.firstIndex(of: tab) ?? 0) + 1)")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .tag(tab)
    }
}

// MARK: - Wallpapers

private struct WallpapersPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let lib = model.library
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 20) {
                homeScreen
                lockScreen
            }

            if lib.converting != nil || !lib.notices.isEmpty {
                VStack(spacing: 8) {
                    if let converting = lib.converting {
                        ProgressCard(progress: converting) { model.library.cancelCurrentJob() }
                    }
                    ForEach(lib.notices) { notice in
                        NoticeCard(
                            notice: notice,
                            upscale: notice.upscale.map { url in { model.upscale(url); model.library.dismiss(notice) } },
                            dismiss: { model.library.dismiss(notice) }
                        )
                    }
                }
            }

            if lib.videos.isEmpty {
                DropZone(isLarge: true, acceptsDrops: true, add: model.addVideos)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Library").font(.title3.weight(.semibold))
                        Text("\(lib.videos.count)").foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Text("Click to set the home screen · drop videos anywhere to add")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 16)], spacing: 18) {
                        ForEach(lib.videos, id: \.self) { url in
                            WallpaperTile(model: model, url: url)
                        }
                    }
                }
            }
        }
    }

    private func name(_ url: URL?) -> String? { url?.deletingPathExtension().lastPathComponent }

    private var homeScreen: some View {
        let url = model.isCurrentBroken ? nil : model.current
        let info = url.flatMap { model.library.infos[$0] }
        return ScreenCaption(title: "Home Screen", detail: name(model.current) ?? "No video — pick one below", symbol: "house.fill") {
            ScreenFrame(showsMenuBar: true) {
                if let url, let info, let player = model.previewPlayer {
                    PlayerPreview(player: player, video: info.size, edits: model.library.edits(for: url))
                } else if let still = model.lockPreview {
                    Image(nsImage: still).resizable().scaledToFill().opacity(0.45)
                }
            }
        } accessory: {
            let status = model.status
            HStack(spacing: 5) {
                Circle().fill(status.color).frame(width: 6, height: 6)
                Text(status.text)
            }
        }
    }

    private var lockScreen: some View {
        ScreenCaption(title: "Lock Screen", detail: name(model.lockScreen) ?? "Your own desktop picture", symbol: "lock.fill") {
            ScreenFrame {
                if let still = model.lockPreview { Image(nsImage: still).resizable().scaledToFill() }
            }
            .overlay { LockClock() }
        } accessory: {
            if model.lockScreen != nil {
                Button("Restore Mine") { model.setLockScreen(nil) }
                    .buttonStyle(.link)
                    .help("Remove the lock screen wallpaper and put your own desktop picture back")
            } else {
                Text("Click the lock on a wallpaper to use it here")
            }
        }
    }
}

/// A miniature display: your screen's shape, a thin bezel, rounded like a Mac display.
private struct ScreenFrame<Content: View>: View {
    /// A hint of the menu bar, so the home screen reads as your desktop.
    var showsMenuBar = false
    @ViewBuilder let content: Content

    private var aspect: CGFloat {
        let size = NSScreen.main?.frame.size ?? CGSize(width: 16, height: 10)
        return size.width / max(size.height, 1)
    }

    var body: some View {
        Color.black
            .overlay { content }
            .overlay(alignment: .top) { if showsMenuBar { Color.white.opacity(0.18).frame(height: 7) } }
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(4)
            .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

/// The date and time drawn over the lock screen preview, the way macOS shows them.
private struct LockClock: View {
    var body: some View {
        GeometryReader { geo in
            TimelineView(.everyMinute) { context in
                VStack(spacing: geo.size.width * 0.005) {
                    Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.system(size: geo.size.width * 0.035, weight: .semibold))
                    Text(context.date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                        .font(.system(size: geo.size.width * 0.16, weight: .semibold, design: .rounded))
                        .tracking(-geo.size.width * 0.003)
                }
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.25), radius: 6)
                .frame(maxWidth: .infinity)
                .padding(.top, geo.size.height * 0.1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ScreenCaption<Screen: View, Accessory: View>: View {
    let title: String
    let detail: String
    let symbol: String
    @ViewBuilder let screen: Screen
    @ViewBuilder let accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            screen
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Label(title, systemImage: symbol).font(.headline)
                    Spacer()
                    accessory.font(.caption).foregroundStyle(.secondary)
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Shown over the window while files are dragged in.
private struct DropOverlay: View {
    let tab: AppModel.Tab

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 40)).foregroundStyle(.tint)
                Text(tab == .upscale ? "Drop to upscale" : "Drop to add to your library").font(.title3.weight(.semibold))
                Text(tab == .upscale ? "Videos, GIFs and images" : "Videos, GIFs and links are converted automatically")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(12)
        )
        .allowsHitTesting(false)
    }
}

// MARK: - Settings

private struct SettingsPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Playback") {
                Toggle(isOn: Binding(get: { model.gate.playsInLowPowerMode }, set: { model.gate.playsInLowPowerMode = $0 })) {
                    Text("Play in Low Power Mode")
                    Text("Off saves battery: the wallpaper pauses in Low Power Mode.")
                }
                Toggle(isOn: Binding(get: { model.gate.pausesWhenCovered }, set: { model.gate.pausesWhenCovered = $0 })) {
                    Text("Pause when the desktop is covered")
                    Text("Full-screen apps or maximized windows hide the wallpaper anyway.")
                }
            }
            Section("General") {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 })) {
                    Text("Open at login")
                    Text(model.launchAtLoginNeedsApproval
                         ? "Allow it in System Settings › General › Login Items."
                         : "Start LiveWallpaper automatically.")
                }
            }
            Section {
                Picker(selection: Binding(get: { model.resolution }, set: { model.resolution = $0 })) {
                    ForEach(ResolutionChoice.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Resolution")
                    Text("Wallpapers are checked and upscaled for this. Native is your display's own resolution.")
                }
                Picker("Upscaler", selection: Binding(get: { model.upscaler }, set: { model.upscaler = $0 })) {
                    ForEach(Upscaler.Engine.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                ModelList(model: model, input: ModelAdvisor.typicalInput, inputLabel: "a 1080p video", compact: true, engines: [model.upscaler])
                Toggle(isOn: Binding(get: { model.asksToDeleteModel }, set: { model.asksToDeleteModel = $0 })) {
                    Text("Ask after upscaling")
                    Text("Offer to keep or delete the Real-ESRGAN model each time it's used.")
                }
            } header: {
                Text("Quality & upscaling")
            } footer: {
                Button("Compare all models…") { model.tab = .upscale }.buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
    }
}
