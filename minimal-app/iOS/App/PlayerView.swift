@preconcurrency import AVKit
import SwiftUI
import UIKit
#if canImport(KSPlayer)
@preconcurrency import KSPlayer
#endif
#if canImport(MobileVLCKit)
@preconcurrency import MobileVLCKit
#endif

enum StremioInternalPlayer: String, CaseIterable, Identifiable, Sendable {
    case performance = "performance"
    case ksPlayer = "ksplayer"
    case vlcKit = "vlckit"
    case avPlayer = "avplayer"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .performance: "Performance"
        case .ksPlayer: "KSPlayer"
        case .vlcKit: "VLC"
        case .avPlayer: "AVPlayer (deprecated)"
        }
    }

    var detail: String {
        switch self {
        case .performance: "Rust policy + hardware decode"
        case .ksPlayer: "Official Stremio default"
        case .vlcKit: "Official compatibility player"
        case .avPlayer: "Apple formats only"
        }
    }

    var controlsSummary: String {
        switch self {
        case .performance: "Adaptive controls / PiP"
        case .ksPlayer: "PiP / audio / subtitles"
        case .vlcKit: "Seek / pause / rotate"
        case .avPlayer: "Native AV controls"
        }
    }

    static var selected: Self {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["SKELETON_INTERNAL_PLAYER"],
           let player = Self(rawValue: override.lowercased()) {
            return player
        }
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: "preferredInternalPlayer"),
           let player = Self(rawValue: stored) {
            return player
        }
        if defaults.bool(forKey: "useAVPlayer") { return .avPlayer }
        if defaults.bool(forKey: "useVLCKit") { return .vlcKit }
        return .performance
    }

    static func select(_ player: Self) {
        let defaults = UserDefaults.standard
        defaults.set(player.rawValue, forKey: "preferredInternalPlayer")
        defaults.set(player == .avPlayer, forKey: "useAVPlayer")
        defaults.set(player == .vlcKit, forKey: "useVLCKit")
    }
}

enum PlayerDebugPreferences {
    static let overlayEnabledKey = "playerDebugOverlayEnabled"

    static var environmentForcesOverlay: Bool {
        ProcessInfo.processInfo.environment["SKELETON_PLAYER_DEBUG_OVERLAY"] == "1"
    }
}

private struct PlayerDebugSnapshot: Equatable {
    var engine: String
    var state: String
    var displayFPS: Double?
    var nominalFPS: Double?
    var droppedFrames: Int?
    var droppedPackets: Int?
    var stalls: Int?
    var bufferSeconds: Double?
    var hardwareAcceleration: String?

    static func waiting(engine: String) -> Self {
        Self(
            engine: engine,
            state: "Starting",
            displayFPS: nil,
            nominalFPS: nil,
            droppedFrames: nil,
            droppedPackets: nil,
            stalls: nil,
            bufferSeconds: nil,
            hardwareAcceleration: nil
        )
    }

    var logDescription: String {
        [
            "engine=\(engine.replacingOccurrences(of: " ", with: "_"))",
            "state=\(state.lowercased())",
            "fps=\(number(displayFPS))",
            "nominal_fps=\(number(nominalFPS))",
            "dropped_frames=\(integer(droppedFrames))",
            "dropped_packets=\(integer(droppedPackets))",
            "stalls=\(integer(stalls))",
            "buffer_seconds=\(number(bufferSeconds))",
            "hardware=\(hardwareAcceleration?.replacingOccurrences(of: " ", with: "_") ?? "unknown")",
        ].joined(separator: " ")
    }

    private func number(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "unknown"
    }

    private func integer(_ value: Int?) -> String {
        value.map(String.init) ?? "unknown"
    }
}

@MainActor
private enum PlayerDebugMetrics {
    static func avPlayer(
        _ player: AVPlayer,
        engine: String,
        nominalFPS: Double? = nil
    ) -> PlayerDebugSnapshot {
        guard let item = player.currentItem else {
            return .waiting(engine: engine)
        }

        let currentFPS = item.tracks
            .map { Double($0.currentVideoFrameRate) }
            .filter { $0 > 0 }
            .max()
        let event = item.accessLog()?.events.last
        let droppedFrames = event.flatMap {
            $0.numberOfDroppedVideoFrames >= 0 ? $0.numberOfDroppedVideoFrames : nil
        }
        let stalls = event.flatMap {
            $0.numberOfStalls >= 0 ? $0.numberOfStalls : nil
        }

        let state: String
        switch player.timeControlStatus {
        case .playing:
            state = "Playing"
        case .waitingToPlayAtSpecifiedRate:
            state = "Buffering"
        case .paused:
            state = item.status == .readyToPlay ? "Paused" : "Starting"
        @unknown default:
            state = "Waiting"
        }

        return PlayerDebugSnapshot(
            engine: engine,
            state: state,
            displayFPS: currentFPS,
            nominalFPS: nominalFPS,
            droppedFrames: droppedFrames,
            droppedPackets: nil,
            stalls: stalls,
            bufferSeconds: bufferedSeconds(for: item),
            hardwareAcceleration: "System HW"
        )
    }

    private static func bufferedSeconds(for item: AVPlayerItem) -> Double? {
        let currentTime = item.currentTime().seconds
        guard currentTime.isFinite else { return nil }
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = range.end.seconds
            guard start.isFinite, end.isFinite else { continue }
            if currentTime >= start - 0.05, currentTime <= end + 0.05 {
                return max(end - currentTime, 0)
            }
        }
        return 0
    }
}

private struct PlayerDebugOverlay: View {
    let snapshot: PlayerDebugSnapshot
    var topInset: CGFloat = 58

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 7, height: 7)
                    Text(snapshot.engine)
                        .fontWeight(.semibold)
                    Text(snapshot.state.uppercased())
                        .foregroundStyle(.secondary)
                }

                metric("FPS", value: fpsText)
                metric("Dropped", value: droppedText, highlightsProblem: hasDrops)
                metric("Stalls", value: integer(snapshot.stalls))
                metric("Buffer", value: bufferText)
                metric("Decode", value: snapshot.hardwareAcceleration ?? "--")
                if snapshot.droppedPackets != nil {
                    metric(
                        "Packets",
                        value: integer(snapshot.droppedPackets),
                        highlightsProblem: (snapshot.droppedPackets ?? 0) > 0
                    )
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(width: max(proxy.size.width - 24, 0), alignment: .leading)
            .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(hasDrops ? Color.orange.opacity(0.9) : Color.white.opacity(0.18))
            }
            .padding(.leading, 12)
            .padding(.top, topInset)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player-debug-overlay")
        .accessibilityLabel(
            "Player debug, \(snapshot.engine), \(snapshot.state), "
                + "\(fpsText) frames per second, \(droppedText) dropped, "
                + "\(integer(snapshot.stalls)) stalls"
        )
    }

    private var fpsText: String {
        let displayed = number(snapshot.displayFPS)
        guard snapshot.nominalFPS != nil else { return displayed }
        return "\(displayed) / \(number(snapshot.nominalFPS))"
    }

    private var droppedText: String {
        guard let droppedFrames = snapshot.droppedFrames else { return "--" }
        return "\(droppedFrames) frames"
    }

    private var bufferText: String {
        snapshot.bufferSeconds.map { String(format: "%.1f s", $0) } ?? "--"
    }

    private var hasDrops: Bool {
        (snapshot.droppedFrames ?? 0) > 0 || (snapshot.droppedPackets ?? 0) > 0
    }

    private var stateColor: Color {
        switch snapshot.state {
        case "Playing": .green
        case "Buffering", "Seeking", "Starting": .orange
        case "Failed": .red
        default: .secondary
        }
    }

    @ViewBuilder
    private func metric(
        _ label: String,
        value: String,
        highlightsProblem: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(highlightsProblem ? Color.orange : Color.white)
        }
        .frame(minWidth: 124)
    }

    private func number(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "--"
    }

    private func integer(_ value: Int?) -> String {
        value.map(String.init) ?? "--"
    }
}

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
/// KSPlayer path matching the official Stremio default. Direct containers use
/// its FFmpeg engine; HLS stays inside KSPlayer but uses KSAVPlayer because its
/// segmented seeking is substantially more reliable than FFmpeg's HLS demuxer.
struct KSPlayerScreen: View {
    let title: String
    private let plan: PlaybackPlan
    private let watchTogetherContent: WatchTogetherContent
    private let minimumVideoDuration: TimeInterval
    private let onExhausted: (@MainActor (Error) -> Void)?
    @State private var attemptRevision = 0
    @State private var failureMessage: String?
    @State private var automaticRetryCount = 0
    @State private var retryPosition: TimeInterval = 0

    init(
        plan: PlaybackPlan,
        title: String,
        watchTogetherContent: WatchTogetherContent? = nil,
        minimumVideoDuration: TimeInterval = 4,
        onExhausted: (@MainActor (Error) -> Void)? = nil
    ) {
        self.plan = plan
        self.title = title
        self.watchTogetherContent = watchTogetherContent
            ?? WatchTogetherContent(title: title)
        self.minimumVideoDuration = minimumVideoDuration
        self.onExhausted = onExhausted
    }

