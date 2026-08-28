@preconcurrency import AVFoundation
import Foundation
import SwiftUI
import UIKit

struct PlayerStressMetrics: Codable, Sendable {
    let title: String
    let startupMilliseconds: Double
    let seekAttempts: Int
    let successfulSeeks: Int
    let seekMedianMilliseconds: Double
    let seekP95Milliseconds: Double
    let seekSyncRecoveryMilliseconds: [Double]
    let seekSyncRecoveryP95Milliseconds: Double
    let pauseResumeAttempts: Int
    let successfulPauseResumes: Int
    let pausedSeekPreserved: Bool
    let videoUnderflowIntervals: Int
    let videoQueueStateTransitions: Int
    let nominalFPS: Double
    let enqueuedVideoFPS: Double
    let droppedVideoFrames: UInt32
    let droppedVideoPackets: UInt32
    let realTimeRatio: Double
    let rendererUnderflowSkewP95Milliseconds: Double
    let rendererUnderflowSkewMaxMilliseconds: Double
    let longestVideoUnderflowMilliseconds: Double
    let audioTrackCount: Int
    let videoTrackCount: Int
    let renderedVideoFrame: Bool

    var passed: Bool {
        // This is source/sample cadence, not a claim about frames presented by
        // AVSampleBufferDisplayLayer. The renderer does not expose a displayed
        // frame counter, so playback smoothness is gated separately by queue
        // underflow and media-clock continuity.
        let packetCadenceIsPlausible = nominalFPS <= 0
            || enqueuedVideoFPS <= 0
            || (enqueuedVideoFPS >= nominalFPS * 0.75
                && enqueuedVideoFPS <= nominalFPS * 1.50)
        return startupMilliseconds <= 12_000
            && successfulSeeks == seekAttempts
            && seekP95Milliseconds <= 2_500
            && seekSyncRecoveryP95Milliseconds <= 3_000
            && successfulPauseResumes == pauseResumeAttempts
            && pausedSeekPreserved
            && realTimeRatio >= 0.95
            && rendererUnderflowSkewP95Milliseconds <= 150
            && rendererUnderflowSkewMaxMilliseconds <= 300
            && longestVideoUnderflowMilliseconds <= 350
            && videoUnderflowIntervals == 0
            && videoQueueStateTransitions <= 2
            && droppedVideoFrames <= 5
            && packetCadenceIsPlausible
            && (videoTrackCount == 0 || renderedVideoFrame)
    }
}

struct RealPlayerStressEntry: Codable, Sendable {
    let movie: String
    let provider: String
    let sourceProfile: String
    let metrics: PlayerStressMetrics?
    let error: String?
}

struct RealPlayerStressReport: Codable, Sendable {
    let generatedAt: Date
    let requestedMovies: Int
    let testedMovies: Int
    let passedMovies: Int
    let entries: [RealPlayerStressEntry]

    var passed: Bool {
        testedMovies == requestedMovies && passedMovies == requestedMovies
    }
}

struct ObsessionStreamStressEntry: Codable, Sendable {
    let streamIndex: Int
    let provider: String
    let sourceProfile: String
    let engine: String?
    let metrics: PlayerStressMetrics?
    let error: String?
}

struct ObsessionStreamStressReport: Codable, Sendable {
    let generatedAt: Date
    let requestedStreams: Int
    let availableStreams: Int
    let testedStreams: Int
    let passedStreams: Int
    let entries: [ObsessionStreamStressEntry]

    var passed: Bool {
        testedStreams == requestedStreams && passedStreams == requestedStreams
    }
}

struct SingleMoviePlaybackAuditReport: Codable, Sendable {
    let generatedAt: Date
    let movie: String
    let provider: String
    let streamTitle: String?
    let sourceProfile: String?
    let engine: String
    let audioOutput: String
    let metrics: PlayerStressMetrics?
    let error: String?

    var passed: Bool { metrics?.passed == true && error == nil }
}

private final class BunnyStressProbe {
    var info: BunnyNativeMediaInfo?
    var firstFrameRendered = false
    var failure: Error?
    var ended = false
    var seekRevision = 0
    var seekSucceeded = false
    var decodedVideoFrames = 0
    var droppedVideoFrames = 0
    var renderedAudioFrames = 0
    var bufferedDuration: TimeInterval = 0
    var videoQueueEnd = TimeInterval.nan
    var audioQueueEnd = TimeInterval.nan

    func bind(to decoder: BunnyNativeDecoder) {
        decoder.onOpen = { [weak self] info in
            guard let self else { return }
            let options = info.audioTracks.map {
                PlaybackLanguageOption(
                    languageTag: $0.language,
                    displayName: $0.title
                )
            }
            if let preferredIndex = PlaybackLanguageMatcher.bestMatchIndex(
                in: options,
                preferredLanguage: PlaybackLanguagePreferences.preferredAudioLanguage()
            ), info.audioTracks.indices.contains(preferredIndex) {
                decoder.selectAudioStreamIndex(info.audioTracks[preferredIndex].streamIndex)
            }
            self.info = info
        }
        decoder.onFirstFrame = { [weak self] in
            self?.firstFrameRendered = true
        }
        decoder.onSeekCompleted = { [weak self] _, succeeded in
            guard let self else { return }
            seekSucceeded = succeeded
            seekRevision += 1
        }
        decoder.onMetrics = { [weak self] decoded, dropped, audio, buffered, videoEnd, audioEnd in
            guard let self else { return }
            decodedVideoFrames = decoded
            droppedVideoFrames = dropped
            renderedAudioFrames = audio
            bufferedDuration = max(buffered, 0)
            videoQueueEnd = videoEnd
            audioQueueEnd = audioEnd
        }
        decoder.onEnded = { [weak self] in
            self?.ended = true
        }
        decoder.onFailure = { [weak self] error in
            self?.failure = error
        }
    }
}

