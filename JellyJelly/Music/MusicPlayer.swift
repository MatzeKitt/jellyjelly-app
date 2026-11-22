import AVFoundation
import AppKit
import MediaPlayer
import Observation

/// Plays songs from a queue. The next song is loaded into the player ahead of time, so it starts without a gap.
@MainActor
@Observable
final class MusicPlayer {
    struct Entry: Identifiable, Hashable {
        /// Its own ID, since the same song can be queued more than once.
        let id = UUID()
        var item: BaseItem
    }

    enum RepeatMode: String {
        case off
        case all
        case one
    }

    enum LyricsState: Equatable {
        case none
        case loading
        case loaded([LyricLine])
    }

    /// How the current song reaches the player, for the line under the controls.
    struct StreamInfo: Equatable {
        var isTranscoded: Bool
        var isDownloaded = false
        var codec: String?
        var sourceCodec: String?
        var bitrate: Int?
        var sampleRate: Int?
        var bitDepth: Int?

        var summary: String {
            var parts = [MediaDescription.codecName(codec)]
            if let bitDepth, !isTranscoded {
                parts.append("\(bitDepth)-bit")
            }
            if let sampleRate, !isTranscoded {
                parts.append("\((Double(sampleRate) / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz")
            }
            if let bitrate, isTranscoded || bitDepth == nil {
                parts.append(Format.bitrate(Double(bitrate)))
            }
            if isTranscoded {
                parts.append(String(localized: "transcoded from \(MediaDescription.codecName(sourceCodec))"))
            } else if isDownloaded {
                parts.append(String(localized: "Downloaded"))
            } else {
                parts.append(String(localized: "Direct Play"))
            }
            return parts.joined(separator: " · ")
        }
    }

    private struct ResolvedTrack {
        var entryId: UUID
        var itemId: String
        var url: URL
        var mediaSourceId: String?
        var playSessionId: String?
        var stream: StreamInfo
    }

    private enum ReportKind {
        case start
        case progress
        case stopped
    }

    // MARK: Queue

    private(set) var entries: [Entry] = []
    private(set) var index = 0
    private(set) var isShuffled = false
    private(set) var repeatMode = RepeatMode.off

    // MARK: Playback state

    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    /// Whether the user wants music to play, even while it's still loading or buffering.
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var stream: StreamInfo?
    private(set) var lyrics = LyricsState.none
    var volume: Double {
        didSet {
            player.volume = Float(volume / 100)
            app.settings.musicVolume = volume
        }
    }

    var current: BaseItem? { entries.indices.contains(index) ? entries[index].item : nil }
    var currentEntry: Entry? { entries.indices.contains(index) ? entries[index] : nil }
    var history: [Entry] { Array(entries.prefix(index)) }
    var upcoming: [Entry] { index + 1 < entries.count ? Array(entries[(index + 1)...]) : [] }
    var hasNext: Bool { nextIndex != nil }

    private var nextIndex: Int? {
        if index + 1 < entries.count {
            return index + 1
        }
        return repeatMode == .all && !entries.isEmpty ? 0 : nil
    }

