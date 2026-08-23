#if SKELETON_SCREENSHOT_HARNESS
import SwiftUI

/// The UI-state binary does not exercise playback. Keeping a tiny Bunny
/// surface here lets that lightweight harness avoid linking the full FFmpeg
/// decoder while the production simulator build continues to compile it.
struct BunnyPlayerScreen: View {
    init(
        plan: PlaybackPlan,
        title: String,
        initialPosition: TimeInterval = 0,
        minimumVideoDuration: TimeInterval = 4,
        onProgress: PlaybackProgressHandler? = nil,
        watchChannel: WatchPlaybackControlChannel? = nil,
        onControlsVisibilityChanged: (@MainActor (Bool) -> Void)? = nil,
        onExhausted: (@MainActor (Error) -> Void)? = nil
    ) {}

    init(url: URL, title: String) {}

    var body: some View {
        Color.black
            .overlay {
                Label("Bunny playback fixture", systemImage: "hare.fill")
                    .foregroundStyle(.secondary)
            }
    }
}
#endif
