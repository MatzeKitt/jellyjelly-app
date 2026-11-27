import Foundation

/// Browsing, playing, and downloading audiobooks.
extension AppModel {
    var hasAudiobooks: Bool { !audiobookLibraries.isEmpty }

    // MARK: - Loading

    /// Every audiobook in a library, grouped into books.
    func audiobooks(in library: BaseItem) async throws -> [Audiobook] {
        guard let client else {
            throw APIError.notAuthenticated
        }
        let pageSize = 1000
        var files: [BaseItem] = []
        while true {
            var query = ItemQuery()
            query.parentId = library.id
            query.includeItemTypes = [ItemType.audioBook]
            query.fields = ["ParentId", "SortName", "DateCreated", "Path"]
            query.startIndex = files.count
            query.limit = pageSize
            query.enableTotalRecordCount = false
            let page = try await client.items(query).items
            files += page
            if page.count < pageSize {
                break
            }
        }
        // Books made of several files show the name and artwork of their folder.
        let groups = Dictionary(grouping: files, by: Audiobook.groupKey)
        let folderIds = Set(groups.values.filter { $0.count > 1 }.compactMap { $0.first?.parentId })
        let folders = await items(withIds: Array(folderIds))
        return Audiobook.books(from: files, folders: folders)
    }

    private func items(withIds ids: [String]) async -> [String: BaseItem] {
        guard let client else {
            return [:]
        }
        var found: [String: BaseItem] = [:]
        for start in stride(from: 0, to: ids.count, by: 100) {
            var query = ItemQuery()
            query.ids = Array(ids[start..<min(ids.count, start + 100)])
            query.fields = ["Overview", "SortName", "DateCreated"]
            query.enableTotalRecordCount = false
            for item in (try? await client.items(query).items) ?? [] {
                found[item.id] = item
            }
        }
        return found
    }

    /// The whole book a file belongs to, or the book of a folder, with its chapters. Falls back to the
    /// downloaded files while the server can't be reached.
    func audiobook(for seed: BaseItem) async throws -> Audiobook {
        let book: Audiobook
        do {
            book = try await fetchAudiobook(seed)
        } catch {
            guard let offline = offlineAudiobook(for: seed) else {
                throw error
            }
            book = offline
        }
        return await addingFileChapters(to: book)
    }

    private func fetchAudiobook(_ seed: BaseItem) async throws -> Audiobook {
        guard let client else {
            throw APIError.notAuthenticated
        }
        let folderId = seed.isAudiobook ? seed.parentId : seed.id
        var siblings: [BaseItem] = []
        if let folderId {
            var query = ItemQuery()
            query.parentId = folderId
            query.recursive = false
            query.includeItemTypes = [ItemType.audioBook]
            query.fields = JellyfinClient.standardFields + ["ParentId", "SortName", "Chapters", "MediaSources", "People"]
            query.enableTotalRecordCount = false
            siblings = try await client.items(query).items.filter { ($0.album ?? "") == (seed.album ?? "") }
        }
        if seed.isAudiobook, siblings.count <= 1 {
            // The single-item endpoint includes the chapters and media sources.
            let item = try await client.item(seed.id)
            return Audiobook(item: item, parts: [item])
        }
        guard let folderId, let first = siblings.first else {
            throw AudiobookError.empty
        }
        var folder = (try? await client.item(folderId)) ?? Audiobook.folder(of: first)
        folder.album = first.album
        folder.albumArtist = folder.albumArtist ?? first.albumArtist
        return Audiobook(item: folder, parts: Audiobook.sortedParts(siblings))
    }

