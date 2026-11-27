import SwiftUI

/// An audiobook's page: cover, author, progress, description, and its chapters, which play from where they start.
struct AudiobookView: View {
    /// A file of the book, or the folder of a book made of several files.
    var seed: BaseItem

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @State private var book: Audiobook?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            if let book {
                content(book)
            } else if let failure {
                EmptyStateView(systemImage: "exclamationmark.triangle", title: String(localized: "Couldn't load the audiobook"), message: failure)
                    .frame(height: 480)
            } else {
                LoadingView().frame(height: 480)
            }
        }
        .scrollIndicators(.never)
        .ignoresSafeArea(edges: .top)
        .task(id: "\(seed.id)|\(app.refreshGeneration)") {
            await load()
        }
        .onChange(of: app.lastChange) { _, change in
            if let change {
                book?.apply(change.itemId, change.userData)
            }
        }
    }

    /// Whether this book is the one in the player.
    private func isLoaded(_ book: Audiobook) -> Bool {
        app.music.book?.id == book.id
    }

    /// Where listening continues: live while the book is in the player, otherwise from the server.
    private func position(in book: Audiobook) -> Double {
        isLoaded(book) ? app.music.bookPosition : (book.isFinished ? 0 : book.resumePosition)
    }

    private func content(_ book: Audiobook) -> some View {
        let loaded = isLoaded(book)
        let position = position(in: book)
        let current = loaded || book.isStarted ? book.chapter(at: position) : nil
        return VStack(alignment: .leading, spacing: 32) {
            MusicHeader(kind: String(localized: "Audiobook"), title: book.title, artworkURL: app.coverURL(of: book, width: 800),
                        placeholderImage: "book.closed.fill", subtitle: author(book), details: details(book)) {
                Button {
                    if loaded, app.music.isPlaying {
                        app.music.pause()
                    } else {
                        app.playAudiobook(book)
                    }
                } label: {
                    Label(playTitle(book, loaded: loaded), systemImage: loaded && app.music.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(book.parts.isEmpty)

                if book.isStarted || loaded {
                    Button {
                        app.playAudiobook(book, startOver: true)
                    } label: {
                        Label("Start Over", systemImage: "backward.end.fill")
                    }
                    .buttonStyle(AccentButtonStyle(prominent: false))
                }

                Button {
                    app.toggleFavorite(book.item)
                } label: {
                    Image(systemName: book.item.isFavorite ? "heart.fill" : "heart")
                }
                .buttonStyle(CircleIconButtonStyle(size: 42, active: book.item.isFavorite))
                .help(book.item.isFavorite ? "Remove from Favorites" : "Add to Favorites")

                AudiobookDownloadButton(book: book)

                Menu {
                    AudiobookMenuItems(book: book, app: app)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(CircleIconButtonStyle(size: 42))
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if (book.isStarted || loaded), !book.isFinished, book.duration > 0 {
                progress(book, position: position, chapter: current)
                    .padding(.horizontal, Metrics.pagePadding)
            }

            if let overview = book.overview {
                ExpandableText(text: overview, lines: 4)
                    .frame(maxWidth: 820, alignment: .leading)
                    .padding(.horizontal, Metrics.pagePadding)
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: String(localized: "Chapters"), subtitle: String(localized: "\(book.chapters.count) chapters"))
                    .padding(.horizontal, Metrics.pagePadding)
                LazyVStack(spacing: 2) {
                    ForEach(book.chapters) { chapter in
                        ChapterRow(chapter: chapter, isCurrent: chapter.id == current?.id, isPlaying: loaded && app.music.isPlaying,
                                   isDone: book.isFinished || chapter.end <= position) {
                            app.playAudiobook(book, from: chapter)
                        }
                    }
                }
                .padding(.horizontal, Metrics.pagePadding - 12)
            }
        }
        .padding(.bottom, 60)
    }

    private func progress(_ book: Audiobook, position: Double, chapter: BookChapter?) -> some View {
        let fraction = min(max(position / book.duration, 0), 1)
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule().fill(palette.accent).frame(width: proxy.size.width * fraction)
                }
            }
            .frame(width: 420, height: 6)
            HStack(spacing: 6) {
                Text("\(Format.duration(book.duration - position)) left · \(Int((fraction * 100).rounded()))%")
                if let chapter, book.chapters.count > 1 {
                    Text("·")
                    Text(chapter.title)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.secondaryText)
        }
    }

    private func playTitle(_ book: Audiobook, loaded: Bool) -> String {
        if loaded, app.music.isPlaying {
            return String(localized: "Pause")
        }
        if book.isFinished, !loaded {
            return String(localized: "Listen Again")
        }
        return book.isStarted || loaded ? String(localized: "Resume") : String(localized: "Play")
    }

    private func author(_ book: Audiobook) -> AnyView? {
        guard let author = book.author else {
            return nil
        }
        return AnyView(
            Text(author)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(palette.accent)
        )
    }

    private func details(_ book: Audiobook) -> [String] {
        var values: [String] = []
        if let year = book.item.productionYear ?? book.parts.first?.productionYear {
            values.append(String(year))
        }
        if let genres = book.item.genres ?? book.parts.first?.genres, !genres.isEmpty {
            values.append(genres.prefix(2).joined(separator: ", "))
        }
        if book.duration > 0 {
            values.append(Format.duration(book.duration))
        }
        if book.isMultiPart {
            values.append(String(localized: "\(book.parts.count) files"))
        }
        if book.isFinished {
            values.append(String(localized: "Finished"))
        }
        let bytes = book.parts.reduce(Int64(0)) { $0 + ($1.primaryMediaSource?.size ?? 0) }
        if bytes > 0 {
            values.append(Format.bytes(Double(bytes)))
        }
        return values
    }

    private func load() async {
        do {
            book = try await app.audiobook(for: seed)
            failure = nil
        } catch {
            if book == nil {
                failure = error.localizedDescription
            }
        }
    }
}
