import AppKit
import AVFoundation
import os

/// Apple's player, used for MP4/MOV files with codecs macOS decodes natively.
@MainActor
final class AVPlayerEngine: PlaybackEngine {
    let kind = EngineKind.avPlayer
    var onEvent: ((EngineEvent) -> Void)?
    var videoView: NSView { view }
    let rendersSubtitles = false

    /// Buffer diagnostics, readable with
    /// `log stream --level info --predicate 'subsystem == "media.kitt.JellyJelly"'`.
    private static let log = Logger(subsystem: "media.kitt.JellyJelly", category: "AVPlayer")

    private let player = AVPlayer()
    private let view = PlayerLayerView()
    private var item: AVPlayerItem?
    /// Streams go through a disk cache; downloaded files play straight from disk.
    private var cache: StreamCache?
    /// The video track, for looking up where the file stores a point in time.
    private var sampleTrack: AVAssetTrack?
    private var readAheadSeconds: Double = 0
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var startAt: Double = 0
    private var didLoad = false
    private var stallCount = 0
    private var rate: Float = 1
    private var audioGroup: AVMediaSelectionGroup?
    private var lastBufferingState: Bool?
    private var trackInfo: [TrackInfo] = []
    private var lastBufferedAhead: Double = 0
    private var seeking = false

    private struct TrackInfo {
        var trackID: CMPersistentTrackID
        var isVideo: Bool
        var codec: String
        var frameRate: Float
        var dataRate: Float
        var channels: Int?
        var sampleRate: Double?
    }

    static let nativeContainers: Set<String> = ["mp4", "m4v", "mov"]
    static let nativeVideoCodecs: Set<String> = ["h264", "avc", "avc1", "hevc", "h265", "hvc1", "hev1"]
    static let nativeAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac", "flac"]

    /// Whether AVFoundation can open this file directly, without help from the server.
    static func canPlay(_ source: MediaSource) -> Bool {
        let containers = (source.container ?? "").lowercased().split(separator: ",").map(String.init)
        guard containers.contains(where: nativeContainers.contains) else {
            return false
        }
        let streams = source.mediaStreams ?? []
        guard let video = streams.first(where: { $0.type == "Video" }),
              nativeVideoCodecs.contains((video.codec ?? "").lowercased())
        else {
            return false
        }
        let audio = streams.filter { $0.type == "Audio" }
        return audio.allSatisfy { nativeAudioCodecs.contains(($0.codec ?? "").lowercased()) }
    }

    init() {
        view.playerLayer.player = player
        player.automaticallyWaitsToMinimizeStalling = true
        player.preventsDisplaySleepDuringVideoPlayback = true
        player.appliesMediaSelectionCriteriaAutomatically = true
    }

    func load(_ source: PlaybackSource) {
        let cache = source.url.isFileURL ? nil : StreamCache(url: source.url, headers: source.headers, readAheadSeconds: source.bufferAheadSeconds)
        self.cache = cache
        readAheadSeconds = Double(max(30, source.bufferAheadSeconds))
        let asset = AVURLAsset(url: cache?.assetURL ?? source.url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": source.headers,
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
        ])
        if let cache {
            asset.resourceLoader.setDelegate(cache, queue: cache.queue)
        }
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = TimeInterval(source.bufferAheadSeconds)
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        self.item = item
        startAt = source.startAt
        player.volume = Float(source.volume / 100)
        if !source.preferredAudioLanguage.isEmpty {
            let criteria = AVPlayerMediaSelectionCriteria(preferredLanguages: [source.preferredAudioLanguage], preferredMediaCharacteristics: nil)
            player.setMediaSelectionCriteria(criteria, forMediaCharacteristic: .audible)
        }
        observe(item)
        player.replaceCurrentItem(with: item)

