import AVKit
import SwiftUI
import UIKit
#if canImport(KSPlayer)
@preconcurrency import KSPlayer
#endif

@MainActor
final class AppOrientationDelegate: NSObject, UIApplicationDelegate {
    static var supportedOrientations: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.supportedOrientations
    }
}

@MainActor
private enum PlayerPresentation {
    static func prepareAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // Playback can still proceed without background audio; the active
            // player engine will report a media error if it is unavailable.
        }
    }

    static func endAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
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
            NSLog("Player orientation update failed: %@", error.localizedDescription)
        }
    }

    static func restorePortrait() {
        AppOrientationDelegate.supportedOrientations = .portrait
        guard let scene = foregroundScene else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        guard scene.effectiveGeometry.interfaceOrientation.isLandscape else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { error in
            NSLog("Player portrait restore failed: %@", error.localizedDescription)
        }
    }

    private static var foregroundScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}

private struct PlayerOrientationButton: View {
    var body: some View {
        Button {
            PlayerPresentation.toggleOrientation()
        } label: {
            Image(systemName: "rectangle.landscape.rotate")
        }
        .accessibilityLabel("Rotate player")
        .accessibilityHint("Switches between portrait and landscape")
        .accessibilityIdentifier("player-orientation-toggle")
    }
}

#if canImport(KSPlayer)
/// App-owned playback coordinator. The UI is ours and the bundled FFmpeg
/// backend is selected deterministically so a failed link is never hidden by
/// an automatic engine or source switch.
struct PlayerScreen: View {
    let title: String
    private let plan: PlaybackPlan
    private let minimumVideoDuration: TimeInterval
    private let onExhausted: (@MainActor (Error) -> Void)?
    @State private var attemptRevision = 0
    @State private var failureMessage: String?

    init(
        plan: PlaybackPlan,
        title: String,
        minimumVideoDuration: TimeInterval = 4,
        onExhausted: (@MainActor (Error) -> Void)? = nil
    ) {
        self.plan = plan
        self.title = title
        self.minimumVideoDuration = minimumVideoDuration
        self.onExhausted = onExhausted
    }

    init(url: URL, title: String) {
        self.init(
            plan: PlaybackPlan(
                primaryURL: url,
                fallbackURL: nil,
                usesCompatibilityPlayback: false
            ),
            title: title
        )
    }

    private struct Candidate: Hashable {
        let url: URL
        let engine: StremioPlayerConfiguration.Engine
    }

    private var candidate: Candidate {
        Candidate(url: plan.primaryURL, engine: .ffmpeg)
    }

    var body: some View {
        ZStack {
            if failureMessage == nil {
                KSPlaybackAttempt(
                    url: candidate.url,
                    engine: candidate.engine,
                    title: title,
                    minimumVideoDuration: minimumVideoDuration,
                    initialPosition: 0,
                    onFailure: advanceOrFail
                )
                .id("\(candidate.engine.rawValue)-\(attemptRevision)")
                .accessibilityIdentifier("stremio-player")
            }

            if let failureMessage {
                playbackFailure(message: failureMessage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { PlayerPresentation.prepareAudioSession() }
        .onDisappear {
            PlayerPresentation.endAudioSession()
            PlayerPresentation.restorePortrait()
        }
    }

    @ViewBuilder
    private func playbackFailure(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "play.slash")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Playback unavailable").font(.title3.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                failureMessage = nil
                attemptRevision += 1
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(28)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 22))
        .padding()
        .accessibilityIdentifier("player-error")
    }

    @MainActor
    private func advanceOrFail(_ error: Error) {
        if let onExhausted {
            onExhausted(error)
        } else {
            failureMessage = "KSPlayer could not decode this source (\(error.localizedDescription)). Try another stream."
        }
    }
}

