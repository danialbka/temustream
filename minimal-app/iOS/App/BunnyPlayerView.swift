@preconcurrency import AVFoundation
@preconcurrency import AVKit
import Combine
import SwiftUI
import UIKit

/// Stremio's custom AVFoundation player. Bunny owns the rendering surface,
/// controls, seeking, captions, and PiP presentation instead of delegating UI
/// to AVPlayerViewController. AVPlayer still supplies Apple's hardware-backed
/// decode and adaptive network pipeline for formats supported by AVFoundation.
struct BunnyPlayerScreen: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    private let onProgress: PlaybackProgressHandler?
    private let onPlaybackReady: PlaybackReadyHandler?
    private let onExhausted: (@MainActor (Error) -> Void)?
    private let watchChannel: WatchPlaybackControlChannel?
    private let onControlsVisibilityChanged: PlaybackControlsVisibilityHandler?
    @StateObject private var model: BunnyPlaybackModel
    @State private var controlsVisible = true
    @State private var viewportMode = BunnyViewportMode.fit
    @State private var retryRevision = 0
    @State private var controlsRevision = 0
    @State private var toastMessage: String?
    @State private var didReportExhaustion = false
    @State private var runtimeRecoveryCount = 0
    @State private var runtimeRecoveryScheduled = false
    @State private var watchRegistrationID: UUID?
    @State private var trackPickerPresented = false
    @AppStorage("playerDebugOverlayEnabled") private var debugOverlaySetting = false

    init(
        plan: PlaybackPlan,
        title: String,
        initialPosition: TimeInterval = 0,
        minimumVideoDuration: TimeInterval = 4,
        onProgress: PlaybackProgressHandler? = nil,
        onPlaybackReady: PlaybackReadyHandler? = nil,
        watchChannel: WatchPlaybackControlChannel? = nil,
        onControlsVisibilityChanged: PlaybackControlsVisibilityHandler? = nil,
        onExhausted: (@MainActor (Error) -> Void)? = nil
    ) {
        self.title = title
        self.onProgress = onProgress
        self.onPlaybackReady = onPlaybackReady
        self.watchChannel = watchChannel
        self.onControlsVisibilityChanged = onControlsVisibilityChanged
        self.onExhausted = onExhausted
        _model = StateObject(
            wrappedValue: BunnyPlaybackModel(
                plan: plan,
                title: title,
                initialPosition: initialPosition,
                minimumVideoDuration: minimumVideoDuration
            )
        )
    }

    init(url: URL, title: String) {
        self.init(
            plan: PlaybackPlan(primaryURL: url, fallbackURL: nil),
            title: title
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                BunnyVideoSurface(
                    player: model.player,
                    customVideoLayer: model.customVideoLayer,
                    usesCustomDecoder: model.usesCustomDecoder,
                    viewportMode: viewportMode,
                    onLayerReady: model.attach(playerLayer:)
                )
                .ignoresSafeArea()
                .background(Color.black)
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
                .accessibilityIdentifier("bunny-player-video")

                if let bitmapSubtitleCue = model.bitmapSubtitleCue {
                    BunnyBitmapSubtitleOverlay(
                        cue: bitmapSubtitleCue,
                        presentationSize: model.bitmapSubtitlePresentationSize,
                        viewportMode: viewportMode
                    )
                }

                if !model.captionLines.isEmpty {
                    BunnySubtitleOverlay(lines: model.captionLines)
                }

                if model.isPreparing, model.failureMessage == nil {
                    startupOverlay
                }

                if controlsVisible, model.failureMessage == nil {
                    BunnyControlsOverlay(
                        model: model,
                        title: title,
                        viewportSize: proxy.size,
                        viewportMode: $viewportMode,
                        trackPickerPresented: $trackPickerPresented,
                        close: { dismiss() },
                        rotate: { BunnyPresentation.toggleOrientation() },
                        onInteraction: { scheduleControlsAutoHide() },
                        onViewportChange: { mode in
                            viewportMode = mode
                            showToast(mode.notice)
                        },
                        onSeekFailure: {
                            showToast("Couldn’t finish that seek — tap to retry")
                        }
                    )
                    .transition(.opacity)
                } else if model.failureMessage == nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showControls() }
                        .accessibilityLabel("Show player controls")
                        .accessibilityIdentifier("player-show-controls")
                }

                if debugOverlayEnabled,
                   model.failureMessage == nil,
                   !trackPickerPresented {
                    BunnyDebugOverlay(snapshot: model.debugSnapshot)
                }

                if let toastMessage {
                    BunnyToast(message: toastMessage)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                if let failureMessage = model.failureMessage {
                    playbackFailure(message: failureMessage)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .simultaneousGesture(pinchGesture)
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .animation(.easeOut(duration: 0.18), value: controlsVisible)
        .animation(.easeOut(duration: 0.18), value: toastMessage)
        .onChange(of: viewportMode) { mode in
            NSLog("PLAYER_VIEWPORT engine=Bunny mode=%@", mode.rawValue)
        }
        .onChange(of: model.noticeMessage) { message in
            guard let message else { return }
            showToast(message, duration: 4)
        }
        .task(id: retryRevision) { await runPlayback() }
        .onAppear {
            onControlsVisibilityChanged?(controlsVisible)
            registerWatchChannel()
            if startsLandscapeForVerification {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    BunnyPresentation.ensureLandscape()
                }
            }
        }
        .onChange(of: controlsVisible) { isVisible in
            onControlsVisibilityChanged?(isVisible)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
        ) { notification in
            guard notification.object as? AVPlayerItem === model.player.currentItem else {
                return
            }
            reportProgress(updateKind: .final)
            model.notePlaybackEnded()
            showControls(autoHide: false)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled)
        ) { notification in
            guard notification.object as? AVPlayerItem === model.player.currentItem else {
                return
            }
            model.notePlaybackStall()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)
        ) { notification in
            guard notification.object as? AVPlayerItem === model.player.currentItem else {
                return
            }
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey]
                as? Error ?? BunnyPlaybackError.assetNotPlayable
            handleRuntimeFailure(error)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
        ) { notification in
            model.handleAudioInterruption(notification)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .playbackAudioOutputWasDisconnected)
        ) { _ in
            model.pauseAfterAudioOutputDisconnect()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .playbackVoiceCaptureDidChange)
        ) { _ in
            model.handleAudioSessionReconfiguration()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
        ) { _ in
            model.applicationWillResignActive()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
        ) { _ in
            model.applicationDidBecomeActive()
        }
        .onDisappear {
            if let watchRegistrationID { watchChannel?.unregister(watchRegistrationID) }
            reportProgress(updateKind: .final)
            model.stop()
            #if targetEnvironment(simulator)
            PlaybackAudioSession.stopMicrophoneAuditIfNeeded()
            #endif
            BunnyPresentation.endAudioSession()
        }
    }

    @MainActor
    private func registerWatchChannel() {
        guard watchRegistrationID == nil, let watchChannel else { return }
        watchRegistrationID = watchChannel.register(
            sample: { model.watchPlaybackSample },
            apply: { adjustment, baselineRate in
                await model.applyWatchAdjustment(adjustment, baselineRate: baselineRate)
            }
        )
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onEnded { magnification in
                let nextMode: BunnyViewportMode?
                if magnification >= 1.08 {
                    nextMode = .fill
                } else if magnification <= 0.92 {
                    nextMode = .fit
                } else {
                    nextMode = nil
                }
                guard let nextMode, nextMode != viewportMode else { return }
                viewportMode = nextMode
            }
    }

    private var startupOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(Color.appAccent)
            Text(model.statusMessage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(.black.opacity(0.74), in: RoundedRectangle(cornerRadius: 18))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player-startup-status")
    }

    private func playbackFailure(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "hare.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.appAccent)
            Text("Bunny couldn’t play this stream")
                .font(.title3.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                didReportExhaustion = false
                runtimeRecoveryCount = 0
                runtimeRecoveryScheduled = false
                model.clearFailureForRetry()
                retryRevision += 1
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appAccent)
        }
        .padding(28)
        .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 22))
        .padding()
        .accessibilityIdentifier("player-error")
    }

    @MainActor
    private func runPlayback() async {
        do {
            try await model.prepare()
            guard !Task.isCancelled else { return }
            onPlaybackReady?()
            #if targetEnvironment(simulator)
            await PlaybackAudioSession.startMicrophoneAuditIfRequested()
            #endif
            scheduleControlsAutoHide()
            try await model.monitor(onProgress: onProgress)
        } catch is CancellationError {
            return
        } catch {
            while !Task.isCancelled, !model.acceptsRuntimeFailure {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled, !didReportExhaustion else { return }
            if scheduleRuntimeRecovery(after: error) { return }
            didReportExhaustion = true
            if let onExhausted {
                onExhausted(error)
            } else {
                model.presentFailure(error)
            }
        }
    }

    private func toggleControls() {
        if trackPickerPresented {
            trackPickerPresented = false
            scheduleControlsAutoHide()
            return
        }
        if controlsVisible {
            controlsRevision += 1
            controlsVisible = false
        } else {
            showControls()
        }
    }

    private func showControls(autoHide: Bool = true) {
        controlsVisible = true
        if autoHide {
            scheduleControlsAutoHide()
        } else {
            controlsRevision += 1
        }
    }

    private func scheduleControlsAutoHide() {
        controlsVisible = true
        controlsRevision += 1
        guard !keepsControlsVisibleForVerification else { return }
        let revision = controlsRevision
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            guard revision == controlsRevision,
                  model.wantsPlayback,
                  !model.isScrubbing,
                  !trackPickerPresented,
                  model.failureMessage == nil
            else { return }
            controlsVisible = false
        }
    }

    private func showToast(_ message: String, duration: TimeInterval = 1.4) {
        toastMessage = message
        let expected = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            if toastMessage == expected {
                toastMessage = nil
            }
        }
    }

    private func handleRuntimeFailure(_ error: Error) {
        guard !didReportExhaustion else { return }
        guard model.acceptsRuntimeFailure else {
            NSLog(
                "BUNNY_PLAYER deferred_failure lifecycle=inactive error=%@",
                error.localizedDescription
            )
            return
        }
        if scheduleRuntimeRecovery(after: error) { return }
        didReportExhaustion = true
        if let onExhausted {
            onExhausted(error)
        } else {
            model.presentFailure(error)
        }
    }

    @MainActor
    private func scheduleRuntimeRecovery(after error: Error) -> Bool {
        if runtimeRecoveryScheduled { return true }
        guard model.canRecoverFromRuntimeFailure,
              runtimeRecoveryCount < 2
        else { return false }
        runtimeRecoveryCount += 1
        runtimeRecoveryScheduled = true
        let delay = runtimeRecoveryCount == 1 ? 0.6 : 1.2
        showToast("Reconnecting stream…")
        NSLog(
            "BUNNY_PLAYER runtime_recovery attempt=%ld position=%.1f error=%@",
            runtimeRecoveryCount,
            model.currentTime,
            error.localizedDescription
        )
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !didReportExhaustion else { return }
            runtimeRecoveryScheduled = false
            retryRevision += 1
        }
        return true
    }

    private func reportProgress(updateKind: PlaybackProgressUpdateKind) {
        guard let progress = model.progressSnapshot else { return }
        onProgress?(progress.position, progress.duration, updateKind)
    }

    private var debugOverlayEnabled: Bool {
        debugOverlaySetting
            || ProcessInfo.processInfo.environment["SKELETON_PLAYER_DEBUG_OVERLAY"] == "1"
    }

    private var keepsControlsVisibleForVerification: Bool {
        ProcessInfo.processInfo.environment["SKELETON_PLAYER_CONTROLS_LOCKED"] == "1"
    }

    private var startsLandscapeForVerification: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["SKELETON_PLAYER_FIXTURE_LANDSCAPE"] == "1"
        #else
        false
        #endif
    }
}

