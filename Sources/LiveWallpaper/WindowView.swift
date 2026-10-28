import AVFoundation
import SwiftUI

/// The app window: sections as tabs in the toolbar (no sidebar), each section's actions beside them.
struct WindowView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            page(model.tab)
                .id(model.tab)
                .transition(pageTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 1), value: model.tab)
        .overlay { if model.isDropTargeted { DropOverlay(tab: model.tab).transition(dropTransition) } }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 1), value: model.isDropTargeted)
        .navigationTitle(model.tab.rawValue)
        .toolbar { toolbar }
        .frame(minWidth: 860, minHeight: 580)
        .tint(model.prefs.accent.color)
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

    /// Pages slide in from the side you're heading to and out the other way (a fade with Reduce Motion).
    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let dx: CGFloat = model.tabMovedForward ? 36 : -36
        // The old page leaves quickly so the two never read as one jumbled page mid-switch.
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: dx)),
                           removal: .opacity.combined(with: .offset(x: -dx)).animation(.easeOut(duration: 0.12)))
    }

    private var dropTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98))
    }

    @ViewBuilder private func page(_ tab: AppModel.Tab) -> some View {
        switch tab {
        case .wallpapers: ScrollView { WallpapersPane(model: model).padding(24) }
        case .upscale: ScrollView { UpscaleView(studio: model.studio, model: model).padding(24) }
        case .memory: MemoryView(cleaner: model.memory, needed: memoryNeed).padding(24)
        case .settings: SettingsPane(model: model)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.gate.userPaused.toggle() } label: {
                Label(model.gate.userPaused ? "Resume" : "Pause", systemImage: model.gate.userPaused ? "play.fill" : "pause.fill")
            }
            .disabled(model.current == nil || model.isCurrentBroken)
            .help(model.gate.userPaused ? "Resume the wallpaper (⌥⌘P)" : "Pause the wallpaper (⌥⌘P)")
            let status = model.status
            HStack(spacing: 5) {
                Circle().fill(status.color).frame(width: 7, height: 7)
                Text(status.text).lineLimit(1)
            }
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize()
            .padding(.trailing, 6)
            .help(status.text)
            .accessibilityIdentifier("status")
        }
        ToolbarItem(placement: .principal) {
            TabSwitcher(model: model)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            switch model.tab {
            case .wallpapers:
                Button { model.addFromYouTube() } label: { Label("YouTube", systemImage: "play.rectangle") }
                    .help("Add a wallpaper from a YouTube link (⌘L)")
                Button { model.startScan() } label: { Label("Find Videos", systemImage: "magnifyingglass") }
                    .help("Find videos on this Mac that could be wallpapers (⇧⌘F)")
                Button { model.addVideos() } label: { Label("Add Video", systemImage: "plus") }
                    .help("Add a video or GIF (⌘O)")
            case .upscale:
                Button { model.studio.choose() } label: { Label("Choose File", systemImage: "plus") }
                    .help("Choose a video, GIF or image to upscale (⌘O)")
                    .disabled(model.studio.isBusy)
            case .memory, .settings:
                EmptyView()
            }
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

// MARK: - Tabs

/// The sections as a compact segmented switcher; a pill glides to the chosen tab.
private struct TabSwitcher: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Wider when the ⌘ hints are shown so labels never crowd.
    private var tabWidth: CGFloat { model.prefs.showShortcutHints ? 132 : 112 }

    var body: some View {
        let tabs = AppModel.Tab.allCases
        let index = CGFloat(tabs.firstIndex(of: model.tab) ?? 0)
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                let selected = tab == model.tab
                Button { model.tab = tab } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(tab.rawValue)
                        if model.prefs.showShortcutHints {
                            Text(shortcut(tab)).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(width: tabWidth, height: 26)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(tab.rawValue) (\(shortcut(tab)))")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .background(alignment: .leading) {
            Capsule()
                .fill(Color(nsColor: .controlColor))
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .frame(width: tabWidth, height: 26)
                .offset(x: index * tabWidth)
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 1), value: model.tab)
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private func shortcut(_ tab: AppModel.Tab) -> String {
        tab == .settings ? "⌘," : "⌘\((AppModel.Tab.allCases.firstIndex(of: tab) ?? 0) + 1)"
    }
}

