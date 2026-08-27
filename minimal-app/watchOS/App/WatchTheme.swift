import SwiftUI

enum WatchAccentPreset: String, CaseIterable, Identifiable {
    case orange
    case blue
    case mint
    case pink

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .orange: .orange
        case .blue: .blue
        case .mint: .mint
        case .pink: .pink
        }
    }
}

enum WatchTheme {
    static let accent = Color.orange
    static let playable = Color.green
    static let unavailable = Color.secondary
}

struct WatchStatusPill: View {
    let symbol: String
    let text: String
    var color: Color = WatchTheme.accent

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.16), in: Capsule())
    }
}
