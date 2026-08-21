import Foundation
import StremioSkeletonCore

private let pages: [[MetaItem]] = (0..<10).map { page in
    (0..<100).map { offset in
        let index = page * 100 + offset
        return MetaItem(
            id: "tt\(1_000_000 + index)",
            type: "movie",
            name: "Benchmark Movie \(index)",
            releaseInfo: "2026"
        )
    }
}

private func measure(iterations: Int, operation: () throws -> Void) rethrows -> [Double] {
    try (0..<iterations).map { _ in
        let start = DispatchTime.now().uptimeNanoseconds
        try operation()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000
    }
}

private func median(_ samples: [Double]) -> Double {
    let sorted = samples.sorted()
    return sorted[sorted.count / 2]
}

private func naiveAppend(_ pages: [[MetaItem]]) -> [MetaItem] {
    var result: [MetaItem] = []
    for page in pages {
        for item in page where !result.contains(where: {
            $0.type == item.type && $0.id == item.id
        }) {
            result.append(item)
        }
    }
    return result
}

let encodedPage = try JSONEncoder().encode(CatalogResponse(metas: pages[0]))
let decodeSamples = try measure(iterations: 100) {
    _ = try JSONDecoder().decode(CatalogResponse.self, from: encodedPage)
}
let optimizedSamples = measure(iterations: 100) {
    var accumulator = CatalogPageAccumulator()
    for page in pages {
        accumulator.append(page, supportsSkip: true)
    }
    precondition(accumulator.items.count == 1_000)
}
let naiveSamples = measure(iterations: 20) {
    precondition(naiveAppend(pages).count == 1_000)
}

var duplicateGuard = CatalogPageAccumulator()
duplicateGuard.append(pages[0], supportsSkip: true)
duplicateGuard.append(pages[0], supportsSkip: true)
precondition(duplicateGuard.items.count == 100 && !duplicateGuard.canLoadMore)

let optimizedMedian = median(optimizedSamples)
let naiveMedian = median(naiveSamples)
let speedup = naiveMedian / max(optimizedMedian, 0.000_001)

print("Catalog paging benchmark (release, 1,000 items)")
print(String(format: "first-page JSON decode median: %.3f ms", median(decodeSamples)))
print(String(format: "Set-backed append median: %.3f ms", optimizedMedian))
print(String(format: "Naive repeated-scan median: %.3f ms", naiveMedian))
print(String(format: "Append speedup: %.1fx", speedup))
print("Duplicate-page stop: PASS")

guard optimizedMedian < naiveMedian else {
    fputs("Optimized paging did not beat naive accumulation\n", stderr)
    exit(1)
}