        Task { [weak self] in
            if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
                self?.audioGroup = group
                self?.onEvent?(.tracksChanged)
            }
            await self?.loadTrackInfo(asset)
        }
    }

    private func observe(_ item: AVPlayerItem) {
        observations = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                DispatchQueue.main.async {
                    self?.statusChanged(item)
                }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                DispatchQueue.main.async {
                    self?.timeControlChanged()
                }
            },
            item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.reportBufferedAhead()
                }
            },
            item.observe(\.duration, options: [.new]) { [weak self] item, _ in
                DispatchQueue.main.async {
                    let seconds = item.duration.seconds
                    if seconds.isFinite, seconds > 0 {
                        self?.onEvent?(.duration(seconds))
                    }
                }
            },
        ]
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onEvent?(.ended)
                }
            },
            center.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.stallCount += 1
                    Self.log.warning("Stalled: \(self.bufferSnapshot, privacy: .public)")
                }
            },
            center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                MainActor.assumeIsolated {
                    self?.onEvent?(.failed(error?.localizedDescription ?? String(localized: "Playback failed.")))
                }
            },
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.didLoad else {
                    return
                }
                self.onEvent?(.time(time.seconds))
                if let cache = self.cache, let duration = self.item?.duration.seconds {
                    cache.updatePlayhead(time.seconds, duration: duration,
                                         byteOffset: self.byteOffset(at: time.seconds),
                                         readAheadByteOffset: self.byteOffset(at: min(duration, time.seconds + self.readAheadSeconds)))
                    self.reportBufferedAhead()
                }
            }
        }
    }

    private func statusChanged(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay where !didLoad:
            didLoad = true
            let duration = item.duration.seconds
            onEvent?(.loaded(duration: duration.isFinite ? duration : nil))
            if startAt > 0 {
                player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.player.playImmediately(atRate: self?.rate ?? 1)
                    }
                }
            } else {
                player.playImmediately(atRate: rate)
            }
        case .failed:
            onEvent?(.failed(item.error?.localizedDescription ?? String(localized: "AVPlayer could not open this file.")))
        default:
            break
        }
    }

    private func timeControlChanged() {
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            && player.reasonForWaitingToPlay != .noItemToPlay
        if waiting != lastBufferingState {
            lastBufferingState = waiting
            onEvent?(.buffering(waiting, progress: nil))
            if waiting, !seeking {
                let reason = player.reasonForWaitingToPlay?.rawValue ?? "unknown"
                Self.log.warning("Waiting (\(reason, privacy: .public)): \(self.bufferSnapshot, privacy: .public)")
            }
        }
        onEvent?(.paused(player.timeControlStatus == .paused))
    }

    private var bufferedAhead: Double {
        guard let item else {
            return 0
        }
        let now = item.currentTime().seconds
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = (range.start + range.duration).seconds
            if now >= start - 0.5, now <= end {
                return max(0, end - now)
            }
        }
        return 0
    }

    private func reportBufferedAhead() {
        let ahead = bufferedAhead
        // While it renders video, AVPlayer now and then drops a block just ahead of the playhead.
        // The stream cache has it on disk, so this only stalls playback without one.
        if lastBufferedAhead >= 30, ahead < 5, !seeking {
            Self.log.info("Player buffer collapsed from \(self.lastBufferedAhead, format: .fixed(precision: 1), privacy: .public) s: \(self.bufferSnapshot, privacy: .public)")
        }
        lastBufferedAhead = ahead
        onEvent?(.bufferedAhead(max(ahead, cache?.statistics.cachedAheadSeconds ?? 0)))
    }

    /// The playhead, every loaded range, AVPlayer's own buffer verdicts, and the stream cache.
    private var bufferSnapshot: String {
        guard let item else {
            return "no item"
        }
        let ranges = item.loadedTimeRanges.map { value in
            let range = value.timeRangeValue
            return String(format: "%.1f–%.1f", range.start.seconds, (range.start + range.duration).seconds)
        }
        var snapshot = String(format: "position %.1f, ", item.currentTime().seconds)
            + "ranges [\(ranges.joined(separator: ", "))], "
            + "likely to keep up \(item.isPlaybackLikelyToKeepUp), buffer empty \(item.isPlaybackBufferEmpty)"
        if let ahead = cache?.statistics.cachedAheadSeconds {
            snapshot += String(format: ", cached ahead %.1f s", ahead)
        }
        return snapshot
    }

    // MARK: - Controls

    func play() {
        player.playImmediately(atRate: rate)
    }

    func pause() {
        player.pause()
    }

    func seek(to seconds: Double) {
        seeking = true
        onEvent?(.buffering(true, progress: nil))
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.seeking = false
                self?.lastBufferingState = nil
                self?.timeControlChanged()
            }
        }
    }

    func setRate(_ rate: Double) {
        self.rate = Float(rate)
        if player.timeControlStatus != .paused {
            player.rate = Float(rate)
        }
    }

    func setVolume(_ volume: Double) {
        player.volume = Float(volume / 100)
    }

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
    }

    func setSubtitleScale(_ scale: Double) {}

    var audioTracks: [TrackOption] {
        guard let item, let group = audioGroup else {
            return []
        }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        return group.options.enumerated().map { index, option in
            let language = option.locale.flatMap { Locale.current.localizedString(forLanguageCode: $0.identifier) }
            return TrackOption(id: String(index), title: option.displayName, detail: language, isSelected: option == selected)
        }
    }

    var subtitleTracks: [TrackOption] { [] }

    func selectAudioTrack(_ id: String) {
        guard let item, let group = audioGroup, let index = Int(id), group.options.indices.contains(index) else {
            return
        }
        item.select(group.options[index], in: group)
        onEvent?(.tracksChanged)
    }

    func selectSubtitleTrack(_ id: String?) {}

    func stop() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        observations.forEach { $0.invalidate() }
        observations = []
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens = []
        player.pause()
        player.replaceCurrentItem(with: nil)
        item = nil
        cache?.close()
        cache = nil
    }

    // MARK: - Stats

    func collectStats() -> [StatSection] {
        guard let item else {
            return []
        }
        var video: [StatRow] = []
        var audio: [StatRow] = []
        let enabledAudio = Set(item.tracks.filter { $0.isEnabled && $0.assetTrack?.mediaType == .audio }.compactMap { $0.assetTrack?.trackID })
        for track in trackInfo {
            if track.isVideo {
                video.append(StatRow(label: String(localized: "Codec"), value: track.codec))
                let size = item.presentationSize
                video.append(StatRow(label: String(localized: "Resolution"), value: "\(Int(size.width))×\(Int(size.height))"))
                video.append(StatRow(label: String(localized: "Frame rate"), value: String(format: "%.3f fps", track.frameRate)))
                if track.dataRate > 0 {
                    video.append(StatRow(label: String(localized: "Bitrate"), value: Format.bitrate(Double(track.dataRate))))
                }
                video.append(StatRow(label: String(localized: "Decoder"), value: String(localized: "VideoToolbox (hardware)"), highlight: .good))
            } else if enabledAudio.contains(track.trackID) {
                audio.append(StatRow(label: String(localized: "Codec"), value: track.codec))
                if let channels = track.channels, let sampleRate = track.sampleRate {
                    audio.append(StatRow(label: String(localized: "Channels"), value: "\(channelDescription(channels)) · \(Int(sampleRate)) Hz"))
                }
                if track.dataRate > 0 {
                    audio.append(StatRow(label: String(localized: "Bitrate"), value: Format.bitrate(Double(track.dataRate))))
                }
            }
        }
        if let event = item.accessLog()?.events.last, event.numberOfDroppedVideoFrames >= 0 {
            video.append(StatRow(label: String(localized: "Dropped frames"), value: "\(event.numberOfDroppedVideoFrames)",
                                 highlight: event.numberOfDroppedVideoFrames > 0 ? .warning : .good))
        }

        var buffer: [StatRow] = []
        let playerAhead = bufferedAhead
        let cacheStatistics = cache?.statistics
        let ahead = max(playerAhead, cacheStatistics?.cachedAheadSeconds ?? 0)
        buffer.append(StatRow(label: String(localized: "Buffered ahead"), value: String(format: "%.1f s", ahead), highlight: ahead > 10 ? .good : .warning))
        buffer.append(StatRow(label: String(localized: "Target buffer"), value: "\(Int(item.preferredForwardBufferDuration)) s"))
        if let cacheStatistics {
            buffer.append(StatRow(label: String(localized: "Player buffer"), value: String(format: "%.1f s", playerAhead)))
            buffer.append(StatRow(label: String(localized: "Cache (forward)"), value: Format.bytes(Double(cacheStatistics.cachedAheadBytes))))
            buffer.append(StatRow(label: String(localized: "Cache (total)"), value: Format.bytes(Double(cacheStatistics.cachedBytes))))
            buffer.append(StatRow(label: String(localized: "Download rate"), value: Format.bitrate(cacheStatistics.downloadRate * 8)))
            buffer.append(StatRow(label: String(localized: "Transferred"), value: Format.bytes(Double(cacheStatistics.downloadedBytes))))
            buffer.append(StatRow(label: String(localized: "Reading"),
                                  value: cacheStatistics.isDownloading ? String(localized: "Downloading") : String(localized: "Idle (buffer full)")))
            buffer.append(StatRow(label: String(localized: "Network errors"),
                                  value: cacheStatistics.lastError.map { String(localized: "\(cacheStatistics.errorCount) · last: \($0)") } ?? "0",
                                  highlight: cacheStatistics.errorCount > 0 ? .warning : .good))
        } else if let event = item.accessLog()?.events.last {
            if event.observedBitrate > 0 {
                buffer.append(StatRow(label: String(localized: "Download rate"), value: Format.bitrate(event.observedBitrate)))
            }
            if event.numberOfBytesTransferred > 0 {
                buffer.append(StatRow(label: String(localized: "Transferred"), value: Format.bytes(Double(event.numberOfBytesTransferred))))
            }
        }
        buffer.append(StatRow(label: String(localized: "Stalls"), value: "\(stallCount)", highlight: stallCount > 0 ? .warning : .good))
        buffer.append(StatRow(label: String(localized: "Likely to keep up"), value: item.isPlaybackLikelyToKeepUp ? String(localized: "Yes") : String(localized: "No"),
                              highlight: item.isPlaybackLikelyToKeepUp ? .good : .warning))
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate, let reason = player.reasonForWaitingToPlay {
            buffer.append(StatRow(label: String(localized: "Waiting"), value: reason.rawValue, highlight: .warning))
        }

        return [
            StatSection(title: String(localized: "Video"), rows: video),
            StatSection(title: String(localized: "Audio"), rows: audio),
            StatSection(title: String(localized: "Buffer"), rows: buffer),
            StatSection(title: String(localized: "Engine"), rows: [StatRow(label: String(localized: "Engine"), value: "AVFoundation (AVPlayer)")]),
        ]
    }

    private func loadTrackInfo(_ asset: AVURLAsset) async {
        guard let tracks = try? await asset.load(.tracks) else {
            return
        }
        var info: [TrackInfo] = []
        for track in tracks where track.mediaType == .video || track.mediaType == .audio {
            guard let (descriptions, frameRate, dataRate) = try? await track.load(.formatDescriptions, .nominalFrameRate, .estimatedDataRate) else {
                continue
            }
            let description = descriptions.first
            let basic = description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            info.append(TrackInfo(
                trackID: track.trackID,
                isVideo: track.mediaType == .video,
                codec: description.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?",
                frameRate: frameRate,
                dataRate: dataRate,
                channels: basic.map { Int($0.mChannelsPerFrame) },
                sampleRate: basic?.mSampleRate
            ))
            if track.mediaType == .video, cache != nil, (try? await track.load(.canProvideSampleCursors)) == true {
                sampleTrack = track
            }
        }
        trackInfo = info
    }

    /// Where the file stores the video at `seconds`, so the stream cache knows exactly which bytes the playhead needs.
    private func byteOffset(at seconds: Double) -> Int? {
        guard let sampleTrack, seconds.isFinite,
              let cursor = sampleTrack.makeSampleCursor(presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600))
        else {
            return nil
        }
        let range = cursor.currentChunkStorageRange
        return range.length > 0 ? Int(range.offset) : nil
    }

    private func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(code)"
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer = playerLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
