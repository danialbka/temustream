import SwiftUI

struct TVAddonsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var addonURL = ""
  @State private var isInstalling = false
  @State private var statusMessage: String?
  @State private var errorMessage: String?

  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 44) {
        TVScreenHeader(
          title: "Add-ons",
          subtitle: "Connect Stremio-compatible catalogs and stream providers"
        )

        VStack(alignment: .leading, spacing: 20) {
          TVSectionTitle(
            "Install an Add-on",
            subtitle: "Enter its HTTPS manifest address"
          )
          HStack(spacing: 18) {
            TextField("https://example.com/manifest.json", text: $addonURL)
              .textContentType(.URL)
              .autocorrectionDisabled()
            Button {
              Task { await install() }
            } label: {
              if isInstalling {
                Label("Installing…", systemImage: "hourglass")
              } else {
                Label("Install", systemImage: "plus")
              }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isInstalling || addonURL.isEmpty)
          }
          if let statusMessage {
            Label(statusMessage, systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
          }
        }
        .padding(30)
        .background(TVTheme.elevated, in: RoundedRectangle(cornerRadius: 24))

        VStack(alignment: .leading, spacing: 20) {
          TVSectionTitle(
            "Installed",
            subtitle:
              "\(model.installedAddons.count) manifest\(model.installedAddons.count == 1 ? "" : "s")"
          )

          ForEach(Array(model.installedAddons.enumerated()), id: \.element) { index, url in
            HStack(spacing: 20) {
              Image(systemName: index == 0 ? "sparkles.tv.fill" : "shippingbox.fill")
                .font(.title)
                .foregroundStyle(TVTheme.accent)
                .frame(width: 54)
              VStack(alignment: .leading, spacing: 5) {
                Text(index == 0 ? "Primary catalog" : (url.host ?? "Add-on"))
                  .font(.title3.weight(.semibold))
                Text(url.absoluteString)
                  .font(.callout.monospaced())
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              Spacer()
              if index > 0 {
                Button(role: .destructive) {
                  model.removeAddon(url)
                } label: {
                  Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.bordered)
              }
            }
            .padding(24)
            .background(TVTheme.elevated, in: RoundedRectangle(cornerRadius: 20))
          }
        }
      }
      .padding(.horizontal, TVTheme.horizontalInset)
      .padding(.top, TVTheme.screenTopInset)
      .padding(.bottom, 90)
    }
    .background(TVTheme.background)
    .alert(
      "Couldn’t install add-on",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "Please check the manifest address.")
    }
    .accessibilityIdentifier("tvos-addons")
  }

  @MainActor
  private func install() async {
    isInstalling = true
    statusMessage = nil
    defer { isInstalling = false }
    do {
      try await model.installAddon(addonURL)
      statusMessage = "Add-on installed"
      addonURL = ""
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
