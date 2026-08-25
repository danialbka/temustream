import SwiftUI

struct ViewingProfilePickerView: View {
    let snapshot: ViewingProfileSnapshot
    let onSelect: @MainActor @Sendable (UUID) async throws -> Void
    let onCreate: @MainActor @Sendable (String, ViewingProfileAvatar) async throws -> Void
    let onUpdate: @MainActor @Sendable (UUID, String, ViewingProfileAvatar) async throws -> Void
    let onArchive: @MainActor @Sendable (UUID) async throws -> Void
    let onRestore: @MainActor @Sendable (UUID) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editor: ProfileEditorRoute?
    @State private var busyProfileID: UUID?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Who's watching?")
                        .font(.largeTitle.bold())
                        .frame(maxWidth: .infinity, alignment: .center)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 128), spacing: 20)],
                        spacing: 24
                    ) {
                        ForEach(snapshot.profiles) { profile in
                            profileButton(profile)
                        }
                        createButton
                    }

                    if !snapshot.archivedProfiles.isEmpty {
                        archivedSection
                    }
                }
                .padding(24)
            }
            .background(Color(uiColor: .systemBackground))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editor) { route in
                ViewingProfileEditorView(
                    title: route.profile == nil ? "Create Profile" : "Edit Profile",
                    initialName: route.profile?.name ?? "",
                    initialAvatar: route.profile?.avatar ?? .bunny,
                    canArchive: route.profile.map { _ in
                        snapshot.profiles.count > 1
                    } ?? false,
                    onSave: { name, avatar in
                        if let profile = route.profile {
                            try await onUpdate(profile.id, name, avatar)
                        } else {
                            try await onCreate(name, avatar)
                        }
                    },
                    onArchive: route.profile.map { profile in
                        { @MainActor @Sendable in
                            try await onArchive(profile.id)
                        }
                    }
                )
            }
            .alert("Profiles", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Something went wrong.")
            }
        }
        .accessibilityIdentifier("viewing-profile-picker")
    }

    private func profileButton(_ profile: ViewingProfile) -> some View {
        VStack(spacing: 10) {
            Button {
                busyProfileID = profile.id
                Task {
                    defer { busyProfileID = nil }
                    do {
                        try await onSelect(profile.id)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    ProfileAvatarView(profile: profile, size: 112)
                    if snapshot.activeProfileID == profile.id {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.appAccent)
                            .background(Circle().fill(.black.opacity(0.5)))
                    }
                    if busyProfileID == profile.id {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black.opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(busyProfileID != nil)
            .accessibilityLabel("Watch as \(profile.name)")

            HStack(spacing: 5) {
                Text(profile.name)
                    .font(.headline)
                    .lineLimit(1)
                Button {
                    editor = ProfileEditorRoute(profile: profile)
                } label: {
                    Image(systemName: "pencil.circle")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(profile.name)")
            }
        }
    }

    private var createButton: some View {
        Button {
            editor = ProfileEditorRoute(profile: nil)
        } label: {
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .frame(width: 112, height: 112)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundStyle(Color.appAccent)
                    }
                Text("Add Profile")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("add-viewing-profile")
    }

    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recently removed")
                .font(.headline)
                .foregroundStyle(.secondary)
            ForEach(snapshot.archivedProfiles) { profile in
                HStack(spacing: 12) {
                    ProfileAvatarView(profile: profile, size: 44)
                    Text(profile.name)
                    Spacer()
                    Button("Restore") {
                        Task {
                            do { try await onRestore(profile.id) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }
}

struct ViewingProfileMenuButton: View {
    let profile: ViewingProfile
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ProfileAvatarView(profile: profile, size: 34)
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(.white.opacity(0.75), lineWidth: 1)
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Viewing profile, \(profile.name)")
        .accessibilityIdentifier("viewing-profile-menu")
    }
}

struct MediaReactionControl: View {
    let reaction: MediaReaction?
    let compact: Bool
    let onSelect: (MediaReaction?) -> Void

    init(
        reaction: MediaReaction?,
        compact: Bool = false,
        onSelect: @escaping (MediaReaction?) -> Void
    ) {
        self.reaction = reaction
        self.compact = compact
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: compact ? -7 : 8) {
            reactionButton(.dislike, icon: "hand.thumbsdown", label: "Not for me")
            reactionButton(.like, icon: "hand.thumbsup", label: "I like this")
            reactionButton(.love, icon: "heart", label: "Love this")
        }
        .padding(compact ? 0 : 5)
        .background {
            Capsule()
                .fill(Color(uiColor: .tertiarySystemBackground))
                .frame(height: compact ? 36 : nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("media-reaction-control")
    }

    private func reactionButton(
        _ value: MediaReaction,
        icon: String,
        label: String
    ) -> some View {
        let selected = reaction == value
        return Button {
            onSelect(selected ? nil : value)
        } label: {
            Image(systemName: selected ? "\(icon).fill" : icon)
                .font(.system(size: compact ? 14 : 17, weight: .semibold))
                .frame(
                    width: compact ? 30 : 38,
                    height: compact ? 30 : 34
                )
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(
                    Capsule().fill(selected ? Color.appAccent : .clear)
                )
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ProfileAvatarView: View {
    let profile: ViewingProfile
    let size: CGFloat

    var body: some View {
        Group {
            if let assetName = profile.avatar.assetName {
                Image(assetName)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: size * 0.21)
                    .fill(profile.avatar.gradient)
                    .overlay {
                        Image(systemName: profile.avatar.symbolName)
                            .font(.system(size: size * 0.42, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.21))
    }
}

private struct ProfileEditorRoute: Identifiable {
    let id = UUID()
    let profile: ViewingProfile?
}

private struct ViewingProfileEditorView: View {
    let title: String
    let initialName: String
    let initialAvatar: ViewingProfileAvatar
    let canArchive: Bool
    let onSave: @MainActor @Sendable (String, ViewingProfileAvatar) async throws -> Void
    let onArchive: (@MainActor @Sendable () async throws -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var avatar: ViewingProfileAvatar
    @State private var busy = false
    @State private var confirmsArchive = false
    @State private var errorMessage: String?

    init(
        title: String,
        initialName: String,
        initialAvatar: ViewingProfileAvatar,
        canArchive: Bool,
        onSave: @escaping @MainActor @Sendable (String, ViewingProfileAvatar) async throws -> Void,
        onArchive: (@MainActor @Sendable () async throws -> Void)?
    ) {
        self.title = title
        self.initialName = initialName
        self.initialAvatar = initialAvatar
        self.canArchive = canArchive
        self.onSave = onSave
        self.onArchive = onArchive
        _name = State(initialValue: initialName)
        _avatar = State(initialValue: initialAvatar)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Profile name", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                }
                Section("Choose an avatar") {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 72), spacing: 16)],
                        spacing: 16
                    ) {
                        ForEach(ViewingProfileAvatar.allCases, id: \.self) { choice in
                            Button {
                                avatar = choice
                            } label: {
                                ProfileAvatarView(
                                    profile: ViewingProfile(name: name, avatar: choice),
                                    size: 64
                                )
                                .overlay(alignment: .topTrailing) {
                                    if avatar == choice {
                                        Image(systemName: "checkmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, Color.appAccent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(choice.accessibilityName)
                            .accessibilityAddTraits(avatar == choice ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 6)
                }
                if onArchive != nil {
                    Section {
                        Button("Remove Profile", role: .destructive) {
                            confirmsArchive = true
                        }
                        .disabled(!canArchive || busy)
                    } footer: {
                        Text(
                            canArchive
                                ? "Removed profiles can be restored with their history intact."
                                : "At least one profile must remain."
                        )
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                }
            }
            .confirmationDialog(
                "Remove this profile?",
                isPresented: $confirmsArchive,
                titleVisibility: .visible
            ) {
                Button("Remove Profile", role: .destructive) { archive() }
            } message: {
                Text("Its library, progress, ratings, and recommendations will be kept for recovery.")
            }
            .alert("Profiles", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Something went wrong.")
            }
        }
    }

    private func save() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await onSave(name, avatar)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func archive() {
        guard let onArchive else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await onArchive()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private extension ViewingProfileAvatar {
    var assetName: String? {
        switch self {
        case .avril: return "ProfileAvril"
        case .sam: return "ProfileSam"
        case .lopBunny: return "ProfileLopBunny"
        case .goldenPuppy: return "ProfileGoldenPuppy"
        case .tabbyKitten: return "ProfileTabbyKitten"
        case .seaOtter: return "ProfileSeaOtter"
        case .bunny, .carrot, .moon, .star, .popcorn, .rocket: return nil
        }
    }

    var symbolName: String {
        switch self {
        case .bunny: return "hare.fill"
        case .carrot: return "carrot.fill"
        case .moon: return "moon.stars.fill"
        case .star: return "star.fill"
        case .popcorn: return "popcorn.fill"
        // `rocket.fill` is unavailable on part of our iOS 16 deployment range.
        // Keep the persisted avatar identity while rendering a filled symbol
        // that is present across every supported OS version.
        case .rocket: return "paperplane.fill"
        case .avril, .sam: return "person.crop.square.fill"
        case .lopBunny, .goldenPuppy, .tabbyKitten, .seaOtter:
            return "pawprint.fill"
        }
    }

    var accessibilityName: String {
        switch self {
        case .bunny: return "Bunny"
        case .carrot: return "Carrot"
        case .moon: return "Moon"
        case .star: return "Star"
        case .popcorn: return "Popcorn"
        case .rocket: return "Rocket"
        case .avril: return "Avril Lavigne"
        case .sam: return "Sam Altman"
        case .lopBunny: return "Lop bunny"
        case .goldenPuppy: return "Golden puppy"
        case .tabbyKitten: return "Tabby kitten"
        case .seaOtter: return "Sea otter"
        }
    }

    var gradient: LinearGradient {
        switch self {
        case .bunny:
            return LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .carrot:
            return LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .moon:
            return LinearGradient(colors: [.indigo, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .star:
            return LinearGradient(colors: [.yellow, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .popcorn:
            return LinearGradient(colors: [.red, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .rocket:
            return LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .avril:
            return LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .sam:
            return LinearGradient(colors: [.green, .gray], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .lopBunny:
            return LinearGradient(colors: [.brown, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .goldenPuppy:
            return LinearGradient(colors: [.yellow, .brown], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .tabbyKitten:
            return LinearGradient(colors: [.gray, .brown], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .seaOtter:
            return LinearGradient(colors: [.blue, .brown], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
