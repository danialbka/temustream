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
}

@MainActor
final class WatchTogetherModel: ObservableObject {
    func start() async {}
    func attachPlayer(_ channel: WatchPlaybackControlChannel, contentKey: String) {}
    func detachPlayer(_ channel: WatchPlaybackControlChannel) {}
}

struct FriendsView: View {
    var body: some View {
        Label("Friends unavailable in snapshots", systemImage: "person.2")
    }
}

struct WatchRoomPlayerButton: View {
    let contentKey: String
    let contentType: String
    let contentTitle: String
    @Binding var showsRoom: Bool

    var body: some View { EmptyView() }
}

extension View {
    func watchTogetherRoomSheet(
        isPresented: Binding<Bool>,
        contentKey: String,
        contentType: String,
        contentTitle: String
    ) -> some View {
        self
    }
}

struct WatchRoomVoiceButton: View {
    let contentKey: String

    var body: some View { EmptyView() }
}

enum PlaybackAudioSession {
    static func beginPlayback() {}
    static func endPlayback() {}
}
#endif
