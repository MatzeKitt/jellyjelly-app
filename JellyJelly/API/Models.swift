import Foundation

// MARK: - Items

struct BaseItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String?
    var originalTitle: String?
    var serverId: String?
    var type: String?
    var mediaType: String?
    var collectionType: String?
    var isFolder: Bool?

    var overview: String?
    var taglines: [String]?
    var genres: [String]?
    var tags: [String]?
    var studios: [NameIdPair]?
    var people: [Person]?
    var officialRating: String?
    var communityRating: Double?
    var criticRating: Double?
    var productionYear: Int?
    var premiereDate: Date?
    var dateCreated: Date?
    var endDate: Date?
    var status: String?
    var runTimeTicks: Int64?
    var container: String?
    var path: String?
    var width: Int?
    var height: Int?

    var parentId: String?
    var seriesId: String?
    var seriesName: String?
    var seasonId: String?
    var seasonName: String?
    var indexNumber: Int?
    var parentIndexNumber: Int?
    var childCount: Int?
    var recursiveItemCount: Int?

    var imageTags: [String: String]?
    var backdropImageTags: [String]?
    var parentBackdropItemId: String?
    var parentBackdropImageTags: [String]?
    var parentLogoItemId: String?
    var parentLogoImageTag: String?
    var parentThumbItemId: String?
    var parentThumbImageTag: String?
    var seriesPrimaryImageTag: String?
    var seriesThumbImageTag: String?
    var primaryImageAspectRatio: Double?

    var userData: UserItemData?
    var mediaSources: [MediaSource]?
    var mediaStreams: [MediaStream]?
    var chapters: [Chapter]?
    var trickplay: [String: [String: TrickplayInfo]]?
    var providerIds: [String: String]?

    static func == (lhs: BaseItem, rhs: BaseItem) -> Bool {
        lhs.id == rhs.id && lhs.userData == rhs.userData
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct NameIdPair: Codable, Hashable, Sendable {
    var name: String?
    var id: String?
}

struct Person: Codable, Hashable, Sendable, Identifiable {
    var name: String?
    var id: String
    var role: String?
    var type: String?
    var primaryImageTag: String?
}

struct UserItemData: Codable, Hashable, Sendable {
    var playedPercentage: Double?
    var unplayedItemCount: Int?
    var playbackPositionTicks: Int64?
    var playCount: Int?
    var isFavorite: Bool?
    var lastPlayedDate: Date?
    var played: Bool?
}

struct Chapter: Codable, Hashable, Sendable {
    var startPositionTicks: Int64?
    var name: String?
    var imageTag: String?
}

struct TrickplayInfo: Codable, Hashable, Sendable {
    var width: Int?
    var height: Int?
    var tileWidth: Int?
    var tileHeight: Int?
    var thumbnailCount: Int?
    var interval: Int?
    var bandwidth: Int?
}

// MARK: - Media

struct MediaSource: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String?
    var path: String?
    var container: String?
    var size: Int64?
    var bitrate: Int?
    var runTimeTicks: Int64?
    var supportsDirectPlay: Bool?
    var supportsDirectStream: Bool?
    var supportsTranscoding: Bool?
    var isRemote: Bool?
    var `protocol`: String?
    var mediaStreams: [MediaStream]?
    var defaultAudioStreamIndex: Int?
    var defaultSubtitleStreamIndex: Int?
    var transcodingUrl: String?
}

struct MediaStream: Codable, Hashable, Sendable {
    var type: String?
    var index: Int?
    var codec: String?
    var codecTag: String?
    var profile: String?
    var level: Double?
    var language: String?
    var title: String?
    var displayTitle: String?
    var isDefault: Bool?
    var isForced: Bool?
    var isExternal: Bool?
    var isTextSubtitleStream: Bool?
    var supportsExternalStream: Bool?
    var deliveryMethod: String?
    var deliveryUrl: String?
    var path: String?

    var width: Int?
    var height: Int?
    var bitRate: Int?
    var bitDepth: Int?
    var averageFrameRate: Double?
    var realFrameRate: Double?
    var videoRange: String?
    var videoRangeType: String?
    var videoDoViTitle: String?
    var pixelFormat: String?
    var colorSpace: String?
    var colorTransfer: String?
    var colorPrimaries: String?
    var isInterlaced: Bool?
    var aspectRatio: String?

    var channels: Int?
    var channelLayout: String?
    var sampleRate: Int?
    var audioSpatialFormat: String?
}

struct MediaSegment: Codable, Hashable, Sendable {
    var id: String?
    var type: String?
    var startTicks: Int64?
    var endTicks: Int64?
}

// MARK: - Responses

struct ItemsResponse: Codable, Sendable {
    var items: [BaseItem]
    var totalRecordCount: Int?
    var startIndex: Int?
}

struct SegmentsResponse: Codable, Sendable {
    var items: [MediaSegment]
}

struct PlaybackInfoResponse: Codable, Sendable {
    var mediaSources: [MediaSource]?
    var playSessionId: String?
    var errorCode: String?
}

struct PublicSystemInfo: Codable, Sendable {
    var serverName: String?
    var version: String?
    var id: String?
    var productName: String?
    var startupWizardCompleted: Bool?
}

