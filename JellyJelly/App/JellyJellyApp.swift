import SwiftUI

@main
struct JellyJellyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel.shared

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
            }
            CommandMenu("Playback") {
                Button("Play/Pause") { app.player?.togglePause() }
                    .disabled(app.player == nil)
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
        }
        return .terminateNow
    }
}
