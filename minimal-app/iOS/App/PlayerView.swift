@preconcurrency import AVKit
@preconcurrency import CoreMedia
import SwiftUI
import UIKit

typealias PlaybackProgressHandler = @MainActor (
    _ position: TimeInterval,
    _ duration: TimeInterval,
    _ updateKind: PlaybackProgressUpdateKind
) -> Void

typealias PlaybackControlsVisibilityHandler = @MainActor (_ isVisible: Bool) -> Void
typealias PlaybackReadyHandler = @MainActor () -> Void

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

    private static let preferenceKey = "preferredInternalPlayer"
    private static let legacyAVPlayerKey = "useAVPlayer"
    private static let legacyVLCKey = "useVLCKit"

    var id: String { rawValue }
    var title: String { "Bunny" }
    var detail: String { "Rust container core + Apple system decoders" }
    var controlsSummary: String { "PiP / audio / subtitles / seeking" }

    static var selected: Self {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["SKELETON_INTERNAL_PLAYER"],
           override.lowercased() == Self.bunny.rawValue {
            return .bunny
        }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: preferenceKey) != Self.bunny.rawValue
            || defaults.bool(forKey: legacyAVPlayerKey)
            || defaults.bool(forKey: legacyVLCKey) {
            migrateLegacyPlayerPreference(defaults: defaults)
        }
        return .bunny
    }

    static func select(_ player: Self) {
        let defaults = UserDefaults.standard
        defaults.set(player.rawValue, forKey: preferenceKey)
        defaults.set(false, forKey: legacyAVPlayerKey)
        defaults.set(false, forKey: legacyVLCKey)
    }

    private static func migrateLegacyPlayerPreference(defaults: UserDefaults) {
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

/// Reference-backed handoff state shared by a resolving screen and its active
/// player. Unlike a value passed through a SwiftUI body update, this is armed
/// synchronously before navigation and cannot be stale when onDisappear runs.
@MainActor
final class PlayerOrientationHandoff: ObservableObject {
    private var pendingOrientation: UIInterfaceOrientationMask?

    func armForNextPlayer() {
        pendingOrientation = PlayerPresentation.currentOrientationMask
        NSLog(
            "PLAYER_LAYOUT armed episode handoff orientation=%@",
            pendingOrientation == .portrait ? "portrait" : "landscape"
        )
    }

    func consumePendingOrientation() -> UIInterfaceOrientationMask? {
        defer { pendingOrientation = nil }
        return pendingOrientation
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

    static var currentOrientationMask: UIInterfaceOrientationMask {
        guard let scene = foregroundScene else {
            return AppOrientationDelegate.supportedOrientations
        }
        let orientation = scene.effectiveGeometry.interfaceOrientation
        guard orientation != .unknown else {
            return AppOrientationDelegate.supportedOrientations
        }
        return orientation.isLandscape ? .landscape : .portrait
    }

    static func preserve(_ orientationMask: UIInterfaceOrientationMask) {
        AppOrientationDelegate.supportedOrientations = orientationMask
        guard let scene = foregroundScene else { return }
        scene.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
        let current = scene.effectiveGeometry.interfaceOrientation
        let alreadyMatches = orientationMask == .portrait
            ? current.isPortrait
            : current.isLandscape
        if !alreadyMatches {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientationMask)) { error in
                NSLog("Player orientation preservation failed: %@", error.localizedDescription)
            }
        }
        NSLog(
            "PLAYER_LAYOUT preserved orientation=%@",
            orientationMask == .portrait ? "portrait" : "landscape"
        )
    }

    static func restorePortrait() {
        NSLog("PLAYER_LAYOUT restoring orientation=portrait")
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
    private let onPlaybackReady: PlaybackReadyHandler?
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
        onPlaybackReady: PlaybackReadyHandler? = nil,
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
        self.onPlaybackReady = onPlaybackReady
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
                onPlaybackReady?()
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


/// Adaptive player backed by the Rust policy core. Apple-native streams stay
/// on AVFoundation; direct containers are demuxed by Bunny's Rust core and
/// supplied to Apple system decoders.
private struct PerformancePlayerScreen: View {
    let title: String
    private let plan: PlaybackPlan
    private let initialPosition: TimeInterval
    private let minimumVideoDuration: TimeInterval
    private let onProgress: PlaybackProgressHandler?
    private let onPlaybackReady: PlaybackReadyHandler?
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
        onPlaybackReady: PlaybackReadyHandler?,
        watchChannel: WatchPlaybackControlChannel?,
        onControlsVisibilityChanged: PlaybackControlsVisibilityHandler?,
        onExhausted: (@MainActor (Error) -> Void)?
    ) {
        self.plan = plan
        self.title = title
        self.initialPosition = max(initialPosition, 0)
        self.minimumVideoDuration = minimumVideoDuration
        self.onProgress = onProgress
        self.onPlaybackReady = onPlaybackReady
        self.watchChannel = watchChannel
        self.onControlsVisibilityChanged = onControlsVisibilityChanged
        self.onExhausted = onExhausted
        policy = PlaybackPerformanceCore.policy(
            url: plan.primaryURL,
            title: [title, plan.detectedMIMEType].compactMap { $0 }.joined(separator: " "),
            player: .bunny
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
                onPlaybackReady: onPlaybackReady,
                watchChannel: watchChannel,
                onControlsVisibilityChanged: onControlsVisibilityChanged,
                onExhausted: onExhausted
            )
        case .automatic, .bunnyRust:
            BunnyPlayerScreen(
                plan: plan,
                title: title,
                initialPosition: initialPosition,
                minimumVideoDuration: minimumVideoDuration,
                onProgress: onProgress,
                onPlaybackReady: onPlaybackReady,
                watchChannel: watchChannel,
                onControlsVisibilityChanged: onControlsVisibilityChanged,
                onExhausted: onExhausted
            )
        }
    }
}

