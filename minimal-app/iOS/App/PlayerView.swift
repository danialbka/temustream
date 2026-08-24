@preconcurrency import AVKit
@preconcurrency import CoreMedia
import SwiftUI
import UIKit
#if canImport(KSPlayer)
@preconcurrency import KSPlayer
#endif
#if canImport(MobileVLCKit)
@preconcurrency import MobileVLCKit
#endif

typealias PlaybackProgressHandler = @MainActor (
    _ position: TimeInterval,
    _ duration: TimeInterval,
    _ updateKind: PlaybackProgressUpdateKind
) -> Void

typealias PlaybackControlsVisibilityHandler = @MainActor (_ isVisible: Bool) -> Void

/// Mutable playback progress that does not participate in SwiftUI observation.
/// Checkpoint updates must never recreate the active decoder or its parent view.
@MainActor
private final class PlaybackProgressReference {
    var position: TimeInterval
    var duration: TimeInterval

    init(position: TimeInterval, duration: TimeInterval = 0) {
        self.position = max(position, 0)
        self.duration = max(duration, 0)
    }

    func update(position: TimeInterval, duration: TimeInterval) {
        guard position.isFinite, duration.isFinite else { return }
        if position >= 1 || self.position <= 0 {
            self.position = max(position, 0)
        }
        self.duration = max(duration, 0)
    }
}

enum StremioInternalPlayer: String, CaseIterable, Identifiable, Sendable {
    case bunny = "bunny"
    case performance = "performance"
    case ksPlayer = "ksplayer"
    case vlcKit = "vlckit"

    private static let preferenceKey = "preferredInternalPlayer"
    private static let legacyAVPlayerKey = "useAVPlayer"
    private static let legacyVLCKey = "useVLCKit"
    private static let removedAVPlayerRawValue = "avplayer"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .performance: "Performance"
        case .bunny: "Bunny"
        case .ksPlayer: "KSPlayer"
        case .vlcKit: "VLC"
        }
    }

    var detail: String {
        switch self {
        case .performance: "Rust policy + hardware decode"
        case .bunny: "Custom Apple + FFmpeg decoder"
        case .ksPlayer: "Official Stremio default"
        case .vlcKit: "Native fast path + VLC compatibility"
        }
    }

    var controlsSummary: String {
        switch self {
        case .performance: "Adaptive controls / PiP"
        case .bunny: "Custom controls / PiP / tracks"
        case .ksPlayer: "PiP / audio / subtitles"
        case .vlcKit: "Seek / tracks / mute / rotate"
        }
    }

    static var selected: Self {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["SKELETON_INTERNAL_PLAYER"],
           let player = Self(rawValue: override.lowercased()) {
            return player
        }
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: preferenceKey) {
            if stored == removedAVPlayerRawValue {
                migrateRemovedAVPlayerPreference(defaults: defaults)
                return .bunny
            }
            if let player = Self(rawValue: stored) { return player }
        }
        if defaults.bool(forKey: legacyAVPlayerKey) {
            migrateRemovedAVPlayerPreference(defaults: defaults)
            return .bunny
        }
        if defaults.bool(forKey: legacyVLCKey) { return .vlcKit }
        return .bunny
    }

    static func select(_ player: Self) {
        let defaults = UserDefaults.standard
        defaults.set(player.rawValue, forKey: preferenceKey)
        defaults.set(false, forKey: legacyAVPlayerKey)
        defaults.set(player == .vlcKit, forKey: legacyVLCKey)
    }

    private static func migrateRemovedAVPlayerPreference(defaults: UserDefaults) {
        defaults.set(Self.bunny.rawValue, forKey: preferenceKey)
        defaults.set(false, forKey: legacyAVPlayerKey)
        defaults.set(false, forKey: legacyVLCKey)
    }
}

enum PlayerDebugPreferences {
    static let overlayEnabledKey = "playerDebugOverlayEnabled"

    static var environmentForcesOverlay: Bool {
        ProcessInfo.processInfo.environment["SKELETON_PLAYER_DEBUG_OVERLAY"] == "1"
    }
}

struct SubtitleVisualStyle {
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 5

    let value: SubtitleStyle

    init(_ value: SubtitleStyle = SubtitleStylePreferences.current()) {
        self.value = value
    }

    var uiFont: UIFont {
        let base = UIFont.systemFont(
            ofSize: CGFloat(value.size.pointSize),
            weight: uiFontWeight
        )
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
    }

    var font: Font { Font(uiFont) }

    var color: Color { Color(uiColor: uiColor) }

    var uiColor: UIColor {
        UIColor(
            red: CGFloat(value.color.redComponent),
            green: CGFloat(value.color.greenComponent),
            blue: CGFloat(value.color.blueComponent),
            alpha: 1
        )
    }

    var backgroundColor: Color {
        .black.opacity(value.backgroundOpacity)
    }

    var shadowColor: Color {
        value.shadowEnabled ? .black.opacity(0.95) : .clear
    }

    var vlcOptions: [String] {
        let opacity = Int((value.backgroundOpacity * 255).rounded())
        let shadowOpacity = value.shadowEnabled ? 255 : 0
        var options = [
            "--sub-text-scale=\(value.size.relativeScalePercent)",
            "--freetype-color=0x\(value.color.hexRGB)",
            "--freetype-background-color=0x000000",
            "--freetype-background-opacity=\(opacity)",
            "--freetype-shadow-color=0x000000",
            "--freetype-shadow-opacity=\(shadowOpacity)",
        ]
        if value.weight == .bold {
            options.append("--freetype-bold")
        }
        return options
    }

    var avTextStyleRules: [AVTextStyleRule] {
        let edgeStyle = (value.shadowEnabled
            ? kCMTextMarkupCharacterEdgeStyle_DropShadow
            : kCMTextMarkupCharacterEdgeStyle_None) as String
        let foreground: [NSNumber] = [
            1,
            NSNumber(value: value.color.redComponent),
            NSNumber(value: value.color.greenComponent),
            NSNumber(value: value.color.blueComponent),
        ]
        let background: [NSNumber] = [
            NSNumber(value: value.backgroundOpacity), 0, 0, 0,
        ]
        let attributes: [String: Any] = [
            kCMTextMarkupAttribute_ForegroundColorARGB as String: foreground,
            kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String: background,
            kCMTextMarkupAttribute_BoldStyle as String: NSNumber(
                value: value.weight != .regular
            ),
            kCMTextMarkupAttribute_RelativeFontSize as String: NSNumber(
                value: value.size.relativeScalePercent
            ),
            kCMTextMarkupAttribute_CharacterEdgeStyle as String: edgeStyle,
        ]
        guard let rule = AVTextStyleRule(textMarkupAttributes: attributes) else {
            return []
        }
        return [rule]
    }

    private var uiFontWeight: UIFont.Weight {
        switch value.weight {
        case .regular: .regular
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

@propertyWrapper
struct SubtitleStyleStorage: DynamicProperty {
    @AppStorage(SubtitleStylePreferences.sizeKey)
    private var sizeRawValue = SubtitleStyle.default.size.rawValue
    @AppStorage(SubtitleStylePreferences.colorKey)
    private var colorRawValue = SubtitleStyle.default.color.rawValue
    @AppStorage(SubtitleStylePreferences.weightKey)
    private var weightRawValue = SubtitleStyle.default.weight.rawValue
    @AppStorage(SubtitleStylePreferences.backgroundOpacityKey)
    private var backgroundOpacity = SubtitleStyle.default.backgroundOpacity
    @AppStorage(SubtitleStylePreferences.shadowEnabledKey)
    private var shadowEnabled = SubtitleStyle.default.shadowEnabled

    var wrappedValue: SubtitleVisualStyle {
        SubtitleVisualStyle(
            SubtitleStyle(
                sizeRawValue: sizeRawValue,
                colorRawValue: colorRawValue,
                weightRawValue: weightRawValue,
                backgroundOpacity: backgroundOpacity,
                shadowEnabled: shadowEnabled
            )
        )
    }
}

struct StyledSubtitleText: View {
    let text: AttributedString
    let style: SubtitleVisualStyle

    init(_ text: String, style: SubtitleVisualStyle) {
        self.text = AttributedString(text)
        self.style = style
    }

    init(_ text: AttributedString, style: SubtitleVisualStyle) {
        self.text = text
        self.style = style
    }

    var body: some View {
        Text(text)
            .font(style.font)
            .multilineTextAlignment(.center)
            .foregroundStyle(style.color)
            .padding(.horizontal, SubtitleVisualStyle.horizontalPadding)
            .padding(.vertical, SubtitleVisualStyle.verticalPadding)
            .background(
                style.backgroundColor,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .shadow(color: style.shadowColor, radius: 2, x: 0, y: 1)
    }
}

@MainActor
func applySubtitleStyle(
    to item: AVPlayerItem,
    style: SubtitleStyle = SubtitleStylePreferences.current()
) {
    item.textStyleRules = SubtitleVisualStyle(style).avTextStyleRules
}

@MainActor
func applyPlaybackLanguagePreferences(to item: AVPlayerItem) async {
    let asset = item.asset
    let audioGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
    let subtitleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)

    if let audioGroup,
       let preferredAudio = preferredAVMediaOption(
            in: audioGroup,
            language: PlaybackLanguagePreferences.preferredAudioLanguage()
       ) {
        item.select(preferredAudio, in: audioGroup)
    }

    if let subtitleGroup {
        if PlaybackLanguagePreferences.subtitlesEnabled(),
           let preferredSubtitle = preferredAVMediaOption(
                in: subtitleGroup,
                language: PlaybackLanguagePreferences.preferredSubtitleLanguage()
           ) {
            item.select(preferredSubtitle, in: subtitleGroup)
        } else {
            item.select(nil, in: subtitleGroup)
        }
    }
}

@MainActor
func rememberPlaybackLanguageSelections(from item: AVPlayerItem) async {
    let asset = item.asset
    let audioGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
    let subtitleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)

    if let audioGroup,
       let selected = item.currentMediaSelection.selectedMediaOption(in: audioGroup) {
        PlaybackLanguagePreferences.rememberAudioSelection(
            languageTag: selected.extendedLanguageTag ?? selected.locale?.identifier,
            displayName: selected.displayName
        )
    }

    if let subtitleGroup,
       let selected = item.currentMediaSelection.selectedMediaOption(in: subtitleGroup) {
        PlaybackLanguagePreferences.rememberSubtitleSelection(
            languageTag: selected.extendedLanguageTag ?? selected.locale?.identifier,
            displayName: selected.displayName
        )
    } else if subtitleGroup != nil {
        PlaybackLanguagePreferences.rememberSubtitlesDisabled()
    }
}

@MainActor
private func preferredAVMediaOption(
    in group: AVMediaSelectionGroup,
    language: String
) -> AVMediaSelectionOption? {
    let options = group.options.map {
        PlaybackLanguageOption(
            languageTag: $0.extendedLanguageTag ?? $0.locale?.identifier,
            displayName: $0.displayName
        )
    }
    guard let index = PlaybackLanguageMatcher.bestMatchIndex(
        in: options,
        preferredLanguage: language
    ) else { return nil }
    return group.options[index]
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
            NSLog("Player orientation update failed: %@", error.localizedDescription)
        }
    }

    /// Player engines can be replaced without leaving PlayerScreen. Match the
    /// orientation mask to the geometry already on screen so an outgoing
    /// engine cannot force the incoming controls through a second, stale
    /// portrait layout pass.
    static func synchronizeWithCurrentOrientation() {
        guard let scene = foregroundScene else { return }
        let orientation = scene.effectiveGeometry.interfaceOrientation
        guard orientation != .unknown else { return }
        AppOrientationDelegate.supportedOrientations = orientation.isLandscape
            ? .landscape
            : .portrait
        scene.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
        NSLog(
            "PLAYER_LAYOUT synchronized orientation=%@",
            orientation.isLandscape ? "landscape" : "portrait"
        )
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

/// Shared fit/fill interaction used by every internal player. A two-finger
/// pinch commits to one of two stable presentation modes instead of leaving
/// the video at an arbitrary zoom level. The small pill confirms the change
/// without covering the center controls or debug overlay.
private struct PlaybackViewportInteractionModifier: ViewModifier {
    @Binding var mode: PlaybackViewportMode
    @State private var feedbackVisible = false
    @State private var feedbackRevision = 0

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                MagnificationGesture()
                    .onEnded { magnification in
                        let updated = mode.applying(
                            magnification: Double(magnification)
                        )
                        if updated != mode {
                            mode = updated
                        }
                    }
            )
            .overlay(alignment: .topTrailing) {
                if feedbackVisible {
                    Label(
                        mode == .fill ? "Fill screen" : "Fit video",
                        systemImage: mode == .fill
                            ? "arrow.up.left.and.arrow.down.right"
                            : "arrow.down.right.and.arrow.up.left"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.78), in: Capsule())
                    .padding(.top, 64)
                    .padding(.trailing, 14)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("player-content-mode-status")
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
            .onChange(of: mode) { _ in
                showFeedback()
            }
            .animation(.easeOut(duration: 0.16), value: feedbackVisible)
    }

    @MainActor
    private func showFeedback() {
        feedbackRevision += 1
        let revision = feedbackRevision
        feedbackVisible = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_100))
            guard revision == feedbackRevision else { return }
            feedbackVisible = false
        }
    }
}

