import AppKit
import MediaPlayer
import Observation

@MainActor
@Observable
final class PlayerModel {
    enum Phase: Equatable {
        case loading
        case playing
        case failed(String)
    }

    struct ChapterMark: Identifiable, Hashable {
        var id: Double { start }
        var start: Double
        var name: String
    }

    // MARK: Content

    private(set) var item: BaseItem
    private(set) var queue: [BaseItem]
    private(set) var mediaSource: MediaSource?
    private(set) var playSessionId: String?
    /// The downloaded copy being played, if any.
    private(set) var offlineCopy: OfflineCopy?
    private(set) var chapters: [ChapterMark] = []
    private(set) var segments: [MediaSegment] = []

    // MARK: Playback state

    private(set) var phase: Phase = .loading
    private(set) var engineKind: EngineKind?
    private(set) var engineReason = ""
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPaused = false
    private(set) var isBuffering = true
    private(set) var bufferProgress: Double?
    private(set) var bufferedAhead: Double = 0
    private(set) var bufferHistory: [Double] = []
    private(set) var rate: Double = 1
    private(set) var isMuted = false
    var volume: Double {
        didSet {
            engine?.setVolume(volume)
            app.settings.volume = volume
        }
    }

    private(set) var audioOptions: [TrackOption] = []
    private(set) var subtitleOptions: [TrackOption] = []
    private(set) var subtitleText: String?
    private(set) var activeSegment: MediaSegment?
    private(set) var upNext: BaseItem?
    private(set) var upNextDismissed = false

    // MARK: UI state

    var showStats: Bool
    private(set) var controlsVisible = true
    var isInteractingWithControls = false
    private(set) var isFullScreen = false
    /// The video plays in a floating window while the main window is free for browsing.
    private(set) var isPictureInPicture = false
    private(set) var statsSections: [StatSection] = []
    private(set) var serverPlayMethod: String?
    private(set) var serverTranscoding: TranscodingInfo?

    private(set) var engine: PlaybackEngine?

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private let client: JellyfinClient
    @ObservationIgnored private var startAt: Double
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var hideControlsTask: Task<Void, Never>?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var appSubtitles: [Int: SubtitleCues] = [:]
    @ObservationIgnored private var appSubtitleIndex: Int?
    @ObservationIgnored private var skippedSegments: Set<String> = []
    @ObservationIgnored private var lastReportedPosition: Double = -1
    @ObservationIgnored private var hasReportedStart = false
    @ObservationIgnored private var hasEnded = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var triedFallback = false
    @ObservationIgnored private var windowObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var workspaceObserver: NSObjectProtocol?
    @ObservationIgnored private var reportChain: Task<Void, Never>?
    @ObservationIgnored private var trickplayCache: [Int: CGImage] = [:]
    @ObservationIgnored private var pictureInPicture: PictureInPictureWindow?
    /// Picture in picture was entered on switching to another app, so returning to the app ends it.
    @ObservationIgnored private var isAutomaticPictureInPicture = false
    @ObservationIgnored private weak var mainWindow: NSWindow?

    init(app: AppModel, client: JellyfinClient, item: BaseItem, queue: [BaseItem], startAt: Double) {
        self.app = app
        self.client = client
        self.item = item
        self.queue = queue
        self.startAt = startAt
        self.volume = app.settings.volume
        self.showStats = app.settings.showStatsOnStart
    }

    var title: String { item.displayName }

