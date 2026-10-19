import Foundation
import Observation

enum PlayerEnginePreference: String, CaseIterable, Identifiable {
    case automatic
    case mpv
    case avPlayer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .mpv: String(localized: "Always mpv")
        case .avPlayer: String(localized: "Always AVPlayer")
        }
    }
}

enum ResumeBehavior: String, CaseIterable, Identifiable {
    case ask
    case resume
    case startOver

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: String(localized: "Ask every time")
        case .resume: String(localized: "Always resume")
        case .startOver: String(localized: "Always start over")
        }
    }
}

enum FeedOrder: String, CaseIterable, Identifiable {
    case uploadDate
    case dateAdded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uploadDate: String(localized: "Upload date")
        case .dateAdded: String(localized: "Date added to server")
        }
    }

    var sortBy: [String] {
        switch self {
        case .uploadDate: ["PremiereDate", "DateCreated", "SortName"]
        case .dateAdded: ["DateCreated", "SortName"]
        }
    }
}

enum SegmentSkipMode: String, CaseIterable, Identifiable {
    case button
    case automatic
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .button: String(localized: "Show skip button")
        case .automatic: String(localized: "Skip automatically")
        case .off: String(localized: "Off")
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case german = "de"

    var id: String { rawValue }

    /// Language names stay in their own language, so they're recognizable whichever one is active.
    var title: String {
        switch self {
        case .system: String(localized: "System Language (\(Self.systemDefault.title))")
        case .english: "English"
        case .german: "Deutsch"
        }
    }

    /// The language actually shown: the system default for `.system`.
    var resolved: AppLanguage {
        self == .system ? Self.systemDefault : self
    }

    /// The first of the system's preferred languages the app supports, falling back to English like macOS does.
    /// Reads the global domain, because `Locale.preferredLanguages` includes the app's own override.
    static var systemDefault: AppLanguage {
        let preferred = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
            ?? Locale.preferredLanguages
        let supported = Bundle.main.localizations.filter { $0 != "Base" }
        let match = Bundle.preferredLocalizations(from: supported, forPreferences: preferred).first
        return match.flatMap { AppLanguage(rawValue: Locale.Language(identifier: $0).languageCode?.identifier ?? $0) } ?? .english
    }
}