private enum BunnyDecoderEngine {
    case native
    case customFFmpeg

    var logName: String {
        switch self {
        case .native: "avfoundation"
        case .customFFmpeg: "custom_ffmpeg"
        }
    }
}

@MainActor
private final class BunnyPlaybackModel: NSObject, ObservableObject {
    let player: AVPlayer

    @Published private(set) var statusMessage = "Preparing Bunny…"
    @Published private(set) var failureMessage: String?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPreparing = true
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var isSeeking = false
    @Published private(set) var isScrubbing = false
    @Published private(set) var wantsPlayback = true
    @Published private(set) var isMuted = false
    @Published private(set) var captionLines: [String] = []
    @Published private(set) var bitmapSubtitleCue: BunnyFFmpegBitmapSubtitleCue?
    @Published private(set) var audioOptions: [BunnyMediaOption] = []
    @Published private(set) var subtitleOptions: [BunnyMediaOption] = []
    @Published private(set) var selectedAudioID: UUID?
    @Published private(set) var selectedSubtitleID: UUID?
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var pictureInPictureSupported = false
    @Published private(set) var debugSnapshot = BunnyDebugSnapshot.waiting
    @Published private(set) var usesCustomDecoder = false
    @Published private(set) var noticeMessage: String?

    private let plan: PlaybackPlan
    private let title: String
    private let minimumVideoDuration: TimeInterval
    private var resumePosition: TimeInterval
    private var videoOutput: AVPlayerItemVideoOutput?
    private var legibleOutput: AVPlayerItemLegibleOutput?
    private let captionDelegate = BunnyCaptionDelegate()
    private weak var playerLayer: AVPlayerLayer?
    private var pictureInPictureController: AVPictureInPictureController?
    private var activeAsset: AVURLAsset?
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var mediaOptionsTask: Task<Void, Never>?
    private var stallCount = 0
    private var didRestorePosition = false
    private var activeEngine = BunnyDecoderEngine.native
    private var customDecoder: BunnyFFmpegDecoder?
    private var customMediaInfo: BunnyFFmpegMediaInfo?
    private var customOpenComplete = false
    private var customFirstFrame = false
    private var customEnded = false
    private var customFailure: Error?
    private var customSeekRevision = 0
    private var customSeekSucceeded = false
    private var customBufferedSeconds: TimeInterval = 0
    private var customDecodedFrames = 0
    private var customDroppedFrames = 0
    private var customRenderedAudioFrames = 0
    private var customDisplayFPS: Double?
    private var customMetricsSampleTime = 0.0
    private var customMetricsSampleFrames = 0
    private var customLastDecodedAt = 0.0
    private var customRecoveryAttempts = 0
    private var softwareDecodeURLs: Set<URL> = []
    private var captionRevision = 0
    private var activeCustomSubtitleCueID: UUID?
    private var applicationIsActive = true
    private var applicationLifecycleRevision = 0
    private var pendingPlaybackNotice: String?

    // FFmpeg's remote read timeout is 15 seconds. Resume seeks get one extra
    // second for the completion callback to reach the main actor, followed by
    // a separate window in which an actual post-seek frame must arrive.
    private static let customResumeSeekTimeout: TimeInterval = 16
    private static let customPostSeekMediaTimeout: TimeInterval = 8
    private static let resumeFallbackNotice =
        "Resume took too long, so Bunny started this stream from the beginning."

    init(
        plan: PlaybackPlan,
        title: String,
        initialPosition: TimeInterval,
        minimumVideoDuration: TimeInterval
    ) {
        self.plan = plan
        self.title = title
        resumePosition = max(initialPosition, 0)
        self.minimumVideoDuration = max(minimumVideoDuration, 0)
        player = AVPlayer()
        super.init()
        captionDelegate.model = self
        player.automaticallyWaitsToMinimizeStalling = true
        player.preventsDisplaySleepDuringVideoPlayback = true
    }

    var customVideoLayer: AVSampleBufferDisplayLayer? {
        customDecoder?.videoLayer
    }

    var bitmapSubtitlePresentationSize: CGSize {
        guard let size = customMediaInfo?.presentationSize,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0
        else {
            return bitmapSubtitleCue?.sourceSize ?? .zero
        }
        return size
    }

    var progressSnapshot: (position: TimeInterval, duration: TimeInterval)? {
        let position = activeEngine == .customFFmpeg
            ? customDecoder?.currentTime ?? currentTime
            : player.currentTime().seconds
        let itemDuration = activeEngine == .customFFmpeg
            ? duration
            : player.currentItem?.duration.seconds ?? duration
        guard position.isFinite, itemDuration.isFinite, itemDuration > 0 else { return nil }
        return (max(position, 0), itemDuration)
    }

    var canRecoverFromRuntimeFailure: Bool {
        !isPreparing && (currentTime >= 1 || customFirstFrame)
    }

    var acceptsRuntimeFailure: Bool { applicationIsActive }

    func attach(playerLayer: AVPlayerLayer) {
        self.playerLayer = playerLayer
        playerLayer.player = player
        configurePictureInPicture()
    }

    func prepare() async throws {
        resetAttemptState()
        BunnyPresentation.prepareAudioSession()

        var lastError: Error = BunnyPlaybackError.noPlayableCandidate
        for candidate in candidateURLs {
            guard !Task.isCancelled else { throw CancellationError() }
            let sourceTitle = [title, plan.detectedMIMEType]
                .compactMap { $0 }
                .joined(separator: " ")
            let policy = PlaybackPerformanceCore.policy(
                url: candidate,
                title: sourceTitle,
                player: .bunny
            )
            let engines: [BunnyDecoderEngine] = policy.decoder == .bunnyFFmpeg
                ? [.customFFmpeg]
                : [.native, .customFFmpeg]

            for engine in engines {
                guard !Task.isCancelled else { throw CancellationError() }
                didRestorePosition = resumePosition <= 0
                statusMessage = engine == .customFFmpeg
                    ? "Opening Bunny decoder…"
                    : (candidate == plan.fallbackURL
                        ? "Optimizing stream for Bunny…"
                        : "Preparing Bunny…")
                do {
                    switch engine {
                    case .native:
                        try await prepareNativeCandidate(candidate)
                    case .customFFmpeg:
                        try await prepareCustomCandidate(
                            candidate,
                            preferHardwareVideoDecoding: !softwareDecodeURLs.contains(candidate)
                        )
                    }
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                    NSLog(
                        "BUNNY_PLAYER candidate_failed engine=%@ host=%@ error=%@",
                        engine.logName,
                        candidate.host ?? "local",
                        error.localizedDescription
                    )
                    cleanupCurrentEngineForNextAttempt()
                }
            }
        }
        throw lastError
    }

    private func prepareNativeCandidate(_ url: URL) async throws {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let pathExtension = url.pathExtension.lowercased()
        let normalizedMIMEType = plan.detectedMIMEType?.lowercased() ?? ""
        let isAdaptiveStream = pathExtension == "m3u8"
            || normalizedMIMEType.contains("mpegurl")

        activeEngine = .native
        usesCustomDecoder = false
        configurePictureInPicture()

        let asset: AVURLAsset
        if #available(iOS 17.0, *),
           url == plan.primaryURL,
           let detectedMIMEType = plan.detectedMIMEType,
           !detectedMIMEType.isEmpty {
            asset = AVURLAsset(
                url: url,
                options: [AVURLAssetOverrideMIMETypeKey: detectedMIMEType]
            )
        } else {
            asset = AVURLAsset(url: url)
        }

        var videoTracks: [AVAssetTrack] = []
        if !isAdaptiveStream {
            let isPlayable = try await asset.load(.isPlayable)
            guard isPlayable else { throw BunnyPlaybackError.assetNotPlayable }
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
                throw BunnyPlaybackError.noMediaTracks
            }
        }

        let item = AVPlayerItem(asset: asset)
        applySubtitleStyle(to: item)
        // Start adaptive playback immediately. Once the first frame is on
        // screen, grow a bounded cushion in the background for smooth seeking.
        item.preferredForwardBufferDuration = 0
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false

