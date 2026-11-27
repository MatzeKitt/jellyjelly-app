import SwiftUI

// MARK: - Cards

/// A square book cover with its progress, a mark once finished, and a play button on hover.
struct BookCard: View {
    var book: Audiobook
    var width: CGFloat = 170

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Button {
                    app.openAudiobook(book.item)
                } label: {
                    CoverArt(url: app.coverURL(of: book, width: Int(width * 2)), cornerRadius: Metrics.cardCorner, systemImage: "book.closed.fill")
                        .overlay(alignment: .bottom) {
                            if let progress = book.progress {
                                ProgressStrip(progress: progress)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            if book.isFinished {
                                WatchedBadge()
                                    .padding(8)
                            }
                        }
                }
                .buttonStyle(.plain)
                if hovering {
                    CardPlayButton {
                        app.playAudiobook(book.item)
                    }
                    .padding(10)
                    .padding(.bottom, book.progress == nil ? 0 : 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .frame(width: width, height: width)
            .hoverLift { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(2)
                if let line = subtitle {
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .contextMenu {
            AudiobookMenuItems(book: book, app: app)
        }
    }

    private var subtitle: String? {
        if let progress = book.progress, book.duration > 0 {
            return String(localized: "\(Format.duration(book.duration * (1 - progress))) left")
        }
        return book.author
    }
}

// MARK: - Menus

/// Right-click actions for an audiobook.
struct AudiobookMenuItems: View {
    var book: Audiobook
    var app: AppModel

    var body: some View {
        Button {
            app.playAudiobook(book.item)
        } label: {
            Label(book.progress != nil ? "Resume" : "Play", systemImage: "play.fill")
        }
        if book.isStarted {
            Button {
                app.playAudiobook(book.item, startOver: true)
            } label: {
                Label("Play from Beginning", systemImage: "backward.end.fill")
            }
        }
        Button {
            app.openAudiobook(book.item)
        } label: {
            Label("Show Details", systemImage: "info.circle")
        }
        Divider()
        Button {
            app.setFinished(book.item, !book.isFinished)
        } label: {
            if book.isFinished {
                Label("Mark as Not Started", systemImage: "arrow.counterclockwise")
            } else {
                Label("Mark as Finished", systemImage: "checkmark.circle")
            }
        }
        if book.isStarted, !book.isFinished {
            Button {
                app.setFinished(book.item, false)
            } label: {
                Label("Mark as Not Started", systemImage: "arrow.counterclockwise")
            }
        }
        Button {
            app.toggleFavorite(book.item)
        } label: {
            Label(book.item.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: book.item.isFavorite ? "heart.slash" : "heart")
        }
        Divider()
        let downloaded = app.downloadRecords(of: book)
        let missing = book.parts.contains { part in
            switch app.downloads.status(of: part.id) {
            case nil, .failed: true
            default: false
            }
        }
        if missing {
            Button {
                app.downloadAudiobook(book.item)
            } label: {
                Label("Download Audiobook", systemImage: "arrow.down.circle")
            }
        }
        if !downloaded.isEmpty {
            Button(role: .destructive) {
                app.removeDownloads(of: book)
            } label: {
                Label("Remove Download", systemImage: "trash")
            }
        }
    }
}

// MARK: - Download button

/// The download button of a book's page: download what's missing, cancel while downloading, or remove once
/// every file is downloaded.
struct AudiobookDownloadButton: View {
    var book: Audiobook

    @Environment(AppModel.self) private var app
    @State private var confirmingRemoval = false

    var body: some View {
        let summary = app.downloadSummary(of: book)
        let isComplete = summary.total > 0 && summary.completed == summary.total
        let pending = summary.pending > 0
        Button {
            if isComplete {
                confirmingRemoval = true
            } else if pending {
                for part in book.parts where [.queued, .downloading].contains(app.downloads.status(of: part.id)) {
                    app.downloads.remove(part.id)
                }
            } else {
                app.downloadAudiobook(book)
            }
        } label: {
            if pending {
                if book.isMultiPart {
                    ProgressRing(progress: Double(summary.completed) / Double(max(summary.total, 1)))
                        .frame(width: 18, height: 18)
                } else if let part = book.parts.first {
                    DownloadProgressRing(itemId: part.id)
                        .frame(width: 18, height: 18)
                }
            } else {
                Image(systemName: isComplete ? "arrow.down.circle.fill" : "arrow.down.circle")
            }
        }
        .buttonStyle(CircleIconButtonStyle(size: 42, active: isComplete))
        .disabled(book.parts.isEmpty)
        .help(help(summary, isComplete: isComplete, pending: pending))
        .confirmationDialog("Remove the download of “\(book.title)”?", isPresented: $confirmingRemoval) {
            Button("Remove Download", role: .destructive) {
                app.removeDownloads(of: book)
            }
        } message: {
            Text("The audiobook will no longer be available offline.")
        }
    }

    private func help(_ summary: (completed: Int, pending: Int, total: Int), isComplete: Bool, pending: Bool) -> String {
        if isComplete {
            return String(localized: "Downloaded (click to remove)")
        }
        if pending {
            return book.isMultiPart ? String(localized: "Downloaded \(summary.completed) of \(summary.total) files (click to cancel)")
                : String(localized: "Downloading (click to cancel)")
        }
        return String(localized: "Download for Offline Listening")
    }
}

// MARK: - Playback controls

/// The speeds offered for audiobooks.
enum PlaybackSpeed {
    static let options: [Double] = [0.75, 0.9, 1, 1.1, 1.2, 1.25, 1.3, 1.5, 1.75, 2, 2.5, 3]

    static func label(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

/// A button showing the speed, with a menu of speeds.
struct BookSpeedMenu: View {
    var music: MusicPlayer
    var size: CGFloat = 30

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Menu {
            Picker("Playback Speed", selection: Binding(get: { music.rate }, set: { music.setRate($0) })) {
                ForEach(PlaybackSpeed.options, id: \.self) { rate in
                    Text(PlaybackSpeed.label(rate)).tag(rate)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(PlaybackSpeed.label(music.rate))
                .font(.system(size: size * 0.42, weight: .bold).monospacedDigit())
                .foregroundStyle(music.rate == 1 ? .white.opacity(hovering ? 1 : 0.8) : palette.accent)
                .padding(.horizontal, 8)
                .frame(minWidth: size, minHeight: size)
                .background(.white.opacity(hovering ? 0.1 : 0), in: Capsule())
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Playback Speed")
    }
}

/// A moon button with the sleep timer's options, and the time left while it runs.
struct SleepTimerMenu: View {
    var music: MusicPlayer
    var size: CGFloat = 30

    static let minutes = [5, 10, 15, 30, 45, 60, 90]

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Menu {
            SleepTimerItems(music: music)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: music.sleepTimer == nil ? "moon.zzz" : "moon.zzz.fill")
                    .font(.system(size: size * 0.45, weight: .semibold))
                if let timer = music.sleepTimer {
                    SleepTimerLabel(timer: timer, isBook: music.book != nil)
                        .font(.system(size: size * 0.38, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundStyle(music.sleepTimer == nil ? .white.opacity(hovering ? 1 : 0.8) : palette.accent)
            .padding(.horizontal, music.sleepTimer == nil ? 0 : 8)
            .frame(minWidth: size, minHeight: size)
            .background(.white.opacity(hovering ? 0.1 : 0), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Sleep Timer")
    }
}

/// The sleep timer's options, for its button and the Playback menu.
struct SleepTimerItems: View {
    var music: MusicPlayer

    var body: some View {
        Toggle("Off", isOn: Binding(get: { music.sleepTimer == nil }, set: { if $0 { music.setSleepTimer(nil) } }))
        Divider()
        ForEach(SleepTimerMenu.minutes, id: \.self) { minutes in
            Button("\(minutes) Minutes") {
                music.setSleepTimer(.at(.now.addingTimeInterval(Double(minutes) * 60)))
            }
        }
        Divider()
        Toggle(music.book == nil ? "End of Song" : "End of Chapter", isOn: Binding(
            get: { music.sleepTimer == .endOfChapter },
            set: { music.setSleepTimer($0 ? .endOfChapter : nil) }
        ))
    }
}

/// The time left until the sleep timer pauses, counting down every second.
struct SleepTimerLabel: View {
    var timer: MusicPlayer.SleepTimer
    var isBook: Bool

    var body: some View {
        switch timer {
        case let .at(deadline):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Format.time(max(0, deadline.timeIntervalSince(context.date))))
            }
        case .endOfChapter:
            Text(isBook ? "Chapter End" : "Song End")
        }
    }
}

extension AppSettings {
    /// The SF Symbol for skipping by an interval, with the number in it where one exists.
    static func skipSymbol(_ seconds: Double, forward: Bool) -> String {
        let base = forward ? "goforward" : "gobackward"
        let value = Int(seconds)
        return [5, 10, 15, 30, 45, 60, 75, 90].contains(value) ? "\(base).\(value)" : base
    }
}

// MARK: - Chapters

/// A chapter in a list: number or playing indicator, title, start time, and length. Chapters already
/// listened to are dimmed.
struct ChapterRow: View {
    var chapter: BookChapter
    var isCurrent: Bool
    var isPlaying: Bool
    var isDone: Bool
    var compact = false
    var onPlay: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if hovering, !isCurrent {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(palette.text)
                } else if isCurrent {
                    NowPlayingIndicator(isPlaying: isPlaying)
                } else {
                    Text("\(chapter.id + 1)")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(palette.tertiaryText)
                }
            }
            .frame(width: 28)

            Text(chapter.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isCurrent ? palette.accent : palette.text)
                .lineLimit(compact ? 1 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !compact {
                Text(Format.time(chapter.start))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(palette.tertiaryText)
                    .frame(width: 70, alignment: .trailing)
            }
            Text(Format.time(chapter.duration))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(palette.tertiaryText)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, compact ? 8 : 12)
        .frame(height: compact ? 38 : 44)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? palette.accent.opacity(0.12) : .white.opacity(hovering ? 0.07 : 0))
        }
        .opacity(isDone && !isCurrent ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .onHover { hovering = $0 }
        .help("Play from Here")
    }
}

extension AppModel {
    /// The download records of a book's files, including those of files the book doesn't list yet, e.g. when it
    /// came from search results.
    func downloadRecords(of book: Audiobook) -> [DownloadRecord] {
        if !book.isMultiPart {
            return downloads.records[book.item.id].map { [$0] } ?? []
        }
        let key = book.item.id + "|" + (book.item.album ?? "")
        let ids = Set(book.parts.map(\.id))
        return downloads.records.values.filter { ids.contains($0.id) || ($0.item.isAudiobook && Audiobook.groupKey($0.item) == key) }
    }

    /// Removes and cancels the downloads of every file of a book.
    func removeDownloads(of book: Audiobook) {
        downloadRecords(of: book).forEach { downloads.remove($0.id) }
    }

    /// Resolves the whole book first, so every file is marked.
    func setFinished(_ seed: BaseItem, _ finished: Bool) {
        Task {
            do {
                setFinished(try await audiobook(for: seed), finished)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
