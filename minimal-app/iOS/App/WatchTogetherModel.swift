import Combine
@preconcurrency import ConvexMobile
import AVFoundation
import Foundation
import LiveKit
import Security

struct WatchProfile: Codable, Identifiable, Equatable {
    let id: String
    let displayName: String
    let friendCode: String?
}

struct WatchFriendRequest: Codable, Identifiable, Equatable {
    let id: String
    let profileId: String
    let displayName: String
    let direction: String
}

struct WatchFriendsPayload: Codable, Equatable {
    let friends: [WatchProfile]
    let requests: [WatchFriendRequest]
}

struct WatchRoomInvite: Codable, Identifiable, Equatable {
    let id: String
    let roomId: String
    let roomCode: String
    let contentTitle: String
    let fromDisplayName: String
}

struct WatchRoomPlayback: Codable, Equatable {
    let position: Double
    let isPlaying: Bool
    let rate: Double
    let versionCounter: Int64
    let versionActor: String
    let updatedAt: Int64
}

struct WatchRoomParticipant: Codable, Identifiable, Equatable {
    let id: String
    let displayName: String
    let isHost: Bool
}

struct WatchRoom: Codable, Identifiable, Equatable {
    let id: String
    let code: String
    let hostProfileId: String
    let contentKey: String
    let contentType: String
    let contentTitle: String
    let playback: WatchRoomPlayback
    let participants: [WatchRoomParticipant]
}

struct WatchTogetherConfiguration {
    let convexURL: String
    let liveKitURL: String?

    static var current: Self? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "WatchTogetherConvexURL") as? String else {
            return nil
        }
        let convexURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard convexURL.hasPrefix("https://") else { return nil }
        let rawLiveKit = Bundle.main.object(forInfoDictionaryKey: "WatchTogetherLiveKitURL") as? String
        let liveKitURL = rawLiveKit?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            convexURL: convexURL,
            liveKitURL: liveKitURL?.hasPrefix("wss://") == true ? liveKitURL : nil
        )
    }
}

/// The small, stable slice of Watch Together state rendered by player chrome.
///
/// Room playback heartbeats replace `WatchTogetherModel.activeRoom` frequently.
/// Keeping the controls on their own observable projection both makes join,
/// leave, and microphone changes redraw immediately and avoids rebuilding the
/// controls for playback-only room updates.
struct WatchPlayerControlsSnapshot: Equatable {
    let activeRoomID: String?
    let activeContentKey: String?
    let realtimeConnected: Bool
    let voiceState: WatchVoiceControlState

    static let idle = Self(
        activeRoomID: nil,
        activeContentKey: nil,
        realtimeConnected: false,
        voiceState: .off
    )
}

@MainActor
final class WatchPlayerControlsModel: ObservableObject {
    @Published private(set) var snapshot: WatchPlayerControlsSnapshot = .idle

    fileprivate func update(_ next: WatchPlayerControlsSnapshot) {
        guard next != snapshot else { return }
        snapshot = next
        NSLog(
            "WATCH_PLAYER_CONTROLS room=%@ realtime=%@ voice=%@",
            next.activeRoomID ?? "none",
            next.realtimeConnected ? "yes" : "no",
            next.voiceState.rawValue
        )
    }
}

@MainActor
final class WatchPlaybackControlChannel: ObservableObject {
    typealias SampleProvider = @MainActor () -> WatchLocalPlaybackSample?
    typealias AdjustmentApplier = @MainActor (WatchPlaybackAdjustment, Double) async -> Void
    typealias EventHandler = @MainActor (WatchPlaybackEventKind, WatchLocalPlaybackSample) async -> Void

    private struct Adapter {
        let id: UUID
        let sample: SampleProvider
        let apply: AdjustmentApplier
    }

    private var adapter: Adapter?
    private var monitorTask: Task<Void, Never>?
    private var handler: EventHandler?
    private var lastSample: WatchLocalPlaybackSample?
    private var lastSampleAt = ProcessInfo.processInfo.systemUptime
    private var lastHeartbeatAt = ProcessInfo.processInfo.systemUptime
    private var suppressionGeneration = 0
    private var suppressUntil = 0.0