/// Measures Bunny's Rust Matroska/WebM path with Apple's sample-buffer
/// decoders and renderers attached, so backpressure and frame pacing remain
/// representative of production playback.
@MainActor
private enum BunnyPlayerStressBenchmark {
    static func measure(
        url: URL,
        title: String,
        visible: Bool = false,
        startupTimeout: TimeInterval = 30,
        minimumDuration: TimeInterval = 4,
        seekFractions: [Double] = [0.10, 0.50, 0.85, 0.25, 0.70],
        cadenceSampleSeconds: TimeInterval = 12
    ) async throws -> PlayerStressMetrics {
        // Exercise the production movie-session policy as part of the stress
        // gate. Previously the simulator benchmark bypassed this setup, so it
        // could not catch AirPods/multichannel route regressions.
        PlaybackAudioSession.beginPlayback()
        let window = foregroundWindow()
        let host = UIView(
            frame: visible
                ? (window?.bounds ?? UIScreen.main.bounds)
                : CGRect(x: -4, y: -4, width: 2, height: 2)
        )
        host.isUserInteractionEnabled = false
        host.alpha = visible ? 1 : 0.01
        host.backgroundColor = .black
        window?.addSubview(host)

        #if targetEnvironment(simulator)
        let trustedPrivateOrigin = ["127.0.0.1", "localhost", "::1"]
            .contains(url.host?.lowercased() ?? "") ? url : nil
        #else
        let trustedPrivateOrigin: URL? = nil
        #endif
        let decoder = BunnyNativeDecoder(
            url: url,
            trustedPrivateNetworkOrigin: trustedPrivateOrigin
        )
        decoder.videoLayer.frame = host.bounds
        decoder.videoLayer.videoGravity = .resizeAspect
        host.layer.addSublayer(decoder.videoLayer)
        let probe = BunnyStressProbe()
        probe.bind(to: decoder)

        defer {
            decoder.stop()
            decoder.videoLayer.removeFromSuperlayer()
            host.removeFromSuperview()
            PlaybackAudioSession.endPlayback()
        }

        let startupStartedAt = ProcessInfo.processInfo.systemUptime
        NSLog("PLAYER_STRESS_STEP startup_begin title=%@", title)
        decoder.start()
        try await waitUntil(timeout: startupTimeout, probe: probe) {
            probe.info != nil && probe.firstFrameRendered
        }
        decoder.play(atRate: 1)
        try await waitUntil(timeout: 5, probe: probe) {
            decoder.currentTime > 0.15
        }
        let startupMilliseconds = elapsedMilliseconds(since: startupStartedAt)
        NSLog("PLAYER_STRESS_STEP startup_end title=%@ elapsed_ms=%.1f", title, startupMilliseconds)

        guard let info = probe.info else { throw PlayerStressError.timedOut }
        let duration = info.duration
        guard duration.isFinite, duration >= minimumDuration else {
            throw PlayerStressError.invalidDuration(duration)
        }

        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment[
            "SKELETON_BUNNY_AUDIO_ROUTE_AUDIT"
        ] == "1" {
            try await auditAudioRendererRecovery(
                decoder: decoder,
                probe: probe,
                info: info
            )
        }
        #endif

        var seekLatencies = [Double]()
        var seekSyncLatencies = [Double]()
        var successfulSeeks = 0
        for (seekIndex, fraction) in seekFractions.enumerated() {
            let target = min(max(duration * fraction, 0.5), duration - 1)
            decoder.pause()
            let revision = probe.seekRevision
            let decodedBeforeSeek = decoder.metricsSnapshot.decodedVideoFrames
            let seekStartedAt = ProcessInfo.processInfo.systemUptime
            NSLog("PLAYER_STRESS_STEP seek_begin title=%@ index=%ld", title, seekIndex + 1)
            decoder.seek(to: target)
            try await waitUntil(timeout: 15, probe: probe) {
                probe.seekRevision > revision
            }
            let seekMilliseconds = elapsedMilliseconds(since: seekStartedAt)
            seekLatencies.append(seekMilliseconds)
            guard probe.seekSucceeded else { continue }

            decoder.play(atRate: 1)
            do {
                let resumedTarget = min(target + 0.15, duration - 0.05)
                try await waitUntil(timeout: 12, probe: probe) {
                    let metrics = decoder.metricsSnapshot
                    let videoReady = !info.hasVideo
                        || (metrics.decodedVideoFrames > decodedBeforeSeek
                            && metrics.videoQueueEnd.isFinite
                            && metrics.videoQueueEnd >= target - 0.20)
                    return videoReady && decoder.currentTime >= resumedTarget
                }
                seekSyncLatencies.append(elapsedMilliseconds(since: seekStartedAt))
                successfulSeeks += 1
            } catch {
                NSLog(
                    "PLAYER_STRESS_STEP seek_resume_timeout title=%@ index=%ld target=%.3f current=%.3f video=%.3f",
                    title,
                    seekIndex + 1,
                    target,
                    decoder.currentTime,
                    probe.videoQueueEnd
                )
            }
        }

        let pauseResumeAttempts = 5
        var successfulPauseResumes = 0
        for _ in 0..<pauseResumeAttempts {
            let pausedAt = decoder.currentTime
            decoder.pause()
            try await Task.sleep(for: .milliseconds(120))
            let stayedPaused = decoder.rate == 0
                && abs(decoder.currentTime - pausedAt) < 0.20
            decoder.play(atRate: 1)
            do {
                try await waitUntil(timeout: 3, probe: probe) {
                    decoder.rate > 0 && decoder.currentTime >= pausedAt + 0.20
                }
                if stayedPaused { successfulPauseResumes += 1 }
            } catch {
                // Continue so the report captures all five cycles.
            }
        }

        let pausedSeekTarget = min(max(duration * 0.48, 0.5), duration - 1)
        decoder.pause()
        let pausedSeekRevision = probe.seekRevision
        decoder.seek(to: pausedSeekTarget)
        try await waitUntil(timeout: 15, probe: probe) {
            probe.seekRevision > pausedSeekRevision
        }
        decoder.pause()
        try await Task.sleep(for: .milliseconds(350))
        let pausedSeekPreserved = probe.seekSucceeded
            && decoder.rate == 0
            && abs(decoder.currentTime - pausedSeekTarget) < 2
        decoder.play(atRate: 1)
        do {
            try await waitUntil(timeout: 8, probe: probe) {
                decoder.rate > 0 && decoder.currentTime >= pausedSeekTarget + 0.35
            }
        } catch {
            let metrics = decoder.metricsSnapshot
            NSLog(
                "PLAYER_STRESS_STEP paused_seek_resume_timeout title=%@ current=%.3f video=%.3f audio=%.3f desired_rate=%.2f applied_rate=%.2f",
                title,
                decoder.currentTime,
                metrics.videoQueueEnd,
                metrics.audioQueueEnd,
                decoder.rate,
                decoder.synchronizer.rate
            )
            throw error
        }

        let sampleStartedAt = ProcessInfo.processInfo.systemUptime
        let mediaStartedAt = decoder.currentTime
        let rendererMetricsStartedAt = decoder.metricsSnapshot
        var underflowSince: TimeInterval?
        var isInsideCountedStall = false
        var videoUnderflowIntervals = 0
        var videoQueueStateTransitions = 0
        var wasBuffering = false
        var rendererUnderflowSkewSamples = [Double]()
        var longestVideoUnderflowMilliseconds = 0.0

        let cadenceSampleCount = max(Int(cadenceSampleSeconds * 10), 1)
        for _ in 0..<cadenceSampleCount {
            try await Task.sleep(for: .milliseconds(100))
            if let failure = probe.failure { throw failure }
            let now = ProcessInfo.processInfo.systemUptime
            let clock = decoder.currentTime
            let rendererMetrics = decoder.metricsSnapshot
            // The decoder intentionally fills several seconds of the sample
            // buffer and then waits for backpressure. A quiet decoder is not a
            // frozen picture while the display layer still has timed frames.
            // Count a visual stall only when playback has actually outrun the
            // end of the queued video timeline.
            let frameGrace = info.nominalFrameRate > 0
                ? max(2 / info.nominalFrameRate, 0.08)
                : 0.10
            let buffering = info.hasVideo
                && decoder.rate > 0
                && (!rendererMetrics.videoQueueEnd.isFinite
                    || clock > rendererMetrics.videoQueueEnd + frameGrace)
            if buffering != wasBuffering {
                videoQueueStateTransitions += 1
                wasBuffering = buffering
            }

            if buffering {
                underflowSince = underflowSince ?? now
                if let underflowSince {
                    if now - underflowSince >= 0.35,
                       !isInsideCountedStall {
                        videoUnderflowIntervals += 1
                        isInsideCountedStall = true
                    }
                    longestVideoUnderflowMilliseconds = max(
                        longestVideoUnderflowMilliseconds,
                        elapsedMilliseconds(since: underflowSince)
                    )
                }
            } else {
                underflowSince = nil
                isInsideCountedStall = false
            }

            if info.hasVideo,
               info.hasAudio,
               rendererMetrics.videoQueueEnd.isFinite,
               rendererMetrics.audioQueueEnd.isFinite {
                // Both renderers use the same AVSampleBufferRenderSynchronizer
                // clock. Queue tails may legitimately differ because demuxers
                // deliver packets in chunks; only unequal underflow can make
                // one renderer visibly or audibly fall behind the other.
                let videoUnderflow = max(clock - rendererMetrics.videoQueueEnd, 0)
                let audioUnderflow = max(clock - rendererMetrics.audioQueueEnd, 0)
                rendererUnderflowSkewSamples.append(
                    abs(videoUnderflow - audioUnderflow) * 1_000
                )
            }
        }

        let wallSeconds = ProcessInfo.processInfo.systemUptime - sampleStartedAt
        let mediaSeconds = max(decoder.currentTime - mediaStartedAt, 0)
        let rendererMetricsEndedAt = decoder.metricsSnapshot
        let decodedFrames = max(
            rendererMetricsEndedAt.decodedVideoFrames
                - rendererMetricsStartedAt.decodedVideoFrames,
            0
        )
        let enqueuedVideoSeconds = max(
            rendererMetricsEndedAt.videoQueueEnd
                - rendererMetricsStartedAt.videoQueueEnd,
            0
        )
        let enqueuedVideoFPS = enqueuedVideoSeconds > 0.25
            ? Double(decodedFrames) / enqueuedVideoSeconds
            : 0
        guard !info.hasAudio || rendererMetricsEndedAt.renderedAudioFrames > 0 else {
            throw PlayerStressError.missingAudioOutput
        }
        NSLog(
            "PLAYER_STRESS_STEP bunny_media title=%@ video_frames=%ld audio_frames=%ld video_end=%.3f audio_end=%.3f",
            title,
            rendererMetricsEndedAt.decodedVideoFrames,
            rendererMetricsEndedAt.renderedAudioFrames,
            rendererMetricsEndedAt.videoQueueEnd,
            rendererMetricsEndedAt.audioQueueEnd
        )
        return PlayerStressMetrics(
            title: title,
            startupMilliseconds: startupMilliseconds,
            seekAttempts: seekFractions.count,
            successfulSeeks: successfulSeeks,
            seekMedianMilliseconds: percentile(seekLatencies, percentile: 0.50),
            seekP95Milliseconds: percentile(seekLatencies, percentile: 0.95),
            seekSyncRecoveryMilliseconds: seekSyncLatencies,
            seekSyncRecoveryP95Milliseconds: percentile(
                seekSyncLatencies,
                percentile: 0.95
            ),
            pauseResumeAttempts: pauseResumeAttempts,
            successfulPauseResumes: successfulPauseResumes,
            pausedSeekPreserved: pausedSeekPreserved,
            videoUnderflowIntervals: videoUnderflowIntervals,
            videoQueueStateTransitions: videoQueueStateTransitions,
            nominalFPS: info.nominalFrameRate,
            enqueuedVideoFPS: enqueuedVideoFPS,
            droppedVideoFrames: UInt32(clamping: rendererMetricsEndedAt.droppedVideoFrames),
            droppedVideoPackets: 0,
            realTimeRatio: wallSeconds > 0 ? mediaSeconds / wallSeconds : 0,
            rendererUnderflowSkewP95Milliseconds: percentile(
                rendererUnderflowSkewSamples,
                percentile: 0.95,
                emptyValue: 0
            ),
            rendererUnderflowSkewMaxMilliseconds: rendererUnderflowSkewSamples.max() ?? 0,
            longestVideoUnderflowMilliseconds: longestVideoUnderflowMilliseconds,
            audioTrackCount: info.audioTracks.count,
            videoTrackCount: info.hasVideo ? 1 : 0,
            renderedVideoFrame: !info.hasVideo || probe.firstFrameRendered
        )
    }

