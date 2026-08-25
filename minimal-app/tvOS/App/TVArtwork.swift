import SwiftUI

struct TVRemoteImage: View {
  let url: URL?
  let contentMode: ContentMode
  let systemImage: String

  init(
    url: URL?,
    contentMode: ContentMode = .fill,
    systemImage: String = "film"
  ) {
    self.url = url
    self.contentMode = contentMode
    self.systemImage = systemImage
  }

  var body: some View {
    AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
      switch phase {
      case .success(let image):
        image
          .resizable()
          .aspectRatio(contentMode: contentMode)
      case .empty:
        ZStack {
          TVTheme.elevated
          ProgressView()
            .controlSize(.large)
        }
      case .failure:
        placeholder
      @unknown default:
        placeholder
      }
    }
  }

  private var placeholder: some View {
    ZStack {
      LinearGradient(
        colors: [Color.white.opacity(0.12), Color.white.opacity(0.04)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      Image(systemName: systemImage)
        .font(.system(size: 56, weight: .light))
        .foregroundStyle(.secondary)
    }
  }
}

struct TVMediaLink: View {
  let item: MetaItem
  let preferredManifestURL: URL?
  let progress: PlaybackProgress?

  init(
    item: MetaItem,
    preferredManifestURL: URL? = nil,
    progress: PlaybackProgress? = nil
  ) {
    self.item = item
    self.preferredManifestURL = preferredManifestURL
    self.progress = progress
  }

  var body: some View {
    NavigationLink {
      TVDetailsView(
        seed: item,
        preferredManifestURL: preferredManifestURL
      )
    } label: {
      VStack(alignment: .leading, spacing: 12) {
        ZStack(alignment: .bottom) {
          TVRemoteImage(url: item.poster)
            .frame(width: TVTheme.posterWidth, height: TVTheme.posterHeight)
            .clipped()

          if let progress, progress.duration > 0 {
            GeometryReader { proxy in
              let fraction = min(max(progress.position / progress.duration, 0), 1)
              ZStack(alignment: .leading) {
                Color.white.opacity(0.3)
                TVTheme.accent
                  .frame(width: proxy.size.width * fraction)
              }
            }
            .frame(height: 7)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

        Text(item.name)
          .font(.headline)
          .lineLimit(1)
        Text(progress.map(resumeLabel) ?? secondaryLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(width: TVTheme.posterWidth, alignment: .leading)
    }
    .buttonStyle(.card)
    .accessibilityIdentifier("tv-media-\(item.type)-\(item.id)")
  }

  private var secondaryLabel: String {
    [item.releaseInfo, item.genres?.first]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .joined(separator: " · ")
      .nilIfEmpty ?? item.type.capitalized
  }

  private func resumeLabel(_ progress: PlaybackProgress) -> String {
    let minutes = Int(progress.position) / 60
    return "Resume from \(minutes)m"
  }
}

struct TVBackdrop: View {
  let item: MetaItem

  var body: some View {
    TVRemoteImage(url: item.background ?? item.poster)
      .overlay {
        LinearGradient(
          colors: [
            .clear,
            TVTheme.background.opacity(0.18),
            TVTheme.background.opacity(0.96),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
      }
      .overlay(alignment: .leading) {
        LinearGradient(
          colors: [TVTheme.background.opacity(0.96), .clear],
          startPoint: .leading,
          endPoint: .trailing
        )
        .frame(maxWidth: 1_050)
      }
      .clipped()
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
