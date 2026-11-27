import SwiftUI

// MARK: - Bar

/// The player at the bottom of the main window while music or an audiobook is loaded.
struct NowPlayingBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    var body: some View {
        let music = app.music
        if let item = music.current {
            let span = music.seekSpan
            HStack(spacing: 20) {
                HStack(spacing: 12) {
                    Button {
                        app.showsNowPlaying = true
                    } label: {
                        CoverArt(url: music.coverURL(app: app, width: 120), cornerRadius: 6, systemImage: music.book == nil ? "music.note" : "book.closed.fill")
                            .frame(width: 50, height: 50)
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                    }
                    .buttonStyle(.plain)
                    .help("Show Now Playing (⌘P)")
                    if let book = music.book {
                        BookTitle(book: book, chapter: music.currentChapter, size: 13)
                    } else {
                        TrackTitle(item: item, size: 13)
                    }
                }
                .frame(width: 290, alignment: .leading)

                Spacer(minLength: 8)

                VStack(spacing: 2) {
                    if music.book != nil {
                        BookTransport(music: music, size: 30)
                    } else {
                        MusicTransport(music: music, size: 30)
                    }
                    HStack(spacing: 10) {
                        TimeLabel(seconds: span.position)
                        MusicSeekBar(music: music)
                        TimeLabel(seconds: span.duration)
                    }
                }
                .frame(maxWidth: 560)

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    if music.book != nil {
                        BookSpeedMenu(music: music)
                        SleepTimerMenu(music: music)
                        MusicControlButton(systemImage: "list.bullet", help: "Chapters", active: app.showsNowPlaying) {
                            show(.chapters)
                        }
                    } else {
                        SleepTimerMenu(music: music)
                        MusicControlButton(systemImage: "quote.bubble", help: "Lyrics (⇧⌘L)", active: app.showsNowPlaying && app.nowPlayingPanel == .lyrics) {
                            show(.lyrics)
                        }
                        MusicControlButton(systemImage: "list.bullet", help: "Queue", active: app.showsNowPlaying && app.nowPlayingPanel == .queue) {
                            show(.queue)
                        }
                    }
                    MusicVolume(music: music, width: music.book == nil ? 80 : 70)
                    MusicControlButton(systemImage: app.showsNowPlaying ? "chevron.down" : "chevron.up",
                                       help: app.showsNowPlaying ? "Hide Now Playing (⌘P)" : "Show Now Playing (⌘P)") {
                        app.showsNowPlaying.toggle()
                    }
                }
                .frame(width: 290, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .frame(height: 78)
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    palette.sidebar.opacity(0.9)
                }
            }
            .overlay(alignment: .top) {
                Rectangle().fill(palette.hairline).frame(height: 1)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Opens Now Playing on a panel, or closes it when that panel is already showing. Books only have chapters.
    private func show(_ panel: NowPlayingPanel) {
        if app.showsNowPlaying, app.nowPlayingPanel == panel || app.music.book != nil {
            app.showsNowPlaying = false
        } else {
            app.nowPlayingPanel = panel
            app.showsNowPlaying = true
        }
    }
}

/// The song's title, which opens the album, over its artists, which open the artist.
private struct TrackTitle: View {
    var item: BaseItem
    var size: CGFloat
    var alignment: HorizontalAlignment = .leading

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: alignment, spacing: size * 0.2) {
            Button(item.displayName) {
                app.open(item)
            }
            .buttonStyle(.plain)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(palette.text)
            .lineLimit(1)
            .help(item.album.map { String(localized: "Go to \($0)") } ?? "")

            if let artists = item.artistLine {
                Button(artists) {
                    if let artist = item.artistItems?.first ?? item.primaryArtist {
                        app.openArtist(artist)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: size * 0.85, weight: .medium))
                .foregroundStyle(alignment == .center ? palette.accent : palette.secondaryText)
                .lineLimit(1)
            }
        }
    }
}