private struct KSPlaybackAttempt: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let engine: StremioPlayerConfiguration.Engine
    let title: String
    let minimumVideoDuration: TimeInterval
    let initialPosition: TimeInterval
    let onFailure: @MainActor (Error) -> Void
    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    @State private var startupStartedAt = ProcessInfo.processInfo.systemUptime
    @State private var didRecordStartup = false
    @State private var didProduceMedia = false
    @State private var didProduceVideoFrame = false
    @State private var didReportFailure = false
    @State private var isAudioOnly = false
    @State private var wantsPlayback = true
    @State private var playerState = KSPlayerState.initialized
    @State private var didRestorePosition = false

    private let options: KSOptions

    init(
        url: URL,
        engine: StremioPlayerConfiguration.Engine,
        title: String,
        minimumVideoDuration: TimeInterval,
        initialPosition: TimeInterval,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        self.url = url
        self.engine = engine
        self.title = title
        self.minimumVideoDuration = minimumVideoDuration
        self.initialPosition = initialPosition
        self.onFailure = onFailure

        self.options = StremioPlayerConfiguration.makeOptions(engine: engine)
    }

    var body: some View {
        ZStack {
            KSVideoPlayer(coordinator: coordinator, url: url, options: options)
                .onStateChanged { _, state in
                    playerState = state
                    if state == .bufferFinished {
                        didProduceMedia = true
                        // KSPlayer hides its mask immediately after invoking this
                        // callback. Re-apply our policy on the next main-loop turn.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(50))
                            coordinator.mask(
                                show: true,
                                autoHide: !keepsControlsVisibleForVerification
                            )
                        }
                    } else if state == .error {
                        reportFailure(PlayerAttemptError.playerError)
                    }
                }
                .onPlay { currentTime, totalTime in
                    let hasVideo = !(coordinator.playerLayer?.player
                        .tracks(mediaType: .video).isEmpty ?? true)
                    if !hasVideo && (currentTime > 0 || totalTime > 1) {
                        didProduceMedia = true
                        recordStartupIfNeeded(currentTime: currentTime)
                    }
                }
                .onFinish { _, error in
                    if let error {
                        reportFailure(error)
                    }
                }
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    coordinator.mask(show: !coordinator.isMaskShow)
                }

            if !coordinator.isMaskShow {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        coordinator.mask(show: true)
                    }
                    .accessibilityLabel("Show player controls")
                    .accessibilityIdentifier("player-show-controls")
            }

            PlayerSubtitleOverlay(model: coordinator.subtitleModel)
                .allowsHitTesting(false)

            if isAudioOnly, didProduceMedia {
                VStack(spacing: 14) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 68))
                        .foregroundStyle(.orange)
                    Text("Audio playback")
                        .font(.headline)
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("audio-playback-status")
            }

            if !didProduceMedia, !didReportFailure {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.orange)
                    Text(engine == .native ? "Starting video…" : "Trying compatibility player…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("player-startup-status")
            }

            if coordinator.isMaskShow {
                PlayerControlsOverlay(
                    coordinator: coordinator,
                    state: playerState,
                    title: title,
                    wantsPlayback: $wantsPlayback,
                    onSeekFailure: { position in
                        reportFailure(PlayerAttemptError.seekRecoveryTimedOut(engine, position))
                    },
                    close: { dismiss() }
                )
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .animation(.easeOut(duration: 0.18), value: coordinator.isMaskShow)
        .onAppear {
            startupStartedAt = ProcessInfo.processInfo.systemUptime
            didRecordStartup = false
            didProduceMedia = false
            didProduceVideoFrame = false
            didReportFailure = false
            isAudioOnly = false
            wantsPlayback = true
            playerState = .initialized
            didRestorePosition = initialPosition <= 0
            coordinator.isScaleAspectFill = false
            coordinator.isMaskShow = true
            if startsLandscapeForVerification {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    PlayerPresentation.toggleOrientation()
                }
            }
        }
        .task(id: "\(engine.rawValue)|\(url.absoluteString)") {
            var lastPlaybackTime = 0.0
            var lastProgressAt = ProcessInfo.processInfo.systemUptime
            var playableWithoutProgressSince: TimeInterval?
            var videoWithoutFrameSince: TimeInterval?
            let startedAt = ProcessInfo.processInfo.systemUptime

            while !Task.isCancelled, !didReportFailure {
                try? await Task.sleep(for: .milliseconds(250))
                guard let layer = coordinator.playerLayer else { continue }

                let player = layer.player
                let now = ProcessInfo.processInfo.systemUptime
                let hasVideo = !player.tracks(mediaType: .video).isEmpty
                let hasAudio = !player.tracks(mediaType: .audio).isEmpty
                let currentTime = hasVideo
                    ? ((player as? KSMEPlayer)?.displayedVideoTime
                        ?? player.currentPlaybackTime)
                    : player.currentPlaybackTime
                let frameVisible = hasVideo
                    && StremioPlayerConfiguration.hasVisibleVideoFrame(player)
                isAudioOnly = player.isReadyToPlay && hasAudio && !hasVideo

                if !didProduceMedia, now - startedAt >= 8 {
                    reportFailure(PlayerAttemptError.startupTimedOut(engine))
                    return
                }

                let duration = player.duration
                if hasVideo, player.isReadyToPlay,
                   duration.isFinite, duration > 0,
                   duration < minimumVideoDuration {
                    reportFailure(PlayerAttemptError.unexpectedShortVideo(duration))
                    return
                }

                if !didRestorePosition, initialPosition > 0,
                   player.isReadyToPlay, player.seekable {
                    didRestorePosition = true
                    PlayerSeekRecovery.seek(
                        layer: layer,
                        to: min(initialPosition, max(duration - 1, 0)),
                        resume: wantsPlayback
                    )
                    lastPlaybackTime = initialPosition
                    lastProgressAt = now
                    continue
                }

                if frameVisible {
                    didProduceVideoFrame = true
                    didProduceMedia = true
                    recordStartupIfNeeded(currentTime: currentTime)
                } else if !hasVideo, hasAudio, currentTime > 0.10 {
                    didProduceMedia = true
                    recordStartupIfNeeded(currentTime: currentTime)
                }

                if wantsPlayback, player.isReadyToPlay {
                    let progressed = currentTime >= lastPlaybackTime + 0.03
                    if progressed {
                        playableWithoutProgressSince = nil
                        lastProgressAt = now
                    } else if player.loadState == .playable {
                        playableWithoutProgressSince = playableWithoutProgressSince ?? now
                        if let stalledAt = playableWithoutProgressSince {
                            let stalledFor = now - stalledAt
                            if stalledFor >= 3 {
                                ensurePlayback(layer, forceNativeClock: true)
                            } else if stalledFor >= 0.75 {
                                ensurePlayback(layer, forceNativeClock: false)
                            }
                        }
                    }
                    if didProduceMedia, now - lastProgressAt >= 5 {
                        reportFailure(
                            PlayerAttemptError.playbackDidNotAdvance(engine, currentTime)
                        )
                        return
                    }
                } else {
                    playableWithoutProgressSince = nil
                    lastProgressAt = now
                }

                if wantsPlayback, hasVideo, currentTime > 0.50, !frameVisible,
                   player.loadState == .playable {
                    videoWithoutFrameSince = videoWithoutFrameSince ?? now
                    if let blackSince = videoWithoutFrameSince, now - blackSince >= 4 {
                        reportFailure(PlayerAttemptError.videoFrameTimedOut(engine))
                        return
                    }
                } else {
                    videoWithoutFrameSince = nil
                }

                lastPlaybackTime = currentTime
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            startPictureInPictureIfPossible()
        }
        .onDisappear {
            coordinator.playerLayer?.stop()
            coordinator.resetPlayer()
        }
    }

    private func startPictureInPictureIfPossible() {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let playerLayer = coordinator.playerLayer,
              !playerLayer.isPipActive
        else { return }
        playerLayer.isPipActive = true
    }

    private func ensurePlayback(
        _ layer: KSPlayerLayer,
        forceNativeClock: Bool
    ) {
        guard wantsPlayback else { return }
        PlayerSeekRecovery.resume(layer: layer)
    }

    private func recordStartupIfNeeded(currentTime: TimeInterval) {
        guard currentTime > 0, !didRecordStartup else { return }
        didRecordStartup = true
        let elapsed = (ProcessInfo.processInfo.systemUptime - startupStartedAt) * 1_000
        NSLog(
            "PLAYER_BENCHMARK playing_ms=%.1f engine=%@ title=%@",
            elapsed,
            engine.rawValue,
            title
        )
    }

    private func reportFailure(_ error: Error) {
        guard !didReportFailure else { return }
        didReportFailure = true
        let elapsed = (ProcessInfo.processInfo.systemUptime - startupStartedAt) * 1_000
        NSLog(
            "PLAYER_BENCHMARK failed_ms=%.1f engine=%@ title=%@ error=%@",
            elapsed,
            engine.rawValue,
            title,
            error.localizedDescription
        )
        onFailure(error)
    }

    private var keepsControlsVisibleForVerification: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["SKELETON_PLAYER_CONTROLS_LOCKED"] == "1"
        #else
        false
        #endif
    }

    private var startsLandscapeForVerification: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["SKELETON_PLAYER_FIXTURE_LANDSCAPE"] == "1"
        #else
        false
        #endif
    }
}

