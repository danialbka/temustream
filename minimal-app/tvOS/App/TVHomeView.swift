import SwiftUI

struct TVHomeView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      LazyVStack(alignment: .leading, spacing: TVTheme.shelfSpacing) {
        header

        if let heroItem {
          TVHeroView(
            item: heroItem,
            progress: heroProgress
          )
        }

        if model.isLoading && model.homeShelves.isEmpty {
          HStack(spacing: 18) {
            ProgressView()
              .controlSize(.large)
            Text("Loading your shelves…")
              .font(.title2)
          }
          .frame(maxWidth: .infinity, minHeight: 300)
        } else if let error = model.errorMessage, model.homeShelves.isEmpty {
          TVEmptyState(
            title: "Couldn’t load TemuStremio",
            message: error,
            systemImage: "wifi.exclamationmark"
          )
          Button("Try Again") {
            Task { try? await model.loadHome() }
          }
          .buttonStyle(.borderedProminent)
          .frame(maxWidth: .infinity)
        } else {
          if !model.continueWatching.isEmpty {
            TVMediaShelf(
              title: "Continue Watching",
              subtitle: "Pick up where you left off",
              items: model.continueWatching.map(\.item),
              progressByIdentity: continueProgressByIdentity
            )
          }

          ForEach(model.homeShelves) { shelf in
            TVMediaShelf(
              title: shelf.title,
              subtitle: shelf.subtitle,
              items: shelf.items
            )
          }
        }
      }
      .padding(.bottom, 90)
    }
    .background(TVTheme.background)
    .accessibilityIdentifier("tvos-home")
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 28) {
      VStack(alignment: .leading, spacing: 4) {
        Text("TemuStremio")
          .font(.system(size: 42, weight: .black, design: .rounded))
        Text("Made for Apple TV")
          .font(.headline)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Menu {
        ForEach(model.catalogSources) { source in
          Button {
            Task { try? await model.selectCatalogSource(source) }
          } label: {
            if source.id == model.selectedCatalogSourceID {
              Label(source.title, systemImage: "checkmark")
            } else {
              Text(source.title)
            }
          }
        }
      } label: {
        Label(
          model.selectedCatalogSource?.title ?? "Catalog",
          systemImage: "square.grid.2x2"
        )
        .foregroundStyle(.white)
      }
      .buttonStyle(.bordered)

      if let profile = model.activeViewingProfile {
        Label(profile.name, systemImage: profile.avatar.tvSystemImage)
          .font(.headline)
          .padding(.horizontal, 18)
          .padding(.vertical, 10)
          .background(TVTheme.elevated, in: Capsule())
      }
    }
    .padding(.horizontal, TVTheme.horizontalInset)
    .padding(.top, 105)
  }

  private var heroItem: MetaItem? {
    model.continueWatching.first?.item
      ?? model.homeShelves.first?.items.first
      ?? model.catalog.first
  }

  private var heroProgress: PlaybackProgress? {
    guard let heroItem else { return nil }
    return model.continueWatching.first(where: {
      MediaIdentity($0.item) == MediaIdentity(heroItem)
    })?.progress
  }

  private var continueProgressByIdentity: [MediaIdentity: PlaybackProgress] {
    model.continueWatching.reduce(into: [:]) { result, entry in
      result[MediaIdentity(entry.item)] = entry.progress
    }
  }
}

struct TVHeroView: View {
  let item: MetaItem
  let progress: PlaybackProgress?

  var body: some View {
    TVBackdrop(item: item)
      .frame(height: 620)
      .overlay(alignment: .bottomLeading) {
        VStack(alignment: .leading, spacing: 18) {
          Text(item.name)
            .font(.system(size: 62, weight: .bold))
            .lineLimit(2)
            .frame(maxWidth: 880, alignment: .leading)

          HStack(spacing: 14) {
            if let releaseInfo = item.releaseInfo {
              Text(releaseInfo)
            }
            Text(item.type.capitalized)
            if let rating = item.imdbRating {
              Label(rating, systemImage: "star.fill")
            }
          }
          .font(.headline)
          .foregroundStyle(.secondary)

          if let description = item.description, !description.isEmpty {
            Text(description)
              .font(.title3)
              .foregroundStyle(Color.white.opacity(0.82))
              .lineLimit(2)
              .frame(maxWidth: 850, alignment: .leading)
          }

          NavigationLink {
            TVDetailsView(seed: item)
          } label: {
            Label(
              progress == nil ? "View Details" : "Continue Watching",
              systemImage: progress == nil ? "info.circle.fill" : "play.fill"
            )
            .foregroundStyle(.white)
          }
          .buttonStyle(.borderedProminent)
        }
        .padding(54)
      }
      .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
      .padding(.horizontal, TVTheme.horizontalInset)
      .accessibilityIdentifier("tvos-home-hero")
  }
}

struct TVMediaShelf: View {
  let title: String
  let subtitle: String?
  let items: [MetaItem]
  let preferredManifestURL: URL?
  let progressByIdentity: [MediaIdentity: PlaybackProgress]

  init(
    title: String,
    subtitle: String? = nil,
    items: [MetaItem],
    preferredManifestURL: URL? = nil,
    progressByIdentity: [MediaIdentity: PlaybackProgress] = [:]
  ) {
    self.title = title
    self.subtitle = subtitle
    self.items = items
    self.preferredManifestURL = preferredManifestURL
    self.progressByIdentity = progressByIdentity
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      TVSectionTitle(title, subtitle: subtitle)
        .padding(.horizontal, TVTheme.horizontalInset)

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(alignment: .top, spacing: 32) {
          ForEach(items) { item in
            TVMediaLink(
              item: item,
              preferredManifestURL: preferredManifestURL,
              progress: progressByIdentity[MediaIdentity(item)]
            )
          }
        }
        .padding(.horizontal, TVTheme.horizontalInset)
        .padding(.vertical, 20)
      }
      .focusSection()
    }
  }
}
