@preconcurrency import AVFoundation
import Foundation

extension Notification.Name {
    static let playbackVoiceCaptureDidChange = Notification.Name(
        "TemuStream.playbackVoiceCaptureDidChange"
    )
    static let playbackAudioOutputWasDisconnected = Notification.Name(
        "TemuStream.playbackAudioOutputWasDisconnected"
    )
}

/// Owns the movie playback audio session for the iOS release target.
@MainActor
enum PlaybackAudioSession {
    private static var playbackActive = false
    private static var contentChannelCount = 2
    private static var routeChangeObserver: NSObjectProtocol?
    private static var spatialCapabilityObserver: NSObjectProtocol?

    static var isPlaybackActive: Bool { playbackActive }

    static func beginPlayback() {
        observeOutputRouteChangesIfNeeded()
        guard !isPlaybackActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            // Match the system TV/AVPlayer route. The long-form video policy is
            // also the path Apple documents for reliable AirPlay buffering.
            try session.setCategory(
                .playback,
                mode: .moviePlayback,
                policy: .longFormVideo
            )
            // AirPods expose two hardware channels but can render a
            // multichannel movie bed. Without this declaration iOS treats the
            // app as stereo-only and doesn't offer the same Spatial Audio
            // path as AVPlayer.
            try session.setSupportsMultichannelContent(true)
            try session.setActive(true)
            playbackActive = true
            applyPreferredOutputConfiguration(session: session)
            NSLog(
                "PLAYBACK_AUDIO_SESSION state=playout category=%@ policy=%lu route=%@ channels=%ld sample_rate=%.0f multichannel=%@",
                currentCategory,
                session.routeSharingPolicy.rawValue,
                currentOutputTypes,
                session.outputNumberOfChannels,
                session.sampleRate,
                session.supportsMultichannelContent ? "yes" : "no"
            )
        } catch {
            NSLog("PLAYBACK_AUDIO_SESSION state=failed error=%@", error.localizedDescription)
        }
    }

    /// Supplies the channel count of the selected movie track. The source
    /// remains correctly tagged at its native layout; this preference only
    /// chooses the best hardware width supported by the current route.
    static func configurePlaybackContent(channelCount: Int) {
        contentChannelCount = min(max(channelCount, 1), 32)
        guard isPlaybackActive else { return }
        applyPreferredOutputConfiguration(session: AVAudioSession.sharedInstance())
    }

    static func endPlayback() {
        guard playbackActive else { return }
        playbackActive = false
        contentChannelCount = 2
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    static func reactivatePlayback() {
        guard isPlaybackActive else {
            beginPlayback()
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true)
            applyPreferredOutputConfiguration(session: session)
        } catch {
            NSLog("PLAYBACK_AUDIO_SESSION state=reactivate_failed error=%@", error.localizedDescription)
        }
    }

    /// Bluetooth connections are ordinary route changes, not interruptions.
    /// Reactivate the shared session immediately, then let the active player
    /// rebuild its renderer at the current playhead.
    @discardableResult
    private static func recoverPlaybackAfterRouteChange(reasonRawValue rawReason: UInt) -> Bool {
        guard isPlaybackActive else { return false }
        guard let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
              routeChangeNeedsPlaybackReactivation(reason)
        else { return false }

        reactivatePlayback()
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { $0.portType.rawValue }
            .joined(separator: ",")
        NSLog(
            "PLAYBACK_AUDIO_SESSION route_change=%ld outputs=%@ recovery=requested",
            rawReason,
            outputs.isEmpty ? "none" : outputs
        )
        return true
    }

    private static func routeChangeNeedsPlaybackReactivation(
        _ reason: AVAudioSession.RouteChangeReason
    ) -> Bool {
        switch reason {
        case .newDeviceAvailable:
            true
        // Do not force playback onto the speaker after headphones disappear.
        // AVPlayer retains ownership of its normal privacy pause.
        case .unknown, .oldDeviceUnavailable, .categoryChange, .override,
             .wakeFromSleep, .noSuitableRouteForCategory,
             .routeConfigurationChange:
            false
        @unknown default:
            false
        }
    }

    private static func observeOutputRouteChangesIfNeeded() {
        guard routeChangeObserver == nil else { return }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notification in
            guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey]
                    as? UInt
            else { return }
            Task { @MainActor in
                guard isPlaybackActive else { return }
                guard let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
                else { return }
                if reason == .oldDeviceUnavailable {
                    applyPreferredOutputConfiguration(
                        session: AVAudioSession.sharedInstance()
                    )
                    // Preserve Apple's headphones-unplug privacy behavior for
                    // custom renderers that do not pause automatically.
                    NotificationCenter.default.post(
                        name: .playbackAudioOutputWasDisconnected,
                        object: nil
                    )
                    NSLog("PLAYBACK_AUDIO_SESSION route_change=%ld privacy=pause", rawReason)
                    return
                }
                _ = recoverPlaybackAfterRouteChange(reasonRawValue: rawReason)
                applyPreferredOutputConfiguration(
                    session: AVAudioSession.sharedInstance()
                )
            }
        }
        spatialCapabilityObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.spatialPlaybackCapabilitiesChangedNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard isPlaybackActive else { return }
                applyPreferredOutputConfiguration(
                    session: AVAudioSession.sharedInstance()
                )
            }
        }
    }

    private static func applyPreferredOutputConfiguration(session: AVAudioSession) {
        let maximumChannels = max(session.maximumOutputNumberOfChannels, 1)
        let preferredChannels = min(contentChannelCount, maximumChannels)
        if session.preferredOutputNumberOfChannels != preferredChannels {
            do {
                try session.setPreferredOutputNumberOfChannels(preferredChannels)
            } catch {
                NSLog(
                    "PLAYBACK_AUDIO_SESSION output_configuration=failed source_channels=%ld preferred_channels=%ld maximum_channels=%ld error=%@",
                    contentChannelCount,
                    preferredChannels,
                    maximumChannels,
                    error.localizedDescription
                )
                return
            }
        }
        let spatialAudioEnabled = session.currentRoute.outputs.contains {
            $0.isSpatialAudioEnabled
        }
        NSLog(
            "PLAYBACK_AUDIO_SESSION output_configuration=ready source_channels=%ld preferred_channels=%ld actual_channels=%ld maximum_channels=%ld spatial=%@",
            contentChannelCount,
            preferredChannels,
            session.outputNumberOfChannels,
            maximumChannels,
            spatialAudioEnabled ? "enabled" : "disabled"
        )
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

    private static var currentOutputTypes: String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { $0.portType.rawValue }
        return outputs.isEmpty ? "none" : outputs.joined(separator: ",")
    }

    #if targetEnvironment(simulator)
    static func startMicrophoneAuditIfRequested() async {}
    static func stopMicrophoneAuditIfNeeded() {}
    #endif
}