    var subtitle: String? {
        if item.isEpisode {
            let parts = [item.seriesName, app.isYouTube(item) ? nil : item.episodeLabel].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        return item.productionYear.map(String.init)
    }

    var remaining: Double { max(0, duration - position) }

    // MARK: - Lifecycle

    func start() {
        installKeyMonitor()
        observeWindow()
        configureRemoteCommands()
        if app.settings.openPlayerFullScreen, let window = NSApp.mainWindow, !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        tasks.append(Task { await load() })
        tasks.append(Task { await reportLoop() })
        tasks.append(Task { await statsLoop() })
        userActivity()
    }

    private func load() async {
        phase = .loading
        isBuffering = true
        if let copy = app.downloads.offlineCopy(of: item.id), let source = copy.mediaSource {
            // Downloaded: play the local file right away, without waiting for the server.
            offlineCopy = copy
            var details = copy.record.item
            details.userData = item.userData ?? details.userData
            apply(details)
            segments = copy.record.segments
            mediaSource = source
            startEngine(for: source, preferMPV: false)
            updateNowPlaying()
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let details = try await client.item(item.id)
            guard isCurrentLoad(generation) else {
                return
            }
            apply(details)

            var source = details.primaryMediaSource
            let info = try? await client.playbackInfo(itemId: details.id, mediaSourceId: source?.id)
            guard isCurrentLoad(generation) else {
                return
            }
            if let info {
                playSessionId = info.playSessionId
                if let first = info.mediaSources?.first(where: { $0.id == source?.id }) ?? info.mediaSources?.first {
                    source = first
                }
            }
            guard let source else {
                fail(String(localized: "This item has no playable file."))
                return
            }
            mediaSource = source
            startEngine(for: source, preferMPV: false)
            updateNowPlaying()
            Task {
                let loaded = (try? await client.mediaSegments(itemId: details.id)) ?? []
                if isCurrentLoad(generation) {
                    segments = loaded
                }
            }
        } catch {
            if isCurrentLoad(generation) {
                fail(error.localizedDescription)
            }
        }
    }

    /// A load that finishes after the player closed or moved on to another item must not start an engine,
    /// or its video would keep playing without any controls.
    private func isCurrentLoad(_ generation: Int) -> Bool {
        !closed && generation == loadGeneration
    }

    private func apply(_ details: BaseItem) {
        item = details
        chapters = (details.chapters ?? []).compactMap { chapter in
            guard let start = chapter.startPositionTicks else {
                return nil
            }
            return ChapterMark(start: start.tickSeconds, name: chapter.name ?? "")
        }
        if let ticks = details.runTimeTicks {
            duration = ticks.tickSeconds
        }
    }

    private func startEngine(for source: MediaSource, preferMPV: Bool) {
        guard !closed else {
            return
        }
        engine?.stop()
        let (engine, reason) = makeEngine(for: source, preferMPV: preferMPV)
        self.engine = engine
        engineKind = engine.kind
        engineReason = reason
        engine.onEvent = { [weak self] event in
            self?.handle(event)
        }

        let streamURL = offlineCopy?.fileURL ?? client.directStreamURL(itemId: item.id, mediaSource: source, playSessionId: playSessionId)
        var external: [ExternalSubtitle] = []
        if engine.rendersSubtitles {
            for stream in source.mediaStreams ?? [] where stream.type == "Subtitle" && stream.isExternal == true {
                guard let index = stream.index else {
                    continue
                }
                let format = Self.subtitleFormat(stream.codec)
                let url: URL
                if let offlineCopy {
                    guard let local = offlineCopy.subtitleURL(streamIndex: index, format: format) else {
                        continue
                    }
                    url = local
                } else {
                    url = client.subtitleURL(itemId: item.id, mediaSourceId: source.id, streamIndex: index, format: format)
                }
                external.append(ExternalSubtitle(
                    url: url,
                    title: stream.displayTitle ?? stream.title ?? String(localized: "External"),
                    language: stream.language,
                    isDefault: stream.isDefault ?? false
                ))
            }
        }
        let settings = app.settings
        engine.load(PlaybackSource(
            url: streamURL,
            headers: ["Authorization": client.authorizationHeader],
            startAt: startAt,
            externalSubtitles: external,
            bufferAheadSeconds: settings.bufferAheadSeconds,
            cacheSizeMB: settings.cacheSizeMB,
            prebufferSeconds: settings.prebufferSeconds,
            hardwareDecoding: settings.hardwareDecoding,
            preferredAudioLanguage: settings.preferredAudioLanguage,
            preferredSubtitleLanguage: settings.preferredSubtitleLanguage,
            subtitlesEnabled: settings.subtitlesEnabled,
            volume: volume
        ))
        engine.setSubtitleScale(settings.subtitleScale)
        if rate != 1 {
            engine.setRate(rate)
        }
        refreshTracks()
        pictureInPicture?.setVideoAspectRatio(videoAspectRatio)
    }

    /// Width over height of the video stream, as reported by the server.
    private var videoAspectRatio: CGFloat {
        guard let video = mediaSource?.mediaStreams?.first(where: { $0.type == "Video" }),
              let width = video.width, let height = video.height, width > 0, height > 0
        else {
            return 16 / 9
        }
        return min(max(CGFloat(width) / CGFloat(height), 0.5), 3)
    }

    private func makeEngine(for source: MediaSource, preferMPV: Bool) -> (PlaybackEngine, String) {
        let native = AVPlayerEngine.canPlay(source)
        let preference = preferMPV ? .mpv : app.settings.enginePreference
        switch preference {
        case .avPlayer:
            return (AVPlayerEngine(), String(localized: "Selected in settings"))
        case .mpv:
            if let mpv = MPVEngine() {
                return (mpv, preferMPV ? String(localized: "AVPlayer could not open the file") : String(localized: "Selected in settings"))
            }
            return (AVPlayerEngine(), String(localized: "mpv is not installed"))
        case .automatic:
            if native {
                return (AVPlayerEngine(), String(localized: "Native container and codecs"))
            }
            if let mpv = MPVEngine() {
                return (mpv, String(localized: "\((source.container ?? String(localized: "file")).uppercased()) needs FFmpeg decoding"))
            }
            return (AVPlayerEngine(), String(localized: "mpv is not installed; trying AVPlayer"))
        }
    }

    static func subtitleFormat(_ codec: String?) -> String {
        switch (codec ?? "").lowercased() {
        case "subrip", "srt": "srt"
        case "webvtt", "vtt": "vtt"
        case "ass": "ass"
        case "ssa": "ssa"
        case let other where !other.isEmpty: other
        default: "srt"
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        isBuffering = false
        // The error and its Close button live in the full player.
        exitPictureInPicture()
        userActivity()
    }

    /// Stops playback, reports the final position, and dismisses the player.
    func close() {
        guard !closed else {
            return
        }
        closed = true
        recordOfflineProgress()
        send(.stopped, stopReport())
        teardown()
        // Entering picture in picture already left the automatic full screen.
        if isFullScreen, !isPictureInPicture, app.settings.openPlayerFullScreen, let window = NSApp.mainWindow {
            window.toggleFullScreen(nil)
        }
        app.playerDidClose(after: reportChain)
    }

    /// Used at app termination: waits (up to 2 seconds) for the stop report so the resume point is saved.
    func stopForTermination() {
        guard !closed else {
            return
        }
        closed = true
        recordOfflineProgress()
        let report = stopReport()
        teardown()
        client.reportPlaybackStoppedBlocking(report, timeout: 2)
    }

    /// Keeps the resume point of a download locally, in case the server can't be reached.
    private func recordOfflineProgress() {
        guard offlineCopy != nil, hasReportedStart else {
            return
        }
        app.downloads.recordPlayback(item.id, position: position, duration: duration)
    }

    private func teardown() {
        tasks.forEach { $0.cancel() }
        tasks = []
        hideControlsTask?.cancel()
        pictureInPicture?.dismiss()
        pictureInPicture = nil
        engine?.stop()
        engine = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
        endActivity()
        NSCursor.setHiddenUntilMouseMoves(false)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        let commands = MPRemoteCommandCenter.shared()
        [commands.togglePlayPauseCommand, commands.playCommand, commands.pauseCommand, commands.nextTrackCommand,
         commands.skipForwardCommand, commands.skipBackwardCommand, commands.changePlaybackPositionCommand]
            .forEach { $0.removeTarget(nil) }
    }

    // MARK: - Engine events

    private func handle(_ event: EngineEvent) {
        switch event {
        case let .loaded(duration):
            if let duration, duration > 0 {
                self.duration = duration
            }
            phase = .playing
            refreshTracks()
            selectDefaultAppSubtitle()
            if !hasReportedStart {
                hasReportedStart = true
                send(.start, progressReport())
            }
        case let .time(seconds):
            guard seconds.isFinite else {
                return
            }
            position = seconds
            if phase == .loading, seconds > 0 {
                phase = .playing
            }
            positionChanged()
        case let .duration(seconds):
            if seconds > 0 {
                duration = seconds
            }
        case let .paused(paused):
            if paused != isPaused {
                isPaused = paused
                updateActivity()
                updateNowPlaying()
                if hasReportedStart {
                    send(.progress, progressReport())
                }
                if paused {
                    userActivity()
                }
            }
        case let .buffering(buffering, progress):
            isBuffering = buffering
            bufferProgress = progress
        case let .bufferedAhead(seconds):
            bufferedAhead = seconds
        case .tracksChanged:
            refreshTracks()
        case .ended:
            ended()
        case let .failed(message):
            if !triedFallback, engineKind == .avPlayer, MPVEngine.isAvailable, let source = mediaSource {
                // AVPlayer rejected the file; mpv decodes nearly everything.
                triedFallback = true
                startAt = max(startAt, position)
                startEngine(for: source, preferMPV: true)
                return
            }
            fail(message)
        }
    }

    private func positionChanged() {
        if let cues = appSubtitleIndex.flatMap({ appSubtitles[$0] }) {
            subtitleText = cues.text(at: position)
        } else if subtitleText != nil {
            subtitleText = nil
        }
        updateSegment()
        updateUpNext()
    }

    private func updateSegment() {
        let skippable: Set<String> = ["Intro", "Recap", "Preview", "Commercial", "Outro"]
        let current = segments.first { segment in
            guard let type = segment.type, skippable.contains(type),
                  let start = segment.startTicks?.tickSeconds, let end = segment.endTicks?.tickSeconds
            else {
                return false
            }
            return position >= start && position < end - 1
        }
        guard let current, app.settings.segmentSkip != .off else {
            activeSegment = nil
            return
        }
        // Credits at the very end are handled by "Up Next" when there is a next item.
        if current.type == "Outro", upNext != nil {
            activeSegment = nil
            return
        }
        let key = current.id ?? "\(current.startTicks ?? 0)"
        if app.settings.segmentSkip == .automatic, !skippedSegments.contains(key) {
            skippedSegments.insert(key)
            skipActiveSegment(current)
            return
        }
        activeSegment = current
    }

    func skipActiveSegment(_ segment: MediaSegment? = nil) {
        guard let segment = segment ?? activeSegment, let end = segment.endTicks?.tickSeconds else {
            return
        }
        activeSegment = nil
        seek(to: end)
    }

    private func updateUpNext() {
        guard app.settings.autoplayNext, !upNextDismissed, let next = queue.first, duration > 0 else {
            upNext = nil
            return
        }
        let outroStart = segments.first { $0.type == "Outro" }?.startTicks?.tickSeconds
        let threshold = outroStart.map { min(duration - $0, 120) } ?? 0
        if remaining <= max(15, threshold) {
            upNext = next
        } else {
            upNext = nil
        }
    }

    func dismissUpNext() {
        upNextDismissed = true
        upNext = nil
    }

    private func ended() {
        guard !hasEnded else {
            return
        }
        hasEnded = true
        if app.settings.autoplayNext, !upNextDismissed, !queue.isEmpty {
            playNext()
        } else {
            position = duration
            close()
        }
    }

    // MARK: - Controls

    func togglePause() {
        guard let engine else {
            return
        }
        if isPaused {
            engine.play()
        } else {
            engine.pause()
        }
        userActivity()
    }

    func seek(to seconds: Double) {
        let target = min(max(0, seconds), max(0, duration - 0.5))
        position = target
        hasEnded = false
        engine?.seek(to: target)
        positionChanged()
        send(.progress, progressReport())
    }

    func skip(by seconds: Double) {
        seek(to: position + seconds)
        userActivity()
    }

    func setRate(_ rate: Double) {
        self.rate = rate
        engine?.setRate(rate)
    }

    func toggleMute() {
        isMuted.toggle()
        engine?.setMuted(isMuted)
    }

    func adjustVolume(by delta: Double) {
        volume = min(100, max(0, volume + delta))
        if isMuted {
            toggleMute()
        }
    }

    func selectAudio(_ id: String) {
        engine?.selectAudioTrack(id)
        refreshTracks()
    }

    func selectSubtitle(_ id: String?) {
        guard let engine else {
            return
        }
        if engine.rendersSubtitles {
            engine.selectSubtitleTrack(id)
        } else {
            selectAppSubtitle(id.flatMap { Int($0) })
        }
        refreshTracks()
    }

    func toggleStats() {
        showStats.toggle()
        if showStats {
            refreshStats()
        }
    }

    func playNext() {
        guard let next = queue.first else {
            close()
            return
        }
        switchTo(next, queue: Array(queue.dropFirst()))
    }

    func toggleFullScreen() {
        if isPictureInPicture {
            exitPictureInPicture(enterFullScreen: true)
            return
        }
        NSApp.mainWindow?.toggleFullScreen(nil)
    }

    // MARK: - Picture in picture

    func togglePictureInPicture() {
        if isPictureInPicture {
            exitPictureInPicture()
        } else {
            enterPictureInPicture()
        }
    }

    /// Moves the video into a floating window and hands the main window back for browsing.
    ///
    /// - Parameter automatic: Entered on switching to another app. The window keeps its full screen then,
    ///   since leaving it would pull the user back to its Space.
    func enterPictureInPicture(automatic: Bool = false) {
        guard !isPictureInPicture, !closed else {
            return
        }
        if case .failed = phase {
            return
        }
        let window = engine?.videoView.window ?? NSApp.mainWindow
        mainWindow = window
        // Undo the automatic full screen, like closing the player does.
        if !automatic, isFullScreen, app.settings.openPlayerFullScreen {
            window?.toggleFullScreen(nil)
        }
        isPictureInPicture = true
        isAutomaticPictureInPicture = automatic
        isInteractingWithControls = false
        hideControlsTask?.cancel()
        NSCursor.setHiddenUntilMouseMoves(false)
        let panel = PictureInPictureWindow(model: self, app: app, aspectRatio: videoAspectRatio, on: window?.screen)
        pictureInPicture = panel
        // Without taking focus, so the main window stays ready for browsing.
        panel.orderFrontRegardless()
    }

    /// Brings the video back into the full player.
    func exitPictureInPicture(enterFullScreen: Bool = false) {
        guard isPictureInPicture else {
            return
        }
        // Automatic picture in picture left the window's full screen as it was.
        let restoresFullScreen = enterFullScreen || (app.settings.openPlayerFullScreen && !isAutomaticPictureInPicture)
        isPictureInPicture = false
        isAutomaticPictureInPicture = false
        pictureInPicture?.dismiss()
        pictureInPicture = nil
        let window = mainWindow ?? NSApp.mainWindow
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if restoresFullScreen, let window, !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        userActivity()
    }

    /// Replaces the current item without dismissing the player.
    private func switchTo(_ next: BaseItem, queue: [BaseItem]) {
        recordOfflineProgress()
        send(.stopped, stopReport())
        engine?.stop()
        engine = nil
        item = next
        self.queue = queue
        startAt = next.hasResumePosition ? next.resumePosition : 0
        mediaSource = nil
        playSessionId = nil
        offlineCopy = nil
        position = 0
        duration = next.duration ?? 0
        chapters = []
        segments = []
        upNext = nil
        upNextDismissed = false
        activeSegment = nil
        subtitleText = nil
        appSubtitles = [:]
        appSubtitleIndex = nil
        skippedSegments = []
        hasReportedStart = false
        hasEnded = false
        triedFallback = false
        trickplayCache = [:]
        serverPlayMethod = nil
        serverTranscoding = nil
        bufferHistory = []
        tasks.append(Task { await load() })
        userActivity()
    }

    // MARK: - Tracks

    private func refreshTracks() {
        guard let engine else {
            audioOptions = []
            subtitleOptions = []
            return
        }
        audioOptions = engine.audioTracks
        if engine.rendersSubtitles {
            subtitleOptions = engine.subtitleTracks
        } else {
            subtitleOptions = appSubtitleStreams.map { stream in
                let index = stream.index ?? -1
                var detail: [String] = []
                if let language = stream.language {
                    detail.append(Locale.current.localizedString(forLanguageCode: language) ?? language)
                }
                if stream.isExternal == true {
                    detail.append(String(localized: "External"))
                }
                return TrackOption(id: String(index), title: stream.displayTitle ?? stream.title ?? String(localized: "Subtitle \(index)"),
                                   detail: detail.joined(separator: " · "), isSelected: appSubtitleIndex == index)
            }
        }
    }

    /// Text subtitles the server can convert to WebVTT for app-side rendering.
    private var appSubtitleStreams: [MediaStream] {
        (mediaSource?.mediaStreams ?? []).filter { $0.type == "Subtitle" && $0.isTextSubtitleStream != false && $0.index != nil }
    }

    private func selectDefaultAppSubtitle() {
        guard let engine, !engine.rendersSubtitles, app.settings.subtitlesEnabled else {
            return
        }
        let streams = appSubtitleStreams
        let language = app.settings.preferredSubtitleLanguage
        let match = streams.first { !language.isEmpty && ($0.language ?? "").hasPrefix(language) }
            ?? streams.first { $0.isDefault == true || $0.isForced == true }
            ?? streams.first
        if let index = match?.index {
            selectAppSubtitle(index)
        }
    }

    private func selectAppSubtitle(_ index: Int?) {
        appSubtitleIndex = index
        subtitleText = nil
        refreshTracks()
        guard let index, appSubtitles[index] == nil, let source = mediaSource else {
            return
        }
        if let offlineCopy {
            if let file = offlineCopy.subtitleURL(streamIndex: index, format: "vtt"), let text = try? String(contentsOf: file, encoding: .utf8) {
                appSubtitles[index] = SubtitleCues(text: text)
                positionChanged()
            }
            return
        }
        let url = client.subtitleURL(itemId: item.id, mediaSourceId: source.id, streamIndex: index, format: "vtt")
        Task {
            var request = URLRequest(url: url)
            request.setValue(client.authorizationHeader, forHTTPHeaderField: "Authorization")
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let text = String(data: data, encoding: .utf8)
            else {
                return
            }
            appSubtitles[index] = SubtitleCues(text: text)
            positionChanged()
        }
    }

    // MARK: - Reporting

    private enum ReportKind {
        case start
        case progress
        case stopped
    }

    /// Sends playback reports strictly in order, so "stopped" never overtakes "progress".
    private func send(_ kind: ReportKind, _ report: PlaybackReport) {
        let previous = reportChain
        let client = client
        let downloads = app.downloads
        reportChain = Task {
            await previous?.value
            switch kind {
            case .start: await client.reportPlaybackStart(report)
            case .progress: await client.reportPlaybackProgress(report)
            case .stopped:
                if await client.reportPlaybackStopped(report) {
                    downloads.markSynced(report.itemId)
                }
            }
        }
    }

    private func progressReport() -> PlaybackReport {
        PlaybackReport(
            itemId: item.id,
            mediaSourceId: mediaSource?.id,
            playSessionId: playSessionId,
            positionTicks: position.ticks,
            isPaused: isPaused,
            isMuted: isMuted,
            volumeLevel: Int(volume),
            canSeek: true,
            playMethod: "DirectPlay"
        )
    }

    private func stopReport() -> PlaybackReport {
        var report = progressReport()
        report.isPaused = nil
        report.isMuted = nil
        report.volumeLevel = nil
        report.canSeek = nil
        if case .failed = phase {
            report.failed = true
        }
        return report
    }

    /// Saves the position every 10 seconds so resume works even after a crash.
    private func reportLoop() async {
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else {
                return
            }
            tick += 1
            bufferHistory.append(bufferedAhead)
            if bufferHistory.count > 120 {
                bufferHistory.removeFirst(bufferHistory.count - 120)
            }
            if phase == .playing, tick % 10 == 0, abs(position - lastReportedPosition) > 1 {
                lastReportedPosition = position
                send(.progress, progressReport())
                updateNowPlaying()
            }
            if phase == .playing, tick == 5 || tick % 30 == 0 {
                await verifyServerSession()
            }
        }
    }

    private func verifyServerSession() async {
        guard let session = try? await client.ownSession() else {
            return
        }
        serverPlayMethod = session.playState?.playMethod
        serverTranscoding = session.transcodingInfo
    }

    private func statsLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(750))
            if showStats {
                refreshStats()
            }
        }
    }

    func refreshStats() {
        var sections: [StatSection] = []
        var playback: [StatRow] = []
        if offlineCopy != nil {
            // Nothing is streamed, so there is no server play method to verify.
            playback.append(StatRow(label: String(localized: "Play method"), value: String(localized: "Downloaded file (offline)"), highlight: .good))
        } else {
            playback.append(StatRow(label: String(localized: "Play method"), value: String(localized: "Direct Play (original file, static stream)"), highlight: .good))
            if let transcoding = serverTranscoding {
                let reasons = (transcoding.transcodeReasons ?? []).joined(separator: ", ")
                playback.append(StatRow(label: String(localized: "Server"), value: String(localized: "Transcoding! \(reasons)"), highlight: .warning))
            } else if let method = serverPlayMethod {
                playback.append(StatRow(label: String(localized: "Server"), value: String(localized: "\(method) · no transcoding"), highlight: .good))
            } else {
                playback.append(StatRow(label: String(localized: "Server"), value: String(localized: "Verifying…")))
            }
        }
        if let engineKind {
            playback.append(StatRow(label: String(localized: "Player"), value: "\(engineKind.rawValue) — \(engineReason)"))
        }
        playback.append(StatRow(label: String(localized: "Position"), value: "\(Format.time(position)) / \(Format.time(duration))"))
        if rate != 1 {
            playback.append(StatRow(label: String(localized: "Speed"), value: String(format: "%.2g×", rate)))
        }
        sections.append(StatSection(title: String(localized: "Playback"), rows: playback))

        if let source = mediaSource {
            var file: [StatRow] = []
            if let path = source.path {
                file.append(StatRow(label: String(localized: "File"), value: (path as NSString).lastPathComponent))
            }
            if let container = source.container {
                file.append(StatRow(label: String(localized: "Container"), value: container.uppercased()))
            }
            if let size = source.size {
                file.append(StatRow(label: String(localized: "Size"), value: Format.bytes(Double(size))))
            }
            if let bitrate = source.bitrate {
                file.append(StatRow(label: String(localized: "Bitrate"), value: Format.bitrate(Double(bitrate))))
            }
            let streams = source.mediaStreams ?? []
            if let video = streams.first(where: { $0.type == "Video" }) {
                file.append(StatRow(label: String(localized: "Video"), value: MediaDescription.video(video)))
            }
            if let audio = streams.first(where: { $0.type == "Audio" && $0.isDefault == true }) ?? streams.first(where: { $0.type == "Audio" }) {
                file.append(StatRow(label: String(localized: "Audio"), value: MediaDescription.audio(audio)))
            }
            let subtitleCount = streams.filter { $0.type == "Subtitle" }.count
            if subtitleCount > 0 {
                file.append(StatRow(label: String(localized: "Subtitles"), value: String(localized: "\(subtitleCount) tracks")))
            }
            sections.append(StatSection(title: String(localized: "Source"), rows: file))
        }
        sections += engine?.collectStats() ?? []
        statsSections = sections.filter { !$0.rows.isEmpty }
    }

    // MARK: - Trickplay

    var trickplayInfo: (width: Int, info: TrickplayInfo)? {
        guard let sourceId = mediaSource?.id, let byWidth = item.trickplay?[sourceId] ?? item.trickplay?.values.first else {
            return nil
        }
        let candidates = byWidth.compactMap { key, value in Int(key).map { ($0, value) } }.sorted { $0.0 < $1.0 }
        guard let best = candidates.first(where: { $0.0 >= 320 }) ?? candidates.last else {
            return nil
        }
        return (best.0, best.1)
    }

    /// The preview thumbnail for a position, cut from the server's trickplay tile sheet.
    func trickplayThumbnail(at seconds: Double) async -> CGImage? {
        guard let (width, info) = trickplayInfo, let sourceId = mediaSource?.id,
              let interval = info.interval, interval > 0,
              let columns = info.tileWidth, let rows = info.tileHeight, columns > 0, rows > 0
        else {
            return nil
        }
        let index = Int(seconds * 1000) / interval
        let perSheet = columns * rows
        let sheetIndex = index / perSheet
        let sheet: CGImage
        if let cached = trickplayCache[sheetIndex] {
            sheet = cached
        } else {
            let url = client.trickplayTileURL(itemId: item.id, mediaSourceId: sourceId, width: width, index: sheetIndex)
            guard let image = await ImageLoader.shared.image(for: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return nil
            }
            trickplayCache[sheetIndex] = image
            sheet = image
        }
        let tile = index % perSheet
        let thumbWidth = sheet.width / columns
        let thumbHeight = info.height.map { min($0, sheet.height / rows) } ?? sheet.height / rows
        let rect = CGRect(x: (tile % columns) * thumbWidth, y: (tile / columns) * thumbHeight, width: thumbWidth, height: thumbHeight)
        return sheet.cropping(to: rect)
    }

    // MARK: - Controls visibility

    func userActivity() {
        controlsVisible = true
        hideControlsTask?.cancel()
        hideControlsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else {
                return
            }
            if !self.isPaused, self.phase == .playing, !self.isInteractingWithControls {
                self.controlsVisible = false
                // While browsing next to the floating window, the cursor must stay visible.
                if !self.isPictureInPicture {
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            }
        }
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = KeyPress(code: event.keyCode, characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags, window: event.window)
            let handled = MainActor.assumeIsolated {
                self?.handleKey(key) ?? false
            }
            return handled ? nil : event
        }
    }

    private struct KeyPress {
        var code: UInt16
        var characters: String?
        var modifiers: NSEvent.ModifierFlags
        var window: NSWindow?
    }

    private func handleKey(_ key: KeyPress) -> Bool {
        // Leave shortcuts with Command to the menu bar and text input to text fields.
        if key.modifiers.contains(.command) || NSApp.keyWindow?.firstResponder is NSTextView {
            return false
        }
        if isPictureInPicture {
            // Keys typed while browsing belong to the main window, not to playback.
            guard let window = key.window, window === pictureInPicture else {
                return false
            }
            if key.code == 53 {
                exitPictureInPicture()
                return true
            }
        }
        let shift = key.modifiers.contains(.shift)
        switch key.code {
        case 49: togglePause()
        case 123: skip(by: shift ? -60 : -10)
        case 124: skip(by: shift ? 60 : 10)
        case 126: adjustVolume(by: 5)
        case 125: adjustVolume(by: -5)
        case 53:
            if isFullScreen {
                toggleFullScreen()
            } else {
                close()
            }
        case 36:
            if activeSegment != nil {
                skipActiveSegment()
            } else if upNext != nil {
                playNext()
            } else {
                return false
            }
        default:
            switch key.characters?.lowercased() {
            case "k": togglePause()
            case "j": skip(by: -10)
            case "l": skip(by: 10)
            case "f": toggleFullScreen()
            case "p": togglePictureInPicture()
            case "m": toggleMute()
            case "i": toggleStats()
            case "n": playNext()
            case "s":
                if activeSegment != nil {
                    skipActiveSegment()
                }
            case "c": cycleSubtitles()
            case "[": setRate(max(0.25, rate - 0.25))
            case "]": setRate(min(3, rate + 0.25))
            case "=": setRate(1)
            default: return false
            }
        }
        userActivity()
        return true
    }

    private func cycleSubtitles() {
        let options = subtitleOptions
        guard !options.isEmpty else {
            return
        }
        if let current = options.firstIndex(where: \.isSelected) {
            selectSubtitle(current + 1 < options.count ? options[current + 1].id : nil)
        } else {
            selectSubtitle(options[0].id)
        }
    }

    // MARK: - System integration

    private func observeWindow() {
        let center = NotificationCenter.default
        isFullScreen = NSApp.mainWindow?.styleMask.contains(.fullScreen) ?? false
        windowObservers = [
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isFullScreen = true }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isFullScreen = false }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationDidBecomeActive() }
            },
        ]
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.otherApplicationDidActivate(application) }
        }
    }

    /// Keeps a playing video in view while another app is in front.
    ///
    /// Menu bar apps and other agents activate on interaction without covering the window,
    /// so only regular apps trigger picture in picture.
    private func otherApplicationDidActivate(_ application: NSRunningApplication?) {
        guard let application, application != .current, application.activationPolicy == .regular,
              app.settings.autoPictureInPicture, !isPictureInPicture, !isPaused, phase == .playing,
              engine?.videoView.window?.isVisible == true
        else {
            return
        }
        enterPictureInPicture(automatic: true)
    }

    /// Returns to the full player, unless picture in picture was entered by hand.
    private func applicationDidBecomeActive() {
        guard isAutomaticPictureInPicture else {
            return
        }
        exitPictureInPicture()
    }

    private func updateActivity() {
        if isPaused {
            endActivity()
        } else if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Playing video")
        }
    }

    private func endActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePause() }
            return .success
        }
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.engine?.play() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.engine?.pause() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playNext() }
            return .success
        }
        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: 10) }
            return .success
        }
        commands.skipBackwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: -10) }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.displayName,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0 : rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let series = item.seriesName {
            info[MPMediaItemPropertyArtist] = series
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPaused ? .paused : .playing
    }
}

