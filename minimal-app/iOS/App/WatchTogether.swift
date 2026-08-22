@preconcurrency import AVFoundation
@preconcurrency import Combine
@preconcurrency import GroupActivities
import SwiftUI
import UIKit
#if canImport(_GroupActivities_UIKit)
import _GroupActivities_UIKit
#endif

struct WatchTogetherContent: Codable, Hashable, Identifiable, Sendable {
    let identifier: String
    let title: String

    var id: String { identifier }

    init(identifier: String? = nil, title: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = cleanTitle.isEmpty ? "Video" : String(cleanTitle.prefix(120))

        let cleanIdentifier = identifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let identifierLooksPrivate = cleanIdentifier?.contains("://") == true
            || cleanIdentifier?.contains("?") == true
            || cleanIdentifier?.contains("token=") == true
        if let cleanIdentifier, !cleanIdentifier.isEmpty, !identifierLooksPrivate {
            self.identifier = String(cleanIdentifier.prefix(240))
        } else {
            self.identifier = WatchTogetherContentIdentity.fallbackIdentifier(for: self.title)
        }
    }
}

private struct StremioWatchTogetherActivity: GroupActivity, Sendable {
    let content: WatchTogetherContent

    var metadata: GroupActivityMetadata {
        get async {
            var metadata = GroupActivityMetadata()
            metadata.type = .watchTogether
            metadata.title = content.title
            metadata.subtitle = "Watch together in Stremio"
            return metadata
        }
    }
}

/// Main-actor operations required to drive a non-AVPlayer playback engine.
/// The adapter never reports local commands back to SharePlay; only explicit
/// user actions call the coordinator, preventing remote-command echo loops.
@MainActor
struct WatchTogetherPlaybackAdapter {
    let content: WatchTogetherContent
    let currentTime: () -> TimeInterval
    let duration: () -> TimeInterval
    let isPlaying: () -> Bool
    let isReady: () -> Bool
    let play: () -> Void
    let pause: () -> Void
    let seek: (TimeInterval) async -> Bool
}

private final class WatchTogetherAVPlayerItemDelegate: NSObject,
    AVPlayerPlaybackCoordinatorDelegate,
    @unchecked Sendable
{
    let itemIdentifier: String

    init(itemIdentifier: String) {
        self.itemIdentifier = itemIdentifier
    }

    func playbackCoordinator(
        _ coordinator: AVPlayerPlaybackCoordinator,
        identifierFor playerItem: AVPlayerItem
    ) -> String {
        itemIdentifier
    }
}

private final class WatchTogetherPlaybackControlDelegate: NSObject,
    AVPlaybackCoordinatorPlaybackControlDelegate,
    @unchecked Sendable
{
    weak var owner: WatchTogetherCoordinator?

    nonisolated func playbackCoordinator(
        _ coordinator: AVDelegatingPlaybackCoordinator,
        didIssue playCommand: AVDelegatingPlaybackCoordinatorPlayCommand,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        Task { @MainActor [weak owner] in
            guard let owner else {
                completionHandler()
                return
            }
            await owner.apply(playCommand, completionHandler: completionHandler)
        }
    }

    nonisolated func playbackCoordinator(
        _ coordinator: AVDelegatingPlaybackCoordinator,
        didIssue pauseCommand: AVDelegatingPlaybackCoordinatorPauseCommand,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        Task { @MainActor [weak owner] in
            owner?.apply(pauseCommand)
            completionHandler()
        }
    }

    nonisolated func playbackCoordinator(
        _ coordinator: AVDelegatingPlaybackCoordinator,
        didIssue seekCommand: AVDelegatingPlaybackCoordinatorSeekCommand,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        Task { @MainActor [weak owner] in
            guard let owner else {
                completionHandler()
                return
            }
            await owner.apply(seekCommand, completionHandler: completionHandler)
        }
    }

    nonisolated func playbackCoordinator(
        _ coordinator: AVDelegatingPlaybackCoordinator,
        didIssue bufferingCommand: AVDelegatingPlaybackCoordinatorBufferingCommand,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        Task { @MainActor [weak owner] in
            guard let owner else {
                completionHandler()
                return
            }
            await owner.apply(bufferingCommand, completionHandler: completionHandler)
        }
    }
}

@MainActor
final class WatchTogetherCoordinator: ObservableObject, @unchecked Sendable {
    static let shared = WatchTogetherCoordinator()

    @Published private(set) var isActive = false
    @Published private(set) var isPreparing = false
    @Published private(set) var participantCount = 0
    @Published private(set) var sessionContent: WatchTogetherContent?
    @Published private(set) var hasMatchingPlayback = false
    @Published private(set) var lastActionText: String?
    @Published var errorMessage: String?