private enum PlayerAttemptError: LocalizedError {
    case playerError
    case startupTimedOut(StremioPlayerConfiguration.Engine)
    case playbackDidNotAdvance(StremioPlayerConfiguration.Engine, TimeInterval)
    case seekRecoveryTimedOut(StremioPlayerConfiguration.Engine, TimeInterval)
    case videoFrameTimedOut(StremioPlayerConfiguration.Engine)
    case unexpectedShortVideo(TimeInterval)

    var resumePosition: TimeInterval? {
        switch self {
        case let .playbackDidNotAdvance(_, position),
             let .seekRecoveryTimedOut(_, position):
            position
        default:
            nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .playerError:
            "The player could not open this stream."
        case let .startupTimedOut(engine):
            "The \(engine.rawValue) engine returned no playable audio or video within 8 seconds."
        case let .playbackDidNotAdvance(engine, _):
            "The \(engine.rawValue) engine opened the stream but playback did not advance."
        case let .seekRecoveryTimedOut(engine, _):
            "The \(engine.rawValue) engine could not resume after scrubbing."
        case let .videoFrameTimedOut(engine):
            "The \(engine.rawValue) engine produced playback time without a visible video frame."
        case let .unexpectedShortVideo(duration):
            "The source returned only \(Int(duration.rounded())) seconds of video instead of the selected title."
        }
    }
}

