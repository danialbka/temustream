import SwiftUI

enum TVTheme {
  static let accent = Color(red: 1.0, green: 0.47, blue: 0.12)
  static let background = Color(red: 0.025, green: 0.028, blue: 0.04)
  static let elevated = Color.white.opacity(0.09)
  static let subtle = Color.white.opacity(0.64)
  static let horizontalInset: CGFloat = 76
  static let shelfSpacing: CGFloat = 52
  static let posterWidth: CGFloat = 246
  static let posterHeight: CGFloat = 360
}

struct TVSectionTitle: View {
  let title: String
  let subtitle: String?

  init(_ title: String, subtitle: String? = nil) {
    self.title = title
    self.subtitle = subtitle
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.title2.weight(.bold))
      if let subtitle, !subtitle.isEmpty {
        Text(subtitle)
          .font(.callout)
          .foregroundStyle(TVTheme.subtle)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

struct TVEmptyState: View {
  let title: String
  let message: String
  let systemImage: String

  var body: some View {
    VStack(spacing: 24) {
      Image(systemName: systemImage)
        .font(.system(size: 72, weight: .light))
        .foregroundStyle(TVTheme.accent)
      Text(title)
        .font(.largeTitle.bold())
      Text(message)
        .font(.title3)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 760)
    }
    .frame(maxWidth: .infinity, minHeight: 520)
    .padding(60)
  }
}