    private enum AttachmentKind {
        case none
        case native
        case custom
    }

    private let playbackControlDelegate: WatchTogetherPlaybackControlDelegate
    private let delegatingCoordinator: AVDelegatingPlaybackCoordinator
    private var session: GroupSession<StremioWatchTogetherActivity>?
    private var sessionSubscriptions = Set<AnyCancellable>()
    private var sessionObserverTask: Task<Void, Never>?
    private var connectedSessionID: UUID?
    private var attachmentKind = AttachmentKind.none
    private var attachmentToken: UUID?
    private var attachedContent: WatchTogetherContent?
    private weak var nativePlayer: AVPlayer?
    private var nativeItemDelegate: WatchTogetherAVPlayerItemDelegate?
    private var customAdapter: WatchTogetherPlaybackAdapter?
    private var actionClearTask: Task<Void, Never>?
    #if targetEnvironment(simulator)
    private var didRunInvitationSmoke = false
    #endif

    private init() {
        let delegate = WatchTogetherPlaybackControlDelegate()
        playbackControlDelegate = delegate
        delegatingCoordinator = AVDelegatingPlaybackCoordinator(
            playbackControlDelegate: delegate
        )
        delegatingCoordinator.pauseSnapsToMediaTimeOfOriginator = true
        delegate.owner = self
    }

    func startObservingSessions() {
        guard sessionObserverTask == nil else { return }
        sessionObserverTask = Task { @MainActor [weak self] in
            for await session in StremioWatchTogetherActivity.sessions() {
                guard !Task.isCancelled else { return }
                self?.accept(session)
            }
        }
    }

    func share(_ content: WatchTogetherContent) {
        startObservingSessions()
        errorMessage = nil
        isPreparing = true

        if let session, session.activity.content.identifier != content.identifier {
            session.leave()
            clearSession()
        }

        let activity = StremioWatchTogetherActivity(content: content)
        #if canImport(_GroupActivities_UIKit)
        do {
            let controller = try GroupActivitySharingController(activity)
            controller.modalPresentationStyle = .formSheet
            guard let presenter = Self.topViewController() else {
                isPreparing = false
                errorMessage = "Unable to present the SharePlay invitation."
                return
            }
            presenter.present(controller, animated: true)
            Task { @MainActor [weak self, controller] in
                let result = await controller.result
                self?.isPreparing = false
                if result == .cancelled {
                    self?.lastActionText = "SharePlay invitation cancelled"
                }
            }
            return
        } catch {
            NSLog("WATCH_TOGETHER sharing-controller error=%@", error.localizedDescription)
        }
        #endif

        Task { @MainActor [weak self] in
            await self?.activate(activity)
        }
    }

    func leave() {
        session?.leave()
        clearSession()
        showAction("Left the watch party")
    }

    func endForEveryone() {
        session?.end()
        clearSession()
        showAction("Watch party ended")
    }

    func attach(
        player: AVPlayer,
        content: WatchTogetherContent,
        token: UUID
    ) {
        if attachmentKind == .native,
           attachmentToken == token,
           nativePlayer === player,
           attachedContent == content {
            return
        }
        attachmentKind = .native
        attachmentToken = token
        attachedContent = content
        customAdapter = nil
        delegatingCoordinator.transitionToItem(
            withIdentifier: nil,
            proposingInitialTimingBasedOn: nil
        )

        nativePlayer = player
        let delegate = WatchTogetherAVPlayerItemDelegate(
            itemIdentifier: content.identifier
        )
        nativeItemDelegate = delegate
        player.playbackCoordinator.delegate = delegate
        player.playbackCoordinator.pauseSnapsToMediaTimeOfOriginator = true
        connectedSessionID = nil
        connectCurrentPlaybackIfPossible()
        refreshMatchState()
        runInvitationSmokeIfRequested(content)
    }

    func attach(
        adapter: WatchTogetherPlaybackAdapter,
        token: UUID
    ) {
        if attachmentKind == .custom,
           attachmentToken == token,
           attachedContent == adapter.content {
            customAdapter = adapter
            return
        }

        nativePlayer?.playbackCoordinator.delegate = nil
        nativePlayer = nil
        nativeItemDelegate = nil
        attachmentKind = .custom
        attachmentToken = token
        attachedContent = adapter.content
        customAdapter = adapter
        connectedSessionID = nil
        connectCurrentPlaybackIfPossible()
        refreshMatchState()
        runInvitationSmokeIfRequested(adapter.content)
    }

