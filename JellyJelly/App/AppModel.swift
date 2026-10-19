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
    case settings
}

enum Route: Hashable {
    case item(BaseItem)
    case library(BaseItem)
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

    var unwatched: [BaseItem] { items.filter { !$0.isPlayed } }

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
    }

    func signOut() async {
        player?.close()
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
            let unsupported: Set<String> = ["music", "books", "photos", "livetv", "playlists"]
            libraries = views.filter { !unsupported.contains($0.collectionType ?? "") }
            await loadChannels()
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
        }
    }

    // MARK: - Navigation

    func open(_ item: BaseItem) {
        if item.type == ItemType.collectionFolder || item.type == ItemType.userView {
            section = .library(item.id)
            return
        }
        path.append(.item(item))
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
        changeSequence += 1
        lastChange = ItemChange(itemId: itemId, userData: data, sequence: changeSequence)
        downloads.apply(itemId, data)
    }

    // MARK: - Downloads

    /// Downloads a playable item right away; for series, seasons, and channels, asks first.
    func download(_ item: BaseItem) {
        if item.isPlayable {
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
        if item.isPlayable {
            downloads.remove(item.id)
        } else {
            downloads.records(in: item).forEach { downloads.remove($0.id) }
        }
    }

    // MARK: - Playback

    func play(_ item: BaseItem, queue: [BaseItem] = [], mode: StartMode = .automatic) {
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
        Task {
            await reports?.value
            refresh()
        }
    }
}