private struct PlayerControlsOverlay: View {
    @ObservedObject var coordinator: KSVideoPlayer.Coordinator
    let state: KSPlayerState
    let title: String
    @Binding var wantsPlayback: Bool
    let onSeekFailure: (TimeInterval) -> Void
    let close: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.72), .clear, .black.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 12) {
                topControls
                Spacer(minLength: 18)
                centerControls
                Spacer(minLength: 18)
                bottomControls
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .tint(.white)
        .buttonStyle(PlayerOverlayButtonStyle())
        .accessibilityIdentifier("player-controls")
    }

    private var topControls: some View {
        HStack(spacing: 10) {
            overlayButton("xmark", label: "Close player", identifier: "player-close", action: close)

            Spacer(minLength: 8)

            if hasAudioTracks {
                PlayerAudioMenu(coordinator: coordinator)
            }
            PlayerSubtitleMenu(coordinator: coordinator)
            overlayButton(
                coordinator.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                label: coordinator.isMuted ? "Unmute" : "Mute",
                action: { coordinator.isMuted.toggle() }
            )
            overlayButton(
                "pip",
                label: "Picture in Picture",
                identifier: "player-pip",
                action: { coordinator.playerLayer?.isPipActive.toggle() }
            )
            overlayButton(
                "rectangle.landscape.rotate",
                label: "Rotate player",
                identifier: "player-orientation-toggle",
                action: PlayerPresentation.toggleOrientation
            )
        }
    }

    private var centerControls: some View {
        HStack(spacing: 44) {
            controlButton("gobackward.15", label: "Back 15 seconds") {
                seekBy(-15)
            }
            controlButton(state.isPlaying ? "pause.fill" : "play.fill", label: state.isPlaying ? "Pause" : "Play", prominent: true) {
                if state.isPlaying {
                    wantsPlayback = false
                    if let layer = coordinator.playerLayer {
                        PlayerSeekRecovery.pause(layer: layer)
                    }
                    coordinator.mask(show: true, autoHide: false)
                } else {
                    wantsPlayback = true
                    if let layer = coordinator.playerLayer {
                        PlayerSeekRecovery.resume(layer: layer)
                    }
                    coordinator.mask(show: true)
                }
            }
            controlButton("goforward.15", label: "Forward 15 seconds") {
                seekBy(15)
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
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .accessibilityLabel("Buffering")
                }
                Spacer(minLength: 8)
                overlayButton(
                    coordinator.isScaleAspectFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    label: coordinator.isScaleAspectFill ? "Fit video" : "Fill screen",
                    identifier: "player-content-mode",
                    action: { coordinator.isScaleAspectFill.toggle() }
                )
            }
            PlayerTimeline(
                coordinator: coordinator,
                isReady: !isLoading,
                isActivelyPlaying: state.isPlaying,
                onSeekFailure: onSeekFailure
            )
        }
    }

    private var isLoading: Bool {
        switch state {
        case .initialized, .preparing, .readyToPlay, .buffering:
            true
        case .bufferFinished, .paused, .playedToTheEnd, .error:
            false
        }
    }

    private var hasAudioTracks: Bool {
        !(coordinator.playerLayer?.player.tracks(mediaType: .audio).isEmpty ?? true)
    }

    private func seekBy(_ interval: TimeInterval) {
        guard let layer = coordinator.playerLayer else { return }
        let duration = layer.player.duration
        let target = min(
            max(layer.player.currentPlaybackTime + interval, 0),
            max(duration - 1, 0)
        )
        PlayerSeekRecovery.seek(layer: layer, to: target, resume: wantsPlayback) { finished in
            if !finished { onSeekFailure(target) }
        }
    }

    @ViewBuilder
    private func overlayButton(
        _ systemName: String,
        label: String,
        identifier: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier ?? label)
    }

    private func controlButton(
        _ systemName: String,
        label: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: prominent ? 26 : 23, weight: .semibold))
                .frame(width: prominent ? 56 : 48, height: prominent ? 56 : 48)
                .background(.black.opacity(0.58), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct PlayerTimeline: View {
    @ObservedObject var coordinator: KSVideoPlayer.Coordinator
    @ObservedObject private var model: ControllerTimeModel
    let isReady: Bool
    let isActivelyPlaying: Bool
    let onSeekFailure: (TimeInterval) -> Void
    @State private var isScrubbing = false
    @State private var scrubPosition = 0.0
    @State private var wasPlayingBeforeScrub = false

    init(
        coordinator: KSVideoPlayer.Coordinator,
        isReady: Bool,
        isActivelyPlaying: Bool,
        onSeekFailure: @escaping (TimeInterval) -> Void
    ) {
        self.coordinator = coordinator
        model = coordinator.timemodel
        self.isReady = isReady
        self.isActivelyPlaying = isActivelyPlaying
        self.onSeekFailure = onSeekFailure
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(isReady ? formatted(model.currentTime) : "--:--")
            Slider(
                value: Binding(
                    get: {
                        isScrubbing ? scrubPosition : Double(model.currentTime)
                    },
                    set: { scrubPosition = $0 }
                ),
                in: 0...Double(max(model.totalTime, 1)),
                onEditingChanged: { editing in
                    if editing {
                        guard !isScrubbing else { return }
                        isScrubbing = true
                        scrubPosition = Double(model.currentTime)
                        // KSPlayer's underlying AVPlayer may briefly report a
                        // zero rate while its UI state is still playing. Keep
                        // that playback intent so releasing the scrubber always
                        // resumes a movie that was playing before the drag.
                        wasPlayingBeforeScrub = isActivelyPlaying
                            || coordinator.playerLayer?.player.isPlaying == true
                        if wasPlayingBeforeScrub {
                            if let layer = coordinator.playerLayer {
                                PlayerSeekRecovery.pause(layer: layer)
                            }
                        }
                    } else if let layer = coordinator.playerLayer {
                        let target = scrubPosition
                        let shouldResume = wasPlayingBeforeScrub
                        isScrubbing = false
                        PlayerSeekRecovery.seek(
                            layer: layer,
                            to: target,
                            resume: shouldResume
                        ) { finished in
                            if finished {
                                model.currentTime = Int(target)
                            }
                        }
                        if shouldResume {
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(4))
                                guard !isScrubbing,
                                      coordinator.playerLayer === layer,
                                      layer.player.currentPlaybackTime < target + 0.25
                                else { return }
                                onSeekFailure(target)
                            }
                        }
                    }
                }
            )
            .tint(.orange)
            .disabled(!isReady || !(coordinator.playerLayer?.player.seekable ?? false))
            .accessibilityIdentifier("player-timeline")
            Text(isReady ? formatted(model.totalTime) : "--:--")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white.opacity(0.9))
    }

    private func formatted(_ seconds: Int) -> String {
        let clamped = max(seconds, 0)
        let hours = clamped / 3_600
        let minutes = (clamped % 3_600) / 60
        let remainingSeconds = clamped % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
            : String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}