    /// The downloaded files of a book.
    func offlineAudiobook(for seed: BaseItem) -> Audiobook? {
        let key = seed.isAudiobook ? Audiobook.groupKey(seed) : seed.id + "|" + (seed.album ?? "")
        let parts = downloads.records.values
            .filter { $0.isComplete && $0.item.isAudiobook && Audiobook.groupKey($0.item) == key }
            .map(\.item)
        guard let first = parts.first else {
            return nil
        }
        if seed.isAudiobook, parts.count == 1 {
            return Audiobook(item: first, parts: parts)
        }
        return Audiobook(item: seed.isAudiobook ? Audiobook.folder(of: first) : seed, parts: Audiobook.sortedParts(parts))
    }

    /// The cover of a book: a downloaded copy first, so it shows offline, then the folder's, then the first file's.
    func coverURL(of book: Audiobook, width: Int) -> URL? {
        if let first = book.parts.first, let local = downloads.imageURL(for: first.id, "cover") {
            return local
        }
        return client?.coverURL(book.item, width: width) ?? book.parts.first.flatMap { client?.coverURL($0, width: width) }
    }

    // MARK: - Navigation and playback

    func openAudiobook(_ seed: BaseItem) {
        showsNowPlaying = false
        path.append(.audiobook(seed))
    }

    /// Continues a book where it was left, or starts it over.
    func playAudiobook(_ seed: BaseItem, startOver: Bool = false) {
        if !startOver, let book = music.book, book.id == seed.id || book.parts.contains(where: { $0.id == seed.id }) {
            music.play()
            return
        }
        Task {
            do {
                playAudiobook(try await audiobook(for: seed), startOver: startOver)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Plays a book from one of its files, where that file was left.
    func playAudiobook(from file: BaseItem) {
        if let book = music.book, music.current?.id == file.id, book.parts.contains(where: { $0.id == file.id }) {
            music.play()
            return
        }
        Task {
            do {
                let book = try await audiobook(for: file)
                let part = book.parts.firstIndex { $0.id == file.id } ?? 0
                let item = book.parts[part]
                music.playBook(book, part: part, at: item.isPlayed ? 0 : item.resumePosition)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Plays a book from a chapter, from where it was left, or from the beginning.
    func playAudiobook(_ book: Audiobook, from chapter: BookChapter? = nil, startOver: Bool = false) {
        if let chapter {
            music.playBook(book, part: chapter.part, at: chapter.start - book.offset(of: chapter.part))
            return
        }
        if !startOver, music.book?.id == book.id {
            music.play()
            return
        }
        let point = startOver ? (part: 0, position: 0.0) : book.resumePoint
        music.playBook(book, part: point.part, at: point.position)
    }

    // MARK: - Downloads

    func downloadAudiobook(_ seed: BaseItem) {
        Task {
            do {
                downloadAudiobook(try await audiobook(for: seed))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Downloads a single file right away; for a book made of several files, asks first.
    func downloadAudiobook(_ book: Audiobook) {
        for part in book.parts {
            if case .failed = downloads.status(of: part.id) {
                downloads.retry(part.id)
            }
        }
        let missing = book.parts.filter { downloads.status(of: $0.id) == nil }
        guard book.isMultiPart else {
            downloads.enqueue(missing)
            return
        }
        downloadRequest = DownloadRequest(container: book.item, items: missing, isAudiobook: true)
    }

    /// The downloaded, downloading, and failed files of a book.
    func downloadSummary(of book: Audiobook) -> (completed: Int, pending: Int, total: Int) {
        let statuses = book.parts.map { downloads.status(of: $0.id) }
        return (statuses.filter { $0 == .completed }.count, statuses.filter { $0 == .queued || $0 == .downloading }.count, book.parts.count)
    }

    // MARK: - Progress

    /// Marks every file as played, or resets the whole book to not started.
    func setFinished(_ book: Audiobook, _ finished: Bool) {
        guard let client else {
            return
        }
        Task {
            do {
                for part in book.parts {
                    let touched = part.isPlayed || part.resumePosition > 0 || part.userData?.lastPlayedDate != nil
                    guard finished ? !part.isPlayed : touched else {
                        continue
                    }
                    broadcast(part.id, try await client.setPlayed(part.id, played: finished))
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