    private var previousIndex: Int? {
        if index > 0 {
            return index - 1
        }
        return repeatMode == .all && !entries.isEmpty ? entries.count - 1 : nil
    }

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private let player = AVQueuePlayer()
    /// The queue in the order it was started in, to return to when shuffle is turned off.
    @ObservationIgnored private var unshuffled: [Entry]?
    @ObservationIgnored private var currentTrack: ResolvedTrack?
    @ObservationIgnored private var currentItem: AVPlayerItem?
    @ObservationIgnored private var currentObservation: NSKeyValueObservation?
    @ObservationIgnored private var prepared: (track: ResolvedTrack, item: AVPlayerItem)?
    @ObservationIgnored private var preparedObservation: NSKeyValueObservation?
    @ObservationIgnored private var preparingEntryId: UUID?
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    /// Bumped whenever another song becomes current, so late results for the previous one are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var hasReportedStart = false
    @ObservationIgnored private var lastReportedPosition: Double = -1
    @ObservationIgnored private var reportChain: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var playerObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var remoteTargets: [(command: MPRemoteCommand, target: Any)] = []
    @ObservationIgnored private var artwork: (itemId: String, artwork: MPMediaItemArtwork)?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
        volume = app.settings.musicVolume
        player.volume = Float(volume / 100)
        observePlayer()
        installKeyMonitor()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                self?.tick()
            }
        }
    }

    // MARK: - Starting playback

    /// Replaces the queue and plays it.
    ///
    /// - Parameters:
    ///   - start: The song to start with; `nil` starts at the top, or anywhere when shuffling.
    ///   - shuffle: Whether to shuffle the songs; `nil` keeps the current shuffle mode.
    func play(_ items: [BaseItem], startingAt start: Int? = nil, shuffle: Bool? = nil) {
        let songs = items.filter(\.isAudio)
        guard !songs.isEmpty else {
            return
        }
        var list = songs.map { Entry(item: $0) }
        var startIndex = min(max(start ?? 0, 0), list.count - 1)
        let shuffling = shuffle ?? isShuffled
        unshuffled = nil
        if shuffling {
            unshuffled = list
            // A song picked from a list stays first; the rest plays in random order.
            let first = start == nil ? [] : [list.remove(at: startIndex)]
            list = first + list.shuffled()
            startIndex = 0
        }
        isShuffled = shuffling
        entries = list
        failures = 0
        load(at: startIndex, autoplay: true)
    }

    /// Queues songs right after the current one.
    func playNext(_ items: [BaseItem]) {
        let songs = items.filter(\.isAudio).map { Entry(item: $0) }
        guard !songs.isEmpty else {
            return
        }
        guard current != nil else {
            play(songs.map(\.item), shuffle: false)
            return
        }
        entries.insert(contentsOf: songs, at: index + 1)
        if let currentId = currentEntry?.id, let position = unshuffled?.firstIndex(where: { $0.id == currentId }) {
            unshuffled?.insert(contentsOf: songs, at: position + 1)
        }
        queueChanged()
    }

    /// Queues songs at the end.
    func addToQueue(_ items: [BaseItem]) {
        let songs = items.filter(\.isAudio).map { Entry(item: $0) }
        guard !songs.isEmpty else {
            return
        }
        guard current != nil else {
            play(songs.map(\.item), shuffle: false)
            return
        }
        entries += songs
        unshuffled? += songs
        queueChanged()
    }

    // MARK: - Controls

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard current != nil else {
            return
        }
        // Music and video don't play at the same time.
        app.player?.close()
        claimSystemControls()
        isPlaying = true
        if currentItem == nil {
            // Restored from the last session, or the queue ended: the song needs loading first.
            if loadTask == nil {
                load(at: index, startAt: position, autoplay: true)
            }
            return
        }
        player.play()
        if hasReportedStart {
            report(.progress)
        } else {
            reportStart()
        }
        updateNowPlaying()
    }

    func pause() {
        isPlaying = false
        player.pause()
        report(.progress)
        updateNowPlaying()
        saveQueue()
    }

    func next() {
        guard let next = nextIndex else {
            return
        }
        load(at: next, autoplay: isPlaying || currentItem == nil)
    }

    /// Restarts the song after its first seconds, like a CD player; otherwise goes back a song.
    func previous() {
        guard position < 3, let previous = previousIndex else {
            seek(to: 0)
            return
        }
        load(at: previous, autoplay: isPlaying || currentItem == nil)
    }

    func seek(to seconds: Double) {
        let target = min(max(0, seconds), max(0, duration - 0.5))
        position = target
        guard let currentItem else {
            // Applied when the song loads.
            return
        }
        if currentItem.status != .readyToPlay {
            pendingSeek = target
            return
        }
        isSeeking = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.isSeeking = false }
        }
        report(.progress)
        updateNowPlaying()
    }

    func adjustVolume(by delta: Double) {
        volume = min(100, max(0, volume + delta))
    }

    func jump(to entry: Entry) {
        guard let target = entries.firstIndex(where: { $0.id == entry.id }) else {
            return
        }
        load(at: target, autoplay: true)
    }

    func toggleShuffle() {
        if isShuffled {
            // Back to the original order, continuing after the current song.
            if let unshuffled, let currentId = currentEntry?.id, let position = unshuffled.firstIndex(where: { $0.id == currentId }) {
                entries = unshuffled
                index = position
            }
            unshuffled = nil
            isShuffled = false
        } else {
            unshuffled = entries
            if let currentEntry {
                entries = history + [currentEntry] + upcoming.shuffled()
            }
            isShuffled = true
        }
        queueChanged()
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: setRepeatMode(.all)
        case .all: setRepeatMode(.one)
        case .one: setRepeatMode(.off)
        }
    }

    func setRepeatMode(_ mode: RepeatMode) {
        applyRepeatMode(mode)
        if !entries.isEmpty {
            queueChanged()
        }
    }

    private func applyRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode
        // Repeating a song keeps it in the player at its end, to start over.
        player.actionAtItemEnd = mode == .one ? .none : .advance
    }

    // MARK: - Editing the queue

    func remove(_ entry: Entry) {
        guard entry.id != currentEntry?.id, let position = entries.firstIndex(where: { $0.id == entry.id }) else {
            return
        }
        entries.remove(at: position)
        if position < index {
            index -= 1
        }
        unshuffled?.removeAll { $0.id == entry.id }
        queueChanged()
    }

    /// Moves songs within the upcoming part of the queue; offsets count from the first upcoming song.
    func moveUpcoming(fromOffsets source: IndexSet, toOffset destination: Int) {
        var list = upcoming
        list.move(fromOffsets: source, toOffset: destination)
        entries = Array(entries.prefix(index + 1)) + list
        queueChanged()
    }

    /// Moves a queued song right after the current one.
    func moveToNext(_ entry: Entry) {
        guard let position = entries.firstIndex(where: { $0.id == entry.id }), position > index else {
            return
        }
        entries.remove(at: position)
        entries.insert(entry, at: index + 1)
        queueChanged()
    }

    /// Removes the upcoming songs, keeping the current one and the history.
    func clearUpcoming() {
        let removed = Set(upcoming.map(\.id))
        entries.removeAll { removed.contains($0.id) }
        unshuffled?.removeAll { removed.contains($0.id) }
        queueChanged()
    }

    /// Stops playback and empties the queue.
    func stop() {
        loadTask?.cancel()
        loadTask = nil
        finishReport()
        generation += 1
        clearPrepared()
        player.removeAllItems()
        currentItem = nil
        currentObservation = nil
        currentTrack = nil
        entries = []
        unshuffled = nil
        index = 0
        position = 0
        duration = 0
        isPlaying = false
        isBuffering = false
        stream = nil
        lyrics = .none
        releaseSystemControls()
        app.showsNowPlaying = false
        saveQueue()
    }

    /// Patches a user-data change into the queued songs, e.g. a favorite toggled elsewhere.
    func apply(_ itemId: String, _ data: UserItemData?) {
        guard let data else {
            return
        }
        for position in entries.indices where entries[position].item.id == itemId {
            entries[position].item.userData = data
        }
    }

    private func queueChanged() {
        if entries.isEmpty {
            stop()
            return
        }
        prepareNext()
        saveQueue()
    }

    // MARK: - Loading

    /// Makes another song current and starts streaming it.
    private func load(at target: Int, startAt: Double = 0, autoplay: Bool, forceTranscoding: Bool = false) {
        guard entries.indices.contains(target) else {
            return
        }
        if autoplay {
            app.player?.close()
            claimSystemControls()
        }
        finishReport()
        generation += 1
        let generation = generation
        let entry = entries[target]
        index = target
        position = startAt
        duration = entry.item.duration ?? 0
        isPlaying = autoplay
        isBuffering = autoplay
        stream = nil
        pendingSeek = nil
        currentTrack = nil
        currentItem = nil
        currentObservation = nil
        clearPrepared()
        player.removeAllItems()
        loadLyrics(for: entry.item)
        updateNowPlaying()
        saveQueue()
        loadTask?.cancel()
        loadTask = Task {
            defer {
                if generation == self.generation {
                    loadTask = nil
                }
            }
            do {
                let track = try await resolve(entry, forceTranscoding: forceTranscoding)
                guard generation == self.generation else {
                    return
                }
                start(track, at: startAt)
            } catch {
                guard generation == self.generation, !Task.isCancelled else {
                    return
                }
                failed(entry, message: error.localizedDescription)
            }
        }
    }

    /// Asks the server for a stream of the song: the original file or AAC, depending on the file and the quality setting.
    private func resolve(_ entry: Entry, forceTranscoding: Bool = false) async throws -> ResolvedTrack {
        // A downloaded song plays from disk, without asking the server, so it also works offline.
        if !forceTranscoding, let copy = app.downloads.offlineCopy(of: entry.item.id) {
            let audio = copy.mediaSource?.mediaStreams?.first { $0.type == "Audio" }
            return ResolvedTrack(
                entryId: entry.id,
                itemId: entry.item.id,
                url: copy.fileURL,
                mediaSourceId: copy.mediaSource?.id,
                playSessionId: nil,
                stream: StreamInfo(isTranscoded: false, isDownloaded: true, codec: audio?.codec ?? copy.mediaSource?.container,
                                   bitrate: audio?.bitRate ?? copy.mediaSource?.bitrate, sampleRate: audio?.sampleRate, bitDepth: audio?.bitDepth)
            )
        }
        guard let client = app.client else {
            throw APIError.notAuthenticated
        }
        let quality = app.settings.musicQuality
        let info = try await client.audioPlaybackInfo(itemId: entry.item.id, maxBitrate: quality.maxBitrate, forceTranscoding: forceTranscoding)
        guard let source = info.mediaSources?.first else {
            throw MusicPlayerError.noStream
        }
        let audio = source.mediaStreams?.first { $0.type == "Audio" }
        if source.supportsDirectPlay == true, !forceTranscoding {
            return ResolvedTrack(
                entryId: entry.id,
                itemId: entry.item.id,
                url: client.audioStreamURL(itemId: entry.item.id, mediaSource: source, playSessionId: info.playSessionId),
                mediaSourceId: source.id,
                playSessionId: info.playSessionId,
                stream: StreamInfo(isTranscoded: false, codec: audio?.codec ?? source.container, bitrate: audio?.bitRate ?? source.bitrate,
                                   sampleRate: audio?.sampleRate, bitDepth: audio?.bitDepth)
            )
        }
        guard let url = source.transcodingUrl.flatMap(client.transcodingURL) else {
            throw MusicPlayerError.noStream
        }
        return ResolvedTrack(
            entryId: entry.id,
            itemId: entry.item.id,
            url: url,
            mediaSourceId: source.id,
            playSessionId: info.playSessionId,
            stream: StreamInfo(isTranscoded: true, codec: "aac", sourceCodec: audio?.codec ?? source.container, bitrate: quality.maxBitrate ?? 320_000)
        )
    }

    private func start(_ track: ResolvedTrack, at startAt: Double) {
        let item = AVPlayerItem(url: track.url)
        currentTrack = track
        currentItem = item
        currentObservation = observeStatus(of: item)
        stream = track.stream
        if startAt > 1 {
            pendingSeek = startAt
        }
        player.removeAllItems()
        player.insert(item, after: nil)
        if isPlaying {
            player.play()
            reportStart()
        } else {
            player.pause()
        }
        updateNowPlaying()
        prepareNext()
    }

    private func observeStatus(of item: AVPlayerItem) -> NSKeyValueObservation {
        item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor in self?.statusChanged(of: item, to: status, message: message) }
        }
    }

    private func statusChanged(of item: AVPlayerItem, to status: AVPlayerItem.Status, message: String?) {
        if let prepared, item === prepared.item, status == .failed {
            // Loaded again when its turn comes, which also tries transcoding.
            clearPrepared()
            return
        }
        guard item === currentItem, let track = currentTrack else {
            return
        }
        switch status {
        case .readyToPlay:
            failures = 0
            if let pendingSeek {
                self.pendingSeek = nil
                seek(to: pendingSeek)
            }
        case .failed:
            if !track.stream.isTranscoded {
                // AVPlayer rejected the file, so the server converts it instead.
                load(at: index, startAt: position, autoplay: isPlaying, forceTranscoding: true)
            } else if let entry = currentEntry {
                failed(entry, message: message ?? String(localized: "The stream could not be played."))
            }
        default:
            break
        }
    }

    /// Skips a song that can't be played, unless several in a row failed.
    private func failed(_ entry: Entry, message: String) {
        failures += 1
        if failures < 3, isPlaying, let next = nextIndex, next != index {
            load(at: next, autoplay: true)
            return
        }
        isPlaying = false
        isBuffering = false
        updateNowPlaying()
        app.errorMessage = String(localized: "“\(entry.item.displayName)” can't be played. \(message)")
    }

    /// Hands the next song to the player while the current one plays, so it follows without a gap.
    private func prepareNext() {
        guard currentItem != nil, repeatMode != .one, let next = nextIndex else {
            clearPrepared()
            return
        }
        let entry = entries[next]
        if prepared?.track.entryId == entry.id || preparingEntryId == entry.id {
            return
        }
        clearPrepared()
        preparingEntryId = entry.id
        let generation = generation
        prepareTask = Task {
            guard let track = try? await resolve(entry), !Task.isCancelled, generation == self.generation,
                  nextIndex.map({ entries[$0].id }) == entry.id, let currentItem
            else {
                if generation == self.generation, preparingEntryId == entry.id {
                    preparingEntryId = nil
                }
                return
            }
            preparingEntryId = nil
            let item = AVPlayerItem(url: track.url)
            guard player.canInsert(item, after: currentItem) else {
                return
            }
            player.insert(item, after: currentItem)
            prepared = (track, item)
            preparedObservation = observeStatus(of: item)
        }
    }

    private func clearPrepared() {
        prepareTask?.cancel()
        prepareTask = nil
        preparingEntryId = nil
        if let prepared {
            player.remove(prepared.item)
        }
        prepared = nil
        preparedObservation = nil
    }

    // MARK: - Player events

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.timeChanged(time.seconds)
            }
        }
        playerObservations = [
            player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.currentItemChanged() }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                Task { @MainActor in self?.isBuffering = waiting }
            },
        ]
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            MainActor.assumeIsolated {
                self?.itemDidEnd(item)
            }
        }
    }

    private func timeChanged(_ seconds: Double) {
        guard seconds.isFinite, !isSeeking, pendingSeek == nil, let currentItem, player.currentItem === currentItem else {
            return
        }
        position = seconds
        let itemDuration = currentItem.duration.seconds
        if itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }
    }

    /// The player moved on to the prepared song on its own.
    private func currentItemChanged() {
        guard let item = player.currentItem, item !== currentItem, let prepared, item === prepared.item,
              let target = entries.firstIndex(where: { $0.id == prepared.track.entryId })
        else {
            return
        }
        finishReport()
        generation += 1
        self.prepared = nil
        index = target
        currentTrack = prepared.track
        currentItem = item
        currentObservation = preparedObservation
        preparedObservation = nil
        stream = prepared.track.stream
        position = 0
        duration = entries[target].item.duration ?? 0
        failures = 0
        if isPlaying {
            reportStart()
        }
        loadLyrics(for: entries[target].item)
        updateNowPlaying()
        saveQueue()
        prepareNext()
    }

    private func itemDidEnd(_ item: AVPlayerItem?) {
        guard let item, item === currentItem else {
            return
        }
        position = duration
        if repeatMode == .one {
            finishReport()
            player.seek(to: .zero)
            position = 0
            player.play()
            reportStart()
            return
        }
        // The prepared song takes over by itself.
        guard prepared == nil else {
            return
        }
        finishReport()
        if let next = nextIndex {
            load(at: next, autoplay: true)
        } else {
            // The end of the queue: stop on the last song, ready to play it again.
            load(at: index, autoplay: false)
        }
    }

    // MARK: - Lyrics

    private func loadLyrics(for item: BaseItem) {
        lyricsTask?.cancel()
        guard item.hasLyrics != false, let client = app.client else {
            lyrics = .none
            return
        }
        lyrics = .loading
        let itemId = item.id
        lyricsTask = Task {
            let lines = (try? await client.lyrics(itemId: itemId)) ?? []
            guard !Task.isCancelled, current?.id == itemId else {
                return
            }
            lyrics = lines.isEmpty ? .none : .loaded(lines)
        }
    }

    // MARK: - Reporting

    private func reportStart() {
        guard currentTrack != nil, !hasReportedStart else {
            return
        }
        hasReportedStart = true
        report(.start)
    }

    /// Ends the server's play session of the current song, which records it as played once most of it was heard.
    private func finishReport() {
        guard hasReportedStart else {
            return
        }
        report(.stopped)
        hasReportedStart = false
        lastReportedPosition = -1
    }

    private func playbackReport(stopped: Bool) -> PlaybackReport? {
        guard let track = currentTrack else {
            return nil
        }
        return PlaybackReport(
            itemId: track.itemId,
            mediaSourceId: track.mediaSourceId,
            playSessionId: track.playSessionId,
            positionTicks: position.ticks,
            isPaused: stopped ? nil : !isPlaying,
            volumeLevel: stopped ? nil : Int(volume),
            canSeek: stopped ? nil : true,
            playMethod: track.stream.isTranscoded ? "Transcode" : "DirectPlay"
        )
    }

    /// Sends reports strictly in order, so "stopped" never overtakes "progress".
    private func report(_ kind: ReportKind) {
        guard hasReportedStart || kind == .start, let report = playbackReport(stopped: kind == .stopped), let client = app.client else {
            return
        }
        let previous = reportChain
        reportChain = Task {
            await previous?.value
            switch kind {
            case .start: await client.reportPlaybackStart(report)
            case .progress: await client.reportPlaybackProgress(report)
            case .stopped: await client.reportPlaybackStopped(report)
            }
        }
    }

    /// Saves the position every 10 seconds, on the server and for the next launch.
    private func tick() {
        guard isPlaying, hasReportedStart, abs(position - lastReportedPosition) > 1 else {
            return
        }
        lastReportedPosition = position
        report(.progress)
        updateNowPlaying()
        UserDefaults.standard.set(position, forKey: "musicPosition")
    }

    /// Used at app termination: waits (up to 2 seconds) for the stop report.
    func stopForTermination() {
        saveQueue()
        guard hasReportedStart, let report = playbackReport(stopped: true) else {
            return
        }
        hasReportedStart = false
        player.pause()
        app.client?.reportPlaybackStoppedBlocking(report, timeout: 2)
    }

    // MARK: - Keeping the queue between launches

    private func saveQueue() {
        let defaults = UserDefaults.standard
        guard !entries.isEmpty else {
            ["musicQueue", "musicQueueIndex", "musicPosition", "musicUnshuffledQueue"].forEach(defaults.removeObject)
            return
        }
        // A window around the current song, small enough to restore with a few requests.
        let lower = max(0, index - 50)
        let saved = entries[lower..<min(entries.count, lower + 300)]
        defaults.set(saved.map(\.item.id), forKey: "musicQueue")
        defaults.set(index - lower, forKey: "musicQueueIndex")
        defaults.set(position, forKey: "musicPosition")
        defaults.set(repeatMode.rawValue, forKey: "musicRepeat")
        if let unshuffled {
            let ids = Set(saved.map(\.id))
            defaults.set(unshuffled.filter { ids.contains($0.id) }.map(\.item.id), forKey: "musicUnshuffledQueue")
        } else {
            defaults.removeObject(forKey: "musicUnshuffledQueue")
        }
    }

    /// Brings back the queue of the last session, paused where it was left.
    func restore() async {
        let defaults = UserDefaults.standard
        guard entries.isEmpty, let client = app.client, let ids = defaults.stringArray(forKey: "musicQueue"), !ids.isEmpty else {
            return
        }
        applyRepeatMode(RepeatMode(rawValue: defaults.string(forKey: "musicRepeat") ?? "") ?? .off)
        var found: [String: BaseItem] = [:]
        for start in stride(from: 0, to: ids.count, by: 100) {
            var query = ItemQuery()
            query.ids = Array(ids[start..<min(ids.count, start + 100)])
            query.enableTotalRecordCount = false
            for item in (try? await client.items(query).items) ?? [] {
                found[item.id] = item
            }
        }
        // Songs deleted on the server in the meantime drop out.
        let savedIndex = min(max(defaults.integer(forKey: "musicQueueIndex"), 0), ids.count - 1)
        let list = ids.compactMap { found[$0] }.map { Entry(item: $0) }
        guard !list.isEmpty, entries.isEmpty else {
            return
        }
        let currentSurvived = found[ids[savedIndex]] != nil
        entries = list
        index = min(ids[..<savedIndex].filter { found[$0] != nil }.count, list.count - 1)
        position = currentSurvived ? defaults.double(forKey: "musicPosition") : 0
        duration = list[index].item.duration ?? 0
        if let original = defaults.stringArray(forKey: "musicUnshuffledQueue") {
            var pool = list
            unshuffled = original.compactMap { id in pool.firstIndex { $0.item.id == id }.map { pool.remove(at: $0) } }
            isShuffled = true
        }
        loadLyrics(for: list[index].item)
    }

    // MARK: - System integration

    /// Video playback takes over the media keys and Now Playing.
    func yieldToVideo() {
        if isPlaying {
            pause()
        }
        releaseSystemControls()
    }

    /// Takes the media keys back once a video closed.
    func videoDidClose() {
        // The video player removed every target, including these.
        remoteTargets = []
        if current != nil {
            claimSystemControls()
        }
    }

    private func claimSystemControls() {
        guard remoteTargets.isEmpty else {
            return
        }
        let commands = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MusicPlayer) -> Void) {
            let target = command.addTarget { [weak self] _ in
                Task { @MainActor in
                    if let self {
                        action(self)
                    }
                }
                return .success
            }
            remoteTargets.append((command, target))
        }
        add(commands.togglePlayPauseCommand) { $0.togglePlayPause() }
        add(commands.playCommand) { $0.play() }
        add(commands.pauseCommand) { $0.pause() }
        add(commands.nextTrackCommand) { $0.next() }
        add(commands.previousTrackCommand) { $0.previous() }
        let seek = commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let time = event.positionTime
            Task { @MainActor in self?.seek(to: time) }
            return .success
        }
        remoteTargets.append((commands.changePlaybackPositionCommand, seek))
    }

    private func releaseSystemControls() {
        for (command, target) in remoteTargets {
            command.removeTarget(target)
        }
        remoteTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func updateNowPlaying() {
        guard !remoteTargets.isEmpty, let item = current else {
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.displayName,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1 : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artist = item.artistLine {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album = item.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let artwork, artwork.itemId == item.id {
            info[MPMediaItemPropertyArtwork] = artwork.artwork
        } else {
            loadArtwork(for: item)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func loadArtwork(for item: BaseItem) {
        guard let url = app.client?.coverURL(item, width: 600) else {
            return
        }
        Task {
            guard let image = await ImageLoader.shared.image(for: url), current?.id == item.id else {
                return
            }
            let picture = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            artwork = (item.id, MPMediaItemArtwork(boundsSize: picture.size) { _ in picture })
            updateNowPlaying()
        }
    }

    /// Space plays and pauses, ⌘← and ⌘→ skip, ⌘↑ and ⌘↓ change the volume, while no video is open.
    /// Handled here rather than as menu shortcuts, so the keys keep working in text fields.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let code = event.keyCode
            let handled = MainActor.assumeIsolated {
                self?.handleKey(code: code, modifiers: modifiers) ?? false
            }
            return handled ? nil : event
        }
    }

    private func handleKey(code: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard app.player == nil, current != nil, !(NSApp.keyWindow?.firstResponder is NSTextView) else {
            return false
        }
        switch (code, modifiers) {
        case (49, []): togglePlayPause()
        case (123, .command): previous()
        case (124, .command): next()
        case (126, .command): adjustVolume(by: 5)
        case (125, .command): adjustVolume(by: -5)
        default: return false
        }
        return true
    }
}

enum MusicPlayerError: LocalizedError {
    case noStream

    var errorDescription: String? {
        String(localized: "The server didn't offer a stream for this song.")
    }
}