private extension View {
    func playbackViewportInteraction(
        mode: Binding<PlaybackViewportMode>
    ) -> some View {
        modifier(PlaybackViewportInteractionModifier(mode: mode))
    }
}

#if canImport(KSPlayer)
/// KSPlayer path matching the official Stremio default. Direct containers use
/// its FFmpeg engine; HLS stays inside KSPlayer but uses KSAVPlayer because its
/// segmented seeking is substantially more reliable than FFmpeg's HLS demuxer.
struct KSPlayerScreen: View {
    let title: String
    private let plan: PlaybackPlan
    private let minimumVideoDuration: TimeInterval
    private let onProgress: PlaybackProgressHandler?
    private let onExhausted: (@MainActor (Error) -> Void)?
    private let watchChannel: WatchPlaybackControlChannel?
    private let onControlsVisibilityChanged: PlaybackControlsVisibilityHandler?
    @State private var attemptRevision = 0
    @State private var failureMessage: String?
    @State private var automaticRetryCount = 0
    @State private var retryPosition: TimeInterval = 0

    init(
        plan: PlaybackPlan,
        title: String,
        initialPosition: TimeInterval = 0,
        minimumVideoDuration: TimeInterval = 4,
        onProgress: PlaybackProgressHandler? = nil,
        watchChannel: WatchPlaybackControlChannel? = nil,
        onControlsVisibilityChanged: PlaybackControlsVisibilityHandler? = nil,
        onExhausted: (@MainActor (Error) -> Void)? = nil
    ) {
        self.plan = plan
        self.title = title
        self.minimumVideoDuration = minimumVideoDuration
        self.onProgress = onProgress
        self.watchChannel = watchChannel
        self.onControlsVisibilityChanged = onControlsVisibilityChanged
        self.onExhausted = onExhausted
        _retryPosition = State(initialValue: max(initialPosition, 0))
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
        ZStack(alignment: .bottomTrailing) {
            if failureMessage == nil {
                KSPlaybackAttempt(
                    url: candidate.url,
                    engine: candidate.engine,
                    title: title,
                    minimumVideoDuration: minimumVideoDuration,
                    initialPosition: retryPosition,
                    performancePolicy: playbackPolicy,
                    onProgress: onProgress,
                    watchChannel: watchChannel,
                    onControlsVisibilityChanged: onControlsVisibilityChanged,
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
        }
    }

    @ViewBuilder
    private func playbackFailure(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "play.slash")
                .font(.system(size: 44))
                .foregroundStyle(Color.appAccent)
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
            .tint(Color.appAccent)
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
    let minimumVideoDuration: TimeInterval
    let initialPosition: TimeInterval
    let performancePolicy: PlaybackPerformancePolicy
    let onProgress: PlaybackProgressHandler?
    let watchChannel: WatchPlaybackControlChannel?
    let onControlsVisibilityChanged: PlaybackControlsVisibilityHandler?
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
    @State private var didApplyAudioPreference = false
    @State private var didApplySubtitlePreference = false
    @State private var viewportMode = PlaybackViewportMode.fit
    @AppStorage(PlayerDebugPreferences.overlayEnabledKey)
    private var debugOverlaySetting = false
    @State private var debugSnapshot = PlayerDebugSnapshot.waiting(engine: "KSPlayer")
    @State private var watchRegistrationID: UUID?

    private let options: KSOptions

    init(
        url: URL,
        engine: StremioPlayerConfiguration.Engine,
        title: String,
        minimumVideoDuration: TimeInterval,
        initialPosition: TimeInterval,
        performancePolicy: PlaybackPerformancePolicy,
        onProgress: PlaybackProgressHandler?,
        watchChannel: WatchPlaybackControlChannel?,
        onControlsVisibilityChanged: PlaybackControlsVisibilityHandler?,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        self.url = url
        self.engine = engine
        self.title = title
        self.minimumVideoDuration = minimumVideoDuration
        self.initialPosition = initialPosition
        self.performancePolicy = performancePolicy
        self.onProgress = onProgress
        self.watchChannel = watchChannel
        self.onControlsVisibilityChanged = onControlsVisibilityChanged
        self.onFailure = onFailure

        self.options = StremioPlayerConfiguration.makeOptions(
            engine: engine,
            performancePolicy: performancePolicy,
            initialPosition: initialPosition
        )
    }

    var body: some View {
        ZStack {
            KSVideoPlayer(coordinator: coordinator, url: url, options: options)
                .onStateChanged { _, state in
                    playerState = state
                    if state == .paused {
                        // Mirror the engine state so the local stall watchdog
                        // never restarts a user-requested pause.
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
                    } else if let player = coordinator.playerLayer?.player {
                        let duration = player.duration
                        onProgress?(duration, duration, .final)
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

            if isAudioOnly, didProduceMedia {
                VStack(spacing: 14) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 68))
                        .foregroundStyle(Color.appAccent)
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
                        .tint(Color.appAccent)
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
                    wantsPlayback: $wantsPlayback,
                    viewportMode: $viewportMode,
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
        .playbackViewportInteraction(mode: $viewportMode)
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
            didRestorePosition = initialPosition <= 0 || engine == .ffmpeg
            if engine == .ffmpeg, initialPosition > 0 {
                NSLog(
                    "PLAYER_RESUME engine=ffmpeg mode=open target=%.1f",
                    initialPosition
                )
            }
            didAttemptStallRecovery = false
            didRunParityVerification = false
            didApplyAudioPreference = false
            didApplySubtitlePreference = false
            debugSnapshot = .waiting(engine: debugEngineName)
            viewportMode = .fit
            coordinator.isScaleAspectFill = false
            coordinator.isMaskShow = true
            onControlsVisibilityChanged?(true)
            registerWatchChannel()
            if startsLandscapeForVerification {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    PlayerPresentation.toggleOrientation()
                }
            }
        }
        .onChange(of: viewportMode) { mode in
            coordinator.isScaleAspectFill = mode == .fill
            NSLog("PLAYER_VIEWPORT engine=%@ mode=%@", debugEngineName, mode.rawValue)
        }
        .onChange(of: coordinator.isMaskShow) { isVisible in
            onControlsVisibilityChanged?(isVisible)
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
            var lastProgressReportAt = startedAt

            while !Task.isCancelled, !didReportFailure {
                try? await Task.sleep(for: .milliseconds(250))
                guard let layer = coordinator.playerLayer else { continue }

                let player = layer.player
                let now = ProcessInfo.processInfo.systemUptime
                let hasVideo = !player.tracks(mediaType: .video).isEmpty
                let hasAudio = !player.tracks(mediaType: .audio).isEmpty
                applyPreferredTracksIfAvailable(to: player)
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
                if now - lastProgressReportAt >= 5 {
                    lastProgressReportAt = now
                    onProgress?(currentTime, duration, .checkpoint)
                }
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
                    let postStartStallTimeout: TimeInterval = player.loadState == .loading
                        ? 30
                        : 15
                    if didProduceMedia,
                       now - lastProgressAt >= postStartStallTimeout {
                        NSLog(
                            "PLAYER_REPAIR stalled_after_start engine=%@ seconds=%.1f load=%@",
                            engine.rawValue,
                            now - lastProgressAt,
                            String(describing: player.loadState)
                        )
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
            if let watchRegistrationID { watchChannel?.unregister(watchRegistrationID) }
            if let player = coordinator.playerLayer?.player {
                let currentTime = (player as? KSMEPlayer)?.displayedVideoTime
                    ?? player.currentPlaybackTime
                onProgress?(currentTime, player.duration, .final)
            }
            coordinator.playerLayer?.stop()
            coordinator.resetPlayer()
        }
    }

    @MainActor
    private func registerWatchChannel() {
        guard watchRegistrationID == nil, let watchChannel else { return }
        watchRegistrationID = watchChannel.register(
            sample: {
                guard let player = coordinator.playerLayer?.player else { return nil }
                let position = (player as? KSMEPlayer)?.displayedVideoTime ?? player.currentPlaybackTime
                guard position.isFinite else { return nil }
                return WatchLocalPlaybackSample(
                    position: position,
                    isPlaying: player.isPlaying,
                    rate: player.playbackRate > 0 ? Double(player.playbackRate) : 1
                )
            },
            apply: { adjustment, baselineRate in
                guard let layer = coordinator.playerLayer else { return }
                if let target = adjustment.targetPosition {
                    await withCheckedContinuation { continuation in
                        PlayerSeekRecovery.seek(
                            layer: layer,
                            to: target,
                            resume: adjustment.shouldPlay ?? wantsPlayback
                        ) { _ in continuation.resume() }
                    }
                }
                let requestedRate = adjustment.temporaryRate ?? adjustment.playbackRate ?? baselineRate
                if adjustment.temporaryRate != nil || adjustment.playbackRate != nil {
                    layer.player.playbackRate = Float(requestedRate)
                }
                if adjustment.shouldPlay == false {
                    wantsPlayback = false
                    PlayerSeekRecovery.pause(layer: layer)
                } else if adjustment.shouldPlay == true {
                    wantsPlayback = true
                    PlayerSeekRecovery.resume(layer: layer)
                }
            }
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

    @MainActor
    private func applyPreferredTracksIfAvailable(
        to player: any MediaPlayerProtocol
    ) {
        if !didApplyAudioPreference {
            let tracks = player.tracks(mediaType: .audio)
            let options = tracks.map {
                PlaybackLanguageOption(
                    languageTag: $0.languageCode,
                    displayName: $0.name
                )
            }
            if let index = PlaybackLanguageMatcher.bestMatchIndex(
                in: options,
                preferredLanguage: PlaybackLanguagePreferences.preferredAudioLanguage()
            ) {
                player.select(track: tracks[index])
                didApplyAudioPreference = true
            } else if !tracks.isEmpty {
                // Keep the container's default audio when the preferred
                // language is unavailable, but do not keep rescanning it.
                didApplyAudioPreference = true
            }
        }

        guard !didApplySubtitlePreference else { return }
        let subtitleModel = coordinator.subtitleModel
        guard PlaybackLanguagePreferences.subtitlesEnabled() else {
            subtitleModel.selectedSubtitleInfo = nil
            didApplySubtitlePreference = true
            return
        }
        let infos = subtitleModel.subtitleInfos
        let options = infos.map { info in
            let track = info as? any MediaPlayerTrack
            return PlaybackLanguageOption(
                languageTag: track?.languageCode,
                displayName: info.name
            )
        }
        guard let index = PlaybackLanguageMatcher.bestMatchIndex(
            in: options,
            preferredLanguage: PlaybackLanguagePreferences.preferredSubtitleLanguage()
        ) else { return }
        let selected = infos[index]
        subtitleModel.selectedSubtitleInfo = selected
        if let track = selected as? any MediaPlayerTrack {
            player.select(track: track)
        }
        didApplySubtitlePreference = true
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
    let state: KSPlayerState
    let title: String
    @Binding var wantsPlayback: Bool
    @Binding var viewportMode: PlaybackViewportMode
    let onSeekFailure: (TimeInterval) -> Void
    let close: () -> Void
    @State private var isAudioPickerPresented = false
    @State private var audioTrackOptions: [PlayerAudioTrackOption] = []
    @State private var isSubtitlePickerPresented = false
    @State private var subtitleTrackOptions: [PlayerSubtitleTrackOption] = []

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

            if isAudioPickerPresented {
                audioTrackPicker
                    .zIndex(2)
            }
            if isSubtitlePickerPresented {
                subtitleTrackPicker
                    .zIndex(2)
            }
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
                overlayButton(
                    "waveform",
                    label: "Audio tracks",
                    identifier: "player-audio-tracks",
                    action: toggleAudioPicker
                )
            }
            overlayButton(
                "captions.bubble",
                label: "Subtitles",
                identifier: "player-subtitles",
                action: toggleSubtitlePicker
            )
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
                action: {
                    coordinator.mask(show: false, autoHide: false)
                    PlayerPresentation.toggleOrientation()
                }
            )
        }
    }

    private var audioTrackPicker: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Label("Audio", systemImage: "waveform")
                        .font(.headline)
                    Spacer(minLength: 8)
                    Button {
                        dismissAudioPicker()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.bold())
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close audio tracks")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider().overlay(.white.opacity(0.12))

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(audioTrackOptions) { option in
                            Button {
                                selectAudioTrack(option)
                            } label: {
                                HStack(spacing: 11) {
                                    Image(
                                        systemName: option.isSelected
                                            ? "checkmark"
                                            : "waveform"
                                    )
                                    .frame(width: 18)
                                    Text(option.name)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
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
                            .accessibilityIdentifier("player-audio-track-\(option.id)")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(
                width: min(340, max(proxy.size.width - 32, 220)),
                height: min(max(proxy.size.height - 96, 150), 390)
            )
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .accessibilityIdentifier("player-audio-track-picker")
        }
    }

    private var subtitleTrackPicker: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Label("Subtitles", systemImage: "captions.bubble")
                        .font(.headline)
                    Spacer(minLength: 8)
                    Button {
                        dismissSubtitlePicker()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.bold())
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close subtitles")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider().overlay(.white.opacity(0.12))

                ScrollView {
                    LazyVStack(spacing: 2) {
                        subtitleTrackRow(
                            id: "off",
                            name: "Off",
                            isSelected: coordinator.subtitleModel.selectedSubtitleInfo == nil
                        ) {
                            coordinator.subtitleModel.selectedSubtitleInfo = nil
                            PlaybackLanguagePreferences.rememberSubtitlesDisabled()
                            dismissSubtitlePicker()
                        }

                        ForEach(subtitleTrackOptions) { option in
                            subtitleTrackRow(
                                id: option.id,
                                name: option.name,
                                isSelected: option.isSelected
                            ) {
                                selectSubtitleTrack(option)
                            }
                        }

                        if subtitleTrackOptions.isEmpty {
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
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .accessibilityIdentifier("player-subtitle-track-picker")
        }
    }

    private func subtitleTrackRow(
        id: String,
        name: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: isSelected ? "checkmark" : "captions.bubble")
                    .frame(width: 18)
                Text(name)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
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
        .accessibilityIdentifier("player-subtitle-track-\(id)")
    }

    @MainActor
    private func toggleAudioPicker() {
        if isAudioPickerPresented {
            dismissAudioPicker()
            return
        }
        guard let player = coordinator.playerLayer?.player else { return }
        audioTrackOptions = player.tracks(mediaType: .audio).map {
            PlayerAudioTrackOption(
                id: $0.trackID,
                name: $0.name,
                languageCode: $0.languageCode,
                isSelected: $0.isEnabled
            )
        }
        guard !audioTrackOptions.isEmpty else { return }
        isSubtitlePickerPresented = false
        isAudioPickerPresented = true
        // Freeze the controls while the picker is open. The playback clock
        // continues updating, but it can no longer tear down the selection UI.
        coordinator.mask(show: true, autoHide: false)
        NSLog("PLAYER_TRACK_PICKER opened tracks=%ld", audioTrackOptions.count)
    }

    @MainActor
    private func selectAudioTrack(_ option: PlayerAudioTrackOption) {
        guard let layer = coordinator.playerLayer else { return }
        let player = layer.player
        guard let track = player.tracks(mediaType: .audio).first(where: {
                  $0.trackID == option.id
              }) else { return }
        let shouldResume = wantsPlayback
        let selectionTime = player.currentPlaybackTime
        PlayerSeekRecovery.pause(layer: layer)
        player.select(track: track)
        PlayerSeekRecovery.seek(
            layer: layer,
            to: selectionTime,
            resume: shouldResume
        ) { finished in
            NSLog(
                "PLAYER_TRACK_PICKER audio_realign finished=%@ position=%.2f",
                finished ? "yes" : "no",
                selectionTime
            )
        }
        PlaybackLanguagePreferences.rememberAudioSelection(
            languageTag: option.languageCode,
            displayName: option.name
        )
        audioTrackOptions = audioTrackOptions.map {
            PlayerAudioTrackOption(
                id: $0.id,
                name: $0.name,
                languageCode: $0.languageCode,
                isSelected: $0.id == option.id
            )
        }
        NSLog("PLAYER_TRACK_PICKER selected id=%d name=%@", option.id, option.name)
        dismissAudioPicker()
    }

    @MainActor
    private func dismissAudioPicker() {
        isAudioPickerPresented = false
        coordinator.mask(show: true)
    }

    @MainActor
    private func toggleSubtitlePicker() {
        if isSubtitlePickerPresented {
            dismissSubtitlePicker()
            return
        }
        let model = coordinator.subtitleModel
        subtitleTrackOptions = model.subtitleInfos.map { info in
            let track = info as? any MediaPlayerTrack
            return PlayerSubtitleTrackOption(
                id: info.subtitleID,
                name: info.name,
                languageCode: track?.languageCode,
                isSelected: model.selectedSubtitleInfo?.subtitleID == info.subtitleID
            )
        }
        isAudioPickerPresented = false
        isSubtitlePickerPresented = true
        coordinator.mask(show: true, autoHide: false)
        NSLog("PLAYER_TRACK_PICKER opened kind=subtitles tracks=%ld", subtitleTrackOptions.count)
    }

    @MainActor
    private func selectSubtitleTrack(_ option: PlayerSubtitleTrackOption) {
        let model = coordinator.subtitleModel
        guard let info = model.subtitleInfos.first(where: {
            $0.subtitleID == option.id
        }) else { return }
        model.selectedSubtitleInfo = info
        if let track = info as? any MediaPlayerTrack {
            coordinator.playerLayer?.player.select(track: track)
        }
        PlaybackLanguagePreferences.rememberSubtitleSelection(
            languageTag: option.languageCode,
            displayName: option.name
        )
        subtitleTrackOptions = subtitleTrackOptions.map {
            PlayerSubtitleTrackOption(
                id: $0.id,
                name: $0.name,
                languageCode: $0.languageCode,
                isSelected: $0.id == option.id
            )
        }
        NSLog("PLAYER_TRACK_PICKER selected kind=subtitles id=%@", option.id)
        dismissSubtitlePicker()
    }

    @MainActor
    private func dismissSubtitlePicker() {
        isSubtitlePickerPresented = false
        coordinator.mask(show: true)
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
                    viewportMode == .fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    label: viewportMode == .fill ? "Fit video" : "Fill screen",
                    identifier: "player-content-mode",
                    action: { viewportMode = viewportMode.toggled }
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

private struct PlayerAudioTrackOption: Identifiable, Equatable {
    let id: Int32
    let name: String
    let languageCode: String?
    let isSelected: Bool
}

private struct PlayerSubtitleTrackOption: Identifiable, Equatable {
    let id: String
    let name: String
    let languageCode: String?
    let isSelected: Bool
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
                        if wasPlayingBeforeScrub,
                           let layer = coordinator.playerLayer {
                            PlayerSeekRecovery.pause(layer: layer)
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
                            scheduleSeekFailureCheck(layer: layer, target: target)
                        }
                    }
                }
            )
            .tint(Color.appAccent)
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

private struct PlayerSubtitleOverlay: View {
    @ObservedObject var model: SubtitleModel
    @SubtitleStyleStorage private var subtitleStyle
    @State private var anchor = SubtitlePlacement.defaultPosition
    @GestureState private var dragTranslation = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            let displayedAnchor = constrained(
                anchor.translated(
                    x: Double(dragTranslation.width),
                    y: Double(dragTranslation.height),
                    viewportWidth: Double(proxy.size.width),
                    viewportHeight: Double(proxy.size.height)
                ),
                in: proxy.size
            )

            VStack(spacing: 6) {
                ForEach(model.parts) { part in
                    if let text = part.text {
                        StyledSubtitleText(
                            AttributedString(text),
                            style: subtitleStyle
                        )
                    } else if let image = part.image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 120)
                    }
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
                    .updating($dragTranslation) { value, translation, _ in
                        translation = value.translation
                    }
                    .onEnded { value in
                        anchor = constrained(
                            anchor.translated(
                                x: Double(value.translation.width),
                                y: Double(value.translation.height),
                                viewportWidth: Double(proxy.size.width),
                                viewportHeight: Double(proxy.size.height)
                            ),
                            in: proxy.size
                        )
                        NSLog(
                            "PLAYER_SUBTITLE position_x=%.3f position_y=%.3f",
                            anchor.horizontal,
                            anchor.vertical
                        )
                    }
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Draggable subtitles")
            .accessibilityValue(
                String(
                    format: "Horizontal %.2f, vertical %.2f",
                    displayedAnchor.horizontal,
                    displayedAnchor.vertical
                )
            )
            .accessibilityIdentifier("player-subtitle-overlay")
        }
        .allowsHitTesting(!model.parts.isEmpty)
        .accessibilityHidden(model.parts.isEmpty)
    }

    private func constrained(
        _ placement: SubtitlePlacement,
        in viewport: CGSize
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
        var partCount = 0

        for part in model.parts {
            let size: CGSize
            if let text = part.text {
                let bounds = (text.string as NSString).boundingRect(
                    with: CGSize(
                        width: max(maximumWidth - horizontalPadding, 1),
                        height: .greatestFiniteMagnitude
                    ),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font],
                    context: nil
                )
                size = CGSize(
                    width: min(ceil(bounds.width) + horizontalPadding, maximumWidth),
                    height: ceil(bounds.height) + verticalPadding
                )
            } else if let image = part.image, image.size.height > 0 {
                let scale = min(
                    maximumWidth / max(image.size.width, 1),
                    120 / image.size.height,
                    1
                )
                size = CGSize(
                    width: image.size.width * scale,
                    height: image.size.height * scale
                )
            } else {
                continue
            }
            width = max(width, size.width)
            height += size.height
            partCount += 1
        }

        if partCount > 1 {
            height += CGFloat(partCount - 1) * 6
        }
        return CGSize(width: width, height: height)
    }
}

#endif

struct NativePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    @Binding var viewportMode: PlaybackViewportMode

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var viewportMode: Binding<PlaybackViewportMode>