/// The book's title, which opens its page, over the chapter, or the author when there are no chapters.
private struct BookTitle: View {
    var book: Audiobook
    var chapter: BookChapter?
    var size: CGFloat
    var alignment: HorizontalAlignment = .leading

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: alignment, spacing: size * 0.2) {
            Button(book.title) {
                app.openAudiobook(book.item)
            }
            .buttonStyle(.plain)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(palette.text)
            .lineLimit(1)
            .help("Show Audiobook")

            if let line = alignment == .center ? book.author : (book.chapters.count > 1 ? chapter?.title : book.author) {
                Text(line)
                    .font(.system(size: size * 0.85, weight: .medium))
                    .foregroundStyle(alignment == .center ? palette.accent : palette.secondaryText)
                    .lineLimit(1)
            }
        }
    }
}

extension MusicPlayer {
    /// What the seek bar spans: the song, or the chapter of a book.
    var seekSpan: (position: Double, duration: Double) {
        guard book != nil, let chapter = currentChapter else {
            return (position, duration)
        }
        return (min(max(0, bookPosition - chapter.start), chapter.duration), chapter.duration)
    }

    func seekInSpan(to seconds: Double) {
        guard book != nil, let chapter = currentChapter else {
            seek(to: seconds)
            return
        }
        seekBook(to: chapter.start + seconds)
    }

    /// The cover of the book, or of the song.
    func coverURL(app: AppModel, width: Int) -> URL? {
        if let book {
            return app.coverURL(of: book, width: width)
        }
        return current.flatMap { app.client?.coverURL($0, width: width) }
    }

    /// The time left in the book at the current speed.
    var bookTimeLeft: Double {
        guard let book else {
            return 0
        }
        return max(0, book.duration - bookPosition) / max(rate, 0.1)
    }
}

// MARK: - Controls

struct MusicControlButton: View {
    var systemImage: String
    var help: LocalizedStringKey
    var size: CGFloat = 30
    var active = false
    /// A mode that is on or off, like shuffle, which is dimmed while off. The accent alone doesn't tell
    /// the states apart in color schemes with a light accent.
    var isToggle = false
    var action: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var color: Color {
        if active {
            return palette.accent
        }
        if isToggle {
            return .white.opacity(hovering ? 0.5 : 0.3)
        }
        return .white.opacity(hovering ? 1 : 0.8)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .background(.white.opacity(hovering ? 0.1 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// Shuffle, previous, play/pause, next, and repeat.
struct MusicTransport: View {
    var music: MusicPlayer
    var size: CGFloat

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: size * 0.55) {
            MusicControlButton(systemImage: "shuffle", help: "Shuffle", size: size, active: music.isShuffled, isToggle: true) {
                music.toggleShuffle()
            }
            MusicControlButton(systemImage: "backward.fill", help: "Previous (⌘←)", size: size) {
                music.previous()
            }
            PlayPauseButton(music: music, size: size)
            MusicControlButton(systemImage: "forward.fill", help: "Next (⌘→)", size: size) {
                music.next()
            }
            .disabled(!music.hasNext)
            MusicControlButton(systemImage: music.repeatMode == .one ? "repeat.1" : "repeat", help: repeatHelp, size: size, active: music.repeatMode != .off, isToggle: true) {
                music.cycleRepeatMode()
            }
        }
    }

    private var repeatHelp: LocalizedStringKey {
        switch music.repeatMode {
        case .off: "Repeat Off"
        case .all: "Repeat All"
        case .one: "Repeat One"
        }
    }
}

/// Skip back, previous chapter, play/pause, next chapter, and skip forward.
struct BookTransport: View {
    var music: MusicPlayer
    var size: CGFloat

    @Environment(AppModel.self) private var app

    var body: some View {
        let back = app.settings.audiobookSkipBack
        let forward = app.settings.audiobookSkipForward
        HStack(spacing: size * 0.55) {
            MusicControlButton(systemImage: AppSettings.skipSymbol(back, forward: false), help: "Back \(Int(back)) Seconds (⇧⌘←)", size: size) {
                music.skip(by: -back)
            }
            MusicControlButton(systemImage: "backward.end.fill", help: "Previous Chapter (⌘←)", size: size) {
                music.previousChapter()
            }
            PlayPauseButton(music: music, size: size)
            MusicControlButton(systemImage: "forward.end.fill", help: "Next Chapter (⌘→)", size: size) {
                music.nextChapter()
            }
            .disabled(!music.hasNext)
            MusicControlButton(systemImage: AppSettings.skipSymbol(forward, forward: true), help: "Forward \(Int(forward)) Seconds (⇧⌘→)", size: size) {
                music.skip(by: forward)
            }
        }
    }
}

/// The big round play button, with a spinner while loading.
private struct PlayPauseButton: View {
    var music: MusicPlayer
    var size: CGFloat

    var body: some View {
        Button {
            music.togglePlayPause()
        } label: {
            ZStack {
                Circle().fill(.white)
                if music.isBuffering, music.isPlaying {
                    // macOS draws the spinner for the color scheme and ignores the tint, so the app's dark
                    // scheme would make it white on the white button.
                    ProgressView()
                        .controlSize(.small)
                        .environment(\.colorScheme, .light)
                } else {
                    Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: size * 0.55, weight: .bold))
                        .foregroundStyle(.black)
                        .offset(x: music.isPlaying ? 0 : size * 0.04)
                }
            }
            .frame(width: size * 1.3, height: size * 1.3)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(music.isPlaying ? "Pause (Space)" : "Play (Space)")
    }
}

struct MusicVolume: View {
    var music: MusicPlayer
    var width: CGFloat

    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var music = music
        HStack(spacing: 6) {
            Image(systemName: music.volume == 0 ? "speaker.slash.fill" : (music.volume < 50 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 18)
            Slider(value: $music.volume, in: 0...100)
                .frame(width: width)
                .tint(palette.accent)
                .controlSize(.small)
        }
        .help("Volume (⌘↑ and ⌘↓)")
    }
}

private struct TimeLabel: View {
    var seconds: Double