    func detach(token: UUID) {
        guard attachmentToken == token else { return }
        if attachmentKind == .native {
            nativePlayer?.playbackCoordinator.delegate = nil
        } else if attachmentKind == .custom {
            delegatingCoordinator.transitionToItem(
                withIdentifier: nil,
                proposingInitialTimingBasedOn: nil
            )
        }
        attachmentKind = .none
        attachmentToken = nil
        attachedContent = nil
        nativePlayer = nil
        nativeItemDelegate = nil
        customAdapter = nil
        connectedSessionID = nil
        refreshMatchState()
    }

    /// Returns true when the custom bridge owns this action. AVPlayer-backed
    /// surfaces return false and continue through their native controls, which
    /// AVPlayerPlaybackCoordinator intercepts automatically.
    @discardableResult
    func requestPlay(for contentIdentifier: String) -> Bool {
        guard let adapter = matchingCustomAdapter(contentIdentifier) else { return false }
        if isCoordinating(contentIdentifier) {
            delegatingCoordinator.coordinateRateChange(to: 1, options: [])
        } else {
            adapter.play()
        }
        return true
    }

    @discardableResult
    func requestPause(for contentIdentifier: String) -> Bool {
        guard let adapter = matchingCustomAdapter(contentIdentifier) else { return false }
        if isCoordinating(contentIdentifier) {
            delegatingCoordinator.coordinateRateChange(to: 0, options: [])
        } else {
            adapter.pause()
        }
        return true
    }