        init(viewportMode: Binding<PlaybackViewportMode>) {
            self.viewportMode = viewportMode
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            let current = viewportMode.wrappedValue
            let updated = current.applying(
                magnification: Double(recognizer.scale)
            )
            if updated != current {
                viewportMode.wrappedValue = updated
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewportMode: $viewportMode)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.videoGravity = viewportMode == .fill
            ? .resizeAspectFill
            : .resizeAspect
        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        pinch.cancelsTouchesInView = false
        pinch.delegate = context.coordinator
        controller.view.addGestureRecognizer(pinch)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.viewportMode = $viewportMode
        if controller.player !== player {
            controller.player = player
        }
        controller.videoGravity = viewportMode == .fill
            ? .resizeAspectFill
            : .resizeAspect
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
    private let debugEngineName: String
    private let benchmarkEngineName: String
    private let minimumVideoDuration: TimeInterval
    private let onProgress: PlaybackProgressHandler?
    private let onExhausted: (@MainActor (Error) -> Void)?
    private let watchChannel: WatchPlaybackControlChannel?
    private let onControlsVisibilityChanged: PlaybackControlsVisibilityHandler?
    @State private var player = AVPlayer()
    @State private var candidateIndex = 0
    @State private var attemptRevision = 0
    @State private var statusMessage = "Preparing video…"
    @State private var failureMessage: String?
    @State private var nominalFPS: Double?
    @State private var progressReference: PlaybackProgressReference
    @State private var didRestorePosition = false
    @State private var viewportMode = PlaybackViewportMode.fit
    @AppStorage(PlayerDebugPreferences.overlayEnabledKey)
    private var debugOverlaySetting = false
    @State private var debugSnapshot: PlayerDebugSnapshot
    @State private var watchRegistrationID: UUID?

    init(
        plan: PlaybackPlan,
        title: String,
        initialPosition: TimeInterval = 0,
        minimumVideoDuration: TimeInterval = 4,
        onProgress: PlaybackProgressHandler? = nil,
        watchChannel: WatchPlaybackControlChannel? = nil,
        onControlsVisibilityChanged: PlaybackControlsVisibilityHandler? = nil,
        debugEngineName: String = "AVPlayer",
        benchmarkEngineName: String = "avplayer",
        onExhausted: (@MainActor (Error) -> Void)? = nil
    ) {
        self.plan = plan
        self.title = title
        self.debugEngineName = debugEngineName
        self.benchmarkEngineName = benchmarkEngineName
        self.minimumVideoDuration = minimumVideoDuration
        self.onProgress = onProgress
        self.watchChannel = watchChannel
        self.onControlsVisibilityChanged = onControlsVisibilityChanged
        self.onExhausted = onExhausted
        _progressReference = State(
            initialValue: PlaybackProgressReference(position: initialPosition)
        )
        _debugSnapshot = State(
            initialValue: PlayerDebugSnapshot.waiting(engine: debugEngineName)
        )
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
            NativePlayerView(player: player, viewportMode: $viewportMode)
                .background(.black)

            if let failureMessage {
                playbackFailure(message: failureMessage)
            } else if !statusMessage.isEmpty {
                VStack(spacing: 12) {
                    ProgressView().tint(Color.appAccent)
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
        .playbackViewportInteraction(mode: $viewportMode)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    viewportMode = viewportMode.toggled
                } label: {
                    Image(
                        systemName: viewportMode == .fill
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right"
                    )
                }
                .accessibilityLabel(viewportMode == .fill ? "Fit video" : "Fill screen")
                .accessibilityIdentifier("player-content-mode")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                PlayerOrientationButton()
            }
        }
        .task(id: "\(candidateIndex)-\(attemptRevision)") { await startCurrentCandidate() }
        .task(id: "debug-\(candidateIndex)-\(attemptRevision)-\(debugOverlayEnabled)") {
            await monitorPlayerDebug()
        }
        .task(id: "progress-\(candidateIndex)-\(attemptRevision)") {
            await monitorPlaybackProgress()
        }
        .onAppear {
            onControlsVisibilityChanged?(true)
            registerWatchChannel()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)
        ) { notification in
            guard notification.object as? AVPlayerItem === player.currentItem else { return }
            advanceOrFail()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
        ) { notification in
            guard let item = notification.object as? AVPlayerItem,
                  item === player.currentItem
            else { return }
            let duration = item.duration.seconds
            if duration.isFinite, duration > 0 {
                progressReference.update(position: duration, duration: duration)
                onProgress?(duration, duration, .final)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: AVPlayerItem.mediaSelectionDidChangeNotification
            )
        ) { notification in
            guard let item = notification.object as? AVPlayerItem,
                  item === player.currentItem
            else { return }
            Task { @MainActor in
                await rememberPlaybackLanguageSelections(from: item)
            }
        }
        .onDisappear {
            if let watchRegistrationID { watchChannel?.unregister(watchRegistrationID) }
            reportCurrentProgress(updateKind: .final)
            player.pause()
            player.replaceCurrentItem(with: nil)
            PlayerPresentation.endAudioSession()
        }
    }

    @MainActor
    private func registerWatchChannel() {
        guard watchRegistrationID == nil, let watchChannel else { return }
        watchRegistrationID = watchChannel.register(
            sample: {
                guard let item = player.currentItem else { return nil }
                let position = item.currentTime().seconds
                guard position.isFinite else { return nil }
                return WatchLocalPlaybackSample(
                    position: position,
                    isPlaying: player.timeControlStatus == .playing || player.rate > 0,
                    rate: player.rate > 0 ? Double(player.rate) : 1
                )
            },
            apply: { adjustment, baselineRate in
                if let target = adjustment.targetPosition { await seek(to: target) }
                let requestedRate = adjustment.temporaryRate ?? adjustment.playbackRate ?? baselineRate
                if adjustment.shouldPlay == false {
                    player.pause()
                } else if adjustment.shouldPlay == true {
                    player.playImmediately(atRate: Float(requestedRate))
                } else if adjustment.temporaryRate != nil || adjustment.playbackRate != nil,
                          player.timeControlStatus == .playing || player.rate > 0 {
                    player.rate = Float(requestedRate)
                }
            }
        )
    }

    @ViewBuilder
    private func playbackFailure(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "play.slash")
                .font(.system(size: 44))
                .foregroundStyle(Color.appAccent)
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
            .tint(Color.appAccent)
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
        didRestorePosition = progressReference.position <= 0
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
        applySubtitleStyle(to: item)
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(videoOutput)
        player.replaceCurrentItem(with: item)
        player.play()
        Task { @MainActor [weak item] in
            guard let item else { return }
            await applyPlaybackLanguagePreferences(to: item)
        }

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
                if !didRestorePosition, progressReference.position > 0 {
                    didRestorePosition = true
                    let target = duration.isFinite && duration > 0
                        ? min(progressReference.position, max(duration - 1, 0))
                        : progressReference.position
                    await seek(to: target)
                    player.play()
                    continue
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
                    "PLAYER_BENCHMARK playing_ms=%.1f engine=%@ title=%@",
                    elapsed,
                    benchmarkEngineName,
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
        debugSnapshot = .waiting(engine: debugEngineName)
        guard debugOverlayEnabled else { return }
        while !Task.isCancelled {
            let sample = PlayerDebugMetrics.avPlayer(
                player,
                engine: debugEngineName,
                nominalFPS: nominalFPS
            )
            debugSnapshot = sample
            NSLog("PLAYER_DEBUG %@", sample.logDescription)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    @MainActor
    private func monitorPlaybackProgress() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            reportCurrentProgress()
        }
    }

    @MainActor
    private func reportCurrentProgress(
        updateKind: PlaybackProgressUpdateKind = .checkpoint
    ) {
        guard let item = player.currentItem else { return }
        let position = item.currentTime().seconds
        let duration = item.duration.seconds
        guard position.isFinite, duration.isFinite else { return }
        progressReference.update(position: position, duration: duration)
        onProgress?(
            progressReference.position,
            progressReference.duration,
            updateKind
        )
    }

    @MainActor
    private func seek(to position: TimeInterval) async {
        await withCheckedContinuation { continuation in
            player.seek(
                to: CMTime(seconds: max(position, 0), preferredTimescale: 600),
                toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600),
                toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600)
            ) { _ in continuation.resume() }
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
            NSLog(
                "PLAYER_PARITY FAIL player=%@ step=autoplay-or-visible-frame",
                benchmarkEngineName
            )
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
            NSLog("PLAYER_PARITY FAIL player=%@ step=seek", benchmarkEngineName)
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
            NSLog("PLAYER_PARITY FAIL player=%@ step=pause", benchmarkEngineName)
            return
        }

        player.play()
        for _ in 0..<30 {
            if item.currentTime().seconds >= pausedAt + 0.35 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard player.rate > 0, item.currentTime().seconds >= pausedAt + 0.35 else {
            NSLog("PLAYER_PARITY FAIL player=%@ step=resume", benchmarkEngineName)
            return
        }

        NSLog(
            "PLAYER_PARITY PASS player=%@ autoplay=yes frame=yes seek=yes pause=yes resume=yes duration=%.1f",
            benchmarkEngineName,
            duration
        )
        #endif
    }

    @MainActor
    private func advanceOrFail() {
        reportCurrentProgress()
        player.pause()
        player.replaceCurrentItem(with: nil)
        let nextCandidateIndex = candidateIndex + 1
        if candidates.indices.contains(nextCandidateIndex) {
            NSLog(
                "PLAYER_REPAIR avplayer=advance-candidate from=%ld to=%ld",
                candidateIndex,
                nextCandidateIndex
            )
            failureMessage = nil
            statusMessage = "Trying the original stream…"
            candidateIndex = nextCandidateIndex
            return
        }
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
        let view = UIView()
        view.backgroundColor = .black
        view.clipsToBounds = true
        player.drawable = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        if (player.drawable as AnyObject?) !== view {
            player.drawable = view
        }
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        if (coordinator.player.drawable as AnyObject?) === view {
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
    @Published var videoSize = CGSize.zero
    @Published var isMuted = false
    @Published var failureMessage: String?
    @Published private(set) var hasRenderedFrame = false
    @Published private(set) var didReachEnd = false
    @Published private(set) var debugSnapshot = PlayerDebugSnapshot.waiting(engine: "VLC")
    @Published private(set) var audioTrackOptions: [VLCTrackOption] = []
    @Published private(set) var subtitleTrackOptions: [VLCTrackOption] = []
    @Published private(set) var selectedAudioTrackID = -1
    @Published private(set) var selectedSubtitleTrackID = -1
    private var debugStallCount = 0
    private var wasBuffering = false
    private var lastStatisticsAt: TimeInterval?
    private var lastDisplayedPictures = 0
    private var measuredDisplayFPS: Double?
    private var debugMetricsEnabled = false
    private var activeBoundedRenderer = false
    private var boundedDisplayedFrames: UInt64 = 0
    private var boundedDroppedFrames: UInt64 = 0
    private var statePollingTask: Task<Void, Never>?
    private var preferredTrackSelectionTask: Task<Void, Never>?
    private let adaptiveMaxWidth: Int
    private let adaptiveMaxHeight: Int

    init(policy: PlaybackPerformancePolicy) {
        performancePolicy = policy
        let environment = ProcessInfo.processInfo.environment
        #if targetEnvironment(simulator)
        let defaultAdaptiveMaxWidth = 1_280
        let defaultAdaptiveMaxHeight = 720
        #else
        let defaultAdaptiveMaxWidth = 1_920
        let defaultAdaptiveMaxHeight = 1_080
        #endif
        adaptiveMaxWidth = max(
            Int(environment["SKELETON_VLC_ADAPTIVE_MAX_WIDTH"] ?? "")
                ?? defaultAdaptiveMaxWidth,
            320
        )
        adaptiveMaxHeight = max(
            Int(environment["SKELETON_VLC_ADAPTIVE_MAX_HEIGHT"] ?? "")
                ?? defaultAdaptiveMaxHeight,
            180
        )
        var options = [
            "--network-caching=\(policy.networkCacheMilliseconds)",
            "--http-reconnect",
            "--avcodec-hw=\(environment["SKELETON_VLC_AVCODEC_HW"] ?? "any")",
            "--adaptive-logic=rate",
            "--adaptive-maxwidth=\(adaptiveMaxWidth)",
            "--adaptive-maxheight=\(adaptiveMaxHeight)",
            "--preferred-resolution=\(adaptiveMaxHeight)",
            "--drop-late-frames",
            "--skip-frames",
            "--no-color",
        ]
        options.append(contentsOf: SubtitleVisualStyle().vlcOptions)
        if policy.prefersVideoToolboxChain {
            // VideoToolbox already has the highest iOS video-decoder priority.
            // Restricting the global codec chain to video decoders also blocks
            // VLC's subtitle decoders and can force an expensive avcodec
            // fallback. Keep hardware-only VideoToolbox enabled while leaving
            // audio and subtitle module selection unconstrained.
            options.append("--videotoolbox")
            options.append("--videotoolbox-hw-decoder-only")
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
        let mediaNetworkCacheMilliseconds = networkCacheMilliseconds(for: url)
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=\(mediaNetworkCacheMilliseconds)")
        media.addOption(":http-reconnect")
        media.addOption(":adaptive-logic=rate")
        media.addOption(":adaptive-maxwidth=\(adaptiveMaxWidth)")
        media.addOption(":adaptive-maxheight=\(adaptiveMaxHeight)")
        media.addOption(":preferred-resolution=\(adaptiveMaxHeight)")
        player.media = media
        NSLog(
            "VLC_MEDIA network_cache_ms=%ld provider_proxy=%@ transport_bridge=%@",
            mediaNetworkCacheMilliseconds,
            isProviderProxy(url) ? "yes" : "no",
            isLocalTransportBridge(url) ? "yes" : "no"
        )
        player.play()
        beginStatePolling()

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

    func toggleMute() {
        guard let audio = player.audio else { return }
        audio.isMuted = !audio.isMuted
        isMuted = audio.isMuted
    }

    func beginPreferredLanguageTrackSelection() {
        preferredTrackSelectionTask?.cancel()
        preferredTrackSelectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<40 {
                refreshTrackOptions()
                applyPreferredLanguageTracks()
                if !audioTrackOptions.isEmpty, !subtitleTrackOptions.isEmpty {
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
            }
            let selectedAudioName = audioTrackOptions.first {
                $0.id == selectedAudioTrackID
            }?.name ?? "Off"
            let selectedSubtitleName = subtitleTrackOptions.first {
                $0.id == selectedSubtitleTrackID
            }?.name ?? "Off"
            NSLog(
                "VLC_TRACKS audio=%ld subtitles=%ld selected_audio=%ld selected_audio_name=%@ selected_subtitle=%ld selected_subtitle_name=%@",
                audioTrackOptions.count,
                subtitleTrackOptions.count,
                selectedAudioTrackID,
                selectedAudioName,
                selectedSubtitleTrackID,
                selectedSubtitleName
            )
        }
    }

    func selectAudioTrack(_ track: VLCTrackOption) {
        player.currentAudioTrackIndex = Int32(track.id)
        PlaybackLanguagePreferences.rememberAudioSelection(
            languageTag: nil,
            displayName: track.name
        )
        refreshTrackOptions()
    }

    /// LibVLC can briefly mix queued packets from the previous audio stream
    /// when a remote track is changed in-place. Pause and realign the media
    /// clock before resuming so the new decoder starts on the current timeline.
    func switchAudioTrackAndRealign(_ track: VLCTrackOption) async {
        let position = currentTime
        let shouldResume = player.isPlaying
        if shouldResume { pause() }
        selectAudioTrack(track)
        let realigned: Bool
        if position <= 0 {
            realigned = true
        } else {
            realigned = await seekAndWait(to: position)
        }
        if shouldResume { play() }
        NSLog(
            "VLC_TRACK_SWITCH audio=%ld realigned=%@ resumed=%@",
            track.id,
            realigned ? "yes" : "no",
            shouldResume ? "yes" : "no"
        )
    }

    func selectSubtitleTrack(_ track: VLCTrackOption?) {
        guard let track else {
            player.currentVideoSubTitleIndex = -1
            PlaybackLanguagePreferences.rememberSubtitlesDisabled()
            refreshTrackOptions()
            return
        }
        player.currentVideoSubTitleIndex = Int32(track.id)
        PlaybackLanguagePreferences.rememberSubtitleSelection(
            languageTag: nil,
            displayName: track.name
        )
        refreshTrackOptions()
    }

    private func applyPreferredLanguageTracks() {
        let audioTracks = audioTrackOptions
        let audioOptions = audioTracks.map {
            PlaybackLanguageOption(languageTag: nil, displayName: $0.name)
        }
        if let index = PlaybackLanguageMatcher.bestMatchIndex(
            in: audioOptions,
            preferredLanguage: PlaybackLanguagePreferences.preferredAudioLanguage()
        ) {
            player.currentAudioTrackIndex = Int32(audioTracks[index].id)
        }

        let subtitleTracks = subtitleTrackOptions
        guard PlaybackLanguagePreferences.subtitlesEnabled() else {
            player.currentVideoSubTitleIndex = -1
            selectedSubtitleTrackID = -1
            return
        }
        let subtitleOptions = subtitleTracks.map {
            PlaybackLanguageOption(languageTag: nil, displayName: $0.name)
        }
        if let index = PlaybackLanguageMatcher.bestMatchIndex(
            in: subtitleOptions,
            preferredLanguage: PlaybackLanguagePreferences.preferredSubtitleLanguage()
        ) {
            player.currentVideoSubTitleIndex = Int32(subtitleTracks[index].id)
            selectedSubtitleTrackID = subtitleTracks[index].id
        } else {
            player.currentVideoSubTitleIndex = -1
            selectedSubtitleTrackID = -1
        }
        selectedAudioTrackID = Int(player.currentAudioTrackIndex)
    }

    func seek(to seconds: TimeInterval) {
        guard player.isSeekable else { return }
        player.time = VLCTime(int: Int32(max(seconds, 0) * 1_000))
        updatePublishedState()
    }

    func seekAndWait(to seconds: TimeInterval) async -> Bool {
        guard player.isSeekable else { return false }
        let target = duration > 0
            ? min(max(seconds, 0), duration)
            : max(seconds, 0)
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
        statePollingTask?.cancel()
        statePollingTask = nil
        preferredTrackSelectionTask?.cancel()
        preferredTrackSelectionTask = nil
        player.stop()
        player.media = nil
        isPlaying = false
        isReady = false
        currentTime = 0
        duration = 0
        videoSize = .zero
        isMuted = false
        hasRenderedFrame = false
        didReachEnd = false
        debugSnapshot = .waiting(engine: "VLC")
        debugStallCount = 0
        wasBuffering = false
        lastStatisticsAt = nil
        lastDisplayedPictures = 0
        measuredDisplayFPS = nil
        audioTrackOptions = []
        subtitleTrackOptions = []
        selectedAudioTrackID = -1
        selectedSubtitleTrackID = -1
        if clearFailure { failureMessage = nil }
    }

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            updatePublishedState()
            if player.state == .error {
                failureMessage = VLCPlaybackError.playerError.localizedDescription
            }
            if player.state == .ended, !didReachEnd {
                didReachEnd = true
            }
        }
    }

    private func updatePublishedState() {
        let playing = player.isPlaying
        if isPlaying != playing { isPlaying = playing }
        let nextCurrentTime = max(TimeInterval(player.time.intValue) / 1_000, 0)
        if abs(currentTime - nextCurrentTime) >= 0.025 {
            currentTime = nextCurrentTime
        }
        let reportedDuration = max(
            TimeInterval(player.media?.length.intValue ?? 0) / 1_000,
            0
        )
        let inferredDuration: TimeInterval
        let playbackPosition = Double(player.position)
        if reportedDuration <= 0,
           nextCurrentTime > 0,
           playbackPosition.isFinite,
           playbackPosition > 0.000_1 {
            inferredDuration = nextCurrentTime / playbackPosition
        } else {
            inferredDuration = 0
        }
        let nextDuration = reportedDuration > 0
            ? reportedDuration
            : (duration > 0 ? duration : inferredDuration)
        if abs(duration - nextDuration) >= 0.10 {
            duration = nextDuration
        }
        let currentVideoSize = player.videoSize
        if videoSize != currentVideoSize {
            videoSize = currentVideoSize
        }
        let currentMutedState = player.audio?.isMuted ?? false
        if isMuted != currentMutedState {
            isMuted = currentMutedState
        }
        refreshTrackOptions()
        updateDebugStallState()
    }

    private func beginStatePolling() {
        statePollingTask?.cancel()
        statePollingTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                updatePublishedState()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func networkCacheMilliseconds(for url: URL) -> Int {
        if let override = Int(
            ProcessInfo.processInfo.environment["SKELETON_VLC_NETWORK_CACHE_MS"] ?? ""
        ) {
            return min(max(override, 300), 10_000)
        }
        if isLocalTransportBridge(url) {
            return max(performancePolicy.networkCacheMilliseconds, 900)
        }
        if isProviderProxy(url) {
            return max(performancePolicy.networkCacheMilliseconds, 1_200)
        }
        return performancePolicy.networkCacheMilliseconds
    }

    private func isProviderProxy(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return ["debrid", "torbox", "tb-cdn", "real-debrid", "alldebrid"]
            .contains(where: host.contains)
    }

    private func isLocalTransportBridge(_ url: URL) -> Bool {
        url.host == "127.0.0.1"
            && url.path.hasPrefix("/stream/")
            && url.path.hasSuffix("/media.ts")
    }

    private func refreshTrackOptions() {
        let nextAudioTracks = trackOptions(
            names: player.audioTrackNames,
            indexes: player.audioTrackIndexes
        )
        if audioTrackOptions != nextAudioTracks {
            audioTrackOptions = nextAudioTracks
        }
        let nextSubtitleTracks = trackOptions(
            names: player.videoSubTitlesNames,
            indexes: player.videoSubTitlesIndexes
        )
        if subtitleTrackOptions != nextSubtitleTracks {
            subtitleTrackOptions = nextSubtitleTracks
        }
        let nextAudioTrackID = Int(player.currentAudioTrackIndex)
        if selectedAudioTrackID != nextAudioTrackID {
            selectedAudioTrackID = nextAudioTrackID
        }
        let nextSubtitleTrackID = Int(player.currentVideoSubTitleIndex)
        if selectedSubtitleTrackID != nextSubtitleTrackID {
            selectedSubtitleTrackID = nextSubtitleTrackID
        }
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

private struct VLCTrackOption: Identifiable, Equatable {
    let id: Int
    let name: String
}

private enum VLCTrackPickerKind: Equatable {
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

private func trackOptions(names: [Any], indexes: [Any]) -> [VLCTrackOption] {
    let labels = names.compactMap { $0 as? String }
    let identifiers = indexes.compactMap { value -> Int? in
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }
    return zip(labels, identifiers).compactMap { name, identifier in
        guard identifier >= 0 else { return nil }
        return VLCTrackOption(id: identifier, name: name)
    }
}

private struct VLCPlayerScreen: View {
    let title: String
    private let plan: PlaybackPlan
    private let initialPosition: TimeInterval
    private let minimumVideoDuration: TimeInterval
    private let onProgress: PlaybackProgressHandler?
    private let onExhausted: (@MainActor (Error) -> Void)?
    private let watchChannel: WatchPlaybackControlChannel?
    private let onControlsVisibilityChanged: PlaybackControlsVisibilityHandler?
    private let backend: VLCPlaybackBackend
    @State private var didFallBackToCompatibility = false

    init(
        plan: PlaybackPlan,
        title: String,
        initialPosition: TimeInterval = 0,
        minimumVideoDuration: TimeInterval,
        onProgress: PlaybackProgressHandler? = nil,
        watchChannel: WatchPlaybackControlChannel? = nil,
        onControlsVisibilityChanged: PlaybackControlsVisibilityHandler? = nil,
        onExhausted: (@MainActor (Error) -> Void)?
    ) {
        self.plan = plan
        self.title = title
        self.initialPosition = max(initialPosition, 0)
        self.minimumVideoDuration = minimumVideoDuration
        self.onProgress = onProgress
        self.watchChannel = watchChannel
        self.onControlsVisibilityChanged = onControlsVisibilityChanged
        self.onExhausted = onExhausted
        #if targetEnvironment(simulator)
        let forcesCompatibility = ProcessInfo.processInfo.environment[
            "SKELETON_VLC_FORCE_COMPATIBILITY"
        ] == "1"
        #else
        let forcesCompatibility = false
        #endif
        backend = forcesCompatibility
            ? .compatibility
            : VLCPlaybackRouting.backend(
                for: plan.primaryURL,
                detectedMIMEType: plan.detectedMIMEType
            )
    }

    @ViewBuilder
    var body: some View {
        switch activeBackend {
        case .nativeHardware:
            AVPlayerScreen(
                plan: plan,
                title: title,
                initialPosition: initialPosition,
                minimumVideoDuration: minimumVideoDuration,
                onProgress: onProgress,
                watchChannel: watchChannel,
                onControlsVisibilityChanged: onControlsVisibilityChanged,
                debugEngineName: "VLC Native",
                benchmarkEngineName: "vlc-native",
                onExhausted: { error in
                    NSLog(
                        "VLC_ACCELERATOR fallback=mobilevlckit error=%@",
                        error.localizedDescription
                    )
                    didFallBackToCompatibility = true
                }
            )
            .onAppear {
                NSLog("VLC_ACCELERATOR backend=avfoundation hardware=system")
            }
        case .compatibility:
            VLCCompatibilityPlayerScreen(
                plan: plan,
                title: title,
                initialPosition: initialPosition,
                minimumVideoDuration: minimumVideoDuration,
                onProgress: onProgress,
                watchChannel: watchChannel,
                onControlsVisibilityChanged: onControlsVisibilityChanged,
                onExhausted: onExhausted
            )
            .onAppear {
                NSLog("VLC_ACCELERATOR backend=mobilevlckit hardware=videotoolbox")
            }
        }
    }

    private var activeBackend: VLCPlaybackBackend {
        didFallBackToCompatibility ? .compatibility : backend
    }
}

private struct VLCCompatibilityPlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    private let plan: PlaybackPlan
    private let minimumVideoDuration: TimeInterval
    private let onProgress: PlaybackProgressHandler?
    private let onExhausted: (@MainActor (Error) -> Void)?
    private let watchChannel: WatchPlaybackControlChannel?
    private let onControlsVisibilityChanged: PlaybackControlsVisibilityHandler?
    private let playbackPolicy: PlaybackPerformancePolicy
    @StateObject private var model: VLCPlaybackModel
    @State private var controlsVisible = true
    @State private var attemptRevision = 0
    @State private var isScrubbing = false
    @State private var scrubPosition: TimeInterval = 0
    @State private var resumeAfterScrub = false
    @State private var viewportMode = PlaybackViewportMode.fit
    @State private var progressReference: PlaybackProgressReference
    @State private var trackPicker: VLCTrackPickerKind?
    @State private var trackPickerOptions: [VLCTrackOption] = []
    @State private var trackPickerSelectedID: Int?
    @AppStorage(PlayerDebugPreferences.overlayEnabledKey)
    private var debugOverlaySetting = false
    @State private var watchRegistrationID: UUID?

    init(
        plan: PlaybackPlan,
        title: String,
        initialPosition: TimeInterval = 0,
        minimumVideoDuration: TimeInterval,
        onProgress: PlaybackProgressHandler? = nil,
        watchChannel: WatchPlaybackControlChannel? = nil,
        onControlsVisibilityChanged: PlaybackControlsVisibilityHandler? = nil,
        onExhausted: (@MainActor (Error) -> Void)?
    ) {
        let policy = PlaybackPerformanceCore.policy(
            url: plan.primaryURL,
            title: title,
            player: .vlcKit
        )
        self.plan = plan
        self.title = title
        self.minimumVideoDuration = minimumVideoDuration
        self.onProgress = onProgress
        self.watchChannel = watchChannel
        self.onControlsVisibilityChanged = onControlsVisibilityChanged
        self.onExhausted = onExhausted
        playbackPolicy = policy
        _model = StateObject(wrappedValue: VLCPlaybackModel(policy: policy))
        _progressReference = State(
            initialValue: PlaybackProgressReference(position: initialPosition)
        )
    }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                VLCRenderView(player: model.player)
                    .scaleEffect(vlcRenderScale(in: proxy.size))
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .animation(.easeInOut(duration: 0.2), value: viewportMode)
            }
            .clipped()
            .ignoresSafeArea()

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { controlsVisible.toggle() }
                .accessibilityLabel(
                    controlsVisible ? "Hide player controls" : "Show player controls"
                )
                .accessibilityIdentifier("player-control-toggle-surface")

            if !model.isReady, model.failureMessage == nil {
                VStack(spacing: 12) {
                    ProgressView().tint(Color.appAccent)
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

            if let trackPicker {
                vlcTrackPicker(trackPicker)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .playbackViewportInteraction(mode: $viewportMode)
        .animation(.easeOut(duration: 0.18), value: controlsVisible)
        .animation(.easeOut(duration: 0.18), value: trackPicker)
        .onChange(of: viewportMode) { mode in
            NSLog("PLAYER_VIEWPORT engine=VLC mode=%@", mode.rawValue)
        }
        .task(id: attemptRevision) { await startPlayback() }
        .task(id: "debug-\(debugOverlayEnabled)-\(attemptRevision)") {
            await logPlayerDebug()
        }
        .task(id: "progress-\(attemptRevision)") {
            await monitorPlaybackProgress()
        }
        .onAppear {
            onControlsVisibilityChanged?(controlsVisible)
            registerWatchChannel()
        }
        .onChange(of: controlsVisible) { isVisible in
            onControlsVisibilityChanged?(isVisible)
        }
        .onChange(of: model.didReachEnd) { didReachEnd in
            guard didReachEnd else { return }
            reportCurrentProgress(updateKind: .final)
        }
        .onDisappear {
            if let watchRegistrationID { watchChannel?.unregister(watchRegistrationID) }
            reportCurrentProgress(updateKind: .final)
            model.stop()
            PlayerPresentation.endAudioSession()
        }
        .accessibilityIdentifier("stremio-player")
    }

    @MainActor
    private func registerWatchChannel() {
        guard watchRegistrationID == nil, let watchChannel else { return }
        watchRegistrationID = watchChannel.register(
            sample: {
                guard model.isReady else { return nil }
                return WatchLocalPlaybackSample(
                    position: model.currentTime,
                    isPlaying: model.isPlaying,
                    rate: model.player.rate > 0 ? Double(model.player.rate) : 1
                )
            },
            apply: { adjustment, baselineRate in
                if let target = adjustment.targetPosition { _ = await model.seekAndWait(to: target) }
                let requestedRate = adjustment.temporaryRate ?? adjustment.playbackRate ?? baselineRate
                if adjustment.shouldPlay == false {
                    model.pause()
                } else if adjustment.shouldPlay == true {
                    model.player.rate = Float(requestedRate)
                    model.play()
                } else if adjustment.temporaryRate != nil || adjustment.playbackRate != nil,
                          model.isPlaying {
                    model.player.rate = Float(requestedRate)
                }
            }
        )
    }

    private var controls: some View {
        GeometryReader { proxy in
            let isPortrait = proxy.size.height > proxy.size.width

            VStack(spacing: 0) {
                vlcTopControls(showsTitle: !isPortrait)

                Spacer(minLength: 14)

                HStack(spacing: 44) {
                    controlButton("gobackward.15", label: "Back 15 seconds") {
                        seekVLC(by: -15)
                    }
                    controlButton(
                        model.isPlaying ? "pause.fill" : "play.fill",
                        label: model.isPlaying ? "Pause" : "Play",
                        size: 26,
                        prominent: true
                    ) {
                        if model.isPlaying {
                            model.pause()
                        } else {
                            model.play()
                        }
                    }
                    controlButton("goforward.15", label: "Forward 15 seconds") {
                        seekVLC(by: 15)
                    }
                }

                Spacer(minLength: 14)

                vlcBottomControls(showsTitle: isPortrait)
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .buttonStyle(PlayerOverlayButtonStyle())
        .accessibilityIdentifier("player-controls")
    }

    private func vlcTopControls(showsTitle: Bool) -> some View {
        HStack(spacing: 8) {
            controlButton(
                "xmark",
                label: "Close player",
                identifier: "player-close"
            ) {
                controlsVisible = false
                PlayerPresentation.restorePortrait()
                dismiss()
            }

            if showsTitle {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }

            Spacer(minLength: 4)

            if model.audioTrackOptions.count > 1 {
                controlButton(
                    "waveform",
                    label: "Audio tracks",
                    identifier: "player-audio-tracks"
                ) {
                    openTrackPicker(.audio)
                }
            }
            controlButton(
                "captions.bubble",
                label: "Subtitles",
                identifier: "player-subtitles"
            ) {
                openTrackPicker(.subtitles)
            }
            controlButton(
                model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                label: model.isMuted ? "Unmute" : "Mute"
            ) {
                model.toggleMute()
            }
            controlButton(
                "rectangle.landscape.rotate",
                label: "Rotate player",
                identifier: "player-orientation-toggle"
            ) {
                controlsVisible = false
                PlayerPresentation.toggleOrientation()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.linearGradient(
            colors: [.black.opacity(0.82), .clear],
            startPoint: .top,
            endPoint: .bottom
        ))
    }

    private func vlcBottomControls(showsTitle: Bool) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if showsTitle {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                }
                Spacer(minLength: 8)
                controlButton(
                    viewportMode == .fill
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    label: viewportMode == .fill ? "Fit video" : "Fill screen",
                    identifier: "player-content-mode"
                ) {
                    viewportMode = viewportMode.toggled
                }
            }

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
                            model.pause()
                        }
                    } else {
                        let target = scrubPosition
                        isScrubbing = false
                        model.seek(to: target)
                        if resumeAfterScrub {
                            model.play()
                        }
                    }
                }
            )
            .tint(Color.appAccent)
            .disabled(model.duration <= 0 || !model.player.isSeekable)
            .accessibilityIdentifier("player-timeline")

            HStack {
                Text(formatTime(isScrubbing ? scrubPosition : model.currentTime))
                Spacer()
                Text(formatTime(model.duration))
            }
            .font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.linearGradient(
            colors: [.clear, .black.opacity(0.82)],
            startPoint: .top,
            endPoint: .bottom
        ))
    }

    private func vlcTrackPicker(_ kind: VLCTrackPickerKind) -> some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { trackPicker = nil }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: kind.systemImage)
                    Text(kind.title)
                        .font(.headline)
                    Spacer()
                    Button {
                        trackPicker = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close (kind.title.lowercased()) tracks")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().overlay(.white.opacity(0.12))

                ScrollView {
                    LazyVStack(spacing: 0) {
                        if kind == .subtitles {
                            vlcTrackRow(
                                title: "Off",
                                systemImage: "captions.bubble.fill",
                                isSelected: trackPickerSelectedID == nil
                            ) {
                                model.selectSubtitleTrack(nil)
                                trackPickerSelectedID = nil
                                trackPicker = nil
                            }
                        }

                        ForEach(trackPickerOptions) { option in
                            vlcTrackRow(
                                title: option.name,
                                systemImage: kind.systemImage,
                                isSelected: trackPickerSelectedID == option.id
                            ) {
                                selectVLCTrack(option, kind: kind)
                            }
                        }
                    }
                }
                .frame(maxHeight: 310)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
            .padding(20)
            .frame(maxWidth: 430)
        }
        .accessibilityIdentifier("vlc-track-picker")
    }

    private func vlcTrackRow(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 22)
                Text(title)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.white.opacity(0.10) : .clear)
    }

    private func openTrackPicker(_ kind: VLCTrackPickerKind) {
        switch kind {
        case .audio:
            trackPickerOptions = model.audioTrackOptions
            trackPickerSelectedID = model.selectedAudioTrackID
        case .subtitles:
            trackPickerOptions = model.subtitleTrackOptions
            let selected = model.selectedSubtitleTrackID
            trackPickerSelectedID = selected >= 0 ? selected : nil
        }
        trackPicker = kind
        NSLog(
            "VLC_TRACK_PICKER opened kind=%@ tracks=%ld",
            kind == .audio ? "audio" : "subtitles",
            trackPickerOptions.count
        )
    }

    private func selectVLCTrack(_ option: VLCTrackOption, kind: VLCTrackPickerKind) {
        trackPickerSelectedID = option.id
        switch kind {
        case .audio:
            Task { @MainActor in
                await model.switchAudioTrackAndRealign(option)
                trackPicker = nil
            }
        case .subtitles:
            model.selectSubtitleTrack(option)
            trackPicker = nil
        }
    }

    private func seekVLC(by interval: TimeInterval) {
        let target = min(
            max(model.currentTime + interval, 0),
            max(model.duration, 0)
        )
        model.seek(to: target)
    }

    private func controlButton(
        _ systemName: String,
        label: String,
        size: CGFloat = 18,
        prominent: Bool = false,
        identifier: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .frame(
                    width: prominent ? 56 : 44,
                    height: prominent ? 56 : 44
                )
                .background(.black.opacity(0.48), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier ?? label)
    }

    private func vlcRenderScale(in viewport: CGSize) -> CGFloat {
        CGFloat(
            viewportMode.renderScale(
                videoWidth: Double(model.videoSize.width),
                videoHeight: Double(model.videoSize.height),
                viewportWidth: Double(viewport.width),
                viewportHeight: Double(viewport.height)
            )
        )
    }

    @ViewBuilder
    private func playbackFailure(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "play.slash")
                .font(.system(size: 44))
                .foregroundStyle(Color.appAccent)
            Text("Playback unavailable").font(.title3.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                model.failureMessage = nil
                attemptRevision += 1
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appAccent)
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
            model.beginPreferredLanguageTrackSelection()
            if progressReference.position > 0 {
                _ = await model.seekAndWait(to: progressReference.position)
                model.play()
            }
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
            reportCurrentProgress()
            model.stop()
            if let onExhausted {
                onExhausted(error)
            } else {
                model.failureMessage = error.localizedDescription
            }
        }
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
        // LibVLC's native drawable keeps VideoToolbox in its intended output
        // path. Its custom-memory callback renderer requires a non-null pixel
        // plane for every in-flight frame and can outlive stop during teardown,
        // which caused picture_CopyPixels crashes on real devices.
        false
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

    @MainActor
    private func monitorPlaybackProgress() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            reportCurrentProgress()
        }
    }

    @MainActor
    private func reportCurrentProgress(
        updateKind: PlaybackProgressUpdateKind = .checkpoint
    ) {
        guard model.currentTime.isFinite, model.duration.isFinite else { return }
        progressReference.update(
            position: model.currentTime,
            duration: model.duration
        )
        onProgress?(
            progressReference.position,
            progressReference.duration,
            updateKind
        )
    }
}
#endif