    var body: some View {
        Text(Format.time(seconds))
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
            .frame(width: 40)
    }
}

/// A thin progress bar that grows on hover, shows the time under the pointer, and seeks on click or drag.
/// In a book, it spans the current chapter.
struct MusicSeekBar: View {
    var music: MusicPlayer

    @Environment(\.palette) private var palette
    @State private var hoverX: CGFloat?
    @State private var dragPosition: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let span = music.seekSpan
            let duration = max(span.duration, 0.001)
            let progress = min(1, max(0, (dragPosition ?? span.position) / duration))
            let expanded = hoverX != nil || dragPosition != nil

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(expanded ? palette.accent : .white.opacity(0.85))
                    .frame(width: width * progress)
                Circle()
                    .fill(.white)
                    .frame(width: expanded ? 12 : 0, height: expanded ? 12 : 0)
                    .shadow(radius: 2)
                    .offset(x: width * progress - (expanded ? 6 : 0))
            }
            .frame(height: expanded ? 6 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                if let x = hoverX, dragPosition == nil {
                    Text(Format.time(Double(x / width) * duration))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.8), in: Capsule())
                        .fixedSize()
                        .offset(x: min(max(0, x - 20), max(0, width - 40)), y: -16)
                        .allowsHitTesting(false)
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
                        dragPosition = Double(min(max(0, value.location.x), width) / width) * duration
                    }
                    .onEnded { value in
                        dragPosition = nil
                        music.seekInSpan(to: Double(min(max(0, value.location.x), width) / width) * duration)
                    }
            )
            .animation(.easeOut(duration: 0.12), value: expanded)
        }
        .frame(height: 18)
    }
}

// MARK: - Full view