        let output = AVPlayerItemVideoOutput(
            pixelBufferAttributes: [
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        )
        item.add(output)

        let captions = AVPlayerItemLegibleOutput()
        captions.suppressesPlayerRendering = true
        captions.advanceIntervalForDelegateInvocation = 0
        captions.setDelegate(captionDelegate, queue: .main)
        item.add(captions)

        activeAsset = asset
        videoOutput = output
        legibleOutput = captions
        player.replaceCurrentItem(with: item)
        resumePlayback()
        wantsPlayback = true
        mediaOptionsTask = Task { @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            await self.configureMediaOptions(asset: asset, item: item)
        }

        var readyAt: TimeInterval?
        while !Task.isCancelled {
            if item.status == .failed {
                throw item.error ?? BunnyPlaybackError.assetNotPlayable
            }
            if item.status == .readyToPlay {
                let itemDuration = item.duration.seconds
                if itemDuration.isFinite, itemDuration > 0 {
                    duration = itemDuration
                    if itemDuration < minimumVideoDuration {
                        throw BunnyPlaybackError.unexpectedShortVideo(itemDuration)
                    }
                }

                if !didRestorePosition, resumePosition > 0 {
                    didRestorePosition = true
                    let target = itemDuration.isFinite && itemDuration > 0
                        ? min(resumePosition, max(itemDuration - 1, 0))
                        : resumePosition
                    let restored = await performSeek(to: target, resume: true)
                    if !restored {
                        resumePosition = 0
                        pendingPlaybackNotice = Self.resumeFallbackNotice
                        _ = await seekCompletion(to: 0, tolerance: .zero)
                        resumePlayback()
                    }
                }

                if readyAt == nil {
                    readyAt = ProcessInfo.processInfo.systemUptime
                }
                let expectsVisibleFrame = isAdaptiveStream || !videoTracks.isEmpty
                let hasVisibleFrame = !expectsVisibleFrame
                    || playerLayer?.isReadyForDisplay == true
                    || output.hasNewPixelBuffer(forItemTime: item.currentTime())
                if hasVisibleFrame,
                   (player.timeControlStatus == .playing || player.rate > 0) {
                    currentTime = max(item.currentTime().seconds, 0)
                    isPreparing = false
                    statusMessage = ""
                    publishPendingPlaybackNotice()
                    if !url.isFileURL {
                        item.preferredForwardBufferDuration = 8
                    }
                    refreshPlaybackState()
                    NSLog(
                        "BUNNY_PLAYER ready_ms=%.1f hardware=avfoundation source=%@",
                        (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
                        url.host ?? "local"
                    )
                    return
                }

                if let readyAt,
                   ProcessInfo.processInfo.systemUptime - readyAt >= 4 {
                    throw BunnyPlaybackError.noVisibleFrame
                }
            }
            let startupTimeout: TimeInterval = 18
            if ProcessInfo.processInfo.systemUptime - startedAt >= startupTimeout {
                throw BunnyPlaybackError.startupTimedOut(startupTimeout)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CancellationError()
    }

    private func prepareCustomCandidate(
        _ url: URL,
        preferHardwareVideoDecoding: Bool
    ) async throws {
        var useHardware = preferHardwareVideoDecoding
        var didRestartAfterResumeFailure = false

        while !Task.isCancelled {
            do {
                try await prepareCustomDecoder(
                    url,
                    preferHardwareVideoDecoding: useHardware
                )
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch BunnyPlaybackError.seekFailed
                where resumePosition > 0 && !didRestartAfterResumeFailure {
                didRestartAfterResumeFailure = true
                let failedPosition = resumePosition
                resumePosition = 0
                pendingPlaybackNotice = Self.resumeFallbackNotice
                cleanupCurrentEngineForNextAttempt()
                didRestorePosition = true
                statusMessage = "Starting this stream from the beginning…"
                NSLog(
                    "BUNNY_PLAYER resume_fallback=same_stream position=%.1f host=%@",
                    failedPosition,
                    url.host ?? "local"
                )
            } catch {
                let decoderError = error as NSError
                let explicitlyRetryable = decoderError.userInfo[
                    BunnyFFmpegDecoderSoftwareRetryKey
                ] as? Bool == true
                let openedHardwareWithoutFrame = customOpenComplete
                    && customMediaInfo?.hasVideo == true
                    && !customFirstFrame
                    && customDecoder?.hardwareVideoDecoderNegotiated == true
                guard useHardware,
                      explicitlyRetryable || openedHardwareWithoutFrame
                else {
                    if didRestartAfterResumeFailure {
                        pendingPlaybackNotice = nil
                    }
                    throw error
                }

                useHardware = false
                softwareDecodeURLs.insert(url)
                cleanupCurrentEngineForNextAttempt()
                didRestorePosition = resumePosition <= 0
                statusMessage = "Retrying with Bunny software decoder…"
                NSLog(
                    "BUNNY_PLAYER decoder_fallback from=videotoolbox to=software host=%@ error=%@",
                    url.host ?? "local",
                    error.localizedDescription
                )
            }
        }
        throw CancellationError()
    }

    private func prepareCustomDecoder(
        _ url: URL,
        preferHardwareVideoDecoding: Bool
    ) async throws {
        let startedAt = ProcessInfo.processInfo.systemUptime
        activeEngine = .customFFmpeg
        usesCustomDecoder = true
        player.pause()
        player.replaceCurrentItem(with: nil)
        clearMediaOutputs()

        let decoder = BunnyFFmpegDecoder(
            url: url,
            preferHardwareVideoDecoding: preferHardwareVideoDecoding
        )
        customDecoder = decoder
        customOpenComplete = false
        customFirstFrame = false
        customEnded = false
        customFailure = nil
        customBufferedSeconds = 0
        customDecodedFrames = 0
        customDroppedFrames = 0
        customRenderedAudioFrames = 0
        customDisplayFPS = nil
        customMetricsSampleFrames = 0
        customMetricsSampleTime = ProcessInfo.processInfo.systemUptime
        customLastDecodedAt = customMetricsSampleTime
        customRecoveryAttempts = 0

        decoder.onOpen = { [weak self, weak decoder] info in
            guard let self, let decoder, self.customDecoder === decoder else { return }
            self.customMediaInfo = info
            self.customOpenComplete = true
            self.customDisplayFPS = info.nominalFrameRate > 0 ? info.nominalFrameRate : nil
            if info.duration.isFinite, info.duration > 0 {
                self.duration = info.duration
            }
            self.audioOptions = info.audioTracks.map(BunnyMediaOption.init(track:))
            self.subtitleOptions = info.subtitleTracks.map(BunnyMediaOption.init(track:))
            if let preferredAudio = self.preferredOption(
                in: self.audioOptions,
                language: PlaybackLanguagePreferences.preferredAudioLanguage()
            ), let streamIndex = preferredAudio.customStreamIndex {
                decoder.selectAudioStreamIndex(streamIndex)
                self.selectedAudioID = preferredAudio.id
            } else {
                self.selectedAudioID = self.audioOptions.first {
                    $0.customStreamIndex == info.selectedAudioStreamIndex
                }?.id
            }
            if PlaybackLanguagePreferences.subtitlesEnabled(),
               let preferredSubtitle = self.preferredOption(
                    in: self.subtitleOptions,
                    language: PlaybackLanguagePreferences.preferredSubtitleLanguage()
               ), let streamIndex = preferredSubtitle.customStreamIndex {
                decoder.selectSubtitleStreamIndex(streamIndex)
                self.selectedSubtitleID = preferredSubtitle.id
            } else {
                decoder.selectSubtitleStreamIndex(-1)
                self.selectedSubtitleID = nil
            }
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["SKELETON_BUNNY_AUTO_SUBTITLE"] == "1",
               let firstSubtitle = self.subtitleOptions.first,
               let streamIndex = firstSubtitle.customStreamIndex {
                decoder.selectSubtitleStreamIndex(streamIndex)
                self.selectedSubtitleID = firstSubtitle.id
            }
            #endif
            self.configurePictureInPicture()
        }
        decoder.onFirstFrame = { [weak self, weak decoder] in
            guard let self, let decoder, self.customDecoder === decoder else { return }
            self.customFirstFrame = true
        }
        decoder.onSubtitle = { [weak self, weak decoder] text, start, duration in
            guard let self, let decoder, self.customDecoder === decoder else { return }
            self.scheduleCustomSubtitle(text, start: start, duration: duration)
        }
        decoder.onBitmapSubtitle = { [weak self, weak decoder] cue, start, duration in
            guard let self, let decoder, self.customDecoder === decoder else { return }
            self.scheduleCustomBitmapSubtitle(cue, start: start, duration: duration)
        }
        decoder.onSeekCompleted = { [weak self, weak decoder] position, succeeded in
            guard let self, let decoder, self.customDecoder === decoder else { return }
            if succeeded {
                self.currentTime = max(position, 0)
            }
            self.customSeekSucceeded = succeeded
            self.customSeekRevision += 1
            self.customMetricsSampleFrames = self.customDecodedFrames
            self.customMetricsSampleTime = ProcessInfo.processInfo.systemUptime
            if let frameRate = self.customMediaInfo?.nominalFrameRate, frameRate > 0 {
                self.customDisplayFPS = frameRate
            }
        }
        decoder.onMetrics = { [weak self, weak decoder] decoded, dropped, renderedAudio, buffered, _, _ in
            guard let self, let decoder, self.customDecoder === decoder else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - self.customMetricsSampleTime
            if decoded > self.customDecodedFrames {
                self.customLastDecodedAt = now
            }
            // Sample-buffer renderers accept short bursts into their bounded
            // queue. A four-second cadence window reports scheduled display
            // rate without turning those healthy bursts into misleading FPS.
            if elapsed >= 4 {
                self.customDisplayFPS = Double(max(decoded - self.customMetricsSampleFrames, 0)) / elapsed
                self.customMetricsSampleFrames = decoded
                self.customMetricsSampleTime = now
            }
            self.customDecodedFrames = decoded
            self.customDroppedFrames = dropped
            self.customRenderedAudioFrames = renderedAudio
            self.customBufferedSeconds = max(buffered, 0)
        }
        decoder.onEnded = { [weak self, weak decoder] in
            guard let self, let decoder, self.customDecoder === decoder else { return }
            self.customEnded = true
        }
        decoder.onFailure = { [weak self, weak decoder] error in
            guard let self, let decoder, self.customDecoder === decoder else { return }
            if preferHardwareVideoDecoding,
               (error as NSError).userInfo[BunnyFFmpegDecoderSoftwareRetryKey] as? Bool == true {
                self.softwareDecodeURLs.insert(url)
            }
            self.customFailure = error
        }
        decoder.start()

        while !Task.isCancelled {
            if let customFailure {
                throw customFailure
            }
            if customOpenComplete, customFirstFrame {
                if duration > 0, duration < minimumVideoDuration {
                    throw BunnyPlaybackError.unexpectedShortVideo(duration)
                }
                if !didRestorePosition, resumePosition > 0 {
                    didRestorePosition = true
                    let target = duration > 0
                        ? min(resumePosition, max(duration - 1, 0))
                        : resumePosition
                    guard await performCustomSeek(
                        to: target,
                        resume: true,
                        timeout: Self.customResumeSeekTimeout,
                        postSeekMediaTimeout: Self.customPostSeekMediaTimeout
                    ) else {
                        throw BunnyPlaybackError.seekFailed
                    }
                } else {
                    decoder.play(atRate: playbackRate)
                }
                customMetricsSampleFrames = customDecodedFrames
                customMetricsSampleTime = ProcessInfo.processInfo.systemUptime
                if let frameRate = customMediaInfo?.nominalFrameRate, frameRate > 0 {
                    customDisplayFPS = frameRate
                }
                wantsPlayback = true
                isPreparing = false
                statusMessage = ""
                publishPendingPlaybackNotice()
                refreshPlaybackState()
                NSLog(
                    "BUNNY_PLAYER ready_ms=%.1f engine=custom_ffmpeg hardware=%@ requested=%@ container=%@ source=%@",
                    (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
                    decoder.hardwareVideoDecode ? "videotoolbox" : "software",
                    preferHardwareVideoDecoding ? "hardware-first" : "software-only",
                    customMediaInfo?.containerName ?? "unknown",
                    url.host ?? "local"
                )
                return
            }
            let sourceIs4K = max(
                customMediaInfo?.presentationSize.width ?? 0,
                customMediaInfo?.presentationSize.height ?? 0
            ) >= 3_000
            // Some large provider files spend most of the normal startup
            // budget probing and reaching their first interleaved keyframe.
            // Once Bunny has positively opened a 4K source, give its hardware
            // path enough time to produce media instead of misreporting an
            // otherwise playable stream as unsupported.
            let startupTimeout: TimeInterval = !url.isFileURL && sourceIs4K ? 35 : 20
            if ProcessInfo.processInfo.systemUptime - startedAt >= startupTimeout {
                throw BunnyPlaybackError.startupTimedOut(startupTimeout)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CancellationError()
    }

    func monitor(onProgress: PlaybackProgressHandler?) async throws {
        var lastPosition = currentTime
        var lastAdvanceAt = ProcessInfo.processInfo.systemUptime
        var lastProgressReportAt = lastAdvanceAt
        var lastDebugSampleAt = 0.0
        var lastDecodedFrames = customDecodedFrames
        var lastDecodeAt = lastAdvanceAt
        var nativeRecoveryAttempts = 0
        var observedLifecycleRevision = applicationLifecycleRevision

        while !Task.isCancelled, hasActivePlayback {
            refreshPlaybackState()
            let now = ProcessInfo.processInfo.systemUptime
            let sampledTime = currentTime
            if observedLifecycleRevision != applicationLifecycleRevision
                || !applicationIsActive {
                observedLifecycleRevision = applicationLifecycleRevision
                if sampledTime.isFinite { lastPosition = sampledTime }
                lastAdvanceAt = now
                lastDecodeAt = now
                try await Task.sleep(for: .milliseconds(250))
                continue
            }
            if !wantsPlayback || isScrubbing || isSeeking {
                if sampledTime.isFinite { lastPosition = sampledTime }
                lastAdvanceAt = now
            } else if sampledTime.isFinite, sampledTime >= lastPosition + 0.08 {
                lastPosition = sampledTime
                lastAdvanceAt = now
                customRecoveryAttempts = 0
                nativeRecoveryAttempts = 0
            }

            if customDecodedFrames > lastDecodedFrames {
                lastDecodedFrames = customDecodedFrames
                lastDecodeAt = now
            }
            if let customFailure, activeEngine == .customFFmpeg {
                throw customFailure
            }
            if customEnded, activeEngine == .customFFmpeg {
                if let progressSnapshot {
                    onProgress?(progressSnapshot.position, progressSnapshot.duration, .final)
                }
                notePlaybackEnded()
                return
            }
            if activeEngine == .native,
               let item = player.currentItem,
               item.status == .failed {
                throw item.error ?? BunnyPlaybackError.assetNotPlayable
            }

            if activeEngine == .native,
               wantsPlayback,
               !isScrubbing,
               !isSeeking,
               player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
               now - lastAdvanceAt >= 4,
               bufferedSeconds >= 1.5 {
                resumePlaybackImmediately()
                lastAdvanceAt = now
                NSLog("BUNNY_PLAYER recovery=bounded-play buffer=%.2f", bufferedSeconds)
            }

            if activeEngine == .customFFmpeg,
               wantsPlayback,
               !isScrubbing,
               !isSeeking,
               customDecoder?.rate == 0,
               customBufferedSeconds >= 0.15 {
                customDecoder?.play(atRate: playbackRate)
            }

            let playbackHasStalled = now - lastAdvanceAt >= 15
                && (activeEngine != .customFFmpeg || now - lastDecodeAt >= 15)
            if wantsPlayback,
               !isScrubbing,
               !isSeeking,
               playbackHasStalled,
               (duration <= 0 || currentTime < duration - 1) {
                if activeEngine == .customFFmpeg, customRecoveryAttempts < 2 {
                    customRecoveryAttempts += 1
                    let recovered = await performSeek(to: currentTime, resume: true)
                    lastAdvanceAt = now
                    lastDecodeAt = now
                    NSLog(
                        "BUNNY_PLAYER recovery=custom-demux-reset attempt=%d succeeded=%@",
                        customRecoveryAttempts,
                        recovered ? "yes" : "no"
                    )
                } else if activeEngine == .native, nativeRecoveryAttempts < 2 {
                    nativeRecoveryAttempts += 1
                    let recovered = await performSeek(to: currentTime, resume: true)
                    lastAdvanceAt = now
                    NSLog(
                        "BUNNY_PLAYER recovery=native-rebuffer attempt=%d succeeded=%@",
                        nativeRecoveryAttempts,
                        recovered ? "yes" : "no"
                    )
                } else {
                    throw BunnyPlaybackError.playbackStalled
                }
            }

            if now - lastProgressReportAt >= 5 {
                lastProgressReportAt = now
                if let progressSnapshot {
                    onProgress?(
                        progressSnapshot.position,
                        progressSnapshot.duration,
                        .checkpoint
                    )
                }
            }

            if debugOverlayEnabled, now - lastDebugSampleAt >= 1 {
                lastDebugSampleAt = now
                debugSnapshot = makeDebugSnapshot()
                NSLog("PLAYER_DEBUG %@", debugSnapshot.logDescription)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    func togglePlayback() {
        if wantsPlayback {
            wantsPlayback = false
            if activeEngine == .customFFmpeg {
                customDecoder?.pause()
            } else {
                player.pause()
            }
            isPlaying = false
            isBuffering = false
        } else {
            if duration > 0, currentTime >= duration - 0.5 {
                Task { @MainActor in
                    _ = await performSeek(to: 0, resume: true)
                }
            } else {
                wantsPlayback = true
                if activeEngine == .customFFmpeg {
                    customDecoder?.play(atRate: playbackRate)
                } else {
                    resumePlayback()
                }
                refreshPlaybackState()
            }
        }
    }

    var watchPlaybackSample: WatchLocalPlaybackSample? {
        guard hasActivePlayback, currentTime.isFinite else { return nil }
        return WatchLocalPlaybackSample(
            position: currentTime,
            isPlaying: isPlaying,
            rate: Double(playbackRate)
        )
    }

    func applyWatchAdjustment(
        _ adjustment: WatchPlaybackAdjustment,
        baselineRate: Double
    ) async {
        let requestedRate = Float(
            adjustment.temporaryRate ?? adjustment.playbackRate ?? baselineRate
        )
        let shouldResume = adjustment.shouldPlay ?? wantsPlayback
        if let target = adjustment.targetPosition {
            _ = await performSeek(to: target, resume: shouldResume)
        }
        if adjustment.temporaryRate != nil || adjustment.playbackRate != nil {
            playbackRate = requestedRate
            if activeEngine == .customFFmpeg {
                if shouldResume { customDecoder?.play(atRate: requestedRate) }
            } else if shouldResume {
                player.playImmediately(atRate: requestedRate)
            }
        }
        if adjustment.shouldPlay == false, wantsPlayback {
            togglePlayback()
        } else if adjustment.shouldPlay == true, !wantsPlayback {
            togglePlayback()
        }
    }

    func toggleMute() {
        if activeEngine == .customFFmpeg {
            customDecoder?.isMuted.toggle()
            isMuted = customDecoder?.isMuted ?? false
        } else {
            player.isMuted.toggle()
            isMuted = player.isMuted
        }
    }

    func pauseForScrubbing() -> Bool {
        let shouldResume = wantsPlayback
        isScrubbing = true
        if activeEngine == .customFFmpeg {
            customDecoder?.pause()
        } else {
            player.pause()
        }
        isPlaying = false
        isBuffering = false
        return shouldResume
    }

    func finishScrubbing(to target: TimeInterval, resume: Bool) async -> Bool {
        isScrubbing = false
        return await performSeek(to: target, resume: resume)
    }

    func seek(by interval: TimeInterval) async -> Bool {
        let upperBound = duration > 0 ? max(duration - 0.25, 0) : .greatestFiniteMagnitude
        let target = min(max(currentTime + interval, 0), upperBound)
        return await performSeek(to: target, resume: wantsPlayback)
    }

    private func performSeek(to requestedTarget: TimeInterval, resume: Bool) async -> Bool {
        if activeEngine == .customFFmpeg {
            return await performCustomSeek(to: requestedTarget, resume: resume)
        }
        guard let item = player.currentItem else { return false }
        isSeeking = true
        let target = duration > 0
            ? min(max(requestedTarget, 0), max(duration - 0.25, 0))
            : max(requestedTarget, 0)
        player.pause()

        var finished = await seekCompletion(
            to: target,
            tolerance: CMTime(seconds: 0.2, preferredTimescale: 600)
        )
        let firstPosition = item.currentTime().seconds
        if !finished || !firstPosition.isFinite || abs(firstPosition - target) > 2 {
            finished = await seekCompletion(to: target, tolerance: .zero)
        }

        let resolvedPosition = item.currentTime().seconds
        if resolvedPosition.isFinite {
            currentTime = max(resolvedPosition, 0)
        }
        wantsPlayback = resume
        if resume {
            resumePlayback()
            for _ in 0..<20 {
                if player.rate > 0 || player.timeControlStatus == .playing { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if player.rate == 0,
               player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
               bufferedSeconds >= 1 {
                resumePlaybackImmediately()
            }
        }
        isSeeking = false
        refreshPlaybackState()
        NSLog(
            "BUNNY_PLAYER seek target=%.2f actual=%.2f resume=%@ finished=%@",
            target,
            currentTime,
            resume ? "yes" : "no",
            finished ? "yes" : "no"
        )
        return finished && abs(currentTime - target) <= 2.5
    }

    private func performCustomSeek(
        to requestedTarget: TimeInterval,
        resume: Bool,
        timeout: TimeInterval = 6,
        postSeekMediaTimeout: TimeInterval? = nil
    ) async -> Bool {
        guard let customDecoder else { return false }
        isSeeking = true
        let target = duration > 0
            ? min(max(requestedTarget, 0), max(duration - 0.25, 0))
            : max(requestedTarget, 0)
        invalidateCustomSubtitles()
        customDecoder.pause()
        let expectedRevision = customSeekRevision + 1
        customSeekSucceeded = false
        customDecoder.seek(toTime: target)

        let videoFramesBeforeSeek = customDecodedFrames
        let audioFramesBeforeSeek = customRenderedAudioFrames
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while customSeekRevision < expectedRevision,
              ProcessInfo.processInfo.systemUptime < deadline,
              !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(25))
        }
        var finished = customSeekRevision >= expectedRevision && customSeekSucceeded
        wantsPlayback = resume
        if resume, finished {
            customDecoder.play(atRate: playbackRate)
        }
        if finished, let postSeekMediaTimeout {
            let mediaDeadline = ProcessInfo.processInfo.systemUptime + postSeekMediaTimeout
            while !hasCustomMediaAdvanced(
                videoFramesBeforeSeek: videoFramesBeforeSeek,
                audioFramesBeforeSeek: audioFramesBeforeSeek
            ), ProcessInfo.processInfo.systemUptime < mediaDeadline,
                  customFailure == nil,
                  !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(25))
            }
            finished = customFailure == nil && hasCustomMediaAdvanced(
                videoFramesBeforeSeek: videoFramesBeforeSeek,
                audioFramesBeforeSeek: audioFramesBeforeSeek
            )
        }
        if finished {
            currentTime = max(customDecoder.currentTime, target)
            resumePosition = target
        } else {
            let decoderTime = customDecoder.currentTime
            if decoderTime.isFinite {
                currentTime = max(decoderTime, 0)
            }
        }
        isSeeking = false
        refreshPlaybackState()
        NSLog(
            "BUNNY_PLAYER seek engine=custom_ffmpeg target=%.2f resume=%@ timeout=%.1f post_frame=%@ finished=%@",
            target,
            resume ? "yes" : "no",
            timeout,
            postSeekMediaTimeout == nil ? "not-required" : "required",
            finished ? "yes" : "no"
        )
        return finished
    }

    private func hasCustomMediaAdvanced(
        videoFramesBeforeSeek: Int,
        audioFramesBeforeSeek: Int
    ) -> Bool {
        if customMediaInfo?.hasVideo == true {
            return customDecodedFrames > videoFramesBeforeSeek
        }
        if customMediaInfo?.hasAudio == true {
            return customRenderedAudioFrames > audioFramesBeforeSeek
        }
        return false
    }

    private func seekCompletion(to seconds: TimeInterval, tolerance: CMTime) async -> Bool {
        await withCheckedContinuation { continuation in
            player.seek(
                to: CMTime(seconds: seconds, preferredTimescale: 600),
                toleranceBefore: tolerance,
                toleranceAfter: tolerance
            ) { finished in
                continuation.resume(returning: finished)
            }
        }
    }

    func selectAudio(_ track: BunnyMediaOption) {
        switch track.source {
        case let .native(option):
            guard let item = player.currentItem, let audioGroup else { return }
            let shouldResume = wantsPlayback
            let selectionTime = item.currentTime().seconds
            player.pause()
            item.select(option, in: audioGroup)
            selectedAudioID = track.id
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                if selectionTime.isFinite,
                   selectionTime > 0,
                   item.duration.seconds.isFinite,
                   item.duration.seconds > 0 {
                    _ = await self.performSeek(to: selectionTime, resume: shouldResume)
                } else if shouldResume {
                    self.resumePlayback()
                    self.refreshPlaybackState()
                }
                NSLog(
                    "BUNNY_PLAYER audio_switch engine=avfoundation resumed=%@",
                    shouldResume ? "yes" : "no"
                )
            }
        case let .custom(streamIndex):
            customDecoder?.selectAudioStreamIndex(streamIndex)
            selectedAudioID = track.id
            NSLog("BUNNY_PLAYER audio_switch engine=custom_ffmpeg stream=%ld", streamIndex)
        }
        PlaybackLanguagePreferences.rememberAudioSelection(
            languageTag: track.languageTag,
            displayName: track.title
        )
    }

    func selectSubtitle(_ track: BunnyMediaOption?) {
        invalidateCustomSubtitles()
        if activeEngine == .customFFmpeg {
            customDecoder?.selectSubtitleStreamIndex(track?.customStreamIndex ?? -1)
        } else if let item = player.currentItem, let subtitleGroup {
            item.select(track?.nativeOption, in: subtitleGroup)
        }
        selectedSubtitleID = track?.id
        if let track {
            PlaybackLanguagePreferences.rememberSubtitleSelection(
                languageTag: track.languageTag,
                displayName: track.title
            )
        } else {
            PlaybackLanguagePreferences.rememberSubtitlesDisabled()
        }
    }

    func selectPlaybackRate(_ rate: Float) {
        guard BunnyPlaybackRate.supported.contains(rate) else { return }
        playbackRate = rate
        if wantsPlayback, !isScrubbing, !isSeeking {
            if activeEngine == .customFFmpeg {
                customDecoder?.play(atRate: rate)
            } else {
                resumePlaybackImmediately()
            }
            refreshPlaybackState()
        }
        NSLog("BUNNY_PLAYER playback_rate=%.2f", rate)
    }

    func togglePictureInPicture() {
        guard let pictureInPictureController else { return }
        if pictureInPictureController.isPictureInPictureActive {
            pictureInPictureController.stopPictureInPicture()
        } else if pictureInPictureController.isPictureInPicturePossible {
            pictureInPictureController.startPictureInPicture()
        }
    }

    func updateCaptionLines(_ lines: [String]) {
        bitmapSubtitleCue = nil
        captionLines = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func notePlaybackStall() {
        stallCount += 1
        isBuffering = wantsPlayback
    }

    func notePlaybackEnded() {
        invalidateCustomSubtitles()
        wantsPlayback = false
        isPlaying = false
        isBuffering = false
        if duration > 0 {
            currentTime = duration
        }
    }

    func handleAudioInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }
        switch type {
        case .began:
            if activeEngine == .customFFmpeg {
                customDecoder?.pause()
            } else {
                player.pause()
            }
            isPlaying = false
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions ?? 0)
            if wantsPlayback, options.contains(.shouldResume) {
                BunnyPresentation.prepareAudioSession()
                if activeEngine == .customFFmpeg {
                    customDecoder?.play(atRate: playbackRate)
                } else {
                    resumePlayback()
                }
            }
        @unknown default:
            break
        }
    }

    func handleAudioSessionReconfiguration() {
        PlaybackAudioSession.reactivatePlayback()
        guard wantsPlayback, !isPreparing else { return }
        if activeEngine == .customFFmpeg {
            customDecoder?.play(atRate: playbackRate)
        } else {
            resumePlayback()
        }
        refreshPlaybackState()
    }

    func pauseAfterAudioOutputDisconnect() {
        guard wantsPlayback else { return }
        wantsPlayback = false
        if activeEngine == .customFFmpeg {
            customDecoder?.pause()
        } else {
            player.pause()
        }
        refreshPlaybackState()
        NSLog("BUNNY_PLAYER audio_route_disconnect action=pause")
    }


    func applicationWillResignActive() {
        applicationIsActive = false
        applicationLifecycleRevision &+= 1
        NSLog("BUNNY_PLAYER lifecycle=inactive position=%.1f", currentTime)
    }

    func applicationDidBecomeActive() {
        applicationIsActive = true
        applicationLifecycleRevision &+= 1
        PlaybackAudioSession.reactivatePlayback()
        guard wantsPlayback, !isPreparing else { return }
        if activeEngine == .customFFmpeg {
            customDecoder?.play(atRate: playbackRate)
        } else {
            resumePlayback()
        }
        refreshPlaybackState()
        NSLog("BUNNY_PLAYER lifecycle=active position=%.1f", currentTime)
    }

    func presentFailure(_ error: Error) {
        player.pause()
        customDecoder?.pause()
        invalidateCustomSubtitles()
        wantsPlayback = false
        isPlaying = false
        isBuffering = false
        isPreparing = false
        statusMessage = ""
        failureMessage = error.localizedDescription
    }

    func clearFailureForRetry() {
        failureMessage = nil
        statusMessage = "Preparing Bunny…"
        isPreparing = true
    }

    func stop() {
        invalidateCustomSubtitles()
        pictureInPictureController?.stopPictureInPicture()
        pictureInPictureController = nil
        pictureInPictureSupported = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        customDecoder?.stop()
        customDecoder = nil
        clearMediaOutputs()
    }

    private func resetAttemptState() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        customDecoder?.stop()
        customDecoder = nil
        clearMediaOutputs()
        isPreparing = true
        failureMessage = nil
        statusMessage = "Preparing Bunny…"
        currentTime = 0
        duration = 0
        isPlaying = false
        isBuffering = false
        isSeeking = false
        isScrubbing = false
        wantsPlayback = true
        invalidateCustomSubtitles()
        audioOptions = []
        subtitleOptions = []
        selectedAudioID = nil
        selectedSubtitleID = nil
        usesCustomDecoder = false
        activeEngine = .native
        noticeMessage = nil
        pendingPlaybackNotice = nil
        customMediaInfo = nil
        customOpenComplete = false
        customFirstFrame = false
        customEnded = false
        customFailure = nil
        customSeekRevision = 0
        customSeekSucceeded = false
        customBufferedSeconds = 0
        customDecodedFrames = 0
        customDroppedFrames = 0
        customRenderedAudioFrames = 0
        customDisplayFPS = nil
        customRecoveryAttempts = 0
        stallCount = 0
        didRestorePosition = resumePosition <= 0
        debugSnapshot = .waiting
    }

    private func publishPendingPlaybackNotice() {
        guard let pendingPlaybackNotice else { return }
        self.pendingPlaybackNotice = nil
        noticeMessage = pendingPlaybackNotice
    }

    private func clearMediaOutputs() {
        mediaOptionsTask?.cancel()
        mediaOptionsTask = nil
        legibleOutput?.setDelegate(nil, queue: nil)
        legibleOutput = nil
        videoOutput = nil
        activeAsset = nil
        audioGroup = nil
        subtitleGroup = nil
    }

    private func cleanupCurrentEngineForNextAttempt() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        customDecoder?.stop()
        customDecoder = nil
        customMediaInfo = nil
        usesCustomDecoder = false
        clearMediaOutputs()
        invalidateCustomSubtitles()
    }

    private var hasActivePlayback: Bool {
        switch activeEngine {
        case .native:
            player.currentItem != nil
        case .customFFmpeg:
            customDecoder != nil
        }
    }

    private func scheduleCustomSubtitle(
        _ text: String?,
        start: TimeInterval,
        duration subtitleDuration: TimeInterval
    ) {
        guard let text, !text.isEmpty, selectedSubtitleID != nil else {
            scheduleCustomSubtitleClear(at: start)
            return
        }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            scheduleCustomSubtitleClear(at: start)
            return
        }
        let revision = captionRevision
        let cueID = UUID()
        let end = start + max(subtitleDuration, 0.1)
        Task { @MainActor [weak self] in
            guard let self,
                  await self.waitForCustomSubtitleTime(start, revision: revision)
            else { return }
            self.activeCustomSubtitleCueID = cueID
            self.bitmapSubtitleCue = nil
            self.captionLines = lines
            guard await self.waitForCustomSubtitleTime(end, revision: revision),
                  self.activeCustomSubtitleCueID == cueID
            else { return }
            self.activeCustomSubtitleCueID = nil
            self.captionLines = []
        }
    }

    private func scheduleCustomBitmapSubtitle(
        _ cue: BunnyFFmpegBitmapSubtitleCue?,
        start: TimeInterval,
        duration subtitleDuration: TimeInterval
    ) {
        guard let cue, !cue.parts.isEmpty, selectedSubtitleID != nil else {
            scheduleCustomSubtitleClear(at: start)
            return
        }
        let revision = captionRevision
        let cueID = UUID()
        let end = start + max(subtitleDuration, 0.1)
        Task { @MainActor [weak self] in
            guard let self,
                  await self.waitForCustomSubtitleTime(start, revision: revision)
            else { return }
            self.activeCustomSubtitleCueID = cueID
            self.captionLines = []
            self.bitmapSubtitleCue = cue
            guard await self.waitForCustomSubtitleTime(end, revision: revision),
                  self.activeCustomSubtitleCueID == cueID
            else { return }
            self.activeCustomSubtitleCueID = nil
            self.bitmapSubtitleCue = nil
        }
    }

    private func scheduleCustomSubtitleClear(at start: TimeInterval) {
        guard start > 0, selectedSubtitleID != nil else {
            invalidateCustomSubtitles()
            return
        }
        let revision = captionRevision
        Task { @MainActor [weak self] in
            guard let self,
                  await self.waitForCustomSubtitleTime(start, revision: revision)
            else { return }
            self.activeCustomSubtitleCueID = nil
            self.captionLines = []
            self.bitmapSubtitleCue = nil
        }
    }

    private func waitForCustomSubtitleTime(
        _ target: TimeInterval,
        revision: Int
    ) async -> Bool {
        while !Task.isCancelled,
              revision == captionRevision,
              selectedSubtitleID != nil,
              customDecoder != nil {
            let clock = customDecoder?.currentTime ?? currentTime
            if clock.isFinite, clock >= target - 0.025 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return false
    }

    private func invalidateCustomSubtitles() {
        captionRevision &+= 1
        activeCustomSubtitleCueID = nil
        captionLines = []
        bitmapSubtitleCue = nil
    }

    private func configurePictureInPicture() {
        pictureInPictureController?.stopPictureInPicture()
        pictureInPictureController = nil
        pictureInPictureSupported = false
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

        let controller: AVPictureInPictureController?
        if activeEngine == .customFFmpeg, let customDecoder {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: customDecoder.videoLayer,
                playbackDelegate: self
            )
            controller = AVPictureInPictureController(contentSource: source)
        } else if let playerLayer {
            controller = AVPictureInPictureController(playerLayer: playerLayer)
        } else {
            controller = nil
        }
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        pictureInPictureController = controller
        pictureInPictureSupported = controller != nil
    }

    private var candidateURLs: [URL] {
        [plan.primaryURL, plan.fallbackURL]
            .compactMap { $0 }
            .reduce(into: []) { result, url in
                if !result.contains(url) { result.append(url) }
            }
    }

    private func configureMediaOptions(asset: AVAsset, item: AVPlayerItem) async {
        let loadedAudioGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
        let loadedSubtitleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)
        guard !Task.isCancelled,
              activeAsset === asset,
              player.currentItem === item
        else { return }
        audioGroup = loadedAudioGroup
        subtitleGroup = loadedSubtitleGroup

        if let audioGroup {
            audioOptions = audioGroup.options.enumerated().map { index, option in
                BunnyMediaOption(index: index, nativeOption: option)
            }
            if let preferred = preferredOption(
                in: audioOptions,
                language: PlaybackLanguagePreferences.preferredAudioLanguage()
            ), let nativeOption = preferred.nativeOption {
                item.select(nativeOption, in: audioGroup)
                selectedAudioID = preferred.id
            } else if let selected = item.currentMediaSelection.selectedMediaOption(in: audioGroup),
               let option = audioOptions.first(where: { $0.nativeOption === selected }) {
                selectedAudioID = option.id
            }
        }

        if let subtitleGroup {
            subtitleOptions = subtitleGroup.options.enumerated().map { index, option in
                BunnyMediaOption(index: index, nativeOption: option)
            }
            if PlaybackLanguagePreferences.subtitlesEnabled(),
               let preferred = preferredOption(
                    in: subtitleOptions,
                    language: PlaybackLanguagePreferences.preferredSubtitleLanguage()
               ), let nativeOption = preferred.nativeOption {
                item.select(nativeOption, in: subtitleGroup)
                selectedSubtitleID = preferred.id
            } else if !PlaybackLanguagePreferences.subtitlesEnabled() {
                item.select(nil, in: subtitleGroup)
                selectedSubtitleID = nil
            } else if let selected = item.currentMediaSelection.selectedMediaOption(in: subtitleGroup),
               let option = subtitleOptions.first(where: { $0.nativeOption === selected }) {
                selectedSubtitleID = option.id
            }
        }
    }

    private func preferredOption(
        in options: [BunnyMediaOption],
        language: String
    ) -> BunnyMediaOption? {
        let languageOptions = options.map {
            PlaybackLanguageOption(
                languageTag: $0.languageTag,
                displayName: $0.title
            )
        }
        guard let index = PlaybackLanguageMatcher.bestMatchIndex(
            in: languageOptions,
            preferredLanguage: language
        ) else { return nil }
        return options[index]
    }

    private func refreshPlaybackState() {
        if activeEngine == .customFFmpeg {
            guard let customDecoder else {
                isPlaying = false
                isBuffering = false
                return
            }
            let decoderTime = customDecoder.currentTime
            if decoderTime.isFinite {
                currentTime = max(decoderTime, 0)
                resumePosition = currentTime
            }
            isPlaying = wantsPlayback && customDecoder.rate > 0
            let videoDecodeStarved = customMediaInfo?.hasVideo == true
                && ProcessInfo.processInfo.systemUptime - customLastDecodedAt > 1.5
            isBuffering = wantsPlayback && !isSeeking && !customEnded
                && (customDecoder.rate <= 0 || videoDecodeStarved)
            isMuted = customDecoder.isMuted
            return
        }
        guard let item = player.currentItem else {
            isPlaying = false
            isBuffering = false
            return
        }
        let itemTime = item.currentTime().seconds
        if itemTime.isFinite {
            currentTime = max(itemTime, 0)
            resumePosition = currentTime
        }
        let itemDuration = item.duration.seconds
        if itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }
        isPlaying = player.timeControlStatus == .playing || player.rate > 0
        isBuffering = wantsPlayback
            && player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        isMuted = player.isMuted
    }