    private static func waitUntil(
        timeout: TimeInterval,
        probe: BunnyStressProbe,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let failure = probe.failure { throw failure }
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw PlayerStressError.timedOut
    }

    #if targetEnvironment(simulator)
    /// Exercises the same automatic renderer-flush signal iOS emits while
    /// moving custom sample-buffer audio to a Bluetooth destination.
    private static func auditAudioRendererRecovery(
        decoder: BunnyNativeDecoder,
        probe: BunnyStressProbe,
        info: BunnyNativeMediaInfo
    ) async throws {
        guard info.hasAudio else { throw PlayerStressError.missingAudioOutput }
        let revision = probe.seekRevision
        let position = decoder.currentTime
        let renderedAudioFrames = probe.renderedAudioFrames

        NotificationCenter.default.post(
            name: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: decoder.audioRenderer
        )
        try await waitUntil(timeout: 8, probe: probe) {
            probe.seekRevision > revision && probe.seekSucceeded
        }
        decoder.play(atRate: 1)
        try await waitUntil(timeout: 8, probe: probe) {
            decoder.currentTime >= position + 0.20
                && probe.renderedAudioFrames > renderedAudioFrames
        }
        NSLog(
            "BUNNY_AUDIO_ROUTE_AUDIT PASS position=%.3f recovered=%.3f audio_frames=%ld",
            position,
            decoder.currentTime,
            probe.renderedAudioFrames
        )
    }
    #endif