/// The current song large, over its blurred artwork, beside the queue or the lyrics.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var app = app
        let music = app.music
        ZStack {
            palette.backgroundBottom.ignoresSafeArea()
            if let item = music.current {
                // An overlay, so the square artwork filling the window doesn't make the view taller than the window.
                Color.clear
                    .overlay {
                        RemoteImage(url: music.coverURL(app: app, width: 600)) { Color.clear }
                            .scaleEffect(1.4)
                            .blur(radius: 90)
                            .opacity(0.6)
                    }
                    .clipped()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                HStack(alignment: .center, spacing: 48) {
                    VStack(spacing: 22) {
                        CoverArt(url: music.coverURL(app: app, width: 1000), cornerRadius: 16, systemImage: music.book == nil ? "music.note" : "book.closed.fill")
                            .frame(maxWidth: 460, maxHeight: 460)
                            .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                            .scaleEffect(music.isPlaying ? 1 : 0.94)
                            .animation(.spring(response: 0.45, dampingFraction: 0.75), value: music.isPlaying)

                        if let book = music.book {
                            bookControls(book, music: music)
                        } else {
                            songControls(item, music: music)
                        }

                        if let stream = music.stream {
                            Text(stream.summary)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.45))
                                .textSelection(.enabled)
                        }
                    }
                    .frame(minWidth: 340, maxWidth: 480)

                    VStack(spacing: 14) {
                        if let book = music.book {
                            Text("Chapters")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(palette.secondaryText)
                            ChaptersPanel(book: book, music: music)
                        } else {
                            Picker("", selection: $app.nowPlayingPanel) {
                                Text("Queue").tag(NowPlayingPanel.queue)
                                Text("Lyrics").tag(NowPlayingPanel.lyrics)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 220)

                            switch app.nowPlayingPanel {
                            case .queue, .chapters: QueuePanel(music: music)
                            case .lyrics: LyricsPanel(music: music)
                            }
                        }
                    }
                    .padding(.top, 18)
                    .frame(width: 400)
                    .frame(maxHeight: .infinity)
                    .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.08)))
                }
                .padding(.horizontal, 48)
                .padding(.top, 64)
                .padding(.bottom, 32)
            }

            Button {
                app.showsNowPlaying = false
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(CircleIconButtonStyle(size: 38))
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
            .padding(.leading, 24)
            .padding(.top, 34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: music.current == nil) { _, empty in
            if empty {
                app.showsNowPlaying = false
            }
        }
    }

    @ViewBuilder
    private func songControls(_ item: BaseItem, music: MusicPlayer) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                app.toggleFavorite(item)
            } label: {
                Image(systemName: item.isFavorite ? "heart.fill" : "heart")
            }
            .buttonStyle(CircleIconButtonStyle(size: 36, active: item.isFavorite))
            .help(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            TrackTitle(item: item, size: 22, alignment: .center)
                .frame(maxWidth: .infinity)
            Menu {
                MusicMenuItems(item: item, app: app)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(CircleIconButtonStyle(size: 36))
            .menuIndicator(.hidden)
            .fixedSize()
        }

        VStack(spacing: 4) {
            MusicSeekBar(music: music)
            HStack {
                Text(Format.time(music.position))
                Spacer()
                Text("-" + Format.time(max(0, music.duration - music.position)))
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }

        MusicTransport(music: music, size: 40)

        HStack(spacing: 14) {
            MusicVolume(music: music, width: 200)
            SleepTimerMenu(music: music, size: 32)
        }
    }

    /// The book's title and author, the chapter with its own seek bar, the time left in the book, and the
    /// controls for chapters, skipping, speed, and the sleep timer.
    @ViewBuilder
    private func bookControls(_ book: Audiobook, music: MusicPlayer) -> some View {
        let span = music.seekSpan
        HStack(alignment: .center, spacing: 12) {
            Button {
                app.toggleFavorite(book.item)
            } label: {
                Image(systemName: book.item.isFavorite ? "heart.fill" : "heart")
            }
            .buttonStyle(CircleIconButtonStyle(size: 36, active: book.item.isFavorite))
            .help(book.item.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            BookTitle(book: book, chapter: music.currentChapter, size: 22, alignment: .center)
                .frame(maxWidth: .infinity)
            Menu {
                AudiobookMenuItems(book: book, app: app)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(CircleIconButtonStyle(size: 36))
            .menuIndicator(.hidden)
            .fixedSize()
        }

        VStack(spacing: 6) {
            if let chapter = music.currentChapter, book.chapters.count > 1 {
                Text(chapter.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            MusicSeekBar(music: music)
            HStack {
                Text(Format.time(span.position))
                Spacer()
                if let chapter = music.currentChapter, book.chapters.count > 1 {
                    Text("Chapter \(chapter.id + 1) of \(book.chapters.count)")
                    Spacer()
                }
                Text("-" + Format.time(max(0, span.duration - span.position)))
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }

        BookTransport(music: music, size: 40)

        Text("\(Format.duration(music.bookTimeLeft)) left in the book")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))

        HStack(spacing: 14) {
            BookSpeedMenu(music: music, size: 32)
            SleepTimerMenu(music: music, size: 32)
            MusicVolume(music: music, width: 150)
        }
    }
}

// MARK: - Chapters

/// The chapters of the book that's playing, scrolled to the current one; clicking one plays it.
private struct ChaptersPanel: View {
    var book: Audiobook
    var music: MusicPlayer

    var body: some View {
        let current = music.currentChapter
        let position = music.bookPosition
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(book.chapters) { chapter in
                        ChapterRow(chapter: chapter, isCurrent: chapter.id == current?.id, isPlaying: music.isPlaying,
                                   isDone: chapter.end <= position, compact: true) {
                            music.jump(to: chapter)
                        }
                        .id(chapter.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            .onAppear {
                if let current {
                    proxy.scrollTo(current.id, anchor: .center)
                }
            }
            .onChange(of: current?.id) { _, id in
                if let id {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }
}

// MARK: - Queue

/// The songs played before, the current one, and what's up next, which can be reordered by dragging.
private struct QueuePanel: View {
    var music: MusicPlayer

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @State private var showsHistory = false

    var body: some View {
        let upcoming = music.upcoming
        ScrollViewReader { proxy in
            List {
                if !music.history.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showsHistory.toggle()
                        }
                    } label: {
                        Label(showsHistory ? "Hide History" : "Show History (\(music.history.count))",
                              systemImage: showsHistory ? "chevron.down" : "clock.arrow.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .queueRowStyle()
                    if showsHistory {
                        ForEach(music.history) { entry in
                            QueueRow(entry: entry, music: music, dimmed: true)
                                .queueRowStyle()
                        }
                    }
                }

                if let current = music.currentEntry {
                    QueueSectionHeader(title: String(localized: "Now Playing"))
                        .queueRowStyle()
                    QueueRow(entry: current, music: music, isCurrent: true)
                        .id(current.id)
                        .queueRowStyle()
                }

                QueueSectionHeader(title: String(localized: "Up Next"), detail: upcoming.isEmpty ? nil
                    : [String(localized: "\(upcoming.count) songs"), upcoming.map(\.item).totalDuration].compactMap { $0 }.joined(separator: " · ")) {
                    Menu {
                        AddToPlaylistMenu(items: upcoming.map(\.item), app: app)
                            .disabled(upcoming.isEmpty)
                        Divider()
                        Button("Clear Up Next") {
                            music.clearUpcoming()
                        }
                        .disabled(upcoming.isEmpty)
                        Button("Clear and Stop", role: .destructive) {
                            music.stop()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.secondaryText)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .queueRowStyle()

                if upcoming.isEmpty {
                    Text(music.repeatMode == .all ? "The queue starts over after this song." : "Nothing else is queued. Right-click a song or album and choose “Play Next” or “Add to Queue”.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.tertiaryText)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .queueRowStyle()
                }

                ForEach(upcoming) { entry in
                    QueueRow(entry: entry, music: music)
                        .queueRowStyle()
                }
                .onMove { source, destination in
                    music.moveUpcoming(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .onAppear {
                if let id = music.currentEntry?.id {
                    proxy.scrollTo(id, anchor: .top)
                }
            }
        }
    }

}

/// A heading in the queue, lined up with the songs' artwork, with details on the same baseline.
private struct QueueSectionHeader<Accessory: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var accessory: () -> Accessory

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(palette.tertiaryText)
            .lineLimit(1)
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension QueueSectionHeader where Accessory == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) {
            EmptyView()
        }
    }
}

private extension View {
    func queueRowStyle() -> some View {
        listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// A song in the queue; clicking it plays it.
private struct QueueRow: View {
    var entry: MusicPlayer.Entry
    var music: MusicPlayer
    var isCurrent = false
    var dimmed = false

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        let item = entry.item
        HStack(spacing: 10) {
            ZStack {
                CoverArt(url: app.client?.coverURL(item, width: 96), cornerRadius: 4)
                if isCurrent {
                    Color.black.opacity(0.45)
                    NowPlayingIndicator(isPlaying: music.isPlaying)
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isCurrent ? palette.accent : palette.text)
                    .lineLimit(1)
                if let artists = item.artistLine {
                    Text(artists)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if hovering, !isCurrent {
                Button {
                    music.remove(entry)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove from Queue")
            } else {
                Text(item.duration.map(Format.time) ?? "")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(palette.tertiaryText)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.white.opacity(hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(dimmed ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isCurrent {
                music.jump(to: entry)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            if !isCurrent {
                Button {
                    music.jump(to: entry)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                if !dimmed {
                    Button {
                        music.moveToNext(entry)
                    } label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                }
                Button(role: .destructive) {
                    music.remove(entry)
                } label: {
                    Label("Remove from Queue", systemImage: "minus.circle")
                }
                Divider()
            }
            AddToPlaylistMenu(items: [item], app: app)
            if item.albumId != nil {
                Button {
                    app.open(item)
                } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }
            if let artist = item.primaryArtist {
                Button {
                    app.openArtist(artist)
                } label: {
                    Label("Go to \(artist.name ?? String(localized: "Artist"))", systemImage: "music.mic")
                }
            }
            Button {
                app.toggleFavorite(item)
            } label: {
                Label(item.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: item.isFavorite ? "heart.slash" : "heart")
            }
        }
    }
}

// MARK: - Lyrics

/// Lyrics from the server. Timed lyrics follow the song, highlight the current line, and seek when a line is clicked.
private struct LyricsPanel: View {
    var music: MusicPlayer

    @Environment(\.palette) private var palette

    var body: some View {
        switch music.lyrics {
        case .loading:
            LoadingView()
        case .none:
            EmptyStateView(systemImage: "quote.bubble", title: String(localized: "No lyrics"),
                           message: String(localized: "Jellyfin has no lyrics for this song. It reads them from LRC or text files next to the song, or from a lyrics plugin."))
        case let .loaded(lines):
            let synced = lines.contains { $0.start != nil }
            let current = synced ? lines.lastIndex { ($0.start?.tickSeconds ?? .infinity) <= music.position + 0.3 } : nil
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: synced ? 16 : 6) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            let text = line.text?.trimmingCharacters(in: .whitespaces) ?? ""
                            Text(text.isEmpty ? "♪" : text)
                                .font(.system(size: synced ? 22 : 16, weight: synced ? .bold : .medium))
                                .foregroundStyle(lineColor(index: index, current: current, synced: synced))
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let start = line.start {
                                        music.seek(to: start.tickSeconds)
                                    }
                                }
                                .id(index)
                                .animation(.easeOut(duration: 0.25), value: current)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, synced ? 160 : 20)
                }
                .scrollIndicators(.never)
                .onChange(of: current) { _, line in
                    if let line {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            proxy.scrollTo(line, anchor: .center)
                        }
                    }
                }
                .onAppear {
                    if let current {
                        proxy.scrollTo(current, anchor: .center)
                    }
                }
            }
        }
    }

    private func lineColor(index: Int, current: Int?, synced: Bool) -> Color {
        guard synced else {
            return .white.opacity(0.85)
        }
        guard let current else {
            return .white.opacity(0.4)
        }
        return index == current ? .white : .white.opacity(index < current ? 0.3 : 0.45)
    }
}
