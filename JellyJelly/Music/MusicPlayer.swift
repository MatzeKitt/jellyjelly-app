import AVFoundation
import AppKit
import MediaPlayer
import Observation

/// Plays songs from a queue, or the files of an audiobook. The next song or file is loaded into the player ahead
/// of time, so it starts without a gap.
///
/// While a book plays, its files form the queue, positions count from the start of the book, previous and
/// next move between chapters, and the playback speed of audiobooks applies.
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

    enum SleepTimer: Equatable {
        /// Pauses at a time, fading out over the last seconds.
        case at(Date)
        /// Pauses at the end of the chapter, or of the song.
        case endOfChapter
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
    /// The audiobook whose files are in the queue, if one is playing.
    private(set) var book: Audiobook?
    /// The playback speed of audiobooks. Music always plays at its own speed.
    private(set) var rate: Double
    private(set) var sleepTimer: SleepTimer?
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
    /// Whether there is a next song, or a next chapter in a book.
    var hasNext: Bool {
        if let book {
            return currentChapter.map { $0.id + 1 < book.chapters.count } ?? false
        }
        return nextIndex != nil
    }

    /// The position in the whole book, or in the song.
    var bookPosition: Double { (book?.offset(of: index) ?? 0) + position }
    var currentChapter: BookChapter? { book?.chapter(at: bookPosition) }

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
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    /// Fires at the end of the chapter while the sleep timer waits for it.
    @ObservationIgnored private var sleepBoundary: Any?
    /// Whether the player pauses at the end of the file instead of moving on, for the sleep timer.
    @ObservationIgnored private var stopsAtItemEnd = false
    @ObservationIgnored private var lastChapterId: Int?

    init(app: AppModel) {
        self.app = app
        volume = app.settings.musicVolume
        rate = app.settings.audiobookRate
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
        // The book's file reports its position while it's still a book's.
        finishReport()
        leaveBook()
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

    /// Queues songs right after the current one. Songs don't join a book, but replace it.
    func playNext(_ items: [BaseItem]) {
        let songs = items.filter(\.isAudio).map { Entry(item: $0) }
        guard !songs.isEmpty else {
            return
        }
        guard current != nil, book == nil else {
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
        guard current != nil, book == nil else {
            play(songs.map(\.item), shuffle: false)
            return
        }
        entries += songs
        unshuffled? += songs
        queueChanged()
    }

    /// Replaces the queue with the files of a book and plays it from a position in one of them.
    func playBook(_ book: Audiobook, part: Int, at position: Double) {
        guard !book.parts.isEmpty else {
            return
        }
        finishReport()
        self.book = book
        unshuffled = nil
        isShuffled = false
        applyRepeatMode(.off)
        entries = book.parts.map { Entry(item: $0) }
        failures = 0
        lastChapterId = nil
        applyRate()
        load(at: min(max(part, 0), entries.count - 1), startAt: position, autoplay: true)
    }

    private func leaveBook() {
        guard book != nil else {
            return
        }
        book = nil
        lastChapterId = nil
        applyRate()
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

    /// The next song, or the next chapter of a book.
    func next() {
        if book != nil {
            nextChapter()
            return
        }
        guard let next = nextIndex else {
            return
        }
        load(at: next, autoplay: isPlaying || currentItem == nil)
    }

    /// Restarts the song after its first seconds, like a CD player; otherwise goes back a song.
    /// In a book, the same for chapters.
    func previous() {
        if book != nil {
            previousChapter()
            return
        }
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
        armChapterStop()
    }

    /// Seeks to a time in the whole book, loading another of its files if needed; in a song, just seeks.
    func seekBook(to seconds: Double) {
        guard let book else {
            seek(to: seconds)
            return
        }
        let target = min(max(0, seconds), max(0, book.duration - 0.5))
        let part = book.part(at: target)
        let local = target - book.offset(of: part)
        if part == index {
            seek(to: local)
        } else {
            load(at: part, startAt: local, autoplay: isPlaying)
        }
    }

    /// Skips forward or back, across the files of a book.
    func skip(by seconds: Double) {
        seekBook(to: bookPosition + seconds)
    }

    func nextChapter() {
        guard let book, let chapter = currentChapter, book.chapters.indices.contains(chapter.id + 1) else {
            return
        }
        seekBook(to: book.chapters[chapter.id + 1].start)
    }

    /// Goes back to the start of the chapter, or to the chapter before within its first seconds.
    func previousChapter() {
        guard let book, let chapter = currentChapter else {
            return
        }
        if bookPosition - chapter.start < 3, chapter.id > 0 {
            seekBook(to: book.chapters[chapter.id - 1].start)
        } else {
            seekBook(to: chapter.start)
        }
    }

    func jump(to chapter: BookChapter) {
        seekBook(to: chapter.start)
        if !isPlaying {
            play()
        }
    }

    func setRate(_ value: Double) {
        rate = value
        app.settings.audiobookRate = value
        applyRate()
    }

    private func applyRate() {
        let effective = Float(book == nil ? 1 : rate)
        player.defaultRate = effective
        if player.rate != 0 {
            player.rate = effective
        }
        updateNowPlaying()
    }

    // MARK: - Sleep timer

    func setSleepTimer(_ timer: SleepTimer?) {
        sleepTask?.cancel()
        sleepTask = nil
        // A fade that was cut short.
        player.volume = Float(volume / 100)
        sleepTimer = timer
        if case let .at(deadline) = timer {
            sleepTask = Task { [weak self] in
                await self?.runSleepTimer(until: deadline)
            }
        }
        armChapterStop()
    }

    /// Waits for the time, fades out over a few seconds, and pauses.
    private func runSleepTimer(until deadline: Date) async {
        let fade = 6.0
        let steps = 30
        try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow - fade)))
        for step in 1...steps {
            guard !Task.isCancelled else {
                return
            }
            player.volume = Float(volume / 100) * Float(1 - Double(step) / Double(steps))
            try? await Task.sleep(for: .seconds(fade / Double(steps)))
        }
        guard !Task.isCancelled else {
            return
        }
        sleepTask = nil
        sleepTimer = nil
        pause()
        player.volume = Float(volume / 100)
    }

    /// Arms the stop at the end of the chapter or song: a boundary inside a book's file, or the end of the file.
    private func armChapterStop() {
        if let sleepBoundary {
            player.removeTimeObserver(sleepBoundary)
            self.sleepBoundary = nil
        }
        stopsAtItemEnd = false
        defer {
            updateItemEndAction()
        }
        guard sleepTimer == .endOfChapter, currentItem != nil else {
            return
        }
        guard let book, let chapter = currentChapter, entries.indices.contains(index) else {
            stopsAtItemEnd = true
            return
        }
        let offset = book.offset(of: index)
        let fileEnd = offset + (entries[index].item.duration ?? duration)
        guard chapter.part == index, chapter.end < fileEnd - 1 else {
            stopsAtItemEnd = true
            return
        }
        let time = CMTime(seconds: chapter.end - offset, preferredTimescale: 600)
        sleepBoundary = player.addBoundaryTimeObserver(forTimes: [NSValue(time: time)], queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                self?.chapterEndReached(chapter)
            }
        }
    }

    /// Pauses at the end of a chapter, right where the next one starts.
    private func chapterEndReached(_ chapter: BookChapter) {
        guard sleepTimer == .endOfChapter, book != nil, abs(bookPosition - chapter.end) < 3 else {
            return
        }
        setSleepTimer(nil)
        pause()
        seekBook(to: chapter.end)
    }

    private func updateItemEndAction() {
        player.actionAtItemEnd = stopsAtItemEnd ? .pause : (repeatMode == .one ? .none : .advance)
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
        guard book == nil else {
            return
        }
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
        guard book == nil else {
            return
        }
        applyRepeatMode(mode)
        if !entries.isEmpty {
            queueChanged()
        }
    }

    private func applyRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode
        // Repeating a song keeps it in the player at its end, to start over.
        updateItemEndAction()
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
        leaveBook()
        setSleepTimer(nil)
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
        book?.apply(itemId, data)
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
        let item = makeItem(track.url)
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
        armChapterStop()
        prepareNext()
    }

    private func makeItem(_ url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        // Keeps voices natural at other speeds.
        item.audioTimePitchAlgorithm = .spectral
        return item
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
            let item = makeItem(track.url)
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
        // The status observation misses a change when the player was already playing before the new file.
        if isBuffering, seconds > position, player.timeControlStatus == .playing {
            isBuffering = false
        }
        position = seconds
        let itemDuration = currentItem.duration.seconds
        if itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }
        if book != nil, currentChapter?.id != lastChapterId {
            lastChapterId = currentChapter?.id
            updateNowPlaying()
        }
    }

    /// The player moved on to the prepared song on its own.
    private func currentItemChanged() {
        guard let item = player.currentItem, item !== currentItem, let prepared, item === prepared.item,
              let target = entries.firstIndex(where: { $0.id == prepared.track.entryId })
        else {
            return
        }
        finishReport(completed: true)
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
        armChapterStop()
        prepareNext()
    }

    private func itemDidEnd(_ item: AVPlayerItem?) {
        guard let item, item === currentItem else {
            return
        }
        position = duration
        if stopsAtItemEnd {
            // The sleep timer ends with the chapter or song: stop, ready to continue with what follows.
            setSleepTimer(nil)
            isPlaying = false
            finishReport(completed: true)
            load(at: nextIndex ?? endIndex, autoplay: false)
            return
        }
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
        finishReport(completed: true)
        if let next = nextIndex {
            load(at: next, autoplay: true)
        } else {
            load(at: endIndex, autoplay: false)
        }
    }

    /// Where playback waits once the queue ended: on the last song, ready to play it again, or at the start
    /// of a finished book.
    private var endIndex: Int { book == nil ? index : 0 }

    // MARK: - Lyrics

    private func loadLyrics(for item: BaseItem) {
        lyricsTask?.cancel()
        guard book == nil, item.hasLyrics != false, let client = app.client else {
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
    ///
    /// - Parameter completed: Whether the file played to its end. A book's file then goes without a position,
    ///   which the server takes as finished; it would otherwise ignore positions in a book's last minutes.
    private func finishReport(completed: Bool = false) {
        guard hasReportedStart else {
            return
        }
        recordOfflineProgress(completed: completed)
        report(.stopped, completed: completed)
        hasReportedStart = false
        lastReportedPosition = -1
    }

    /// Keeps the position in a downloaded book's file locally, in case the server can't be reached.
    private func recordOfflineProgress(completed: Bool) {
        guard book != nil, let track = currentTrack, track.stream.isDownloaded else {
            return
        }
        app.downloads.recordPlayback(track.itemId, position: position, duration: max(duration, position), finished: completed)
    }

    private func playbackReport(stopped: Bool, completed: Bool = false) -> PlaybackReport? {
        guard let track = currentTrack else {
            return nil
        }
        return PlaybackReport(
            itemId: track.itemId,
            mediaSourceId: track.mediaSourceId,
            playSessionId: track.playSessionId,
            positionTicks: stopped && completed && book != nil ? nil : position.ticks,
            isPaused: stopped ? nil : !isPlaying,
            volumeLevel: stopped ? nil : Int(volume),
            canSeek: stopped ? nil : true,
            playMethod: track.stream.isTranscoded ? "Transcode" : "DirectPlay"
        )
    }

    /// Sends reports strictly in order, so "stopped" never overtakes "progress".
    private func report(_ kind: ReportKind, completed: Bool = false) {
        guard hasReportedStart || kind == .start, let report = playbackReport(stopped: kind == .stopped, completed: completed),
              let client = app.client
        else {
            return
        }
        let isBook = book != nil
        let previous = reportChain
        reportChain = Task {
            await previous?.value
            switch kind {
            case .start: await client.reportPlaybackStart(report)
            case .progress: await client.reportPlaybackProgress(report)
            case .stopped:
                let delivered = await client.reportPlaybackStopped(report)
                if isBook {
                    await bookFileStopped(report.itemId, delivered: delivered, client: client)
                }
            }
        }
    }

    /// Shares the new progress of a book's file, so the book's page and the library show it.
    private func bookFileStopped(_ itemId: String, delivered: Bool, client: JellyfinClient) async {
        if delivered {
            app.downloads.markSynced(itemId)
            if let data = try? await client.userData(itemId) {
                app.broadcast(itemId, data)
            }
        } else if let data = app.downloads.records[itemId]?.item.userData {
            // Recorded offline, to be synced later.
            app.announce(itemId, data)
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
        recordOfflineProgress(completed: false)
        hasReportedStart = false
        player.pause()
        app.client?.reportPlaybackStoppedBlocking(report, timeout: 2)
    }

    // MARK: - Keeping the queue between launches

    private func saveQueue() {
        let defaults = UserDefaults.standard
        guard !entries.isEmpty else {
            ["musicQueue", "musicQueueIndex", "musicPosition", "musicUnshuffledQueue", "musicBook"].forEach(defaults.removeObject)
            return
        }
        if let book {
            // Just enough to find the book again.
            var seed = BaseItem(id: book.item.id, name: book.item.name, type: book.item.type)
            seed.album = book.item.album
            seed.parentId = book.item.parentId
            defaults.set(try? JSONEncoder().encode(seed), forKey: "musicBook")
        } else {
            defaults.removeObject(forKey: "musicBook")
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
        if let data = defaults.data(forKey: "musicBook"), let seed = try? JSONDecoder().decode(BaseItem.self, from: data) {
            await restoreBook(seed, ids: ids)
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

    private func restoreBook(_ seed: BaseItem, ids: [String]) async {
        let defaults = UserDefaults.standard
        guard let book = try? await app.audiobook(for: seed), !book.parts.isEmpty, entries.isEmpty else {
            return
        }
        let savedIndex = defaults.integer(forKey: "musicQueueIndex")
        let currentId = ids.indices.contains(savedIndex) ? ids[savedIndex] : nil
        self.book = book
        applyRepeatMode(.off)
        applyRate()
        entries = book.parts.map { Entry(item: $0) }
        if let saved = book.parts.firstIndex(where: { $0.id == currentId }) {
            index = saved
            position = defaults.double(forKey: "musicPosition")
        } else {
            (index, position) = book.resumePoint
        }
        duration = entries[index].item.duration ?? 0
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
        for (command, sign) in [(commands.skipForwardCommand, 1.0), (commands.skipBackwardCommand, -1.0)] {
            let target = command.addTarget { [weak self] event in
                let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
                Task { @MainActor in self?.skip(by: sign * interval) }
                return .success
            }
            remoteTargets.append((command, target))
        }
        let seek = commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let time = event.positionTime
            Task { @MainActor in self?.seekBook(to: time) }
            return .success
        }
        remoteTargets.append((commands.changePlaybackPositionCommand, seek))
    }

    private func releaseSystemControls() {
        for (command, target) in remoteTargets {
            command.removeTarget(target)
        }
        remoteTargets = []
        // The video player skips with these and doesn't turn them back on.
        MPRemoteCommandCenter.shared().skipForwardCommand.isEnabled = true
        MPRemoteCommandCenter.shared().skipBackwardCommand.isEnabled = true
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func updateNowPlaying() {
        guard !remoteTargets.isEmpty, let item = current else {
            return
        }
        let commands = MPRemoteCommandCenter.shared()
        // Books skip by the intervals from the settings; songs show previous and next instead.
        commands.skipForwardCommand.isEnabled = book != nil
        commands.skipBackwardCommand.isEnabled = book != nil
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: app.settings.audiobookSkipForward)]
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: app.settings.audiobookSkipBack)]
        let speed = book == nil ? 1 : rate
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.displayName,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artist = item.artistLine {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album = item.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        // A book shows its chapter as the title and counts its time from the start of the book.
        if let book {
            let chapter = currentChapter
            info[MPMediaItemPropertyTitle] = book.chapters.count > 1 ? chapter?.title ?? book.title : book.title
            info[MPMediaItemPropertyAlbumTitle] = book.title
            info[MPMediaItemPropertyArtist] = book.author
            info[MPMediaItemPropertyPlaybackDuration] = book.duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = bookPosition
            if let chapter {
                info[MPNowPlayingInfoPropertyChapterNumber] = chapter.id
                info[MPNowPlayingInfoPropertyChapterCount] = book.chapters.count
            }
        }
        let artworkId = book?.id ?? item.id
        if let artwork, artwork.itemId == artworkId {
            info[MPMediaItemPropertyArtwork] = artwork.artwork
        } else {
            loadArtwork(for: item)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func loadArtwork(for item: BaseItem) {
        let id = book?.id ?? item.id
        guard let url = book.flatMap({ app.coverURL(of: $0, width: 600) }) ?? app.client?.coverURL(item, width: 600) else {
            return
        }
        Task {
            guard let image = await ImageLoader.shared.image(for: url), (book?.id ?? current?.id) == id else {
                return
            }
            let picture = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            artwork = (id, MPMediaItemArtwork(boundsSize: picture.size) { _ in picture })
            updateNowPlaying()
        }
    }

    /// Space plays and pauses, ⌘← and ⌘→ skip, ⌘↑ and ⌘↓ change the volume, while no video is open.
    /// In a book, ⌘← and ⌘→ move between chapters, and ⇧⌘← and ⇧⌘→ skip back and forward.
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
        case (123, [.command, .shift]) where book != nil: skip(by: -app.settings.audiobookSkipBack)
        case (124, [.command, .shift]) where book != nil: skip(by: app.settings.audiobookSkipForward)
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
