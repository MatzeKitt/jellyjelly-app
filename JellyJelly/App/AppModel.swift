import AppKit
import Foundation
import Observation

enum SidebarSection: Hashable {
    case home
    case subscriptions
    case search
    case favorites
    case downloads
    case library(String)
    case music(MusicSection)
    /// A library of the type "Books", showing its audiobooks.
    case audiobooks(String)
    case settings
}

enum MusicSection: String, CaseIterable, Hashable {
    case listenNow
    case albums
    case artists
    case songs
    case playlists

    var title: String {
        switch self {
        case .listenNow: String(localized: "Listen Now")
        case .albums: String(localized: "Albums")
        case .artists: String(localized: "Artists")
        case .songs: String(localized: "Songs")
        case .playlists: String(localized: "Playlists")
        }
    }

    var systemImage: String {
        switch self {
        case .listenNow: "play.circle.fill"
        case .albums: "opticaldisc.fill"
        case .artists: "music.mic"
        case .songs: "music.note"
        case .playlists: "music.note.list"
        }
    }
}

/// Which side panel the full Now Playing view shows. Audiobooks show their chapters instead.
enum NowPlayingPanel: Hashable {
    case queue
    case lyrics
    case chapters
}

/// Creating a playlist, optionally with songs in it, or renaming one.
enum PlaylistSheet: Identifiable {
    case create(adding: [BaseItem])
    case edit(BaseItem)

    var id: String {
        switch self {
        case let .create(items): "create:" + items.map(\.id).joined(separator: ",")
        case let .edit(playlist): "edit:" + playlist.id
        }
    }
}

enum Route: Hashable {
    case item(BaseItem)
    case library(BaseItem)
    /// An audiobook, given by one of its files or by the folder of a book made of several files.
    case audiobook(BaseItem)
}

/// A user-data change, broadcast so every list can patch its copy of the item.
struct ItemChange: Equatable {
    var itemId: String
    var userData: UserItemData?
    var sequence: Int
}

struct PlayRequest: Identifiable {
    let id = UUID()
    var item: BaseItem
    var queue: [BaseItem]
}

/// Items of a series, season, or channel waiting for the user to confirm the download.
struct DownloadRequest: Identifiable {
    let id = UUID()
    var container: BaseItem
    var items: [BaseItem]
    /// The files of an audiobook, which only make sense all together.
    var isAudiobook = false

    /// Songs have no watched state, so an album or playlist always downloads in full; so does an audiobook.
    var unwatched: [BaseItem] { container.isMusic || isAudiobook ? items : items.filter { !$0.isPlayed } }

    static func size(of items: [BaseItem]) -> Int64 {
        items.reduce(0) { $0 + ($1.primaryMediaSource?.size ?? 0) }
    }
}

enum StartMode {
    case automatic
    case resume
    case beginning
}

@MainActor
@Observable
final class AppModel {
    enum Phase {
        case launching
        case signedOut
        case signedIn
    }

    static let shared = AppModel()

    let settings = AppSettings.shared
    let downloads = DownloadManager()

    var phase: Phase = .launching
    var client: JellyfinClient?
    var user: UserDto?
    var serverName: String?
    var serverVersion: String?
    var libraries: [BaseItem] = []
    var channels: [BaseItem] = []
    var musicLibraries: [BaseItem] = []
    /// Libraries of the type "Books", which hold audiobooks.
    var audiobookLibraries: [BaseItem] = []
    /// The user's music playlists, for "Add to Playlist" menus.
    var musicPlaylists: [BaseItem] = []

    @ObservationIgnored private(set) lazy var music = MusicPlayer(app: self)
    /// Whether the Now Playing view covers the main window.
    var showsNowPlaying = false
    var nowPlayingPanel = NowPlayingPanel.queue
    var playlistSheet: PlaylistSheet?
    /// Bumped whenever a playlist's contents changed, so open playlist pages reload.
    var playlistGeneration = 0

    var section: SidebarSection = .home {
        didSet {
            if oldValue != section {
                path = []
            }
        }
    }
    var path: [Route] = []

    var player: PlayerModel?
    /// Whether the player covers the main window, as opposed to playing in picture in picture.
    var showsFullPlayer: Bool { player.map { !$0.isPictureInPicture } ?? false }
    var resumePrompt: PlayRequest?
    var downloadRequest: DownloadRequest?
    var lastChange: ItemChange?
    var errorMessage: String?
    /// Bumped whenever content should be reloaded from the server.
    var refreshGeneration = 0

