import Foundation

struct PlaybackLanguageOption: Equatable, Sendable {
    let languageTag: String?
    let displayName: String
}

enum PlaybackLanguageMatcher {
    static let englishIdentifier = "en"

    private static let aliases: [String: String] = [
        "en": "en", "eng": "en", "english": "en",
        "es": "es", "spa": "es", "spanish": "es",
        "fr": "fr", "fra": "fr", "fre": "fr", "french": "fr",
        "de": "de", "deu": "de", "ger": "de", "german": "de",
        "it": "it", "ita": "it", "italian": "it",
        "pt": "pt", "por": "pt", "portuguese": "pt",
        "ja": "ja", "jpn": "ja", "japanese": "ja",
        "ko": "ko", "kor": "ko", "korean": "ko",
        "zh": "zh", "zho": "zh", "chi": "zh", "chinese": "zh",
        "ru": "ru", "rus": "ru", "russian": "ru",
        "ar": "ar", "ara": "ar", "arabic": "ar",
        "hi": "hi", "hin": "hi", "hindi": "hi",
    ]

    static func normalizedIdentifier(
        languageTag: String?,
        displayName: String? = nil
    ) -> String? {
        if let languageTag,
           let normalized = normalizedCandidate(languageTag, allowsWords: false) {
            return normalized
        }
        if let displayName {
            return normalizedCandidate(displayName, allowsWords: true)
        }
        return nil
    }

    static func bestMatchIndex(
        in options: [PlaybackLanguageOption],
        preferredLanguage: String
    ) -> Int? {
        guard let preferred = normalizedIdentifier(languageTag: preferredLanguage) else {
            return nil
        }

        return options.enumerated()
            .compactMap { index, option -> (index: Int, score: Int)? in
                if normalizedIdentifier(languageTag: option.languageTag) == preferred {
                    return (index, 0)
                }
                if normalizedIdentifier(
                    languageTag: nil,
                    displayName: option.displayName
                ) == preferred {
                    return (index, 1)
                }
                return nil
            }
            .min { lhs, rhs in
                lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score < rhs.score
            }?
            .index
    }

    private static func normalizedCandidate(
        _ value: String,
        allowsWords: Bool
    ) -> String? {
        let lowercase = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !lowercase.isEmpty else { return nil }

        let tokens = lowercase.components(
            separatedBy: CharacterSet.alphanumerics.inverted
        ).filter { !$0.isEmpty }
        for token in tokens {
            if let alias = aliases[token] { return alias }
        }

        guard !allowsWords else { return nil }
        let primary = lowercase
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init)
        guard let primary, (2...3).contains(primary.count) else { return nil }
        return aliases[primary] ?? primary
    }
}

enum PlaybackLanguagePreferences {
    static let preferredAudioLanguageKey = "preferredAudioLanguage"
    static let preferredSubtitleLanguageKey = "preferredSubtitleLanguage"
    static let subtitlesEnabledKey = "preferredSubtitlesEnabled"
    static let defaultLanguage = PlaybackLanguageMatcher.englishIdentifier

    static func preferredAudioLanguage(
        defaults: UserDefaults = .standard
    ) -> String {
        defaults.string(forKey: preferredAudioLanguageKey) ?? defaultLanguage
    }

    static func preferredSubtitleLanguage(
        defaults: UserDefaults = .standard
    ) -> String {
        defaults.string(forKey: preferredSubtitleLanguageKey) ?? defaultLanguage
    }

    static func subtitlesEnabled(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.object(forKey: subtitlesEnabledKey) == nil
            ? true
            : defaults.bool(forKey: subtitlesEnabledKey)
    }

    static func rememberAudioSelection(
        languageTag: String?,
        displayName: String,
        defaults: UserDefaults = .standard
    ) {
        guard let language = PlaybackLanguageMatcher.normalizedIdentifier(
            languageTag: languageTag,
            displayName: displayName
        ) else { return }
        defaults.set(language, forKey: preferredAudioLanguageKey)
    }

    static func rememberSubtitleSelection(
        languageTag: String?,
        displayName: String,
        defaults: UserDefaults = .standard
    ) {
        if let language = PlaybackLanguageMatcher.normalizedIdentifier(
            languageTag: languageTag,
            displayName: displayName
        ) {
            defaults.set(language, forKey: preferredSubtitleLanguageKey)
        }
        defaults.set(true, forKey: subtitlesEnabledKey)
    }

    static func rememberSubtitlesDisabled(
        defaults: UserDefaults = .standard
    ) {
        defaults.set(false, forKey: subtitlesEnabledKey)
    }
}

enum StreamFailoverPolicy {
    static let countdownSeconds = 3

    static func nextSourceIndex(
        after currentIndex: Int,
        sourceCount: Int
    ) -> Int? {
        guard currentIndex >= 0, sourceCount > 0 else { return nil }
        let nextIndex = currentIndex + 1
        return nextIndex < sourceCount ? nextIndex : nil
    }

    static var countdownValues: [Int] {
        Array(stride(from: countdownSeconds, through: 1, by: -1))
    }
}