    private func resumePlayback() {
        player.defaultRate = playbackRate
        player.play()
    }

    private func resumePlaybackImmediately() {
        player.defaultRate = playbackRate
        player.playImmediately(atRate: playbackRate)
    }

    private var bufferedSeconds: TimeInterval {
        if activeEngine == .customFFmpeg {
            return customBufferedSeconds
        }
        guard let item = player.currentItem else { return 0 }
        let position = item.currentTime().seconds
        guard position.isFinite else { return 0 }
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = range.end.seconds
            guard start.isFinite, end.isFinite else { continue }
            if position >= start - 0.05, position <= end + 0.05 {
                return max(end - position, 0)
            }
        }
        return 0
    }

    private func makeDebugSnapshot() -> BunnyDebugSnapshot {
        if activeEngine == .customFFmpeg {
            return BunnyDebugSnapshot(
                state: isSeeking ? "Seeking" : isBuffering ? "Buffering" : isPlaying ? "Playing" : "Paused",
                displayFPS: customDisplayFPS,
                droppedFrames: customDroppedFrames,
                stalls: stallCount,
                bufferSeconds: customBufferedSeconds,
                decoder: customDecoder?.hardwareVideoDecode == true
                    ? "FFmpeg · VideoToolbox"
                    : "FFmpeg · Software"
            )
        }
        guard let item = player.currentItem else { return .waiting }
        let event = item.accessLog()?.events.last
        let frameRate = item.tracks
            .map { Double($0.currentVideoFrameRate) }
            .filter { $0 > 0 }
            .max()
        #if targetEnvironment(simulator)
        let nativeDecoderLabel = "Apple · Simulator"
        #else
        let nativeDecoderLabel = "Apple · VideoToolbox"
        #endif
        return BunnyDebugSnapshot(
            state: isSeeking ? "Seeking" : isBuffering ? "Buffering" : isPlaying ? "Playing" : "Paused",
            displayFPS: frameRate,
            droppedFrames: event.map { max($0.numberOfDroppedVideoFrames, 0) },
            stalls: max(stallCount, event.map { max($0.numberOfStalls, 0) } ?? 0),
            bufferSeconds: bufferedSeconds,
            decoder: nativeDecoderLabel
        )
    }

    private var debugOverlayEnabled: Bool {
        UserDefaults.standard.bool(forKey: "playerDebugOverlayEnabled")
            || ProcessInfo.processInfo.environment["SKELETON_PLAYER_DEBUG_OVERLAY"] == "1"
    }
}