    private var changeSequence = 0

    // MARK: - Session

    func restoreSession() async {
        let defaults = UserDefaults.standard
        guard let server = defaults.string(forKey: "serverURL"),
              let url = URL(string: server),
              let userId = defaults.string(forKey: "userId"),
              let token = Keychain.get("token:\(userId)")
        else {
            phase = .signedOut
            return
        }
        let client = JellyfinClient(serverURL: url, token: token, userId: userId)
        do {
            let user = try await client.currentUser()
            await finishSignIn(client: client, user: user)
        } catch APIError.http(401, _) {
            phase = .signedOut
        } catch {
            // Offline or temporarily unreachable: keep the session and let screens retry.
            self.client = client
            self.user = UserDto(id: userId, name: defaults.string(forKey: "userName"))
            downloads.activate(client: client, userId: userId)
            phase = .signedIn
            if downloads.hasCompleted {
                section = .downloads
                errorMessage = String(localized: "The server can't be reached right now. Your downloads are available offline.")
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func completeSignIn(serverURL: URL, result: AuthenticationResult) async {
        guard let token = result.accessToken, let user = result.user else {
            return
        }
        let defaults = UserDefaults.standard
        defaults.set(serverURL.absoluteString, forKey: "serverURL")
        defaults.set(user.id, forKey: "userId")
        defaults.set(user.name, forKey: "userName")
        Keychain.set(token, for: "token:\(user.id)")
        let client = JellyfinClient(serverURL: serverURL, token: token, userId: user.id)
        await finishSignIn(client: client, user: user)
    }

    private func finishSignIn(client: JellyfinClient, user: UserDto) async {
        self.client = client
        self.user = user
        downloads.activate(client: client, userId: user.id)
        if let info = try? await client.publicSystemInfo() {
            serverName = info.serverName
            serverVersion = info.version
        }
        phase = .signedIn
        await client.reportCapabilities()
        await loadLibraries()
        await music.restore()
    }

    func signOut() async {
        player?.close()
        // The saved queue belongs to this user.
        music.stop()
        // Downloads stay on disk for the next sign-in of the same user.
        downloads.deactivate()
        if let client {
            await client.logout()
        }
        if let userId = user?.id {
            Keychain.remove("token:\(userId)")
        }
        UserDefaults.standard.removeObject(forKey: "userId")
        client = nil
        user = nil
        libraries = []
        channels = []
        musicLibraries = []
        audiobookLibraries = []
        musicPlaylists = []
        section = .home
        path = []
        phase = .signedOut
    }

    var lastServerURL: String {
        UserDefaults.standard.string(forKey: "serverURL") ?? ""
    }

    // MARK: - Libraries

    @ObservationIgnored private var librariesLoad: Task<Void, Never>?

    /// Loads libraries and channels; concurrent callers share one request.
    func loadLibraries() async {
        if let librariesLoad {
            await librariesLoad.value
            return
        }
        let task = Task { await fetchLibraries() }
        librariesLoad = task
        await task.value
        librariesLoad = nil
    }

    private func fetchLibraries() async {
        guard let client else {
            return
        }
        do {
            let views = try await client.userViews()
            // Music has its own sidebar section, and books their own page, instead of a library page.
            let unsupported: Set<String> = ["music", "books", "photos", "livetv", "playlists"]
            libraries = views.filter { !unsupported.contains($0.collectionType ?? "") }
            musicLibraries = views.filter { $0.collectionType == "music" }
            audiobookLibraries = views.filter { $0.collectionType == "books" }
            await loadChannels()
            if hasMusic {
                await loadPlaylists()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Libraries holding YouTube channels: chosen in settings, or detected by name.
    var youTubeLibraries: [BaseItem] {
        let chosen = settings.youTubeLibraryIds
        if !chosen.isEmpty {
            return libraries.filter { chosen.contains($0.id) }
        }
        return libraries.filter { ($0.name ?? "").localizedCaseInsensitiveContains("youtube") }
    }

    var hasYouTube: Bool { !youTubeLibraries.isEmpty }

    func isYouTubeLibrary(_ id: String) -> Bool {
        youTubeLibraries.contains { $0.id == id }
    }

    private var channelIds: Set<String> = []

    func loadChannels() async {
        guard let client else {
            return
        }
        var result: [BaseItem] = []
        for library in youTubeLibraries {
            var query = ItemQuery()
            query.parentId = library.id
            query.includeItemTypes = [ItemType.series]
            query.sortBy = ["DateLastContentAdded", "SortName"]
            query.sortOrder = ["Descending", "Ascending"]
            query.fields = ["Overview", "PrimaryImageAspectRatio", "RecursiveItemCount", "ChildCount"]
            if let response = try? await client.items(query) {
                result += response.items
            }
        }
        channels = result
        channelIds = Set(result.map(\.id))
    }

    /// Whether an item is a YouTube channel or one of its videos.
    func isYouTube(_ item: BaseItem) -> Bool {
        if channelIds.contains(item.id) {
            return true
        }
        if let seriesId = item.seriesId, channelIds.contains(seriesId) {
            return true
        }
        if let parentId = item.parentId, isYouTubeLibrary(parentId) {
            return true
        }
        return false
    }

    func channel(for item: BaseItem) -> BaseItem? {
        guard let seriesId = item.seriesId else {
            return nil
        }
        return channels.first { $0.id == seriesId }
    }

    func refresh() {
        refreshGeneration += 1
        Task {
            await loadChannels()
            if hasMusic {
                await loadPlaylists()
            }
        }
    }

    // MARK: - Navigation

    func open(_ item: BaseItem) {
        showsNowPlaying = false
        if item.type == ItemType.collectionFolder || item.type == ItemType.userView {
            section = .library(item.id)
            return
        }
        if item.isAudiobook {
            openAudiobook(item)
            return
        }
        // A song opens on its album.
        if item.isAudio, let albumId = item.albumId {
            path.append(.item(BaseItem(id: albumId, name: item.album, type: ItemType.musicAlbum)))
            return
        }
        path.append(.item(item))
    }

    func openArtist(_ artist: NameIdPair) {
        guard let id = artist.id else {
            return
        }
        open(BaseItem(id: id, name: artist.name, type: ItemType.musicArtist))
    }

    func goBack() {
        if !path.isEmpty {
            path.removeLast()
        }
    }

    // MARK: - Item actions

    func togglePlayed(_ item: BaseItem) {
        guard let client else {
            return
        }
        let played = !item.isPlayed
        Task {
            do {
                let data = try await client.setPlayed(item.id, played: played)
                broadcast(item.id, data)
                if item.isSeries || item.isSeason {
                    refresh()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func toggleFavorite(_ item: BaseItem) {
        guard let client else {
            return
        }
        let favorite = !item.isFavorite
        Task {
            do {
                let data = try await client.setFavorite(item.id, favorite: favorite)
                broadcast(item.id, data)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func removeFromContinueWatching(_ item: BaseItem) {
        guard let client else {
            return
        }
        Task {
            do {
                try await client.updateUserData(item.id, UserDataUpdate(playbackPositionTicks: 0))
                var data = item.userData ?? UserItemData()
                data.playbackPositionTicks = 0
                data.playedPercentage = 0
                broadcast(item.id, data)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func broadcast(_ itemId: String, _ data: UserItemData?) {
        announce(itemId, data)
        downloads.apply(itemId, data)
    }

    /// Lets lists and the audio player patch their copies, without touching the downloads, e.g. for progress
    /// made offline that the downloads already recorded.
    func announce(_ itemId: String, _ data: UserItemData?) {
        changeSequence += 1
        lastChange = ItemChange(itemId: itemId, userData: data, sequence: changeSequence)
        music.apply(itemId, data)
    }

    // MARK: - Downloads

    /// Downloads a video or song right away; for series, seasons, channels, albums, and playlists, asks first.
    func download(_ item: BaseItem) {
        if item.isAudiobook {
            downloadAudiobook(item)
            return
        }
        if item.isDownloadable {
            downloads.enqueue([item])
            return
        }
        Task {
            await requestDownload(of: item)
        }
    }

    private func requestDownload(of container: BaseItem) async {
        guard let client else {
            return
        }
        if container.isMusic {
            do {
                let songs = try await songs(of: container, withSizes: true).filter { downloads.status(of: $0.id) == nil }
                downloadRequest = DownloadRequest(container: container, items: songs)
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        let youTube = isYouTube(container)
        var query = ItemQuery()
        query.parentId = container.id
        query.includeItemTypes = [ItemType.episode, ItemType.movie, ItemType.video]
        if youTube {
            // Newest uploads download first.
            query.sortBy = settings.feedOrder.sortBy
            query.sortOrder = Array(repeating: "Descending", count: query.sortBy.count)
        } else {
            query.sortBy = ["ParentIndexNumber", "IndexNumber", "SortName"]
            query.sortOrder = ["Ascending", "Ascending", "Ascending"]
        }
        query.fields = JellyfinClient.standardFields + ["MediaSources"]
        query.enableTotalRecordCount = false
        do {
            let items = try await client.items(query).items.filter { downloads.status(of: $0.id) == nil }
            downloadRequest = DownloadRequest(container: container, items: items)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeDownload(_ item: BaseItem) {
        if item.isDownloadable {
            downloads.remove(item.id)
        } else {
            downloads.records(in: item).forEach { downloads.remove($0.id) }
        }
    }

    // MARK: - Playback

    func play(_ item: BaseItem, queue: [BaseItem] = [], mode: StartMode = .automatic) {
        if item.isMusic {
            playMusic(item)
            return
        }
        if item.isAudiobook {
            playAudiobook(item, startOver: mode == .beginning)
            return
        }
        Task {
            await startPlayback(item, queue: queue, mode: mode)
        }
    }

    private func startPlayback(_ item: BaseItem, queue: [BaseItem], mode: StartMode) async {
        guard let client else {
            return
        }
        var target = item
        var queue = queue
        // Containers play their next episode or first unwatched video.
        if item.isSeries || item.isSeason {
            guard let resolved = await firstPlayable(in: item, client: client) else {
                errorMessage = String(localized: "Nothing to play in \(item.displayName).")
                return
            }
            target = resolved.item
            queue = resolved.queue
        }
        let startAt: Double
        switch mode {
        case .beginning:
            startAt = 0
        case .resume:
            startAt = target.resumePosition
        case .automatic:
            if target.hasResumePosition {
                switch settings.resumeBehavior {
                case .ask:
                    resumePrompt = PlayRequest(item: target, queue: queue)
                    return
                case .resume:
                    startAt = target.resumePosition
                case .startOver:
                    startAt = 0
                }
            } else {
                startAt = 0
            }
        }
        if let player {
            player.close()
        }
        music.yieldToVideo()
        let model = PlayerModel(app: self, client: client, item: target, queue: queue, startAt: startAt)
        player = model
        model.start()
    }

    private func firstPlayable(in container: BaseItem, client: JellyfinClient) async -> (item: BaseItem, queue: [BaseItem])? {
        let seriesId = container.isSeries ? container.id : (container.seriesId ?? container.id)
        if container.isSeries, !isYouTube(container),
           let next = try? await client.nextUp(limit: 1, seriesId: container.id).first {
            let episodes = (try? await client.episodes(seriesId: seriesId)) ?? []
            let index = episodes.firstIndex { $0.id == next.id }
            return (next, index.map { Array(episodes[($0 + 1)...]) } ?? [])
        }
        var query = ItemQuery()
        query.parentId = container.id
        query.includeItemTypes = [ItemType.episode, ItemType.movie, ItemType.video]
        if isYouTube(container) {
            // Channels play like a feed: oldest unwatched upload first.
            query.sortBy = settings.feedOrder.sortBy
            query.sortOrder = Array(repeating: "Ascending", count: query.sortBy.count)
        } else {
            query.sortBy = ["ParentIndexNumber", "IndexNumber", "SortName"]
            query.sortOrder = ["Ascending", "Ascending", "Ascending"]
        }
        query.limit = 200
        guard let items = try? await client.items(query).items, !items.isEmpty else {
            return nil
        }
        let start = items.firstIndex { !$0.isPlayed } ?? 0
        return (items[start], Array(items[(start + 1)...]))
    }

    /// Dismisses the player and reloads once the server has the final position, so resume
    /// shelves and the channels' unwatched counts reflect what was just watched.
    func playerDidClose(after reports: Task<Void, Never>?) {
        player = nil
        music.videoDidClose()
        Task {
            await reports?.value
            refresh()
        }
    }
}
