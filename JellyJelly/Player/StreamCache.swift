import Foundation
import Network
import os

/// Feeds AVPlayer from a disk cache that a single sequential download keeps filled.
///
/// While it renders video, AVPlayer's own buffer for progressive downloads now and then drops a block
/// just ahead of the playhead and requests it again. Served from the network, playback stalls until
/// that block arrives, which takes seconds when the server reads from slow storage such as an rclone mount.
/// Served from this cache, it's there right away.
///
/// AVPlayer reads the cache over HTTP from a server on the loopback interface. Fed through a resource loader
/// instead, it keeps only a second or two of high-bitrate video in memory and stalls all the time.
final class StreamCache: NSObject, URLSessionDataDelegate, @unchecked Sendable {
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

    /// A byte range from an HTTP `Range` header.
    private enum RequestedRange {
        case all
        case from(Int, through: Int?)
        case suffix(Int)

        /// Anything but a single `bytes=` range, such as several ranges, asks for the whole file.
        init(header: String) {
            guard header.hasPrefix("bytes="), !header.contains(",") else {
                self = .all
                return
            }
            let bounds = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                .map { Int($0.trimmingCharacters(in: .whitespaces)) }
            switch (bounds.first ?? nil, bounds.count == 2 ? bounds[1] : nil) {
            case let (start?, last):
                self = .from(start, through: last)
            case let (nil, count?):
                self = .suffix(count)
            default:
                self = .all
            }
        }
    }

    /// A request from AVPlayer that is being answered.
    private final class Reader {
        let connection: NWConnection
        let range: RequestedRange
        let isHead: Bool
        /// The next byte to send.
        var offset: Int
        /// The exclusive end of the response, once the file size is known.
        var end: Int?
        var isSending = false

        init(connection: NWConnection, range: RequestedRange, isHead: Bool) {
            self.connection = connection
            self.range = range
            self.isHead = isHead
            if case let .from(start, _) = range {
                offset = start
            } else {
                offset = 0
            }
        }

        /// Settles the byte range once the file size is known. False if it lies outside the file.
        func resolve(contentLength: Int) -> Bool {
            switch range {
            case .all:
                offset = 0
                end = contentLength
            case let .from(start, last):
                guard start < contentLength, (last ?? start) >= start else {
                    return false
                }
                end = min(contentLength, (last ?? contentLength - 1) + 1)
            case let .suffix(count):
                guard count > 0 else {
                    return false
                }
                offset = max(0, contentLength - count)
                end = contentLength
            }
            return true
        }
    }

    private static let filePrefix = "JellyJelly-stream-"
    private static let log = Logger(subsystem: "media.kitt.JellyJelly", category: "StreamCache")
    /// A running download that reaches a requested byte within this distance is kept instead of restarted.
    private static let reuseDistance = 16 << 20
    /// How far before the playhead the last keyframe may lie.
    private static let keyframeSeconds: Double = 10
    /// The most data in flight to one request, so memory use stays flat however much AVPlayer asks for.
    private static let sendChunkBytes = 1 << 20
    private static let maxHeaderBytes = 16 << 10
    private static let maxFailures = 6

    /// All state below is confined to this queue, which also runs the server and session callbacks.
    private let queue = DispatchQueue(label: "media.kitt.JellyJelly.stream-cache")

    private let remoteURL: URL
    private let headers: [String: String]
    private let readAheadSeconds: Double
    private let fileURL: URL
    private var file: FileHandle?
    private var session: URLSession?
    private var listener: NWListener?
    /// Only requests for this path are answered, so other processes can't read along.
    private let token = UUID().uuidString

    /// Byte offsets present in the cache file.
    private var cached = IndexSet()
    private var contentLength: Int?
    private var contentType: String?
    private var readers: [Reader] = []
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

