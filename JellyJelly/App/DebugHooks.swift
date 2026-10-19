#if DEBUG
import AppKit
import SwiftUI

/// Debug-only remote control for automated UI checks.
///
/// Post a distributed notification named `media.kitt.JellyJelly.debug` whose object is a
/// command string, e.g. `snapshot /tmp/shot.png`, `section subscriptions`, `open <itemId>`,
/// `play <itemId>`, `player pause|resume|stats|next|close|pip|seek <seconds>`, `download <itemId>`,
/// `remove-download <itemId>`, `state /tmp/state.json`.
@MainActor
enum DebugHooks {
    static func install() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("media.kitt.JellyJelly.debug"), object: nil, queue: .main) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated {
                run(command)
            }
        }
    }

    private static func run(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = parts.first else {
            return
        }
        let argument = parts.count > 1 ? parts[1] : ""
        let app = AppModel.shared
        switch verb {
        case "snapshot":
            snapshot(to: argument)
        case "section":
            switch argument {
            case "home": app.section = .home
            case "subscriptions": app.section = .subscriptions
            case "search": app.section = .search
            case "favorites": app.section = .favorites
            case "downloads": app.section = .downloads
            case "settings": app.section = .settings
            default:
                if argument.hasPrefix("library:") {
                    app.section = .library(String(argument.dropFirst(8)))
                }
            }
        case "theme":
            if let theme = ThemeScheme(rawValue: argument) {
                app.settings.theme = theme
            }
        case "open":
            Task {
                if let item = try? await app.client?.item(argument) {
                    app.open(item)
                }
            }
        case "back":
            app.goBack()
        case "play":
            // `play <itemId> [queueId,queueId,…]`
            let ids = argument.split(separator: " ").map(String.init)
            Task {
                guard let id = ids.first,
                      let item = (try? await app.client?.item(id)) ?? app.downloads.offlineCopy(of: id)?.record.item
                else {
                    return
                }
                var queue: [BaseItem] = []
                for next in ids.dropFirst().first?.split(separator: ",") ?? [] {
                    if let queued = try? await app.client?.item(String(next)) {
                        queue.append(queued)
                    }
                }
                app.play(item, queue: queue)
            }
        case "download":
            Task {
                if let item = try? await app.client?.item(argument) {
                    app.download(item)
                }
            }
        case "remove-download":
            app.downloads.remove(argument)
        case "resume-prompt":
            if let request = app.resumePrompt {
                app.resumePrompt = nil
                app.play(request.item, queue: request.queue, mode: argument == "beginning" ? .beginning : .resume)
            }
        case "player":
            guard let player = app.player else {
                return
            }
            let sub = argument.split(separator: " ").map(String.init)
            switch sub.first {
            case "pause", "resume": player.togglePause()
            case "stats": player.toggleStats()
            case "next": player.playNext()
            case "close": player.close()
            case "seek": player.seek(to: Double(sub.last ?? "0") ?? 0)
            case "subtitle": player.selectSubtitle(sub.count > 1 ? sub[1] : nil)
            case "show": player.userActivity()
            case "pip": player.togglePictureInPicture()
            default: break
            }
        case "state":
            writeState(to: argument)
        case "quit":
            NSApp.terminate(nil)
        default:
            break
        }
    }

    private static func snapshot(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView,
              let layer = view.layer
        else {
            return
        }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return
        }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private static func writeState(to path: String) {
        let app = AppModel.shared
        var state: [String: Any] = [
            "phase": "\(app.phase)",
            "section": "\(app.section)",
            "path": app.path.count,
            "libraries": app.libraries.map(\.displayName),
            "channels": app.channels.map(\.displayName),
            "resumePrompt": app.resumePrompt?.item.id as Any,
            "error": app.errorMessage as Any,
            "downloads": app.downloads.records.values.map { record in
                [
                    "id": record.id,
                    "status": "\(app.downloads.status(of: record.id).map { "\($0)" } ?? "none")",
                    "received": app.downloads.progress(of: record.id)?.received as Any,
                    "bytes": record.fileBytes as Any,
                    "subtitles": record.subtitles.map(\.fileName),
                    "needsSync": record.needsSync as Any,
                ]
            },
        ]
        if let player = app.player {
            player.refreshStats()
            state["player"] = [
                "item": player.item.id,
                "phase": "\(player.phase)",
                "engine": player.engineKind?.rawValue as Any,
                "reason": player.engineReason,
                "position": player.position,
                "duration": player.duration,
                "paused": player.isPaused,
                "pictureInPicture": player.isPictureInPicture,
                "buffering": player.isBuffering,
                "bufferedAhead": player.bufferedAhead,
                "subtitleText": player.subtitleText as Any,
                "audio": player.audioOptions.map { "\($0.id):\($0.title):\($0.isSelected)" },
                "subtitles": player.subtitleOptions.map { "\($0.id):\($0.title):\($0.isSelected)" },
                "activeSegment": player.activeSegment?.type as Any,
                "upNext": player.upNext?.id as Any,
                "queue": player.queue.map(\.id),
                "chapters": player.chapters.count,
                "stats": player.statsSections.map { section in
                    [section.title: section.rows.map { "\($0.label)=\($0.value)" }]
                },
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif
