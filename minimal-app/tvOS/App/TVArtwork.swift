import SwiftUI
import UIKit

private enum TVArtworkLoadPhase {
  case empty
  case success(UIImage)
  case failure
}

struct TVRemoteImage: View {
  let url: URL?
  let contentMode: ContentMode
  let systemImage: String

  @State private var phase: TVArtworkLoadPhase = .empty

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
    Group {
      switch phase {
      case .success(let image):
        Image(uiImage: image)
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
      }
    }
    .task(id: url) {
      phase = .empty
      guard let url,
            let data = await ArtworkDataCache.shared.data(
              for: url,
              limits: .television
            ),
            !Task.isCancelled,
            let image = UIImage(data: data)
      else {
        if !Task.isCancelled {
          phase = .failure
        }
        return
      }
      withAnimation(.easeOut(duration: 0.2)) {
        phase = .success(image)
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
      VStack(alignment: .leading, spacing: 0) {
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
        .frame(width: TVTheme.posterWidth, height: TVTheme.posterHeight)

        VStack(alignment: .leading, spacing: 5) {
          Text(item.name)
            .font(.headline)
            .lineLimit(2)
            .minimumScaleFactor(0.82)
            .frame(height: 48, alignment: .topLeading)
          Text(progress.map(resumeLabel) ?? secondaryLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: TVTheme.posterWidth, height: 102, alignment: .topLeading)
      }
      .frame(width: TVTheme.posterWidth, height: TVTheme.posterHeight + 102, alignment: .topLeading)
      .background(TVTheme.surface)
      .clipShape(
        RoundedRectangle(cornerRadius: TVTheme.cardCornerRadius, style: .continuous)
      )
      .contentShape(
        RoundedRectangle(cornerRadius: TVTheme.cardCornerRadius, style: .continuous)
      )
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
    let minutes = PlaybackTimeFormatter.wholeSeconds(progress.position).map { $0 / 60 } ?? 0
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
