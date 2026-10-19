import AppKit
import Foundation

/// Plays any container/codec FFmpeg understands, straight from the original file.
@MainActor
final class MPVEngine: PlaybackEngine {
    let kind = EngineKind.mpv
    var onEvent: ((EngineEvent) -> Void)?
    var videoView: NSView { view }
    let rendersSubtitles = true

    private let lib: LibMPV
    private var handle: OpaquePointer?
    private let view: MPVVideoView
    private var wakeupBox: Unmanaged<WeakEngineBox>?
    private var pendingSubtitles: [ExternalSubtitle] = []
    private var subtitlesEnabled = false
    private var preferredSubtitleLanguage = ""
    private var didLoad = false
    private var pausedForCache = false
    private var seeking = false
    private var cacheProgress: Double?
    private var stallCount = 0
    private var basePrebuffer = 3
    private var currentPrebuffer = 3

    private enum Observed: UInt64 {
        case timePos = 1
        case duration
        case pause
        case pausedForCache
        case cacheBufferingState
        case demuxerCacheDuration
        case trackList
        case eofReached
        case seeking
    }

    static var isAvailable: Bool { LibMPV.shared != nil }

    init?() {
        guard let lib = LibMPV.shared, let handle = lib.create() else {
            return nil
        }
        self.lib = lib
        self.handle = handle
        self.view = MPVVideoView(lib: lib)
    }

    private func configure(_ source: PlaybackSource) -> Bool {
        guard let handle else {
            return false
        }
        let options: [(String, String)] = [
            ("vo", "libmpv"),
            // Required when rendering without blocking for the frame's target time.
            ("video-timing-offset", "0"),
            ("hwdec", source.hardwareDecoding ? "auto-safe" : "no"),
            ("config", "no"),
            ("load-scripts", "no"),
            ("ytdl", "no"),
            ("osc", "no"),
            ("osd-level", "0"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("terminal", "no"),
            ("msg-level", "all=warn"),
            ("idle", "yes"),
            ("keep-open", "yes"),
            ("audio-client-name", "JellyJelly"),
            ("user-agent", "JellyJelly/\(ClientIdentity.current.version)"),
            // Buffering: read far ahead into RAM, keep some history for quick back-seeks,
            // and refill a few seconds before (re)starting so playback doesn't stutter.
            ("cache", "yes"),
            ("cache-secs", String(source.bufferAheadSeconds)),
            ("demuxer-readahead-secs", String(source.bufferAheadSeconds)),
            ("demuxer-max-bytes", "\(source.cacheSizeMB)MiB"),
            ("demuxer-max-back-bytes", "\(max(64, source.cacheSizeMB / 4))MiB"),
            ("demuxer-seekable-cache", "yes"),
            ("cache-pause", "yes"),
            ("cache-pause-initial", "yes"),
            ("cache-pause-wait", String(max(1, source.prebufferSeconds))),
            ("network-timeout", "30"),
            ("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=15"),
            ("alang", source.preferredAudioLanguage),
            ("slang", source.preferredSubtitleLanguage),
            ("sid", source.subtitlesEnabled ? "auto" : "no"),
            ("sub-auto", "no"),
            ("volume", String(Int(source.volume))),
            ("volume-max", "100"),
        ]
        for (name, value) in options where !value.isEmpty {
            lib.setOption(handle, name, value)
        }
        for (name, value) in source.headers {
            lib.setOption(handle, "http-header-fields-append", "\(name): \(value)")
        }
        guard lib.initialize(handle) >= 0 else {
            return false
        }

        observe(.timePos, "time-pos", MPV_FORMAT_DOUBLE)
        observe(.duration, "duration", MPV_FORMAT_DOUBLE)
        observe(.pause, "pause", MPV_FORMAT_FLAG)
        observe(.pausedForCache, "paused-for-cache", MPV_FORMAT_FLAG)
        observe(.cacheBufferingState, "cache-buffering-state", MPV_FORMAT_INT64)
        observe(.demuxerCacheDuration, "demuxer-cache-duration", MPV_FORMAT_DOUBLE)
        observe(.trackList, "track-list", MPV_FORMAT_NONE)
        observe(.eofReached, "eof-reached", MPV_FORMAT_FLAG)
        observe(.seeking, "seeking", MPV_FORMAT_FLAG)

        let box = Unmanaged.passRetained(WeakEngineBox(self))
        wakeupBox = box
        lib.setWakeupCallback(handle, { context in
            guard let context else {
                return
            }
            let box = Unmanaged<WeakEngineBox>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    box.engine?.drainEvents()
                }
            }
        }, box.toOpaque())