/// Adaptive player backed by the Rust policy core. It keeps Apple-native
/// streams on AVFoundation, sends relabeled/direct containers through
/// KSPlayer's FFmpeg/VideoToolbox path, and uses VLC's native drawable for HEVC
/// and unusually large output surfaces.
private struct PerformancePlayerScreen: View {
    let title: String
    private let plan: PlaybackPlan
    private let initialPosition: TimeInterval
    private let minimumVideoDuration: TimeInterval
    private let onProgress: PlaybackProgressHandler?
    private let onExhausted: (@MainActor (Error) -> Void)?
    private let watchChannel: WatchPlaybackControlChannel?
    private let onControlsVisibilityChanged: PlaybackControlsVisibilityHandler?
    private let policy: PlaybackPerformancePolicy

    init(
        plan: PlaybackPlan,
        title: String,
        initialPosition: TimeInterval,
        minimumVideoDuration: TimeInterval,
        onProgress: PlaybackProgressHandler?,
        watchChannel: WatchPlaybackControlChannel?,
        onControlsVisibilityChanged: PlaybackControlsVisibilityHandler?,
        onExhausted: (@MainActor (Error) -> Void)?
    ) {
        self.plan = plan
        self.title = title
        self.initialPosition = max(initialPosition, 0)
        self.minimumVideoDuration = minimumVideoDuration
        self.onProgress = onProgress
        self.watchChannel = watchChannel
        self.onControlsVisibilityChanged = onControlsVisibilityChanged
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
                initialPosition: initialPosition,
                minimumVideoDuration: minimumVideoDuration,
                onProgress: onProgress,
                watchChannel: watchChannel,
                onControlsVisibilityChanged: onControlsVisibilityChanged,
                onExhausted: onExhausted
            )
        case .vlcVideoToolboxBridge:
            #if canImport(MobileVLCKit)
            VLCPlayerScreen(
                plan: plan,
                title: title,
                initialPosition: initialPosition,
                minimumVideoDuration: minimumVideoDuration,
                onProgress: onProgress,
                watchChannel: watchChannel,
                onControlsVisibilityChanged: onControlsVisibilityChanged,
                onExhausted: onExhausted
            )
            #else
            performanceKSPlayer
            #endif
        case .automatic, .ffmpegVideoToolbox, .bunnyFFmpeg:
            performanceKSPlayer
        }
    }

    @ViewBuilder
    private var performanceKSPlayer: some View {
        #if canImport(KSPlayer)
        KSPlayerScreen(
            plan: plan,
            title: title,
            initialPosition: initialPosition,
            minimumVideoDuration: minimumVideoDuration,
            onProgress: onProgress,
            watchChannel: watchChannel,
            onControlsVisibilityChanged: onControlsVisibilityChanged,
            onExhausted: onExhausted
        )
        #else
        AVPlayerScreen(
            plan: plan,
            title: title,
            initialPosition: initialPosition,
            minimumVideoDuration: minimumVideoDuration,
            onProgress: onProgress,
            watchChannel: watchChannel,
            onControlsVisibilityChanged: onControlsVisibilityChanged,
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
        // Bunny owns both its native and direct-FFmpeg paths. Selecting it is
        // an explicit request to stay in Bunny rather than visibly switching
        // to KSPlayer or VLC after a decoder error.
        if preferred == .bunny {
            return [.bunny]
        }
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
            fallbacks = [.vlcKit, .ksPlayer, .bunny]
        } else if ["mkv", "webm", "avi"].contains(pathExtension)
            || ["x265", "hevc", "av1", "flac"].contains(where: sourceHint.contains) {
            fallbacks = [.ksPlayer, .vlcKit, .bunny]
        } else if ["m3u8", "mp4", "mov", "m4v"].contains(pathExtension)
            || ["hls", "h264", "avc", "aac"].contains(where: sourceHint.contains) {
            fallbacks = [.bunny, .vlcKit, .ksPlayer]
        } else {
            fallbacks = [.vlcKit, .ksPlayer, .bunny]
        }
        return ([preferred] + fallbacks).reduce(into: []) { result, player in
            if !result.contains(player) { result.append(player) }
        }
    }
}

