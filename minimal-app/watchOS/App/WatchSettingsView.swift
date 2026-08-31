import SwiftUI

struct WatchManualStreamView: View {
    @EnvironmentObject private var model: WatchAppModel
    @State private var urlInput = ""
    @State private var errorMessage: String?
    @State private var selectedPlayback: WatchPlaybackRequest?
    @State private var isResolving = false

    var body: some View {
        List {
            Section {
                TextField("https://…/stream.m3u8", text: $urlInput)
                Button {
                    Task { await openStream() }
                } label: {
                    if isResolving {
                        ProgressView()
                    } else {
                        Label("Play on Watch", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isResolving
                        || urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            } footer: {
                Text("Use dictation, the watch keyboard, or paste an HTTP(S) URL. Non-native sources require your configured server.")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Supported") {
                Label("HTTPS HLS playlists", systemImage: "checkmark.circle.fill")
                Label("AVPlayer-compatible HTTPS video", systemImage: "checkmark.circle.fill")
                if model.hasConfiguredStreamingServer {
                    Label("Server-converted HTTP(S) video", systemImage: "server.rack")
                }
            }
        }
        .navigationTitle("Open Stream")
        .fullScreenCover(item: $selectedPlayback) { request in
            WatchPlaybackSessionView(request: request)
                .environmentObject(model)
        }
    }

    private func openStream() async {
        isResolving = true
        defer { isResolving = false }
        do {
            let request = try await model.resolveManualPlaybackRequest(
                urlInput: urlInput
            )
            errorMessage = nil
            selectedPlayback = request
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct WatchSettingsView: View {
    @EnvironmentObject private var model: WatchAppModel
    @State private var manifestInput = ""
    @State private var isInstalling = false
    @State private var installError: String?

    var body: some View {
        List {
            Section("Profile") {
                NavigationLink {
                    WatchProfilesView()
                } label: {
                    if let profile = model.activeViewingProfile {
                        Label(profile.name, systemImage: profile.avatar.watchSymbol)
                    } else {
                        Label("Profiles", systemImage: "person.2")
                    }
                }
            }

            Section("Account") {
                NavigationLink {
                    WatchAccountView()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(
                            model.isSignedIn ? "Stremio Account" : "Sign In",
                            systemImage: model.isSignedIn
                                ? "person.crop.circle.fill.badge.checkmark"
                                : "person.crop.circle"
                        )
                        Text(model.accountEmail ?? model.accountSyncStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Section("Stream Add-ons") {
                ForEach(model.addonURLs, id: \.self) { url in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(addonName(for: url))
                            .font(.headline)
                        Text(url.host ?? url.absoluteString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if url != WatchAppModel.defaultManifestURL {
                            Button(role: .destructive) {
                                Task { await model.removeAddon(url) }
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            .font(.caption)
                        }
                    }
                }

                TextField("HTTPS manifest URL", text: $manifestInput)
                Button {
                    Task { await installAddon() }
                } label: {
                    if isInstalling {
                        ProgressView()
                    } else {
                        Label("Install Add-on", systemImage: "plus.circle.fill")
                    }
                }
                .disabled(
                    isInstalling
                        || manifestInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                if let installError {
                    Text(installError)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                if model.isSignedIn {
                    Text(model.accountSyncStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Streaming Server") {
                NavigationLink {
                    WatchStreamingServerView()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(
                            model.hasConfiguredStreamingServer
                                ? "Configured Server"
                                : "Set Up Server",
                            systemImage: "server.rack"
                        )
                        if model.hasConfiguredStreamingServer {
                            Text(model.streamingServerOnline ? "Online" : "Not checked or offline")
                                .font(.caption2)
                                .foregroundStyle(
                                    model.streamingServerOnline
                                        ? WatchTheme.playable
                                        : .secondary
                                )
                        }
                    }
                }
            }

            Section("Playback") {
                Toggle("Autoplay Next Episode", isOn: $model.autoplayNextEpisode)

                Picker("Default Speed", selection: $model.preferredPlaybackRate) {
                    Text("0.75×").tag(0.75)
                    Text("1×").tag(1.0)
                    Text("1.25×").tag(1.25)
                    Text("1.5×").tag(1.5)
                }

                Picker("Audio", selection: $model.preferredAudioLanguage) {
                    ForEach(Self.languages, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }

                Toggle("Use Captions", isOn: $model.preferredSubtitlesEnabled)
                if model.preferredSubtitlesEnabled {
                    Picker("Captions", selection: $model.preferredSubtitleLanguage) {
                        ForEach(Self.languages, id: \.code) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                }
            }

            Section("Personalization") {
                Picker("Accent", selection: $model.accentPresetRawValue) {
                    ForEach(WatchAccentPreset.allCases) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                }
                Button {
                    Task { await model.resetPersonalization() }
                } label: {
                    Label("Reset Ratings & For You", systemImage: "arrow.counterclockwise")
                }
                if !model.recentSearches.isEmpty {
                    Button(role: .destructive) {
                        model.clearRecentSearches()
                    } label: {
                        Label("Clear Recent Searches", systemImage: "trash")
                    }
                }
            }

            Section("Watch Playback") {
                compatibilityRow("HLS and native HTTPS video", supported: true)
                compatibilityRow(
                    "Torrent via your streaming server",
                    supported: model.hasConfiguredStreamingServer
                )
                compatibilityRow(
                    "MKV or incompatible codecs via server HLS",
                    supported: model.hasConfiguredStreamingServer
                )
                compatibilityRow("DASH without HLS conversion", supported: false)
                compatibilityRow("VLC, FFmpeg, custom iPhone players", supported: false)
                Text("Native streams open directly. Sources that need conversion are sent only to a server you configure.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("On This Watch") {
                LabeledContent("Library", value: "\(model.library.count)")
                LabeledContent("Continue watching", value: "\(model.progress.count)")
                Text("Anonymous and signed-in library, progress, and add-on data stay in separate watch storage scopes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }

    private static let languages: [(code: String, name: String)] = [
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
    ]

    private func addonName(for url: URL) -> String {
        model.addons.first { $0.manifestURL == url }?.manifest.name
            ?? (url == WatchAppModel.defaultManifestURL ? "Cinemeta" : "Unavailable Add-on")
    }

    private func compatibilityRow(_ title: String, supported: Bool) -> some View {
        Label(
            title,
            systemImage: supported ? "checkmark.circle.fill" : "xmark.circle"
        )
        .foregroundStyle(supported ? WatchTheme.playable : WatchTheme.unavailable)
    }

    private func installAddon() async {
        isInstalling = true
        defer { isInstalling = false }
        do {
            try await model.installAddon(manifestInput)
            manifestInput = ""
            installError = nil
        } catch {
            installError = error.localizedDescription
        }
    }
}

struct WatchAccountView: View {
    @EnvironmentObject private var model: WatchAppModel
    @State private var email = ""
    @State private var password = ""
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if model.isSignedIn {
                Section("Stremio Account") {
                    if let email = model.accountEmail {
                        LabeledContent("Signed in", value: email)
                    }
                    LabeledContent("Status", value: model.accountSyncStatus)
                    Button {
                        Task { await syncNow() }
                    } label: {
                        if isBusy || model.isSyncingAccount {
                            ProgressView()
                        } else {
                            Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(isBusy || model.isSyncingAccount)

                    Button(role: .destructive) {
                        Task {
                            errorMessage = nil
                            await model.signOut()
                        }
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            } else {
                Section("Sign In") {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    Button {
                        Task { await signIn() }
                    } label: {
                        if isBusy {
                            ProgressView()
                        } else {
                            Label("Sign In & Sync", systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || !canSubmitSignIn)
                    if let signInValidationMessage {
                        Text(signInValidationMessage)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("watch-account-sign-in-validation")
                    }
                }
            }

            Section("Synced") {
                if model.viewingProfileSnapshot?.activeProfileAllowsAccountLibrarySync == true {
                    Label("Account library", systemImage: "bookmark")
                } else {
                    Label("Local profile library", systemImage: "bookmark")
                }
                Label("Installed add-ons", systemImage: "shippingbox")
                Label(WatchSessionStore.storageDescription, systemImage: "key.fill")
                Text("Your password is submitted for sign-in and is never saved by Bunny.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if model.viewingProfileSnapshot?.activeProfileAllowsAccountLibrarySync == false {
                    Text("Only the primary profile syncs the account’s canonical Stremio library. This profile’s library remains isolated on the watch.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Account")
        .onChange(of: email) { _, _ in errorMessage = nil }
        .onChange(of: password) { _, _ in errorMessage = nil }
    }

    private var canSubmitSignIn: Bool {
        SignInFormCredentials.canSubmit(email: email, password: password)
    }

    private var signInValidationMessage: String? {
        guard !email.isEmpty || !password.isEmpty else { return nil }
        return SignInFormCredentials.validationError(email: email, password: password)
    }

    private func signIn() async {
        let credentials: SignInFormCredentials
        do {
            credentials = try SignInFormCredentials(email: email, password: password)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        isBusy = true
        errorMessage = nil
        password = ""
        defer { isBusy = false }
        do {
            try await model.signIn(
                email: credentials.email,
                password: credentials.password
            )
            email = credentials.email
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func syncNow() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await model.syncAccount()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct WatchStreamingServerView: View {
    @EnvironmentObject private var model: WatchAppModel
    @State private var isChecking = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                TextField("https://server.example", text: $model.streamingServerInput)
                    .textInputAutocapitalization(.never)
                Button {
                    Task { await saveAndTest() }
                } label: {
                    if isChecking {
                        ProgressView()
                    } else {
                        Label("Save & Test", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isChecking
                        || model.streamingServerInput
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                )

                if model.hasConfiguredStreamingServer {
                    Label(
                        model.streamingServerOnline ? "Server online" : "Server offline",
                        systemImage: model.streamingServerOnline
                            ? "checkmark.circle.fill"
                            : "xmark.circle"
                    )
                    .foregroundStyle(
                        model.streamingServerOnline
                            ? WatchTheme.playable
                            : WatchTheme.unavailable
                    )
                }

                if model.hasConfiguredStreamingServer {
                    Button(role: .destructive) {
                        model.clearStreamingServer()
                        errorMessage = nil
                    } label: {
                        Label("Forget Server", systemImage: "trash")
                    }
                }
            } header: {
                Text("Server URL")
            } footer: {
                Text("Use HTTPS, or HTTP only for a private LAN host. Credentials, query tokens, and public HTTP servers are rejected.")
            }

            Section("What It Does") {
                Label("Resolves torrent sources", systemImage: "link")
                Label("Converts incompatible video to HLS", systemImage: "arrow.triangle.2.circlepath")
                Text("The server must be one you operate or are authorized to use. Bunny does not include a server or bypass service access rules.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Stream Server")
        .task {
            guard model.hasConfiguredStreamingServer else { return }
            isChecking = true
            await model.refreshStreamingServerStatus()
            isChecking = false
        }
    }

    private func saveAndTest() async {
        isChecking = true
        errorMessage = nil
        defer { isChecking = false }
        do {
            try await model.saveStreamingServer()
            if !model.streamingServerOnline {
                errorMessage = "Saved, but the watch could not reach this server."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