        view.glLayer.attach(handle)
        return true
    }

    private func observe(_ id: Observed, _ name: String, _ format: mpv_format) {
        _ = lib.observeProperty(handle, id.rawValue, name, format)
    }

    // MARK: - PlaybackEngine

    func load(_ source: PlaybackSource) {
        basePrebuffer = max(1, source.prebufferSeconds)
        currentPrebuffer = basePrebuffer
        guard configure(source) else {
            onEvent?(.failed(String(localized: "mpv could not be initialized.")))
            return
        }
        pendingSubtitles = source.externalSubtitles
        subtitlesEnabled = source.subtitlesEnabled
        preferredSubtitleLanguage = source.preferredSubtitleLanguage
        lib.set(handle, "start", source.startAt > 0 ? String(format: "%.3f", source.startAt) : "none")
        lib.set(handle, "pause", "no")
        lib.command(handle, ["loadfile", source.url.absoluteString, "replace"])
    }

    func play() {
        lib.set(handle, "pause", "no")
    }

    func pause() {
        lib.set(handle, "pause", "yes")
    }

    func seek(to seconds: Double) {
        lib.command(handle, ["seek", String(format: "%.3f", max(0, seconds)), "absolute"], async: true)
    }

    func setRate(_ rate: Double) {
        lib.set(handle, "speed", String(rate))
    }

    func setVolume(_ volume: Double) {
        lib.set(handle, "volume", String(Int(volume)))
    }

    func setMuted(_ muted: Bool) {
        lib.set(handle, "mute", muted ? "yes" : "no")
    }

    func setSubtitleScale(_ scale: Double) {
        lib.set(handle, "sub-scale", String(scale))
    }

    var audioTracks: [TrackOption] { tracks(ofType: "audio") }

    var subtitleTracks: [TrackOption] { tracks(ofType: "sub") }

    func selectAudioTrack(_ id: String) {
        lib.set(handle, "aid", id)
    }

    func selectSubtitleTrack(_ id: String?) {
        lib.set(handle, "sid", id ?? "no")
    }

    func stop() {
        guard let handle else {
            return
        }
        self.handle = nil
        lib.setWakeupCallback(handle, nil, nil)
        wakeupBox?.release()
        wakeupBox = nil
        lib.command(handle, ["stop"])
        view.glLayer.detach()
        // Destroying waits for mpv's threads to finish; keep that off the main thread.
        nonisolated(unsafe) let detached = handle
        let lib = self.lib
        DispatchQueue.global(qos: .utility).async {
            lib.terminateDestroy(detached)
        }
    }

    // MARK: - Events

    fileprivate func drainEvents() {
        while let handle, let event = lib.waitEvent(handle, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
            process(event)
        }
    }

    private func process(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee else {
                return
            }
            propertyChanged(Observed(rawValue: event.reply_userdata), data)
        case MPV_EVENT_FILE_LOADED:
            didLoad = true
            addExternalSubtitles()
            onEvent?(.loaded(duration: lib.double(handle, "duration")))
            onEvent?(.tracksChanged)
        case MPV_EVENT_END_FILE:
            guard let data = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee else {
                return
            }
            if data.reason == MPV_END_FILE_REASON_ERROR {
                let message = lib.errorString(data.error).map { String(cString: $0) } ?? String(localized: "unknown error")
                onEvent?(.failed(String(localized: "mpv could not play this file (\(message)).")))
            }
        default:
            break
        }
    }

    private func propertyChanged(_ id: Observed?, _ property: mpv_event_property) {
        func double() -> Double? {
            guard property.format == MPV_FORMAT_DOUBLE, let data = property.data else {
                return nil
            }
            return data.assumingMemoryBound(to: Double.self).pointee
        }
        func flag() -> Bool? {
            guard property.format == MPV_FORMAT_FLAG, let data = property.data else {
                return nil
            }
            return data.assumingMemoryBound(to: Int32.self).pointee != 0
        }
        func int() -> Int64? {
            guard property.format == MPV_FORMAT_INT64, let data = property.data else {
                return nil
            }
            return data.assumingMemoryBound(to: Int64.self).pointee
        }

        switch id {
        case .timePos:
            if let value = double() {
                onEvent?(.time(value))
            }
        case .duration:
            if let value = double() {
                onEvent?(.duration(value))
            }
        case .pause:
            if let value = flag() {
                onEvent?(.paused(value))
            }
        case .pausedForCache:
            let paused = flag() ?? false
            if paused, !pausedForCache, didLoad, !seeking {
                stallCount += 1
                // When the network can't keep up, refill longer each time so playback
                // runs in longer uninterrupted stretches instead of stuttering.
                currentPrebuffer = min(30, basePrebuffer << min(stallCount, 4))
                lib.set(handle, "cache-pause-wait", String(currentPrebuffer))
            }
            pausedForCache = paused
            reportBuffering()
        case .seeking:
            seeking = flag() ?? false
            reportBuffering()
        case .cacheBufferingState:
            cacheProgress = int().map { Double($0) / 100 }
            if pausedForCache {
                reportBuffering()
            }
        case .demuxerCacheDuration:
            if let value = double() {
                onEvent?(.bufferedAhead(value))
            }
        case .trackList:
            onEvent?(.tracksChanged)
        case .eofReached:
            if flag() == true, didLoad {
                onEvent?(.ended)
            }
        case nil:
            break
        }
    }

    private func reportBuffering() {
        let waiting = pausedForCache || (seeking && didLoad)
        onEvent?(.buffering(waiting, progress: pausedForCache ? cacheProgress : nil))
    }

    private func addExternalSubtitles() {
        for subtitle in pendingSubtitles {
            var args = ["sub-add", subtitle.url.absoluteString, "auto", subtitle.title]
            if let language = subtitle.language {
                args.append(language)
            }
            lib.command(handle, args)
        }
        pendingSubtitles = []
        guard subtitlesEnabled, lib.string(handle, "sid") == "no" || lib.string(handle, "sid") == "auto" else {
            return
        }
        // Prefer a track in the preferred language, then a default-flagged one.
        let subs = subtitleTracks
        let match = subs.first { preferredSubtitleLanguage.isEmpty == false && ($0.detail ?? "").localizedCaseInsensitiveContains(preferredSubtitleLanguage) }
            ?? subs.first
        if let match {
            selectSubtitleTrack(match.id)
        }
    }

    // MARK: - Tracks

    private func tracks(ofType type: String) -> [TrackOption] {
        guard let handle, let count = lib.int(handle, "track-list/count") else {
            return []
        }
        var result: [TrackOption] = []
        for index in 0..<count {
            let prefix = "track-list/\(index)/"
            guard lib.string(handle, prefix + "type") == type, let id = lib.string(handle, prefix + "id") else {
                continue
            }
            let title = lib.string(handle, prefix + "title")
            let language = lib.string(handle, prefix + "lang")
            let codec = lib.string(handle, prefix + "codec")
            let external = lib.flag(handle, prefix + "external") ?? false
            let selected = lib.flag(handle, prefix + "selected") ?? false
            var detail: [String] = []
            if let language {
                detail.append(Locale.current.localizedString(forLanguageCode: language) ?? language)
            }
            if let codec {
                detail.append(codec.uppercased())
            }
            if type == "audio", let channels = lib.int(handle, prefix + "demux-channel-count") {
                detail.append(channelDescription(Int(channels)))
            }
            if external {
                detail.append(String(localized: "External"))
            }
            let name = title ?? language.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 } ?? String(localized: "Track \(id)")
            result.append(TrackOption(id: id, title: name, detail: detail.joined(separator: " · "), isSelected: selected))
        }
        return result
    }

    // MARK: - Stats

    func collectStats() -> [StatSection] {
        guard let handle else {
            return []
        }
        func s(_ name: String) -> String? { lib.string(handle, name) }
        func d(_ name: String) -> Double? { lib.double(handle, name) }
        func i(_ name: String) -> Int64? { lib.int(handle, name) }

        var video: [StatRow] = []
        if let codec = s("video-codec") {
            video.append(StatRow(label: String(localized: "Codec"), value: codec))
        }
        if let w = i("video-params/w"), let h = i("video-params/h") {
            var value = "\(w)×\(h)"
            if let dw = i("video-params/dw"), let dh = i("video-params/dh"), dw != w || dh != h {
                value += " " + String(localized: "(display \(dw)×\(dh))")
            }
            video.append(StatRow(label: String(localized: "Resolution"), value: value))
        }
        if let fps = d("container-fps") {
            var value = String(format: "%.3f fps", fps)
            if let estimated = d("estimated-vf-fps") {
                value += " " + String(localized: "(rendering \(estimated, format: .number.precision(.fractionLength(2))))")
            }
            video.append(StatRow(label: String(localized: "Frame rate"), value: value))
        }
        if let format = s("video-params/pixelformat") {
            video.append(StatRow(label: String(localized: "Pixel format"), value: format))
        }
        if let primaries = s("video-params/primaries"), let gamma = s("video-params/gamma") {
            video.append(StatRow(label: String(localized: "Color"), value: "\(primaries) / \(gamma)"))
        }
        let hwdec = s("hwdec-current") ?? "no"
        video.append(StatRow(label: String(localized: "Decoder"), value: hwdec == "no" || hwdec.isEmpty ? String(localized: "Software") : String(localized: "Hardware (\(hwdec))"),
                             highlight: hwdec == "no" || hwdec.isEmpty ? .none : .good))
        if let bitrate = d("video-bitrate") {
            video.append(StatRow(label: String(localized: "Bitrate"), value: Format.bitrate(bitrate)))
        }
        let voDropped = i("frame-drop-count") ?? 0
        let decoderDropped = i("decoder-frame-drop-count") ?? 0
        let delayed = i("vo-delayed-frame-count") ?? 0
        video.append(StatRow(label: String(localized: "Dropped frames"), value: String(localized: "\(voDropped) output · \(decoderDropped) decoder · \(delayed) late"),
                             highlight: voDropped + decoderDropped > 0 ? .warning : .good))
        if let avsync = d("avsync") {
            video.append(StatRow(label: String(localized: "A/V sync"), value: String(format: "%+.3f s", avsync)))
        }

        var audio: [StatRow] = []
        if let codec = s("audio-codec") ?? s("audio-codec-name") {
            audio.append(StatRow(label: String(localized: "Codec"), value: codec))
        }
        if let channels = s("audio-params/hr-channels") ?? s("audio-params/channels") {
            var value = channels
            if let rate = i("audio-params/samplerate") {
                value += " · \(rate) Hz"
            }
            audio.append(StatRow(label: String(localized: "Channels"), value: value))
        }
        if let bitrate = d("audio-bitrate") {
            audio.append(StatRow(label: String(localized: "Bitrate"), value: Format.bitrate(bitrate)))
        }
        if let device = s("audio-device") {
            audio.append(StatRow(label: String(localized: "Output"), value: device))
        }

        var buffer: [StatRow] = []
        let ahead = d("demuxer-cache-duration") ?? 0
        buffer.append(StatRow(label: String(localized: "Buffered ahead"), value: String(format: "%.1f s", ahead), highlight: ahead > 10 ? .good : .warning))
        if let bytes = i("demuxer-cache-state/fw-bytes") {
            buffer.append(StatRow(label: String(localized: "Cache (forward)"), value: Format.bytes(Double(bytes))))
        }
        if let total = i("demuxer-cache-state/total-bytes") {
            buffer.append(StatRow(label: String(localized: "Cache (total)"), value: Format.bytes(Double(total))))
        }
        if let rate = i("demuxer-cache-state/raw-input-rate") {
            buffer.append(StatRow(label: String(localized: "Download rate"), value: Format.bitrate(Double(rate) * 8)))
        } else if let speed = d("cache-speed") {
            buffer.append(StatRow(label: String(localized: "Download rate"), value: Format.bitrate(speed * 8)))
        }
        buffer.append(StatRow(label: String(localized: "Stalls"), value: "\(stallCount)", highlight: stallCount > 0 ? .warning : .good))
        buffer.append(StatRow(label: String(localized: "Refill target"), value: "\(currentPrebuffer) s" + (currentPrebuffer > basePrebuffer ? " " + String(localized: "(raised after stalls)") : "")))
        let idle = lib.flag(handle, "demuxer-cache-idle") ?? false
        buffer.append(StatRow(label: String(localized: "Reading"), value: idle ? String(localized: "Idle (buffer full)") : String(localized: "Downloading")))
        if lib.flag(handle, "paused-for-cache") == true {
            let state = i("cache-buffering-state") ?? 0
            buffer.append(StatRow(label: String(localized: "State"), value: String(localized: "Refilling buffer (\(state)%)"), highlight: .warning))
        }

        var file: [StatRow] = []
        if let format = s("file-format") {
            file.append(StatRow(label: String(localized: "Demuxer"), value: format))
        }
        file.append(StatRow(label: String(localized: "Engine"), value: "libmpv \(lib.version) · \(s("mpv-version") ?? "")"))

        return [
            StatSection(title: String(localized: "Video"), rows: video),
            StatSection(title: String(localized: "Audio"), rows: audio),
            StatSection(title: String(localized: "Buffer"), rows: buffer),
            StatSection(title: String(localized: "Engine"), rows: file),
        ]
    }
}

/// Lets C callbacks reach the engine without keeping it alive.
private final class WeakEngineBox {
    weak var engine: MPVEngine?

    init(_ engine: MPVEngine) {
        self.engine = engine
    }
}

func channelDescription(_ channels: Int) -> String {
    switch channels {
    case 1: String(localized: "Mono")
    case 2: String(localized: "Stereo")
    case 6: "5.1"
    case 8: "7.1"
    default: String(localized: "\(channels) ch", comment: "Number of audio channels")
    }
}
