import Foundation
import Observation

/// New and unwatched videos across all YouTube channels, newest upload first.
@MainActor
@Observable
final class FeedModel {
    private(set) var items: [BaseItem] = []
    private(set) var total = 0
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    var channelFilter: String?

    let pageSize: Int

    init(pageSize: Int = 48) {
        self.pageSize = pageSize
    }

    var canLoadMore: Bool { items.count < total }

    func reload(_ app: AppModel, keepCount: Bool = false) async {
        let count = keepCount ? max(items.count, pageSize) : pageSize
        await fetch(app, limit: count, replace: true)
    }

    func loadMore(_ app: AppModel) async {
        guard canLoadMore, !isLoading else {
            return
        }
        await fetch(app, limit: items.count + pageSize, replace: true)
    }

    func apply(_ change: ItemChange?, includeWatched: Bool) {
        guard let change else {
            return
        }
        items.apply(change)
        if !includeWatched, change.userData?.played == true, let index = items.firstIndex(where: { $0.id == change.itemId }) {
            items.remove(at: index)
            total = max(0, total - 1)
        }
    }

    private func fetch(_ app: AppModel, limit: Int, replace: Bool) async {
        guard let client = app.client else {
            return
        }
        let parents: [String]
        if let channelFilter {
            parents = [channelFilter]
        } else {
            parents = app.youTubeLibraries.map(\.id)
        }
        guard !parents.isEmpty else {
            items = []
            total = 0
            hasLoaded = true
            return
        }
        isLoading = true
        defer { isLoading = false }

        let settings = app.settings
        var query = ItemQuery()
        query.includeItemTypes = [ItemType.episode, ItemType.video]
        query.sortBy = settings.feedOrder.sortBy
        query.sortOrder = Array(repeating: settings.feedOldestFirst ? "Ascending" : "Descending", count: query.sortBy.count)
        query.isPlayed = settings.feedIncludeWatched ? nil : false
        query.limit = limit
        query.fields = ["Overview", "PrimaryImageAspectRatio", "DateCreated", "Path"]
        do {
            var merged: [BaseItem] = []
            var totalCount = 0
            // `parentId` takes a single ID, so several libraries are fetched and merged.
            for parent in parents {
                query.parentId = parent
                let response = try await client.items(query)
                merged += response.items
                totalCount += response.totalRecordCount ?? response.items.count
            }
            if parents.count > 1 {
                merged.sort { lhs, rhs in
                    let left = (settings.feedOrder == .uploadDate ? lhs.uploadDate : lhs.dateCreated) ?? .distantPast
                    let right = (settings.feedOrder == .uploadDate ? rhs.uploadDate : rhs.dateCreated) ?? .distantPast
                    return settings.feedOldestFirst ? left < right : left > right
                }
                merged = Array(merged.prefix(limit))
            }
            items = merged
            total = totalCount
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        hasLoaded = true
    }
}
