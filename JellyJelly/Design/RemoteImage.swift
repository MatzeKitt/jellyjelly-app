import AppKit
import ImageIO
import SwiftUI

/// Loads and caches artwork in memory and on disk.
actor ImageLoader {
    static let shared = ImageLoader()

    // NSCache is thread-safe, so the synchronous cache check needs no actor hop.
    private nonisolated(unsafe) let memory = NSCache<NSURL, CGImage>()
    private var inFlight: [URL: Load] = [:]
    private let session: URLSession

    init() {
        memory.totalCostLimit = 400 * 1024 * 1024
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 1024 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)
    }

    nonisolated func cached(_ url: URL) -> CGImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> CGImage? {
        if let image = memory.object(forKey: url as NSURL) {
            return image
        }
        if let load = inFlight[url], !load.task.isCancelled {
            return await wait(for: load)
        }
        let session = self.session
        let load = Load(task: Task<CGImage?, Never>.detached(priority: .userInitiated) {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400
            else {
                return nil
            }
            return Self.decode(data)
        })
        inFlight[url] = load
        let image = await wait(for: load)
        if inFlight[url] === load {
            inFlight[url] = nil
        }
        if let image {
            memory.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        }
        return image
    }

    /// Cards that scroll out of view cancel their wait, so their downloads stop holding up the visible ones.
    private func wait(for load: Load) async -> CGImage? {
        load.waiters += 1
        return await withTaskCancellationHandler {
            await load.task.value
        } onCancel: {
            Task { await self.abandon(load) }
        }
    }

    private func abandon(_ load: Load) {
        load.waiters -= 1
        if load.waiters == 0 {
            load.task.cancel()
        }
    }

    /// Decodes the pixels here instead of lazily on first draw, which would stall scrolling on the main thread.
    private nonisolated static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// One download, shared by everyone waiting for the same image.
    private final class Load {
        let task: Task<CGImage?, Never>
        var waiters = 0

        init(task: Task<CGImage?, Never>) {
            self.task = task
        }
    }
}

struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: CGImage?
    @State private var loadedURL: URL?

    var body: some View {
        // Lazy grids recreate cells while scrolling, so a cached image shows right away instead of after a placeholder frame.
        let shown = loadedURL == url ? image : url.flatMap(ImageLoader.shared.cached)
        ZStack {
            if let shown {
                Image(decorative: shown, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                loadedURL = nil
                return
            }
            if let cached = ImageLoader.shared.cached(url) {
                image = cached
                loadedURL = url
                return
            }
            let loaded = await ImageLoader.shared.image(for: url)
            guard !Task.isCancelled else {
                return
            }
            withAnimation(.easeOut(duration: 0.2)) {
                image = loaded
                loadedURL = url
            }
        }
    }
}

extension RemoteImage where Placeholder == Color {
    init(url: URL?, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = { Color.white.opacity(0.06) }
    }
}
