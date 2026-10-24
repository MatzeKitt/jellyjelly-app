import SwiftUI

struct PlayerView: View {
    var model: PlayerModel

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // In picture in picture, the floating window owns the video view.
            VideoSurface(engineView: model.isPictureInPicture ? nil : model.engine?.videoView)
                .ignoresSafeArea()

            // Gesture layer: click to pause, double-click for full screen.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture(count: 2) { model.toggleFullScreen() }
                .onTapGesture(count: 1) { model.togglePause() }

            if let text = model.subtitleText {
                SubtitleOverlay(text: text, scale: app.settings.subtitleScale, raised: model.controlsVisible)
                    .allowsHitTesting(false)
            }

            if model.isBuffering, !model.phase.isFailed {
                BufferingIndicator(progress: model.bufferProgress, loading: model.phase == .loading)
                    .allowsHitTesting(false)
            }

            if case let .failed(message) = model.phase {
                PlayerErrorView(message: message) {
                    model.close()
                }
            }

            PlayerChrome(model: model)
                .opacity(model.controlsVisible ? 1 : 0)
                .allowsHitTesting(model.controlsVisible)
                .animation(.easeInOut(duration: 0.25), value: model.controlsVisible)

            if model.showStats {
                StatsOverlay(model: model)
                    .padding(.top, 78)
                    .padding(.trailing, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            VStack(alignment: .trailing, spacing: 14) {
                Spacer()
                if let segment = model.activeSegment {
                    SkipSegmentButton(segment: segment) {
                        model.skipActiveSegment()
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                if let next = model.upNext {
                    UpNextCard(item: next, remaining: model.remaining) {
                        model.playNext()
                    } onCancel: {
                        model.dismissUpNext()
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .padding(.trailing, 32)
            .padding(.bottom, model.controlsVisible ? 140 : 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .animation(.spring(response: 0.35), value: model.activeSegment?.id)
            .animation(.spring(response: 0.35), value: model.upNext?.id)
            .animation(.easeInOut(duration: 0.25), value: model.controlsVisible)
        }
        .onContinuousHover { phase in
            if case .active = phase {
                model.userActivity()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.showStats)
        .preferredColorScheme(.dark)
        .onAppear {
            // A text field left focused behind the player would swallow the playback keys.
            NSApp.mainWindow?.makeFirstResponder(nil)
        }
    }
}

private extension PlayerModel.Phase {
    var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

/// Hosts the active engine's NSView, swapping it when the engine changes.
struct VideoSurface: NSViewRepresentable {
    var engineView: NSView?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard container.subviews.first !== engineView else {
            return
        }
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let engineView else {
            return
        }
        engineView.frame = container.bounds
        engineView.autoresizingMask = [.width, .height]
        container.addSubview(engineView)
    }
}

// MARK: - Chrome

private struct PlayerChrome: View {
    var model: PlayerModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            bottomBar
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 16) {
            Button {
                model.close()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(CircleIconButtonStyle(size: 40))
            .help("Close Player (Esc)")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(1)
                if let subtitle = model.subtitle {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            Spacer()
            if let engine = model.engineKind {
                Text("DIRECT PLAY · \(engine.rawValue.uppercased())")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 40)
        .background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            SeekBar(model: model)
            HStack(spacing: 14) {
                Button {
                    model.togglePause()
                } label: {
                    Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 22, weight: .bold))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.isPaused ? "Play (Space)" : "Pause (Space)")

                PlayerIconButton(systemImage: "gobackward.10", help: "Back 10 Seconds (←)") { model.skip(by: -10) }
                PlayerIconButton(systemImage: "goforward.10", help: "Forward 10 Seconds (→)") { model.skip(by: 10) }
                if !model.queue.isEmpty {
                    PlayerIconButton(systemImage: "forward.end.fill", help: "Next (N)") { model.playNext() }
                }
                VolumeControl(model: model)

                Text("\(Format.time(model.position)) / \(Format.time(model.duration))")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.leading, 4)

                Spacer()

                if model.duration > 0 {
                    Text("Ends at \(Date.now.addingTimeInterval(model.remaining / max(model.rate, 0.1)).formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }

                SpeedMenu(model: model)
                if !model.chapters.isEmpty {
                    ChapterMenu(model: model)
                }
                TrackMenu(title: String(localized: "Audio"), emptyMessage: String(localized: "No audio tracks"), systemImage: "waveform", options: model.audioOptions, allowsOff: false) { id in
                    if let id {
                        model.selectAudio(id)
                    }
                }
                TrackMenu(title: String(localized: "Subtitles"), emptyMessage: String(localized: "No subtitle tracks"), systemImage: "captions.bubble", options: model.subtitleOptions, allowsOff: true) { id in
                    model.selectSubtitle(id)
                }
                PlayerIconButton(systemImage: "chart.bar.xaxis", help: "Stats (I)", active: model.showStats) { model.toggleStats() }
                PlayerIconButton(systemImage: "pip.enter", help: "Picture in Picture (P)") { model.enterPictureInPicture() }
                PlayerIconButton(systemImage: model.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                 help: "Full Screen (F)") { model.toggleFullScreen() }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 50)
        .padding(.bottom, 24)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
        .onHover { model.isInteractingWithControls = $0 }
    }
}

private struct PlayerIconButton: View {
    var systemImage: String
    var help: LocalizedStringKey
    var active = false
    var action: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(active ? palette.accent : .white.opacity(hovering ? 1 : 0.85))
                .frame(width: 32, height: 32)
                .background(.white.opacity(hovering ? 0.12 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

private struct VolumeControl: View {
    var model: PlayerModel
    @State private var hovering = false
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            PlayerIconButton(systemImage: volumeIcon, help: "Mute (M)") { model.toggleMute() }
            if hovering {
                Slider(value: $model.volume, in: 0...100)
                    .frame(width: 90)
                    .tint(palette.accent)
                    .controlSize(.small)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .onHover { value in
            withAnimation(.easeOut(duration: 0.15)) {
                hovering = value
            }
        }
    }

    private var volumeIcon: String {
        if model.isMuted || model.volume == 0 {
            return "speaker.slash.fill"
        }
        return model.volume < 50 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
    }
}

private struct SpeedMenu: View {
    var model: PlayerModel

    var body: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { rate in
                Button {
                    model.setRate(rate)
                } label: {
                    if rate == model.rate {
                        Label(label(rate), systemImage: "checkmark")
                    } else {
                        Text(label(rate))
                    }
                }
            }
        } label: {
            Text(model.rate == 1 ? "1×" : label(model.rate))
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .frame(minWidth: 32, minHeight: 32)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback Speed ([ and ])")
    }

    private func label(_ rate: Double) -> String {
        rate == 1 ? String(localized: "Normal") : String(format: "%g×", rate)
    }
}

private struct ChapterMenu: View {
    var model: PlayerModel

    var body: some View {
        Menu {
            ForEach(model.chapters) { chapter in
                Button {
                    model.seek(to: chapter.start)
                } label: {
                    let current = model.chapters.last { $0.start <= model.position + 0.5 }?.start == chapter.start
                    if current {
                        Label("\(Format.time(chapter.start))  \(chapter.name)", systemImage: "checkmark")
                    } else {
                        Text("\(Format.time(chapter.start))  \(chapter.name)")
                    }
                }
            }
        } label: {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 32, height: 32)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Chapters")
    }
}

private struct TrackMenu: View {
    var title: String
    var emptyMessage: String
    var systemImage: String
    var options: [TrackOption]
    var allowsOff: Bool
    var onSelect: (String?) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Menu {
            Section(title) {
                if allowsOff {
                    Button {
                        onSelect(nil)
                    } label: {
                        if options.contains(where: \.isSelected) {
                            Text("Off")
                        } else {
                            Label("Off", systemImage: "checkmark")
                        }
                    }
                }
                ForEach(options) { option in
                    Button {
                        onSelect(option.id)
                    } label: {
                        let text = [option.title, option.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
                        if option.isSelected {
                            Label(text, systemImage: "checkmark")
                        } else {
                            Text(text)
                        }
                    }
                }
                if options.isEmpty {
                    Text(emptyMessage)
                }
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(allowsOff && options.contains(where: \.isSelected) ? palette.accent : .white.opacity(0.85))
                .frame(width: 32, height: 32)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(title)
    }
}

// MARK: - Seek bar

private struct SeekBar: View {
    var model: PlayerModel

    @Environment(\.palette) private var palette
    @State private var hoverX: CGFloat?
    @State private var dragPosition: Double?
    @State private var preview: CGImage?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let duration = max(model.duration, 0.001)
            let shown = dragPosition ?? model.position
            let progress = min(1, max(0, shown / duration))
            let buffered = min(1, max(0, (model.position + model.bufferedAhead) / duration))
            let expanded = hoverX != nil || dragPosition != nil

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(.white.opacity(0.38))
                    .frame(width: width * buffered)
                Capsule().fill(palette.accent)
                    .frame(width: width * progress)
                ForEach(model.chapters.dropFirst()) { chapter in
                    Rectangle()
                        .fill(.black.opacity(0.7))
                        .frame(width: 2)
                        .offset(x: width * chapter.start / duration - 1)
                }
                Circle()
                    .fill(.white)
                    .frame(width: expanded ? 16 : 0, height: expanded ? 16 : 0)
                    .shadow(radius: 3)
                    .offset(x: width * progress - (expanded ? 8 : 0))
            }
            .frame(height: expanded ? 8 : 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .bottomLeading) {
                if let x = hoverX ?? dragPosition.map({ CGFloat($0 / duration) * width }) {
                    let time = Double(x / width) * duration
                    SeekPreview(time: time, chapter: chapterName(at: time), image: preview)
                        .fixedSize()
                        .frame(width: 240)
                        .offset(x: min(max(0, x - 120), max(0, width - 240)), y: -22)
                        .allowsHitTesting(false)
                        .task(id: Int(time / 2)) {
                            preview = await model.trickplayThumbnail(at: time)
                        }
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    hoverX = min(max(0, location.x), width)
                case .ended:
                    hoverX = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        model.isInteractingWithControls = true
                        dragPosition = Double(min(max(0, value.location.x), width) / width) * duration
                    }
                    .onEnded { value in
                        let target = Double(min(max(0, value.location.x), width) / width) * duration
                        dragPosition = nil
                        model.seek(to: target)
                        model.isInteractingWithControls = false
                    }
            )
            .animation(.easeOut(duration: 0.12), value: expanded)
        }
        .frame(height: 22)
    }

    private func chapterName(at time: Double) -> String? {
        model.chapters.last { $0.start <= time }?.name
    }
}

private struct SeekPreview: View {
    var time: Double
    var chapter: String?
    var image: CGImage?

    var body: some View {
        VStack(spacing: 6) {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.3)))
            }
            VStack(spacing: 1) {
                Text(Format.time(time))
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                if let chapter, !chapter.isEmpty {
                    Text(chapter)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .frame(maxWidth: 220)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .shadow(color: .black.opacity(0.5), radius: 10)
    }
}

// MARK: - Overlays

private struct SubtitleOverlay: View {
    var text: String
    var scale: Double
    var raised: Bool

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 30 * scale, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .shadow(color: .black, radius: 2)
                .shadow(color: .black.opacity(0.8), radius: 6)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 80)
                .padding(.bottom, raised ? 150 : 60)
                .animation(.easeInOut(duration: 0.25), value: raised)
        }
    }
}

private struct BufferingIndicator: View {
    var progress: Double?
    var loading: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.15), lineWidth: 5)
                if let progress {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(palette.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut, value: progress)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
            }
            .frame(width: 64, height: 64)
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(24)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var label: String {
        if loading {
            return String(localized: "Loading…")
        }
        if let progress {
            return String(localized: "Buffering \(Int(progress * 100))%")
        }
        return String(localized: "Buffering…")
    }
}

private struct PlayerErrorView: View {
    var message: String
    var onClose: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(palette.accent)
            Text("Playback failed")
                .font(.system(size: 20, weight: .bold))
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            if !MPVEngine.isAvailable {
                Text("Tip: install mpv (`brew install mpv`) so JellyJelly can direct-play MKV, WebM, VP9, AV1, and more.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            Button("Close", action: onClose)
                .buttonStyle(AccentButtonStyle())
        }
        .padding(36)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct SkipSegmentButton: View {
    var segment: MediaSegment
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(segment.skipTitle, systemImage: "forward.fill")
                .labelStyle(TrailingIconLabelStyle())
        }
        .buttonStyle(AccentButtonStyle())
        .help("Skip (S or Return)")
    }
}

private struct UpNextCard: View {
    var item: BaseItem
    var remaining: Double
    var onPlay: () -> Void
    var onCancel: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 14) {
            RemoteImage(url: app.client?.thumbURL(item, width: 400))
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text("UP NEXT · \(Int(remaining.rounded()))s")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1)
                    .foregroundStyle(palette.accent)
                Text(item.displayName)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(2)
                    .frame(width: 220, alignment: .leading)
                if let series = item.seriesName {
                    Text(series)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Button("Play Now", action: onPlay)
                        .buttonStyle(AccentButtonStyle())
                        .controlSize(.small)
                    Button("Cancel", action: onCancel)
                        .buttonStyle(AccentButtonStyle(prominent: false))
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}