private struct PlayerAudioMenu: View {
    @ObservedObject var coordinator: KSVideoPlayer.Coordinator

    private var tracks: [MediaPlayerTrack] {
        coordinator.playerLayer?.player.tracks(mediaType: .audio) ?? []
    }

    var body: some View {
        Menu {
            ForEach(tracks, id: \.trackID) { track in
                Button {
                    coordinator.playerLayer?.player.select(track: track)
                } label: {
                    Label(track.name, systemImage: track.isEnabled ? "checkmark" : "waveform")
                }
            }
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 42, height: 42)
                .background(.black.opacity(0.68), in: Circle())
        }
        .accessibilityLabel("Audio tracks")
        .accessibilityIdentifier("player-audio-tracks")
    }
}

private struct PlayerSubtitleMenu: View {
    @ObservedObject var coordinator: KSVideoPlayer.Coordinator
    @ObservedObject private var model: SubtitleModel

    init(coordinator: KSVideoPlayer.Coordinator) {
        self.coordinator = coordinator
        model = coordinator.subtitleModel
    }

    var body: some View {
        Menu {
            Button("Off") {
                model.selectedSubtitleInfo = nil
            }
            ForEach(model.subtitleInfos, id: \.subtitleID) { info in
                Button {
                    model.selectedSubtitleInfo = info
                    if let track = info as? MediaPlayerTrack {
                        coordinator.playerLayer?.player.select(track: track)
                    }
                } label: {
                    Label(info.name, systemImage: info.isEnabled ? "checkmark" : "captions.bubble")
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 42, height: 42)
                .background(.black.opacity(0.68), in: Circle())
        }
        .accessibilityLabel("Subtitles")
        .accessibilityIdentifier("player-subtitles")
    }
}

private struct PlayerSubtitleOverlay: View {
    @ObservedObject var model: SubtitleModel