struct UserDto: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String?
    var serverId: String?
    var primaryImageTag: String?
    var hasPassword: Bool?
    var policy: UserPolicy?
}

struct UserPolicy: Codable, Sendable, Hashable {
    var isAdministrator: Bool?
}

struct AuthenticationResult: Codable, Sendable {
    var user: UserDto?
    var accessToken: String?
    var serverId: String?
    var sessionInfo: SessionInfo?
}

struct QuickConnectResult: Codable, Sendable {
    var authenticated: Bool?
    var secret: String?
    var code: String?
}

struct SessionInfo: Codable, Sendable {
    var id: String?
    var deviceId: String?
    var client: String?
    var playState: PlayerState?
    var transcodingInfo: TranscodingInfo?
    var nowPlayingItem: BaseItem?
}

struct PlayerState: Codable, Sendable {
    var positionTicks: Int64?
    var isPaused: Bool?
    var playMethod: String?
    var mediaSourceId: String?
}

struct TranscodingInfo: Codable, Sendable {
    var audioCodec: String?
    var videoCodec: String?
    var container: String?
    var isVideoDirect: Bool?
    var isAudioDirect: Bool?
    var bitrate: Int?
    var transcodeReasons: [String]?
}

// MARK: - Reporting

struct PlaybackReport: Codable, Sendable {
    var itemId: String
    var mediaSourceId: String?
    var playSessionId: String?
    var positionTicks: Int64?
    var isPaused: Bool?
    var isMuted: Bool?
    var volumeLevel: Int?
    var canSeek: Bool?
    var playMethod: String?
    var audioStreamIndex: Int?
    var subtitleStreamIndex: Int?
    var playbackStartTimeTicks: Int64?
    var failed: Bool?
}

struct UserDataUpdate: Codable, Sendable {
    var playbackPositionTicks: Int64?
    var played: Bool?
    var isFavorite: Bool?
}

// MARK: - Helpers

enum ItemType {
    static let movie = "Movie"
    static let series = "Series"
    static let season = "Season"
    static let episode = "Episode"
    static let video = "Video"
    static let boxSet = "BoxSet"
    static let musicVideo = "MusicVideo"
    static let collectionFolder = "CollectionFolder"
    static let userView = "UserView"
    static let folder = "Folder"
}

extension Int64 {
    /// Jellyfin "ticks" are 100 ns units.
    var tickSeconds: Double { Double(self) / 10_000_000 }
}

extension Double {
    var ticks: Int64 { Int64((self * 10_000_000).rounded()) }
}

extension BaseItem {
    var isEpisode: Bool { type == ItemType.episode }
    var isSeries: Bool { type == ItemType.series }
    var isSeason: Bool { type == ItemType.season }
    var isMovie: Bool { type == ItemType.movie }
    var isPlayable: Bool {
        switch type {
        case ItemType.movie, ItemType.episode, ItemType.video, ItemType.musicVideo: return true
        default: return mediaType == "Video"
        }
    }
    var isContainer: Bool {
        isSeries || isSeason || type == ItemType.boxSet || type == ItemType.collectionFolder
            || type == ItemType.userView || type == ItemType.folder
    }

    var displayName: String { name ?? String(localized: "Untitled") }
    var duration: Double? { runTimeTicks.map { $0.tickSeconds } }
    var resumePosition: Double {
        userData?.playbackPositionTicks.map { $0.tickSeconds } ?? 0
    }
    var isPlayed: Bool { userData?.played ?? false }
    var isFavorite: Bool { userData?.isFavorite ?? false }
    var progress: Double? {
        guard let pct = userData?.playedPercentage, pct > 0, !isPlayed else { return nil }
        return min(max(pct / 100, 0), 1)
    }
    var hasResumePosition: Bool { resumePosition > 5 && !isPlayed }
    var unplayedCount: Int { userData?.unplayedItemCount ?? 0 }

    /// The date a video was uploaded/released, falling back to when it was added.
    var uploadDate: Date? { premiereDate ?? dateCreated }

    var episodeLabel: String? {
        guard isEpisode else { return nil }
        switch (parentIndexNumber, indexNumber) {
        case let (season?, episode?): return String(localized: "S\(season):E\(episode)", comment: "Season and episode number")
        case let (nil, episode?): return String(localized: "E\(episode)", comment: "Episode number")
        default: return nil
        }
    }

    func imageTag(_ type: String) -> String? {
        guard let tags = imageTags else { return nil }
        return tags[type] ?? tags[type.lowercasedFirst]
    }

    var primaryMediaSource: MediaSource? { mediaSources?.first }
    var allStreams: [MediaStream] { primaryMediaSource?.mediaStreams ?? mediaStreams ?? [] }
    var videoStream: MediaStream? { allStreams.first { $0.type == "Video" } }
    var audioStreams: [MediaStream] { allStreams.filter { $0.type == "Audio" } }
    var subtitleStreams: [MediaStream] { allStreams.filter { $0.type == "Subtitle" } }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
    var uppercasedFirst: String { prefix(1).uppercased() + dropFirst() }
}
