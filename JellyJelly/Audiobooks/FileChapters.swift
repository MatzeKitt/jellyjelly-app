import AVFoundation

/// Reads chapters from audiobook files, for servers that don't extract them from audio, e.g. the chapter
/// track of an M4B. Results are kept for the session, since reading a remote file takes a moment.
actor FileChapters {
    static let shared = FileChapters()

    private var cache: [String: [Chapter]] = [:]
    private var loads: [String: Task<[Chapter], Never>] = [:]

    /// The containers that carry chapters AVFoundation reads.
    static func mayHaveChapters(_ file: BaseItem) -> Bool {
        let path = (file.path ?? file.primaryMediaSource?.path ?? "") as NSString
        let containers = ["m4b", "m4a", "mp4", "aac", "mov"]
        if containers.contains(path.pathExtension.lowercased()) {
            return true
        }
        let container = file.container ?? file.primaryMediaSource?.container ?? ""
        return container.split(separator: ",").contains { containers.contains(String($0).lowercased()) }
    }

    /// The chapters of a file, or none if it has fewer than two.
    func chapters(of itemId: String, at url: URL) async -> [Chapter] {
        if let cached = cache[itemId] {
            return cached
        }
        if let load = loads[itemId] {
            return await load.value
        }
        let load = Task.detached(priority: .userInitiated) { await Self.read(url) }
        loads[itemId] = load
        let chapters = await load.value
        loads[itemId] = nil
        cache[itemId] = chapters
        return chapters
    }

    private static func read(_ url: URL) async -> [Chapter] {
        let asset = AVURLAsset(url: url)
        guard let groups = try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages),
              groups.count > 1
        else {
            return []
        }
        var chapters: [Chapter] = []
        for group in groups {
            let start = group.timeRange.start.seconds
            guard start.isFinite else {
                continue
            }
            let title = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
            let name = try? await title?.load(.stringValue)
            chapters.append(Chapter(startPositionTicks: start.ticks, name: name))
        }
        return chapters
    }
}

extension AppModel {
    /// Fills in chapters the server doesn't know from the files themselves: the downloaded copy, or the stream.
    func addingFileChapters(to book: Audiobook) async -> Audiobook {
        var parts = book.parts
        var changed = false
        await withTaskGroup(of: (Int, [Chapter]).self) { group in
            for (index, part) in parts.enumerated() where (part.chapters ?? []).count < 2 && FileChapters.mayHaveChapters(part) {
                guard let url = chapterSourceURL(of: part) else {
                    continue
                }
                group.addTask {
                    (index, await FileChapters.shared.chapters(of: part.id, at: url))
                }
            }
            for await (index, chapters) in group where chapters.count > 1 {
                parts[index].chapters = chapters
                changed = true
            }
        }
        return changed ? Audiobook(item: book.item, parts: parts) : book
    }

    private func chapterSourceURL(of part: BaseItem) -> URL? {
        if let copy = downloads.offlineCopy(of: part.id) {
            return copy.fileURL
        }
        guard let client else {
            return nil
        }
        let source = part.primaryMediaSource ?? MediaSource(id: part.id)
        return client.audioStreamURL(itemId: part.id, mediaSource: source, playSessionId: nil)
    }
}