extension BunnyPlaybackModel: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        guard playing != wantsPlayback else { return }
        togglePlayback()
        pictureInPictureController.invalidatePlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        guard duration > 0 else {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
        return CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        !wantsPlayback
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime
    ) async {
        _ = await seek(by: skipInterval.seconds)
        pictureInPictureController.invalidatePlaybackState()
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }
}

@MainActor
private struct BunnyMediaOption: Identifiable {
    let id = UUID()
    let title: String
    let detail: String?
    let languageTag: String?
    let source: BunnyMediaSource

    init(index: Int, nativeOption: AVMediaSelectionOption) {
        source = .native(nativeOption)
        title = nativeOption.displayName.isEmpty
            ? "Track \(index + 1)"
            : nativeOption.displayName
        languageTag = nativeOption.extendedLanguageTag
            ?? nativeOption.locale?.identifier
        detail = languageTag
    }

    init(track: BunnyFFmpegTrack) {
        source = .custom(track.streamIndex)
        title = track.title
        languageTag = track.language
        detail = [track.language, track.codecName.uppercased()]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    var nativeOption: AVMediaSelectionOption? {
        guard case let .native(option) = source else { return nil }
        return option
    }

    var customStreamIndex: Int? {
        guard case let .custom(streamIndex) = source else { return nil }
        return streamIndex
    }
}

@MainActor
private enum BunnyMediaSource {
    case native(AVMediaSelectionOption)
    case custom(Int)
}

private enum BunnyPlaybackRate {
    static let supported: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    static func label(for rate: Float) -> String {
        rate == rate.rounded()
            ? String(format: "%.0fx", Double(rate))
            : String(format: "%gx", Double(rate))
    }
}

private final class BunnyCaptionDelegate: NSObject,
    AVPlayerItemLegibleOutputPushDelegate,
    @unchecked Sendable {
    weak var model: BunnyPlaybackModel?

    nonisolated func legibleOutput(
        _ output: AVPlayerItemLegibleOutput,
        didOutputAttributedStrings strings: [NSAttributedString],
        nativeSampleBuffers nativeSamples: [Any],
        forItemTime itemTime: CMTime
    ) {
        let lines = strings.map(\.string)
        Task { @MainActor [weak model] in
            model?.updateCaptionLines(lines)
        }
    }

    nonisolated func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) {
        Task { @MainActor [weak model] in
            model?.updateCaptionLines([])
        }
    }
}

