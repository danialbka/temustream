import AVFoundation
import Foundation
import SwiftUI
import UIKit
#if canImport(KSPlayer)
@preconcurrency import KSPlayer
#endif

#if canImport(KSPlayer)
@MainActor
enum StremioPlayerConfiguration {
    enum Engine: String, Hashable, Sendable {
        case automatic
        case native
        case ffmpeg
    }

    enum AudioOutput: String, Hashable, Sendable {
        case engine
        case renderer
    }

    static func configureEngine(_ engine: Engine = .ffmpeg) {
        switch engine {
        case .automatic:
            KSOptions.firstPlayerType = KSAVPlayer.self
            KSOptions.secondPlayerType = KSMEPlayer.self
        case .native:
            KSOptions.firstPlayerType = KSAVPlayer.self
            KSOptions.secondPlayerType = nil
        case .ffmpeg:
            KSOptions.firstPlayerType = KSMEPlayer.self
            KSOptions.secondPlayerType = nil
        }
        KSOptions.isAutoPlay = true
        KSOptions.isSecondOpen = false
        KSOptions.canBackgroundPlay = true
        KSOptions.canStartPictureInPictureAutomaticallyFromInline = true
    }

    static func makeOptions(
        engine: Engine = .ffmpeg,
        audioOutput: AudioOutput = .engine,
        performancePolicy: PlaybackPerformancePolicy? = nil
    ) -> KSOptions {
        configureEngine(engine)
        KSOptions.audioPlayerType = switch audioOutput {
        case .engine: AudioEnginePlayer.self
        case .renderer: AudioRendererPlayer.self
        }
        let options = KSOptions()
        options.hardwareDecode = true
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["SKELETON_KS_ASYNC_DECOMPRESSION"] == "1" {
            options.asynchronousDecompression = true
        }
        #endif
        options.autoRotate = true
        options.autoSelectEmbedSubtitle = true
        options.canStartPictureInPictureAutomaticallyFromInline = true
        // The stress benchmark found no stall reduction at six seconds, while
        // startup regressed and dropped frames increased. Keep KSPlayer's
        // measured three-second default explicit here.
        options.preferredForwardBufferDuration = performancePolicy?.forwardBufferSeconds ?? 3
        options.maxBufferDuration = performancePolicy?.maximumBufferSeconds ?? 30
        options.isSeekedAutoPlay = false
        options.mpegTSByteSeekResolver = performancePolicy?.mpegTSByteSeekResolver
        options.useTimeBasedSeekingForMPEGTS = options.mpegTSByteSeekResolver != nil
        // The bridge intentionally resolves to the preceding keyframe region.
        // Accurate seek decodes that small preroll and withholds frames until
        // the requested presentation timestamp, preventing post-seek A/V skew.
        options.isAccurateSeek = options.mpegTSByteSeekResolver != nil
        // Bound a dead range request without changing KSPlayer's proven
        // buffering depth or enabling its risky infinite DNS retry option.
        options.formatContextOptions["rw_timeout"] = 15_000_000
        options.formatContextOptions["reconnect_delay_max"] = 2
        options.formatContextOptions["reconnect_on_http_error"] = "5xx"
        return options
    }