private enum StremioPlayerBridge {
    static func order(
        preferred: StremioInternalPlayer,
        sourceURL: URL,
        title: String
    ) -> [StremioInternalPlayer] {
        _ = preferred
        _ = sourceURL
        _ = title
        return [.bunny]
    }
}

struct PlayerScreen: View {
    @EnvironmentObject private var watchTogether: WatchTogetherModel
    @AppStorage(WatchTogetherPreferences.enabledKey)
    private var watchTogetherEnabled = WatchTogetherPreferences.defaultEnabled
    let title: String
    private let plan: PlaybackPlan
    private let contentKey: String
    private let contentType: String
    private let watchContentTitle: String
    private let minimumVideoDuration: TimeInterval
    private let onProgress: PlaybackProgressHandler?
    private let onPlaybackReady: PlaybackReadyHandler?
    private let onExhausted: (@MainActor (Error) -> Void)?
    private let introSkipSegment: PlaybackSkipSegment?
    private let restoresPortraitOnDisappear: Bool
    private let orientationHandoff: PlayerOrientationHandoff?
    private let playerOrder: [StremioInternalPlayer]
    @State private var activePlayerIndex = 0
    @State private var bridgeFailureMessage: String?
    @State private var bridgeRevision = 0
    @State private var bridgeNotice: String?
    @State private var progressReference: PlaybackProgressReference
    @State private var didRunSimulatorPlayerSwitch = false
    @State private var playerChromeVisible = true
    @State private var introSkipVisible = false
    @State private var didSkipIntro = false
    @State private var isSkippingIntro = false
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
        onPlaybackReady: PlaybackReadyHandler? = nil,
        onExhausted: (@MainActor (Error) -> Void)? = nil,
        introSkipSegment: PlaybackSkipSegment? = nil,
        restoresPortraitOnDisappear: Bool = true,
        orientationHandoff: PlayerOrientationHandoff? = nil
    ) {
        self.plan = plan
        self.title = title
        self.contentKey = contentIdentifier ?? "title:\(title)"
        self.contentType = contentType
        self.watchContentTitle = watchContentTitle ?? title
        self.minimumVideoDuration = minimumVideoDuration
        self.onProgress = onProgress
        self.onPlaybackReady = onPlaybackReady
        self.onExhausted = onExhausted
        self.introSkipSegment = introSkipSegment
        self.restoresPortraitOnDisappear = restoresPortraitOnDisappear
        self.orientationHandoff = orientationHandoff
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
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Player screen")
                .accessibilityIdentifier("player-screen-\(contentKey)")
                .allowsHitTesting(false)

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

            if watchTogetherEnabled, playerChromeVisible, bridgeFailureMessage == nil {
                VStack {
                    HStack {
                        Spacer()
                        WatchRoomVoiceButton(
                            watch: watchTogether,
                            controls: watchTogether.playerControls,
                            contentKey: contentKey
                        )
                        WatchRoomPlayerButton(
                            controls: watchTogether.playerControls,
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

            if introSkipVisible,
               let introSkipSegment,
               bridgeFailureMessage == nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            Task { await skipIntro(introSkipSegment) }
                        } label: {
                            HStack(spacing: 9) {
                                if isSkippingIntro {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "forward.end.fill")
                                }
                                Text(introSkipSegment.title ?? "Skip Intro")
                                    .font(.subheadline.weight(.bold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 48)
                            .background(.black.opacity(0.82), in: Capsule())
                            .overlay {
                                Capsule().stroke(Color.white.opacity(0.34), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isSkippingIntro)
                        .accessibilityLabel("Skip Intro")
                        .accessibilityHint("Jumps to the exact end of the intro")
                        .accessibilityIdentifier("player-skip-intro")
                    }
                }
                .padding(.trailing, 22)
                .padding(.bottom, playerChromeVisible ? 104 : 30)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(6)
            }

        }
        .animation(.easeOut(duration: 0.18), value: introSkipVisible)
        .onAppear {
            PlayerPresentation.synchronizeWithCurrentOrientation()
            if watchTogetherEnabled {
                watchTogether.attachPlayer(watchChannel, contentKey: contentKey)
            }
        }
        .onChange(of: activePlayerIndex) { _ in
            playerChromeVisible = true
            PlayerPresentation.synchronizeWithCurrentOrientation()
        }
        .onDisappear {
            watchTogether.detachPlayer(watchChannel)
            if let preservedOrientation = orientationHandoff?.consumePendingOrientation() {
                PlayerPresentation.preserve(preservedOrientation)
                NSLog("PLAYER_LAYOUT preserved orientation for episode autoplay")
            } else if restoresPortraitOnDisappear {
                PlayerPresentation.restorePortrait()
            }
        }
        .onChange(of: watchTogetherEnabled) { enabled in
            if enabled {
                Task {
                    await watchTogether.setFeatureEnabled(true)
                    watchTogether.attachPlayer(watchChannel, contentKey: contentKey)
                }
            } else {
                watchRoomPresented = false
                watchTogether.detachPlayer(watchChannel)
                Task { await watchTogether.setFeatureEnabled(false) }
            }
        }
        .task {
            await runSimulatorPlayerSwitchIfRequested()
            if watchTogetherEnabled {
                await watchTogether.start()
                await watchTogether.runPlayerControlsUIAuditIfRequested(contentKey: contentKey)
            }
        }
        .task(id: introSkipSegment) {
            await monitorIntroSkipAvailability()
        }
        .watchTogetherRoomSheet(
            watch: watchTogether,
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
        case .bunny:
            BunnyPlayerScreen(
                plan: plan,
                title: title,
                initialPosition: progressReference.position,
                minimumVideoDuration: minimumVideoDuration,
                onProgress: handleProgress,
                onPlaybackReady: onPlaybackReady,
                watchChannel: watchChannel,
                onControlsVisibilityChanged: updatePlayerChromeVisibility,
                onExhausted: { handlePlayerFailure(player: player, error: $0) }
            )
            }
        }
    }

    @MainActor
    private func updatePlayerChromeVisibility(_ isVisible: Bool) {
        playerChromeVisible = isVisible
    }

    @MainActor
    private func monitorIntroSkipAvailability() async {
        introSkipVisible = false
        guard let introSkipSegment else { return }
        while !Task.isCancelled, !didSkipIntro {
            let shouldShow = watchChannel.sample().map {
                IntroSkipPolicy.shouldOfferSkip(
                    for: introSkipSegment,
                    position: $0.position
                )
            } ?? false
            if introSkipVisible != shouldShow {
                introSkipVisible = shouldShow
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    @MainActor
    private func skipIntro(_ segment: PlaybackSkipSegment) async {
        guard !isSkippingIntro,
              let target = IntroSkipPolicy.targetPosition(for: segment)
        else { return }
        let sample = watchChannel.sample()
        isSkippingIntro = true
        introSkipVisible = false
        didSkipIntro = true
        await watchChannel.applyRemote(
            WatchPlaybackAdjustment(targetPosition: target),
            baselineRate: sample?.rate ?? 1
        )
        isSkippingIntro = false
        NSLog(
            "PLAYER_SKIP intro from=%.3f to=%.3f confidence=%@ samples=%@",
            sample?.position ?? segment.start,
            target,
            segment.confidence.map { String(format: "%.3f", $0) } ?? "provider",
            segment.sampleSize.map(String.init) ?? "unknown"
        )
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

struct StreamPlaybackCandidate: Identifiable, Sendable {
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

    var playbackContentIdentity: PlaybackContentIdentity? {
        if let mediaMetadata {
            if let episodeID = mediaMetadata.episodeID {
                return .episode(
                    seriesID: mediaMetadata.mediaID,
                    videoID: episodeID
                )
            }
            return .movie(catalogID: mediaMetadata.mediaID)
        }
        guard let contentIdentifier else { return nil }
        if contentIdentifier.hasPrefix("series:"),
           let marker = contentIdentifier.range(of: ":episode:") {
            let seriesID = String(
                contentIdentifier[
                    contentIdentifier.index(
                        contentIdentifier.startIndex,
                        offsetBy: "series:".count
                    )..<marker.lowerBound
                ]
            )
            let videoID = String(contentIdentifier[marker.upperBound...])
            return .episode(seriesID: seriesID, videoID: videoID)
        }
        if contentIdentifier.hasPrefix("movie:") {
            return .movie(catalogID: String(contentIdentifier.dropFirst("movie:".count)))
        }
        return nil
    }

    var playbackPreferenceKey: PlaybackStreamPreferenceKey? {
        PlaybackStreamPreferenceKey(
            providerName: providerName,
            streamName: stream.name,
            streamTitle: stream.title,
            torrentInfoHash: stream.infoHash,
            fileIndex: stream.fileIdx
        )
    }
}

/// Applies the last proven provider/stream only after the current provider
/// responses have been ranked. It never resolves or revives a saved URL.
func lastSuccessfulPlaybackCandidates(
    from candidates: [StreamPlaybackCandidate],
    store: LastSuccessfulPlaybackPreferenceStore = .shared
) -> [StreamPlaybackCandidate] {
    guard let identity = candidates.first?.playbackContentIdentity,
          candidates.allSatisfy({ $0.playbackContentIdentity == identity })
    else {
        return candidates
    }
    let preference = store.preference(for: identity)
    return LastSuccessfulPlaybackRanker.rank(
        candidates,
        identity: identity,
        preference: preference,
        key: \StreamPlaybackCandidate.playbackPreferenceKey
    )
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
    @State private var episodeAutoplayCountdown = Int(
        EpisodeAutoplayPresentationPolicy.previewLeadTime
    )
    @State private var nextEpisodeCandidates: [StreamPlaybackCandidate] = []
    @State private var nextEpisodeLoadError: String?
    @State private var isLoadingNextEpisode = false
    @State private var didOfferEpisodeAutoplay = false
    @State private var shouldStartNextEpisode = false
    @State private var episodeAutoplayDestination: EpisodeAutoplayDestination?
    @State private var isPresentingNextEpisode = false
    @StateObject private var orientationHandoff = PlayerOrientationHandoff()
    @State private var resolutionRequestID: UUID?
    @State private var performanceTraceID: PerformanceTraceID?
    @State private var didRecordCandidateSuccess = false

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
                    let readyRequestID = resolutionRequestID
                    let readyCandidateID = activeCandidate.id
                    let readyTraceID = performanceTraceID
                    let readyIdentity = activeCandidate.playbackContentIdentity
                    let readyPreferenceKey = activeCandidate.playbackPreferenceKey
                    PlayerScreen(
                        plan: playbackPlan,
                        title: playbackTitle,
                        initialPosition: resumePosition,
                        contentIdentifier: activeCandidate.contentIdentifier,
                        contentType: activeCandidate.contentIdentifier?.split(separator: ":").first.map(String.init) ?? "movie",
                        watchContentTitle: activeCandidate.contentTitle,
                        minimumVideoDuration: minimumVideoDuration,
                        onProgress: recordProgress,
                        onPlaybackReady: {
                            recordFirstVisibleFrame(
                                requestID: readyRequestID,
                                candidateID: readyCandidateID,
                                traceID: readyTraceID,
                                identity: readyIdentity,
                                preferenceKey: readyPreferenceKey
                            )
                        },
                        onExhausted: { playbackError in
                            handlePlaybackExhausted(
                                playbackError,
                                requestID: readyRequestID,
                                candidateID: readyCandidateID
                            )
                        },
                        introSkipSegment: activeStream.introSkipSegment,
                        orientationHandoff: orientationHandoff
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
        .task(id: activeCandidateIndex) {
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
                    if let overview = pending.episode.overview?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                       !overview.isEmpty {
                        Text(overview)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("episode-up-next-summary")
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
                    requestNextEpisodeNow()
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
            .overlay(alignment: .topLeading) {
                Button {
                    cancelSourceFailover(pending)
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.12), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(12)
                .accessibilityLabel("Cancel automatic stream change")
                .accessibilityIdentifier("stream-failover-cancel")
            }
            .padding()
        }
    }

    @MainActor
    private func resolveActiveSource() async {
        playbackPlan = nil
        error = nil
        didRecordCandidateSuccess = false
        let requestID = UUID()
        resolutionRequestID = requestID
        let candidateID = activeCandidate.id
        let traceID = PerformanceMilestoneRecorder.shared.begin(
            flow: .playback,
            identity: activeCandidate.playbackContentIdentity?.storageKey
                ?? "playback-source-\(activeCandidateIndex)"
        )
        performanceTraceID = traceID
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            let resolvedPlan = try await model.playbackPlan(
                for: activeStream,
                providerName: activeCandidate.providerName
            )
            guard !Task.isCancelled,
                  resolutionRequestID == requestID,
                  activeCandidate.id == candidateID
            else { return }
            playbackPlan = resolvedPlan
            let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            let milestoneElapsed = PerformanceMilestoneRecorder.shared.mark(
                .streamResolved,
                for: traceID
            ) ?? elapsed
            NSLog(
                "STREAM_BENCHMARK resolve_ms=%.1f milestone_ms=%.1f source=%ld/%ld title=%@",
                elapsed,
                milestoneElapsed,
                activeCandidateIndex + 1,
                candidates.count,
                playbackTitle
            )
        } catch let resolutionError {
            guard !Task.isCancelled,
                  resolutionRequestID == requestID,
                  activeCandidate.id == candidateID
            else { return }
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

    @MainActor
    private func recordFirstVisibleFrame(
        requestID: UUID?,
        candidateID: String,
        traceID: PerformanceTraceID?,
        identity: PlaybackContentIdentity?,
        preferenceKey: PlaybackStreamPreferenceKey?
    ) {
        guard let requestID,
              resolutionRequestID == requestID,
              activeCandidate.id == candidateID,
              performanceTraceID == traceID,
              playbackPlan != nil
        else { return }
        guard !didRecordCandidateSuccess else { return }
        didRecordCandidateSuccess = true
        if let traceID,
           let elapsed = PerformanceMilestoneRecorder.shared.mark(
               .firstVisibleFrame,
               for: traceID
           ) {
            NSLog(
                "STREAM_BENCHMARK first_visible_frame_ms=%.1f source=%ld/%ld",
                elapsed,
                activeCandidateIndex + 1,
                candidates.count
            )
        }
        guard let identity,
              let preferenceKey
        else { return }
        LastSuccessfulPlaybackPreferenceStore.shared.recordSuccess(
            identity: identity,
            key: preferenceKey
        )
    }

    @MainActor
    private func handlePlaybackExhausted(
        _ playbackError: Error,
        requestID: UUID?,
        candidateID: String
    ) {
        guard let requestID,
              resolutionRequestID == requestID,
              activeCandidate.id == candidateID,
              playbackPlan != nil
        else { return }
        beginSourceFailover(playbackError)
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
            duration: duration
        ) {
            let countdown = EpisodeAutoplayPresentationPolicy.countdownSeconds(
                position: position,
                duration: duration
            )
            beginEpisodeAutoplayIfAvailable(initialCountdown: countdown)
            episodeAutoplayCountdown = countdown
            if EpisodeAutoplayPresentationPolicy.shouldStartNext(
                position: position,
                duration: duration,
                isFinalUpdate: updateKind == .final
            ) {
                shouldStartNextEpisode = true
                playNextEpisodeIfReady()
            }
        } else {
            resetEpisodeAutoplayAfterLeavingPreview()
        }
    }

    @MainActor
    private func beginEpisodeAutoplayIfAvailable(
        initialCountdown: Int = Int(
            EpisodeAutoplayPresentationPolicy.previewLeadTime
        )
    ) {
        guard !didOfferEpisodeAutoplay,
              pendingEpisodeAutoplay == nil,
              let nextEpisode = episodeAutoplayContext?.nextEpisode
        else { return }
        didOfferEpisodeAutoplay = true
        episodeAutoplayCountdown = max(initialCountdown, 0)
        nextEpisodeCandidates = []
        nextEpisodeLoadError = nil
        isLoadingNextEpisode = true
        shouldStartNextEpisode = false
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
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment[
            "SKELETON_EPISODE_AUTOPLAY_REUSE_FIXTURE_STREAM"
        ] == "1" {
            nextEpisodeCandidates = [
                StreamPlaybackCandidate(
                    stream: activeStream,
                    providerName: activeCandidate.providerName,
                    contentIdentifier: EpisodePlaybackIdentity.contentIdentifier(
                        seriesID: context.series.id,
                        videoID: pending.episode.id
                    ),
                    contentTitle: EpisodePlaybackIdentity.contentTitle(
                        seriesTitle: context.series.name,
                        video: pending.episode
                    ),
                    mediaMetadata: .episode(
                        series: context.series,
                        episode: pending.episode
                    ),
                    sourceID: "simulator-autoplay-next-\(pending.episode.id)"
                ),
            ]
            isLoadingNextEpisode = false
            NSLog(
                "EPISODE_AUTOPLAY ready next=%@ streams=1 provider=simulator-fixture",
                pending.episode.id
            )
            if shouldStartNextEpisode {
                playNextEpisodeIfReady()
            }
            return
        }
        #endif
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
        let orderedCandidates = orderedPlaybackCandidates(
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
        nextEpisodeCandidates = lastSuccessfulPlaybackCandidates(
            from: orderedCandidates
        )
        isLoadingNextEpisode = false
        NSLog(
            "EPISODE_AUTOPLAY ready next=%@ streams=%ld provider=%@",
            pending.episode.id,
            nextEpisodeCandidates.count,
            preferred.providerName
        )
        if shouldStartNextEpisode {
            playNextEpisodeIfReady()
        }
    }

    @MainActor
    private func requestNextEpisodeNow() {
        shouldStartNextEpisode = true
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
        orientationHandoff.armForNextPlayer()
        shouldStartNextEpisode = false
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
        shouldStartNextEpisode = false
        NSLog("EPISODE_AUTOPLAY cancelled")
    }

    @MainActor
    private func resetEpisodeAutoplayAfterLeavingPreview() {
        guard pendingEpisodeAutoplay != nil else { return }
        pendingEpisodeAutoplay = nil
        nextEpisodeCandidates = []
        nextEpisodeLoadError = nil
        isLoadingNextEpisode = false
        shouldStartNextEpisode = false
        didOfferEpisodeAutoplay = false
        episodeAutoplayCountdown = Int(
            EpisodeAutoplayPresentationPolicy.previewLeadTime
        )
        NSLog("EPISODE_AUTOPLAY hidden_outside_preview")
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
        resolutionRequestID = nil
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
    private func cancelSourceFailover(_ pending: PendingStreamFailover) {
        guard pendingFailover?.id == pending.id else { return }
        pendingFailover = nil
        error = "This stream did not open. Go back and choose another stream."
        NSLog(
            "STREAM_PLAYBACK failover_cancelled source=%ld/%ld",
            activeCandidateIndex + 1,
            candidates.count
        )
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