    @discardableResult
    func requestSeek(
        to position: TimeInterval,
        resumeAfterSeek: Bool,
        for contentIdentifier: String
    ) -> Bool {
        guard let adapter = matchingCustomAdapter(contentIdentifier) else { return false }
        let target = max(position, 0)
        if isCoordinating(contentIdentifier) {
            delegatingCoordinator.coordinateSeek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                options: []
            )
            if resumeAfterSeek {
                delegatingCoordinator.coordinateRateChange(to: 1, options: [])
            }
        } else {
            Task { @MainActor in
                adapter.pause()
                let finished = await adapter.seek(target)
                if finished, resumeAfterSeek { adapter.play() }
            }
        }
        return true
    }

    var statusText: String {
        guard isActive else { return "Watch Together" }
        if hasMatchingPlayback {
            return participantCount == 1
                ? "Watch party ready"
                : "\(participantCount) watching together"
        }
        if let sessionContent {
            return "Open \(sessionContent.title) to sync"
        }
        return "Watch party connected"
    }

    fileprivate func apply(
        _ command: AVDelegatingPlaybackCoordinatorPlayCommand,
        completionHandler: @escaping @Sendable () -> Void
    ) async {
        guard let adapter = validAdapter(for: command.expectedCurrentItemIdentifier) else {
            completionHandler()
            return
        }
        noteRemoteAction(command.originator == nil ? nil : "Friend resumed playback")

        let hostClock = CMClockGetHostTimeClock()
        let commandHostSeconds = command.hostClockTime.seconds
        var localHostSeconds = CMClockGetTime(hostClock).seconds
        var expected = WatchTogetherTiming.projectedPosition(
            itemTime: command.itemTime.seconds,
            rate: Double(command.rate),
            commandHostTime: commandHostSeconds,
            localHostTime: localHostSeconds,
            duration: adapter.duration()
        )
        if WatchTogetherTiming.needsCorrection(
            currentPosition: adapter.currentTime(),
            expectedPosition: expected
        ) {
            _ = await adapter.seek(expected)
        }

        localHostSeconds = CMClockGetTime(hostClock).seconds
        expected = WatchTogetherTiming.projectedPosition(
            itemTime: command.itemTime.seconds,
            rate: Double(command.rate),
            commandHostTime: commandHostSeconds,
            localHostTime: localHostSeconds,
            duration: adapter.duration()
        )
        if localHostSeconds >= commandHostSeconds,
           WatchTogetherTiming.needsCorrection(
               currentPosition: adapter.currentTime(),
               expectedPosition: expected,
               tolerance: 0.35
           ) {
            _ = await adapter.seek(expected)
        }

        let startDelay = commandHostSeconds - CMClockGetTime(hostClock).seconds
        if startDelay > 0.004 {
            try? await Task.sleep(for: .seconds(startDelay))
        }
        adapter.play()
        completionHandler()
    }

    fileprivate func apply(
        _ command: AVDelegatingPlaybackCoordinatorPauseCommand
    ) {
        guard let adapter = validAdapter(for: command.expectedCurrentItemIdentifier) else {
            return
        }
        adapter.pause()
        noteRemoteAction(command.originator == nil ? nil : "Friend paused playback")
    }

    fileprivate func apply(
        _ command: AVDelegatingPlaybackCoordinatorSeekCommand,
        completionHandler: @escaping @Sendable () -> Void
    ) async {
        guard let adapter = validAdapter(for: command.expectedCurrentItemIdentifier) else {
            completionHandler()
            return
        }
        adapter.pause()
        _ = await adapter.seek(max(command.itemTime.seconds, 0))
        noteRemoteAction(
            command.originator == nil
                ? nil
                : "Friend moved playback to \(Self.formattedTime(command.itemTime.seconds))"
        )
        completionHandler()
    }

    fileprivate func apply(
        _ command: AVDelegatingPlaybackCoordinatorBufferingCommand,
        completionHandler: @escaping @Sendable () -> Void
    ) async {
        guard let adapter = validAdapter(for: command.expectedCurrentItemIdentifier) else {
            completionHandler()
            return
        }
        for _ in 0..<150 {
            if adapter.isReady() { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        completionHandler()
    }

    private func accept(_ newSession: GroupSession<StremioWatchTogetherActivity>) {
        guard session?.id != newSession.id else { return }
        session?.leave()
        sessionSubscriptions.removeAll()
        session = newSession
        sessionContent = newSession.activity.content
        connectedSessionID = nil
        isActive = true
        participantCount = max(newSession.activeParticipants.count, 1)
        isPreparing = false

        newSession.$state
            .sink { [weak self] state in
                self?.sessionStateChanged(state)
            }
            .store(in: &sessionSubscriptions)
        newSession.$activeParticipants
            .sink { [weak self] participants in
                self?.participantCount = max(participants.count, 1)
            }
            .store(in: &sessionSubscriptions)
        newSession.$activity
            .sink { [weak self] activity in
                self?.sessionContent = activity.content
                self?.connectedSessionID = nil
                self?.connectCurrentPlaybackIfPossible()
                self?.refreshMatchState()
            }
            .store(in: &sessionSubscriptions)

        connectCurrentPlaybackIfPossible()
        refreshMatchState()
        newSession.join()
        showAction("Watch party connected")
        NSLog(
            "WATCH_TOGETHER joined session=%@ content=%@",
            newSession.id.uuidString,
            newSession.activity.content.identifier
        )
    }

    private func sessionStateChanged(
        _ state: GroupSession<StremioWatchTogetherActivity>.State
    ) {
        switch state {
        case .waiting:
            isActive = true
        case .joined:
            isActive = true
            isPreparing = false
        case let .invalidated(reason):
            NSLog("WATCH_TOGETHER invalidated error=%@", reason.localizedDescription)
            clearSession()
        @unknown default:
            clearSession()
        }
    }

    private func clearSession() {
        sessionSubscriptions.removeAll()
        session = nil
        sessionContent = nil
        connectedSessionID = nil
        isActive = false
        isPreparing = false
        participantCount = 0
        hasMatchingPlayback = false
    }

    private func connectCurrentPlaybackIfPossible() {
        guard let session,
              let attachedContent,
              attachedContent.identifier == session.activity.content.identifier,
              connectedSessionID != session.id
        else {
            refreshMatchState()
            return
        }

        switch attachmentKind {
        case .none:
            return
        case .native:
            guard let nativePlayer else { return }
            nativePlayer.playbackCoordinator.coordinateWithSession(session)
        case .custom:
            guard customAdapter != nil else { return }
            delegatingCoordinator.transitionToItem(
                withIdentifier: attachedContent.identifier,
                proposingInitialTimingBasedOn: customSnapshotTimebase()
            )
            delegatingCoordinator.coordinateWithSession(session)
        }
        connectedSessionID = session.id
        refreshMatchState()
    }

    private func customSnapshotTimebase() -> CMTimebase? {
        guard let adapter = customAdapter else { return nil }
        var timebase: CMTimebase?
        guard CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        ) == noErr, let timebase else {
            return nil
        }
        CMTimebaseSetTime(
            timebase,
            time: CMTime(seconds: max(adapter.currentTime(), 0), preferredTimescale: 600)
        )
        CMTimebaseSetRate(timebase, rate: adapter.isPlaying() ? 1 : 0)
        return timebase
    }

    private func refreshMatchState() {
        hasMatchingPlayback = isActive
            && attachedContent?.identifier == sessionContent?.identifier
            && attachmentKind != .none
    }

    private func matchingCustomAdapter(
        _ contentIdentifier: String
    ) -> WatchTogetherPlaybackAdapter? {
        guard attachmentKind == .custom,
              attachedContent?.identifier == contentIdentifier
        else { return nil }
        return customAdapter
    }

    private func validAdapter(
        for expectedIdentifier: String
    ) -> WatchTogetherPlaybackAdapter? {
        guard let adapter = customAdapter,
              adapter.content.identifier == expectedIdentifier
        else { return nil }
        return adapter
    }

    private func isCoordinating(_ contentIdentifier: String) -> Bool {
        session != nil
            && sessionContent?.identifier == contentIdentifier
            && attachedContent?.identifier == contentIdentifier
            && connectedSessionID == session?.id
    }

    private func activate(_ activity: StremioWatchTogetherActivity) async {
        do {
            switch await activity.prepareForActivation() {
            case .activationPreferred:
                _ = try await activity.activate()
            case .activationDisabled:
                errorMessage = "SharePlay is unavailable. Start a FaceTime call or invite a friend through Messages, then try again."
            case .cancelled:
                lastActionText = "SharePlay invitation cancelled"
            @unknown default:
                errorMessage = "SharePlay is unavailable right now."
            }
        } catch {
            errorMessage = "Could not start SharePlay: \(error.localizedDescription)"
        }
        isPreparing = false
    }

    private func noteRemoteAction(_ text: String?) {
        guard let text else { return }
        showAction(text)
    }

    private func runInvitationSmokeIfRequested(_ content: WatchTogetherContent) {
        #if targetEnvironment(simulator)
        guard !didRunInvitationSmoke,
              ProcessInfo.processInfo.environment[
                  "SKELETON_WATCH_TOGETHER_INVITATION_SMOKE"
              ] == "1"
        else { return }
        didRunInvitationSmoke = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.share(content)
        }
        #endif
    }

    private func showAction(_ text: String) {
        actionClearTask?.cancel()
        lastActionText = text
        actionClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.lastActionText = nil
        }
    }

    private static func formattedTime(_ seconds: TimeInterval) -> String {
        let value = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }?
            .rootViewController
        var current = root
        while let presented = current?.presentedViewController {
            current = presented
        }
        if let navigation = current as? UINavigationController {
            return navigation.visibleViewController ?? navigation
        }
        if let tabs = current as? UITabBarController {
            return tabs.selectedViewController ?? tabs
        }
        return current
    }
}