struct PlayerScreen: View {
    @EnvironmentObject private var watchTogether: WatchTogetherModel
    let title: String
    private let plan: PlaybackPlan
    private let contentKey: String
    private let contentType: String
    private let watchContentTitle: String
    private let minimumVideoDuration: TimeInterval
    private let onProgress: PlaybackProgressHandler?
    private let onExhausted: (@MainActor (Error) -> Void)?
    private let playerOrder: [StremioInternalPlayer]
    @State private var activePlayerIndex = 0
    @State private var bridgeFailureMessage: String?
    @State private var bridgeRevision = 0
    @State private var bridgeNotice: String?
    @State private var progressReference: PlaybackProgressReference
    @State private var didRunSimulatorPlayerSwitch = false
    @State private var playerChromeVisible = true
    @State private var watchRoomPresented = false
    @StateObject private var watchChannel = WatchPlaybackControlChannel()

    init(
        plan: PlaybackPlan,
        title: String,
        initialPosition: TimeInterval = 0,
        contentIdentifier: String? = nil,
        contentType: String = "movie",
        watchContentTitle: String? = nil,
        minimumVideoDuration: TimeInterval = 4,
        onProgress: PlaybackProgressHandler? = nil,
        onExhausted: (@MainActor (Error) -> Void)? = nil
    ) {
        self.plan = plan
        self.title = title
        self.contentKey = contentIdentifier ?? "title:\(title)"
        self.contentType = contentType
        self.watchContentTitle = watchContentTitle ?? title
        self.minimumVideoDuration = minimumVideoDuration
        self.onProgress = onProgress
        self.onExhausted = onExhausted
        playerOrder = StremioPlayerBridge.order(
            preferred: StremioInternalPlayer.selected,
            sourceURL: plan.primaryURL,
            title: [title, plan.detectedMIMEType].compactMap { $0 }.joined(separator: " ")
        )
        _progressReference = State(
            initialValue: PlaybackProgressReference(position: initialPosition)
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

            if playerChromeVisible, bridgeFailureMessage == nil {
                VStack {
                    HStack {
                        Spacer()
                        WatchRoomVoiceButton(contentKey: contentKey)
                        WatchRoomPlayerButton(
                            contentKey: contentKey,
                            contentType: contentType,
                            contentTitle: watchContentTitle,
                            showsRoom: $watchRoomPresented
                        )
                    }
                    Spacer()
                }
                .padding(.top, 54)
                .padding(.trailing, 14)
                .transition(.opacity)
            }

        }
        .onAppear {
            PlayerPresentation.synchronizeWithCurrentOrientation()
            watchTogether.attachPlayer(watchChannel, contentKey: contentKey)
        }
        .onChange(of: activePlayerIndex) { _ in
            playerChromeVisible = true
            PlayerPresentation.synchronizeWithCurrentOrientation()
        }
        .onDisappear {
            watchTogether.detachPlayer(watchChannel)
            PlayerPresentation.restorePortrait()
        }
        .task {
            await runSimulatorPlayerSwitchIfRequested()
        }
        .watchTogetherRoomSheet(
            isPresented: $watchRoomPresented,
            contentKey: contentKey,
            contentType: contentType,
            contentTitle: watchContentTitle
        )
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
                initialPosition: progressReference.position,
                minimumVideoDuration: minimumVideoDuration,
                onProgress: handleProgress,
                watchChannel: watchChannel,
                onControlsVisibilityChanged: updatePlayerChromeVisibility,
                onExhausted: { handlePlayerFailure(player: player, error: $0) }
            )
        case .bunny:
            BunnyPlayerScreen(
                plan: plan,
                title: title,
                initialPosition: progressReference.position,
                minimumVideoDuration: minimumVideoDuration,
                onProgress: handleProgress,
                watchChannel: watchChannel,
                onControlsVisibilityChanged: updatePlayerChromeVisibility,
                onExhausted: { handlePlayerFailure(player: player, error: $0) }
            )
        case .ksPlayer:
            #if canImport(KSPlayer)
            KSPlayerScreen(
                plan: plan,
                title: title,
                initialPosition: progressReference.position,
                minimumVideoDuration: minimumVideoDuration,
                onProgress: handleProgress,
                watchChannel: watchChannel,
                onControlsVisibilityChanged: updatePlayerChromeVisibility,
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
                initialPosition: progressReference.position,
                minimumVideoDuration: minimumVideoDuration,
                onProgress: handleProgress,
                watchChannel: watchChannel,
                onControlsVisibilityChanged: updatePlayerChromeVisibility,
                onExhausted: { handlePlayerFailure(player: player, error: $0) }
            )
            #else
            PlayerBridgeForcedFailureView(player: player) { error in
                handlePlayerFailure(player: player, error: error)
            }
            #endif
            }
        }
    }

    @MainActor
    private func updatePlayerChromeVisibility(_ isVisible: Bool) {
        playerChromeVisible = isVisible
    }

    @ViewBuilder
    private func bridgeFailure(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "play.slash")
                .font(.system(size: 44))
                .foregroundStyle(Color.appAccent)
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
            .tint(Color.appAccent)
        }
        .padding(28)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 22))
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .accessibilityIdentifier("player-bridge-error")
    }

    @MainActor
    private func handleProgress(
        position: TimeInterval,
        duration: TimeInterval,
        updateKind: PlaybackProgressUpdateKind
    ) {
        guard position.isFinite, duration.isFinite else { return }
        progressReference.update(position: position, duration: duration)
        onProgress?(
            progressReference.position,
            progressReference.duration,
            updateKind
        )
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
                bridgeFailureMessage = "The selected player could not play this stream. Try another source."
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

    @MainActor
    private func runSimulatorPlayerSwitchIfRequested() async {
        #if targetEnvironment(simulator)
        guard !didRunSimulatorPlayerSwitch,
              let rawInterval = ProcessInfo.processInfo.environment[
                "SKELETON_PLAYER_UI_SWITCH_INTERVAL"
              ],
              let interval = Double(rawInterval), interval > 0
        else { return }
        didRunSimulatorPlayerSwitch = true

        for nextIndex in playerOrder.indices.dropFirst(activePlayerIndex + 1) {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            let previousPlayer = activePlayer
            activePlayerIndex = nextIndex
            bridgeRevision += 1
            let nextPlayer = activePlayer
            bridgeNotice = "Testing \(nextPlayer.title) layout"
            NSLog(
                "PLAYER_UI_SWITCH from=%@ to=%@ orientation_preserved=yes",
                previousPlayer.rawValue,
                nextPlayer.rawValue
            )
        }
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
    let id: String
    let stream: Stream
    let providerName: String?
    let contentIdentifier: String?
    let contentTitle: String?
    let initialPosition: TimeInterval
    let mediaMetadata: PlaybackMediaMetadata?

    init(
        stream: Stream,
        providerName: String?,
        contentIdentifier: String? = nil,
        contentTitle: String? = nil,
        initialPosition: TimeInterval = 0,
        mediaMetadata: PlaybackMediaMetadata? = nil,
        sourceID: String? = nil
    ) {
        id = sourceID ?? "\(providerName ?? "unknown")#\(stream.id)"
        self.stream = stream
        self.providerName = providerName
        self.contentIdentifier = contentIdentifier
        self.contentTitle = contentTitle
        self.initialPosition = max(initialPosition, 0)
        self.mediaMetadata = mediaMetadata
    }
}

struct EpisodeAutoplayContext {
    let series: MetaItem
    let episode: Video

    var nextEpisode: Video? {
        EpisodeAutoplaySelector.nextEpisode(
            after: episode,
            episodes: series.videos ?? []
        )
    }

    func advancing(to episode: Video) -> Self {
        Self(series: series, episode: episode)
    }
}

struct ResolvingPlayerScreen: View {
    @EnvironmentObject private var model: AppModel
    let candidates: [StreamPlaybackCandidate]
    let minimumVideoDuration: TimeInterval
    let episodeAutoplayContext: EpisodeAutoplayContext?
    @State private var activeCandidateIndex = 0
    @State private var playbackPlan: PlaybackPlan?
    @State private var error: String?
    @State private var pendingFailover: PendingStreamFailover?
    @State private var countdownRemaining = StreamFailoverPolicy.countdownSeconds
    @State private var resumePosition: TimeInterval
    @State private var pendingEpisodeAutoplay: PendingEpisodeAutoplay?
    @State private var episodeAutoplayCountdown = 8
    @State private var nextEpisodeCandidates: [StreamPlaybackCandidate] = []
    @State private var nextEpisodeLoadError: String?
    @State private var isLoadingNextEpisode = false
    @State private var didOfferEpisodeAutoplay = false
    @State private var episodeAutoplayDestination: EpisodeAutoplayDestination?
    @State private var isPresentingNextEpisode = false

    private struct PendingStreamFailover: Identifiable, Equatable {
        let id = UUID()
        let nextIndex: Int
        let nextTitle: String
    }

    private struct PendingEpisodeAutoplay: Identifiable {
        let id = UUID()
        let episode: Video
    }

    private struct EpisodeAutoplayDestination {
        let context: EpisodeAutoplayContext
        let candidates: [StreamPlaybackCandidate]
    }

    init(
        stream: Stream,
        minimumVideoDuration: TimeInterval = 4,
        episodeAutoplayContext: EpisodeAutoplayContext? = nil
    ) {
        self.init(
            candidate: StreamPlaybackCandidate(stream: stream, providerName: nil),
            minimumVideoDuration: minimumVideoDuration,
            episodeAutoplayContext: episodeAutoplayContext
        )
    }

    init(
        candidate: StreamPlaybackCandidate,
        minimumVideoDuration: TimeInterval = 4,
        episodeAutoplayContext: EpisodeAutoplayContext? = nil
    ) {
        self.init(
            candidates: [candidate],
            minimumVideoDuration: minimumVideoDuration,
            episodeAutoplayContext: episodeAutoplayContext
        )
    }

    init(
        candidates: [StreamPlaybackCandidate],
        minimumVideoDuration: TimeInterval = 4,
        episodeAutoplayContext: EpisodeAutoplayContext? = nil
    ) {
        precondition(!candidates.isEmpty, "ResolvingPlayerScreen requires a stream")
        self.candidates = candidates
        self.minimumVideoDuration = minimumVideoDuration
        self.episodeAutoplayContext = episodeAutoplayContext
        _resumePosition = State(initialValue: candidates[0].initialPosition)
    }

    private var activeCandidate: StreamPlaybackCandidate {
        candidates[min(activeCandidateIndex, candidates.count - 1)]
    }

    private var activeStream: Stream { activeCandidate.stream }

    var body: some View {
        ZStack {
            Group {
                if let playbackPlan {
                    PlayerScreen(
                        plan: playbackPlan,
                        title: playbackTitle,
                        initialPosition: resumePosition,
                        contentIdentifier: activeCandidate.contentIdentifier,
                        contentType: activeCandidate.contentIdentifier?.split(separator: ":").first.map(String.init) ?? "movie",
                        watchContentTitle: activeCandidate.contentTitle,
                        minimumVideoDuration: minimumVideoDuration,
                        onProgress: recordProgress,
                        onExhausted: beginSourceFailover
                    )
                } else if let error, pendingFailover == nil {
                    VStack(spacing: 12) {
                        Image(systemName: "play.slash").font(.system(size: 44))
                        Text("Playback unavailable").font(.title3.bold())
                        Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding()
                    .accessibilityIdentifier("player-resolution-error")
                } else if pendingFailover == nil {
                    ProgressView(progressMessage)
                }
            }

            if let pendingFailover {
                failoverCountdown(pendingFailover)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            if let pendingEpisodeAutoplay, pendingFailover == nil {
                episodeAutoplayCard(pendingEpisodeAutoplay)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(3)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .animation(.easeOut(duration: 0.18), value: pendingFailover)
        .animation(.easeOut(duration: 0.22), value: pendingEpisodeAutoplay?.id)
        .task(id: activeCandidate.id) {
            await resolveActiveSource()
        }
        .task(id: pendingFailover?.id) {
            guard let pendingFailover else { return }
            await runFailoverCountdown(pendingFailover)
        }
        .task(id: pendingEpisodeAutoplay?.id) {
            guard let pendingEpisodeAutoplay else { return }
            await prepareNextEpisode(for: pendingEpisodeAutoplay)
        }
        .task(id: pendingEpisodeAutoplay?.id) {
            guard let pendingEpisodeAutoplay else { return }
            await runEpisodeAutoplayCountdown(pendingEpisodeAutoplay)
        }
        .task {
            await showEpisodeAutoplayPreviewIfRequested()
        }
        .navigationDestination(isPresented: $isPresentingNextEpisode) {
            if let destination = episodeAutoplayDestination {
                ResolvingPlayerScreen(
                    candidates: destination.candidates,
                    minimumVideoDuration: minimumVideoDuration,
                    episodeAutoplayContext: destination.context
                )
            }
        }
    }

    private func episodeAutoplayCard(_ pending: PendingEpisodeAutoplay) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                nextEpisodeThumbnail(pending.episode)

                VStack(alignment: .leading, spacing: 3) {
                    Text("UP NEXT")
                        .font(.caption2.weight(.black))
                        .tracking(0.8)
                        .foregroundStyle(Color.appAccent)
                    Text(episodeLabel(pending.episode))
                        .font(.headline)
                    if let title = pending.episode.title,
                       !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }

            if let nextEpisodeLoadError {
                Text(nextEpisodeLoadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(
                    isLoadingNextEpisode
                        ? "Finding the best stream…"
                        : "Playing automatically in \(episodeAutoplayCountdown)s"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
            }

            HStack(spacing: 9) {
                Button("Not Now") {
                    cancelEpisodeAutoplay()
                }
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.72))

                Button {
                    playNextEpisodeIfReady()
                } label: {
                    Label(
                        isLoadingNextEpisode ? "Preparing" : "Play Now",
                        systemImage: "forward.end.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.appAccent)
                .foregroundStyle(.black)
                .disabled(nextEpisodeLoadError != nil)
            }
            .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(width: 326, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.appAccent.opacity(0.32), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.48), radius: 18, y: 8)
        .padding(18)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("episode-up-next")
    }

    @ViewBuilder
    private func nextEpisodeThumbnail(_ episode: Video) -> some View {
        if let thumbnail = episode.thumbnail {
            AsyncImage(url: thumbnail, transaction: Transaction(animation: nil)) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    episodeThumbnailPlaceholder
                }
            }
            .frame(width: 112, height: 63)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            episodeThumbnailPlaceholder
                .frame(width: 112, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private var episodeThumbnailPlaceholder: some View {
        Rectangle()
            .fill(Color.white.opacity(0.10))
            .overlay {
                Image(systemName: "tv")
                    .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private func failoverCountdown(_ pending: PendingStreamFailover) -> some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()

            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.16), lineWidth: 5)
                    Circle()
                        .trim(
                            from: 0,
                            to: CGFloat(countdownRemaining)
                                / CGFloat(failoverCountdownSeconds)
                        )
                        .stroke(
                            Color.appAccent,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Text("\(countdownRemaining)")
                        .font(.title.bold().monospacedDigit())
                }
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

                Text("Stream unavailable")
                    .font(.title3.bold())
                Text("Trying the next stream in \(countdownRemaining)s")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.appAccent)
                    .accessibilityIdentifier("stream-failover-countdown")
                Text(pending.nextTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Button {
                    completeSourceFailover(pending)
                } label: {
                    Label("Continue to Next Stream", systemImage: "forward.end.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.appAccent)
                .foregroundStyle(.black)
                .accessibilityIdentifier("stream-failover-continue")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 340)
            .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Color.appAccent.opacity(0.32), lineWidth: 1)
            }
            .padding()
        }
    }

    @MainActor
    private func resolveActiveSource() async {
        playbackPlan = nil
        error = nil
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            playbackPlan = try await model.playbackPlan(
                for: activeStream,
                providerName: activeCandidate.providerName
            )
            let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            NSLog(
                "STREAM_BENCHMARK resolve_ms=%.1f source=%ld/%ld title=%@",
                elapsed,
                activeCandidateIndex + 1,
                candidates.count,
                playbackTitle
            )
        } catch let resolutionError {
            let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            NSLog(
                "STREAM_BENCHMARK failed_ms=%.1f source=%ld/%ld title=%@ error=%@",
                elapsed,
                activeCandidateIndex + 1,
                candidates.count,
                playbackTitle,
                resolutionError.localizedDescription
            )
            beginSourceFailover(resolutionError)
        }
    }

    private var playbackTitle: String {
        let value = [activeStream.title, activeStream.name, activeStream.description]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? activeCandidate.stream.displayName
        return String(value.split(separator: "\n", maxSplits: 1).first?.prefix(64) ?? "Stream")
    }

    private var progressMessage: String {
        activeStream.isTorrent ? "Starting torrent…" : "Preparing stream…"
    }

    @MainActor
    private func recordProgress(
        position: TimeInterval,
        duration: TimeInterval,
        updateKind: PlaybackProgressUpdateKind
    ) {
        if position.isFinite, (position >= 1 || resumePosition <= 0) {
            resumePosition = max(position, 0)
        }
        model.recordPlaybackProgress(
            contentIdentifier: activeCandidate.contentIdentifier,
            contentTitle: activeCandidate.contentTitle,
            stream: activeCandidate.stream,
            providerName: activeCandidate.providerName,
            position: position,
            duration: duration,
            mediaMetadata: activeCandidate.mediaMetadata,
            updateKind: updateKind
        )
        if EpisodeAutoplayPresentationPolicy.shouldPresent(
            position: position,
            duration: duration,
            isFinalUpdate: updateKind == .final
        ) {
            beginEpisodeAutoplayIfAvailable()
        }
    }

    @MainActor
    private func beginEpisodeAutoplayIfAvailable() {
        guard !didOfferEpisodeAutoplay,
              pendingEpisodeAutoplay == nil,
              let nextEpisode = episodeAutoplayContext?.nextEpisode
        else { return }
        didOfferEpisodeAutoplay = true
        episodeAutoplayCountdown = 8
        nextEpisodeCandidates = []
        nextEpisodeLoadError = nil
        isLoadingNextEpisode = true
        pendingEpisodeAutoplay = PendingEpisodeAutoplay(episode: nextEpisode)
        NSLog(
            "EPISODE_AUTOPLAY offered current=%@ next=%@",
            episodeAutoplayContext?.episode.id ?? "unknown",
            nextEpisode.id
        )
    }

    @MainActor
    private func prepareNextEpisode(for pending: PendingEpisodeAutoplay) async {
        guard let context = episodeAutoplayContext else { return }
        let providers = await model.streamProviders(
            for: context.series,
            videoID: pending.episode.id
        )
        guard pendingEpisodeAutoplay?.id == pending.id, !Task.isCancelled else {
            return
        }

        let playable = rankedPresentedStreams(from: providers).filter {
            $0.stream.isDirectlyPlayable || $0.stream.isTorrent
        }
        guard !playable.isEmpty else {
            isLoadingNextEpisode = false
            nextEpisodeLoadError = "No playable stream was found for this episode."
            NSLog("EPISODE_AUTOPLAY no_streams next=%@", pending.episode.id)
            return
        }

        let preferred = playable.first {
            $0.providerName == activeCandidate.providerName
        } ?? playable[0]
        nextEpisodeCandidates = orderedPlaybackCandidates(
            from: playable,
            startingAt: preferred.id,
            contentIdentifier: EpisodePlaybackIdentity.contentIdentifier(
                seriesID: context.series.id,
                videoID: pending.episode.id
            ),
            contentTitle: EpisodePlaybackIdentity.contentTitle(
                seriesTitle: context.series.name,
                video: pending.episode
            ),
            initialPosition: 0,
            mediaMetadata: .episode(
                series: context.series,
                episode: pending.episode
            )
        )
        isLoadingNextEpisode = false
        NSLog(
            "EPISODE_AUTOPLAY ready next=%@ streams=%ld provider=%@",
            pending.episode.id,
            nextEpisodeCandidates.count,
            preferred.providerName
        )
        if episodeAutoplayCountdown == 0 {
            playNextEpisodeIfReady()
        }
    }

    @MainActor
    private func runEpisodeAutoplayCountdown(
        _ pending: PendingEpisodeAutoplay
    ) async {
        for value in stride(from: 8, through: 1, by: -1) {
            guard pendingEpisodeAutoplay?.id == pending.id,
                  !Task.isCancelled
            else { return }
            episodeAutoplayCountdown = value
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
        guard pendingEpisodeAutoplay?.id == pending.id,
              !Task.isCancelled
        else { return }
        episodeAutoplayCountdown = 0
        playNextEpisodeIfReady()
    }

    @MainActor
    private func playNextEpisodeIfReady() {
        guard let pending = pendingEpisodeAutoplay,
              let context = episodeAutoplayContext,
              !nextEpisodeCandidates.isEmpty
        else {
            episodeAutoplayCountdown = 0
            return
        }
        episodeAutoplayDestination = EpisodeAutoplayDestination(
            context: context.advancing(to: pending.episode),
            candidates: nextEpisodeCandidates
        )
        pendingEpisodeAutoplay = nil
        isPresentingNextEpisode = true
        NSLog("EPISODE_AUTOPLAY playing next=%@", pending.episode.id)
    }

    @MainActor
    private func cancelEpisodeAutoplay() {
        pendingEpisodeAutoplay = nil
        nextEpisodeCandidates = []
        nextEpisodeLoadError = nil
        isLoadingNextEpisode = false
        NSLog("EPISODE_AUTOPLAY cancelled")
    }

    private func episodeLabel(_ episode: Video) -> String {
        if let season = episode.season, let number = episode.episode {
            return "S\(season) E\(number)"
        }
        if let number = episode.episode { return "Episode \(number)" }
        return "Next Episode"
    }

    @MainActor
    private func showEpisodeAutoplayPreviewIfRequested() async {
        #if targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        guard environment["SKELETON_EPISODE_AUTOPLAY_PREVIEW"] == "1"
                || environment["UI_SCREENSHOT_STATE"] == "episode-up-next"
        else { return }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        beginEpisodeAutoplayIfAvailable()
        #endif
    }

    @MainActor
    private func beginSourceFailover(_ playbackError: Error) {
        guard pendingFailover == nil else { return }
        playbackPlan = nil
        guard let nextIndex = StreamFailoverPolicy.nextSourceIndex(
            after: activeCandidateIndex,
            sourceCount: candidates.count
        ) else {
            error = "Every available stream was tried, but none returned playable media. Go back and choose a different provider."
            NSLog(
                "STREAM_PLAYBACK exhausted sources=%ld error=%@",
                candidates.count,
                playbackError.localizedDescription
            )
            return
        }

        let nextCandidate = candidates[nextIndex]
        countdownRemaining = failoverCountdownSeconds
        pendingFailover = PendingStreamFailover(
            nextIndex: nextIndex,
            nextTitle: sourceTitle(for: nextCandidate)
        )
        NSLog(
            "STREAM_PLAYBACK failover from=%ld to=%ld countdown=%ld error=%@",
            activeCandidateIndex + 1,
            nextIndex + 1,
            failoverCountdownSeconds,
            playbackError.localizedDescription
        )
    }

    @MainActor
    private func runFailoverCountdown(_ pending: PendingStreamFailover) async {
        for value in stride(from: failoverCountdownSeconds, through: 1, by: -1) {
            guard pendingFailover?.id == pending.id, !Task.isCancelled else { return }
            countdownRemaining = value
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
        guard pendingFailover?.id == pending.id, !Task.isCancelled else { return }
        completeSourceFailover(pending)
    }

    @MainActor
    private func completeSourceFailover(_ pending: PendingStreamFailover) {
        guard pendingFailover?.id == pending.id else { return }
        activeCandidateIndex = pending.nextIndex
        playbackPlan = nil
        error = nil
        pendingFailover = nil
        NSLog(
            "STREAM_PLAYBACK selected source=%ld/%ld resume=%.1f",
            activeCandidateIndex + 1,
            candidates.count,
            resumePosition
        )
    }

    private func sourceTitle(for candidate: StreamPlaybackCandidate) -> String {
        let title = [
            candidate.stream.title,
            candidate.stream.name,
            candidate.stream.description,
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
            ?? candidate.stream.displayName
        let compactTitle = String(
            title.split(separator: "\n", maxSplits: 1).first?.prefix(64) ?? "Next stream"
        )
        guard let provider = candidate.providerName, !provider.isEmpty else {
            return compactTitle
        }
        return "\(provider) · \(compactTitle)"
    }

    private var failoverCountdownSeconds: Int {
        #if targetEnvironment(simulator)
        if let rawValue = ProcessInfo.processInfo.environment[
            "SKELETON_FAILOVER_TEST_COUNTDOWN_SECONDS"
        ], let value = Int(rawValue), (3...30).contains(value) {
            return value
        }
        #endif
        return StreamFailoverPolicy.countdownSeconds
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
