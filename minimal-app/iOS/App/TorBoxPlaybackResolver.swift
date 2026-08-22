import Foundation

enum TorBoxPlaybackError: LocalizedError {
    case rejected(Int)
    case nonMediaResponse(String)
    case invalidRedirect
    case providerStillPreparing

    var errorDescription: String? {
        switch self {
        case let .rejected(status):
            "TorBox rejected the stream request (HTTP \(status))."
        case let .nonMediaResponse(type):
            "TorBox returned \(type) instead of a media stream."
        case .invalidRedirect:
            "TorBox returned an invalid redirect."
        case .providerStillPreparing:
            "The provider is still preparing this stream. Try again in a moment."
        }
    }
}

private final class TorBoxRedirectBlocker: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Resolves TorBox permalinks immediately before playback. TorBox's API docs
/// recommend keeping requestdl permalinks and following them to a short-lived
/// CDN URL instead of saving the CDN URL. A 4 KiB range request follows that
/// redirect, identifies relabeled containers, and primes the CDN without
/// downloading the movie twice.
struct TorBoxResolvedSource: Sendable {
    let url: URL
    let detectedMIMEType: String?
    let contentLength: Int64?
    let supportsByteRanges: Bool
}

enum TorBoxPlaybackResolver {
    static func shouldResolve(stream: Stream, url: URL, providerName: String? = nil) -> Bool {
        if url.host?.localizedCaseInsensitiveContains("torbox") == true {
            return true
        }
        let metadata = [providerName, stream.name, stream.title, stream.description]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return metadata.contains("torbox")
            || metadata.contains("scraper tb")
            || metadata.contains("[tb]")
    }

