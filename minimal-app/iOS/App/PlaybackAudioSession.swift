@preconcurrency import AVFoundation
import Foundation
import LiveKit

extension Notification.Name {
    static let playbackVoiceCaptureDidChange = Notification.Name(
        "TemuStream.playbackVoiceCaptureDidChange"
    )
}

/// Keeps movie playout and LiveKit capture under one AVAudioSession owner.
///
/// LiveKit already serializes AVAudioSession changes for its WebRTC engine.
/// Registering the player as an external playout requirement lets the SDK
/// transition between playback and play-and-record without deactivating the
/// movie's audio renderer in between.
@MainActor
enum PlaybackAudioSession {
    private static var playbackRequirement: SessionRequirementHandle?
    private static var fallbackPlaybackActive = false

    static var isPlaybackActive: Bool {
        playbackRequirement != nil || fallbackPlaybackActive
    }

    static func beginPlayback() {
        guard !isPlaybackActive else { return }
        do {
            playbackRequirement = try AudioManager.shared.acquireSessionRequirement(.playout)
            NSLog("PLAYBACK_AUDIO_SESSION state=playout category=%@", currentCategory)
        } catch {
            // Keep playback usable if LiveKit cannot acquire its requirement.
            // This fallback is intentionally used only when the shared owner
            // failed, so it cannot race normal microphone configuration.
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setActive(true)
                fallbackPlaybackActive = true
                NSLog(
                    "PLAYBACK_AUDIO_SESSION state=fallback_playout error=%@",
                    error.localizedDescription
                )
            } catch {
                NSLog("PLAYBACK_AUDIO_SESSION state=failed error=%@", error.localizedDescription)
            }
        }
    }

    static func endPlayback() {
        if let playbackRequirement {
            self.playbackRequirement = nil
            do {
                try playbackRequirement.release()
            } catch {
                NSLog("PLAYBACK_AUDIO_SESSION state=release_failed error=%@", error.localizedDescription)
            }
        }
        if fallbackPlaybackActive {
            fallbackPlaybackActive = false
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    static func reactivatePlayback() {
        guard isPlaybackActive else {
            beginPlayback()
            return
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("PLAYBACK_AUDIO_SESSION state=reactivate_failed error=%@", error.localizedDescription)
        }
    }

    static func voiceCaptureDidChange(isEnabled: Bool) {
        NSLog(
            "PLAYBACK_AUDIO_SESSION voice=%@ category=%@",
            isEnabled ? "live" : "off",
            currentCategory
        )
        NotificationCenter.default.post(
            name: .playbackVoiceCaptureDidChange,
            object: nil,
            userInfo: ["enabled": isEnabled]
        )
    }

    private static var currentCategory: String {
        let session = AVAudioSession.sharedInstance()
        return "\(session.category.rawValue)/\(session.mode.rawValue)"
    }

    #if targetEnvironment(simulator)
    private static var microphoneAuditRunning = false

    /// Starts WebRTC's actual microphone engine without joining a room. This
    /// simulator-only hook exercises the same playout + recording transition
    /// while a real Bunny stream is running.
    static func startMicrophoneAuditIfRequested() async {
        guard ProcessInfo.processInfo.environment["SKELETON_MICROPHONE_AUDIT"] == "1",
              !microphoneAuditRunning
        else { return }
        guard await MicrophonePermissionRequester.request() else {
            NSLog("MICROPHONE_AUDIT permission=denied")
            return
        }
        NSLog("MICROPHONE_AUDIT permission=granted state=starting")
        // WebRTC may synchronously rebuild its AVAudioEngine while changing
        // from playout to playout + recording. Keep that work off MainActor so
        // accepting the system permission alert cannot freeze player UI.
        let startError = await Task.detached(priority: .userInitiated) {
            do {
                try AudioManager.shared.startLocalRecording()
                return nil as String?
            } catch {
                return error.localizedDescription
            }
        }.value
        if let startError {
            NSLog("MICROPHONE_AUDIT state=failed error=%@", startError)
        } else {
            microphoneAuditRunning = true
            voiceCaptureDidChange(isEnabled: true)
            NSLog("MICROPHONE_AUDIT state=recording category=%@", currentCategory)
        }
    }

    static func stopMicrophoneAuditIfNeeded() {
        guard microphoneAuditRunning else { return }
        Task.detached(priority: .userInitiated) {
            do {
                try AudioManager.shared.stopLocalRecording()
            } catch {
                NSLog(
                    "MICROPHONE_AUDIT state=stop_failed error=%@",
                    error.localizedDescription
                )
            }
        }
        microphoneAuditRunning = false
        voiceCaptureDidChange(isEnabled: false)
    }
    #endif
}

/// AVAudioSession invokes its legacy permission callback on a private TCC
/// queue. Keeping this helper explicitly nonisolated prevents Swift 6 from
/// asserting that the callback already runs on MainActor before it resumes the
/// awaiting UI task.
enum MicrophonePermissionRequester {
    nonisolated static func request() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
}
