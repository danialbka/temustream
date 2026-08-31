import Foundation

public enum SignInFormValidationError: LocalizedError, Equatable, Sendable {
    case missingEmail
    case invalidEmail
    case missingPassword

    public var errorDescription: String? {
        switch self {
        case .missingEmail:
            "Enter your email address."
        case .invalidEmail:
            "Enter a valid email address."
        case .missingPassword:
            "Enter your password."
        }
    }
}

public struct SignInFormCredentials: Equatable, Sendable {
    private static let unquotedLocalPartCharacters = CharacterSet(
        charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-/=?^_`{|}~."
    )

    public let email: String
    public let password: String

    public init(email: String, password: String) throws {
        let canonicalEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonicalEmail.isEmpty else { throw SignInFormValidationError.missingEmail }
        guard Self.isValidEmail(canonicalEmail) else {
            throw SignInFormValidationError.invalidEmail
        }
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SignInFormValidationError.missingPassword
        }
        self.email = canonicalEmail
        // Passwords are opaque credentials. Whitespace is used only to reject
        // an effectively empty field; submitted bytes must otherwise remain
        // exactly as the user entered them.
        self.password = password
    }

    public static func validationError(email: String, password: String) -> String? {
        do {
            _ = try Self(email: email, password: password)
            return nil
        } catch let error as SignInFormValidationError {
            return error.localizedDescription
        } catch {
            return "Check your email and password."
        }
    }

    public static func canSubmit(email: String, password: String) -> Bool {
        validationError(email: email, password: password) == nil
    }

    private static func isValidEmail(_ value: String) -> Bool {
        guard value.utf8.count <= 254,
              !value.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains)
        else { return false }

        let components = value.split(separator: "@", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        let local = components[0]
        let domain = components[1]
        guard !local.isEmpty,
              local.utf8.count <= 64,
              local.first != ".",
              local.last != ".",
              !local.contains(".."),
              local.unicodeScalars.allSatisfy(unquotedLocalPartCharacters.contains)
        else { return false }

        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty,
                  label.utf8.count <= 63,
                  label.first != "-",
                  label.last != "-"
            else { return false }
            return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
}

public struct AddonFormFeedback: Equatable, Sendable {
    public private(set) var manifestMessage: String?
    public private(set) var streamingServerMessage: String?

    public init(manifestMessage: String? = nil, streamingServerMessage: String? = nil) {
        self.manifestMessage = manifestMessage
        self.streamingServerMessage = streamingServerMessage
    }

    public mutating func setManifestMessage(_ message: String?) {
        manifestMessage = message
    }

    public mutating func setStreamingServerMessage(_ message: String?) {
        streamingServerMessage = message
    }
}

public struct AppBundleMetadata: Equatable, Sendable {
    public let shortVersion: String?
    public let build: String?

    public init(infoDictionary: [String: Any]) {
        shortVersion = Self.nonemptyString(infoDictionary["CFBundleShortVersionString"])
        build = Self.nonemptyString(infoDictionary["CFBundleVersion"])
    }

    public init(bundle: Bundle = .main) {
        self.init(infoDictionary: bundle.infoDictionary ?? [:])
    }

    public var versionLabel: String {
        switch (shortVersion, build) {
        case let (.some(version), .some(build)):
            "Version \(version) (\(build))"
        case let (.some(version), .none):
            "Version \(version)"
        case let (.none, .some(build)):
            "Build \(build)"
        case (.none, .none):
            "Version unavailable"
        }
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value else { return nil }
        let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

public enum TVPlaybackCompatibilityPolicy {
    public static func requiresFallback(
        streamPrefersCompatibility: Bool,
        detectedMIMEType: String?
    ) -> Bool {
        if streamPrefersCompatibility { return true }
        switch detectedMIMEType?.lowercased() {
        case "video/mp2t", "video/x-matroska", "video/webm":
            return true
        default:
            return false
        }
    }
}

public struct AddonManifestIdentity: Hashable, Sendable {
    private let scheme: String
    private let host: String
    private let port: Int?
    private let percentEncodedPath: String
    private let percentEncodedQuery: String?

    public init?(manifestURL: URL) {
        guard let endpoint = try? AddonEndpoint(manifestURL: manifestURL),
              let components = URLComponents(
                url: endpoint.manifestURL,
                resolvingAgainstBaseURL: false
              ),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased()
        else { return nil }

        self.scheme = scheme
        self.host = host
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80)
        {
            port = nil
        } else {
            port = components.port
        }
        percentEncodedPath = components.percentEncodedPath
        percentEncodedQuery = components.percentEncodedQuery
    }
}

public enum TVPlaybackResumePolicy {
    public static let completionTolerance: TimeInterval = 0.75
    public static let resumeEndMargin: TimeInterval = 1

    public static func clampedPosition(
        _ requestedPosition: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        let requested = finiteNonnegative(requestedPosition) ?? 0
        guard let duration = finitePositive(duration) else { return requested }
        return min(requested, max(duration - min(resumeEndMargin, duration), 0))
    }

    public static func failureResumePosition(
        requestedPosition: TimeInterval,
        latestObservedPosition: TimeInterval,
        attemptDidBecomeReady: Bool,
        duration: TimeInterval
    ) -> TimeInterval {
        let preferred = attemptDidBecomeReady
            ? finiteNonnegative(latestObservedPosition) ?? requestedPosition
            : requestedPosition
        return clampedPosition(preferred, duration: duration)
    }

    public static func shouldFinalize(
        position: TimeInterval,
        duration: TimeInterval,
        attemptDidBecomeReady: Bool
    ) -> Bool {
        guard attemptDidBecomeReady,
              let position = finiteNonnegative(position),
              let duration = finitePositive(duration)
        else { return false }
        return position >= max(duration - completionTolerance, 0)
    }

    public static func isMeaningfulReplay(
        position: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool
    ) -> Bool {
        guard isPlaying, let position = finiteNonnegative(position) else { return false }
        guard let duration = finitePositive(duration) else { return position <= 0.25 }
        return position <= 0.25 || position < max(duration - (completionTolerance * 2), 0)
    }

    fileprivate static func finiteNonnegative(_ value: TimeInterval) -> TimeInterval? {
        value.isFinite ? max(value, 0) : nil
    }

    fileprivate static func finitePositive(_ value: TimeInterval) -> TimeInterval? {
        value.isFinite && value > 0 ? value : nil
    }
}

public enum TVPlaybackMonitorEvent: Equatable, Sendable {
    case ready
    case replayBegan
    case checkpoint(position: TimeInterval, duration: TimeInterval)
    case final(position: TimeInterval, duration: TimeInterval)
}

public struct TVPlaybackMonitorState: Equatable, Sendable {
    public private(set) var didBecomeReady = false
    public private(set) var didReportFinal = false
    public private(set) var latestPosition: TimeInterval
    public private(set) var latestDuration: TimeInterval = 0

    private let resumePosition: TimeInterval
    private var lastCheckpointPosition: TimeInterval

    public init(resumePosition: TimeInterval) {
        let sanitized = TVPlaybackResumePolicy.clampedPosition(
            resumePosition,
            duration: 0
        )
        self.resumePosition = sanitized
        latestPosition = sanitized
        lastCheckpointPosition = sanitized
    }

    public mutating func observe(
        position rawPosition: TimeInterval,
        duration rawDuration: TimeInterval,
        isPlaying: Bool
    ) -> [TVPlaybackMonitorEvent] {
        let position = TVPlaybackResumePolicy.finiteNonnegative(rawPosition) ?? latestPosition
        let duration = TVPlaybackResumePolicy.finitePositive(rawDuration) ?? latestDuration

        if didReportFinal {
            guard TVPlaybackResumePolicy.isMeaningfulReplay(
                position: position,
                duration: duration,
                isPlaying: isPlaying
            ) else { return [] }
            didReportFinal = false
            latestPosition = position
            latestDuration = duration
            lastCheckpointPosition = position
            return [.replayBegan]
        }

        var events: [TVPlaybackMonitorEvent] = []
        if !didBecomeReady,
           isPlaying,
           position >= max(resumePosition - 1, 0)
        {
            didBecomeReady = true
            events.append(.ready)
        }

        if didBecomeReady {
            if isPlaying || position > 0 || latestPosition == 0 {
                latestPosition = position
            }
            if duration > 0 { latestDuration = duration }

            if TVPlaybackResumePolicy.shouldFinalize(
                position: position,
                duration: duration,
                attemptDidBecomeReady: true
            ) {
                didReportFinal = true
                events.append(.final(position: position, duration: duration))
                return events
            }

            if isPlaying, position + 1 < lastCheckpointPosition {
                lastCheckpointPosition = position
            }
            if position >= PlaybackProgress.minimumResumePosition,
               position - lastCheckpointPosition >= 15
            {
                lastCheckpointPosition = position
                events.append(.checkpoint(position: position, duration: duration))
            }
        }
        return events
    }

    public func failureResumePosition(requestedPosition: TimeInterval) -> TimeInterval {
        TVPlaybackResumePolicy.failureResumePosition(
            requestedPosition: requestedPosition,
            latestObservedPosition: latestPosition,
            attemptDidBecomeReady: didBecomeReady,
            duration: latestDuration
        )
    }
}
