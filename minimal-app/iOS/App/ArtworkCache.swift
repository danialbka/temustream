import Foundation
import ImageIO
import SwiftUI
import UIKit

/// A small, bounded image-data cache shared by discovery surfaces. It coalesces
/// duplicate requests and warms URLCache so returning to a shelf does not
/// repeatedly decode or download the same poster.
actor ArtworkDataCache {
    static let shared = ArtworkDataCache()

    private let maximumEntries = 120
    private let maximumTotalBytes = 64 * 1_024 * 1_024
    private let maximumBytesPerImage = 12 * 1_024 * 1_024
    private var dataByURL: [URL: Data] = [:]
    private var recency: [URL] = []
    private var inFlight: [URL: Task<Data?, Never>] = [:]
    private var totalBytes = 0

    func data(for url: URL) async -> Data? {
        if let cached = dataByURL[url] {
            touch(url)
            return cached
        }
        if let request = inFlight[url] {
            return await request.value
        }

        let byteLimit = maximumBytesPerImage
        let request = Task<Data?, Never> {
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.user == nil,
                  url.password == nil
            else { return nil }
            var urlRequest = URLRequest(
                url: url,
                cachePolicy: .returnCacheDataElseLoad,
                timeoutInterval: 15
            )
            urlRequest.setValue("image/*", forHTTPHeaderField: "Accept")
            let configuration = URLSessionConfiguration.default
            guard let (data, response) = try? await BoundedHTTPDataLoader.load(
                request: urlRequest,
                maximumBytes: byteLimit,
                configuration: configuration
            ),
                  !Task.isCancelled,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  http.value(forHTTPHeaderField: "Content-Type")?
                    .lowercased()
                    .hasPrefix("image/") == true,
                  !data.isEmpty,
                  data.count <= byteLimit,
                  Self.hasSafeDecodedDimensions(data)
            else { return nil }
            return data
        }
        inFlight[url] = request
        let loaded = await request.value
        inFlight[url] = nil
        guard let loaded else { return nil }
        insert(loaded, for: url)
        return loaded
    }

    func prefetch(_ urls: [URL], limit: Int = 6) async {
        var seen = Set<URL>()
        let unique = urls.filter { seen.insert($0).inserted }.prefix(max(0, limit))
        await withTaskGroup(of: Void.self) { group in
            for url in unique {
                group.addTask { _ = await self.data(for: url) }
            }
        }
    }

    private func insert(_ data: Data, for url: URL) {
        if let existing = dataByURL[url] {
            totalBytes -= existing.count
        }
        dataByURL[url] = data
        totalBytes += data.count
        touch(url)
        while recency.count > maximumEntries || totalBytes > maximumTotalBytes,
              let oldest = recency.first {
            recency.removeFirst()
            totalBytes -= dataByURL[oldest]?.count ?? 0
            dataByURL[oldest] = nil
        }
    }

    private func touch(_ url: URL) {
        recency.removeAll { $0 == url }
        recency.append(url)
    }

    private nonisolated static func hasSafeDecodedDimensions(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else { return false }
        let widthValue = width.int64Value
        let heightValue = height.int64Value
        guard (1...16_384).contains(widthValue),
              (1...16_384).contains(heightValue),
              widthValue <= Int64.max / heightValue
        else { return false }
        return widthValue * heightValue <= 100_000_000
    }
}

/// Poster/backdrop image view backed by ArtworkDataCache. Decoding happens only
/// after the async fetch completes and the view is still interested in the URL.
struct CachedArtworkImage: View {
    let url: URL?
    var placeholderSystemImage = "film"

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            } else {
                ZStack {
                    Color.appPlaceholderBackground
                    Image(systemName: placeholderSystemImage)
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .clipped()
        .task(id: url) {
            image = nil
            guard let url,
                  let data = await ArtworkDataCache.shared.data(for: url),
                  !Task.isCancelled
            else { return }
            image = UIImage(data: data)
        }
    }
}

enum ArtworkPrefetch {
    static func near(
        _ items: [MetaItem],
        index: Int,
        lookBehind: Int = 2,
        lookAhead: Int = 6
    ) async {
        guard !items.isEmpty else { return }
        let indices = NearViewportPrefetchPolicy.indices(
            visibleRange: index..<(index + 1),
            itemCount: items.count,
            lookBehind: lookBehind,
            lookAhead: lookAhead
        )
        let urls = indices.compactMap { items[$0].poster }
        await ArtworkDataCache.shared.prefetch(urls, limit: urls.count)
    }
}