    private static func percentile(
        _ values: [Double],
        percentile: Double,
        emptyValue: Double = .infinity
    ) -> Double {
        guard !values.isEmpty else { return emptyValue }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * percentile).rounded(.up))
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private static func elapsedMilliseconds(since start: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }

    private static func foregroundWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }
    }
}

private enum PlayerStressError: LocalizedError {
    case invalidDuration(TimeInterval)
    case timedOut
    case missingAudioOutput
    case prefixCaptureRequiresByteRanges
    case invalidPrefixCaptureSize(Int64)

    var errorDescription: String? {
        switch self {
        case let .invalidDuration(duration):
            "Player stress source has invalid duration: \(duration)"
        case .timedOut:
            "Player stress operation timed out"
        case .missingAudioOutput:
            "Bunny discovered an audio track but rendered no audio samples"
        case .prefixCaptureRequiresByteRanges:
            "Provider did not honor the bounded byte-range capture request"
        case let .invalidPrefixCaptureSize(bytes):
            "Provider returned an invalid prefix capture size: \(bytes) bytes"
        }
    }
}

@MainActor
struct PlayerStressScreen: View {
    let url: URL
    @State private var status = "Running player stress test…"

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(status)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("player-stress-status")
        }
        .padding(28)
        .task {
            let environment = ProcessInfo.processInfo.environment
            do {
                let result = try await BunnyPlayerStressBenchmark.measure(
                    url: url,
                    title: "bunny:rust:\(url.lastPathComponent)",
                    visible: environment["SKELETON_PLAYER_STRESS_VISIBLE"] == "1"
                )
                let encoder = JSONEncoder()
                encoder.nonConformingFloatEncodingStrategy = .convertToString(
                    positiveInfinity: "Infinity",
                    negativeInfinity: "-Infinity",
                    nan: "NaN"
                )
                let data = try encoder.encode(result)
                let json = String(decoding: data, as: UTF8.self)
                status = result.passed ? "Player stress PASS" : "Player stress FAIL"
                NSLog("PLAYER_STRESS %@ %@", result.passed ? "PASS" : "FAIL", json)
            } catch {
                status = "Player stress FAIL: \(error.localizedDescription)"
                NSLog("PLAYER_STRESS FAIL error=%@", error.localizedDescription)
            }
        }
    }
}

#if targetEnvironment(simulator)
private enum ProviderPrefixCapture {
    static func save(
        source: PlaybackPlan,
        megabytes: Int
    ) async throws -> (url: URL, bytes: Int64) {
        let boundedMegabytes = min(max(megabytes, 1), 128)
        let byteCount = boundedMegabytes * 1_024 * 1_024
        var request = URLRequest(url: source.primaryURL)
        request.setValue("bytes=0-\(byteCount - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.timeoutInterval = 45

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 206,
              http.value(forHTTPHeaderField: "Content-Range") != nil else {
            throw PlayerStressError.prefixCaptureRequiresByteRanges
        }

        let actualBytes = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
            .fileSize
            .map(Int64.init) ?? 0
        guard actualBytes > 0, actualBytes <= Int64(byteCount) else {
            throw PlayerStressError.invalidPrefixCaptureSize(actualBytes)
        }

        let fileExtension = source.detectedMIMEType == "video/mp2t" ? "ts" : "media"
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
        let destination = documents.appendingPathComponent(
            "provider-network-isolation.\(fileExtension)"
        )
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return (destination, actualBytes)
    }
}
#endif

@MainActor
struct ProviderPlayerAuditScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var plan: PlaybackPlan?
    @State private var failoverCandidates: [StreamPlaybackCandidate]?
    @State private var title = "Resolving provider stream…"
    @State private var failureMessage: String?

