import Foundation
import Observation

/// A downloaded or downloading item, persisted as `download.json` next to its files.
struct DownloadRecord: Codable, Identifiable, Sendable {
    var item: BaseItem
    var mediaSourceId: String?
    var fileName: String?
    var expectedBytes: Int64?
    var fileBytes: Int64?
    var subtitles: [OfflineSubtitle] = []
    var segments: [MediaSegment] = []
    var addedAt: Date
    var completedAt: Date?
    /// Playback progress made offline that the server hasn't received yet.
    var needsSync: Bool?

    var id: String { item.id }
    var isComplete: Bool { completedAt != nil }
    var mediaSource: MediaSource? {
        item.mediaSources?.first { $0.id == mediaSourceId } ?? item.primaryMediaSource
    }
}

struct OfflineSubtitle: Codable, Hashable, Sendable {
    var streamIndex: Int
    var format: String
    var fileName: String
}

enum DownloadStatus: Equatable {
    case queued
    case downloading
    case failed(String)
    case completed
}

struct DownloadProgress: Equatable {
    var received: Int64
    var expected: Int64

    var fraction: Double? {
        expected > 0 ? min(1, Double(received) / Double(expected)) : nil
    }
}

/// A finished download, with everything the player needs to work without the server.
struct OfflineCopy {
    var record: DownloadRecord
    var directory: URL

    var fileURL: URL { directory.appending(path: record.fileName ?? "") }
    var mediaSource: MediaSource? { record.mediaSource }

    func subtitleURL(streamIndex: Int, format: String) -> URL? {
        record.subtitles.first { $0.streamIndex == streamIndex && $0.format == format }
            .map { directory.appending(path: $0.fileName) }
    }
}

enum DownloadError: LocalizedError {
    case noFile
    case notEnoughSpace(needed: Int64, available: Int64)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .noFile:
            return String(localized: "This item has no file to download.")
        case let .notEnoughSpace(needed, available):
            return String(localized: "Not enough disk space: the file needs \(Format.bytes(Double(needed))), but only \(Format.bytes(Double(available))) are free.")
        case .http(403):
            return String(localized: "Your Jellyfin account isn't allowed to download media. An administrator can turn on “Allow media downloading” for your user.")
        case let .http(code):
            return String(localized: "The server answered with error \(code).")
        }
    }
}

/// Downloads original files for offline viewing and keeps track of them on disk.
@MainActor
@Observable
final class DownloadManager {
    static let maxConcurrent = 2

    /// Every known download, finished or not, by item ID.
    private(set) var records: [String: DownloadRecord] = [:]
    private(set) var statuses: [String: DownloadStatus] = [:]
    /// Byte counts of running transfers. Kept apart from `statuses` so only progress views redraw on every tick.
    private(set) var progress: [String: DownloadProgress] = [:]
    private(set) var directoryURL: URL?

    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let delegate: DownloadSessionDelegate
    @ObservationIgnored private var active: Set<String> = []
    @ObservationIgnored private var jobs: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var transfers: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var resumeData: [String: Data] = [:]

