import SwiftUI

@main
struct JellyJellyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel.shared
    @State private var updater = Updater.shared

    var body: some Scene {
        Window("JellyJelly", id: "main") {
            RootView()
                .environment(app)
                .environment(\.palette, app.settings.theme.palette)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1480, height: 920)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .sidebar) {
                Button(app.settings.sidebarCollapsed ? "Expand Sidebar" : "Collapse Sidebar") {
                    withAnimation(.spring(response: 0.3)) {
                        app.settings.sidebarCollapsed.toggle()
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                Button("Refresh") {
                    app.refresh()
                }
                .keyboardShortcut("r")
                .disabled(app.phase != .signedIn)
            }
            CommandMenu("Go") {
                Button("Back") { app.goBack() }
                    .keyboardShortcut("[")
                    .disabled(app.path.isEmpty)
                Divider()
                Button("Home") { app.section = .home }
                    .keyboardShortcut("1")
                Button("Subscriptions") { app.section = .subscriptions }
                    .keyboardShortcut("2")
                    .disabled(!app.hasYouTube)
                Button("Search") { app.section = .search }
                    .keyboardShortcut("f")
                Button("Favorites") { app.section = .favorites }
                    .keyboardShortcut("3")
                Button("Downloads") { app.section = .downloads }
                    .keyboardShortcut("4")
                if app.hasMusic {
                    Divider()
                    ForEach(Array(MusicSection.allCases.enumerated()), id: \.element) { offset, section in
                        Button(section.title) { app.section = .music(section) }
                            .keyboardShortcut(KeyEquivalent(Character(String(offset + 5))))
                    }
                }
            }
            CommandMenu("Playback") {
                Button("Play/Pause") {
                    if let player = app.player {
                        player.togglePause()
                    } else {
                        app.music.togglePlayPause()
                    }
                }
                .disabled(app.player == nil && app.music.current == nil)
                Button("Show Stats") { app.player?.toggleStats() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .disabled(app.player == nil)
                Button("Next Video") { app.player?.playNext() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                    .disabled(app.player?.queue.isEmpty ?? true)
                Button(app.player?.isPictureInPicture == true ? "Exit Picture in Picture" : "Enter Picture in Picture") {
                    app.player?.togglePictureInPicture()
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(app.player == nil)
                Button("Stop") { app.player?.close() }
                    .keyboardShortcut(".")
                    .disabled(app.player == nil)
                Divider()
                // ⌘← and ⌘→ come from the music player's key monitor, so they still move the cursor in text fields.
                if app.music.book != nil {
                    Button("Previous Chapter (⌘←)") { app.music.previous() }
                        .disabled(app.player != nil)
                    Button("Next Chapter (⌘→)") { app.music.next() }
                        .disabled(app.player != nil || !app.music.hasNext)
                    Button("Back \(Int(app.settings.audiobookSkipBack)) Seconds (⇧⌘←)") { app.music.skip(by: -app.settings.audiobookSkipBack) }
                        .disabled(app.player != nil)
                    Button("Forward \(Int(app.settings.audiobookSkipForward)) Seconds (⇧⌘→)") { app.music.skip(by: app.settings.audiobookSkipForward) }
                        .disabled(app.player != nil)
                    Picker("Playback Speed", selection: Binding(get: { app.music.rate }, set: { app.music.setRate($0) })) {
                        ForEach(PlaybackSpeed.options, id: \.self) { rate in
                            Text(PlaybackSpeed.label(rate)).tag(rate)
                        }
                    }
                } else {
                    Button("Previous Song (⌘←)") { app.music.previous() }
                        .disabled(app.player != nil || app.music.current == nil)
                    Button("Next Song (⌘→)") { app.music.next() }
                        .disabled(app.player != nil || !app.music.hasNext)
                    Button(app.music.isShuffled ? "Turn Off Shuffle" : "Shuffle") { app.music.toggleShuffle() }
                        .disabled(app.music.current == nil)
                    Menu("Repeat") {
                        Toggle("Off", isOn: repeatBinding(.off))
                        Toggle("All", isOn: repeatBinding(.all))
                        Toggle("One", isOn: repeatBinding(.one))
                    }
                    .disabled(app.music.current == nil)
                }
                Menu("Sleep Timer") {
                    SleepTimerItems(music: app.music)
                }
                .disabled(app.music.current == nil)
                Divider()
                Button(app.showsNowPlaying ? "Hide Now Playing" : "Show Now Playing") { app.showsNowPlaying.toggle() }
                    .keyboardShortcut("p")
                    .disabled(app.music.current == nil)
                Button("Lyrics") {
                    app.nowPlayingPanel = .lyrics
                    app.showsNowPlaying = true
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(app.music.current == nil || app.music.book != nil)
                Button(app.music.book == nil ? "Clear Queue and Stop Music" : "Stop Audiobook") { app.music.stop() }
                    .disabled(app.music.current == nil)
            }
        }

        Settings {
            SettingsView(embedded: false)
                .environment(app)
                .environment(\.palette, app.settings.theme.palette)
                .preferredColorScheme(.dark)
                .frame(width: 640, height: 720)
        }
    }
}

extension JellyJellyApp {
    private func repeatBinding(_ mode: MusicPlayer.RepeatMode) -> Binding<Bool> {
        Binding(
            get: { app.music.repeatMode == mode },
            set: { if $0 { app.music.setRepeatMode(mode) } }
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        MainActor.assumeIsolated {
            DebugHooks.install()
        }
        #endif
        // The mouse "back" button navigates back, like in a browser.
        NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            guard event.buttonNumber == 3 else {
                return event
            }
            MainActor.assumeIsolated {
                if !AppModel.shared.showsFullPlayer {
                    AppModel.shared.goBack()
                }
            }
            return nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Save the resume point before quitting mid-video. This blocks briefly on purpose:
        // async work doesn't run reliably while AppKit waits on `.terminateLater`.
        MainActor.assumeIsolated {
            AppModel.shared.player?.stopForTermination()
            AppModel.shared.music.stopForTermination()
        }
        return .terminateNow
    }

    /// Controls for the music player, or the audiobook, in the Dock icon's menu.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        // Built inside but returned outside the closure, since NSMenu isn't Sendable.
        var menu: NSMenu?
        MainActor.assumeIsolated {
            let music = AppModel.shared.music
            guard let item = music.current, AppModel.shared.player == nil else {
                return
            }
            let dockMenu = NSMenu()
            let heading = music.book.map { [$0.title, $0.author].compactMap { $0 } } ?? [item.displayName, item.artistLine].compactMap { $0 }
            let title = NSMenuItem(title: heading.joined(separator: " – "), action: nil, keyEquivalent: "")
            title.isEnabled = false
            dockMenu.addItem(title)
            dockMenu.addItem(.separator())
            dockMenu.addItem(dockItem(music.isPlaying ? String(localized: "Pause") : String(localized: "Play"), #selector(dockPlayPause)))
            if music.book != nil {
                let settings = AppModel.shared.settings
                dockMenu.addItem(dockItem(String(localized: "Back \(Int(settings.audiobookSkipBack)) Seconds"), #selector(dockSkipBack)))
                dockMenu.addItem(dockItem(String(localized: "Forward \(Int(settings.audiobookSkipForward)) Seconds"), #selector(dockSkipForward)))
                dockMenu.addItem(dockItem(String(localized: "Next Chapter"), #selector(dockNext), enabled: music.hasNext))
                dockMenu.addItem(dockItem(String(localized: "Previous Chapter"), #selector(dockPrevious)))
            } else {
                dockMenu.addItem(dockItem(String(localized: "Next"), #selector(dockNext), enabled: music.hasNext))
                dockMenu.addItem(dockItem(String(localized: "Previous"), #selector(dockPrevious)))
                dockMenu.addItem(.separator())
                dockMenu.addItem(dockItem(item.isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"), #selector(dockFavorite)))
            }
            menu = dockMenu
        }
        return menu
    }

    private func dockItem(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc private func dockPlayPause() {
        MainActor.assumeIsolated { AppModel.shared.music.togglePlayPause() }
    }

    @objc private func dockNext() {
        MainActor.assumeIsolated { AppModel.shared.music.next() }
    }

    @objc private func dockPrevious() {
        MainActor.assumeIsolated { AppModel.shared.music.previous() }
    }

    @objc private func dockSkipBack() {
        MainActor.assumeIsolated { AppModel.shared.music.skip(by: -AppModel.shared.settings.audiobookSkipBack) }
    }

    @objc private func dockSkipForward() {
        MainActor.assumeIsolated { AppModel.shared.music.skip(by: AppModel.shared.settings.audiobookSkipForward) }
    }

    @objc private func dockFavorite() {
        MainActor.assumeIsolated {
            if let item = AppModel.shared.music.current {
                AppModel.shared.toggleFavorite(item)
            }
        }
    }
}