// MARK: - Wallpapers

private struct WallpapersPane: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let lib = model.library
        let shown = lib.videos(sortedBy: model.prefs.librarySort, matching: model.librarySearch, favoritesOnly: model.showFavoritesOnly)
        VStack(alignment: .leading, spacing: 24) {
            if model.prefs.showPreviews {
                HStack(alignment: .top, spacing: 20) {
                    homeScreen
                    lockScreen
                }
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
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }

            if lib.videos.isEmpty {
                DropZone(isLarge: true, acceptsDrops: true, add: model.addVideos)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 10) {
                        Text("Library").font(.title3.weight(.semibold))
                        Text("\(shown.count == lib.videos.count ? "\(lib.videos.count)" : "\(shown.count) of \(lib.videos.count)")")
                            .foregroundStyle(.secondary).monospacedDigit()
                        InfoButton("Every video you've added, converted for smooth, battery-friendly playback. Click one to make it your home screen; click its lock to use a still of it on the lock screen. Hover for the star (favorites), edit and trash buttons, or right-click for everything.")
                        Spacer()
                        TextField("Search", text: Binding(get: { model.librarySearch }, set: { model.librarySearch = $0 }))
                            .textFieldStyle(.roundedBorder).frame(width: 170)
                        Toggle(isOn: Binding(get: { model.showFavoritesOnly }, set: { model.showFavoritesOnly = $0 })) {
                            Label("Favorites", systemImage: model.showFavoritesOnly ? "star.fill" : "star")
                        }
                        .toggleStyle(.button)
                        .help("Show only starred wallpapers")
                        Picker("Sort", selection: Binding(get: { model.prefs.librarySort }, set: { model.prefs.librarySort = $0 })) {
                            ForEach(LibrarySort.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 160)
                        .help("Sort the library")
                    }
                    if shown.isEmpty {
                        Text(model.showFavoritesOnly && model.librarySearch.isEmpty ? "No favorites yet — hover a wallpaper and click its star." : "No wallpapers match “\(model.librarySearch)”.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: model.prefs.tileSize.minWidth, maximum: model.prefs.tileSize.minWidth * 1.6), spacing: 16)], spacing: 18) {
                        ForEach(shown, id: \.self) { url in
                            WallpaperTile(model: model, url: url)
                        }
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1), value: lib.notices.map(\.id))
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1), value: shown)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: model.current)
    }

    private func name(_ url: URL?) -> String? { url?.deletingPathExtension().lastPathComponent }

    private var homeScreen: some View {
        let url = model.isCurrentBroken ? nil : model.current
        let info = url.flatMap { model.library.infos[$0] }
        return ScreenCaption(title: "Home Screen", detail: name(model.current) ?? "No video — pick one below", symbol: "house.fill",
                             info: "What's behind your desktop icons right now: the wallpaper video, playing live. It pauses when nobody can see it — covered by full-screen apps, the screen asleep or locked, Low Power Mode, or the battery rules in Settings.") {
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
        ScreenCaption(title: "Lock Screen", detail: name(model.lockScreen) ?? "Your own desktop picture", symbol: "lock.fill",
                      info: "macOS doesn't let apps play video on the lock screen, so LiveWallpaper sets a full-quality still from a video (pick the frame in the editor) as your desktop picture, which is what the lock screen shows. Restore Mine puts your own picture back.") {
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
    let info: String
    @ViewBuilder let screen: Screen
    @ViewBuilder let accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            screen
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Label(title, systemImage: symbol).font(.headline)
                    InfoButton(info)
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