    static func resolve(
        _ input: URL,
        stream: Stream? = nil
    ) async throws -> TorBoxResolvedSource {
        let expectedSizeBytes = stream.flatMap {
            TorBoxStreamSelection.expectedSizeBytes(
                in: [$0.title, $0.name, $0.description]
            )
        }
        let permalink = redirectingPermalink(input)
        var url = permalink
        var repairPermalink = isTorrentRequestDownload(permalink) ? permalink : nil
        var repairedFileSelection = false
        var redirectHops = 0
        var readinessPollCount = 0
        var consecutiveNetworkFailures = 0
        let queryKeys = URLComponents(url: input, resolvingAgainstBaseURL: false)?
            .queryItems?.map(\.name).sorted().joined(separator: ",") ?? ""
        NSLog(
            "TORBOX_STREAM_SOURCE host=%@ file=%@ query_keys=%@ expected_bytes=%lld",
            input.host ?? "unknown",
            input.lastPathComponent,
            queryKeys,
            expectedSizeBytes ?? 0
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let redirectBlocker = TorBoxRedirectBlocker()
        for _ in 0..<160 {
            var request = URLRequest(url: url)
            request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let signature: Data
            let response: URLResponse
            do {
                (signature, response) = try await session.data(
                    for: request,
                    delegate: redirectBlocker
                )
                consecutiveNetworkFailures = 0
            } catch {
                guard isRetryableNetworkError(error), consecutiveNetworkFailures < 2 else {
                    throw error
                }
                consecutiveNetworkFailures += 1
                let delay = 0.35 * Double(consecutiveNetworkFailures)
                NSLog(
                    "TORBOX_STREAM_RETRY attempt=%ld delay_s=%.2f host=%@ error=%@",
                    consecutiveNetworkFailures,
                    delay,
                    url.host ?? "unknown",
                    (error as NSError).localizedDescription
                )
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            guard let http = response as? HTTPURLResponse else {
                return TorBoxResolvedSource(
                    url: url,
                    detectedMIMEType: nil,
                    contentLength: nil,
                    supportsByteRanges: false
                )
            }

            if (300...399).contains(http.statusCode) {
                redirectHops += 1
                guard redirectHops <= 6 else {
                    throw TorBoxPlaybackError.invalidRedirect
                }
                guard let location = http.value(forHTTPHeaderField: "Location"),
                      let redirected = URL(string: location, relativeTo: url)?.absoluteURL
                else {
                    throw TorBoxPlaybackError.invalidRedirect
                }
                url = redirectingPermalink(redirected)
                if isTorrentRequestDownload(url) {
                    repairPermalink = url
                }
                continue
            }

            guard (200...299).contains(http.statusCode) else {
                throw TorBoxPlaybackError.rejected(http.statusCode)
            }

            if let expectedSizeBytes,
               let resolvedSizeBytes = responseSize(http),
               TorBoxStreamSelection.shouldRepair(
                   expectedSizeBytes: expectedSizeBytes,
                   resolvedSizeBytes: resolvedSizeBytes
               ) {
                if !repairedFileSelection,
                   let repairPermalink,
                   let repaired = try await repairedPermalink(
                       repairPermalink,
                       expectedSizeBytes: expectedSizeBytes
                   ) {
                    let oldID = queryValue("file_id", in: repairPermalink) ?? "unknown"
                    let newID = queryValue("file_id", in: repaired) ?? "unknown"
                    NSLog(
                        "TORBOX_STREAM_REPAIR reason=size-mismatch expected_bytes=%lld actual_bytes=%lld old_file_id=%@ new_file_id=%@",
                        expectedSizeBytes,
                        resolvedSizeBytes,
                        oldID,
                        newID
                    )
                    repairedFileSelection = true
                    url = repaired
                    redirectHops = 0
                    continue
                }

                guard readinessPollCount < 40 else {
                    throw TorBoxPlaybackError.providerStillPreparing
                }
                readinessPollCount += 1
                let delay = min(1.0 + Double(readinessPollCount - 1) * 0.25, 3.0)
                NSLog(
                    "TORBOX_STREAM_WAIT attempt=%ld delay_s=%.2f expected_bytes=%lld actual_bytes=%lld",
                    readinessPollCount,
                    delay,
                    expectedSizeBytes,
                    resolvedSizeBytes
                )
                try await Task.sleep(for: .seconds(delay))
                url = permalink
                repairPermalink = isTorrentRequestDownload(permalink) ? permalink : nil
                redirectHops = 0
                continue
            }

            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
                .lowercased()
            if contentType.contains("application/json") || contentType.contains("text/html") {
                throw TorBoxPlaybackError.nonMediaResponse(contentType)
            }
            return TorBoxResolvedSource(
                url: url,
                detectedMIMEType: MediaContainerSniffer.detectedMIMEType(
                    signature: signature,
                    serverMIMEType: contentType
                ),
                contentLength: responseSize(http),
                supportsByteRanges: http.statusCode == 206
                    && http.value(forHTTPHeaderField: "Content-Range") != nil
            )
        }
        throw TorBoxPlaybackError.invalidRedirect
    }

    private static func redirectingPermalink(_ input: URL) -> URL {
        guard isTorrentRequestDownload(input)
        else { return input }
        var components = URLComponents(url: input, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.removeAll { $0.name.caseInsensitiveCompare("redirect") == .orderedSame }
        items.append(URLQueryItem(name: "redirect", value: "true"))
        components?.queryItems = items
        return components?.url ?? input
    }

    private static func isTorrentRequestDownload(_ url: URL) -> Bool {
        url.host?.caseInsensitiveCompare("api.torbox.app") == .orderedSame
            && url.path.localizedCaseInsensitiveContains("/torrents/requestdl")
    }

    private static func responseSize(_ response: HTTPURLResponse) -> Int64? {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let total = contentRange.split(separator: "/").last,
           total != "*",
           let size = Int64(total) {
            return size
        }
        guard response.statusCode == 200, response.expectedContentLength > 0 else {
            return nil
        }
        return response.expectedContentLength
    }

    private static func repairedPermalink(
        _ permalink: URL,
        expectedSizeBytes: Int64
    ) async throws -> URL? {
        guard permalink.host?.caseInsensitiveCompare("api.torbox.app") == .orderedSame,
              permalink.path.localizedCaseInsensitiveContains("/torrents/requestdl"),
              let token = queryValue("token", in: permalink),
              let torrentID = queryValue("torrent_id", in: permalink),
              let currentFileID = queryValue("file_id", in: permalink).flatMap(Int.init)
        else { return nil }

        var listComponents = URLComponents(
            string: "https://api.torbox.app/v1/api/torrents/mylist"
        )
        listComponents?.queryItems = [URLQueryItem(name: "id", value: torrentID)]
        guard let listURL = listComponents?.url else { return nil }
        var request = URLRequest(url: listURL)
        request.timeoutInterval = 5
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 7
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let envelope = try? JSONDecoder().decode(TorBoxTorrentListEnvelope.self, from: data),
              let torrent = envelope.torrents.first,
              let replacementID = TorBoxStreamSelection.replacementFileID(
                  files: torrent.files,
                  currentFileID: currentFileID,
                  expectedSizeBytes: expectedSizeBytes
              )
        else { return nil }

        var components = URLComponents(url: permalink, resolvingAgainstBaseURL: false)
        if let queryItems = components?.queryItems {
            components?.queryItems = queryItems.map { item in
                item.name.caseInsensitiveCompare("file_id") == .orderedSame
                    ? URLQueryItem(name: item.name, value: String(replacementID))
                    : item
            }
        }
        return components?.url
    }

    private static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?
            .value
    }

    private static func isRetryableNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return switch urlError.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable:
            true
        default:
            false
        }
    }
}

private struct TorBoxTorrentListEnvelope: Decodable {
    let torrents: [Torrent]

    struct Torrent: Decodable {
        let files: [TorBoxFileCandidate]
    }

    private enum CodingKeys: String, CodingKey { case data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let single = try? container.decode(Torrent.self, forKey: .data) {
            torrents = [single]
        } else {
            torrents = try container.decode([Torrent].self, forKey: .data)
        }
    }
}