/// User preferences, persisted in `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var theme: ThemeScheme { didSet { defaults.set(theme.rawValue, forKey: "theme") } }

    /// The interface language. Stored as the app's `AppleLanguages`, the same value System Settings writes
    /// for per-app languages, so it takes effect on the next launch.
    var language: AppLanguage {
        didSet {
            if language == .system {
                defaults.removeObject(forKey: "AppleLanguages")
            } else {
                defaults.set([language.rawValue], forKey: "AppleLanguages")
            }
        }
    }
    /// The language the running app was launched with.
    let launchLanguage: AppLanguage
    /// Whether the chosen language differs from the one on screen, which only a relaunch applies.
    var languageNeedsRestart: Bool { language.resolved != launchLanguage.resolved }

    /// Library IDs treated as YouTube channel libraries. Empty means auto-detect by name.
    var youTubeLibraryIds: [String] { didSet { defaults.set(youTubeLibraryIds, forKey: "youTubeLibraryIds") } }
    var feedOrder: FeedOrder { didSet { defaults.set(feedOrder.rawValue, forKey: "feedOrder") } }
    var feedOldestFirst: Bool { didSet { defaults.set(feedOldestFirst, forKey: "feedOldestFirst") } }
    var feedIncludeWatched: Bool { didSet { defaults.set(feedIncludeWatched, forKey: "feedIncludeWatched") } }
    var hideYouTubeFromShelves: Bool { didSet { defaults.set(hideYouTubeFromShelves, forKey: "hideYouTubeFromShelves") } }

    var enginePreference: PlayerEnginePreference { didSet { defaults.set(enginePreference.rawValue, forKey: "enginePreference") } }
    var resumeBehavior: ResumeBehavior { didSet { defaults.set(resumeBehavior.rawValue, forKey: "resumeBehavior") } }
    /// How far ahead the player buffers, in seconds.
    var bufferAheadSeconds: Int { didSet { defaults.set(bufferAheadSeconds, forKey: "bufferAheadSeconds") } }
    /// Upper bound for mpv's in-memory demuxer cache, in MiB.
    var cacheSizeMB: Int { didSet { defaults.set(cacheSizeMB, forKey: "cacheSizeMB") } }
    /// Seconds to buffer before starting and after a stall.
    var prebufferSeconds: Int { didSet { defaults.set(prebufferSeconds, forKey: "prebufferSeconds") } }
    var hardwareDecoding: Bool { didSet { defaults.set(hardwareDecoding, forKey: "hardwareDecoding") } }
    var autoplayNext: Bool { didSet { defaults.set(autoplayNext, forKey: "autoplayNext") } }
    var segmentSkip: SegmentSkipMode { didSet { defaults.set(segmentSkip.rawValue, forKey: "segmentSkip") } }
    var openPlayerFullScreen: Bool { didSet { defaults.set(openPlayerFullScreen, forKey: "openPlayerFullScreen") } }
    /// Moves a playing video into picture in picture while another app is active.
    var autoPictureInPicture: Bool { didSet { defaults.set(autoPictureInPicture, forKey: "autoPictureInPicture") } }
    var showStatsOnStart: Bool { didSet { defaults.set(showStatsOnStart, forKey: "showStatsOnStart") } }
    var preferredAudioLanguage: String { didSet { defaults.set(preferredAudioLanguage, forKey: "preferredAudioLanguage") } }
    var preferredSubtitleLanguage: String { didSet { defaults.set(preferredSubtitleLanguage, forKey: "preferredSubtitleLanguage") } }
    var subtitlesEnabled: Bool { didSet { defaults.set(subtitlesEnabled, forKey: "subtitlesEnabled") } }
    var subtitleScale: Double { didSet { defaults.set(subtitleScale, forKey: "subtitleScale") } }
    var volume: Double { didSet { defaults.set(volume, forKey: "volume") } }
    var sidebarCollapsed: Bool { didSet { defaults.set(sidebarCollapsed, forKey: "sidebarCollapsed") } }

    private init() {
        defaults.register(defaults: [
            "feedIncludeWatched": false,
            "hideYouTubeFromShelves": true,
            "bufferAheadSeconds": 180,
            "cacheSizeMB": 1024,
            "prebufferSeconds": 3,
            "hardwareDecoding": true,
            "autoplayNext": true,
            "openPlayerFullScreen": false,
            "autoPictureInPicture": true,
            "showStatsOnStart": false,
            "subtitlesEnabled": false,
            "subtitleScale": 1.0,
            "volume": 100.0,
            "sidebarCollapsed": false,
        ])
        theme = ThemeScheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .violetSignal
        // Only the app's own domain counts; `defaults.stringArray` would fall back to the system languages.
        let languages = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String]
        let code = languages?.first.flatMap { Locale.Language(identifier: $0).languageCode?.identifier }
        launchLanguage = code.flatMap(AppLanguage.init(rawValue:)) ?? .system
        language = launchLanguage
        youTubeLibraryIds = defaults.stringArray(forKey: "youTubeLibraryIds") ?? []
        feedOrder = FeedOrder(rawValue: defaults.string(forKey: "feedOrder") ?? "") ?? .uploadDate
        feedOldestFirst = defaults.bool(forKey: "feedOldestFirst")
        feedIncludeWatched = defaults.bool(forKey: "feedIncludeWatched")
        hideYouTubeFromShelves = defaults.bool(forKey: "hideYouTubeFromShelves")
        enginePreference = PlayerEnginePreference(rawValue: defaults.string(forKey: "enginePreference") ?? "") ?? .automatic
        resumeBehavior = ResumeBehavior(rawValue: defaults.string(forKey: "resumeBehavior") ?? "") ?? .ask
        bufferAheadSeconds = defaults.integer(forKey: "bufferAheadSeconds")
        cacheSizeMB = defaults.integer(forKey: "cacheSizeMB")
        prebufferSeconds = defaults.integer(forKey: "prebufferSeconds")
        hardwareDecoding = defaults.bool(forKey: "hardwareDecoding")
        autoplayNext = defaults.bool(forKey: "autoplayNext")
        segmentSkip = SegmentSkipMode(rawValue: defaults.string(forKey: "segmentSkip") ?? "") ?? .button
        openPlayerFullScreen = defaults.bool(forKey: "openPlayerFullScreen")
        autoPictureInPicture = defaults.bool(forKey: "autoPictureInPicture")
        showStatsOnStart = defaults.bool(forKey: "showStatsOnStart")
        preferredAudioLanguage = defaults.string(forKey: "preferredAudioLanguage") ?? ""
        preferredSubtitleLanguage = defaults.string(forKey: "preferredSubtitleLanguage") ?? ""
        subtitlesEnabled = defaults.bool(forKey: "subtitlesEnabled")
        subtitleScale = defaults.double(forKey: "subtitleScale")
        volume = defaults.double(forKey: "volume")
        sidebarCollapsed = defaults.bool(forKey: "sidebarCollapsed")
    }
}