    init(url: URL, title: String) {
        self.init(
            plan: PlaybackPlan(
                primaryURL: url,
                fallbackURL: nil
            ),
            title: title
        )
    }

    private struct Candidate: Hashable {
        let url: URL
        let engine: StremioPlayerConfiguration.Engine
    }

    private var playbackPolicy: PlaybackPerformancePolicy {
        PlaybackPerformanceCore.policy(
            url: plan.primaryURL,
            title: [title, plan.detectedMIMEType].compactMap { $0 }.joined(separator: " "),
            player: .ksPlayer
        )
    }

    private var candidate: Candidate {
        // This remains the KSPlayer choice exposed in Settings. KSPlayer owns
        // both backends: use its AVFoundation engine for Apple-native formats
        // (faster startup and dependable scrubbing), and reserve FFmpeg for
        // containers/codecs that AVFoundation cannot handle.
        let engine: StremioPlayerConfiguration.Engine = playbackPolicy.decoder == .avFoundation
            ? .native : .ffmpeg
        return Candidate(url: plan.primaryURL, engine: engine)
    }

    var body: some View {
        ZStack {
            if failureMessage == nil {
                KSPlaybackAttempt(
                    url: candidate.url,
                    engine: candidate.engine,
                    title: title,
                    watchTogetherContent: watchTogetherContent,
                    minimumVideoDuration: minimumVideoDuration,
                    initialPosition: retryPosition,
                    performancePolicy: playbackPolicy,
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
                automaticRetryCount = 0
                retryPosition = 0
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
        if automaticRetryCount == 0 {
            automaticRetryCount = 1
            retryPosition = (error as? PlayerAttemptError)?.resumePosition ?? 0
            attemptRevision += 1
            NSLog(
                "PLAYER_REPAIR retry=same-engine engine=%@ position=%.1f",
                candidate.engine.rawValue,
                retryPosition
            )
            return
        }
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
    let watchTogetherContent: WatchTogetherContent
    let minimumVideoDuration: TimeInterval
    let initialPosition: TimeInterval
    let performancePolicy: PlaybackPerformancePolicy
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
    @State private var didAttemptStallRecovery = false
    @State private var didRunParityVerification = false
    @State private var didAttachWatchTogether = false
    @State private var watchTogetherAttachmentToken = UUID()
    @AppStorage(PlayerDebugPreferences.overlayEnabledKey)
    private var debugOverlaySetting = false
    @State private var debugSnapshot = PlayerDebugSnapshot.waiting(engine: "KSPlayer")

    private let options: KSOptions

    init(
        url: URL,
        engine: StremioPlayerConfiguration.Engine,
        title: String,
        watchTogetherContent: WatchTogetherContent,
        minimumVideoDuration: TimeInterval,
        initialPosition: TimeInterval,
        performancePolicy: PlaybackPerformancePolicy,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        self.url = url
        self.engine = engine
        self.title = title
        self.watchTogetherContent = watchTogetherContent
        self.minimumVideoDuration = minimumVideoDuration
        self.initialPosition = initialPosition
        self.performancePolicy = performancePolicy
        self.onFailure = onFailure

        self.options = StremioPlayerConfiguration.makeOptions(
            engine: engine,
            performancePolicy: performancePolicy
        )
    }

    var body: some View {
        ZStack {
            KSVideoPlayer(coordinator: coordinator, url: url, options: options)
                .onStateChanged { _, state in
                    playerState = state
                    if state == .paused {
                        // Native AVPlayer SharePlay commands arrive underneath
                        // KSPlayer's controls. Mirror the remote intent so the
                        // local stall watchdog never restarts a group pause.
                        wantsPlayback = false
                    } else if state.isPlaying {
                        wantsPlayback = true
                    }
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
                    Text("Starting video…")
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
                    watchTogetherContent: watchTogetherContent,
                    wantsPlayback: $wantsPlayback,
                    onSeekFailure: { position in
                        reportFailure(PlayerAttemptError.seekRecoveryTimedOut(engine, position))
                    },
                    close: { dismiss() }
                )
                .transition(.opacity)
            }

            if debugOverlayEnabled {
                PlayerDebugOverlay(snapshot: debugSnapshot)
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
            didAttemptStallRecovery = false
            didRunParityVerification = false
            didAttachWatchTogether = false
            debugSnapshot = .waiting(engine: debugEngineName)
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
            var debugStallCount = 0
            var wasDebugBuffering = false
            var lastDebugSampleAt = 0.0
            let startedAt = ProcessInfo.processInfo.systemUptime

            while !Task.isCancelled, !didReportFailure {
                try? await Task.sleep(for: .milliseconds(250))
                guard let layer = coordinator.playerLayer else { continue }

                if !didAttachWatchTogether, layer.player.isReadyToPlay {
                    didAttachWatchTogether = true
                    attachWatchTogether(to: layer)
                }

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

                let isDebugBuffering = wantsPlayback
                    && didProduceMedia
                    && player.loadState == .loading
                if isDebugBuffering, !wasDebugBuffering {
                    debugStallCount += 1
                }
                wasDebugBuffering = isDebugBuffering
                if debugOverlayEnabled, now - lastDebugSampleAt >= 1 {
                    lastDebugSampleAt = now
                    let sample = makeDebugSnapshot(
                        layer: layer,
                        currentTime: currentTime,
                        stallCount: debugStallCount
                    )
                    debugSnapshot = sample
                    NSLog("PLAYER_DEBUG %@", sample.logDescription)
                }

                let startupTimeout: TimeInterval = url.isFileURL ? 8 : 15
                if !didProduceMedia, now - startedAt >= startupTimeout {
                    reportFailure(
                        PlayerAttemptError.startupTimedOut(engine, startupTimeout)
                    )
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
                    if !didRunParityVerification, paritySmokeRequested {
                        didRunParityVerification = true
                        Task { @MainActor in
                            await runVerificationIfRequested(layer: layer)
                        }
                    }
                } else if !hasVideo, hasAudio, currentTime > 0.10 {
                    didProduceMedia = true
                    recordStartupIfNeeded(currentTime: currentTime)
                }

                if wantsPlayback, player.isReadyToPlay {
                    // A demux seek temporarily stops the clock by design. Do
                    // not let the generic stall watchdog issue play/pause
                    // recovery during that window: doing so invalidates the
                    // seek generation before its completion can be delivered.
                    if player.playbackState == .seeking {
                        playableWithoutProgressSince = nil
                        lastProgressAt = now
                        lastPlaybackTime = currentTime
                        continue
                    }
                    let progressed = currentTime >= lastPlaybackTime + 0.03
                    if progressed {
                        playableWithoutProgressSince = nil
                        didAttemptStallRecovery = false
                        lastProgressAt = now
                    } else if player.loadState == .playable {
                        playableWithoutProgressSince = playableWithoutProgressSince ?? now
                        // A single recovery attempt per stall episode. Repeated
                        // play() calls while the decoder is catching up restart
                        // the render pipeline and manifest as constant stutter.
                        if let stalledAt = playableWithoutProgressSince,
                           now - stalledAt >= 1.5, !didAttemptStallRecovery {
                            didAttemptStallRecovery = true
                            ensurePlayback(layer)
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
            WatchTogetherCoordinator.shared.detach(token: watchTogetherAttachmentToken)
            coordinator.playerLayer?.stop()
            coordinator.resetPlayer()
        }
    }

    @MainActor
    private func attachWatchTogether(to layer: KSPlayerLayer) {
        if let native = layer.player as? KSAVPlayer {
            WatchTogetherCoordinator.shared.attach(
                player: native.player,
                content: watchTogetherContent,
                token: watchTogetherAttachmentToken
            )
            return
        }

        WatchTogetherCoordinator.shared.attach(
            adapter: WatchTogetherPlaybackAdapter(
                content: watchTogetherContent,
                currentTime: { layer.player.currentPlaybackTime },
                duration: { layer.player.duration },
                isPlaying: { layer.player.isPlaying },
                isReady: { layer.player.isReadyToPlay },
                play: {
                    wantsPlayback = true
                    PlayerSeekRecovery.resume(layer: layer)
                },
                pause: {
                    wantsPlayback = false
                    PlayerSeekRecovery.pause(layer: layer)
                },
                seek: { target in
                    await withCheckedContinuation { continuation in
                        PlayerSeekRecovery.seek(
                            layer: layer,
                            to: target,
                            resume: false,
                            completion: { continuation.resume(returning: $0) }
                        )
                    }
                }
            ),
            token: watchTogetherAttachmentToken
        )
    }

    private func startPictureInPictureIfPossible() {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let playerLayer = coordinator.playerLayer,
              !playerLayer.isPipActive
        else { return }
        playerLayer.isPipActive = true
    }

    private var debugOverlayEnabled: Bool {
        debugOverlaySetting || PlayerDebugPreferences.environmentForcesOverlay
    }

    private var debugEngineName: String {
        switch engine {
        case .native: "KSPlayer · Native"
        case .ffmpeg: "KSPlayer · FFmpeg"
        case .automatic: "KSPlayer · Auto"
        }
    }

    @MainActor
    private func makeDebugSnapshot(
        layer: KSPlayerLayer,
        currentTime: TimeInterval,
        stallCount: Int
    ) -> PlayerDebugSnapshot {
        let player = layer.player
        if let nativePlayer = player as? KSAVPlayer {
            var snapshot = PlayerDebugMetrics.avPlayer(
                nativePlayer.player,
                engine: debugEngineName
            )
            snapshot.stalls = max(snapshot.stalls ?? 0, stallCount)
            return snapshot
        }

        let info = player.dynamicInfo
        let nominalFPS = Double(player.nominalFrameRate)
        let buffered = player.playableTime.isFinite
            ? max(player.playableTime - currentTime, 0)
            : nil
        let state: String
        if player.playbackState == .seeking {
            state = "Seeking"
        } else if !wantsPlayback || player.playbackState == .paused {
            state = "Paused"
        } else if player.loadState == .loading {
            state = "Buffering"
        } else if player.isPlaying {
            state = "Playing"
        } else {
            state = "Waiting"
        }

        return PlayerDebugSnapshot(
            engine: debugEngineName,
            state: state,
            displayFPS: info.flatMap { $0.displayFPS > 0 ? $0.displayFPS : nil },
            nominalFPS: nominalFPS > 0 ? nominalFPS : nil,
            droppedFrames: info.map { Int($0.droppedVideoFrameCount) },
            droppedPackets: info.map { Int($0.droppedVideoPacketCount) },
            stalls: stallCount,
            bufferSeconds: buffered,
            hardwareAcceleration: options.hardwareDecode ? "VT requested" : "Software"
        )
    }

    private func ensurePlayback(_ layer: KSPlayerLayer) {
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

    @MainActor
    private func runVerificationIfRequested(layer: KSPlayerLayer) async {
        #if targetEnvironment(simulator)
        let player = layer.player
        let startedAt = player.currentPlaybackTime
        for _ in 0..<30 {
            if player.isPlaying,
               player.currentPlaybackTime >= startedAt + 0.35,
               StremioPlayerConfiguration.hasVisibleVideoFrame(player) {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard player.isPlaying,
              player.currentPlaybackTime >= startedAt + 0.35,
              StremioPlayerConfiguration.hasVisibleVideoFrame(player)
        else {
            NSLog("PLAYER_PARITY FAIL player=ksplayer step=autoplay-or-visible-frame")
            return
        }

        let duration = player.duration
        let seekTarget = duration > 600 ? 120 : min(max(duration * 0.5, 5), 30)
        // Match the real control surface: its timeline remains disabled until
        // KSPlayer exposes a seekable range, which can lag the first frame on
        // a cold progressive-file open.
        for _ in 0..<50 {
            if player.seekable { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard player.seekable else {
            NSLog("PLAYER_PARITY FAIL player=ksplayer step=seek-readiness")
            return
        }
        let seekFinished = await withCheckedContinuation { continuation in
            PlayerSeekRecovery.seek(
                layer: layer,
                to: seekTarget,
                resume: true,
                completion: { continuation.resume(returning: $0) }
            )
        }
        guard seekFinished else {
            NSLog("PLAYER_PARITY FAIL player=ksplayer step=seek")
            return
        }

        for _ in 0..<80 {
            if player.isPlaying,
               player.currentPlaybackTime >= seekTarget + 0.35,
               StremioPlayerConfiguration.hasVisibleVideoFrame(player) {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard player.isPlaying,
              player.currentPlaybackTime >= seekTarget + 0.35,
              StremioPlayerConfiguration.hasVisibleVideoFrame(player)
        else {
            NSLog("PLAYER_PARITY FAIL player=ksplayer step=seek-resume")
            return
        }

        wantsPlayback = false
        PlayerSeekRecovery.pause(layer: layer)
        try? await Task.sleep(for: .milliseconds(500))
        let pausedAt = player.currentPlaybackTime
        try? await Task.sleep(for: .milliseconds(800))
        let pausedEnd = player.currentPlaybackTime
        guard !player.isPlaying, abs(pausedEnd - pausedAt) < 0.25 else {
            NSLog("PLAYER_PARITY FAIL player=ksplayer step=pause")
            return
        }

        wantsPlayback = true
        PlayerSeekRecovery.resume(layer: layer)
        for _ in 0..<80 {
            if player.isPlaying, player.currentPlaybackTime >= pausedEnd + 0.35 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard player.isPlaying, player.currentPlaybackTime >= pausedEnd + 0.35 else {
            NSLog("PLAYER_PARITY FAIL player=ksplayer step=resume")
            return
        }

        NSLog(
            "PLAYER_PARITY PASS player=ksplayer backend=%@ autoplay=yes frame=yes seek=yes pause=yes resume=yes duration=%.1f",
            engine.rawValue,
            duration
        )
        #endif
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

    private var paritySmokeRequested: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["SKELETON_PLAYER_PARITY_SMOKE"] == "1"
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
    case startupTimedOut(StremioPlayerConfiguration.Engine, TimeInterval)
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
        case let .startupTimedOut(engine, timeout):
            "The \(engine.rawValue) engine returned no playable audio or video within \(Int(timeout)) seconds."
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
    @ObservedObject private var watchTogether = WatchTogetherCoordinator.shared
    let state: KSPlayerState
    let title: String
    let watchTogetherContent: WatchTogetherContent
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

            WatchTogetherMenu(content: watchTogetherContent)
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
                    if !watchTogether.requestPause(
                        for: watchTogetherContent.identifier
                    ), let layer = coordinator.playerLayer {
                        PlayerSeekRecovery.pause(layer: layer)
                    }
                    coordinator.mask(show: true, autoHide: false)
                } else {
                    wantsPlayback = true
                    if !watchTogether.requestPlay(
                        for: watchTogetherContent.identifier
                    ), let layer = coordinator.playerLayer {
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
                watchTogetherContent: watchTogetherContent,
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
        if watchTogether.requestSeek(
            to: target,
            resumeAfterSeek: wantsPlayback,
            for: watchTogetherContent.identifier
        ) {
            return
        }
        PlayerSeekRecovery.seek(
            layer: layer,
            to: target,
            resume: wantsPlayback
        ) { finished in
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
    @ObservedObject private var watchTogether = WatchTogetherCoordinator.shared
    let watchTogetherContent: WatchTogetherContent
    let isReady: Bool
    let isActivelyPlaying: Bool
    let onSeekFailure: (TimeInterval) -> Void
    @State private var isScrubbing = false
    @State private var scrubPosition = 0.0
    @State private var wasPlayingBeforeScrub = false

    init(
        coordinator: KSVideoPlayer.Coordinator,
        watchTogetherContent: WatchTogetherContent,
        isReady: Bool,
        isActivelyPlaying: Bool,
        onSeekFailure: @escaping (TimeInterval) -> Void
    ) {
        self.coordinator = coordinator
        model = coordinator.timemodel
        self.watchTogetherContent = watchTogetherContent
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
                            if !watchTogether.requestPause(
                                for: watchTogetherContent.identifier
                            ), let layer = coordinator.playerLayer {
                                PlayerSeekRecovery.pause(layer: layer)
                            }
                        }
                    } else if let layer = coordinator.playerLayer {
                        let target = scrubPosition
                        let shouldResume = wasPlayingBeforeScrub
                        isScrubbing = false
                        if watchTogether.requestSeek(
                            to: target,
                            resumeAfterSeek: shouldResume,
                            for: watchTogetherContent.identifier
                        ) {
                            model.currentTime = Int(target)
                            if shouldResume {
                                scheduleSeekFailureCheck(layer: layer, target: target)
                            }
                            return
                        }
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
                            scheduleSeekFailureCheck(layer: layer, target: target)
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

    private func scheduleSeekFailureCheck(
        layer: KSPlayerLayer,
        target: TimeInterval
    ) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !isScrubbing,
                  coordinator.playerLayer === layer,
                  layer.player.currentPlaybackTime < target + 0.25
            else { return }
            onSeekFailure(target)
        }
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

#endif

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

private struct AVPlayerPreparedSource {
    let asset: AVURLAsset
    let isKnownUnsupported: Bool
}

private enum AVPlayerSourceProbe {
    static func prepare(
        url: URL,
        knownMIMEType: String? = nil
    ) async -> AVPlayerPreparedSource {
        if let knownMIMEType {
            let unsupported = knownMIMEType == "video/x-matroska"
                || knownMIMEType == "video/webm"
            let asset: AVURLAsset
            if #available(iOS 17.0, *) {
                asset = AVURLAsset(
                    url: url,
                    options: [AVURLAssetOverrideMIMETypeKey: knownMIMEType]
                )
            } else {
                asset = AVURLAsset(url: url)
            }
            return AVPlayerPreparedSource(
                asset: asset,
                isKnownUnsupported: unsupported
            )
        }
        let pathExtension = url.pathExtension.lowercased()
        if ["mkv", "webm", "avi", "flv", "wmv"].contains(pathExtension) {
            return AVPlayerPreparedSource(
                asset: AVURLAsset(url: url),
                isKnownUnsupported: true
            )
        }

        let knownNativeExtensions = ["m3u8", "mp4", "m4v", "mov", "mp3", "m4a", "aac", "ts"]
        let host = url.host?.lowercased() ?? ""
        let providerMayRelabelPayload = [
            "debrid", "torbox", "tb-cdn", "real-debrid", "alldebrid",
        ].contains(where: host.contains)
        let needsRemoteProbe = !knownNativeExtensions.contains(pathExtension)
            || (providerMayRelabelPayload && pathExtension != "m3u8")
        guard needsRemoteProbe,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else {
            return AVPlayerPreparedSource(
                asset: AVURLAsset(url: url),
                isKnownUnsupported: false
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            var request = URLRequest(url: url)
            request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let (bytes, response) = try await session.bytes(for: request)
            var signature = Data()
            signature.reserveCapacity(4_096)
            for try await byte in bytes {
                signature.append(byte)
                if signature.count == 4_096 { break }
            }

            let serverMIME = response.mimeType?.lowercased()
            let detectedMIME = MediaContainerSniffer.detectedMIMEType(
                signature: signature,
                serverMIMEType: serverMIME
            )
            if detectedMIME == "video/x-matroska" || detectedMIME == "video/webm" {
                NSLog("PLAYER_STREAM_BRIDGE avprobe=unsupported-container")
                return AVPlayerPreparedSource(
                    asset: AVURLAsset(url: url),
                    isKnownUnsupported: true
                )
            }
            if let detectedMIME, #available(iOS 17.0, *) {
                NSLog("PLAYER_STREAM_BRIDGE avprobe=mime-override type=%@", detectedMIME)
                return AVPlayerPreparedSource(
                    asset: AVURLAsset(
                        url: url,
                        options: [AVURLAssetOverrideMIMETypeKey: detectedMIME]
                    ),
                    isKnownUnsupported: false
                )
            }
        } catch {
            NSLog("PLAYER_STREAM_BRIDGE avprobe=unavailable")
        }

        return AVPlayerPreparedSource(
            asset: AVURLAsset(url: url),
            isKnownUnsupported: false
        )
    }

}

struct AVPlayerScreen: View {
    let title: String
    private let plan: PlaybackPlan
    private let watchTogetherContent: WatchTogetherContent
    private let minimumVideoDuration: TimeInterval
    private let onExhausted: (@MainActor (Error) -> Void)?
    @State private var player = AVPlayer()
    @State private var candidateIndex = 0
    @State private var attemptRevision = 0
    @State private var statusMessage = "Preparing video…"
    @State private var failureMessage: String?
    @State private var nominalFPS: Double?
    @AppStorage(PlayerDebugPreferences.overlayEnabledKey)
    private var debugOverlaySetting = false
    @State private var debugSnapshot = PlayerDebugSnapshot.waiting(engine: "AVPlayer")
    @State private var watchTogetherAttachmentToken = UUID()

    init(
        plan: PlaybackPlan,
        title: String,
        watchTogetherContent: WatchTogetherContent? = nil,
        minimumVideoDuration: TimeInterval = 4,
        onExhausted: (@MainActor (Error) -> Void)? = nil
    ) {
        self.plan = plan
        self.title = title
        self.watchTogetherContent = watchTogetherContent
            ?? WatchTogetherContent(title: title)
        self.minimumVideoDuration = minimumVideoDuration
        self.onExhausted = onExhausted
    }

    init(url: URL, title: String) {
        self.init(
            plan: PlaybackPlan(
                primaryURL: url,
                fallbackURL: nil
            ),
            title: title
        )
    }

    private var candidates: [URL] {
        // For containers/codecs AVPlayer cannot decode, use the configured
        // Stremio server's HLS remux/transcode first. The original URL remains
        // a zero-copy second attempt for mislabeled sources.
        [plan.fallbackURL, plan.primaryURL]
            .compactMap { $0 }
            .reduce(into: []) { urls, url in
                if !urls.contains(url) { urls.append(url) }
            }
    }

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

            if debugOverlayEnabled {
                PlayerDebugOverlay(snapshot: debugSnapshot, topInset: 112)
            }
        }
        .background(.black)
        .ignoresSafeArea()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 10) {
                    WatchTogetherMenu(content: watchTogetherContent)
                    PlayerOrientationButton()
                }
            }
        }
        .task(id: "\(candidateIndex)-\(attemptRevision)") { await startCurrentCandidate() }
        .task(id: "debug-\(candidateIndex)-\(attemptRevision)-\(debugOverlayEnabled)") {
            await monitorPlayerDebug()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)
        ) { notification in
            guard notification.object as? AVPlayerItem === player.currentItem else { return }
            advanceOrFail()
        }
        .onDisappear {
            WatchTogetherCoordinator.shared.detach(token: watchTogetherAttachmentToken)
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
                statusMessage = "Preparing video…"
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
        statusMessage = candidateIndex == 0 && plan.fallbackURL != nil
            ? "Optimizing stream…"
            : "Preparing video…"
        let startupStartedAt = ProcessInfo.processInfo.systemUptime
        // Wake the audio pipeline while the asset probe is doing network work.
        // Starting it only after the probe can add a visible first-play hitch.
        PlayerPresentation.prepareAudioSession()
        let preparedSource = await AVPlayerSourceProbe.prepare(
            url: candidates[candidateIndex],
            knownMIMEType: candidates[candidateIndex] == plan.primaryURL
                ? plan.detectedMIMEType : nil
        )
        guard !Task.isCancelled else { return }
        if preparedSource.isKnownUnsupported {
            advanceOrFail()
            return
        }
        let videoTracks: [AVAssetTrack]?
        do {
            videoTracks = try await preparedSource.asset.loadTracks(withMediaType: .video)
        } catch {
            videoTracks = nil
        }
        let expectsVideo = videoTracks?.isEmpty == false || videoTracks == nil
        if let videoTracks {
            var frameRates = [Double]()
            for track in videoTracks {
                if let rate = try? await track.load(.nominalFrameRate), rate > 0 {
                    frameRates.append(Double(rate))
                }
            }
            nominalFPS = frameRates.max()
        } else {
            nominalFPS = nil
        }
        let item = AVPlayerItem(asset: preparedSource.asset)
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(videoOutput)
        player.replaceCurrentItem(with: item)
        WatchTogetherCoordinator.shared.attach(
            player: player,
            content: watchTogetherContent,
            token: watchTogetherAttachmentToken
        )
        player.play()

        for _ in 0..<160 {
            guard !Task.isCancelled, player.currentItem === item else { return }
            if item.status == .failed {
                NSLog(
                    "PLAYER_REPAIR avplayer=item-failed error=%@",
                    item.error?.localizedDescription ?? "unknown"
                )
                advanceOrFail()
                return
            }
            if item.status == .readyToPlay,
               player.timeControlStatus == .playing || player.rate > 0 {
                let duration = item.duration.seconds
                if duration.isFinite, duration > 0, duration < minimumVideoDuration {
                    player.pause()
                    player.replaceCurrentItem(with: nil)
                    let message = "The source returned only \(Int(duration.rounded())) seconds of video instead of the selected title."
                    if let onExhausted {
                        onExhausted(
                            NSError(
                                domain: "StremioSkeleton.Player",
                                code: 3,
                                userInfo: [NSLocalizedDescriptionKey: message]
                            )
                        )
                    } else {
                        failureMessage = message
                    }
                    return
                }
                if expectsVideo {
                    var renderedFrame = false
                    for _ in 0..<60 {
                        let itemTime = item.currentTime()
                        if videoOutput.hasNewPixelBuffer(forItemTime: itemTime) {
                            renderedFrame = true
                            break
                        }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    guard renderedFrame else {
                        NSLog("PLAYER_REPAIR avplayer=no-visible-video-frame")
                        advanceOrFail()
                        return
                    }
                }
                statusMessage = ""
                let elapsed = (ProcessInfo.processInfo.systemUptime - startupStartedAt) * 1_000
                NSLog(
                    "PLAYER_BENCHMARK playing_ms=%.1f engine=avplayer title=%@",
                    elapsed,
                    title
                )
                await runVerificationIfRequested(item: item, videoOutput: videoOutput)
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        guard !Task.isCancelled, player.currentItem === item else { return }
        advanceOrFail()
    }

    @MainActor
    private func monitorPlayerDebug() async {
        debugSnapshot = .waiting(engine: "AVPlayer")
        guard debugOverlayEnabled else { return }
        while !Task.isCancelled {
            let sample = PlayerDebugMetrics.avPlayer(
                player,
                engine: "AVPlayer",
                nominalFPS: nominalFPS
            )
            debugSnapshot = sample
            NSLog("PLAYER_DEBUG %@", sample.logDescription)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private var debugOverlayEnabled: Bool {
        debugOverlaySetting || PlayerDebugPreferences.environmentForcesOverlay
    }

    @MainActor
    private func runVerificationIfRequested(
        item: AVPlayerItem,
        videoOutput: AVPlayerItemVideoOutput
    ) async {
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["SKELETON_PLAYER_PARITY_SMOKE"] == "1"
        else { return }

        let startedAt = item.currentTime().seconds
        var renderedFrame = false
        for _ in 0..<30 {
            let itemTime = item.currentTime()
            renderedFrame = renderedFrame || videoOutput.hasNewPixelBuffer(forItemTime: itemTime)
            if renderedFrame, itemTime.seconds >= startedAt + 0.35 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard renderedFrame, item.currentTime().seconds >= startedAt + 0.35 else {
            NSLog("PLAYER_PARITY FAIL player=avplayer step=autoplay-or-visible-frame")
            return
        }

        let duration = item.duration.seconds
        let seekTarget = duration > 600 ? 120 : min(max(duration * 0.5, 5), 30)
        await withCheckedContinuation { continuation in
            player.seek(
                to: CMTime(seconds: seekTarget, preferredTimescale: 600),
                toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600),
                toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600)
            ) { _ in continuation.resume() }
        }
        guard abs(item.currentTime().seconds - seekTarget) <= 2 else {
            NSLog("PLAYER_PARITY FAIL player=avplayer step=seek")
            return
        }

        player.pause()
        var pausedAt = item.currentTime().seconds
        var stablePauseSamples = 0
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(150))
            let sampledTime = item.currentTime().seconds
            if player.rate == 0, abs(sampledTime - pausedAt) < 0.20 {
                stablePauseSamples += 1
                if stablePauseSamples >= 3 { break }
            } else {
                stablePauseSamples = 0
            }
            pausedAt = sampledTime
        }
        guard player.rate == 0, stablePauseSamples >= 3 else {
            NSLog("PLAYER_PARITY FAIL player=avplayer step=pause")
            return
        }

        player.play()
        for _ in 0..<30 {
            if item.currentTime().seconds >= pausedAt + 0.35 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard player.rate > 0, item.currentTime().seconds >= pausedAt + 0.35 else {
            NSLog("PLAYER_PARITY FAIL player=avplayer step=resume")
            return
        }

        NSLog(
            "PLAYER_PARITY PASS player=avplayer autoplay=yes frame=yes seek=yes pause=yes resume=yes duration=%.1f",
            duration
        )
        #endif
    }

    @MainActor
    private func advanceOrFail() {
        player.pause()
        failPlayback()
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
        failureMessage = "This source did not return playable media. Try another stream."
    }
}

#if canImport(MobileVLCKit)
private struct VLCRenderView: UIViewRepresentable {
    let player: VLCMediaPlayer
    let usesBoundedRenderer: Bool
    let onFirstFrame: @MainActor () -> Void
    let onFrameMetrics: @MainActor (UInt64, UInt64) -> Void

    final class Coordinator {
        let player: VLCMediaPlayer

        init(player: VLCMediaPlayer) {
            self.player = player
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(player: player)
    }

    func makeUIView(context: Context) -> UIView {
        if usesBoundedRenderer {
            let view = VLCBoundedVideoView(
                player: player,
                maximumPixelSize: CGSize(width: 1_920, height: 1_080)
            )
            view.onFirstFrame = onFirstFrame
            view.onFrameMetrics = onFrameMetrics
            return view
        }
        let view = UIView()
        view.backgroundColor = .black
        view.clipsToBounds = true
        player.drawable = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        if let boundedView = view as? VLCBoundedVideoView {
            boundedView.onFirstFrame = onFirstFrame
            boundedView.onFrameMetrics = onFrameMetrics
            return
        }
        if (player.drawable as AnyObject?) !== view {
            player.drawable = view
        }
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        if let boundedView = view as? VLCBoundedVideoView {
            boundedView.detach()
        } else if (coordinator.player.drawable as AnyObject?) === view {
            coordinator.player.drawable = nil
        }
        view.layer.removeAllAnimations()
    }
}

@MainActor
private final class VLCPlaybackModel: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player: VLCMediaPlayer
    private let performancePolicy: PlaybackPerformancePolicy

    @Published var isPlaying = false
    @Published var isReady = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var failureMessage: String?
    @Published private(set) var hasRenderedFrame = false
    @Published private(set) var debugSnapshot = PlayerDebugSnapshot.waiting(engine: "VLC")
    private var debugStallCount = 0
    private var wasBuffering = false
    private var lastStatisticsAt: TimeInterval?
    private var lastDisplayedPictures = 0
    private var measuredDisplayFPS: Double?
    private var debugMetricsEnabled = false
    private var activeBoundedRenderer = false
    private var boundedDisplayedFrames: UInt64 = 0
    private var boundedDroppedFrames: UInt64 = 0

    init(policy: PlaybackPerformancePolicy) {
        performancePolicy = policy
        let environment = ProcessInfo.processInfo.environment
        var options = [
            "--network-caching=\(policy.networkCacheMilliseconds)",
            "--http-reconnect",
            "--avcodec-hw=\(environment["SKELETON_VLC_AVCODEC_HW"] ?? "any")",
            "--no-color",
        ]
        if policy.prefersVideoToolboxChain {
            options.append("--codec=videotoolbox,avcodec,none")
        }
        #if targetEnvironment(simulator)
        if let codecChain = environment["SKELETON_VLC_CODEC_CHAIN"], !codecChain.isEmpty {
            options.removeAll { $0.hasPrefix("--codec=") }
            options.append("--codec=\(codecChain)")
        }
        if environment["SKELETON_VLC_VIDEOTOOLBOX_ONLY"] == "1" {
            options.append("--videotoolbox-hw-decoder-only")
        }
        if environment["SKELETON_VLC_VERBOSE_LOGGING"] == "1" {
            options.append("--verbose=2")
        }
        #endif
        player = VLCMediaPlayer(options: options)
        super.init()
        #if targetEnvironment(simulator)
        if environment["SKELETON_VLC_VERBOSE_LOGGING"] == "1" {
            let logger = VLCDecoderLogger()
            player.libraryInstance.loggers = [logger]
            NSLog("VLC_DIAGNOSTICS options=%@", options.joined(separator: " "))
        }
        #endif
        player.delegate = self
    }

    func start(
        url: URL,
        minimumVideoDuration: TimeInterval,
        usesBoundedRenderer: Bool
    ) async throws {
        stop(clearFailure: true)
        activeBoundedRenderer = usesBoundedRenderer
        let media = VLCMedia(url: url)
        player.media = media
        player.play()

        // Remote HEVC sources measured between roughly ten and thirteen
        // seconds to expose their first decoded frame in MobileVLCKit. Keep a
        // small margin so the bridge does not reject a valid stream too early.
        for _ in 0..<300 {
            guard !Task.isCancelled else { return }
            if player.state == .error {
                throw VLCPlaybackError.playerError
            }
            updatePublishedState()
            if player.isPlaying,
               usesBoundedRenderer
                    ? hasRenderedFrame
                    : (player.hasVideoOut || currentTime > 0.10) {
                if duration > 0, duration < minimumVideoDuration {
                    throw VLCPlaybackError.unexpectedShortVideo(duration)
                }
                isReady = true
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw VLCPlaybackError.startupTimedOut
    }

    func markRenderedFrame() {
        hasRenderedFrame = true
    }

    func recordBoundedFrameMetrics(displayed: UInt64, dropped: UInt64) {
        boundedDisplayedFrames = displayed
        boundedDroppedFrames = dropped
    }

    func setDebugMetricsEnabled(_ enabled: Bool) {
        guard debugMetricsEnabled != enabled else { return }
        debugMetricsEnabled = enabled
        lastStatisticsAt = nil
        lastDisplayedPictures = activeBoundedRenderer
            ? Int(clamping: boundedDisplayedFrames)
            : 0
        measuredDisplayFPS = nil
        activeBoundedRenderer = false
        boundedDisplayedFrames = 0
        boundedDroppedFrames = 0
        if enabled {
            sampleDebugMetrics()
        } else {
            debugSnapshot = .waiting(engine: "VLC")
        }
    }

    func togglePlayback() {
        if player.isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        player.play()
        updatePublishedState()
    }

    func pause() {
        player.pause()
        updatePublishedState()
    }

    func seek(to seconds: TimeInterval) {
        guard player.isSeekable else { return }
        player.time = VLCTime(int: Int32(max(seconds, 0) * 1_000))
        updatePublishedState()
    }

    func seekAndWait(to seconds: TimeInterval) async -> Bool {
        guard player.isSeekable else { return false }
        let target = min(max(seconds, 0), max(duration, 0))
        player.time = VLCTime(int: Int32(target * 1_000))
        for _ in 0..<40 {
            updatePublishedState()
            if abs(currentTime - target) <= 0.65 { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        updatePublishedState()
        return abs(currentTime - target) <= 1.25
    }

    func skip(_ interval: TimeInterval) {
        seek(to: min(max(currentTime + interval, 0), max(duration, 0)))
    }

    func stop(clearFailure: Bool = false) {
        player.stop()
        player.media = nil
        isPlaying = false
        isReady = false
        currentTime = 0
        duration = 0
        hasRenderedFrame = false
        debugSnapshot = .waiting(engine: "VLC")
        debugStallCount = 0
        wasBuffering = false
        lastStatisticsAt = nil
        lastDisplayedPictures = 0
        measuredDisplayFPS = nil
        if clearFailure { failureMessage = nil }
    }

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            updatePublishedState()
            if player.state == .error {
                failureMessage = VLCPlaybackError.playerError.localizedDescription
            }
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in self?.updatePublishedState() }
    }

    private func updatePublishedState() {
        isPlaying = player.isPlaying
        currentTime = max(TimeInterval(player.time.intValue) / 1_000, 0)
        duration = max(TimeInterval(player.media?.length.intValue ?? 0) / 1_000, 0)
        updateDebugStallState()
    }

    private func updateDebugStallState() {
        guard debugMetricsEnabled else { return }
        let buffering = player.state == .buffering
        if isReady, buffering, !wasBuffering {
            debugStallCount += 1
        }
        wasBuffering = buffering
    }

    func sampleDebugMetrics() {
        guard debugMetricsEnabled else { return }
        updateDebugStallState()
        let buffering = player.state == .buffering
        guard let media = player.media else {
            debugSnapshot = .waiting(engine: "VLC")
            return
        }
        let statistics = media.statistics
        let displayedPictures = activeBoundedRenderer
            ? Int(clamping: boundedDisplayedFrames)
            : max(Int(statistics.displayedPictures), 0)
        let now = ProcessInfo.processInfo.systemUptime
        if let lastStatisticsAt {
            let elapsed = now - lastStatisticsAt
            if elapsed >= 0.45 {
                measuredDisplayFPS = Double(max(displayedPictures - lastDisplayedPictures, 0))
                    / elapsed
                self.lastStatisticsAt = now
                lastDisplayedPictures = displayedPictures
            }
        } else {
            lastStatisticsAt = now
            lastDisplayedPictures = displayedPictures
        }

        let state: String
        if player.isPlaying {
            state = "Playing"
        } else if buffering {
            state = "Buffering"
        } else if player.state == .paused {
            state = "Paused"
        } else if player.state == .error {
            state = "Failed"
        } else {
            state = isReady ? "Waiting" : "Starting"
        }
        debugSnapshot = PlayerDebugSnapshot(
            engine: "VLC",
            state: state,
            displayFPS: measuredDisplayFPS.flatMap { $0 > 0 ? $0 : nil },
            nominalFPS: nil,
            droppedFrames: max(Int(statistics.lostPictures), 0)
                + (activeBoundedRenderer ? Int(clamping: boundedDroppedFrames) : 0),
            droppedPackets: nil,
            stalls: debugStallCount,
            bufferSeconds: nil,
            hardwareAcceleration: activeBoundedRenderer
                ? "VT pixel bridge" : "VT preferred"
        )
    }
}

#if targetEnvironment(simulator)
/// Full libVLC logging is intentionally simulator-only and opt-in: generating
/// every decoder log can itself perturb frame pacing. Keep just the messages
/// needed to prove which decoder path libVLC selected.
private final class VLCDecoderLogger: NSObject, VLCLogging {
    var level = VLCLogLevel(rawValue: 3)!

    func handleMessage(
        _ message: String,
        logLevel: VLCLogLevel,
        context: VLCLogContext?
    ) {
        let lowercase = message.lowercased()
        let module = context?.module.lowercased() ?? ""
        guard lowercase.contains("videotoolbox")
                || lowercase.contains("video toolbox")
                || lowercase.contains("hardware decoding")
                || lowercase.contains("video decoder module")
                || (module.contains("avcodec") && lowercase.contains("codec"))
        else { return }
        NSLog(
            "VLC_DECODER level=%d module=%@ message=%@",
            logLevel.rawValue,
            context?.module ?? "unknown",
            message
        )
    }
}
#endif

private enum VLCPlaybackError: LocalizedError {
    case playerError
    case startupTimedOut
    case unexpectedShortVideo(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .playerError:
            "VLC could not open this stream."
        case .startupTimedOut:
            "VLC returned no playable audio or video within 15 seconds."
        case let .unexpectedShortVideo(duration):
            "VLC opened only a short \(String(format: "%.1f", duration))-second response."
        }
    }
}

private struct VLCPlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var watchTogether = WatchTogetherCoordinator.shared
    let title: String
    private let plan: PlaybackPlan
    private let watchTogetherContent: WatchTogetherContent
    private let minimumVideoDuration: TimeInterval
    private let onExhausted: (@MainActor (Error) -> Void)?
    private let playbackPolicy: PlaybackPerformancePolicy
    @StateObject private var model: VLCPlaybackModel
    @State private var controlsVisible = true
    @State private var attemptRevision = 0
    @State private var isScrubbing = false
    @State private var scrubPosition: TimeInterval = 0
    @State private var resumeAfterScrub = false
    @State private var watchTogetherAttachmentToken = UUID()
    @AppStorage(PlayerDebugPreferences.overlayEnabledKey)
    private var debugOverlaySetting = false

    init(
        plan: PlaybackPlan,
        title: String,
        watchTogetherContent: WatchTogetherContent? = nil,
        minimumVideoDuration: TimeInterval,
        onExhausted: (@MainActor (Error) -> Void)?
    ) {
        let policy = PlaybackPerformanceCore.policy(
            url: plan.primaryURL,
            title: title,
            player: .vlcKit
        )
        self.plan = plan
        self.title = title
        self.watchTogetherContent = watchTogetherContent
            ?? WatchTogetherContent(title: title)
        self.minimumVideoDuration = minimumVideoDuration
        self.onExhausted = onExhausted
        playbackPolicy = policy
        _model = StateObject(wrappedValue: VLCPlaybackModel(policy: policy))
    }

    var body: some View {
        ZStack {
            VLCRenderView(
                player: model.player,
                usesBoundedRenderer: usesBoundedRenderer,
                onFirstFrame: model.markRenderedFrame,
                onFrameMetrics: model.recordBoundedFrameMetrics
            )
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { controlsVisible.toggle() }

            if !model.isReady, model.failureMessage == nil {
                VStack(spacing: 12) {
                    ProgressView().tint(.orange)
                    Text("Starting video…")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(22)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityIdentifier("player-startup-status")
            }

            if let message = model.failureMessage {
                playbackFailure(message: message)
            } else if controlsVisible {
                controls
                    .transition(.opacity)
            }

            if debugOverlayEnabled {
                PlayerDebugOverlay(snapshot: model.debugSnapshot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .animation(.easeOut(duration: 0.18), value: controlsVisible)
        .task(id: attemptRevision) { await startPlayback() }
        .task(id: "debug-\(debugOverlayEnabled)-\(attemptRevision)") {
            await logPlayerDebug()
        }
        .onDisappear {
            WatchTogetherCoordinator.shared.detach(token: watchTogetherAttachmentToken)
            model.stop()
            PlayerPresentation.endAudioSession()
            PlayerPresentation.restorePortrait()
        }
        .accessibilityIdentifier("stremio-player")
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                controlButton("xmark", label: "Close player") { dismiss() }
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                WatchTogetherMenu(content: watchTogetherContent)
                controlButton("rectangle.landscape.rotate", label: "Rotate player") {
                    PlayerPresentation.toggleOrientation()
                }
            }
            .padding()
            .background(.linearGradient(
                colors: [.black.opacity(0.82), .clear],
                startPoint: .top,
                endPoint: .bottom
            ))

            Spacer()

            HStack(spacing: 34) {
                controlButton("gobackward.10", label: "Back 10 seconds") {
                    seekVLC(by: -10)
                }
                controlButton(
                    model.isPlaying ? "pause.fill" : "play.fill",
                    label: model.isPlaying ? "Pause" : "Play",
                    size: 26
                ) {
                    if model.isPlaying {
                        if !watchTogether.requestPause(
                            for: watchTogetherContent.identifier
                        ) {
                            model.pause()
                        }
                    } else if !watchTogether.requestPlay(
                        for: watchTogetherContent.identifier
                    ) {
                        model.play()
                    }
                }
                controlButton("goforward.10", label: "Forward 10 seconds") {
                    seekVLC(by: 10)
                }
            }

            Spacer()

            VStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubPosition : model.currentTime },
                        set: { scrubPosition = $0 }
                    ),
                    in: 0...max(model.duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            isScrubbing = true
                            scrubPosition = model.currentTime
                            resumeAfterScrub = model.player.isPlaying
                            if resumeAfterScrub {
                                if !watchTogether.requestPause(
                                    for: watchTogetherContent.identifier
                                ) {
                                    model.pause()
                                }
                            }
                        } else {
                            let target = scrubPosition
                            isScrubbing = false
                            if !watchTogether.requestSeek(
                                to: target,
                                resumeAfterSeek: resumeAfterScrub,
                                for: watchTogetherContent.identifier
                            ) {
                                model.seek(to: target)
                                if resumeAfterScrub {
                                    model.play()
                                }
                            }
                        }
                    }
                )
                .tint(.orange)
                .disabled(model.duration <= 0 || !model.player.isSeekable)
                .accessibilityIdentifier("player-timeline")

                HStack {
                    Text(formatTime(isScrubbing ? scrubPosition : model.currentTime))
                    Spacer()
                    Text(formatTime(model.duration))
                }
                .font(.caption.monospacedDigit())
            }
            .padding()
            .background(.linearGradient(
                colors: [.clear, .black.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            ))
        }
        .foregroundStyle(.white)
        .accessibilityIdentifier("player-controls")
    }

    private func seekVLC(by interval: TimeInterval) {
        let target = min(
            max(model.currentTime + interval, 0),
            max(model.duration, 0)
        )
        if !watchTogether.requestSeek(
            to: target,
            resumeAfterSeek: model.isPlaying,
            for: watchTogetherContent.identifier
        ) {
            model.seek(to: target)
        }
    }

    private func controlButton(
        _ systemName: String,
        label: String,
        size: CGFloat = 18,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.48), in: Circle())
        }
        .accessibilityLabel(label)
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
                model.failureMessage = nil
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
    private func startPlayback() async {
        PlayerPresentation.prepareAudioSession()
        let startupStartedAt = ProcessInfo.processInfo.systemUptime
        do {
            try await model.start(
                url: plan.primaryURL,
                minimumVideoDuration: minimumVideoDuration,
                usesBoundedRenderer: usesBoundedRenderer
            )
            attachWatchTogether()
            let elapsed = (ProcessInfo.processInfo.systemUptime - startupStartedAt) * 1_000
            NSLog(
                "PLAYER_BENCHMARK playing_ms=%.1f engine=vlckit title=%@",
                elapsed,
                title
            )
            if usesBoundedRenderer {
                NSLog("VLC_FRAME_BRIDGE active title=%@", title)
            }
            await runVerificationIfRequested()
        } catch {
            model.stop()
            if let onExhausted {
                onExhausted(error)
            } else {
                model.failureMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func attachWatchTogether() {
        WatchTogetherCoordinator.shared.attach(
            adapter: WatchTogetherPlaybackAdapter(
                content: watchTogetherContent,
                currentTime: { model.currentTime },
                duration: { model.duration },
                isPlaying: { model.player.isPlaying },
                isReady: { model.isReady },
                play: { model.play() },
                pause: { model.pause() },
                seek: { target in await model.seekAndWait(to: target) }
            ),
            token: watchTogetherAttachmentToken
        )
    }

    @MainActor
    private func runVerificationIfRequested() async {
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["SKELETON_PLAYER_PARITY_SMOKE"] == "1"
        else { return }

        let startedAt = model.currentTime
        for _ in 0..<20 {
            if model.currentTime >= startedAt + 0.35 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let renderedFrame = usesBoundedRenderer
            ? model.hasRenderedFrame
            : model.player.hasVideoOut
        guard renderedFrame, model.currentTime >= startedAt + 0.35 else {
            NSLog("PLAYER_PARITY FAIL player=vlckit step=autoplay-or-visible-frame")
            return
        }

        let seekTarget = model.duration > 600
            ? 120
            : min(max(model.duration * 0.5, 5), 30)
        model.seek(to: seekTarget)
        // A remote range seek updates LibVLC's clock before the decoder has a
        // post-seek frame. Wait for real forward progress so the pause/resume
        // check does not race the network refill.
        var seekRecoveredAt = TimeInterval(model.player.time.intValue) / 1_000
        for _ in 0..<150 {
            seekRecoveredAt = TimeInterval(model.player.time.intValue) / 1_000
            if model.player.isPlaying, seekRecoveredAt >= seekTarget + 0.35 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard model.player.isPlaying, seekRecoveredAt >= seekTarget + 0.35 else {
            NSLog("PLAYER_PARITY FAIL player=vlckit step=seek")
            return
        }

        // Seeking a remote file can transiently report `isPlaying == false`
        // while VLC refills. Resume first, then exercise an explicit pause.
        if !model.player.isPlaying { model.player.play() }
        for _ in 0..<40 {
            if model.player.isPlaying { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard model.player.isPlaying else {
            NSLog("PLAYER_PARITY FAIL player=vlckit step=post-seek-resume")
            return
        }

        model.player.pause()
        // LibVLC's `isPlaying` can remain true while a remote seek settles even
        // though the rendered clock is paused. Verify the user-visible behavior
        // directly: the media clock must stay fixed for a full second.
        try? await Task.sleep(for: .milliseconds(700))
        var pausedAt = TimeInterval(model.player.time.intValue) / 1_000
        try? await Task.sleep(for: .milliseconds(1_000))
        let pausedEnd = TimeInterval(model.player.time.intValue) / 1_000
        guard abs(pausedEnd - pausedAt) < 0.35 else {
            NSLog("PLAYER_PARITY FAIL player=vlckit step=pause-clock")
            return
        }
        pausedAt = pausedEnd

        model.player.play()
        for _ in 0..<120 {
            let currentTime = TimeInterval(model.player.time.intValue) / 1_000
            if currentTime >= pausedAt + 0.35 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let resumedAt = TimeInterval(model.player.time.intValue) / 1_000
        guard model.player.isPlaying, resumedAt >= pausedAt + 0.35 else {
            NSLog("PLAYER_PARITY FAIL player=vlckit step=resume")
            return
        }

        NSLog(
            "PLAYER_PARITY PASS player=vlckit autoplay=yes frame=yes seek=yes pause=yes resume=yes duration=%.1f",
            model.duration
        )
        #endif
    }

    private func formatTime(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let total = Int(value.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var usesBoundedRenderer: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["SKELETON_VLC_BOUNDED_RENDERER"] == "1" {
            return true
        }
        return playbackPolicy.usesBoundedRenderer
    }

    private var debugOverlayEnabled: Bool {
        debugOverlaySetting || PlayerDebugPreferences.environmentForcesOverlay
    }

    @MainActor
    private func logPlayerDebug() async {
        model.setDebugMetricsEnabled(debugOverlayEnabled)
        guard debugOverlayEnabled else { return }
        defer { model.setDebugMetricsEnabled(false) }
        while !Task.isCancelled {
            model.sampleDebugMetrics()
            NSLog("PLAYER_DEBUG %@", model.debugSnapshot.logDescription)
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
#endif

/// Adaptive player backed by the Rust policy core. It keeps Apple-native
/// streams on AVFoundation, sends relabeled/direct containers through
/// KSPlayer's FFmpeg/VideoToolbox path, and uses the bounded VLC bridge for
/// HEVC and unusually large output surfaces.
private struct PerformancePlayerScreen: View {
    let title: String
    private let plan: PlaybackPlan
    private let watchTogetherContent: WatchTogetherContent
    private let minimumVideoDuration: TimeInterval
    private let onExhausted: (@MainActor (Error) -> Void)?
    private let policy: PlaybackPerformancePolicy

    init(
        plan: PlaybackPlan,
        title: String,
        watchTogetherContent: WatchTogetherContent,
        minimumVideoDuration: TimeInterval,
        onExhausted: (@MainActor (Error) -> Void)?
    ) {
        self.plan = plan
        self.title = title
        self.watchTogetherContent = watchTogetherContent
        self.minimumVideoDuration = minimumVideoDuration
        self.onExhausted = onExhausted
        policy = PlaybackPerformanceCore.policy(
            url: plan.primaryURL,
            title: [title, plan.detectedMIMEType].compactMap { $0 }.joined(separator: " "),
            player: .performance
        )
    }

    @ViewBuilder
    var body: some View {
        switch policy.decoder {
        case .avFoundation:
            AVPlayerScreen(
                plan: plan,
                title: title,
                watchTogetherContent: watchTogetherContent,
                minimumVideoDuration: minimumVideoDuration,
                onExhausted: onExhausted
            )
        case .vlcVideoToolboxBridge:
            #if canImport(MobileVLCKit)
            VLCPlayerScreen(
                plan: plan,
                title: title,
                watchTogetherContent: watchTogetherContent,
                minimumVideoDuration: minimumVideoDuration,
                onExhausted: onExhausted
            )
            #else
            performanceKSPlayer
            #endif
        case .automatic, .ffmpegVideoToolbox:
            performanceKSPlayer
        }
    }

    @ViewBuilder
    private var performanceKSPlayer: some View {
        #if canImport(KSPlayer)
        KSPlayerScreen(
            plan: plan,
            title: title,
            watchTogetherContent: watchTogetherContent,
            minimumVideoDuration: minimumVideoDuration,
            onExhausted: onExhausted
        )
        #else
        AVPlayerScreen(
            plan: plan,
            title: title,
            watchTogetherContent: watchTogetherContent,
            minimumVideoDuration: minimumVideoDuration,
            onExhausted: onExhausted
        )
        #endif
    }
}

private enum StremioPlayerBridge {
    static func order(
        preferred: StremioInternalPlayer,
        sourceURL: URL,
        title: String
    ) -> [StremioInternalPlayer] {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["SKELETON_PLAYER_STRICT"] == "1" {
            return [preferred]
        }
        #endif
        let pathExtension = sourceURL.pathExtension.lowercased()
        let sourceHint = "\(sourceURL.path) \(title)".lowercased()
        let fallbacks: [StremioInternalPlayer]
        if ["4320p", "8k", "ai upscale"].contains(where: sourceHint.contains) {
            // The bounded LibVLC callback renderer keeps oversized sources on
            // VLC while limiting only the final decoded frame surface.
            fallbacks = [.vlcKit, .ksPlayer, .avPlayer]
        } else if ["mkv", "webm", "avi"].contains(pathExtension)
            || ["x265", "hevc", "av1", "flac"].contains(where: sourceHint.contains) {
            fallbacks = [.ksPlayer, .vlcKit, .avPlayer]
        } else if ["m3u8", "mp4", "mov", "m4v"].contains(pathExtension)
            || ["hls", "h264", "avc", "aac"].contains(where: sourceHint.contains) {
            fallbacks = [.avPlayer, .vlcKit, .ksPlayer]
        } else {
            fallbacks = [.vlcKit, .ksPlayer, .avPlayer]
        }
        return ([preferred] + fallbacks).reduce(into: []) { result, player in
            if !result.contains(player) { result.append(player) }
        }
    }
}

struct PlayerScreen: View {
    @ObservedObject private var watchTogether = WatchTogetherCoordinator.shared
    let title: String
    private let plan: PlaybackPlan
    private let watchTogetherContent: WatchTogetherContent
    private let minimumVideoDuration: TimeInterval
    private let onExhausted: (@MainActor (Error) -> Void)?
    private let playerOrder: [StremioInternalPlayer]
    @State private var activePlayerIndex = 0
    @State private var bridgeFailureMessage: String?
    @State private var bridgeRevision = 0
    @State private var bridgeNotice: String?

    init(
        plan: PlaybackPlan,
        title: String,
        contentIdentifier: String? = nil,
        contentTitle: String? = nil,
        minimumVideoDuration: TimeInterval = 4,
        onExhausted: (@MainActor (Error) -> Void)? = nil
    ) {
        self.plan = plan
        self.title = title
        watchTogetherContent = WatchTogetherContent(
            identifier: contentIdentifier,
            title: contentTitle ?? title
        )
        self.minimumVideoDuration = minimumVideoDuration
        self.onExhausted = onExhausted
        playerOrder = StremioPlayerBridge.order(
            preferred: StremioInternalPlayer.selected,
            sourceURL: plan.primaryURL,
            title: [title, plan.detectedMIMEType].compactMap { $0 }.joined(separator: " ")
        )
    }

    init(url: URL, title: String) {
        self.init(
            plan: PlaybackPlan(primaryURL: url, fallbackURL: nil),
            title: title
        )
    }

    @ViewBuilder
    var body: some View {
        ZStack(alignment: .top) {
            if let bridgeFailureMessage {
                bridgeFailure(message: bridgeFailureMessage)
            } else {
                playerView(for: activePlayer)
                    .id("\(activePlayer.rawValue)-\(bridgeRevision)")
            }

            if let bridgeNotice {
                Text(bridgeNotice)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.black.opacity(0.78), in: Capsule())
                    .padding(.top, 12)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("player-bridge-status")
            }

            if let action = watchTogether.lastActionText {
                Text(action)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.green.opacity(0.84), in: Capsule())
                    .padding(.top, bridgeNotice == nil ? 12 : 54)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("watch-together-action")
            }
        }
        .alert(
            "Watch Together",
            isPresented: Binding(
                get: { watchTogether.errorMessage != nil },
                set: { if !$0 { watchTogether.errorMessage = nil } }
            )
        ) {
            Button("OK") { watchTogether.errorMessage = nil }
        } message: {
            Text(watchTogether.errorMessage ?? "SharePlay is unavailable.")
        }
    }

    private var activePlayer: StremioInternalPlayer {
        playerOrder[min(activePlayerIndex, playerOrder.count - 1)]
    }

    @ViewBuilder
    private func playerView(for player: StremioInternalPlayer) -> some View {
        if shouldForceFailure(of: player) {
            PlayerBridgeForcedFailureView(player: player) { error in
                handlePlayerFailure(player: player, error: error)
            }
        } else {
            switch player {
        case .performance:
            PerformancePlayerScreen(
                plan: plan,
                title: title,
                watchTogetherContent: watchTogetherContent,
                minimumVideoDuration: minimumVideoDuration,
                onExhausted: { handlePlayerFailure(player: player, error: $0) }
            )
        case .ksPlayer:
            #if canImport(KSPlayer)
            KSPlayerScreen(
                plan: plan,
                title: title,
                watchTogetherContent: watchTogetherContent,
                minimumVideoDuration: minimumVideoDuration,
                onExhausted: { handlePlayerFailure(player: player, error: $0) }
            )
            #else
            PlayerBridgeForcedFailureView(player: player) { error in
                handlePlayerFailure(player: player, error: error)
            }
            #endif
        case .vlcKit:
            #if canImport(MobileVLCKit)
            VLCPlayerScreen(
                plan: plan,
                title: title,
                watchTogetherContent: watchTogetherContent,
                minimumVideoDuration: minimumVideoDuration,
                onExhausted: { handlePlayerFailure(player: player, error: $0) }
            )
            #else
            PlayerBridgeForcedFailureView(player: player) { error in
                handlePlayerFailure(player: player, error: error)
            }
            #endif
        case .avPlayer:
            AVPlayerScreen(
                plan: plan,
                title: title,
                watchTogetherContent: watchTogetherContent,
                minimumVideoDuration: minimumVideoDuration,
                onExhausted: { handlePlayerFailure(player: player, error: $0) }
            )
            }
        }
    }

    @ViewBuilder
    private func bridgeFailure(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "play.slash")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Playback unavailable").font(.title3.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry all players") {
                activePlayerIndex = 0
                bridgeFailureMessage = nil
                bridgeNotice = nil
                bridgeRevision += 1
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(28)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 22))
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .accessibilityIdentifier("player-bridge-error")
    }

    @MainActor
    private func handlePlayerFailure(
        player: StremioInternalPlayer,
        error: Error
    ) {
        guard player == activePlayer else { return }
        NSLog(
            "PLAYER_BRIDGE engine_failed=%@ error=%@",
            player.rawValue,
            error.localizedDescription
        )
        let nextIndex = activePlayerIndex + 1
        guard playerOrder.indices.contains(nextIndex) else {
            if let onExhausted {
                onExhausted(error)
            } else {
                bridgeFailureMessage = "Performance, KSPlayer, VLC, and AVPlayer could not play this stream. Try another source."
            }
            return
        }

        let nextPlayer = playerOrder[nextIndex]
        activePlayerIndex = nextIndex
        bridgeRevision += 1
        bridgeNotice = "Switched to \(nextPlayer.title)"
        NSLog(
            "PLAYER_BRIDGE fallback from=%@ to=%@",
            player.rawValue,
            nextPlayer.rawValue
        )
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            bridgeNotice = nil
        }
    }

    private func shouldForceFailure(of player: StremioInternalPlayer) -> Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["SKELETON_PLAYER_BRIDGE_FAIL"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .contains(player.rawValue) == true
        #else
        false
        #endif
    }
}

#if targetEnvironment(simulator)
private struct PlayerBridgeForcedFailureView: View {
    let player: StremioInternalPlayer
    let onFailure: @MainActor (Error) -> Void

    var body: some View {
        ProgressView("Testing \(player.title) fallback…")
            .task {
                onFailure(
                    NSError(
                        domain: "StremioSkeleton.PlayerBridgeTest",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Forced simulator failure"]
                    )
                )
            }
    }
}
#else
private struct PlayerBridgeForcedFailureView: View {
    let player: StremioInternalPlayer
    let onFailure: @MainActor (Error) -> Void

    var body: some View { EmptyView() }
}
#endif

struct StreamPlaybackCandidate: Identifiable {
    let stream: Stream
    let providerName: String?
    let contentIdentifier: String?
    let contentTitle: String?

    init(
        stream: Stream,
        providerName: String?,
        contentIdentifier: String? = nil,
        contentTitle: String? = nil
    ) {
        self.stream = stream
        self.providerName = providerName
        self.contentIdentifier = contentIdentifier
        self.contentTitle = contentTitle
    }

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
                    contentIdentifier: activeCandidate.contentIdentifier,
                    contentTitle: activeCandidate.contentTitle,
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

}

private struct PlayerOverlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 42, height: 42)
            .background(.black.opacity(configuration.isPressed ? 0.9 : 0.68), in: Circle())
            .contentShape(Circle())
    }
}