    /// Starts the server AVPlayer reads from, and returns its URL, or nil if it can't listen.
    func start() async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let parameters = NWParameters.tcp
                parameters.acceptLocalOnly = true
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                guard !closed, let listener = try? NWListener(using: parameters) else {
                    continuation.resume(returning: nil)
                    return
                }
                self.listener = listener
                var resumed = false
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    let url: URL?
                    switch state {
                    case .ready:
                        url = listener?.port.flatMap { self?.serverURL(port: $0.rawValue) }
                    case let .failed(error):
                        Self.log.error("The cache server stopped: \(error.localizedDescription, privacy: .public)")
                        url = nil
                    case .cancelled:
                        url = nil
                    default:
                        return
                    }
                    if !resumed {
                        resumed = true
                        continuation.resume(returning: url)
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: queue)
            }
        }
    }

    private func serverURL(port: UInt16) -> URL? {
        URL(string: "http://127.0.0.1:\(port)/\(token)/\(remoteURL.lastPathComponent)")
    }

    /// Stops downloading and deletes the cache file.
    func close() {
        queue.async { [self] in
            closed = true
            task?.cancel()
            task = nil
            session?.invalidateAndCancel()
            session = nil
            listener?.cancel()
            listener = nil
            readers.forEach { $0.connection.cancel() }
            readers = []
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

    /// Forgets the playhead until the next update, so the requests for a seek target count.
    /// AVPlayer's time only moves there once their data has arrived.
    func seek() {
        queue.async { [self] in
            readAheadEnd = nil
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

    // MARK: - Server

    private func accept(_ connection: NWConnection) {
        guard !closed else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                if let self, let connection {
                    self.readers.removeAll { $0.connection === connection }
                    self.scheduleDownload()
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    /// Reads the head of the next request on a connection, which AVPlayer keeps open between requests.
    private func receiveRequest(on connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxHeaderBytes) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            var buffer = buffer
            buffer.append(data ?? Data())
            if let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                handleRequest(String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self), on: connection)
            } else if error != nil || isComplete || buffer.count > Self.maxHeaderBytes {
                connection.cancel()
            } else {
                receiveRequest(on: connection, buffer: buffer)
            }
        }
    }

    private func handleRequest(_ head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2, ["GET", "HEAD"].contains(requestLine[0]), requestLine[1].hasPrefix("/\(token)/") else {
            send(head: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", on: connection, closing: true)
            return
        }
        var range = RequestedRange.all
        for line in lines.dropFirst() {
            let field = line.split(separator: ":", maxSplits: 1)
            if field.count == 2, field[0].trimmingCharacters(in: .whitespaces).lowercased() == "range" {
                range = RequestedRange(header: field[1].trimmingCharacters(in: .whitespaces))
            }
        }
        readers.append(Reader(connection: connection, range: range, isHead: requestLine[0] == "HEAD"))
        serve()
    }

    /// Sends AVPlayer whatever the cache holds for its requests, a chunk at a time per request.
    private func serve() {
        guard let file else {
            return
        }
        for reader in readers where !reader.isSending {
            guard let contentLength else {
                continue
            }
            guard let end = reader.end else {
                sendHead(of: reader, contentLength: contentLength)
                continue
            }
            if reader.offset >= end {
                finish(reader)
                continue
            }
            guard let available = contiguousEnd(from: reader.offset) else {
                continue
            }
            let upTo = min(available, end, reader.offset + Self.sendChunkBytes)
            let data: Data
            do {
                try file.seek(toOffset: UInt64(reader.offset))
                guard let read = try file.read(upToCount: upTo - reader.offset), !read.isEmpty else {
                    continue
                }
                data = read
            } catch {
                Self.log.error("Reading the cache file failed: \(error.localizedDescription, privacy: .public)")
                continue
            }
            reader.isSending = true
            reader.connection.send(content: data, completion: .contentProcessed { [weak self, weak reader] error in
                guard let self, let reader, error == nil else {
                    return
                }
                reader.isSending = false
                reader.offset += data.count
                serve()
            })
        }
        scheduleDownload()
    }

    private func sendHead(of reader: Reader, contentLength: Int) {
        guard reader.resolve(contentLength: contentLength), let end = reader.end else {
            readers.removeAll { $0 === reader }
            send(head: "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(contentLength)\r\nContent-Length: 0\r\n\r\n",
                 on: reader.connection)
            return
        }
        var head: String
        if case .all = reader.range {
            head = "HTTP/1.1 200 OK\r\n"
        } else {
            head = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(reader.offset)-\(end - 1)/\(contentLength)\r\n"
        }
        head += "Content-Type: \(contentType ?? "video/mp4")\r\nContent-Length: \(end - reader.offset)\r\nAccept-Ranges: bytes\r\n\r\n"
        if reader.isHead {
            readers.removeAll { $0 === reader }
            send(head: head, on: reader.connection)
            return
        }
        reader.isSending = true
        reader.connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self, weak reader] error in
            guard let self, let reader, error == nil else {
                return
            }
            reader.isSending = false
            serve()
        })
    }

    /// Ends a response and waits for the next request on its connection.
    private func finish(_ reader: Reader) {
        readers.removeAll { $0 === reader }
        receiveRequest(on: reader.connection)
    }

    /// Sends a response without a body, then either waits for the next request or closes the connection.
    private func send(head: String, on connection: NWConnection, closing: Bool = false) {
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            if closing || error != nil {
                connection.cancel()
            } else {
                self?.receiveRequest(on: connection)
            }
        })
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

    /// The first missing byte that a request is waiting for.
    ///
    /// While the file opens, that of the newest request, because AVPlayer's older requests are often
    /// open-ended reads it no longer needs, while a new one, such as for the index at the end of the file,
    /// blocks playback. Once the playhead is known, the earliest one between the playhead and the end of the
    /// read-ahead, which playback needs first. AVPlayer leaves connections open where it stopped reading,
    /// such as at the start of the file, and reads far ahead on others, so requests elsewhere don't count.
    private func requestedOffset() -> Int? {
        let missing = readers.reversed().compactMap { reader -> Int? in
            let offset = contiguousEnd(from: reader.offset) ?? reader.offset
            return reader.end.map { offset < $0 } ?? true ? offset : nil
        }
        if let readAheadEnd {
            // Playback also reads back to the keyframe before the playhead.
            let start = playheadByte - max(Self.reuseDistance, Int((byteRate ?? 0) * Self.keyframeSeconds))
            return missing.filter { $0 >= start && $0 < readAheadEnd }.min()
        }
        if let offset = missing.first {
            return offset
        }
        if contentLength == nil, let reader = readers.last {
            // The file size only arrives with the first response.
            return reader.offset
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
            contentType = response.mimeType ?? "video/mp4"
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
            readers.forEach { $0.connection.cancel() }
            readers = []
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