    deinit { monitorTask?.cancel() }

    @discardableResult
    func register(sample: @escaping SampleProvider, apply: @escaping AdjustmentApplier) -> UUID {
        let id = UUID()
        adapter = Adapter(id: id, sample: sample, apply: apply)
        lastSample = sample()
        lastSampleAt = ProcessInfo.processInfo.systemUptime
        ensureMonitor()
        return id
    }

    func unregister(_ id: UUID) {
        guard adapter?.id == id else { return }
        adapter = nil
        lastSample = nil
    }

    func setEventHandler(_ handler: EventHandler?) {
        self.handler = handler
        lastSample = adapter?.sample()
        lastSampleAt = ProcessInfo.processInfo.systemUptime
        lastHeartbeatAt = lastSampleAt
        ensureMonitor()
    }

    func sample() -> WatchLocalPlaybackSample? { adapter?.sample() }

    func applyRemote(_ adjustment: WatchPlaybackAdjustment, baselineRate: Double) async {
        guard adjustment.hasChanges, let adapter else { return }
        suppressionGeneration += 1
        let generation = suppressionGeneration
        suppressUntil = ProcessInfo.processInfo.systemUptime + max(adjustment.temporaryRateDuration, 1.2)
        await adapter.apply(adjustment, baselineRate)
        lastSample = adapter.sample()
        lastSampleAt = ProcessInfo.processInfo.systemUptime

        guard adjustment.temporaryRate != nil, adjustment.temporaryRateDuration > 0 else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(adjustment.temporaryRateDuration))
            guard let self, generation == self.suppressionGeneration, let current = self.adapter else { return }
            await current.apply(WatchPlaybackAdjustment(playbackRate: baselineRate), baselineRate)
            self.lastSample = current.sample()
        }
    }

    private func ensureMonitor() {
        guard monitorTask == nil else { return }
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.observeSample()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func observeSample() async {
        guard let current = adapter?.sample() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        defer {
            lastSample = current
            lastSampleAt = now
        }
        guard let previous = lastSample, let handler, now >= suppressUntil else { return }

        if previous.isPlaying != current.isPlaying {
            await handler(current.isPlaying ? .play : .pause, current)
            lastHeartbeatAt = now
            return
        }

        let expected = previous.position + (previous.isPlaying ? (now - lastSampleAt) * previous.rate : 0)
        if abs(current.position - expected) >= 1.15 {
            await handler(.seek, current)
            lastHeartbeatAt = now
            return
        }

        if current.isPlaying, now - lastHeartbeatAt >= 4 {
            await handler(.heartbeat, current)
            lastHeartbeatAt = now
        }
    }
}

@MainActor
final class WatchTogetherModel: ObservableObject {
    let playerControls = WatchPlayerControlsModel()

    @Published private(set) var isFeatureEnabled = WatchTogetherPreferences.isEnabled()
    @Published private(set) var profile: WatchProfile?
    @Published private(set) var friends: [WatchProfile] = []
    @Published private(set) var friendRequests: [WatchFriendRequest] = []
    @Published private(set) var roomInvites: [WatchRoomInvite] = []
    @Published private(set) var activeRoom: WatchRoom? {
        didSet { synchronizePlayerControls() }
    }
    @Published private(set) var convexConnected = false
    @Published private(set) var liveKitConnected = false {
        didSet { synchronizePlayerControls() }
    }
    @Published private(set) var liveParticipantCount = 0
    @Published private(set) var voiceState = WatchVoiceControlState.off {
        didSet { synchronizePlayerControls() }
    }
    @Published private(set) var isCreatingProfile = false
    @Published private(set) var statusMessage = "Watch Together is off"
    @Published var errorMessage: String?