struct WatchTogetherMenu: View {
    @ObservedObject private var coordinator = WatchTogetherCoordinator.shared
    let content: WatchTogetherContent

    var body: some View {
        Menu {
            if coordinator.isActive,
               coordinator.sessionContent?.identifier == content.identifier {
                Label(coordinator.statusText, systemImage: "checkmark.circle.fill")
                Button(role: .destructive) {
                    coordinator.leave()
                } label: {
                    Label("Leave Watch Party", systemImage: "rectangle.portrait.and.arrow.right")
                }
                Button(role: .destructive) {
                    coordinator.endForEveryone()
                } label: {
                    Label("End for Everyone", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    coordinator.share(content)
                } label: {
                    Label("Invite Friends with SharePlay", systemImage: "shareplay")
                }
                if let active = coordinator.sessionContent {
                    Text("Current party: \(active.title)")
                }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: coordinator.isPreparing ? "hourglass" : "shareplay")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.52), in: Circle())
                    .foregroundStyle(coordinator.hasMatchingPlayback ? .green : .white)
                if coordinator.hasMatchingPlayback, coordinator.participantCount > 1 {
                    Text("\(coordinator.participantCount)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(4)
                        .background(.green, in: Circle())
                        .offset(x: 4, y: -4)
                }
            }
        }
        .disabled(coordinator.isPreparing)
        .accessibilityLabel(coordinator.statusText)
        .accessibilityIdentifier("watch-together-button")
    }
}

struct WatchTogetherSessionBanner: View {
    @ObservedObject private var coordinator = WatchTogetherCoordinator.shared

    var body: some View {
        if coordinator.isActive, !coordinator.hasMatchingPlayback,
           let content = coordinator.sessionContent {
            HStack(spacing: 10) {
                Image(systemName: "shareplay")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Watch party waiting")
                        .font(.caption.weight(.bold))
                    Text("Open \(content.title) to join playback")
                        .font(.caption2)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Button("Leave") { coordinator.leave() }
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.black.opacity(0.9), in: Capsule())
            .padding(.horizontal)
            .padding(.top, 8)
            .accessibilityIdentifier("watch-together-waiting-banner")
        }
    }
}