    var body: some View {
        VStack {
            Spacer()
            ForEach(model.parts) { part in
                if let text = part.text {
                    Text(AttributedString(text))
                        .font(.body.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                } else if let image = part.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 120)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 86)
    }
}

#else
struct NativePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.entersFullScreenWhenPlaybackBegins = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}

struct PlayerScreen: View {
    let title: String
    private let plan: PlaybackPlan
    private let minimumVideoDuration: TimeInterval
    private let onExhausted: (@MainActor (Error) -> Void)?
    @State private var player = AVPlayer()
    @State private var candidateIndex = 0
    @State private var attemptRevision = 0
    @State private var statusMessage = "Preparing video…"
    @State private var failureMessage: String?

    init(
        plan: PlaybackPlan,
        title: String,
        minimumVideoDuration: TimeInterval = 4,
        onExhausted: (@MainActor (Error) -> Void)? = nil
    ) {
        self.plan = plan
        self.title = title
        self.minimumVideoDuration = minimumVideoDuration
        self.onExhausted = onExhausted
    }

    init(url: URL, title: String) {
        self.init(
            plan: PlaybackPlan(
                primaryURL: url,
                fallbackURL: nil,
                usesCompatibilityPlayback: false
            ),
            title: title
        )
    }

    private var candidates: [URL] { [plan.primaryURL] }

