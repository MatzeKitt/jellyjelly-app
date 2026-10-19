import AppKit
import Foundation

enum EngineKind: String {
    case avPlayer = "AVPlayer"
    case mpv = "mpv"
}

struct ExternalSubtitle: Hashable {
    var url: URL
    var title: String
    var language: String?
    var isDefault: Bool
}

/// Everything an engine needs to open a file.
struct PlaybackSource {
    var url: URL
    var headers: [String: String]
    var startAt: Double
    var externalSubtitles: [ExternalSubtitle]
    var bufferAheadSeconds: Int
    var cacheSizeMB: Int
    var prebufferSeconds: Int
    var hardwareDecoding: Bool
    var preferredAudioLanguage: String
    var preferredSubtitleLanguage: String
    var subtitlesEnabled: Bool
    var volume: Double
}

struct TrackOption: Identifiable, Hashable {
    var id: String
    var title: String
    var detail: String?
    var isSelected: Bool
}

struct StatRow: Identifiable, Hashable {
    var id: String { label }
    var label: String
    var value: String
    var highlight: Highlight = .none

    enum Highlight: Hashable {
        case none
        case good
        case warning
    }
}

struct StatSection: Identifiable, Hashable {
    var id: String { title }
    var title: String
    var rows: [StatRow]
}

enum EngineEvent {
    case loaded(duration: Double?)
    case time(Double)
    case duration(Double)
    case paused(Bool)
    /// `progress` is 0...1 while refilling the buffer, when the engine knows it.
    case buffering(Bool, progress: Double?)
    /// Seconds of media buffered ahead of the playhead.
    case bufferedAhead(Double)
    case tracksChanged
    case ended
    case failed(String)
}

@MainActor
protocol PlaybackEngine: AnyObject {
    var kind: EngineKind { get }
    var videoView: NSView { get }
    var onEvent: ((EngineEvent) -> Void)? { get set }

    func load(_ source: PlaybackSource)
    func play()
    func pause()
    func seek(to seconds: Double)
    func setRate(_ rate: Double)
    func setVolume(_ volume: Double)
    func setMuted(_ muted: Bool)

    var audioTracks: [TrackOption] { get }
    /// Subtitle tracks rendered by the engine itself. Empty if the app renders subtitles.
    var subtitleTracks: [TrackOption] { get }
    var rendersSubtitles: Bool { get }
    func selectAudioTrack(_ id: String)
    func selectSubtitleTrack(_ id: String?)
    func setSubtitleScale(_ scale: Double)

    /// Engine-specific diagnostics for the stats overlay.
    func collectStats() -> [StatSection]
    func stop()
}

enum Format {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else {
            return "--:--"
        }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 60 {
            let hours = minutes / 60
            let rest = minutes % 60
            return rest == 0 ? String(localized: "\(hours)h") : String(localized: "\(hours)h \(rest)m")
        }
        return String(localized: "\(max(minutes, 1))m")
    }

    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }

    static func bitrate(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000 {
            return String(localized: "\(bitsPerSecond / 1_000_000, format: .number.precision(.fractionLength(1))) Mbps")
        }
        return String(localized: "\(bitsPerSecond / 1000, format: .number.precision(.fractionLength(0))) kbps")
    }

    static func relativeDay(_ date: Date?) -> String? {
        guard let date else {
            return nil
        }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: .now)).day ?? 0
        switch days {
        case ..<0: return date.formatted(date: .abbreviated, time: .omitted)
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Yesterday")
        case 2..<7: return String(localized: "\(days) days ago")
        case 7..<31: return String(localized: "\(days / 7) weeks ago")
        case 31..<61: return String(localized: "\(1) months ago")
        case 61..<365: return String(localized: "\(days / 30) months ago")
        default: return String(localized: "\(days / 365) years ago")
        }
    }
}
