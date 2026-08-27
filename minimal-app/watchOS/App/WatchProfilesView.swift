import SwiftUI

struct WatchProfilesView: View {
    @EnvironmentObject private var model: WatchAppModel
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let snapshot = model.viewingProfileSnapshot {
                Section("Who’s Watching?") {
                    ForEach(snapshot.profiles) { profile in
                        VStack(alignment: .leading, spacing: 5) {
                            Button {
                                Task { await select(profile) }
                            } label: {
                                HStack(spacing: 9) {
                                    WatchProfileAvatar(profile: profile)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.name)
                                            .font(.headline)
                                        Text(
                                            profile.id == snapshot.activeProfileID
                                                ? "Current profile"
                                                : "Switch profile"
                                        )
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if profile.id == snapshot.activeProfileID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(WatchTheme.playable)
                                    }
                                }
                            }
                            .buttonStyle(.plain)

                            NavigationLink("Edit") {
                                WatchProfileEditorView(profile: profile)
                            }
                            .font(.caption)
                        }
                        .swipeActions {
                            if snapshot.profiles.count > 1 {
                                Button(role: .destructive) {
                                    Task { await archive(profile) }
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                            }
                        }
                    }

                    NavigationLink {
                        WatchProfileEditorView(profile: nil)
                    } label: {
                        Label("New Profile", systemImage: "person.badge.plus")
                    }
                }

                if !snapshot.archivedProfiles.isEmpty {
                    Section("Archived") {
                        ForEach(snapshot.archivedProfiles) { profile in
                            Button {
                                Task { await restore(profile) }
                            } label: {
                                Label(
                                    "Restore \(profile.name)",
                                    systemImage: "arrow.uturn.backward.circle"
                                )
                            }
                        }
                    }
                }

                Section {
                    Text("Each profile has its own account session, library, progress, add-ons, searches, ratings, recommendations, and playback preferences on this watch.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Loading Profiles")
            }
        }
        .navigationTitle("Profiles")
        .alert(
            "Profiles",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "The profile could not be updated.")
        }
    }

    private func select(_ profile: ViewingProfile) async {
        do { try await model.selectViewingProfile(id: profile.id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func archive(_ profile: ViewingProfile) async {
        do { try await model.archiveViewingProfile(id: profile.id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func restore(_ profile: ViewingProfile) async {
        do { try await model.restoreViewingProfile(id: profile.id) }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct WatchProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: WatchAppModel
    let profile: ViewingProfile?

    @State private var name: String
    @State private var avatar: ViewingProfileAvatar
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(profile: ViewingProfile?) {
        self.profile = profile
        _name = State(initialValue: profile?.name ?? "")
        _avatar = State(initialValue: profile?.avatar ?? .lopBunny)
    }

    var body: some View {
        List {
            Section("Name") {
                TextField("Profile name", text: $name)
            }

            Section("Avatar") {
                Picker("Avatar", selection: $avatar) {
                    ForEach(ViewingProfileAvatar.allCases, id: \.self) { choice in
                        Label(choice.watchTitle, systemImage: choice.watchSymbol)
                            .tag(choice)
                    }
                }
                .labelsHidden()
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Label(
                            profile == nil ? "Create Profile" : "Save Changes",
                            systemImage: "checkmark.circle.fill"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isSaving
                        || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .navigationTitle(profile == nil ? "New Profile" : "Edit Profile")
        .alert(
            "Profile",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "The profile could not be saved.")
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            if let profile {
                try await model.updateViewingProfile(
                    id: profile.id,
                    name: name,
                    avatar: avatar
                )
            } else {
                try await model.createViewingProfile(name: name, avatar: avatar)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct WatchProfileAvatar: View {
    let profile: ViewingProfile

    var body: some View {
        Image(systemName: profile.avatar.watchSymbol)
            .font(.headline)
            .frame(width: 34, height: 34)
            .foregroundStyle(.black)
            .background(WatchTheme.accent, in: Circle())
            .accessibilityHidden(true)
    }
}

extension ViewingProfileAvatar {
    var watchTitle: String {
        switch self {
        case .bunny: "Bunny"
        case .carrot: "Carrot"
        case .moon: "Moon"
        case .star: "Star"
        case .popcorn: "Popcorn"
        case .rocket: "Rocket"
        case .avril: "Avril"
        case .sam: "Sam"
        case .lopBunny: "Lop Bunny"
        case .goldenPuppy: "Golden Puppy"
        case .tabbyKitten: "Tabby Kitten"
        case .seaOtter: "Sea Otter"
        }
    }

    var watchSymbol: String {
        switch self {
        case .bunny, .lopBunny: "hare.fill"
        case .carrot: "carrot.fill"
        case .moon: "moon.stars.fill"
        case .star: "star.fill"
        case .popcorn: "popcorn.fill"
        case .rocket: "rocket.fill"
        case .avril, .sam: "person.crop.circle.fill"
        case .goldenPuppy: "dog.fill"
        case .tabbyKitten: "cat.fill"
        case .seaOtter: "water.waves"
        }
    }
}