    static func hasVisibleVideoFrame(_ player: any MediaPlayerProtocol) -> Bool {
        if let nativePlayer = player as? KSAVPlayer,
           let playerLayer = nativePlayer.view?.layer as? AVPlayerLayer {
            return playerLayer.isReadyForDisplay
        }
        if let ffmpegPlayer = player as? KSMEPlayer,
           let videoView = ffmpegPlayer.view as? MetalPlayView {
            return videoView.pixelBuffer != nil || videoView.displayLayer.status == .rendering
        }
        return false
    }
}

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
    let stalledIntervals: Int
    let bufferingTransitions: Int
    let nominalFPS: Double
    let displayedFPS: Double
    let droppedVideoFrames: UInt32
    let droppedVideoPackets: UInt32
    let realTimeRatio: Double
    let audioVideoSyncP95Milliseconds: Double
    let audioVideoSyncMaxMilliseconds: Double
    let longestVideoFreezeMilliseconds: Double
    let audioTrackCount: Int
    let videoTrackCount: Int
    let renderedVideoFrame: Bool

    var passed: Bool {
        let cadenceIsSmooth = nominalFPS <= 0
            || displayedFPS <= 0
            || displayedFPS >= nominalFPS * 0.90
        return startupMilliseconds <= 12_000
            && successfulSeeks == seekAttempts
            && seekP95Milliseconds <= 2_500
            && seekSyncRecoveryP95Milliseconds <= 3_000
            && successfulPauseResumes == pauseResumeAttempts
            && pausedSeekPreserved
            && realTimeRatio >= 0.95
            && audioVideoSyncP95Milliseconds <= 150
            && audioVideoSyncMaxMilliseconds <= 300
            && longestVideoFreezeMilliseconds <= 350
            && stalledIntervals == 0
            && bufferingTransitions <= 2
            && droppedVideoFrames <= 5
            && cadenceIsSmooth
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

@MainActor
enum PlayerStressBenchmark {
    static func measure(
        url: URL,
        title: String,
        options: KSOptions,
        visible: Bool = false,
        startupTimeout: TimeInterval = 30,
        minimumDuration: TimeInterval = 4,
        seekFractions: [Double] = [0.10, 0.50, 0.85, 0.25, 0.70],
        cadenceSampleSeconds: TimeInterval = 12
    ) async throws -> PlayerStressMetrics {
        let window = foregroundWindow()
        let host = UIView(
            frame: visible
                ? (window?.bounds ?? UIScreen.main.bounds)
                : CGRect(x: -4, y: -4, width: 2, height: 2)
        )
        host.isUserInteractionEnabled = false
        host.alpha = visible ? 1 : 0.01
        host.backgroundColor = .black
        if let window {
            window.addSubview(host)
        }

        let layer = KSPlayerLayer(url: url, isAutoPlay: true, options: options)
        if let playerView = layer.player.view {
            playerView.frame = host.bounds
            host.addSubview(playerView)
        }

        defer {
            layer.stop()
            host.removeFromSuperview()
        }

        let startupStartedAt = ProcessInfo.processInfo.systemUptime
        // Playback is initiated by the app as soon as the player is mounted;
        // no user tap or playback-control interaction is involved.
        layer.play()
        NSLog("PLAYER_STRESS_STEP startup_begin title=%@", title)
        try await waitUntil(timeout: startupTimeout) {
            layer.player.isReadyToPlay
                && layer.player.loadState == .playable
                && layer.player.currentPlaybackTime > 0.15
        }
        let startupMilliseconds = elapsedMilliseconds(since: startupStartedAt)
        NSLog("PLAYER_STRESS_STEP startup_end title=%@ elapsed_ms=%.1f", title, startupMilliseconds)

        let duration = layer.player.duration
        guard duration.isFinite, duration >= minimumDuration else {
            throw PlayerStressError.invalidDuration(duration)
        }

        // The production controls intentionally keep scrubbing disabled until
        // KSPlayer exposes a seekable range. Measuring a seek before that
        // point makes the first request look like a four-second seek while the
        // demuxer is actually still publishing its initial index.
        try await waitUntil(timeout: 8) { layer.player.seekable }
        NSLog("PLAYER_STRESS_STEP seekable title=%@", title)

        var seekLatencies = [Double]()
        var seekSyncLatencies = [Double]()
        var successfulSeeks = 0
        for (seekIndex, fraction) in seekFractions.enumerated() {
            let target = min(max(duration * fraction, 0.5), duration - 1)
            // This phase explicitly measures seeks while playback is wanted.
            // `isPlaying` can momentarily be false during a cold buffer
            // transition even though the layer is in autoplay mode, which
            // would otherwise turn the first stress seek into a paused seek.
            let shouldResume = true
            PlayerSeekRecovery.pause(layer: layer)
            let seekStartedAt = ProcessInfo.processInfo.systemUptime
            NSLog("PLAYER_STRESS_STEP seek_begin title=%@ index=%ld", title, seekIndex + 1)
            let finished = try await seek(layer: layer, to: target, resume: shouldResume)
            let seekMilliseconds = elapsedMilliseconds(since: seekStartedAt)
            seekLatencies.append(seekMilliseconds)
            NSLog(
                "PLAYER_STRESS_STEP seek_end title=%@ index=%ld elapsed_ms=%.1f finished=%@",
                title,
                seekIndex + 1,
                seekMilliseconds,
                finished ? "yes" : "no"
            )
            guard finished else { continue }

            let resumeStartTime = layer.player.currentPlaybackTime
            do {
                let syncMilliseconds = try await waitForSeekSynchronization(
                    layer: layer,
                    target: target,
                    startedAt: seekStartedAt
                )
                seekSyncLatencies.append(syncMilliseconds)
                successfulSeeks += 1
                NSLog(
                    "PLAYER_STRESS_STEP seek_sync title=%@ index=%ld elapsed_ms=%.1f audio=%.3f video=%.3f delta_ms=%.1f",
                    title,
                    seekIndex + 1,
                    syncMilliseconds,
                    layer.player.currentPlaybackTime,
                    displayedTime(for: layer),
                    abs(layer.player.currentPlaybackTime - displayedTime(for: layer)) * 1_000
                )
            } catch {
                let nativeRate = (layer.player as? KSAVPlayer)?.player.rate ?? -1
                NSLog(
                    "PLAYER_STRESS_STEP seek_resume_timeout title=%@ index=%ld target=%.3f start=%.3f current=%.3f video=%.3f delta_ms=%.1f rate=%.3f state=%@ load=%@",
                    title,
                    seekIndex + 1,
                    target,
                    resumeStartTime,
                    layer.player.currentPlaybackTime,
                    displayedTime(for: layer),
                    abs(layer.player.currentPlaybackTime - displayedTime(for: layer)) * 1_000,
                    nativeRate,
                    String(describing: layer.player.playbackState),
                    String(describing: layer.player.loadState)
                )
                // Keep running the remaining seeks so one failure cannot hide
                // the rest of the stress profile.
            }
        }

        let pauseResumeAttempts = 5
        var successfulPauseResumes = 0
        for _ in 0..<pauseResumeAttempts {
            let pausedAt = layer.player.currentPlaybackTime
            PlayerSeekRecovery.pause(layer: layer)
            try await Task.sleep(for: .milliseconds(120))
            let stayedPaused = !layer.player.isPlaying
                && abs(layer.player.currentPlaybackTime - pausedAt) < 0.20
            PlayerSeekRecovery.resume(layer: layer)
            do {
                try await waitUntil(timeout: 3) {
                    layer.player.isPlaying
                        && layer.player.currentPlaybackTime >= pausedAt + 0.20
                }
                if stayedPaused { successfulPauseResumes += 1 }
            } catch {
                // Continue to capture all cycles in one run.
            }
        }

        let pausedSeekTarget = min(max(duration * 0.48, 0.5), duration - 1)
        PlayerSeekRecovery.pause(layer: layer)
        let pausedSeekFinished = try await seek(
            layer: layer,
            to: pausedSeekTarget,
            resume: false
        )
        try await Task.sleep(for: .milliseconds(350))
        let pausedSeekPreserved = pausedSeekFinished
            && !layer.player.isPlaying
            && abs(layer.player.currentPlaybackTime - pausedSeekTarget) < 2
        NSLog(
            "PLAYER_STRESS_STEP paused_seek title=%@ target=%.3f current=%.3f playing=%@ finished=%@",
            title,
            pausedSeekTarget,
            layer.player.currentPlaybackTime,
            layer.player.isPlaying ? "yes" : "no",
            pausedSeekFinished ? "yes" : "no"
        )
        PlayerSeekRecovery.resume(layer: layer)
        try await waitUntil(timeout: 8) {
            layer.player.isPlaying
                && layer.player.currentPlaybackTime >= pausedSeekTarget + 0.35
        }

        let sampleStartedAt = ProcessInfo.processInfo.systemUptime
        let mediaStartedAt = displayedTime(for: layer)
        var lastDisplayedTime = mediaStartedAt
        var unchangedSince: TimeInterval?
        var isInsideCountedStall = false
        var stalledIntervals = 0
        var bufferingTransitions = 0
        var wasBuffering = layer.player.loadState != .playable
        var displayedFPSSamples = [Double]()
        var syncDeltaSamples = [Double]()
        var longestVideoFreezeMilliseconds = 0.0

        let cadenceSampleCount = max(Int(cadenceSampleSeconds * 10), 1)
        for _ in 0..<cadenceSampleCount {
            try await Task.sleep(for: .milliseconds(100))
            let buffering = layer.player.loadState != .playable
            if buffering != wasBuffering {
                bufferingTransitions += 1
                wasBuffering = buffering
            }

            if let value = layer.player.dynamicInfo?.displayFPS, value > 0 {
                displayedFPSSamples.append(value)
            }

            let currentDisplayedTime = displayedTime(for: layer)
            if !layer.player.tracks(mediaType: .audio).isEmpty,
               !layer.player.tracks(mediaType: .video).isEmpty {
                syncDeltaSamples.append(
                    abs(layer.player.currentPlaybackTime - currentDisplayedTime) * 1_000
                )
            }
            if layer.player.isPlaying, !buffering,
               abs(currentDisplayedTime - lastDisplayedTime) < 0.000_1 {
                unchangedSince = unchangedSince ?? ProcessInfo.processInfo.systemUptime
                if let unchangedSince,
                   ProcessInfo.processInfo.systemUptime - unchangedSince >= 0.35,
                   !isInsideCountedStall {
                    stalledIntervals += 1
                    isInsideCountedStall = true
                }
                if let unchangedSince {
                    longestVideoFreezeMilliseconds = max(
                        longestVideoFreezeMilliseconds,
                        elapsedMilliseconds(since: unchangedSince)
                    )
                }
            } else {
                unchangedSince = nil
                isInsideCountedStall = false
                lastDisplayedTime = currentDisplayedTime
            }
        }

        let wallSeconds = ProcessInfo.processInfo.systemUptime - sampleStartedAt
        let mediaSeconds = max(0, displayedTime(for: layer) - mediaStartedAt)
        let info = layer.player.dynamicInfo
        let displayedFPS = displayedFPSSamples.isEmpty
            ? 0
            : displayedFPSSamples.reduce(0, +) / Double(displayedFPSSamples.count)

        let videoTrackCount = layer.player.tracks(mediaType: .video).count
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
            stalledIntervals: stalledIntervals,
            bufferingTransitions: bufferingTransitions,
            nominalFPS: Double(layer.player.nominalFrameRate),
            displayedFPS: displayedFPS,
            droppedVideoFrames: info?.droppedVideoFrameCount ?? 0,
            droppedVideoPackets: info?.droppedVideoPacketCount ?? 0,
            realTimeRatio: wallSeconds > 0 ? mediaSeconds / wallSeconds : 0,
            audioVideoSyncP95Milliseconds: percentile(
                syncDeltaSamples,
                percentile: 0.95,
                emptyValue: 0
            ),
            audioVideoSyncMaxMilliseconds: syncDeltaSamples.max() ?? 0,
            longestVideoFreezeMilliseconds: longestVideoFreezeMilliseconds,
            audioTrackCount: layer.player.tracks(mediaType: .audio).count,
            videoTrackCount: videoTrackCount,
            renderedVideoFrame: videoTrackCount == 0
                || StremioPlayerConfiguration.hasVisibleVideoFrame(layer.player)
        )
    }

    private static func seek(
        layer: KSPlayerLayer,
        to target: TimeInterval,
        resume: Bool
    ) async throws -> Bool {
        var completion: Bool?
        PlayerSeekRecovery.seek(layer: layer, to: target, resume: resume) { finished in
            completion = finished
        }
        try await waitUntil(timeout: 15) { completion != nil }
        return completion == true
    }

    private static func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PlayerStressError.timedOut
    }

    private static func waitForSeekSynchronization(
        layer: KSPlayerLayer,
        target: TimeInterval,
        startedAt: TimeInterval
    ) async throws -> Double {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        var consecutiveSynchronizedSamples = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            let audioTime = layer.player.currentPlaybackTime
            let videoTime = displayedTime(for: layer)
            let nearTarget = abs(audioTime - target) <= 5 && abs(videoTime - target) <= 5
            let synchronized = abs(audioTime - videoTime) <= 0.15
            // KSAVPlayer can keep the wrapper's loadState at `.loading` while
            // AVPlayer is already rendering at rate 1. The native rate is the
            // stronger signal here; rejecting it produced false stress
            // failures even as the clock advanced smoothly past the target.
            let activelyRendering = layer.player.loadState == .playable
                || ((layer.player as? KSAVPlayer)?.player.rate ?? 0) > 0
            if layer.player.isPlaying,
               activelyRendering,
               nearTarget,
               synchronized {
                consecutiveSynchronizedSamples += 1
                if consecutiveSynchronizedSamples >= 4 {
                    return elapsedMilliseconds(since: startedAt)
                }
            } else {
                consecutiveSynchronizedSamples = 0
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PlayerStressError.timedOut
    }

    private static func displayedTime(for layer: KSPlayerLayer) -> TimeInterval {
        guard !layer.player.tracks(mediaType: .video).isEmpty else {
            return layer.player.currentPlaybackTime
        }
        return (layer.player as? KSMEPlayer)?.displayedVideoTime
            ?? layer.player.currentPlaybackTime
    }

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

/// KSPlayer's `autoPlay` seek path can leave HLS streams in an engine-specific
/// transitional state. Keeping seek and resume distinct gives each backend a
/// bounded opportunity to reassert playback after a completed scrub.
@MainActor
enum PlayerSeekRecovery {
    private static var generations = [ObjectIdentifier: Int]()

    static func pause(layer: KSPlayerLayer) {
        let key = ObjectIdentifier(layer)
        generations[key, default: 0] += 1
        layer.pause()
    }

    static func resume(layer: KSPlayerLayer) {
        let key = ObjectIdentifier(layer)
        generations[key, default: 0] += 1
        let generation = generations[key, default: 0]
        layer.play()
        if let mediaPlayer = layer.player as? KSMEPlayer {
            // MPEG-TS HLS can report a completed demux seek before KSMEPlayer
            // has left `.seeking`. Reassert playback for a bounded window so a
            // late state update cannot permanently strand the default engine.
            mediaPlayer.play()
            Task { @MainActor in
                for _ in 0..<24 {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard generations[key] == generation,
                          !Task.isCancelled
                    else { return }
                    if !mediaPlayer.isPlaying {
                        // Some segmented HLS demuxers deliver their seek
                        // completion before KSMEPlayer's queued `.seeking`
                        // transition has drained. Force a real state edge;
                        // repeatedly assigning `.playing` alone can be
                        // overwritten by that late transition.
                        mediaPlayer.pause()
                        try? await Task.sleep(for: .milliseconds(25))
                        guard generations[key] == generation else { return }
                        mediaPlayer.play()
                        layer.play()
                    }
                }
            }
            return
        }
        guard let nativePlayer = layer.player as? KSAVPlayer else { return }
        nativePlayer.player.automaticallyWaitsToMinimizeStalling = false
        nativePlayer.player.currentItem?.preferredForwardBufferDuration = 1
        nativePlayer.player.currentItem?
            .canUseNetworkResourcesForLiveStreamingWhilePaused = true
        nativePlayer.player.playImmediately(
            atRate: max(nativePlayer.playbackRate, 1)
        )
        for delay in [350, 900] {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(delay))
                guard generations[key] == generation,
                      layer.player.playbackState == .playing,
                      nativePlayer.player.rate == 0
                else { return }
                nativePlayer.player.playImmediately(
                    atRate: max(nativePlayer.playbackRate, 1)
                )
            }
        }
    }

    static func seek(
        layer: KSPlayerLayer,
        to target: TimeInterval,
        resume: Bool,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        if let nativePlayer = layer.player as? KSAVPlayer {
            Self.pause(layer: layer)
            let time = CMTime(seconds: max(target, 0), preferredTimescale: 600)
            let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
            nativePlayer.player.seek(
                to: time,
                toleranceBefore: tolerance,
                toleranceAfter: tolerance
            ) { finished in
                if finished, resume { Self.resume(layer: layer) }
                completion(finished)
            }
            return
        }
        Self.pause(layer: layer)
        let key = ObjectIdentifier(layer)
        let generation = generations[key, default: 0]
        seekFFmpeg(
            layer: layer,
            target: target,
            resume: resume,
            generation: generation,
            attempt: 0,
            completion: completion
        )
    }

    private static func seekFFmpeg(
        layer: KSPlayerLayer,
        target: TimeInterval,
        resume: Bool,
        generation: Int,
        attempt: Int,
        completion: @escaping (Bool) -> Void
    ) {
        layer.seek(time: target, autoPlay: false) { finished in
            Task { @MainActor in
                let key = ObjectIdentifier(layer)
                guard generations[key] == generation else {
                    completion(false)
                    return
                }

                if finished {
                    // KSMEPlayer can invoke its callback before the demux and
                    // audio clocks have adopted the requested timestamp. Keep
                    // playback paused until its public clock settles.
                    // A successful FFmpeg seek updates MEPlayerItem's clocks
                    // immediately. If the public clock has not adopted the
                    // target within this short first-attempt window, waiting
                    // several seconds only delays the same recovery seek.
                    let adoptionWindow = attempt == 0 ? 0.6 : 4.0
                    let deadline = ProcessInfo.processInfo.systemUptime + adoptionWindow
                    while ProcessInfo.processInfo.systemUptime < deadline {
                        guard generations[key] == generation else {
                            completion(false)
                            return
                        }
                        if abs(layer.player.currentPlaybackTime - target) <= 2 {
                            if resume { Self.resume(layer: layer) }
                            completion(true)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(40))
                    }
                }

                // A range-backed FFmpeg demux can occasionally acknowledge a
                // seek before its reopened decoder adopts the timestamp. Give
                // the selected KSPlayer engine one bounded retry before the UI
                // reports a failure or considers another player.
                guard attempt == 0, generations[key] == generation else {
                    completion(false)
                    return
                }
                NSLog("PLAYER_REPAIR seek=retry engine=ffmpeg")
                seekFFmpeg(
                    layer: layer,
                    target: target,
                    resume: resume,
                    generation: generation,
                    attempt: 1,
                    completion: completion
                )
            }
        }
    }
}