private enum BunnyViewportMode: String {
    case fit
    case fill

    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fit: .resizeAspect
        case .fill: .resizeAspectFill
        }
    }

    var notice: String {
        switch self {
        case .fit: "Fit to screen"
        case .fill: "Filled screen"
        }
    }

    var buttonSymbol: String {
        switch self {
        case .fit: "arrow.up.left.and.arrow.down.right"
        case .fill: "arrow.down.right.and.arrow.up.left"
        }
    }

    var buttonLabel: String {
        switch self {
        case .fit: "Fill screen"
        case .fill: "Fit video"
        }
    }
}

private final class BunnyPlayerLayerView: UIView {
    let playerLayer = AVPlayerLayer()
    private weak var customLayer: AVSampleBufferDisplayLayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.addSublayer(playerLayer)
        playerLayer.backgroundColor = UIColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        customLayer?.frame = bounds
        CATransaction.commit()
    }

    func update(
        player: AVPlayer,
        customVideoLayer: AVSampleBufferDisplayLayer?,
        usesCustomDecoder: Bool,
        videoGravity: AVLayerVideoGravity
    ) {
        if playerLayer.player !== player {
            playerLayer.player = player
        }
        if customLayer !== customVideoLayer {
            customLayer?.removeFromSuperlayer()
            customLayer = customVideoLayer
            if let customVideoLayer {
                layer.addSublayer(customVideoLayer)
            }
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        playerLayer.videoGravity = videoGravity
        customLayer?.videoGravity = videoGravity
        playerLayer.isHidden = usesCustomDecoder
        customLayer?.isHidden = !usesCustomDecoder
        playerLayer.frame = bounds
        customLayer?.frame = bounds
        CATransaction.commit()
    }
}

private struct BunnyVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    let customVideoLayer: AVSampleBufferDisplayLayer?
    let usesCustomDecoder: Bool
    let viewportMode: BunnyViewportMode
    let onLayerReady: @MainActor (AVPlayerLayer) -> Void

    func makeUIView(context: Context) -> BunnyPlayerLayerView {
        let view = BunnyPlayerLayerView()
        view.update(
            player: player,
            customVideoLayer: customVideoLayer,
            usesCustomDecoder: usesCustomDecoder,
            videoGravity: viewportMode.videoGravity
        )
        // Attaching PiP publishes capability state. Defer it until SwiftUI has
        // finished this representable update so it cannot create a render loop.
        Task { @MainActor [weak view] in
            await Task.yield()
            guard let view else { return }
            onLayerReady(view.playerLayer)
        }
        return view
    }

    func updateUIView(_ view: BunnyPlayerLayerView, context: Context) {
        view.update(
            player: player,
            customVideoLayer: customVideoLayer,
            usesCustomDecoder: usesCustomDecoder,
            videoGravity: viewportMode.videoGravity
        )
    }
}

private struct BunnyControlsOverlay: View {
    @ObservedObject var model: BunnyPlaybackModel
    let title: String
    let viewportSize: CGSize
    @Binding var viewportMode: BunnyViewportMode
    @Binding var trackPickerPresented: Bool
    let close: @MainActor @Sendable () -> Void
    let rotate: @MainActor @Sendable () -> Void
    let onInteraction: @MainActor @Sendable () -> Void
    let onViewportChange: @MainActor @Sendable (BunnyViewportMode) -> Void
    let onSeekFailure: @MainActor @Sendable () -> Void
    @State private var activeTrackPicker: BunnyTrackPickerKind?
    @State private var trackPickerOptions: [BunnyMediaOption] = []