    private let configuration: WatchTogetherConfiguration?
    private let client: ConvexClient?
    private let credentialStore = WatchTogetherCredentialStore()
    private lazy var deviceSecret: String = {
        #if targetEnvironment(simulator)
        if let value = ProcessInfo.processInfo.environment["SKELETON_WATCH_DEVICE_SECRET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), value.count >= 16 {
            return value
        }
        #endif
        return credentialStore.loadOrCreate()
    }()
    private var subscriptions = Set<AnyCancellable>()
    private var roomSubscriptions = Set<AnyCancellable>()
    private var room: Room?
    private var liveKitDelegate: WatchLiveKitDelegate?
    private var microphonePublication: LocalTrackPublication?
    private weak var playerChannel: WatchPlaybackControlChannel?
    private var playerContentKey: String?
    private var reconciler: WatchPlaybackReconciler?
    private var started = false
    #if targetEnvironment(simulator)
    private var didRunPlayerControlsUIAudit = false
    #endif

    init(configuration: WatchTogetherConfiguration? = .current) {
        self.configuration = configuration
        client = configuration.map { ConvexClient(deploymentUrl: $0.convexURL) }
    }

    var isConfigured: Bool { client != nil }

    private func synchronizePlayerControls() {
        playerControls.update(
            WatchPlayerControlsSnapshot(
                activeRoomID: activeRoom?.id,
                activeContentKey: activeRoom?.contentKey,
                realtimeConnected: liveKitConnected,
                voiceState: voiceState
            )
        )
    }

    /// Drives the production player controls through their room and voice
    /// states without touching Convex, LiveKit, or the playback timeline.
    /// This is simulator-only and must be explicitly enabled at launch.
    func runPlayerControlsUIAuditIfRequested(contentKey: String) async {
        #if targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        guard isFeatureEnabled,
              environment["SKELETON_WATCH_CONTROLS_AUDIT"] == "1",
              !didRunPlayerControlsUIAudit
        else { return }
        didRunPlayerControlsUIAudit = true

        let interval = max(
            Double(environment["SKELETON_WATCH_CONTROLS_AUDIT_INTERVAL"] ?? "4") ?? 4,
            1
        )
        let auditRoom = WatchRoom(
            id: "simulator-controls-audit",
            code: "ROOM-AUDIT",
            hostProfileId: "simulator-profile",
            contentKey: contentKey,
            contentType: "movie",
            contentTitle: "Player controls observation audit",
            playback: WatchRoomPlayback(
                position: 0,
                isPlaying: true,
                rate: 1,
                versionCounter: 1,
                versionActor: "simulator-profile",
                updatedAt: Self.nowMilliseconds
            ),
            participants: [
                WatchRoomParticipant(
                    id: "simulator-profile",
                    displayName: "Simulator",
                    isHost: true
                )
            ]
        )

        NSLog("WATCH_PLAYER_UI_AUDIT stage=idle")
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled else { return }
        activeRoom = auditRoom
        NSLog("WATCH_PLAYER_UI_AUDIT stage=joined")

        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled else { return }
        liveKitConnected = true
        NSLog("WATCH_PLAYER_UI_AUDIT stage=connected")

        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled else { return }
        voiceState = .live
        NSLog("WATCH_PLAYER_UI_AUDIT stage=mic_live")

        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled else { return }
        voiceState = .off
        NSLog("WATCH_PLAYER_UI_AUDIT stage=mic_muted")

        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled else { return }
        liveKitConnected = false
        activeRoom = nil
        NSLog("WATCH_PLAYER_UI_AUDIT stage=left")
        #endif
    }

    func setFeatureEnabled(_ enabled: Bool) async {
        guard enabled != isFeatureEnabled || (enabled && !started) else { return }
        isFeatureEnabled = enabled

        if enabled {
            statusMessage = "Connecting Watch Together…"
            errorMessage = nil
            await start()
            return
        }

        if activeRoom != nil {
            await leaveRoom()
        } else {
            await stopMicrophone(markUnavailable: false)
            await room?.disconnect()
            room = nil
            liveKitDelegate = nil
            liveKitConnected = false
            liveParticipantCount = 0
            roomSubscriptions.removeAll()
        }

        // A quick off-on toggle can re-enable the feature while the room
        // disconnect above is awaiting LiveKit or Convex. Do not let the older
        // disable task tear down the newer enabled session.
        guard !isFeatureEnabled else { return }
        playerChannel?.setEventHandler(nil)
        playerChannel = nil
        playerContentKey = nil
        subscriptions.removeAll()
        roomSubscriptions.removeAll()
        roomInvites = []
        convexConnected = false
        started = false
        statusMessage = "Watch Together is off"
        errorMessage = nil
    }

