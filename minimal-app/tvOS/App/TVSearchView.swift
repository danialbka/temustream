import SwiftUI

struct TVSearchView: View {
  @EnvironmentObject private var model: AppModel
  @State private var query = ""
  @State private var mediaType = "movie"

  var body: some View {
    VStack(alignment: .leading, spacing: 46) {
      HStack {
        VStack(alignment: .leading, spacing: 8) {
          Text("Search")
            .font(.system(size: 54, weight: .bold))
          Text("Titles, actors, directors, writers, and genres")
            .font(.title3)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Picker("Type", selection: $mediaType) {
          Text("Movies").tag("movie")
          Text("Series").tag("series")
        }
        .pickerStyle(.segmented)
        .frame(width: 430)
      }

      TextField("Search Bunny", text: $query)
        .submitLabel(.search)
        .onSubmit { runSearch(query) }
        .accessibilityIdentifier("tvos-search-field")

      ScrollView(.vertical, showsIndicators: false) {
        LazyVStack(alignment: .leading, spacing: 46) {
          if model.isSearching {
            HStack(spacing: 18) {
              ProgressView()
                .controlSize(.large)
              Text("Searching installed add-ons…")
                .font(.title2)
            }
            .frame(maxWidth: .infinity, minHeight: 260)
          } else if let message = model.searchFailureMessage {
            TVEmptyState(
              title: "Search unavailable",
              message: message,
              systemImage: "magnifyingglass"
            )
          } else if model.searchCatalogs.isEmpty {
            if !model.recentSearches.isEmpty {
              recentSearches
            } else {
              TVEmptyState(
                title: "What do you want to watch?",
                message:
                  "Press Select in the search field and use the onscreen keyboard or Siri Remote dictation.",
                systemImage: "sparkle.magnifyingglass"
              )
            }
          } else {
            ForEach(model.searchCatalogs) { group in
              TVMediaShelf(
                title: group.catalogName,
                subtitle: group.providerName,
                items: group.items,
                preferredManifestURL: group.manifestURL
              )
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 90)
      }
    }
    .padding(.horizontal, TVTheme.horizontalInset)
    .padding(.top, 125)
    .onChange(of: mediaType) { _, _ in
      if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        runSearch(query)
      }
    }
    .onChange(of: query) { _, newValue in
      if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        model.clearSearch()
      }
    }
    .background(TVTheme.background)
    .accessibilityIdentifier("tvos-search")
  }

  private var recentSearches: some View {
    VStack(alignment: .leading, spacing: 20) {
      TVSectionTitle("Recent Searches")
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 18) {
          ForEach(model.recentSearches, id: \.self) { recent in
            Button(recent) {
              query = recent
              runSearch(recent)
            }
            .buttonStyle(.bordered)
          }
        }
        .padding(.vertical, 16)
      }
      .focusSection()
    }
  }

  private func runSearch(_ rawValue: String) {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      model.clearSearch()
      return
    }
    model.recordRecentSearch(value)
    Task { await model.searchAllCatalogs(value, mediaType: mediaType) }
  }
}
