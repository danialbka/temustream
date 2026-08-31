import SwiftUI

struct TVSettingsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var email = ""
  @State private var password = ""
  @State private var isSigningIn = false
  @State private var isSavingServer = false
  @State private var isResettingPersonalization = false
  @State private var statusMessage: String?
  @State private var errorMessage: String?

  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 44) {
        TVScreenHeader(
          title: "Settings",
          subtitle: "Profiles, account sync, and playback connectivity"
        )

        if let statusMessage {
          Label(statusMessage, systemImage: "checkmark.circle.fill")
            .font(.headline)
            .foregroundStyle(.green)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.green.opacity(0.14), in: Capsule())
        }

        profileSection
        accountSection
        serverSection
        privacySection
        aboutSection
      }
      .padding(.horizontal, TVTheme.horizontalInset)
      .padding(.top, TVTheme.screenTopInset)
      .padding(.bottom, 90)
    }
    .background(TVTheme.background)
    .alert(
      "Settings Error",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "Please try again.")
    }
    .onChange(of: email) { _, _ in errorMessage = nil }
    .onChange(of: password) { _, _ in errorMessage = nil }
    .accessibilityIdentifier("tvos-settings")
  }

  private var profileSection: some View {
    settingsCard {
      HStack(spacing: 26) {
        Image(systemName: model.activeViewingProfile?.avatar.tvSystemImage ?? "person.crop.circle")
          .font(.system(size: 48))
          .foregroundStyle(TVTheme.accent)
          .frame(width: 72)
        VStack(alignment: .leading, spacing: 6) {
          Text("Viewing Profiles")
            .font(.title2.bold())
          Text(model.activeViewingProfile.map { "Watching as \($0.name)" } ?? "Loading profiles…")
            .font(.headline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        NavigationLink {
          TVProfilesView()
        } label: {
          Label("Manage Profiles", systemImage: "chevron.right")
        }
        .buttonStyle(.borderedProminent)
      }
    }
  }

  @ViewBuilder
  private var accountSection: some View {
    settingsCard {
      VStack(alignment: .leading, spacing: 22) {
        TVSectionTitle(
          "Stremio Account",
          subtitle: model.accountSyncStatus
        )

        if let accountEmail = model.accountEmail {
          HStack {
            Label(accountEmail, systemImage: "person.crop.circle.fill")
              .font(.title3)
            Spacer()
            Button(role: .destructive) {
              Task { await model.signOut() }
            } label: {
              Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.bordered)
          }
        } else {
          TextField("Email", text: $email)
            .textContentType(.username)
            .autocorrectionDisabled()
          SecureField("Password", text: $password)
            .textContentType(.password)
          if let signInValidationMessage {
            Label(signInValidationMessage, systemImage: "exclamationmark.circle")
              .font(.callout)
              .foregroundStyle(.red)
              .accessibilityIdentifier("tvos-account-sign-in-validation")
          }
          Button {
            Task { await signIn() }
          } label: {
            if isSigningIn {
              Label("Signing In…", systemImage: "hourglass")
            } else {
              Label("Sign In", systemImage: "person.badge.key.fill")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isSigningIn || !canSubmitSignIn)
        }
      }
    }
  }

  private var serverSection: some View {
    settingsCard {
      VStack(alignment: .leading, spacing: 22) {
        TVSectionTitle(
          "Streaming Server",
          subtitle: model.streamingServerOnline ? "Online" : "Offline or not checked"
        )
        HStack(spacing: 18) {
          TextField("http://192.168.1.10:11470", text: $model.streamingServerInput)
            .textContentType(.URL)
            .autocorrectionDisabled()
          Button {
            Task { await saveServer() }
          } label: {
            Label(
              isSavingServer ? "Checking…" : "Save & Check",
              systemImage: model.streamingServerOnline
                ? "checkmark.circle.fill"
                : "network"
            )
          }
          .buttonStyle(.borderedProminent)
          .disabled(isSavingServer)
        }
        Text(
          "A LAN or HTTPS streaming server is used for torrents and formats AVKit can’t play directly."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    }
  }

  private var privacySection: some View {
    settingsCard {
      HStack(spacing: 28) {
        Image(systemName: "hand.raised.fill")
          .font(.system(size: 44))
          .foregroundStyle(TVTheme.accent)
        VStack(alignment: .leading, spacing: 7) {
          Text("Private Personalization")
            .font(.title2.bold())
          Text(
            "Ratings, recommendations, search history, and watch progress remain local to this Apple TV profile."
          )
          .font(.headline)
          .foregroundStyle(.secondary)
        }
        Spacer()
        Button(role: .destructive) {
          Task { await resetPersonalization() }
        } label: {
          Label(
            isResettingPersonalization ? "Resetting…" : "Reset Recommendations",
            systemImage: "arrow.counterclockwise"
          )
        }
        .buttonStyle(.bordered)
        .disabled(isResettingPersonalization)
      }
    }
  }

  private var aboutSection: some View {
    settingsCard {
      HStack {
        VStack(alignment: .leading, spacing: 8) {
          Text("Bunny for Apple TV")
            .font(.title2.bold())
          Text(AppBundleMetadata().versionLabel)
            .font(.headline)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("tvos-version-build")
          Text(
            "Uses the native tvOS player for Siri Remote controls, audio tracks, subtitles, and display matching."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "appletv.fill")
          .font(.system(size: 64))
          .foregroundStyle(TVTheme.accent)
      }
    }
  }

  private func settingsCard<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    content()
      .padding(30)
      .background(TVTheme.elevated, in: RoundedRectangle(cornerRadius: 24))
  }

  @MainActor
  private func signIn() async {
    let credentials: SignInFormCredentials
    do {
      credentials = try SignInFormCredentials(email: email, password: password)
    } catch {
      errorMessage = error.localizedDescription
      return
    }

    isSigningIn = true
    errorMessage = nil
    defer { isSigningIn = false }
    do {
      try await model.signIn(email: credentials.email, password: credentials.password)
      email = credentials.email
      password = ""
      statusMessage = "Signed in"
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private var canSubmitSignIn: Bool {
    SignInFormCredentials.canSubmit(email: email, password: password)
  }

  private var signInValidationMessage: String? {
    guard !email.isEmpty || !password.isEmpty else { return nil }
    return SignInFormCredentials.validationError(email: email, password: password)
  }

  @MainActor
  private func saveServer() async {
    isSavingServer = true
    defer { isSavingServer = false }
    do {
      try await model.saveStreamingServer()
      statusMessage = model.streamingServerOnline ? "Server online" : "Server saved"
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func resetPersonalization() async {
    isResettingPersonalization = true
    defer { isResettingPersonalization = false }
    do {
      try await model.resetViewingProfilePersonalization()
      statusMessage = "Recommendations reset"
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