    var body: some View {
        ZStack {
            NativePlayerView(player: player)
                .background(.black)

            if let failureMessage {
                playbackFailure(message: failureMessage)
            } else if !statusMessage.isEmpty {
                VStack(spacing: 12) {
                    ProgressView().tint(.orange)
                    Text(statusMessage).foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityIdentifier("player-loading")
            }
        }
        .background(.black)
        .ignoresSafeArea()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                PlayerOrientationButton()
            }
        }
        .task(id: "\(candidateIndex)-\(attemptRevision)") { await startCurrentCandidate() }
        .onReceive(
            NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)
        ) { notification in
            guard notification.object as? AVPlayerItem === player.currentItem else { return }
            advanceOrFail()
        }
        .onDisappear {
            player.pause()
            player.replaceCurrentItem(with: nil)
            PlayerPresentation.endAudioSession()
            PlayerPresentation.restorePortrait()
        }
    }

    @ViewBuilder
    private func playbackFailure(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "play.slash")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Playback unavailable").font(.title3.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                failureMessage = nil
                statusMessage = plan.usesCompatibilityPlayback
                    ? "Converting for this device…"
                    : "Preparing video…"
                candidateIndex = 0
                attemptRevision += 1
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(28)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 22))
        .padding()
        .accessibilityIdentifier("player-error")
    }

    @MainActor
    private func startCurrentCandidate() async {
        guard candidates.indices.contains(candidateIndex) else {
            failPlayback()
            return
        }

        failureMessage = nil
        statusMessage = candidateIndex > 0 || plan.usesCompatibilityPlayback
            ? "Converting for this device…"
            : "Preparing video…"
        let item = AVPlayerItem(url: candidates[candidateIndex])
        player.replaceCurrentItem(with: item)
        PlayerPresentation.prepareAudioSession()
        player.play()

        let startupAttempts = plan.usesCompatibilityPlayback || candidateIndex > 0
            ? 1_800
            : 400
        for _ in 0..<startupAttempts {
            guard !Task.isCancelled, player.currentItem === item else { return }
            if item.status == .failed {
                advanceOrFail()
                return
            }
            if item.status == .readyToPlay,
               player.timeControlStatus == .playing || player.rate > 0 {
                statusMessage = ""
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        guard !Task.isCancelled, player.currentItem === item else { return }
        advanceOrFail()
    }

    @MainActor
    private func advanceOrFail() {
        player.pause()
        if candidateIndex + 1 < candidates.count {
            statusMessage = "Switching to compatibility playback…"
            candidateIndex += 1
        } else {
            failPlayback()
        }
    }

    @MainActor
    private func failPlayback() {
        statusMessage = ""
        if let onExhausted {
            onExhausted(
                NSError(
                    domain: "StremioSkeleton.Player",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Source did not produce playable media"]
                )
            )
            return
        }
        failureMessage = plan.usesCompatibilityPlayback || candidateIndex > 0
            ? "The streaming server could not convert this source. Try another H.264 or H.265 stream, or a smaller file."
            : "This source did not return playable media. Try another stream."
    }
}

#endif

struct StreamPlaybackCandidate: Identifiable {
    let stream: Stream
    let providerName: String?

    var id: String { stream.id }
}

struct ResolvingPlayerScreen: View {
    @EnvironmentObject private var model: AppModel
    let candidate: StreamPlaybackCandidate
    let minimumVideoDuration: TimeInterval
    @State private var playbackPlan: PlaybackPlan?
    @State private var error: String?

    init(
        stream: Stream,
        minimumVideoDuration: TimeInterval = 4
    ) {
        candidate = StreamPlaybackCandidate(stream: stream, providerName: nil)
        self.minimumVideoDuration = minimumVideoDuration
    }

    init(
        candidate: StreamPlaybackCandidate,
        minimumVideoDuration: TimeInterval = 4
    ) {
        self.candidate = candidate
        self.minimumVideoDuration = minimumVideoDuration
    }

    private var activeCandidate: StreamPlaybackCandidate { candidate }
    private var activeStream: Stream { candidate.stream }

    var body: some View {
        Group {
            if let playbackPlan {
                PlayerScreen(
                    plan: playbackPlan,
                    title: playbackTitle,
                    minimumVideoDuration: minimumVideoDuration,
                    onExhausted: advanceToNextSource
                )
            } else if let error {
                VStack(spacing: 12) {
                    Image(systemName: "play.slash").font(.system(size: 44))
                    Text("Playback unavailable").font(.title3.bold())
                    Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
                .accessibilityIdentifier("player-resolution-error")
            } else {
                ProgressView(progressMessage)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .task {
            playbackPlan = nil
            error = nil
            if simulatorUnsupportedReason(for: activeStream) != nil {
                advanceToNextSource(
                    NSError(
                        domain: "StremioSkeleton.Player",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Source is unsupported in Simulator"]
                    )
                )
                return
            }
            let startedAt = ProcessInfo.processInfo.systemUptime
            do {
                playbackPlan = try await model.playbackPlan(
                    for: activeStream,
                    providerName: activeCandidate.providerName
                )
                let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                NSLog("STREAM_BENCHMARK resolve_ms=%.1f title=%@", elapsed, playbackTitle)
            }
            catch let resolutionError {
                let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                NSLog("STREAM_BENCHMARK failed_ms=%.1f title=%@ error=%@", elapsed, playbackTitle, resolutionError.localizedDescription)
                advanceToNextSource(resolutionError)
            }
        }
    }

    private var playbackTitle: String {
        let value = [activeStream.title, activeStream.name, activeStream.description]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? candidate.stream.displayName
        return String(value.split(separator: "\n", maxSplits: 1).first?.prefix(64) ?? "Stream")
    }

    private var progressMessage: String {
        activeStream.isTorrent ? "Starting torrent…" : "Preparing stream…"
    }

    @MainActor
    private func advanceToNextSource(_ playbackError: Error) {
        playbackPlan = nil
        error = "This source did not return smooth movie playback. Please retry it or choose another link."
        NSLog(
            "STREAM_PLAYBACK failed error=%@",
            playbackError.localizedDescription
        )
    }

    private func simulatorUnsupportedReason(for stream: Stream) -> String? {
        #if targetEnvironment(simulator)
        let normalized = [stream.title, stream.name, stream.description]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if normalized.contains("4320p") || normalized.contains("8k") {
            return "8K video decoding is not supported by iOS Simulator. Choose a 4K or 1080p source, or test this source on a physical device."
        }
        if normalized.contains("av1") {
            return "AV1 hardware decoding is not available in iOS Simulator. Choose an H.264 or HEVC source, or test AV1 on a supported physical device."
        }
        #endif
        return nil
    }
}

private struct PlayerOverlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 42, height: 42)
            .background(.black.opacity(configuration.isPressed ? 0.9 : 0.68), in: Circle())
            .contentShape(Circle())
    }
}