private enum PlayerStressError: LocalizedError {
    case invalidDuration(TimeInterval)
    case timedOut
    case prefixCaptureRequiresByteRanges
    case invalidPrefixCaptureSize(Int64)

    var errorDescription: String? {
        switch self {
        case let .invalidDuration(duration):
            "Player stress source has invalid duration: \(duration)"
        case .timedOut:
            "Player stress operation timed out"
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
            let engine = environment["SKELETON_PLAYER_STRESS_ENGINE"] ?? "hybrid"
            let bufferLabel = environment["SKELETON_PLAYER_STRESS_BUFFER"] ?? "default"
            let selectedEngine: StremioPlayerConfiguration.Engine = switch engine {
            case "native": .native
            case "me", "ffmpeg": .ffmpeg
            default: .automatic
            }
            let options = StremioPlayerConfiguration.makeOptions(engine: selectedEngine)
            if let rawBuffer = environment["SKELETON_PLAYER_STRESS_BUFFER"],
               let buffer = Double(rawBuffer) {
                options.preferredForwardBufferDuration = buffer
            }
            do {
                let result = try await PlayerStressBenchmark.measure(
                    url: url,
                    title: "\(engine):b\(bufferLabel):\(url.lastPathComponent)",
                    options: options
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
    @State private var title = "Resolving provider stream…"
    @State private var failureMessage: String?

    var body: some View {
        Group {
            if let plan {
                NavigationStack {
                    PlayerScreen(
                        plan: plan,
                        title: title,
                        minimumVideoDuration: 20 * 60
                    ) { error in
                        failureMessage = error.localizedDescription
                        NSLog(
                            "PROVIDER_PLAYER_AUDIT FAIL player=%@ error=%@",
                            StremioInternalPlayer.selected.rawValue,
                            error.localizedDescription
                        )
                    }
                }
            } else if let failureMessage {
                VStack(spacing: 12) {
                    Image(systemName: "play.slash")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
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

        await model.start()
        guard let item = model.catalog.first(where: {
            $0.name.range(of: movieNeedle, options: .caseInsensitive) != nil
        }) else {
            fail("Missing movie matching \(movieNeedle)")
            return
        }

        let detail = await model.details(for: item)
        let providers = await model.streamProviders(for: detail)
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
        let engine: StremioPlayerConfiguration.Engine = switch environment[
            "SKELETON_SINGLE_MOVIE_ENGINE"
        ] {
        case "native": .native
        default: .ffmpeg
        }
        let audioOutput: StremioPlayerConfiguration.AudioOutput = switch environment[
            "SKELETON_SINGLE_MOVIE_AUDIO_OUTPUT"
        ] {
        case "renderer": .renderer
        default: .engine
        }
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
                engine: engine,
                audioOutput: audioOutput,
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
                engine: engine,
                audioOutput: audioOutput,
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
                engine: engine,
                audioOutput: audioOutput,
                metrics: nil,
                error: "Missing stream matching \(streamNeedle)"
            )
            return
        }

        let metadata = playerStressMetadata(for: stream)
        let profile = playerStressProfile(for: metadata)
        NSLog(
            "SINGLE_MOVIE_PLAYBACK_AUDIT begin movie=%@ provider=%@ engine=%@ audio=%@ stream=%@",
            detail.name,
            provider.name,
            engine.rawValue,
            audioOutput.rawValue,
            metadata
        )

        do {
            // This audit intentionally exercises one resolved source and one
            // selected backend. It never retries another URL or player engine.
            let plan = try await playbackPlan(for: stream, providerName: provider.name)
            let performancePolicy = PlaybackPerformanceCore.policy(
                url: plan.primaryURL,
                title: [metadata, plan.detectedMIMEType]
                    .compactMap { $0 }
                    .joined(separator: " "),
                player: .ksPlayer
            )
            let metrics = try await PlayerStressBenchmark.measure(
                url: plan.primaryURL,
                title: metadata,
                options: StremioPlayerConfiguration.makeOptions(
                    engine: engine,
                    audioOutput: audioOutput,
                    performancePolicy: performancePolicy
                ),
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
                engine: engine,
                audioOutput: audioOutput,
                metrics: metrics,
                error: metrics.passed ? nil : "Strict playback metrics failed"
            )
        } catch {
            writeSingleMoviePlaybackAudit(
                movie: detail.name,
                provider: provider.name,
                streamTitle: metadata,
                sourceProfile: profile,
                engine: engine,
                audioOutput: audioOutput,
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
                var selectedEngine: StremioPlayerConfiguration.Engine?
                var selectedMetrics: PlayerStressMetrics?
                var attemptErrors = [String]()

                let engines: [StremioPlayerConfiguration.Engine] = [.ffmpeg, .native]
                for engine in engines {
                    do {
                        let metrics = try await PlayerStressBenchmark.measure(
                            url: plan.primaryURL,
                            title: "Obsession stream \(index)",
                            options: StremioPlayerConfiguration.makeOptions(engine: engine),
                            visible: true,
                            startupTimeout: 12,
                            minimumDuration: 20 * 60
                        )
                        if selectedMetrics == nil {
                            selectedEngine = engine
                            selectedMetrics = metrics
                        }
                        if metrics.passed {
                            selectedEngine = engine
                            selectedMetrics = metrics
                            break
                        }
                        attemptErrors.append("\(engine.rawValue): metrics failed")
                    } catch {
                        attemptErrors.append("\(engine.rawValue): \(error.localizedDescription)")
                    }
                }

                entries.append(
                    ObsessionStreamStressEntry(
                        streamIndex: index,
                        provider: provider.name,
                        sourceProfile: profile,
                        engine: selectedEngine?.rawValue,
                        metrics: selectedMetrics,
                        error: selectedMetrics?.passed == true
                            ? nil
                            : attemptErrors.joined(separator: "; ")
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
                let result = try await PlayerStressBenchmark.measure(
                    url: plan.primaryURL,
                    title: detail.name,
                    options: StremioPlayerConfiguration.makeOptions()
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
        engine: StremioPlayerConfiguration.Engine,
        audioOutput: StremioPlayerConfiguration.AudioOutput,
        metrics: PlayerStressMetrics?,
        error: String?
    ) {
        let report = SingleMoviePlaybackAuditReport(
            generatedAt: Date(),
            movie: movie,
            provider: provider,
            streamTitle: streamTitle,
            sourceProfile: sourceProfile,
            engine: engine.rawValue,
            audioOutput: audioOutput.rawValue,
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
                "SINGLE_MOVIE_PLAYBACK_AUDIT %@ engine=%@ audio=%@",
                report.passed ? "PASS" : "FAIL",
                engine.rawValue,
                audioOutput.rawValue
            )
        } catch {
            NSLog(
                "SINGLE_MOVIE_PLAYBACK_AUDIT FAIL report=%@",
                error.localizedDescription
            )
        }
    }
}
#endif
