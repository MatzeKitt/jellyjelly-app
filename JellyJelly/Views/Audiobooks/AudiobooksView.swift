import SwiftUI

enum AudiobookSort: String, CaseIterable, Identifiable {
    case title
    case author
    case dateAdded
    case datePlayed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: String(localized: "Title")
        case .author: String(localized: "Author")
        case .dateAdded: String(localized: "Date Added")
        case .datePlayed: String(localized: "Date Played")
        }
    }

    var defaultDescending: Bool {
        switch self {
        case .title, .author: false
        case .dateAdded, .datePlayed: true
        }
    }

    func ascending(_ a: Audiobook, _ b: Audiobook) -> Bool {
        switch self {
        case .title:
            return a.sortTitle.localizedStandardCompare(b.sortTitle) == .orderedAscending
        case .author:
            let order = (a.author ?? "").localizedStandardCompare(b.author ?? "")
            return order == .orderedSame ? a.sortTitle.localizedStandardCompare(b.sortTitle) == .orderedAscending : order == .orderedAscending
        case .dateAdded:
            return (a.dateAdded ?? .distantPast) < (b.dateAdded ?? .distantPast)
        case .datePlayed:
            return (a.lastPlayedDate ?? .distantPast) < (b.lastPlayedDate ?? .distantPast)
        }
    }
}

/// The audiobooks of a library of the type "Books": what's being listened to, then every book, with sorting,
/// a filter, and an A–Z index.
struct AudiobooksView: View {
    var library: BaseItem

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    @State private var books: [Audiobook] = []
    @State private var loaded = false
    @State private var failure: String?
    @State private var sort = AudiobookSort.title
    @State private var descending = false
    @State private var hideFinished = false
    @State private var filterText = ""

    private var shown: [Audiobook] {
        let term = filterText.trimmingCharacters(in: .whitespaces)
        let filtered = books.filter { book in
            (!hideFinished || !book.isFinished)
                && (term.isEmpty || book.title.localizedCaseInsensitiveContains(term) || (book.author ?? "").localizedCaseInsensitiveContains(term))
        }
        let sorted = filtered.sorted(by: sort.ascending)
        return descending ? sorted.reversed() : sorted
    }

    /// Started, unfinished books, the one listened to last first.
    private var inProgress: [Audiobook] {
        books.filter { $0.progress != nil || ($0.isStarted && !$0.isFinished) }
            .sorted { ($0.lastPlayedDate ?? .distantPast) > ($1.lastPlayedDate ?? .distantPast) }
    }

    var body: some View {
        let shown = shown
        let letters = sort == .title ? shown.reduce(into: [String]()) { seen, book in
            if !seen.contains(book.indexLetter) {
                seen.append(book.indexLetter)
            }
        } : []
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    header

                    if !loaded {
                        LoadingView().frame(height: 300)
                    } else if let failure, books.isEmpty {
                        EmptyStateView(systemImage: "exclamationmark.triangle", title: String(localized: "Couldn't load the audiobooks"), message: failure)
                            .frame(height: 320)
                    } else if books.isEmpty {
                        EmptyStateView(systemImage: "books.vertical", title: String(localized: "No audiobooks yet"),
                                       message: String(localized: "Audiobook files in this library show up here. A folder of files sharing an album tag plays as one book. E-books aren't supported."))
                            .frame(height: 320)
                    } else {
                        let continuing = inProgress
                        if !continuing.isEmpty, filterText.isEmpty {
                            Shelf(title: String(localized: "Continue Listening")) {
                                ForEach(continuing) { book in
                                    BookCard(book: book, width: 150)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            if !continuing.isEmpty, filterText.isEmpty {
                                SectionHeader(title: String(localized: "All Audiobooks"))
                                    .padding(.horizontal, Metrics.pagePadding)
                            }
                            if shown.isEmpty {
                                EmptyStateView(systemImage: "books.vertical", title: String(localized: "Nothing to show"), message: String(localized: "Try a different filter."))
                                    .frame(height: 260)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 200), spacing: 22, alignment: .top)], alignment: .leading, spacing: 26) {
                                    ForEach(shown) { book in
                                        BookCard(book: book)
                                            .id(book.id)
                                    }
                                }
                                .padding(.horizontal, Metrics.pagePadding)
                                .padding(.trailing, 24)
                            }
                        }
                    }
                }
                .padding(.bottom, 60)
            }
            .scrollIndicators(.never)
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .trailing) {
                if letters.count > 3 {
                    LetterIndex(letters: letters) { letter in
                        if let target = shown.first(where: { $0.indexLetter == letter }) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(target.id, anchor: .top)
                            }
                        }
                    }
                    .padding(.trailing, 8)
                }
            }
        }
        .task(id: "\(library.id)|\(app.refreshGeneration)") {
            await load()
        }
        .onChange(of: app.lastChange) { _, change in
            guard let change else {
                return
            }
            for index in books.indices where books[index].item.id == change.itemId || books[index].parts.contains(where: { $0.id == change.itemId }) {
                books[index].apply(change.itemId, change.userData)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(title: library.displayName, subtitle: books.isEmpty ? nil : String(localized: "\(books.count) audiobooks"))
            HStack(spacing: 10) {
                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(AudiobookSort.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Picker("Order", selection: $descending) {
                        Text("Ascending").tag(false)
                        Text("Descending").tag(true)
                    }
                    .pickerStyle(.inline)
                } label: {
                    FilterChip(title: sort.title, systemImage: "arrow.up.arrow.down", active: false)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .onChange(of: sort) { _, value in
                    descending = value.defaultDescending
                }

                Button {
                    hideFinished.toggle()
                } label: {
                    FilterChip(title: String(localized: "Hide Finished"), systemImage: "checkmark.circle", active: hideFinished)
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(palette.tertiaryText)
                    TextField("Filter", text: $filterText)
                        .textFieldStyle(.plain)
                        .frame(width: 160)
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(.white.opacity(0.08), in: Capsule())
            }
            .padding(.horizontal, Metrics.pagePadding)
        }
    }

    private func load() async {
        do {
            books = try await app.audiobooks(in: library)
            failure = nil
        } catch {
            // Offline: the downloaded books of this library, if any.
            failure = error.localizedDescription
            if books.isEmpty {
                books = app.downloadedAudiobooks()
            }
        }
        loaded = true
    }
}

extension Audiobook {
    /// The title without leading articles, which the server provides for single files.
    var sortTitle: String {
        isMultiPart ? title : (item.sortName ?? title)
    }

    var indexLetter: String {
        guard let first = sortTitle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).uppercased().first else {
            return "#"
        }
        return first.isLetter ? String(first) : "#"
    }

    var dateAdded: Date? {
        parts.compactMap(\.dateCreated).max() ?? item.dateCreated
    }
}

extension AppModel {
    /// Every book with downloaded files, for browsing while the server can't be reached.
    func downloadedAudiobooks() -> [Audiobook] {
        Audiobook.books(from: downloads.records.values.filter(\.isComplete).map(\.item))
    }
}
