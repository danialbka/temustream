import SwiftUI

struct TVLibraryView: View {
  @EnvironmentObject private var model: AppModel
  private let columns = [
    GridItem(.adaptive(minimum: TVTheme.posterWidth, maximum: TVTheme.posterWidth), spacing: 36)
  ]

  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 38) {
        VStack(alignment: .leading, spacing: 8) {
          Text("My List")
            .font(.system(size: 54, weight: .bold))
          Text(activeProfileSubtitle)
            .font(.title3)
            .foregroundStyle(.secondary)
        }

        if model.library.isEmpty {
          TVEmptyState(
            title: "Your list is empty",
            message:
              "Open a title and choose Add to My List. Each viewing profile keeps its own private list.",
            systemImage: "bookmark"
          )
        } else {
          LazyVGrid(columns: columns, alignment: .leading, spacing: 44) {
            ForEach(model.library) { item in
              TVMediaLink(item: item)
            }
          }
          .focusSection()
        }
      }
      .padding(.horizontal, TVTheme.horizontalInset)
      .padding(.top, 125)
      .padding(.bottom, 90)
    }
    .background(TVTheme.background)
    .accessibilityIdentifier("tvos-library")
  }

  private var activeProfileSubtitle: String {
    if let profile = model.activeViewingProfile {
      return "Saved for \(profile.name)"
    }
    return "Saved titles"
  }
}
