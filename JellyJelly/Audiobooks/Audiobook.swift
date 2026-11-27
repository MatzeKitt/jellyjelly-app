import Foundation

/// A chapter of an audiobook, with its times counted from the start of the book.
struct BookChapter: Identifiable, Hashable, Sendable {
    /// The chapter's position in the book, starting at 0.
    var id: Int
    var title: String
    var start: Double
    var end: Double
    /// The file the chapter is in.
    var part: Int

    var duration: Double { max(0, end - start) }
}

/// A book to listen to: a single file, usually with chapters, or the files of a folder, which play one after
/// another as its parts. Without chapters in the files, every part is a chapter.
struct Audiobook: Identifiable, Equatable, Sendable {
    /// The `AudioBook` item of a single file, or the folder holding the parts. A folder carries the album tag
    /// its parts share in `album`, so the book can be found again among other files of the same folder.
    var item: BaseItem
    private(set) var parts: [BaseItem]
    /// Where each part starts in the book.
    private(set) var offsets: [Double] = []
    private(set) var chapters: [BookChapter] = []
    private(set) var duration: Double = 0

    var id: String { item.id }
    var isMultiPart: Bool { !item.isAudiobook }

    init(item: BaseItem, parts: [BaseItem]) {
        self.item = item
        self.parts = parts
        var total = 0.0
        for (index, part) in parts.enumerated() {
            offsets.append(total)
            let length = part.duration ?? 0
            let marks = (part.chapters ?? [])
                .compactMap { chapter in chapter.startPositionTicks.map { (start: $0.tickSeconds, name: chapter.name) } }
                .filter { length <= 0 || $0.start < length }
                .sorted { $0.start < $1.start }
            if marks.count < 2 {
                // A single chapter covering the whole file says nothing the part doesn't.
                let title = marks.first?.name.flatMap(Self.nonEmpty) ?? (parts.count > 1 ? part.displayName : nil)
                chapters.append(BookChapter(id: chapters.count, title: title ?? String(localized: "Chapter \(chapters.count + 1)"),
                                            start: total, end: total + length, part: index))
            } else {
                for (number, mark) in marks.enumerated() {
                    // The first chapter starts with the file, even if its mark comes a moment later.
                    let start = number == 0 ? total : total + mark.start
                    let end = number + 1 < marks.count ? total + marks[number + 1].start : total + length
                    guard end > start else {
                        continue
                    }
                    chapters.append(BookChapter(id: chapters.count, title: mark.name.flatMap(Self.nonEmpty) ?? String(localized: "Chapter \(chapters.count + 1)"),
                                                start: start, end: end, part: index))
                }
            }
            total += length
        }
        duration = total
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Details

    /// The album tag of a book made of several files usually holds its title, while the files hold chapter names.
    var title: String {
        isMultiPart ? (item.album ?? parts.first?.album ?? item.displayName) : item.displayName
    }

    var author: String? {
        let first = parts.first
        let people = (item.people ?? []) + (first?.people ?? [])
        return item.albumArtist ?? first?.albumArtist ?? first?.artistLine ?? people.first { $0.type == "Author" }?.name
    }

    var overview: String? {
        [item.overview, parts.first?.overview].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// Where a part starts in the book.
    func offset(of part: Int) -> Double {
        offsets.indices.contains(part) ? offsets[part] : 0
    }

    /// The file playing at a time in the book.
    func part(at seconds: Double) -> Int {
        offsets.lastIndex { $0 <= seconds } ?? 0
    }

    /// The chapter playing at a time in the book.
    func chapter(at seconds: Double) -> BookChapter? {
        chapters.last { $0.start <= seconds + 0.05 } ?? chapters.first
    }

    // MARK: - Progress

    var isFinished: Bool { !parts.isEmpty && parts.allSatisfy(\.isPlayed) }
    var isStarted: Bool { parts.contains { $0.isPlayed || $0.resumePosition > 0 || $0.userData?.lastPlayedDate != nil } }
    var lastPlayedDate: Date? { parts.compactMap { $0.userData?.lastPlayedDate }.max() }

    /// The part listening continues in, and the position in it: where the part listened to last stopped,
    /// or the start of the next part once that one was finished.
    var resumePoint: (part: Int, position: Double) {
        guard !isFinished, !parts.isEmpty else {
            return (0, 0)
        }
        if let last = parts.indices.filter({ parts[$0].userData?.lastPlayedDate != nil })
            .max(by: { (parts[$0].userData?.lastPlayedDate ?? .distantPast) < (parts[$1].userData?.lastPlayedDate ?? .distantPast) }) {
            if !parts[last].isPlayed {
                return (last, parts[last].resumePosition)
            }
            if let next = parts.indices.first(where: { $0 > last && !parts[$0].isPlayed }) {
                return (next, 0)
            }
        }
        let first = parts.firstIndex { !$0.isPlayed } ?? 0
        return (first, parts[first].resumePosition)
    }

    /// The time in the book listening continues at.
    var resumePosition: Double {
        let point = resumePoint
        return offset(of: point.part) + point.position
    }

    var listenedSeconds: Double {
        isFinished ? duration : parts.reduce(0) { $0 + ($1.isPlayed ? ($1.duration ?? 0) : $1.resumePosition) }
    }

    /// How much of a started, unfinished book was listened to, between 0 and 1.
    var progress: Double? {
        guard duration > 0, !isFinished else {
            return nil
        }
        let fraction = listenedSeconds / duration
        return fraction > 0 ? min(fraction, 1) : nil
    }

    /// Patches a user-data change into the book, e.g. after a part was played.
    mutating func apply(_ itemId: String, _ data: UserItemData?) {
        guard let data else {
            return
        }
        if item.id == itemId {
            item.userData = data
        }
        for index in parts.indices where parts[index].id == itemId {
            parts[index].userData = data
        }
    }

    // MARK: - Grouping files into books

    /// Files in one folder that share their album tag belong to the same book.
    static func groupKey(_ file: BaseItem) -> String {
        (file.parentId ?? file.id) + "|" + (file.album ?? "")
    }

    /// Groups audiobook files into books, in the order of their first file.
    ///
    /// - Parameter folders: The folders holding the files, for the name and artwork of books made of several files.
    static func books(from files: [BaseItem], folders: [String: BaseItem] = [:]) -> [Audiobook] {
        var groups: [String: [BaseItem]] = [:]
        var order: [String] = []
        for file in files where file.isAudiobook {
            let key = groupKey(file)
            if groups[key] == nil {
                order.append(key)
            }
            groups[key, default: []].append(file)
        }
        return order.compactMap { key in
            guard let files = groups[key], let first = files.first else {
                return nil
            }
            if files.count == 1 {
                return Audiobook(item: first, parts: files)
            }
            return Audiobook(item: folder(of: first, among: folders), parts: sortedParts(files))
        }
    }

    /// The folder a file of a book made of several files is in, standing for the whole book.
    static func folder(of file: BaseItem, among folders: [String: BaseItem] = [:]) -> BaseItem {
        let id = file.parentId ?? file.id
        var folder = folders[id] ?? BaseItem(id: id, name: file.album ?? file.displayName, type: ItemType.folder)
        folder.album = file.album
        folder.albumArtist = folder.albumArtist ?? file.albumArtist
        return folder
    }

    /// Parts in the order they're read: by disc and track number, then by file name.
    static func sortedParts(_ files: [BaseItem]) -> [BaseItem] {
        files.sorted { a, b in
            let left = (a.parentIndexNumber ?? 0, a.indexNumber ?? 0)
            let right = (b.parentIndexNumber ?? 0, b.indexNumber ?? 0)
            if left != right {
                return left < right
            }
            let nameA = a.path.map { ($0 as NSString).lastPathComponent } ?? a.sortName ?? a.displayName
            let nameB = b.path.map { ($0 as NSString).lastPathComponent } ?? b.sortName ?? b.displayName
            return nameA.localizedStandardCompare(nameB) == .orderedAscending
        }
    }
}

enum AudiobookError: LocalizedError {
    case empty

    var errorDescription: String? {
        String(localized: "This audiobook has no files to play.")
    }
}
