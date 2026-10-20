import AVFoundation
import Foundation
import os
import UniformTypeIdentifiers

/// Feeds AVPlayer from a disk cache that a single sequential download keeps filled.
///
/// While it renders video, AVPlayer's own buffer for progressive downloads now and then drops a block
/// just ahead of the playhead and requests it again. Served from the network, playback stalls until
/// that block arrives, which takes seconds when the server reads from slow storage such as an rclone mount.
/// Served from this cache, it's there right away.
final class StreamCache: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    struct Statistics {
        var cachedBytes: Int
        var cachedAheadBytes: Int
        var cachedAheadSeconds: Double?
        var downloadedBytes: Int64
        var downloadRate: Double
        var isDownloading: Bool
        var errorCount: Int
        var lastError: String?
    }

    /// AVPlayer only asks the delegate for URLs it can't load itself.
    private static let scheme = "jellyjelly-cache"
    private static let filePrefix = "JellyJelly-stream-"
    private static let log = Logger(subsystem: "media.kitt.JellyJelly", category: "StreamCache")
    /// A running download that reaches a requested byte within this distance is kept instead of restarted.
    private static let reuseDistance = 4 << 20
    /// The most data handed to AVPlayer in one pass, so cancellations aren't held up.
    private static let servePassBytes = 16 << 20
    private static let maxFailures = 6

    let assetURL: URL
    /// All state below is confined to this queue, which also runs the loader and session callbacks.
    let queue = DispatchQueue(label: "media.kitt.JellyJelly.stream-cache")

    private let remoteURL: URL
    private let headers: [String: String]
    private let readAheadSeconds: Double
    private let fileURL: URL
    private var file: FileHandle?
    private var session: URLSession?

    /// Byte offsets present in the cache file.
    private var cached = IndexSet()
    private var contentLength: Int?
    private var contentType: String?
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var task: URLSessionDataTask?
    /// The offset the running download writes next.
    private var taskOffset = 0
    private var playheadByte = 0
    /// Where the read-ahead ends, once the playhead is known.
    private var readAheadEnd: Int?
    /// Bytes per second of media around the playhead.
    private var byteRate: Double?
    private var remainingSeconds: Double?
    private var failures = 0
    private var retryScheduled = false
    private var closed = false

    private var downloadedBytes: Int64 = 0
    private var rateWindowStart = Date()
    private var rateWindowBytes = 0
    private var downloadRate: Double = 0
    private var errorCount = 0
    private var lastError: String?

    init(url: URL, headers: [String: String], readAheadSeconds: Int) {
        remoteURL = url
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = Self.scheme
        assetURL = components?.url ?? url
        self.headers = headers
        self.readAheadSeconds = Double(max(30, readAheadSeconds))
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(Self.filePrefix + UUID().uuidString)
        super.init()
        Self.removeLeftoverFiles()
        if FileManager.default.createFile(atPath: fileURL.path, contents: nil) {
            file = try? FileHandle(forUpdating: fileURL)
        }
        let operations = OperationQueue()
        operations.underlyingQueue = queue
        operations.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: operations)
    }

    /// Cache files of players that didn't close properly, for example after a crash.
    private static func removeLeftoverFiles() {
        let directory = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(filePrefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Stops downloading and deletes the cache file.
    func close() {
        queue.async { [self] in
            closed = true
            task?.cancel()
            task = nil
            session?.invalidateAndCancel()
            session = nil
            pending.forEach { $0.finishLoading(with: URLError(.cancelled)) }
            pending = []
            try? file?.close()
            file = nil
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Lets the cache read ahead of the playhead and drop data far behind it.
    ///
    /// - Parameters:
    ///   - seconds: The playhead.
    ///   - duration: The item's duration.
    ///   - byteOffset: Where the file stores the playhead's samples, if known. Without it, the position
    ///     is estimated from the average bitrate, which is off wherever the bitrate varies.
    ///   - readAheadByteOffset: Where the file stores the samples at the end of the read-ahead, if known.
    func updatePlayhead(_ seconds: Double, duration: Double, byteOffset: Int?, readAheadByteOffset: Int?) {
        queue.async { [self] in
            guard !closed, let contentLength, seconds.isFinite, duration.isFinite, duration > 0 else {
                return
            }
            let averageRate = Double(contentLength) / duration
            playheadByte = min(contentLength, max(0, byteOffset ?? Int(seconds * averageRate)))
            let end = min(contentLength, max(playheadByte, readAheadByteOffset ?? playheadByte + Int(readAheadSeconds * averageRate)))
            readAheadEnd = end
            // Toward the end, less than the full read-ahead is left.
            let span = min(duration, seconds + readAheadSeconds) - seconds
            byteRate = end > playheadByte && span > 1 ? Double(end - playheadByte) / span : averageRate
            remainingSeconds = max(0, duration - seconds)
            trimBehindPlayhead()
            scheduleDownload()
        }
    }

    var statistics: Statistics {
        queue.sync {
            let ahead = (contiguousEnd(from: playheadByte) ?? playheadByte) - playheadByte
            if task == nil || Date().timeIntervalSince(rateWindowStart) > 3 {
                downloadRate = 0
            }
            return Statistics(
                cachedBytes: cached.count,
                cachedAheadBytes: ahead,
                cachedAheadSeconds: byteRate.map { min(Double(ahead) / $0, remainingSeconds ?? .infinity) },
                downloadedBytes: downloadedBytes,
                downloadRate: downloadRate,
                isDownloading: task != nil,
                errorCount: errorCount,
                lastError: lastError
            )
        }
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !closed else {
            return false
        }
        pending.append(loadingRequest)
        serve()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === loadingRequest }
        scheduleDownload()
    }

    // MARK: - Serving

    /// Answers pending requests with whatever the cache holds for them.
    private func serve() {
        guard let file else {
            return
        }
        var budget = Self.servePassBytes
        var finished: [AVAssetResourceLoadingRequest] = []
        for request in pending {
            if let info = request.contentInformationRequest, let contentLength {
                info.contentType = contentType
                info.contentLength = Int64(contentLength)
                info.isByteRangeAccessSupported = true
            }
            guard let dataRequest = request.dataRequest else {
                if contentLength != nil {
                    request.finishLoading()
                    finished.append(request)
                }
                continue
            }
            guard contentLength != nil || request.contentInformationRequest == nil else {
                continue
            }
            let end = requestEnd(dataRequest)
            var offset = Int(dataRequest.currentOffset)
            while budget > 0, let available = contiguousEnd(from: offset) {
                let upTo = min(available, end ?? available, offset + min(budget, 1 << 20))
                guard upTo > offset else {
                    break
                }
                do {
                    try file.seek(toOffset: UInt64(offset))
                    guard let data = try file.read(upToCount: upTo - offset), !data.isEmpty else {
                        break
                    }
                    dataRequest.respond(with: data)
                    budget -= data.count
                    offset += data.count
                } catch {
                    Self.log.error("Reading the cache file failed: \(error.localizedDescription, privacy: .public)")
                    break
                }
            }
            if let end, offset >= end {
                request.finishLoading()
                finished.append(request)
            }
        }
        pending.removeAll { request in finished.contains { $0 === request } }
        if budget <= 0 {
            queue.async { [weak self] in
                self?.serve()
            }
        }
        scheduleDownload()
    }

    /// The exclusive end of a data request, or nil while the file size is unknown.
    private func requestEnd(_ dataRequest: AVAssetResourceLoadingDataRequest) -> Int? {
        if dataRequest.requestsAllDataToEndOfResource {
            return contentLength
        }
        let end = Int(dataRequest.requestedOffset) + dataRequest.requestedLength
        return contentLength.map { min($0, end) } ?? end
    }

    /// The end of the cached run that contains `offset`, or nil if `offset` isn't cached.
    private func contiguousEnd(from offset: Int) -> Int? {
        cached.rangeView.first { $0.contains(offset) }?.upperBound
    }

    // MARK: - Downloading

    /// Points the download at what AVPlayer is waiting for, or else at the read-ahead.
    private func scheduleDownload() {
        guard !closed, !retryScheduled else {
            return
        }
        let target = requestedOffset() ?? readAheadOffset()
        if task != nil {
            if let target, target >= taskOffset, target - taskOffset < Self.reuseDistance {
                return
            }
            if target == nil, keepsReadingAhead() {
                return
            }
            task?.cancel()
            task = nil
        }
        if let target {
            startDownload(at: target)
        }
    }

    /// The first missing byte of the newest request that is waiting for data.
    ///
    /// Newest first, because AVPlayer's older requests are often open-ended reads it no longer needs,
    /// while a new one, such as for the index at the end of the file, blocks playback.
    private func requestedOffset() -> Int? {
        for request in pending.reversed() {
            guard let dataRequest = request.dataRequest else {
                continue
            }
            let offset = Int(dataRequest.currentOffset)
            if let end = requestEnd(dataRequest), offset >= end {
                continue
            }
            if !cached.contains(offset) {
                return offset
            }
        }
        if contentLength == nil, let request = pending.last {
            // The file size only arrives with the first response.
            return Int(request.dataRequest?.currentOffset ?? 0)
        }
        return nil
    }

    /// Where the read-ahead continues, if the cache holds less than the configured time ahead of the playhead.
    private func readAheadOffset() -> Int? {
        guard let readAheadEnd else {
            return nil
        }
        let end = contiguousEnd(from: playheadByte) ?? playheadByte
        return end < readAheadEnd ? end : nil
    }

    /// A download that extends the playhead's cached run continues a quarter past the read-ahead,
    /// so it doesn't restart for every few seconds played.
    private func keepsReadingAhead() -> Bool {
        guard let readAheadEnd, let contentLength else {
            return false
        }
        let end = contiguousEnd(from: playheadByte) ?? playheadByte
        let goal = min(contentLength, readAheadEnd + (readAheadEnd - playheadByte) / 4)
        return taskOffset == end && end < goal
    }

    private func startDownload(at offset: Int) {
        guard let session else {
            return
        }
        var request = URLRequest(url: remoteURL)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // Stop where cached data starts, so nothing is downloaded twice.
        if let next = cached.integerGreaterThan(offset) {
            request.setValue("bytes=\(offset)-\(next - 1)", forHTTPHeaderField: "Range")
        } else {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        self.task = task
        taskOffset = offset
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard dataTask === task, let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let total = (response.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last).flatMap { Int($0) }
        switch response.statusCode {
        case 206 where total != nil:
            contentLength = total
        case 200 where taskOffset == 0:
            contentLength = response.expectedContentLength > 0 ? Int(response.expectedContentLength) : contentLength
        default:
            completionHandler(.cancel)
            downloadFailed("HTTP \(response.statusCode)")
            return
        }
        if contentType == nil {
            contentType = response.mimeType.flatMap { UTType(mimeType: $0)?.identifier } ?? UTType.mpeg4Movie.identifier
        }
        completionHandler(.allow)
        serve()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task, let file else {
            return
        }
        do {
            try file.seek(toOffset: UInt64(taskOffset))
            try file.write(contentsOf: data)
        } catch {
            Self.log.error("Writing the cache file failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        cached.insert(integersIn: taskOffset..<(taskOffset + data.count))
        taskOffset += data.count
        downloadedBytes += Int64(data.count)
        failures = 0
        rateWindowBytes += data.count
        let elapsed = Date().timeIntervalSince(rateWindowStart)
        if elapsed >= 1 {
            downloadRate = Double(rateWindowBytes) / elapsed
            rateWindowStart = Date()
            rateWindowBytes = 0
        }
        serve()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else {
            return
        }
        self.task = nil
        if let error {
            downloadFailed(error.localizedDescription)
        } else {
            scheduleDownload()
        }
    }

    /// Retries with growing delays, and gives up on the waiting requests after several failures in a row.
    private func downloadFailed(_ message: String) {
        task?.cancel()
        task = nil
        failures += 1
        errorCount += 1
        lastError = message
        Self.log.error("Download failed (\(self.failures) in a row): \(message, privacy: .public)")
        guard failures <= Self.maxFailures else {
            pending.forEach { $0.finishLoading(with: URLError(.cannotLoadFromNetwork)) }
            pending = []
            failures = 0
            return
        }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + min(15, pow(2, Double(failures - 1)))) { [weak self] in
            self?.retryScheduled = false
            self?.scheduleDownload()
        }
    }

    // MARK: - Disk use

    /// Frees data well behind the playhead, so watching a whole movie doesn't fill the disk.
    /// Some of it stays for jumping back, and so does the start of the file, which AVPlayer reads again now and then.
    private func trimBehindPlayhead() {
        guard let byteRate, let file else {
            return
        }
        let block = 1 << 20
        let head = 64 << 20
        let keep = max(256 << 20, Int(byteRate * 300))
        let limit = (playheadByte - keep) / block * block
        guard limit > head, let first = cached.integerGreaterThanOrEqualTo(head), first < limit else {
            return
        }
        for range in cached.rangeView where range.upperBound > head && range.lowerBound < limit {
            // Holes have to start and end on file system blocks.
            let start = max(head, (range.lowerBound + block - 1) / block * block)
            let end = min(range.upperBound, limit) / block * block
            guard end > start else {
                continue
            }
            var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(start), fp_length: off_t(end - start))
            if fcntl(file.fileDescriptor, F_PUNCHHOLE, &hole) == 0 {
                cached.remove(integersIn: start..<end)
            }
        }
    }
}