    var body: some View {
        Group {
            if let failoverCandidates {
                NavigationStack {
                    ResolvingPlayerScreen(
                        candidates: failoverCandidates,
                        minimumVideoDuration: 20 * 60
                    )
                }
            } else if let plan {
                NavigationStack {
                    PlayerScreen(
                        plan: plan,
                        title: title,
                        minimumVideoDuration: 20 * 60,
                        onExhausted: { error in
                            failureMessage = error.localizedDescription
                            NSLog(
                                "PROVIDER_PLAYER_AUDIT FAIL player=%@ error=%@",
                                StremioInternalPlayer.selected.rawValue,
                                error.localizedDescription
                            )
                        }
                    )
                }
            } else if let failureMessage {
                VStack(spacing: 12) {
                    Image(systemName: "play.slash")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.appAccent)
                    Text("Provider stream unavailable").font(.title3.bold())
                    Text(failureMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ProgressView(title)
            }
        }
        .task { await resolveProviderStream() }
    }

    private func resolveProviderStream() async {
        let environment = ProcessInfo.processInfo.environment
        let movieNeedle = environment["SKELETON_PROVIDER_MOVIE"] ?? "Obsession"
        let providerNeedle = environment["SKELETON_PROVIDER_NAME"] ?? "Torrentio"
        let streamNeedle = environment["SKELETON_PROVIDER_STREAM_NEEDLE"] ?? "Lootera"

        if let directValue = environment["SKELETON_PROVIDER_DIRECT_URL"],
           let directURL = URL(string: directValue) {
            let directTitle = environment["SKELETON_PROVIDER_DIRECT_TITLE"]
                ?? "Direct provider playback audit"
            let directMetadata = environment["SKELETON_PROVIDER_DIRECT_METADATA"]
                ?? directTitle
            let providerTag = providerNeedle.range(
                of: "TB",
                options: .caseInsensitive
            ) == nil ? "[RD]" : "[TB]"
            let directStream = Stream(
                url: directURL,
                externalUrl: nil,
                name: "\(providerTag) Provider audit",
                title: directMetadata,
                description: nil,
                infoHash: nil,
                fileIdx: nil,
                sources: nil
            )
            #if targetEnvironment(simulator)
            if environment["SKELETON_PROVIDER_FAILOVER_AUDIT"] == "1",
               let brokenURL = URL(string: "http://127.0.0.1:1/unavailable.mkv") {
                let brokenStream = Stream(
                    url: brokenURL,
                    externalUrl: nil,
                    name: "[TB] Forced unavailable provider source",
                    title: "Provider failover audit source 1",
                    description: nil,
                    infoHash: nil,
                    fileIdx: nil,
                    sources: nil
                )
                failoverCandidates = [
                    StreamPlaybackCandidate(
                        stream: brokenStream,
                        providerName: providerNeedle,
                        sourceID: "provider-audit-broken"
                    ),
                    StreamPlaybackCandidate(
                        stream: directStream,
                        providerName: providerNeedle,
                        sourceID: "provider-audit-real"
                    ),
                ]
                title = "Provider failover audit"
                NSLog(
                    "PROVIDER_FAILOVER_AUDIT ready sources=2 provider=%@",
                    providerNeedle
                )
                return
            }
            #endif
            do {
                plan = try await model.playbackPlan(
                    for: directStream,
                    providerName: providerNeedle
                )
                title = directTitle
                NSLog(
                    "PROVIDER_PLAYER_AUDIT resolved_direct player=%@ mime=%@",
                    StremioInternalPlayer.selected.rawValue,
                    plan?.detectedMIMEType ?? "unknown"
                )
            } catch {
                fail(error.localizedDescription)
            }
            return
        }

        await model.start()
        guard let item = model.catalog.first(where: {
            $0.name.range(of: movieNeedle, options: .caseInsensitive) != nil
        }) else {
            fail("Missing movie matching \(movieNeedle)")
            return
        }

        let detail = await model.details(for: item)
        let providers = await model.streamProviders(for: detail)
        if environment["SKELETON_PROVIDER_LIST_PROVIDERS"] == "1" {
            for provider in providers {
                NSLog(
                    "PROVIDER_GROUP name=%@ streams=%ld",
                    provider.name,
                    provider.streams.count
                )
            }
        }
        guard let provider = providers.first(where: {
            $0.name.range(of: providerNeedle, options: .caseInsensitive) != nil
        }) else {
            fail("Missing provider matching \(providerNeedle)")
            return
        }
        if environment["SKELETON_PROVIDER_LIST_STREAMS"] == "1" {
            for (index, stream) in provider.streams.enumerated() {
                NSLog(
                    "PROVIDER_STREAM index=%ld metadata=%@",
                    index,
                    streamMetadata(stream)
                )
            }
        }
        let selectedStream: Stream?
        if let rawIndex = environment["SKELETON_PROVIDER_STREAM_INDEX"],
           let index = Int(rawIndex),
           provider.streams.indices.contains(index) {
            selectedStream = provider.streams[index]
        } else {
            selectedStream = provider.streams.first(where: {
                streamMetadata($0).range(of: streamNeedle, options: .caseInsensitive) != nil
            })
        }
        guard let stream = selectedStream else {
            fail("Missing stream matching \(streamNeedle)")
            return
        }

        title = streamMetadata(stream)
        do {
            let resolvedPlan = try await model.playbackPlan(
                for: stream,
                providerName: provider.name
            )
            #if targetEnvironment(simulator)
            if let rawMegabytes = environment["SKELETON_PROVIDER_CAPTURE_PREFIX_MB"],
               let megabytes = Int(rawMegabytes) {
                let captured = try await ProviderPrefixCapture.save(
                    source: resolvedPlan,
                    megabytes: megabytes
                )
                NSLog(
                    "NETWORK_ISOLATION_CAPTURE bytes=%lld file=%@ mime=%@",
                    captured.bytes,
                    captured.url.lastPathComponent,
                    resolvedPlan.detectedMIMEType ?? "unknown"
                )
            }
            #endif
            plan = resolvedPlan
            NSLog(
                "PROVIDER_PLAYER_AUDIT RESOLVED player=%@ movie=%@ provider=%@ stream=%@",
                StremioInternalPlayer.selected.rawValue,
                detail.name,
                provider.name,
                title
            )
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func streamMetadata(_ stream: Stream) -> String {
        [stream.title, stream.name, stream.description]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func fail(_ message: String) {
        failureMessage = message
        NSLog(
            "PROVIDER_PLAYER_AUDIT FAIL player=%@ error=%@",
            StremioInternalPlayer.selected.rawValue,
            message
        )
    }
}

@MainActor
extension AppModel {
    func runSingleMoviePlaybackAudit() async {
        let environment = ProcessInfo.processInfo.environment
        let providerNeedle = environment["SKELETON_SINGLE_MOVIE_PROVIDER"]
            ?? "Debridio - Scraper TB"
        let streamNeedle = environment["SKELETON_SINGLE_MOVIE_STREAM_NEEDLE"]
            ?? "Lootera"
        let configuredSeekFractions = environment[
            "SKELETON_SINGLE_MOVIE_SEEK_FRACTIONS"
        ]?.split(separator: ",").compactMap { Double($0) }.filter {
            $0 > 0 && $0 < 1
        }
        let seekFractions = configuredSeekFractions?.isEmpty == false
            ? configuredSeekFractions!
            : [0.10, 0.50, 0.85, 0.25, 0.70]

        let movieName = "Obsession"
        guard let obsession = catalog.first(where: {
            $0.name.range(of: movieName, options: .caseInsensitive) != nil
        }) else {
            writeSingleMoviePlaybackAudit(
                movie: movieName,
                provider: providerNeedle,
                streamTitle: nil,
                sourceProfile: nil,
                metrics: nil,
                error: "Missing Obsession catalog item"
            )
            return
        }

        let detail = await details(for: obsession)
        let providers = await streamProviders(for: detail)
        guard let provider = providers.first(where: {
            $0.name.range(of: providerNeedle, options: .caseInsensitive) != nil
        }) else {
            writeSingleMoviePlaybackAudit(
                movie: detail.name,
                provider: providerNeedle,
                streamTitle: nil,
                sourceProfile: nil,
                metrics: nil,
                error: "Missing provider \(providerNeedle)"
            )
            return
        }

        guard let stream = provider.streams.first(where: {
            playerStressMetadata(for: $0).range(
                of: streamNeedle,
                options: .caseInsensitive
            ) != nil
        }) else {
            writeSingleMoviePlaybackAudit(
                movie: detail.name,
                provider: provider.name,
                streamTitle: nil,
                sourceProfile: nil,
                metrics: nil,
                error: "Missing stream matching \(streamNeedle)"
            )
            return
        }

        let metadata = playerStressMetadata(for: stream)
        let profile = playerStressProfile(for: metadata)
        NSLog(
            "SINGLE_MOVIE_PLAYBACK_AUDIT begin movie=%@ provider=%@ engine=bunny-rust audio=apple-system stream=%@",
            detail.name,
            provider.name,
            metadata
        )

        do {
            // Exercise one resolved source through the production Bunny path.
            // This audit does not hide a failure by swapping player engines.
            let plan = try await playbackPlan(for: stream, providerName: provider.name)
            let metrics = try await BunnyPlayerStressBenchmark.measure(
                url: plan.primaryURL,
                title: metadata,
                visible: true,
                startupTimeout: 20,
                minimumDuration: 20 * 60,
                seekFractions: seekFractions,
                cadenceSampleSeconds: 20
            )
            writeSingleMoviePlaybackAudit(
                movie: detail.name,
                provider: provider.name,
                streamTitle: metadata,
                sourceProfile: profile,
                metrics: metrics,
                error: metrics.passed ? nil : "Strict playback metrics failed"
            )
        } catch {
            writeSingleMoviePlaybackAudit(
                movie: detail.name,
                provider: provider.name,
                streamTitle: metadata,
                sourceProfile: profile,
                metrics: nil,
                error: error.localizedDescription
            )
        }
    }

    func runObsessionStreamStressBenchmark(
        requestedStreams: Int = 20,
        startIndex: Int = 0
    ) async {
        let providerNeedle = "Debridio - Scraper TB"
        let obsession = catalog.first {
            $0.name.range(of: "Obsession", options: .caseInsensitive) != nil
        }
        guard let obsession else {
            writeObsessionStressReport(
                requestedStreams: requestedStreams,
                availableStreams: 0,
                entries: [],
                startIndex: startIndex
            )
            NSLog("OBSESSION_STREAM_STRESS FAIL reason=missing_catalog_item")
            return
        }

        let detail = await details(for: obsession)
        let providers = await streamProviders(for: detail)
        guard let provider = providers.first(where: {
            $0.name.range(of: providerNeedle, options: .caseInsensitive) != nil
        }) else {
            writeObsessionStressReport(
                requestedStreams: requestedStreams,
                availableStreams: 0,
                entries: [],
                startIndex: startIndex
            )
            NSLog("OBSESSION_STREAM_STRESS FAIL reason=missing_provider")
            return
        }

        var seen = Set<String>()
        let streams = provider.streams
            .filter { stream in
                guard stream.url != nil else { return false }
                return seen.insert(stream.id).inserted
            }
            .sorted {
                let lhs = playerStressPriority(for: playerStressMetadata(for: $0))
                let rhs = playerStressPriority(for: playerStressMetadata(for: $1))
                if lhs != rhs { return lhs < rhs }
                return $0.id < $1.id
            }
        let selectedStreams = Array(
            streams.dropFirst(max(startIndex, 0)).prefix(requestedStreams)
        )
        var entries = [ObsessionStreamStressEntry]()

        for (offset, stream) in selectedStreams.enumerated() {
            let index = startIndex + offset + 1
            let metadata = playerStressMetadata(for: stream)
            let profile = playerStressProfile(for: metadata)
            NSLog(
                "OBSESSION_STREAM_STRESS begin index=%ld source=%@",
                index,
                profile
            )

            do {
                let plan = try await playbackPlan(for: stream, providerName: provider.name)
                let metrics = try await BunnyPlayerStressBenchmark.measure(
                    url: plan.primaryURL,
                    title: "Obsession stream \(index)",
                    visible: true,
                    startupTimeout: 12,
                    minimumDuration: 20 * 60
                )

                entries.append(
                    ObsessionStreamStressEntry(
                        streamIndex: index,
                        provider: provider.name,
                        sourceProfile: profile,
                        // Keep the report field for consumers of existing JSON.
                        engine: "bunny-rust",
                        metrics: metrics,
                        error: metrics.passed ? nil : "Strict playback metrics failed"
                    )
                )
            } catch {
                entries.append(
                    ObsessionStreamStressEntry(
                        streamIndex: index,
                        provider: provider.name,
                        sourceProfile: profile,
                        engine: nil,
                        metrics: nil,
                        error: error.localizedDescription
                    )
                )
            }
        }

        writeObsessionStressReport(
            requestedStreams: requestedStreams,
            availableStreams: streams.count,
            entries: entries,
            startIndex: startIndex
        )
    }

    func runRealPlayerStressBenchmark(requestedMovies: Int = 5) async {
        let providerNeedle = "Debridio - Scraper TB"
        var entries = [RealPlayerStressEntry]()

        for item in catalog.prefix(12) where entries.count < requestedMovies {
            let detail = await details(for: item)
            let providers = await streamProviders(for: detail)
            guard let provider = providers.first(where: {
                $0.name.range(of: providerNeedle, options: .caseInsensitive) != nil
            }) else { continue }

            guard let selected = playerStressStream(
                from: provider.streams,
                prefer4K: entries.count.isMultiple(of: 2)
            ) else {
                continue
            }

            do {
                NSLog(
                    "REAL_PLAYER_STRESS begin movie=%@ source=%@",
                    detail.name,
                    selected.profile
                )
                let plan = try await playbackPlan(
                    for: selected.stream,
                    providerName: provider.name
                )
                let result = try await BunnyPlayerStressBenchmark.measure(
                    url: plan.primaryURL,
                    title: detail.name
                )
                entries.append(
                    RealPlayerStressEntry(
                        movie: detail.name,
                        provider: provider.name,
                        sourceProfile: selected.profile,
                        metrics: result,
                        error: nil
                    )
                )
            } catch {
                entries.append(
                    RealPlayerStressEntry(
                        movie: detail.name,
                        provider: provider.name,
                        sourceProfile: selected.profile,
                        metrics: nil,
                        error: error.localizedDescription
                    )
                )
            }
        }

        let report = RealPlayerStressReport(
            generatedAt: Date(),
            requestedMovies: requestedMovies,
            testedMovies: entries.count,
            passedMovies: entries.filter { $0.metrics?.passed == true }.count,
            entries: entries
        )
        do {
            let encoder = JSONEncoder()
            encoder.nonConformingFloatEncodingStrategy = .convertToString(
                positiveInfinity: "Infinity",
                negativeInfinity: "-Infinity",
                nan: "NaN"
            )
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first!
            try data.write(
                to: documents.appendingPathComponent("player-stress-report.json"),
                options: .atomic
            )
            NSLog(
                "REAL_PLAYER_STRESS %@ tested=%ld passed=%ld provider=%@",
                report.passed ? "PASS" : "FAIL",
                report.testedMovies,
                report.passedMovies,
                providerNeedle
            )
        } catch {
            NSLog("REAL_PLAYER_STRESS FAIL report=%@", error.localizedDescription)
        }
    }

    /// Debrid indexes sometimes put 8K AI upscales ahead of normal releases.
    /// Those files exceed the practical decoder/memory envelope of current
    /// iPhones and can be killed by iOS before a player can report an error.
    /// Prefer cached 4K/1080p sources, alternate resolutions across the real
    /// five-movie benchmark, and keep unusually large remuxes behind lighter
    /// sources. The UI still exposes every provider result to the user.
    private func playerStressStream(
        from streams: [Stream],
        prefer4K: Bool
    ) -> (stream: Stream, profile: String)? {
        streams
            .compactMap { stream -> (stream: Stream, profile: String, score: Int)? in
                guard stream.url != nil else { return nil }
                let metadata = [stream.title, stream.name, stream.description]
                    .compactMap { $0 }
                    .joined(separator: " ")
                let uppercased = metadata.uppercased()
                guard !uppercased.contains("4320P"),
                      !uppercased.contains("8K") else { return nil }

                let cached = metadata.contains("⚡")
                let quality: String
                let qualityScore: Int
                if uppercased.contains("2160P") || uppercased.contains("4K") {
                    quality = "4K"
                    qualityScore = prefer4K ? 50 : 25
                } else if uppercased.contains("1080P") {
                    quality = "1080p"
                    qualityScore = prefer4K ? 35 : 50
                } else if uppercased.contains("720P") {
                    quality = "720p"
                    qualityScore = 15
                } else {
                    quality = "unknown quality"
                    qualityScore = 5
                }

                let size = playerStressFileSize(in: metadata)
                let oversizedPenalty: Int
                if let size, size > 50 {
                    oversizedPenalty = 35
                } else if let size, size > 25 {
                    oversizedPenalty = 15
                } else {
                    oversizedPenalty = 0
                }
                let formatPenalty = uppercased.contains("REMUX") ? 8 : 0
                let score = (cached ? 100 : 0)
                    + qualityScore
                    - oversizedPenalty
                    - formatPenalty
                let profile = [
                    cached ? "cached" : "uncached",
                    quality,
                    size.map { String(format: "%.2f GB", $0) }
                ]
                .compactMap { $0 }
                .joined(separator: ", ")
                return (stream, profile, score)
            }
            .max { $0.score < $1.score }
            .map { ($0.stream, $0.profile) }
    }

    private func playerStressFileSize(in metadata: String) -> Double? {
        guard let match = metadata.range(
            of: #"(?i)(?<![A-Z0-9])(\d+(?:\.\d+)?)\s*(TB|GB|MB)(?![A-Z0-9])"#,
            options: .regularExpression
        ) else { return nil }
        let value = String(metadata[match])
        let scanner = Scanner(string: value)
        guard let amount = scanner.scanDouble() else { return nil }
        let unit = value.uppercased()
        if unit.contains("TB") { return amount * 1_024 }
        if unit.contains("MB") { return amount / 1_024 }
        return amount
    }

    private func playerStressProfile(for metadata: String) -> String {
        let uppercased = metadata.uppercased()
        let quality: String
        if uppercased.contains("4320P") || uppercased.contains("8K") {
            quality = "8K"
        } else if uppercased.contains("2160P") || uppercased.contains("4K") {
            quality = "4K"
        } else if uppercased.contains("1080P") {
            quality = "1080p"
        } else if uppercased.contains("720P") {
            quality = "720p"
        } else {
            quality = "unknown quality"
        }
        return [
            metadata.contains("⚡") ? "cached" : "uncached",
            quality,
            playerStressFileSize(in: metadata).map { String(format: "%.2f GB", $0) },
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    private func playerStressMetadata(for stream: Stream) -> String {
        [stream.title, stream.name, stream.description]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    /// Keep this in lockstep with `PresentedStream.playbackPriority`, because
    /// the benchmark must exercise the same order a user sees in Details.
    private func playerStressPriority(for metadata: String) -> Int {
        let uppercased = metadata.uppercased()
        var score = metadata.contains("⚡") ? -1_000 : 0
        if uppercased.contains("4320P") || uppercased.contains("8K") {
            score += 1_000
        } else if uppercased.contains("1080P") {
            score -= 120
        } else if uppercased.contains("2160P") || uppercased.contains("4K") {
            score -= 100
        } else if uppercased.contains("720P") {
            score -= 70
        }
        if uppercased.contains("REMUX") { score += 12 }
        if let size = playerStressFileSize(in: metadata), size > 50 {
            score += 60
        } else if let size = playerStressFileSize(in: metadata), size > 25 {
            score += 25
        }
        return score
    }

    private func writeObsessionStressReport(
        requestedStreams: Int,
        availableStreams: Int,
        entries: [ObsessionStreamStressEntry],
        startIndex: Int
    ) {
        let report = ObsessionStreamStressReport(
            generatedAt: Date(),
            requestedStreams: requestedStreams,
            availableStreams: availableStreams,
            testedStreams: entries.count,
            passedStreams: entries.filter { $0.metrics?.passed == true }.count,
            entries: entries
        )
        do {
            let encoder = JSONEncoder()
            encoder.nonConformingFloatEncodingStrategy = .convertToString(
                positiveInfinity: "Infinity",
                negativeInfinity: "-Infinity",
                nan: "NaN"
            )
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first!
            let finalIndex = startIndex + max(entries.count, requestedStreams)
            try data.write(
                to: documents.appendingPathComponent(
                    "obsession-stream-report-\(startIndex + 1)-\(finalIndex).json"
                ),
                options: .atomic
            )
            NSLog(
                "OBSESSION_STREAM_STRESS %@ available=%ld tested=%ld passed=%ld provider=Debridio - Scraper TB",
                report.passed ? "PASS" : "FAIL",
                report.availableStreams,
                report.testedStreams,
                report.passedStreams
            )
        } catch {
            NSLog("OBSESSION_STREAM_STRESS FAIL report=%@", error.localizedDescription)
        }
    }

    private func writeSingleMoviePlaybackAudit(
        movie: String,
        provider: String,
        streamTitle: String?,
        sourceProfile: String?,
        metrics: PlayerStressMetrics?,
        error: String?
    ) {
        let report = SingleMoviePlaybackAuditReport(
            generatedAt: Date(),
            movie: movie,
            provider: provider,
            streamTitle: streamTitle,
            sourceProfile: sourceProfile,
            // Preserve these report keys for existing benchmark consumers.
            engine: "bunny-rust",
            audioOutput: "apple-system",
            metrics: metrics,
            error: error
        )
        do {
            let encoder = JSONEncoder()
            encoder.nonConformingFloatEncodingStrategy = .convertToString(
                positiveInfinity: "Infinity",
                negativeInfinity: "-Infinity",
                nan: "NaN"
            )
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first!
            try data.write(
                to: documents.appendingPathComponent(
                    "single-movie-playback-audit.json"
                ),
                options: .atomic
            )
            NSLog(
                "SINGLE_MOVIE_PLAYBACK_AUDIT %@ engine=bunny-rust audio=apple-system",
                report.passed ? "PASS" : "FAIL"
            )
        } catch {
            NSLog(
                "SINGLE_MOVIE_PLAYBACK_AUDIT FAIL report=%@",
                error.localizedDescription
            )
        }
    }
}