    private static let manifestName = "download.json"

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static var baseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "JellyJelly/Downloads", directoryHint: .isDirectory)
    }

    init() {
        let delegate = DownloadSessionDelegate()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        delegate.onProgress = { [weak self] itemId, taskId, received, expected in
            Task { @MainActor in
                self?.transferProgressed(itemId, taskId: taskId, received: received, expected: expected)
            }
        }
        delegate.onComplete = { [weak self] itemId, taskId, outcome in
            Task { @MainActor in
                self?.transferCompleted(itemId, taskId: taskId, outcome: outcome)
            }
        }
    }

    // MARK: - Session

    /// Loads the downloads of a user and resumes unfinished ones.
    func activate(client: JellyfinClient, userId: String) {
        deactivate()
        self.client = client
        // Created on the first download, so a user without downloads leaves no empty folder behind.
        directoryURL = Self.baseDirectory.appending(path: userId, directoryHint: .isDirectory)
        loadRecords()
        removeEmptyFolders()
        pump()
        Task {
            await syncOfflineProgress()
            await refreshUserData()
        }
    }

    /// Stops all transfers. Unfinished downloads stay on disk and continue on the next sign-in.
    func deactivate() {
        jobs.values.forEach { $0.cancel() }
        transfers.values.forEach { $0.cancel() }
        jobs = [:]
        transfers = [:]
        active = []
        resumeData = [:]
        records = [:]
        statuses = [:]
        progress = [:]
        client = nil
        directoryURL = nil
    }

    private func loadRecords() {
        guard let directoryURL,
              let folders = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        else {
            return
        }
        let decoder = JSONDecoder()
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appending(path: Self.manifestName)),
                  var record = try? decoder.decode(DownloadRecord.self, from: data)
            else {
                continue
            }
            if record.isComplete, !FileManager.default.fileExists(atPath: folder.appending(path: record.fileName ?? "").path) {
                // The file was deleted behind our back: download it again.
                record.completedAt = nil
                save(record)
            }
            records[record.id] = record
            statuses[record.id] = record.isComplete ? .completed : .queued
        }
    }

    // MARK: - Queries

    func status(of itemId: String) -> DownloadStatus? {
        statuses[itemId]
    }

    func progress(of itemId: String) -> DownloadProgress? {
        progress[itemId]
    }

    func offlineCopy(of itemId: String) -> OfflineCopy? {
        guard let record = records[itemId], record.isComplete, let directory = directory(for: itemId) else {
            return nil
        }
        return OfflineCopy(record: record, directory: directory)
    }

    /// A saved artwork file (`thumb`, `poster`, or `avatar`), if the download has one.
    func imageURL(for itemId: String, _ name: String) -> URL? {
        guard let url = directory(for: itemId)?.appending(path: "\(name).jpg"),
              FileManager.default.fileExists(atPath: url.path)
        else {
            return nil
        }
        return url
    }

    /// Downloads belonging to a series or season.
    func records(in container: BaseItem) -> [DownloadRecord] {
        records.values.filter { record in
            record.item.seriesId == container.id || record.item.seasonId == container.id || record.item.parentId == container.id
        }
    }

    var hasCompleted: Bool {
        records.values.contains(where: \.isComplete)
    }

    var usedBytes: Int64 {
        records.values.reduce(0) { $0 + ($1.fileBytes ?? 0) }
    }

    /// Free space on the volume that holds the downloads, even before their folder exists.
    var availableBytes: Int64? {
        var url = directoryURL ?? Self.baseDirectory
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        return try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Actions

    func enqueue(_ items: [BaseItem]) {
        guard directoryURL != nil else {
            return
        }
        for item in items where item.isPlayable && records[item.id] == nil {
            let record = DownloadRecord(item: item, addedAt: .now)
            guard let directory = directory(for: item.id),
                  (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
            else {
                continue
            }
            records[item.id] = record
            statuses[item.id] = .queued
            save(record)
        }
        pump()
    }

    func retry(_ itemId: String) {
        guard case .failed = statuses[itemId] else {
            return
        }
        statuses[itemId] = .queued
        pump()
    }

    /// Cancels a running download or deletes a finished one.
    func remove(_ itemId: String) {
        jobs.removeValue(forKey: itemId)?.cancel()
        transfers.removeValue(forKey: itemId)?.cancel()
        active.remove(itemId)
        resumeData[itemId] = nil
        records[itemId] = nil
        statuses[itemId] = nil
        progress[itemId] = nil
        if let directory = directory(for: itemId) {
            try? FileManager.default.removeItem(at: directory)
        }
        removeEmptyFolders()
        pump()
    }

    func removeAll() {
        records.keys.forEach(remove)
    }

    /// Applies a user-data change from the server, e.g. after marking an item as watched.
    func apply(_ itemId: String, _ data: UserItemData?) {
        guard var record = records[itemId], let data else {
            return
        }
        record.item.userData = data
        record.needsSync = nil
        records[itemId] = record
        save(record)
    }

    /// Remembers where offline playback stopped, using the server's watched thresholds.
    func recordPlayback(_ itemId: String, position: Double, duration: Double) {
        guard var record = records[itemId], duration > 0 else {
            return
        }
        var data = record.item.userData ?? UserItemData()
        let fraction = position / duration
        if fraction >= 0.9 {
            data.played = true
            data.playCount = (data.playCount ?? 0) + 1
            data.playbackPositionTicks = 0
            data.playedPercentage = nil
        } else if fraction < 0.05 {
            data.playbackPositionTicks = 0
            data.playedPercentage = nil
        } else {
            data.playbackPositionTicks = position.ticks
            data.playedPercentage = fraction * 100
        }
        data.lastPlayedDate = .now
        record.item.userData = data
        record.needsSync = true
        records[itemId] = record
        save(record)
    }

    /// Called once the server confirmed the stop report, so there is nothing left to sync.
    func markSynced(_ itemId: String) {
        guard var record = records[itemId], record.needsSync == true else {
            return
        }
        record.needsSync = nil
        records[itemId] = record
        save(record)
    }

    // MARK: - Server sync

    private func syncOfflineProgress() async {
        guard let client else {
            return
        }
        for record in records.values where record.needsSync == true {
            let data = record.item.userData
            let update = UserDataUpdate(playbackPositionTicks: data?.playbackPositionTicks ?? 0, played: data?.played == true ? true : nil)
            guard (try? await client.updateUserData(record.id, update)) != nil else {
                // Still offline; try again next time.
                return
            }
            markSynced(record.id)
        }
    }

    /// Picks up watched state and resume points that changed on other devices.
    func refreshUserData() async {
        guard let client else {
            return
        }
        let ids = Array(records.keys)
        for start in stride(from: 0, to: ids.count, by: 100) {
            var query = ItemQuery()
            query.ids = Array(ids[start..<min(start + 100, ids.count)])
            query.fields = ["DateCreated"]
            query.enableTotalRecordCount = false
            guard let items = try? await client.items(query).items else {
                return
            }
            for item in items {
                guard var record = records[item.id], record.needsSync != true, let data = item.userData, data != record.item.userData else {
                    continue
                }
                record.item.userData = data
                records[item.id] = record
                save(record)
            }
        }
    }

    // MARK: - Queue

    private func pump() {
        guard client != nil else {
            return
        }
        let queued = records.values
            .filter { statuses[$0.id] == .queued && !active.contains($0.id) }
            .sorted { $0.addedAt < $1.addedAt }
        for record in queued where active.count < Self.maxConcurrent {
            start(record.id)
        }
    }

    private func start(_ itemId: String) {
        guard let client else {
            return
        }
        active.insert(itemId)
        statuses[itemId] = .downloading
        jobs[itemId] = Task {
            await prepareAndTransfer(itemId, client: client)
        }
    }

    /// Fetches details, subtitles, and artwork, then starts the file transfer.
    private func prepareAndTransfer(_ itemId: String, client: JellyfinClient) async {
        guard var record = records[itemId], let directory = directory(for: itemId) else {
            return
        }
        do {
            if record.mediaSourceId == nil {
                var item = try await client.item(itemId)
                guard let source = item.primaryMediaSource else {
                    throw DownloadError.noFile
                }
                try checkFreeSpace(for: source.size, in: directory)
                item.userData = item.userData ?? record.item.userData
                record.item = item
                record.mediaSourceId = source.id
                record.fileName = "media." + Self.fileExtension(source)
                record.expectedBytes = source.size
                record.segments = (try? await client.mediaSegments(itemId: itemId)) ?? []
                record.subtitles = await downloadSubtitles(item: item, source: source, client: client, into: directory)
                await downloadArtwork(item: item, client: client, into: directory)
                try Task.checkCancellation()
                records[itemId] = record
                save(record)
            }
            try Task.checkCancellation()
            beginTransfer(record, client: client, into: directory)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, records[itemId] != nil else {
                return
            }
            finish(itemId, failure: error.localizedDescription)
        }
    }

    private func beginTransfer(_ record: DownloadRecord, client: JellyfinClient, into directory: URL) {
        let task: URLSessionDownloadTask
        if let data = resumeData.removeValue(forKey: record.id) {
            task = session.downloadTask(withResumeData: data)
        } else {
            var request = URLRequest(url: client.downloadURL(itemId: record.id))
            request.setValue(client.authorizationHeader, forHTTPHeaderField: "Authorization")
            task = session.downloadTask(with: request)
        }
        task.taskDescription = TransferTag(itemId: record.id, destination: directory.appending(path: record.fileName ?? "media")).encoded
        jobs[record.id] = nil
        transfers[record.id] = task
        progress[record.id] = DownloadProgress(received: 0, expected: record.expectedBytes ?? 0)
        task.resume()
    }

    private func transferProgressed(_ itemId: String, taskId: Int, received: Int64, expected: Int64) {
        guard transfers[itemId]?.taskIdentifier == taskId else {
            return
        }
        progress[itemId] = DownloadProgress(received: received, expected: expected > 0 ? expected : records[itemId]?.expectedBytes ?? 0)
    }

    private func transferCompleted(_ itemId: String, taskId: Int, outcome: DownloadSessionDelegate.Outcome) {
        guard let task = transfers[itemId], task.taskIdentifier == taskId else {
            return
        }
        transfers[itemId] = nil
        switch outcome {
        case let .finished(bytes):
            guard var record = records[itemId] else {
                return
            }
            record.completedAt = .now
            record.fileBytes = bytes
            records[itemId] = record
            save(record)
            active.remove(itemId)
            statuses[itemId] = .completed
            progress[itemId] = nil
            pump()
        case let .failed(message, data):
            resumeData[itemId] = data
            finish(itemId, failure: message)
        }
    }

    private func finish(_ itemId: String, failure message: String) {
        jobs[itemId] = nil
        active.remove(itemId)
        statuses[itemId] = .failed(message)
        progress[itemId] = nil
        pump()
    }

    // MARK: - Files

    private func directory(for itemId: String) -> URL? {
        directoryURL?.appending(path: itemId, directoryHint: .isDirectory)
    }

    /// Deletes the user's folder and the downloads folder once nothing but Finder metadata is left in them.
    private func removeEmptyFolders() {
        for folder in [directoryURL, Self.baseDirectory].compactMap(\.self) {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
                continue
            }
            guard contents.allSatisfy({ $0 == ".DS_Store" }) else {
                return
            }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func save(_ record: DownloadRecord) {
        guard let directory = directory(for: record.id), let data = try? Self.encoder.encode(record) else {
            return
        }
        try? data.write(to: directory.appending(path: Self.manifestName), options: .atomic)
    }

    /// AVFoundation picks the demuxer by extension, so keep the original one.
    private static func fileExtension(_ source: MediaSource) -> String {
        let fromPath = ((source.path ?? "") as NSString).pathExtension.lowercased()
        if !fromPath.isEmpty {
            return fromPath
        }
        let container = (source.container ?? "").split(separator: ",").first.map(String.init) ?? ""
        return container.isEmpty ? "mkv" : container.lowercased()
    }

    private func checkFreeSpace(for bytes: Int64?, in directory: URL) throws {
        guard let bytes,
              let available = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        else {
            return
        }
        // Keep some headroom so the disk doesn't fill up completely.
        if bytes + 512 * 1024 * 1024 > available {
            throw DownloadError.notEnoughSpace(needed: bytes, available: available)
        }
    }

    /// Saves text subtitles as WebVTT for the app's renderer, and external files in their own format for mpv.
    private func downloadSubtitles(item: BaseItem, source: MediaSource, client: JellyfinClient, into directory: URL) async -> [OfflineSubtitle] {
        var saved: [OfflineSubtitle] = []
        for stream in source.mediaStreams ?? [] where stream.type == "Subtitle" {
            guard let index = stream.index else {
                continue
            }
            var formats: [String] = []
            if stream.isTextSubtitleStream != false {
                formats.append("vtt")
            }
            if stream.isExternal == true {
                formats.append(PlayerModel.subtitleFormat(stream.codec))
            }
            for format in Set(formats) {
                let url = client.subtitleURL(itemId: item.id, mediaSourceId: source.id, streamIndex: index, format: format)
                var request = URLRequest(url: url)
                request.setValue(client.authorizationHeader, forHTTPHeaderField: "Authorization")
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode ?? 200 < 400
                else {
                    continue
                }
                let fileName = "subtitle-\(index).\(format)"
                if (try? data.write(to: directory.appending(path: fileName))) != nil {
                    saved.append(OfflineSubtitle(streamIndex: index, format: format, fileName: fileName))
                }
            }
        }
        return saved
    }

    private func downloadArtwork(item: BaseItem, client: JellyfinClient, into directory: URL) async {
        let images: [(String, URL?)] = [
            ("thumb", client.thumbURL(item, width: 720)),
            ("poster", client.posterURL(item, width: 400)),
            ("avatar", client.avatarURL(item, width: 120)),
        ]
        for (name, url) in images {
            guard let url,
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400
            else {
                continue
            }
            try? data.write(to: directory.appending(path: "\(name).jpg"))
        }
    }
}

/// Identifies a transfer from inside URLSession callbacks, which can't touch the main actor.
private struct TransferTag {
    var itemId: String
    var destination: URL

    var encoded: String { itemId + "\n" + destination.path }

    init(itemId: String, destination: URL) {
        self.itemId = itemId
        self.destination = destination
    }

    init?(_ description: String?) {
        guard let parts = description?.split(separator: "\n", maxSplits: 1), parts.count == 2 else {
            return nil
        }
        itemId = String(parts[0])
        destination = URL(fileURLWithPath: String(parts[1]))
    }
}

private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Outcome: Sendable {
        case finished(bytes: Int64)
        case failed(String, resumeData: Data?)
    }

    var onProgress: (@Sendable (_ itemId: String, _ taskId: Int, _ received: Int64, _ expected: Int64) -> Void)?
    var onComplete: (@Sendable (_ itemId: String, _ taskId: Int, _ outcome: Outcome) -> Void)?

    private let lock = NSLock()
    private var lastReport: [Int: Date] = [:]
    private var handled: Set<Int> = []

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let tag = TransferTag(downloadTask.taskDescription) else {
            return
        }
        // Report at most four times a second.
        let now = Date()
        lock.lock()
        let due = lastReport[downloadTask.taskIdentifier].map { now.timeIntervalSince($0) >= 0.25 } ?? true
        if due {
            lastReport[downloadTask.taskIdentifier] = now
        }
        lock.unlock()
        if due {
            onProgress?(tag.itemId, downloadTask.taskIdentifier, totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let tag = TransferTag(downloadTask.taskDescription) else {
            return
        }
        lock.lock()
        handled.insert(downloadTask.taskIdentifier)
        lock.unlock()
        // The temporary file is deleted when this method returns, so move it right here.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            onComplete?(tag.itemId, downloadTask.taskIdentifier, .failed(DownloadError.http(status).localizedDescription, resumeData: nil))
            return
        }
        do {
            try? FileManager.default.removeItem(at: tag.destination)
            try FileManager.default.moveItem(at: location, to: tag.destination)
            let size = (try? tag.destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            onComplete?(tag.itemId, downloadTask.taskIdentifier, .finished(bytes: size))
        } catch {
            onComplete?(tag.itemId, downloadTask.taskIdentifier, .failed(error.localizedDescription, resumeData: nil))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let alreadyHandled = handled.remove(task.taskIdentifier) != nil
        lastReport[task.taskIdentifier] = nil
        lock.unlock()
        guard !alreadyHandled, let tag = TransferTag(task.taskDescription) else {
            return
        }
        let resumeData = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        onComplete?(tag.itemId, task.taskIdentifier, .failed(error?.localizedDescription ?? String(localized: "The download failed."), resumeData: resumeData))
    }
}
