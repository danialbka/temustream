import Foundation
import XCTest
@testable import StremioSkeletonCore

final class AppPresentationPoliciesTests: XCTestCase {
    func testSignInCredentialsTrimEmailButPreserveOpaquePassword() throws {
        let credentials = try SignInFormCredentials(
            email: "  viewer@example.com\n",
            password: "  secret phrase  "
        )

        XCTAssertEqual(credentials.email, "viewer@example.com")
        XCTAssertEqual(credentials.password, "  secret phrase  ")
    }

    func testSignInCredentialsRejectWhitespaceAndMalformedEmailLocally() {
        XCTAssertEqual(
            SignInFormCredentials.validationError(email: "   \n", password: "secret"),
            "Enter your email address."
        )
        XCTAssertEqual(
            SignInFormCredentials.validationError(email: "not a url", password: "secret"),
            "Enter a valid email address."
        )
        XCTAssertEqual(
            SignInFormCredentials.validationError(email: "viewer@example.com", password: " \t "),
            "Enter your password."
        )
        XCTAssertFalse(SignInFormCredentials.canSubmit(email: "not-an-email", password: "secret"))
        for email in [
            "viewer<invalid>@example.com",
            "viewer,invalid@example.com",
            "viewer:invalid@example.com",
            "viewer;invalid@example.com",
            "viewer\\invalid@example.com",
            "viewer\"invalid@example.com",
        ] {
            XCTAssertFalse(
                SignInFormCredentials.canSubmit(email: email, password: "secret"),
                "Expected local rejection for \(email)"
            )
            XCTAssertEqual(
                SignInFormCredentials.validationError(email: email, password: "secret"),
                "Enter a valid email address."
            )
        }
        XCTAssertTrue(
            SignInFormCredentials.canSubmit(email: "viewer+tv@example.co.uk", password: "secret")
        )
        XCTAssertTrue(
            SignInFormCredentials.canSubmit(
                email: "first.last_o'hara+tag@example-domain.com",
                password: "secret"
            )
        )
    }

    func testAddonFeedbackKeepsManifestAndServerResultsSeparate() {
        var feedback = AddonFormFeedback()
        feedback.setManifestMessage("Manifest is invalid")
        feedback.setStreamingServerMessage("Streaming server URL is invalid")

        XCTAssertEqual(feedback.manifestMessage, "Manifest is invalid")
        XCTAssertEqual(feedback.streamingServerMessage, "Streaming server URL is invalid")

        feedback.setStreamingServerMessage("Server saved")
        XCTAssertEqual(feedback.manifestMessage, "Manifest is invalid")
        XCTAssertEqual(feedback.streamingServerMessage, "Server saved")
    }

    func testBundleMetadataUsesInjectedVersionAndBuildWithoutLiterals() {
        XCTAssertEqual(
            AppBundleMetadata(
                infoDictionary: [
                    "CFBundleShortVersionString": "2.4",
                    "CFBundleVersion": 91,
                ]
            ).versionLabel,
            "Version 2.4 (91)"
        )
        XCTAssertEqual(
            AppBundleMetadata(
                infoDictionary: ["CFBundleShortVersionString": "2.4"]
            ).versionLabel,
            "Version 2.4"
        )
        XCTAssertEqual(AppBundleMetadata(infoDictionary: [:]).versionLabel, "Version unavailable")
    }

    func testTVCompatibilityFallbackIncludesSniffedContainers() {
        XCTAssertTrue(
            TVPlaybackCompatibilityPolicy.requiresFallback(
                streamPrefersCompatibility: false,
                detectedMIMEType: "video/mp2t"
            )
        )
        XCTAssertTrue(
            TVPlaybackCompatibilityPolicy.requiresFallback(
                streamPrefersCompatibility: false,
                detectedMIMEType: "video/x-matroska"
            )
        )
        XCTAssertTrue(
            TVPlaybackCompatibilityPolicy.requiresFallback(
                streamPrefersCompatibility: false,
                detectedMIMEType: "VIDEO/WEBM"
            )
        )
        XCTAssertTrue(
            TVPlaybackCompatibilityPolicy.requiresFallback(
                streamPrefersCompatibility: true,
                detectedMIMEType: "video/mp4"
            )
        )
        XCTAssertFalse(
            TVPlaybackCompatibilityPolicy.requiresFallback(
                streamPrefersCompatibility: false,
                detectedMIMEType: "video/mp4"
            )
        )
    }

