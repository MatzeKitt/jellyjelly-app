import SwiftUI

struct SettingsView: View {
    /// Embedded in the main window (JellyGoose style) or shown in the Settings window.
    var embedded: Bool

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @State private var confirmingRemoveAll = false

    var body: some View {
        @Bindable var settings = app.settings
        @Bindable var updater = Updater.shared
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if embedded {
                    PageTitle(title: String(localized: "Settings"))
                        .padding(.horizontal, -Metrics.pagePadding)
                }

                SettingsGroup(title: "Appearance", systemImage: "paintpalette.fill") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                        ForEach(ThemeScheme.allCases) { scheme in
                            ThemeSwatch(scheme: scheme, selected: settings.theme == scheme) {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    settings.theme = scheme
                                }
                            }
                        }
                    }
                    Divider().overlay(palette.hairline)
                    SettingsRow("Language", detail: settings.languageNeedsRestart ? "JellyJelly needs to restart to switch the language." : nil) {
                        HStack(spacing: 10) {
                            if settings.languageNeedsRestart {
                                Button("Restart Now", action: relaunch)
                            }
                            Picker("", selection: $settings.language) {
                                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }

                SettingsGroup(title: "YouTube", systemImage: "play.rectangle.fill") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Libraries containing YouTube channels")
                            .font(.system(size: 13, weight: .semibold))
                        Text(settings.youTubeLibraryIds.isEmpty
                             ? "Auto-detected by name (any library with “YouTube” in its name). Pick libraries to override."
                             : "Only the selected libraries are treated as YouTube channels.")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.secondaryText)
                        ForEach(app.libraries.filter { $0.collectionType == "tvshows" || $0.collectionType == nil || $0.collectionType == "homevideos" }) { library in
                            Toggle(library.displayName, isOn: Binding(
                                get: { app.isYouTubeLibrary(library.id) },
                                set: { on in
                                    var ids = settings.youTubeLibraryIds.isEmpty ? app.youTubeLibraries.map(\.id) : settings.youTubeLibraryIds
                                    if on {
                                        ids.append(library.id)
                                    } else {
                                        ids.removeAll { $0 == library.id }
                                    }
                                    settings.youTubeLibraryIds = Array(Set(ids))
                                    app.refresh()
                                }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }
                    Divider().overlay(palette.hairline)
                    SettingsRow("Feed order") {
                        Picker("", selection: $settings.feedOrder) {
                            ForEach(FeedOrder.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    SettingsRow("Show oldest first") {
                        Toggle("", isOn: $settings.feedOldestFirst).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsRow("Include watched videos in the feed") {
                        Toggle("", isOn: $settings.feedIncludeWatched).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsRow("Hide YouTube from Next Up and Recently Added") {
                        Toggle("", isOn: $settings.hideYouTubeFromShelves).labelsHidden().toggleStyle(.switch)
                    }
                }

                SettingsGroup(title: "Playback", systemImage: "play.circle.fill") {
                    SettingsRow("Player engine", detail: engineDetail) {
                        Picker("", selection: $settings.enginePreference) {
                            ForEach(PlayerEnginePreference.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    SettingsRow("When a video was started before") {
                        Picker("", selection: $settings.resumeBehavior) {
                            ForEach(ResumeBehavior.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    SettingsRow("Autoplay next video") {
                        Toggle("", isOn: $settings.autoplayNext).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsRow("Intros, credits, and sponsor segments", detail: "Uses Jellyfin media segments, e.g. from intro-skipper or SponsorBlock plugins.") {
                        Picker("", selection: $settings.segmentSkip) {
                            ForEach(SegmentSkipMode.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    SettingsRow("Open player in full screen") {
                        Toggle("", isOn: $settings.openPlayerFullScreen).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsRow("Picture in picture when switching apps", detail: "A playing video moves into a floating window when you switch to another app and back into the player when you return.") {
                        Toggle("", isOn: $settings.autoPictureInPicture).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsRow("Show stats when playback starts") {
                        Toggle("", isOn: $settings.showStatsOnStart).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsRow("Hardware decoding (mpv)") {
                        Toggle("", isOn: $settings.hardwareDecoding).labelsHidden().toggleStyle(.switch)
                    }
                }

                SettingsGroup(title: "Buffering", systemImage: "arrow.down.circle.fill") {
                    SliderRow(title: "Buffer ahead", value: $settings.bufferAheadSeconds, range: 30...900, step: 30,
                              format: { seconds in
                                  [seconds / 60 > 0 ? String(localized: "\(seconds / 60) min") : nil,
                                   seconds % 60 > 0 ? String(localized: "\(seconds % 60) s") : nil].compactMap { $0 }.joined(separator: " ")
                              },
                              detail: "How far ahead of the playhead the player downloads. More buffer rides out network hiccups.")
                    SliderRow(title: "Memory cache (mpv)", value: $settings.cacheSizeMB, range: 128...4096, step: 128,
                              format: { $0 >= 1024 ? String(localized: "\(Double($0) / 1024, format: .number.precision(.fractionLength(1))) GB") : "\($0) MB" },
                              detail: "Upper limit for buffered data. High-bitrate files need more memory for the same buffer length.")
                    SliderRow(title: "Pre-buffer", value: $settings.prebufferSeconds, range: 1...15, step: 1,
                              format: { "\($0) s" },
                              detail: "Seconds of video to load before starting and after a stall, so playback doesn't stutter.")
                }

                SettingsGroup(title: "Audio & Subtitles", systemImage: "captions.bubble.fill") {
                    SettingsRow("Preferred audio language", detail: "ISO code, e.g. eng or deu. Leave empty for the file's default.") {
                        TextField("eng", text: $settings.preferredAudioLanguage)
                            .frame(width: 90)
                    }
                    SettingsRow("Show subtitles by default") {
                        Toggle("", isOn: $settings.subtitlesEnabled).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsRow("Preferred subtitle language") {
                        TextField("eng", text: $settings.preferredSubtitleLanguage)
                            .frame(width: 90)
                    }
                    SettingsRow("Subtitle size") {
                        Slider(value: $settings.subtitleScale, in: 0.6...2.0, step: 0.1)
                            .frame(width: 180)
                            .tint(palette.accent)
                    }
                }

                SettingsGroup(title: "Downloads", systemImage: "arrow.down.circle.fill") {
                    SettingsRow("Space used", detail: "Downloads keep the original file, so they play exactly like streaming, including subtitles, chapters, and skippable segments.") {
                        Text("\(Format.bytes(Double(app.downloads.usedBytes))) in \(app.downloads.records.count) items")
                            .foregroundStyle(palette.secondaryText)
                    }
                    if let directory = app.downloads.directoryURL {
                        SettingsRow("Location") {
                            Button("Show in Finder") {
                                // The folder only exists while there are downloads.
                                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                                NSWorkspace.shared.activateFileViewerSelecting([directory])
                            }
                        }
                    }
                    if !app.downloads.records.isEmpty {
                        Button("Remove All Downloads…") {
                            confirmingRemoveAll = true
                        }
                        .buttonStyle(AccentButtonStyle(prominent: false))
                        .confirmationDialog("Remove all downloads?", isPresented: $confirmingRemoveAll) {
                            Button("Remove All Downloads", role: .destructive) {
                                app.downloads.removeAll()
                            }
                        } message: {
                            Text("This deletes \(Format.bytes(Double(app.downloads.usedBytes))) and cancels running downloads.")
                        }
                    }
                }

                SettingsGroup(title: "Keyboard", systemImage: "keyboard.fill") {
                    VStack(alignment: .leading, spacing: 6) {
                        ShortcutRow(keys: "Space / K", action: "Play / pause")
                        ShortcutRow(keys: "← / →  (⇧ for 1 min)", action: "Skip 10 seconds")
                        ShortcutRow(keys: "↑ / ↓", action: "Volume")
                        ShortcutRow(keys: "F / double-click", action: "Full screen")
                        ShortcutRow(keys: "P  (⌥⌘P anywhere)", action: "Picture in picture")
                        ShortcutRow(keys: "I", action: "Playback stats")
                        ShortcutRow(keys: "C", action: "Cycle subtitles")
                        ShortcutRow(keys: "[ / ] / =", action: "Slower / faster / normal speed")
                        ShortcutRow(keys: "S or Return", action: "Skip intro or segment")
                        ShortcutRow(keys: "N", action: "Next video")
                        ShortcutRow(keys: "Esc", action: "Leave full screen or picture in picture, then close player")
                        ShortcutRow(keys: "⌘[  or mouse back button", action: "Go back")
                    }
                }

                SettingsGroup(title: "Updates", systemImage: "arrow.triangle.2.circlepath.circle.fill") {
                    SettingsRow("Version") {
                        HStack(spacing: 10) {
                            Text(updater.version)
                                .foregroundStyle(palette.secondaryText)
                            Button("Check Now") { updater.checkForUpdates() }
                                .disabled(!updater.canCheckForUpdates)
                        }
                    }
                    SettingsRow("Check for updates automatically") {
                        Toggle("", isOn: $updater.automaticallyChecksForUpdates).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsRow("Download and install updates automatically", detail: "Updates are installed the next time JellyJelly quits.") {
                        Toggle("", isOn: $updater.automaticallyDownloadsUpdates).labelsHidden().toggleStyle(.switch)
                            .disabled(!updater.automaticallyChecksForUpdates)
                    }
                }

                SettingsGroup(title: "Account", systemImage: "person.crop.circle.fill") {
                    SettingsRow("Server") {
                        Text("\(app.serverName ?? "") · Jellyfin \(app.serverVersion ?? "?")")
                            .foregroundStyle(palette.secondaryText)
                    }
                    SettingsRow("Address") {
                        Text(app.client?.serverURL.absoluteString ?? "")
                            .foregroundStyle(palette.secondaryText)
                            .textSelection(.enabled)
                    }
                    SettingsRow("Signed in as") {
                        Text(app.user?.name ?? "")
                            .foregroundStyle(palette.secondaryText)
                    }
                    SettingsRow("mpv") {
                        Text(LibMPV.shared.map { "Loaded from \($0.path) (API \($0.version))" } ?? "Not installed — run `brew install mpv`")
                            .foregroundStyle(palette.secondaryText)
                            .textSelection(.enabled)
                    }
                    if app.phase == .signedIn {
                        Button("Sign Out") {
                            Task { await app.signOut() }
                        }
                        .buttonStyle(AccentButtonStyle(prominent: false))
                    }
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.bottom, 60)
            .padding(.top, embedded ? 0 : 24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .ignoresSafeArea(edges: embedded ? .top : [])
        .background(embedded ? Color.clear : palette.backgroundBottom)
    }

    private var engineDetail: LocalizedStringKey {
        if MPVEngine.isAvailable {
            return "Automatic uses AVPlayer for MP4/MOV with H.264 or HEVC and mpv for everything else. Both play the original file; the server never transcodes."
        }
        return "mpv is not installed, so only MP4/MOV files with H.264 or HEVC can be played. Install it with `brew install mpv`."
    }

    /// Starts a fresh instance, then quits this one; quitting saves the resume point of a running video.
    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else {
                return
            }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    var title: LocalizedStringKey
    var systemImage: String
    @ViewBuilder var content: () -> Content
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(palette.accent)
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.06)))
        }
    }
}

private struct SettingsRow<Control: View>: View {
    var title: LocalizedStringKey
    var detail: LocalizedStringKey?
    @ViewBuilder var control: () -> Control
    @Environment(\.palette) private var palette

    init(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 20)
            control()
        }
    }
}

private struct SliderRow: View {
    var title: LocalizedStringKey
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int
    var format: (Int) -> String
    var detail: LocalizedStringKey
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(format(value))
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(palette.accent)
            }
            Slider(value: Binding(get: { Double(value) }, set: { value = Int($0) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step))
                .tint(palette.accent)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(palette.tertiaryText)
        }
    }
}

private struct ShortcutRow: View {
    var keys: LocalizedStringKey
    var action: LocalizedStringKey
    @Environment(\.palette) private var palette

    var body: some View {
        HStack {
            Text(keys)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(palette.accent)
                .frame(width: 230, alignment: .leading)
            Text(action)
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryText)
        }
    }
}

private struct ThemeSwatch: View {
    var scheme: ThemeScheme
    var selected: Bool
    var action: () -> Void

    var body: some View {
        let palette = scheme.palette
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    palette.backgroundGradient
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3).fill(palette.sidebar).frame(width: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            Capsule().fill(palette.accent).frame(width: 40, height: 6)
                            HStack(spacing: 4) {
                                ForEach(0..<3) { _ in
                                    RoundedRectangle(cornerRadius: 3).fill(palette.surface).frame(height: 20)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? palette.accent : .white.opacity(0.1), lineWidth: selected ? 2.5 : 1))
                HStack(spacing: 6) {
                    Circle().fill(palette.accent).frame(width: 9, height: 9)
                    Text(scheme.title)
                        .font(.system(size: 12, weight: selected ? .bold : .medium))
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accent)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}