    func start() async {
        guard isFeatureEnabled else {
            statusMessage = "Watch Together is off"
            return
        }
        guard !started else { return }
        started = true
        guard let client else {
            statusMessage = "Run scripts/configure-watch-together.sh, then rebuild"
            return
        }
        client.watchWebSocketState()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                case .connected: self?.convexConnected = true
                case .connecting: self?.convexConnected = false
                }
            }
            .store(in: &subscriptions)
        do {
            let restored: WatchProfile = try await queryOnce(
                "profiles:me", args: ["deviceSecret": deviceSecret], as: WatchProfile.self
            )
            guard isFeatureEnabled else { return }
            profile = restored
            statusMessage = "Friends connected"
            subscribeToFriends()
        } catch {
            guard isFeatureEnabled else { return }
            statusMessage = "Choose a display name to get your friend code"
        }
    }

    func createProfile(displayName: String) async {
        guard isFeatureEnabled else { return }
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName.count >= 2 else {
            errorMessage = "Enter a display name with at least 2 characters."
            return
        }
        guard let client else {
            statusMessage = "Watch Together is not configured"
            errorMessage = "Watch Together isn’t configured in this build."
            return
        }
        guard !isCreatingProfile else { return }

        isCreatingProfile = true
        statusMessage = "Creating your profile…"
        errorMessage = nil
        defer { isCreatingProfile = false }
        do {
            let value: WatchProfile = try await client.mutation(
                "profiles:bootstrap",
                with: ["deviceSecret": deviceSecret, "displayName": normalizedName]
            )
            profile = value
            statusMessage = "Friends connected"
            errorMessage = nil
            subscribeToFriends()
        } catch {
            statusMessage = "Couldn’t create your profile"
            errorMessage = "Couldn’t create profile: \(error.localizedDescription)"
        }
    }

    func sendFriendRequest(code: String) async {
        guard isFeatureEnabled else { return }
        guard let client else { return }
        do {
            let _: IdentifierResult = try await client.mutation(
                "friends:sendRequest", with: ["deviceSecret": deviceSecret, "friendCode": code]
            )
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func respondToFriendRequest(_ request: WatchFriendRequest, accept: Bool) async {
        guard isFeatureEnabled else { return }
        guard let client else { return }
        do {
            let _: AcceptedResult = try await client.mutation(
                "friends:respond",
                with: ["deviceSecret": deviceSecret, "requestId": request.id, "accept": accept]
            )
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func createRoom(contentKey: String, contentType: String, contentTitle: String) async {
        guard isFeatureEnabled else { return }
        guard let client else { return }
        if activeRoom != nil { await leaveRoom() }
        do {
            let value: WatchRoom = try await client.mutation(
                "rooms:create",
                with: [
                    "deviceSecret": deviceSecret,
                    "contentKey": contentKey,
                    "contentType": contentType,
                    "contentTitle": contentTitle,
                ]
            )
            await activateRoom(value)
        } catch { errorMessage = error.localizedDescription }
    }

    func invite(_ friend: WatchProfile) async {
        guard isFeatureEnabled else { return }
        guard let client, let activeRoom else { return }
        do {
            let _: IdentifierResult = try await client.mutation(
                "rooms:inviteFriend",
                with: ["deviceSecret": deviceSecret, "roomId": activeRoom.id, "friendProfileId": friend.id]
            )
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func joinRoom(code: String) async {
        guard isFeatureEnabled else { return }
        guard let client else { return }
        if activeRoom != nil { await leaveRoom() }
        do {
            let value: WatchRoom = try await client.mutation(
                "rooms:join", with: ["deviceSecret": deviceSecret, "roomCode": code]
            )
            await activateRoom(value)
        } catch { errorMessage = error.localizedDescription }
    }

    func leaveRoom() async {
        guard let client, let activeRoom else { return }
        let roomID = activeRoom.id
        await stopMicrophone(markUnavailable: false)
        await room?.disconnect()
        room = nil
        liveKitDelegate = nil
        liveKitConnected = false
        liveParticipantCount = 0
        roomSubscriptions.removeAll()
        self.activeRoom = nil
        reconciler = profile.map { WatchPlaybackReconciler(actorID: $0.id) }
        voiceState = .off
        do {
            let _: ClosedResult = try await client.mutation(
                "rooms:leave", with: ["deviceSecret": deviceSecret, "roomId": roomID]
            )
        } catch { errorMessage = error.localizedDescription }
    }

    func toggleMicrophone() async {
        guard isFeatureEnabled else {
            voiceState = .off
            return
        }
        guard liveKitConnected, room != nil else {
            voiceState = .unavailable
            return
        }
        guard voiceState != .enabling else { return }
        if voiceState == .live {
            await stopMicrophone(markUnavailable: false)
            return
        }

        voiceState = .enabling
        guard await requestMicrophonePermission() else {
            voiceState = .denied
            errorMessage = "Microphone access is disabled. Enable it for TemuStremio in iOS Settings."
            return
        }
        guard let room, room.connectionState == .connected else {
            voiceState = .unavailable
            return
        }
        do {
            microphonePublication = try await room.localParticipant.setMicrophone(enabled: true)
            voiceState = .live
            errorMessage = nil
            PlaybackAudioSession.voiceCaptureDidChange(isEnabled: true)
        } catch {
            voiceState = .unavailable
            errorMessage = "Couldn’t start room voice: \(error.localizedDescription)"
        }
    }

    func attachPlayer(_ channel: WatchPlaybackControlChannel, contentKey: String) {
        guard isFeatureEnabled else { return }
        playerChannel = channel
        playerContentKey = contentKey
        channel.setEventHandler { [weak self] kind, sample in
            await self?.publishLocal(kind: kind, sample: sample)
        }
        applyDurableSnapshotIfNeeded()
    }

    func detachPlayer(_ channel: WatchPlaybackControlChannel) {
        guard playerChannel === channel else { return }
        channel.setEventHandler(nil)
        playerChannel = nil
        playerContentKey = nil
    }

    private func subscribeToFriends() {
        guard isFeatureEnabled else { return }
        guard let client else { return }
        client.subscribe(
            to: "friends:list", with: ["deviceSecret": deviceSecret], yielding: WatchFriendsPayload.self
        )
        .receive(on: DispatchQueue.main)
        .sink(receiveCompletion: { [weak self] completion in
            if case let .failure(error) = completion { self?.errorMessage = error.localizedDescription }
        }, receiveValue: { [weak self] value in
            self?.friends = value.friends
            self?.friendRequests = value.requests
        })
        .store(in: &subscriptions)

        client.subscribe(
            to: "rooms:invitations", with: ["deviceSecret": deviceSecret], yielding: [WatchRoomInvite].self
        )
        .receive(on: DispatchQueue.main)
        .replaceError(with: [])
        .assign(to: &$roomInvites)
    }

    private func queryOnce<T: Decodable>(
        _ name: String,
        args: [String: ConvexEncodable?],
        as type: T.Type
    ) async throws -> T {
        guard let client else { throw WatchTogetherClientError.notConfigured }
        for try await value in client.subscribe(to: name, with: args, yielding: type).values {
            return value
        }
        throw WatchTogetherClientError.subscriptionEnded
    }

    private func activateRoom(_ value: WatchRoom) async {
        guard isFeatureEnabled else { return }
        errorMessage = nil
        activeRoom = value
        reconciler = WatchPlaybackReconciler(
            actorID: profile?.id ?? "unknown",
            initialVersion: WatchPlaybackVersion(
                counter: value.playback.versionCounter,
                actorID: value.playback.versionActor
            )
        )
        subscribeToActiveRoom(value.id)
        applyDurableSnapshotIfNeeded()
        await connectLiveKit(roomID: value.id)
    }

    private func subscribeToActiveRoom(_ roomID: String) {
        guard let client else { return }
        roomSubscriptions.removeAll()
        client.subscribe(
            to: "rooms:get",
            with: ["deviceSecret": deviceSecret, "roomId": roomID],
            yielding: Optional<WatchRoom>.self
        )
        .receive(on: DispatchQueue.main)
        .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] value in
            guard let self else { return }
            guard let value else {
                Task { @MainActor in await self.clearClosedRoom() }
                return
            }
            self.activeRoom = value
            self.applyDurableSnapshotIfNeeded()
        })
        .store(in: &roomSubscriptions)
    }

    private func connectLiveKit(roomID: String) async {
        guard isFeatureEnabled else { return }
        guard let client else { return }
        do {
            let token: LiveKitToken = try await client.action(
                "livekit:joinToken", with: ["deviceSecret": deviceSecret, "roomId": roomID]
            )
            let delegate = WatchLiveKitDelegate(owner: self)
            let room = Room(delegate: delegate)
            self.liveKitDelegate = delegate
            self.room = room
            try await room.connect(url: token.serverUrl, token: token.participantToken)
            liveKitConnected = true
            if voiceState == .unavailable {
                voiceState = .off
            }
            refreshLiveParticipants(room)
            statusMessage = "Playback sync connected"
        } catch {
            liveKitConnected = false
            statusMessage = "Room saved; LiveKit realtime is unavailable"
            errorMessage = error.localizedDescription
        }
    }

    private func publishLocal(kind: WatchPlaybackEventKind, sample: WatchLocalPlaybackSample) async {
        guard isFeatureEnabled,
              let activeRoom,
              activeRoom.contentKey == playerContentKey,
              var currentReconciler = reconciler
        else { return }
        let now = Self.nowMilliseconds
        let event = currentReconciler.makeLocalEvent(
            contentKey: activeRoom.contentKey,
            kind: kind,
            sample: sample,
            nowMilliseconds: now
        )
        reconciler = currentReconciler
        if let room, room.connectionState == .connected,
           let data = try? JSONEncoder().encode(event) {
            try? await room.localParticipant.publish(
                data: data,
                options: DataPublishOptions(topic: "temustream.playback.v1", reliable: true)
            )
        }
        guard let client else { return }
        do {
            let _: PlaybackMutationResult = try await client.mutation(
                "rooms:updatePlayback",
                with: [
                    "deviceSecret": deviceSecret,
                    "roomId": activeRoom.id,
                    "position": event.position,
                    "isPlaying": event.isPlaying,
                    "rate": event.rate,
                    // Convex v.number() is encoded as a float64. Passing Swift
                    // Int64 values makes Convex encode them as v.int64(), which
                    // the playback mutation correctly rejects.
                    "versionCounter": Double(event.version.counter),
                    "versionActor": event.version.actorID,
                    "sentAt": Double(event.sentAtMilliseconds),
                ]
            )
        } catch { NSLog("WATCH_TOGETHER durable_update_failed=%@", error.localizedDescription) }
    }

    fileprivate func receiveLiveKitData(_ data: Data, topic: String) {
        guard isFeatureEnabled,
              topic == "temustream.playback.v1",
              let wireEvent = try? JSONDecoder().decode(WatchPlaybackEvent.self, from: data)
        else { return }
        // Participant wall clocks are not guaranteed to agree. Reliable LiveKit
        // packets are applied from receive-now; Convex snapshots use server time.
        let event = WatchPlaybackEvent(
            eventID: wireEvent.eventID,
            contentKey: wireEvent.contentKey,
            kind: wireEvent.kind,
            position: wireEvent.position,
            isPlaying: wireEvent.isPlaying,
            rate: wireEvent.rate,
            version: wireEvent.version,
            sentAtMilliseconds: Self.nowMilliseconds
        )
        applyRemote(event)
    }

    private func clearClosedRoom() async {
        await stopMicrophone(markUnavailable: false)
        await room?.disconnect()
        room = nil
        liveKitDelegate = nil
        liveKitConnected = false
        liveParticipantCount = 0
        activeRoom = nil
        roomSubscriptions.removeAll()
        voiceState = .off
        statusMessage = "Room closed"
    }

    private func applyDurableSnapshotIfNeeded() {
        guard let activeRoom else { return }
        let event = WatchPlaybackEvent(
            contentKey: activeRoom.contentKey,
            kind: .heartbeat,
            position: activeRoom.playback.position,
            isPlaying: activeRoom.playback.isPlaying,
            rate: activeRoom.playback.rate,
            version: WatchPlaybackVersion(
                counter: activeRoom.playback.versionCounter,
                actorID: activeRoom.playback.versionActor
            ),
            sentAtMilliseconds: activeRoom.playback.updatedAt
        )
        applyRemote(event)
    }

    private func applyRemote(_ event: WatchPlaybackEvent) {
        guard event.contentKey == playerContentKey,
              let channel = playerChannel,
              let sample = channel.sample(),
              var currentReconciler = reconciler,
              let adjustment = currentReconciler.reconcile(
                remote: event,
                local: sample,
                nowMilliseconds: Self.nowMilliseconds
              )
        else { return }
        reconciler = currentReconciler
        Task { @MainActor in
            await channel.applyRemote(adjustment, baselineRate: event.rate)
        }
    }

    fileprivate func liveKitConnectionChanged(_ room: Room, connected: Bool) {
        guard isFeatureEnabled else { return }
        liveKitConnected = connected
        refreshLiveParticipants(room)
        if connected {
            if voiceState == .unavailable { voiceState = .off }
            applyDurableSnapshotIfNeeded()
        } else {
            Task { @MainActor in await stopMicrophone(markUnavailable: activeRoom != nil) }
        }
    }

    fileprivate func refreshLiveParticipants(_ room: Room) {
        liveParticipantCount = room.connectionState == .connected ? room.remoteParticipants.count + 1 : 0
    }

    private static var nowMilliseconds: Int64 { Int64((Date().timeIntervalSince1970 * 1_000).rounded()) }

    private func stopMicrophone(markUnavailable: Bool) async {
        if let room, let microphonePublication {
            try? await room.localParticipant.unpublish(publication: microphonePublication)
        } else if let room {
            _ = try? await room.localParticipant.setMicrophone(enabled: false)
        }
        microphonePublication = nil
        voiceState = markUnavailable ? .unavailable : .off
        PlaybackAudioSession.voiceCaptureDidChange(isEnabled: false)
    }

    private func requestMicrophonePermission() async -> Bool {
        await MicrophonePermissionRequester.request()
    }
}

private struct IdentifierResult: Decodable { let requestId: String?; let inviteId: String? }
private struct AcceptedResult: Decodable { let accepted: Bool }
private struct ClosedResult: Decodable { let closed: Bool }
private struct PlaybackMutationResult: Decodable { let accepted: Bool; let playback: WatchRoomPlayback }
private struct LiveKitToken: Decodable { let serverUrl: String; let participantToken: String; let expiresAt: Int64 }

private enum WatchTogetherClientError: LocalizedError {
    case notConfigured
    case subscriptionEnded

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Watch Together is not configured."
        case .subscriptionEnded: "The Convex subscription ended before returning data."
        }
    }
}

private final class WatchLiveKitDelegate: NSObject, RoomDelegate, @unchecked Sendable {
    private weak var owner: WatchTogetherModel?

    init(owner: WatchTogetherModel) { self.owner = owner }

    func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        Task { @MainActor [weak self] in self?.owner?.liveKitConnectionChanged(room, connected: connectionState == .connected) }
    }

    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor [weak self] in self?.owner?.refreshLiveParticipants(room) }
    }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor [weak self] in self?.owner?.refreshLiveParticipants(room) }
    }

    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        Task { @MainActor [weak self] in self?.owner?.receiveLiveKitData(data, topic: topic) }
    }
}

private struct WatchTogetherCredentialStore {
    private let service = "local.stremio.skeleton.watch-together"
    private let account = "device-secret-v1"

    func loadOrCreate() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }
        var random = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess)
        let value = Data(random).base64EncodedString()
        var insert = query
        insert.removeValue(forKey: kSecReturnData as String)
        insert.removeValue(forKey: kSecMatchLimit as String)
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(query as CFDictionary)
        _ = SecItemAdd(insert as CFDictionary, nil)
        return value
    }
}