    func testPrimaryAddonIdentityUsesCanonicalURLRatherThanOrder() throws {
        let primary = try XCTUnwrap(
            AddonManifestIdentity(
                manifestURL: URL(string: "https://EXAMPLE.com:443/addon/manifest.json?token=abc")!
            )
        )
        let equivalent = try XCTUnwrap(
            AddonManifestIdentity(
                manifestURL: URL(string: "https://example.com/addon/manifest.json?token=abc")!
            )
        )
        let differentToken = try XCTUnwrap(
            AddonManifestIdentity(
                manifestURL: URL(string: "https://example.com/addon/manifest.json?token=def")!
            )
        )

        XCTAssertEqual(primary, equivalent)
        XCTAssertNotEqual(primary, differentToken)
        let reordered = [differentToken, equivalent]
        XCTAssertEqual(reordered.firstIndex(of: primary), 1)
    }

    func testTVResumeClampsToEachResolvedDuration() {
        XCTAssertEqual(TVPlaybackResumePolicy.clampedPosition(120, duration: 600), 120)
        XCTAssertEqual(TVPlaybackResumePolicy.clampedPosition(600, duration: 600), 599)
        XCTAssertEqual(TVPlaybackResumePolicy.clampedPosition(900, duration: 600), 599)
        XCTAssertEqual(TVPlaybackResumePolicy.clampedPosition(900, duration: 90), 89)
        XCTAssertEqual(TVPlaybackResumePolicy.clampedPosition(900, duration: .nan), 900)
        XCTAssertEqual(TVPlaybackResumePolicy.clampedPosition(.infinity, duration: 600), 0)
    }

    func testTVFailureResumeUsesLatestReadyPositionAndDoesNotRewind() {
        var monitor = TVPlaybackMonitorState(resumePosition: 45)
        XCTAssertEqual(
            monitor.observe(position: 45, duration: 300, isPlaying: true),
            [.ready]
        )
        XCTAssertEqual(
            monitor.observe(position: 132, duration: 300, isPlaying: true),
            [.checkpoint(position: 132, duration: 300)]
        )
        XCTAssertEqual(monitor.failureResumePosition(requestedPosition: 45), 132)

        XCTAssertEqual(
            TVPlaybackResumePolicy.failureResumePosition(
                requestedPosition: 45,
                latestObservedPosition: 132,
                attemptDidBecomeReady: true,
                duration: 300
            ),
            132
        )
        XCTAssertEqual(
            TVPlaybackResumePolicy.failureResumePosition(
                requestedPosition: 45,
                latestObservedPosition: 0,
                attemptDidBecomeReady: false,
                duration: 30
            ),
            29
        )
    }

    func testTVMonitorCannotFinalizeBeforeReadiness() {
        var monitor = TVPlaybackMonitorState(resumePosition: 599)

        XCTAssertEqual(
            monitor.observe(position: 600, duration: 600, isPlaying: false),
            []
        )
        XCTAssertFalse(monitor.didBecomeReady)
        XCTAssertFalse(monitor.didReportFinal)
    }

    func testTVMonitorSurvivesEOFAndResumesCheckpointsAfterReplay() {
        var monitor = TVPlaybackMonitorState(resumePosition: 0)

        XCTAssertEqual(
            monitor.observe(position: 0, duration: 120, isPlaying: true),
            [.ready]
        )
        XCTAssertEqual(
            monitor.observe(position: 119.5, duration: 120, isPlaying: true),
            [.final(position: 119.5, duration: 120)]
        )
        XCTAssertEqual(
            monitor.observe(position: 120, duration: 120, isPlaying: false),
            []
        )
        XCTAssertTrue(monitor.didReportFinal)

        XCTAssertEqual(
            monitor.observe(position: 0, duration: 120, isPlaying: true),
            [.replayBegan]
        )
        XCTAssertFalse(monitor.didReportFinal)
        XCTAssertEqual(
            monitor.observe(position: 16, duration: 120, isPlaying: true),
            [.checkpoint(position: 16, duration: 120)]
        )
        XCTAssertEqual(
            monitor.observe(position: 119.5, duration: 120, isPlaying: true),
            [.final(position: 119.5, duration: 120)]
        )
    }
}