/// Human-readable summaries of Jellyfin stream metadata.
enum MediaDescription {
    static func codecName(_ codec: String?) -> String {
        switch (codec ?? "").lowercased() {
        case "h264", "avc": "H.264"
        case "hevc", "h265": "HEVC"
        case "av1": "AV1"
        case "vp9": "VP9"
        case "vp8": "VP8"
        case "mpeg2video": "MPEG-2"
        case "aac": "AAC"
        case "ac3": "Dolby Digital"
        case "eac3": "Dolby Digital+"
        case "truehd": "TrueHD"
        case "dts": "DTS"
        case "opus": "Opus"
        case "vorbis": "Vorbis"
        case "flac": "FLAC"
        case "mp3": "MP3"
        case "": String(localized: "Unknown")
        case let other: other.uppercased()
        }
    }

    static func resolutionLabel(_ stream: MediaStream?) -> String? {
        guard let width = stream?.width, let height = stream?.height else {
            return nil
        }
        switch max(width, height * 16 / 9) {
        case 3800...: return "4K"
        case 2500...: return "1440p"
        case 1900...: return "1080p"
        case 1260...: return "720p"
        default: return "\(height)p"
        }
    }

    static func rangeLabel(_ stream: MediaStream?) -> String? {
        guard let type = stream?.videoRangeType, type != "SDR", type != "Unknown" else {
            return nil
        }
        if type.hasPrefix("DOVI") {
            return "Dolby Vision"
        }
        switch type {
        case "HDR10Plus": return "HDR10+"
        default: return type
        }
    }

    static func video(_ stream: MediaStream) -> String {
        var parts = [codecName(stream.codec)]
        if let profile = stream.profile {
            parts[0] += " \(profile)"
        }
        if let width = stream.width, let height = stream.height {
            parts.append("\(width)×\(height)")
        }
        if let fps = stream.realFrameRate ?? stream.averageFrameRate {
            parts.append(String(format: "%.3g fps", fps))
        }
        if let depth = stream.bitDepth {
            parts.append("\(depth)-bit")
        }
        parts.append(rangeLabel(stream) ?? "SDR")
        return parts.joined(separator: " · ")
    }

    static func audio(_ stream: MediaStream) -> String {
        var parts = [codecName(stream.codec)]
        if let layout = stream.channelLayout {
            parts.append(layout)
        } else if let channels = stream.channels {
            parts.append(channelDescription(channels))
        }
        if let language = stream.language {
            parts.append(Locale.current.localizedString(forLanguageCode: language) ?? language)
        }
        return parts.joined(separator: " · ")
    }
}
