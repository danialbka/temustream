import SwiftUI
import UIKit

#if WATCH_TOGETHER_ENABLED
struct FriendsView: View {
    @EnvironmentObject private var watch: WatchTogetherModel
    @AppStorage(WatchTogetherPreferences.enabledKey)
    private var watchTogetherEnabled = WatchTogetherPreferences.defaultEnabled
    @State private var displayName = ""
    @State private var friendCode = ""
    @State private var roomCode = ""
    @FocusState private var profileNameFocused: Bool

    var body: some View {
        Form {
            if watchTogetherEnabled {
                statusSection
                if watch.profile == nil {
                    profileSetup
                } else {
                    myProfile
                    addFriend
                    pendingRequests
                    friends
                    roomInvitations
                    joinRoom
                    activeRoom
                }
                if let error = watch.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            } else {
                Section {
                    Label("Watch Together is off", systemImage: "person.2.slash")
                    Text("Turn it on under Settings → Social Playback to create a profile, add friends, or join a room.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Friends")
        .task {
            if watchTogetherEnabled {
                await watch.start()
            }
        }
    }

    private var statusSection: some View {
        Section {
            Label(
                watch.statusMessage,
                systemImage: watch.liveKitConnected ? "bolt.horizontal.circle.fill" : "person.2.circle"
            )
            .foregroundStyle(watch.liveKitConnected ? .green : .secondary)
            if watch.activeRoom != nil {
                LabeledContent("Realtime", value: watch.liveKitConnected ? "Connected" : "Durable sync only")
                LabeledContent("Live participants", value: "\(watch.liveParticipantCount)")
            }
        } header: { Text("Watch Together") }
    }

    private var profileSetup: some View {
        Section("Create your profile") {
            TextField("Display name", text: $displayName)
                .textInputAutocapitalization(.words)
                .focused($profileNameFocused)
                .submitLabel(.done)
                .onSubmit(createProfile)
                .accessibilityIdentifier("friends-profile-display-name")
            Button(action: createProfile) {
                profileCreationLabel("Get friend code")
            }
            .disabled(
                displayName.trimmingCharacters(in: .whitespacesAndNewlines).count < 2
                    || watch.isCreatingProfile
            )
            .accessibilityIdentifier("friends-profile-create")
        }
    }

    private func createProfile() {
        profileNameFocused = false
        let name = displayName
        Task { await watch.createProfile(displayName: name) }
    }

    @ViewBuilder
    private func profileCreationLabel(_ title: String) -> some View {
        if watch.isCreatingProfile {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Creating profile…")
            }
        } else {
            Text(title)
        }
    }

    @ViewBuilder
    private var myProfile: some View {
        if let profile = watch.profile {
            Section("Your profile") {
                LabeledContent("Name", value: profile.displayName)
                if let code = profile.friendCode {
                    Button {
                        UIPasteboard.general.string = code
                    } label: {
                        LabeledContent("Friend code", value: code)
                    }
                    .accessibilityHint("Copies your friend code")
                }
            }
        }
    }

    private var addFriend: some View {
        Section("Add a friend") {
            TextField("BUN-XXXXXXXX", text: $friendCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Send friend request") {
                let code = friendCode
                friendCode = ""
                Task { await watch.sendFriendRequest(code: code) }
            }
            .disabled(friendCode.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private var pendingRequests: some View {
        let incoming = watch.friendRequests.filter { $0.direction == "incoming" }
        if !incoming.isEmpty {
            Section("Friend requests") {
                ForEach(incoming) { request in
                    HStack {
                        Text(request.displayName)
                        Spacer()
                        Button("Decline") { Task { await watch.respondToFriendRequest(request, accept: false) } }
                            .tint(.secondary)
                        Button("Accept") { Task { await watch.respondToFriendRequest(request, accept: true) } }
                            .tint(Color.appAccent)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var friends: some View {
        Section("Friends") {
            if watch.friends.isEmpty {
                Text("Share your friend code to add someone.").foregroundStyle(.secondary)
            } else {
                ForEach(watch.friends) { friend in
                    Label(friend.displayName, systemImage: "person.fill")
                }
            }
        }
    }

    @ViewBuilder
    private var roomInvitations: some View {
        if !watch.roomInvites.isEmpty {
            Section("Watch invitations") {
                ForEach(watch.roomInvites) { invite in
                    Button {
                        Task { await watch.joinRoom(code: invite.roomCode) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(invite.contentTitle)
                            Text("From \(invite.fromDisplayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var joinRoom: some View {
        Section("Join with room code") {
            TextField("ROOM-XXXXXXXX", text: $roomCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Join room") {
                let code = roomCode
                roomCode = ""
                Task { await watch.joinRoom(code: code) }
            }
            .disabled(roomCode.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private var activeRoom: some View {
        if let room = watch.activeRoom {
            Section("Current room") {
                LabeledContent("Watching", value: room.contentTitle)
                LabeledContent("Room code", value: room.code)
                ForEach(room.participants) { participant in
                    Label(
                        participant.displayName,
                        systemImage: participant.isHost ? "crown.fill" : "person.fill"
                    )
                }
                if room.hostProfileId == watch.profile?.id, !watch.friends.isEmpty {
                    Menu("Invite a friend") {
                        ForEach(watch.friends) { friend in
                            Button(friend.displayName) { Task { await watch.invite(friend) } }
                        }
                    }
                }
                Button("Leave room", role: .destructive) { Task { await watch.leaveRoom() } }
            }
        }
    }
}

struct WatchRoomPlayerButton: View {
    @ObservedObject var controls: WatchPlayerControlsModel
    let contentKey: String
    let contentType: String
    let contentTitle: String
    @Binding var showsRoom: Bool

    private var hasMatchingRoom: Bool {
        controls.snapshot.activeContentKey == contentKey
    }

    var body: some View {
        Button { showsRoom = true } label: {
            HStack(spacing: 6) {
                Image(systemName: controls.snapshot.realtimeConnected ? "person.2.fill" : "person.2")
                if hasMatchingRoom {
                    Text(controls.snapshot.realtimeConnected ? "Together" : "Room")
                }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 11)
            .frame(height: 38)
            .background(.black.opacity(0.68), in: Capsule())
            .overlay { Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(controls.snapshot.realtimeConnected ? Color.appAccent : .white)
        .accessibilityLabel("Watch Together")
        .accessibilityValue(
            hasMatchingRoom
                ? (controls.snapshot.realtimeConnected ? "Realtime connected" : "Room joined")
                : "No active room"
        )
        .accessibilityIdentifier("watch-together-player-button")
    }
}

extension View {
    /// Presents from the stable player root instead of the auto-hiding control.
    /// Removing a sheet's presenting control from the hierarchy dismisses it,
    /// which previously made Watch Together close as soon as playback chrome hid.
    func watchTogetherRoomSheet(
        watch: WatchTogetherModel,
        isPresented: Binding<Bool>,
        contentKey: String,
        contentType: String,
        contentTitle: String
    ) -> some View {
        sheet(isPresented: isPresented) {
            NavigationStack {
                WatchRoomPlayerSheet(
                    watch: watch,
                    contentKey: contentKey,
                    contentType: contentType,
                    contentTitle: contentTitle
                )
            }
            .presentationDetents([.medium, .large])
        }
    }
}

struct WatchRoomVoiceButton: View {
    let watch: WatchTogetherModel
    @ObservedObject var controls: WatchPlayerControlsModel
    let contentKey: String

    private var hasMatchingRoom: Bool { controls.snapshot.activeContentKey == contentKey }
    private var enabled: Bool {
        hasMatchingRoom
            && controls.snapshot.voiceState.canToggle(
                roomConnected: controls.snapshot.realtimeConnected
            )
    }

    var body: some View {
        Button {
            Task { await watch.toggleMicrophone() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(hasMatchingRoom ? controls.snapshot.voiceState.controlText : "Voice")
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 11)
            .frame(height: 38)
            .background(.black.opacity(0.68), in: Capsule())
            .overlay { Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(controls.snapshot.voiceState == .live ? .green : .white)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .accessibilityLabel(controls.snapshot.voiceState.statusText)
        .accessibilityHint(hasMatchingRoom ? "Toggles room voice" : "Join a Watch Together room to use voice")
        .accessibilityIdentifier("watch-together-microphone-toggle")
    }

    private var systemImage: String {
        switch controls.snapshot.voiceState {
        case .off: "mic.slash"
        case .enabling: "ellipsis"
        case .live: "mic.fill"
        case .denied: "mic.badge.xmark"
        case .unavailable: "mic.slash.fill"
        }
    }
}

private struct WatchRoomPlayerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var watch: WatchTogetherModel
    let contentKey: String
    let contentType: String
    let contentTitle: String
    @State private var displayName = ""
    @State private var roomCode = ""
    @FocusState private var profileNameFocused: Bool

    var body: some View {
        Form {
            Section {
                Text(contentTitle).font(.headline)
                Text("Everyone needs access to the same title and a playable stream. Stream URLs and account tokens are never shared.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if watch.profile == nil {
                Section("Your profile") {
                    TextField("Display name", text: $displayName)
                        .textInputAutocapitalization(.words)
                        .focused($profileNameFocused)
                        .submitLabel(.done)
                        .onSubmit(createProfile)
                        .accessibilityIdentifier("watch-profile-display-name")
                    Button(action: createProfile) {
                        if watch.isCreatingProfile {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Creating profile…")
                            }
                        } else {
                            Text("Create profile")
                        }
                    }
                    .disabled(
                        displayName.trimmingCharacters(in: .whitespacesAndNewlines).count < 2
                            || watch.isCreatingProfile
                    )
                    .accessibilityIdentifier("watch-profile-create")
                }
            } else if let room = watch.activeRoom, room.contentKey == contentKey {
                Section("Room \(room.code)") {
                    Label(
                        watch.liveKitConnected ? "Realtime sync connected" : "Waiting for LiveKit realtime",
                        systemImage: watch.liveKitConnected ? "bolt.fill" : "bolt.slash"
                    )
                    LabeledContent("Voice", value: watch.voiceState.statusText)
                    ForEach(room.participants) { participant in
                        Label(participant.displayName, systemImage: participant.isHost ? "crown.fill" : "person.fill")
                    }
                    if room.hostProfileId == watch.profile?.id, !watch.friends.isEmpty {
                        Menu("Invite friend") {
                            ForEach(watch.friends) { friend in
                                Button(friend.displayName) { Task { await watch.invite(friend) } }
                            }
                        }
                    }
                    Button("Leave room", role: .destructive) {
                        Task { await watch.leaveRoom(); dismiss() }
                    }
                }
            } else {
                Section {
                    Button("Create a room for this title") {
                        Task { await watch.createRoom(contentKey: contentKey, contentType: contentType, contentTitle: contentTitle) }
                    }
                    TextField("ROOM-XXXXXXXX", text: $roomCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button("Join room") { Task { await watch.joinRoom(code: roomCode) } }
                        .disabled(roomCode.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    Text("Joining a room for another title will keep that room active, but sync applies only when both players are on its content ID.")
                }
            }

            if let error = watch.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Watch Together")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .accessibilityIdentifier("watch-together-sheet")
    }

    private func createProfile() {
        profileNameFocused = false
        let name = displayName
        Task { await watch.createProfile(displayName: name) }
    }
}
#else
struct FriendsView: View {
    var body: some View { EmptyView() }
}

struct WatchRoomPlayerButton: View {
    @ObservedObject var controls: WatchPlayerControlsModel
    let contentKey: String
    let contentType: String
    let contentTitle: String
    @Binding var showsRoom: Bool

    var body: some View { EmptyView() }
}

struct WatchRoomVoiceButton: View {
    let watch: WatchTogetherModel
    @ObservedObject var controls: WatchPlayerControlsModel
    let contentKey: String

    var body: some View { EmptyView() }
}

extension View {
    func watchTogetherRoomSheet(
        watch: WatchTogetherModel,
        isPresented: Binding<Bool>,
        contentKey: String,
        contentType: String,
        contentTitle: String
    ) -> some View {
        _ = watch
        _ = isPresented
        _ = contentKey
        _ = contentType
        _ = contentTitle
        return self
    }
}
#endif
