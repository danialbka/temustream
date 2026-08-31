import Foundation
import SwiftUI
import UIKit

enum BoundedArtworkPhase {
    case empty
    case success(UIImage)
    case failure
}

/// A finite, already-decoded image store for deterministic in-process harnesses.
/// It never participates in URL trust or network loading; production's default
/// environment value is nil.
@MainActor
final class EmbeddedArtworkImageStore {
    private static let maximumEntryCount = 16
    private let imagesByURL: [URL: UIImage]

    init(imagesByURL: [URL: UIImage]) {
        precondition(imagesByURL.count <= Self.maximumEntryCount)
        precondition(imagesByURL.values.allSatisfy(Self.isWithinMobileDecodeLimits))
        self.imagesByURL = imagesByURL
    }

    func image(for url: URL) -> UIImage? {
        imagesByURL[url]
    }

    func containsAll(_ urls: [URL]) -> Bool {
        urls.allSatisfy { imagesByURL[$0] != nil }
    }

    private static func isWithinMobileDecodeLimits(_ image: UIImage) -> Bool {
        let width = Int64(image.cgImage?.width ?? Int(image.size.width * image.scale))
        let height = Int64(image.cgImage?.height ?? Int(image.size.height * image.scale))
        return ArtworkResourcePolicy.allowsDecodedFrames(
            [ArtworkDecodedFrame(width: width, height: height)],
            limits: .mobile
        )
    }
}

private struct EmbeddedArtworkImageStoreKey: EnvironmentKey {
    static let defaultValue: EmbeddedArtworkImageStore? = nil
}

extension EnvironmentValues {
    var embeddedArtworkImageStore: EmbeddedArtworkImageStore? {
        get { self[EmbeddedArtworkImageStoreKey.self] }
        set { self[EmbeddedArtworkImageStoreKey.self] = newValue }
    }
}

/// Phase-driven view backed by the shared bounded artwork cache.
struct BoundedArtworkImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (BoundedArtworkPhase) -> Content

    @Environment(\.embeddedArtworkImageStore) private var embeddedArtworkImageStore
    @State private var phase: BoundedArtworkPhase = .empty

    var body: some View {
        content(phase)
            .task(id: url) {
                phase = .empty
                guard let url else {
                    phase = .failure
                    return
                }
                if let image = embeddedArtworkImageStore?.image(for: url) {
                    phase = .success(image)
                    return
                }
                guard let data = await ArtworkDataCache.shared.data(
                        for: url,
                        limits: .mobile
                      ),
                      !Task.isCancelled,
                      let image = UIImage(data: data)
                else {
                    if !Task.isCancelled {
                        phase = .failure
                    }
                    return
                }
                phase = .success(image)
            }
    }
}

/// Poster/backdrop image view backed by ArtworkDataCache. Decoding happens only
/// after the async fetch completes and the view is still interested in the URL.
struct CachedArtworkImage: View {
    let url: URL?
    var placeholderSystemImage = "film"

    var body: some View {
        GeometryReader { geometry in
            BoundedArtworkImage(url: url) { phase in
                if case let .success(image) = phase {
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
        }
        .clipped()
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
        await ArtworkDataCache.shared.prefetch(
            urls,
            limits: .mobile,
            limit: urls.count
        )
    }
}