    private var isPortrait: Bool { viewportSize.height > viewportSize.width }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.74), .clear, .black.opacity(0.84)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: isPortrait ? 10 : 12) {
                topControls
                Spacer(minLength: isPortrait ? 10 : 18)
                centerControls
                Spacer(minLength: isPortrait ? 10 : 18)
                bottomControls
            }
            .padding(.horizontal, isPortrait ? 14 : 20)
            .padding(.top, isPortrait ? 10 : 12)
            .padding(.bottom, isPortrait ? 12 : 16)

            if let activeTrackPicker {
                trackPickerPanel(activeTrackPicker)
                    .zIndex(2)
            }
        }
        .tint(.white)
        .buttonStyle(BunnyOverlayButtonStyle())
        .accessibilityIdentifier("player-controls")
        .onChange(of: trackPickerPresented) { isPresented in
            if !isPresented {
                activeTrackPicker = nil
                trackPickerOptions = []
            }
        }
        .task {
            await runTrackPickerAuditIfRequested()
        }
    }

    private var topControls: some View {
        HStack(spacing: isPortrait ? 7 : 10) {
            overlayButton(
                "xmark",
                label: "Close player",
                identifier: "player-close",
                action: close
            )

            if !isPortrait {
                Label("Bunny", systemImage: "hare.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.5), in: Capsule())
                    .accessibilityIdentifier("bunny-player-badge")
            }

            Spacer(minLength: 4)

            overlayButton(
                "waveform",
                label: "Audio tracks",
                identifier: "player-audio-tracks"
            ) {
                presentTrackPicker(.audio)
            }
            overlayButton(
                "captions.bubble",
                label: "Subtitles",
                identifier: "player-subtitles"
            ) {
                presentTrackPicker(.subtitles)
            }
            overlayButton(
                model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                label: model.isMuted ? "Unmute" : "Mute",
                action: model.toggleMute
            )
            overlayButton(
                "pip",
                label: "Picture in Picture",
                identifier: "player-pip",
                disabled: !model.pictureInPictureSupported,
                action: model.togglePictureInPicture
            )
            overlayButton(
                "rectangle.landscape.rotate",
                label: "Rotate player",
                identifier: "player-orientation-toggle",
                action: rotate
            )
        }
    }

    private func trackPickerPanel(_ kind: BunnyTrackPickerKind) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Label(kind.title, systemImage: kind.systemImage)
                        .font(.headline)
                    Spacer(minLength: 8)
                    Button {
                        dismissTrackPicker()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.bold())
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close \(kind.title.lowercased())")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider().overlay(.white.opacity(0.12))

                ScrollView {
                    LazyVStack(spacing: 2) {
                        if kind == .subtitles {
                            trackPickerRow(
                                title: "Off",
                                detail: nil,
                                isSelected: model.selectedSubtitleID == nil,
                                systemImage: "captions.bubble"
                            ) {
                                onInteraction()
                                model.selectSubtitle(nil)
                                dismissTrackPicker()
                            }
                        }

                        ForEach(trackPickerOptions) { option in
                            trackPickerRow(
                                title: option.title,
                                detail: option.detail,
                                isSelected: kind == .audio
                                    ? model.selectedAudioID == option.id
                                    : model.selectedSubtitleID == option.id,
                                systemImage: kind.systemImage
                            ) {
                                onInteraction()
                                if kind == .audio {
                                    model.selectAudio(option)
                                } else {
                                    model.selectSubtitle(option)
                                }
                                dismissTrackPicker()
                            }
                            .accessibilityIdentifier(
                                "bunny-\(kind.rawValue)-track-\(option.id.uuidString)"
                            )
                        }

                        if trackPickerOptions.isEmpty, kind == .audio {
                            Text("Default audio")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                        } else if trackPickerOptions.isEmpty, kind == .subtitles {
                            Text("No embedded subtitles")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(
                width: min(340, max(proxy.size.width - 32, 220)),
                height: min(max(proxy.size.height - 96, 150), 390)
            )
            .foregroundStyle(.white)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .accessibilityIdentifier("bunny-\(kind.rawValue)-track-picker")
        }
    }

    private func trackPickerRow(
        title: String,
        detail: String?,
        isSelected: Bool,
        systemImage: String,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: isSelected ? "checkmark" : systemImage)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lineLimit(2)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
            }
            .font(.subheadline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func presentTrackPicker(_ kind: BunnyTrackPickerKind) {
        if activeTrackPicker == kind {
            dismissTrackPicker()
            return
        }
        trackPickerOptions = kind == .audio
            ? model.audioOptions
            : model.subtitleOptions
        activeTrackPicker = kind
        trackPickerPresented = true
        onInteraction()
        NSLog(
            "BUNNY_TRACK_PICKER opened kind=%@ tracks=%ld",
            kind.rawValue,
            trackPickerOptions.count
        )
    }

    @MainActor
    private func dismissTrackPicker() {
        activeTrackPicker = nil
        trackPickerOptions = []
        trackPickerPresented = false
        onInteraction()
    }

    @MainActor
    private func runTrackPickerAuditIfRequested() async {
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment[
            "SKELETON_PLAYER_TRACK_SWITCH_AUDIT"
        ] == "1" else { return }

        for _ in 0..<120 {
            if model.audioOptions.count > 1, !model.subtitleOptions.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
        }
        guard model.audioOptions.count > 1 else {
            NSLog("BUNNY_TRACK_PICKER FAIL reason=missing-audio-tracks")
            return
        }

        let originalAudioID = model.selectedAudioID
        let originalSubtitleID = model.selectedSubtitleID
        let audioStart = model.currentTime
        presentTrackPicker(.audio)
        try? await Task.sleep(for: .seconds(3))
        guard activeTrackPicker == .audio, trackPickerPresented else {
            NSLog("BUNNY_TRACK_PICKER FAIL reason=audio-picker-dismissed")
            return
        }
        let audioPickerAdvanced = model.currentTime >= audioStart + 1
        NSLog(
            "BUNNY_TRACK_PICKER stable kind=audio playback_advanced=%@",
            audioPickerAdvanced ? "yes" : "no"
        )

        if let alternative = model.audioOptions.first(where: {
            $0.id != originalAudioID
        }) {
            model.selectAudio(alternative)
        }
        dismissTrackPicker()
        try? await Task.sleep(for: .seconds(4))
        guard model.failureMessage == nil else {
            NSLog("BUNNY_TRACK_PICKER FAIL reason=audio-switch-failed")
            return
        }

        presentTrackPicker(.subtitles)
        try? await Task.sleep(for: .seconds(3))
        guard activeTrackPicker == .subtitles, trackPickerPresented else {
            NSLog("BUNNY_TRACK_PICKER FAIL reason=subtitle-picker-dismissed")
            return
        }
        NSLog("BUNNY_TRACK_PICKER stable kind=subtitles")
        dismissTrackPicker()

        if let originalAudioID,
           let original = model.audioOptions.first(where: { $0.id == originalAudioID }) {
            model.selectAudio(original)
        }
        if let originalSubtitleID,
           let original = model.subtitleOptions.first(where: {
               $0.id == originalSubtitleID
           }) {
            model.selectSubtitle(original)
        } else {
            model.selectSubtitle(nil)
        }
        try? await Task.sleep(for: .seconds(3))
        let passed = audioPickerAdvanced && model.failureMessage == nil && model.isPlaying
        NSLog(
            "BUNNY_TRACK_PICKER %@ audio_switch=realigned subtitle_picker=stable",
            passed ? "PASS" : "FAIL"
        )
        #endif
    }

    private var centerControls: some View {
        HStack(spacing: isPortrait ? 34 : 48) {
            centerButton("gobackward.15", label: "Back 15 seconds") {
                seek(by: -15)
            }
            centerButton(
                model.wantsPlayback ? "pause.fill" : "play.fill",
                label: model.wantsPlayback ? "Pause" : "Play",
                prominent: true
            ) {
                model.togglePlayback()
            }
            centerButton("goforward.15", label: "Forward 15 seconds") {
                seek(by: 15)
            }
        }
    }

    private var bottomControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                if model.isBuffering || model.isSeeking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .accessibilityLabel(model.isSeeking ? "Seeking" : "Buffering")
                }
                Spacer(minLength: 8)
                BunnyPlaybackRateMenu(model: model, onInteraction: onInteraction)
                overlayButton(
                    viewportMode.buttonSymbol,
                    label: viewportMode.buttonLabel,
                    identifier: "player-content-mode"
                ) {
                    let next: BunnyViewportMode = viewportMode == .fit ? .fill : .fit
                    onViewportChange(next)
                }
            }

            BunnyTimeline(
                model: model,
                onInteraction: onInteraction,
                onSeekFailure: onSeekFailure
            )
        }
    }

    private func seek(by interval: TimeInterval) {
        onInteraction()
        Task { @MainActor in
            if !(await model.seek(by: interval)) {
                onSeekFailure()
            }
        }
    }

    @ViewBuilder
    private func overlayButton(
        _ systemName: String,
        label: String,
        identifier: String? = nil,
        disabled: Bool = false,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> some View {
        Button {
            onInteraction()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: isPortrait ? 16 : 17, weight: .semibold))
        }
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier ?? "bunny-\(label)")
    }

    private func centerButton(
        _ systemName: String,
        label: String,
        prominent: Bool = false,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> some View {
        Button {
            onInteraction()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: prominent ? 27 : 23, weight: .semibold))
                .frame(
                    width: prominent ? (isPortrait ? 54 : 60) : (isPortrait ? 46 : 50),
                    height: prominent ? (isPortrait ? 54 : 60) : (isPortrait ? 46 : 50)
                )
                .background(.black.opacity(0.58), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private enum BunnyTrackPickerKind: String {
    case audio
    case subtitles

    var title: String {
        switch self {
        case .audio: "Audio"
        case .subtitles: "Subtitles"
        }
    }

    var systemImage: String {
        switch self {
        case .audio: "waveform"
        case .subtitles: "captions.bubble"
        }
    }
}

private struct BunnyTimeline: View {
    @ObservedObject var model: BunnyPlaybackModel
    let onInteraction: () -> Void
    let onSeekFailure: () -> Void
    @State private var scrubPosition = 0.0
    @State private var isEditing = false
    @State private var shouldResumeAfterScrub = false

    var body: some View {
        HStack(spacing: 8) {
            Text(formatted(isEditing ? scrubPosition : model.currentTime))
            Slider(
                value: Binding(
                    get: { isEditing ? scrubPosition : min(model.currentTime, upperBound) },
                    set: { scrubPosition = $0 }
                ),
                in: 0...upperBound,
                onEditingChanged: editingChanged
            )
            .tint(Color.appAccent)
            .disabled(model.duration <= 0 || model.isPreparing)
            .accessibilityIdentifier("player-timeline")
            Text(formatted(model.duration))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white.opacity(0.92))
    }

    private var upperBound: TimeInterval {
        max(model.duration, 1)
    }

    private func editingChanged(_ editing: Bool) {
        onInteraction()
        if editing {
            guard !isEditing else { return }
            isEditing = true
            scrubPosition = model.currentTime
            shouldResumeAfterScrub = model.pauseForScrubbing()
        } else {
            guard isEditing else { return }
            let target = scrubPosition
            let shouldResume = shouldResumeAfterScrub
            isEditing = false
            Task { @MainActor in
                if !(await model.finishScrubbing(to: target, resume: shouldResume)) {
                    onSeekFailure()
                }
            }
        }
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "--:--" }
        let clamped = max(Int(seconds.rounded(.down)), 0)
        let hours = clamped / 3_600
        let minutes = (clamped % 3_600) / 60
        let remainingSeconds = clamped % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
            : String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}

private struct BunnyPlaybackRateMenu: View {
    @ObservedObject var model: BunnyPlaybackModel
    let onInteraction: () -> Void

    var body: some View {
        Menu {
            ForEach(BunnyPlaybackRate.supported, id: \.self) { rate in
                Button {
                    onInteraction()
                    model.selectPlaybackRate(rate)
                } label: {
                    Label(
                        BunnyPlaybackRate.label(for: rate),
                        systemImage: model.playbackRate == rate ? "checkmark" : "speedometer"
                    )
                }
            }
        } label: {
            Text(BunnyPlaybackRate.label(for: model.playbackRate))
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(Color.white)
                .frame(width: 42, height: 42)
                .background(.black.opacity(0.68), in: Circle())
        }
        .simultaneousGesture(TapGesture().onEnded(onInteraction))
        .accessibilityLabel("Playback speed, \(BunnyPlaybackRate.label(for: model.playbackRate))")
        .accessibilityIdentifier("player-playback-speed")
    }
}

private struct BunnyBitmapSubtitleOverlay: View {
    let cue: BunnyFFmpegBitmapSubtitleCue
    let presentationSize: CGSize
    let viewportMode: BunnyViewportMode

    var body: some View {
        GeometryReader { proxy in
            let videoFrame = displayedVideoFrame(in: proxy.size)
            let sourceSize = cue.sourceSize
            let sourceWidth = max(sourceSize.width, 1)
            let sourceHeight = max(sourceSize.height, 1)

            ZStack(alignment: .topLeading) {
                ForEach(Array(cue.parts.enumerated()), id: \.offset) { _, part in
                    let sourceRect = part.sourceRect
                    let width = sourceRect.width / sourceWidth * videoFrame.width
                    let height = sourceRect.height / sourceHeight * videoFrame.height
                    let x = videoFrame.minX
                        + sourceRect.midX / sourceWidth * videoFrame.width
                    let y = videoFrame.minY
                        + sourceRect.midY / sourceHeight * videoFrame.height

                    Image(uiImage: part.image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: max(width, 0), height: max(height, 0))
                        .position(x: x, y: y)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Image subtitles")
            .accessibilityIdentifier("player-bitmap-subtitle-overlay")
        }
        .allowsHitTesting(false)
    }

    private func displayedVideoFrame(in viewport: CGSize) -> CGRect {
        let fallbackSize = cue.sourceSize
        let contentSize = presentationSize.width > 0 && presentationSize.height > 0
            ? presentationSize
            : fallbackSize
        guard viewport.width > 0,
              viewport.height > 0,
              contentSize.width > 0,
              contentSize.height > 0,
              cue.sourceSize.width > 0,
              cue.sourceSize.height > 0
        else { return .zero }

        let widthScale = viewport.width / contentSize.width
        let heightScale = viewport.height / contentSize.height
        let scale = viewportMode == .fit
            ? min(widthScale, heightScale)
            : max(widthScale, heightScale)
        let displayedSize = CGSize(
            width: contentSize.width * scale,
            height: contentSize.height * scale
        )
        return CGRect(
            x: (viewport.width - displayedSize.width) / 2,
            y: (viewport.height - displayedSize.height) / 2,
            width: displayedSize.width,
            height: displayedSize.height
        )
    }
}

private struct BunnySubtitleOverlay: View {
    let lines: [String]
    @SubtitleStyleStorage private var subtitleStyle
    @State private var anchor = SubtitlePlacement.defaultPosition
    @GestureState private var translation = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            let displayedAnchor = constrained(
                anchor.translated(
                    x: Double(translation.width),
                    y: Double(translation.height),
                    viewportWidth: Double(proxy.size.width),
                    viewportHeight: Double(proxy.size.height)
                ),
                viewport: proxy.size
            )

            VStack(spacing: 5) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    StyledSubtitleText(line, style: subtitleStyle)
                }
            }
            .frame(maxWidth: max(proxy.size.width - 48, 1))
            .contentShape(Rectangle())
            .position(
                x: proxy.size.width * displayedAnchor.horizontal,
                y: proxy.size.height * displayedAnchor.vertical
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($translation) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        anchor = constrained(
                            anchor.translated(
                                x: Double(value.translation.width),
                                y: Double(value.translation.height),
                                viewportWidth: Double(proxy.size.width),
                                viewportHeight: Double(proxy.size.height)
                            ),
                            viewport: proxy.size
                        )
                    }
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Draggable subtitles")
            .accessibilityIdentifier("player-subtitle-overlay")
        }
        .allowsHitTesting(!lines.isEmpty)
        .accessibilityHidden(lines.isEmpty)
    }

    private func constrained(
        _ placement: SubtitlePlacement,
        viewport: CGSize
    ) -> SubtitlePlacement {
        let contentSize = estimatedContentSize(
            maximumWidth: max(viewport.width - 48, 1)
        )
        return placement.constrained(
            contentWidth: Double(contentSize.width),
            contentHeight: Double(contentSize.height),
            viewportWidth: Double(viewport.width),
            viewportHeight: Double(viewport.height)
        )
    }

    private func estimatedContentSize(maximumWidth: CGFloat) -> CGSize {
        let font = subtitleStyle.uiFont
        let horizontalPadding = SubtitleVisualStyle.horizontalPadding * 2
        let verticalPadding = SubtitleVisualStyle.verticalPadding * 2
        var width: CGFloat = 0
        var height: CGFloat = 0
        for line in lines {
            let bounds = (line as NSString).boundingRect(
                with: CGSize(
                    width: max(maximumWidth - horizontalPadding, 1),
                    height: .greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )
            width = max(
                width,
                min(ceil(bounds.width) + horizontalPadding, maximumWidth)
            )
            height += ceil(bounds.height) + verticalPadding
        }
        if lines.count > 1 {
            height += CGFloat(lines.count - 1) * 5
        }
        return CGSize(width: width, height: height)
    }
}

private struct BunnyDebugSnapshot: Equatable {
    var state: String
    var displayFPS: Double?
    var droppedFrames: Int?
    var stalls: Int?
    var bufferSeconds: Double?
    var decoder: String

    static let waiting = Self(
        state: "Starting",
        displayFPS: nil,
        droppedFrames: nil,
        stalls: nil,
        bufferSeconds: nil,
        decoder: "Starting"
    )

    var logDescription: String {
        "engine=Bunny state=\(state.lowercased()) fps=\(number(displayFPS)) "
            + "dropped_frames=\(integer(droppedFrames)) stalls=\(integer(stalls)) "
            + "buffer_seconds=\(number(bufferSeconds)) decoder=\(decoder.replacingOccurrences(of: " ", with: "_"))"
    }

    private func number(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "unknown"
    }

    private func integer(_ value: Int?) -> String {
        value.map(String.init) ?? "unknown"
    }
}

private struct BunnyDebugOverlay: View {
    let snapshot: BunnyDebugSnapshot

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 7, height: 7)
                    Label("Bunny", systemImage: "hare.fill")
                        .fontWeight(.semibold)
                    Text(snapshot.state.uppercased())
                        .foregroundStyle(.secondary)
                }
                metric("FPS", value: number(snapshot.displayFPS))
                metric(
                    "Dropped",
                    value: integer(snapshot.droppedFrames),
                    warning: (snapshot.droppedFrames ?? 0) > 0
                )
                metric("Stalls", value: integer(snapshot.stalls))
                metric(
                    "Buffer",
                    value: snapshot.bufferSeconds.map { String(format: "%.1f s", $0) } ?? "--"
                )
                metric("Decode", value: snapshot.decoder)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(width: min(max(proxy.size.width * 0.46, 178), 250), alignment: .leading)
            .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        (snapshot.droppedFrames ?? 0) > 0
                            ? Color.orange.opacity(0.9)
                            : Color.white.opacity(0.18)
                    )
            }
            .padding(.leading, 12)
            .padding(.top, 58)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Player debug, Bunny, \(snapshot.state), "
                + "\(integer(snapshot.droppedFrames)) dropped frames"
        )
        .accessibilityIdentifier("player-debug-overlay")
    }

    private var stateColor: Color {
        switch snapshot.state {
        case "Playing": .green
        case "Buffering", "Seeking", "Starting": .orange
        default: .secondary
        }
    }

    private func metric(_ title: String, value: String, warning: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(warning ? Color.orange : Color.white)
        }
    }

    private func number(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "--"
    }

    private func integer(_ value: Int?) -> String {
        value.map(String.init) ?? "--"
    }
}

