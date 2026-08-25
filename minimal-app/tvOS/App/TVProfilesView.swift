import SwiftUI

struct TVProfilesView: View {
  @EnvironmentObject private var model: AppModel
  @State private var newName = ""
  @State private var newAvatar: ViewingProfileAvatar = .bunny
  @State private var isCreating = false
  @State private var errorMessage: String?

  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 48) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Who’s Watching?")
            .font(.system(size: 54, weight: .bold))
          Text("Each profile keeps separate recommendations, My List, searches, and progress")
            .font(.title3)
            .foregroundStyle(.secondary)
        }

        if let snapshot = model.viewingProfileSnapshot {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 34) {
              ForEach(snapshot.profiles) { profile in
                VStack(spacing: 16) {
                  Button {
                    Task {
                      do { try await model.selectViewingProfile(id: profile.id) } catch {
                        errorMessage = error.localizedDescription
                      }
                    }
                  } label: {
                    TVProfileCard(
                      profile: profile,
                      isActive: profile.id == snapshot.activeProfileID
                    )
                  }
                  .buttonStyle(.card)

                  if profile.id != snapshot.activeProfileID,
                    snapshot.profiles.count > 1
                  {
                    Button(role: .destructive) {
                      Task {
                        do { try await model.archiveViewingProfile(id: profile.id) } catch {
                          errorMessage = error.localizedDescription
                        }
                      }
                    } label: {
                      Label("Archive", systemImage: "archivebox")
                    }
                    .buttonStyle(.bordered)
                  }
                }
              }
            }
            .padding(.vertical, 20)
          }
          .focusSection()

          createSection

          if !snapshot.archivedProfiles.isEmpty {
            archivedSection(snapshot.archivedProfiles)
          }
        } else {
          ProgressView("Loading profiles…")
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 400)
        }
      }
      .padding(.horizontal, TVTheme.horizontalInset)
      .padding(.top, 52)
      .padding(.bottom, 90)
    }
    .background(TVTheme.background)
    .alert(
      "Profile Error",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "Please try again.")
    }
    .navigationTitle("Profiles")
    .accessibilityIdentifier("tvos-profiles")
  }

  private var createSection: some View {
    VStack(alignment: .leading, spacing: 22) {
      TVSectionTitle("Create Profile")
      HStack(spacing: 18) {
        TextField("Profile name", text: $newName)
        Picker("Avatar", selection: $newAvatar) {
          ForEach(ViewingProfileAvatar.allCases, id: \.rawValue) { avatar in
            Label(avatar.tvTitle, systemImage: avatar.tvSystemImage)
              .tag(avatar)
          }
        }
        .frame(width: 360)
        Button {
          Task { await createProfile() }
        } label: {
          Label(isCreating ? "Creating…" : "Create", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .disabled(isCreating || newName.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(30)
    .background(TVTheme.elevated, in: RoundedRectangle(cornerRadius: 24))
  }

  private func archivedSection(_ profiles: [ViewingProfile]) -> some View {
    VStack(alignment: .leading, spacing: 20) {
      TVSectionTitle("Archived Profiles")
      ForEach(profiles) { profile in
        HStack {
          Label(profile.name, systemImage: profile.avatar.tvSystemImage)
            .font(.title3)
          Spacer()
          Button {
            Task {
              do { try await model.restoreViewingProfile(id: profile.id) } catch {
                errorMessage = error.localizedDescription
              }
            }
          } label: {
            Label("Restore", systemImage: "arrow.uturn.backward")
          }
          .buttonStyle(.bordered)
        }
        .padding(22)
        .background(TVTheme.elevated, in: RoundedRectangle(cornerRadius: 18))
      }
    }
  }

  @MainActor
  private func createProfile() async {
    isCreating = true
    defer { isCreating = false }
    do {
      try await model.createViewingProfile(name: newName, avatar: newAvatar)
      newName = ""
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

private struct TVProfileCard: View {
  let profile: ViewingProfile
  let isActive: Bool

  var body: some View {
    VStack(spacing: 18) {
      ZStack {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
          .fill(
            LinearGradient(
              colors: [TVTheme.accent.opacity(0.8), Color.purple.opacity(0.65)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
        Image(systemName: profile.avatar.tvSystemImage)
          .font(.system(size: 88, weight: .semibold))
          .foregroundStyle(.white)
      }
      .frame(width: 250, height: 250)
      .overlay(alignment: .topTrailing) {
        if isActive {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 34))
            .foregroundStyle(.white, TVTheme.accent)
            .padding(14)
        }
      }

      Text(profile.name)
        .font(.title2.bold())
        .lineLimit(1)
      Text(isActive ? "Current profile" : "Select profile")
        .font(.headline)
        .foregroundStyle(isActive ? TVTheme.accent : .secondary)
    }
    .frame(width: 250)
  }
}

extension ViewingProfileAvatar {
  var tvSystemImage: String {
    switch self {
    case .bunny, .lopBunny: "hare.fill"
    case .carrot: "carrot.fill"
    case .moon: "moon.stars.fill"
    case .star: "star.fill"
    case .popcorn: "popcorn.fill"
    case .rocket: "rocket.fill"
    case .avril: "music.mic"
    case .sam: "person.crop.circle.fill"
    case .goldenPuppy: "dog.fill"
    case .tabbyKitten: "cat.fill"
    case .seaOtter: "water.waves"
    }
  }

  var tvTitle: String {
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
}
