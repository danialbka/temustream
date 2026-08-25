#if SKELETON_SCREENSHOT_HARNESS
import SwiftUI

/// The screenshot harness renders player recovery UI without connecting to
/// Convex or LiveKit. Production builds continue to use WatchTogetherModel.
@MainActor
final class WatchPlaybackControlChannel: ObservableObject {
    typealias SampleProvider = @MainActor () -> WatchLocalPlaybackSample?
    typealias AdjustmentApplier = @MainActor (WatchPlaybackAdjustment, Double) async -> Void

    @discardableResult
    func register(
        sample: @escaping SampleProvider,
        apply: @escaping AdjustmentApplier
    ) -> UUID {
        UUID()
    }

    func unregister(_ id: UUID) {}

    func sample() -> WatchLocalPlaybackSample? { nil }

    func applyRemote(
        _ adjustment: WatchPlaybackAdjustment,
        baselineRate: Double
    ) async {}
}

@MainActor
final class WatchPlayerControlsModel: ObservableObject {}

@MainActor
final class WatchTogetherModel: ObservableObject {
    let playerControls = WatchPlayerControlsModel()

    func start() async {}
    func setFeatureEnabled(_ enabled: Bool) async {}
    func attachPlayer(_ channel: WatchPlaybackControlChannel, contentKey: String) {}
    func detachPlayer(_ channel: WatchPlaybackControlChannel) {}
    func runPlayerControlsUIAuditIfRequested(contentKey: String) async {}
}

struct FriendsView: View {
    var body: some View {
        Label("Friends unavailable in snapshots", systemImage: "person.2")
    }
}

struct WatchRoomPlayerButton: View {
    @ObservedObject var controls: WatchPlayerControlsModel
    let contentKey: String
    let contentType: String
    let contentTitle: String
    @Binding var showsRoom: Bool

    var body: some View {
        Button { showsRoom = true } label: {
            Image(systemName: "person.2")
                .font(.caption.weight(.semibold))
                .frame(width: 38, height: 38)
                .background(.black.opacity(0.68), in: Capsule())
                .overlay { Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel("Watch Together")
        .accessibilityIdentifier("watch-together-player-button")
    }
}

extension View {
    func watchTogetherRoomSheet(
        watch: WatchTogetherModel,
        isPresented: Binding<Bool>,
        contentKey: String,
        contentType: String,
        contentTitle: String
    ) -> some View {
        self
    }
}

struct WatchRoomVoiceButton: View {
    let watch: WatchTogetherModel
    @ObservedObject var controls: WatchPlayerControlsModel
    let contentKey: String

    var body: some View {
        Button {} label: {
            Image(systemName: "mic.slash")
                .font(.caption.weight(.semibold))
                .frame(width: 38, height: 38)
                .background(.black.opacity(0.68), in: Capsule())
                .overlay { Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel("Room voice muted")
        .accessibilityIdentifier("watch-together-microphone-toggle")
    }
}

enum PlaybackAudioSession {
    static func beginPlayback() {}
    static func endPlayback() {}
}
#endif