private struct BunnyToast: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "hare.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background(.black.opacity(0.76), in: Capsule())
            .allowsHitTesting(false)
            .accessibilityIdentifier("bunny-player-toast")
    }
}

private struct BunnyOverlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 42, height: 42)
            .background(.black.opacity(configuration.isPressed ? 0.82 : 0.58), in: Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

@MainActor
private enum BunnyPresentation {
    static func prepareAudioSession() {
        PlaybackAudioSession.beginPlayback()
    }

    static func endAudioSession() {
        PlaybackAudioSession.endPlayback()
    }

    static func toggleOrientation() {
        guard let scene = foregroundScene else { return }
        let orientation = scene.effectiveGeometry.interfaceOrientation
        let target: UIInterfaceOrientationMask = orientation.isLandscape
            ? .portrait
            : .landscape

        AppOrientationDelegate.supportedOrientations = target
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { error in
            NSLog("Bunny orientation update failed: %@", error.localizedDescription)
        }
    }

    /// Idempotent simulator-verification entry point. Re-applying it for an
    /// automatically presented episode keeps landscape instead of toggling
    /// an already-landscape player back to portrait.
    static func ensureLandscape() {
        guard let scene = foregroundScene else { return }
        let target = UIInterfaceOrientationMask.landscape
        AppOrientationDelegate.supportedOrientations = target
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        guard !scene.effectiveGeometry.interfaceOrientation.isLandscape else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { error in
            NSLog("Bunny landscape verification failed: %@", error.localizedDescription)
        }
    }

    private static var foregroundScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}

private enum BunnyPlaybackError: LocalizedError {
    case noPlayableCandidate
    case assetNotPlayable
    case noMediaTracks
    case noVisibleFrame
    case startupTimedOut(TimeInterval)
    case playbackStalled
    case seekFailed
    case unexpectedShortVideo(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .noPlayableCandidate:
            "Bunny could not open this source with either of its decoder paths."
        case .assetNotPlayable:
            "AVFoundation could not open this source."
        case .noMediaTracks:
            "The source did not contain playable audio or video tracks."
        case .noVisibleFrame:
            "The stream started, but Bunny did not receive a visible video frame."
        case let .startupTimedOut(timeout):
            "The stream did not start within \(Int(timeout.rounded())) seconds."
        case .playbackStalled:
            "The stream stopped advancing for 15 seconds after Bunny tried to recover it."
        case .seekFailed:
            "Bunny opened the stream, but its decoder could not restore the requested position."
        case let .unexpectedShortVideo(duration):
            "The source returned only \(Int(duration.rounded())) seconds of media."
        }
    }
}
