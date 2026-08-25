import XCTest

@MainActor
final class StremioSkeletonPlayerUITests: XCTestCase {
    private let fixtureBaseURL = "http://127.0.0.1:18766"

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func testPinchChangesViewportWithoutRevealingControls() throws {
        let app = launchApp(
            environment: [
                "SKELETON_PLAYER_FIXTURE_URL": "\(fixtureBaseURL)/sample-autoplay.mp4",
                "SKELETON_PLAYER_FIXTURE_MANUAL_START": "1",
            ]
        )
        startFixturePlayback(in: app)

        let hiddenControlSurface = app.otherElements["player-show-controls"]
        XCTAssertTrue(hiddenControlSurface.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["player-close"].exists)

        hiddenControlSurface.pinch(withScale: 2.0, velocity: 1.5)

        XCTAssertFalse(
            app.staticTexts["Filled screen"].waitForExistence(timeout: 0.5),
            "Pinching to fill must not show a viewport pop-up"
        )
        XCTAssertTrue(
            hiddenControlSurface.waitForExistence(timeout: 2),
            "Pinching the video must not reveal the full player controls"
        )
        XCTAssertFalse(app.buttons["player-close"].exists)
        attachScreenshot(named: "mobile-pinch-fill-controls-hidden")

        hiddenControlSurface.pinch(withScale: 0.5, velocity: -1.5)
        XCTAssertFalse(
            app.staticTexts["Fit to screen"].waitForExistence(timeout: 0.5),
            "Pinching back to fit must not show a viewport pop-up"
        )
        XCTAssertTrue(
            hiddenControlSurface.waitForExistence(timeout: 2),
            "Pinching back to fit must keep the full player controls hidden"
        )
        XCTAssertFalse(app.buttons["player-close"].exists)
        attachScreenshot(named: "mobile-pinch-fit-controls-hidden")
    }

    func testAutomaticNextEpisodePreservesLandscapeOrientation() throws {
        // Keep the simulated hardware in the same direction as the explicit
        // player rotation request, just as a viewer would hold the phone.
        XCUIDevice.shared.orientation = .landscapeRight
        let app = launchApp(
            environment: [
                "SKELETON_EPISODE_AUTOPLAY_FIXTURE_URL": "\(fixtureBaseURL)/sample-autoplay.mp4",
                "SKELETON_EPISODE_AUTOPLAY_FIXTURE_MANUAL_START": "1",
                "SKELETON_EPISODE_AUTOPLAY_REUSE_FIXTURE_STREAM": "1",
                "SKELETON_PLAYER_CONTROLS_LOCKED": "1",
                "SKELETON_PLAYER_FIXTURE_LANDSCAPE": "1",
                "SKELETON_ADDON_URL": "\(fixtureBaseURL)/ui-states/cinemeta/manifest.json",
                "SKELETON_API_URL": fixtureBaseURL,
            ]
        )
        startFixturePlayback(in: app)

        // The fixture intentionally enters the player from the portrait-only
        // launcher. Let that one initial scene rotation finish before querying
        // accessibility; the handoff loop below still samples continuously.
        RunLoop.current.run(until: Date().addingTimeInterval(5))

        let firstEpisode = app.otherElements[
            "player-screen-series:tt-fixture-series:episode:tt-fixture-series:1:1"
        ]
        XCTAssertTrue(firstEpisode.waitForExistence(timeout: 20))

        XCTAssertTrue(waitForLandscape(app: app, timeout: 8))
        attachScreenshot(named: "mobile-autoplay-episode-one-landscape")

        let secondEpisode = app.otherElements[
            "player-screen-series:tt-fixture-series:episode:tt-fixture-series:1:2"
        ]
        let handoffDeadline = Date().addingTimeInterval(45)
        var reachedSecondEpisode = false
        while Date() < handoffDeadline {
            XCTAssertTrue(
                app.frame.width > app.frame.height,
                "Automatic episode advance must never flash back to portrait"
            )
            if secondEpisode.exists {
                reachedSecondEpisode = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }
        XCTAssertTrue(reachedSecondEpisode, "The fixture should automatically advance to episode two")
        XCTAssertTrue(
            waitForLandscape(app: app, timeout: 5),
            "Automatic episode advance must preserve the landscape player geometry"
        )
        attachScreenshot(named: "mobile-autoplay-episode-two-landscape")
    }

    func testSkipIntroUsesValidatedStreamBoundary() throws {
        let app = launchApp(
            environment: [
                "SKELETON_EPISODE_AUTOPLAY_FIXTURE_URL": "\(fixtureBaseURL)/sample-autoplay.mp4",
                "SKELETON_EPISODE_AUTOPLAY_FIXTURE_MANUAL_START": "1",
                "SKELETON_ADDON_URL": "\(fixtureBaseURL)/ui-states/cinemeta/manifest.json",
                "SKELETON_API_URL": fixtureBaseURL,
            ]
        )
        startFixturePlayback(in: app)

        let skipIntro = app.buttons["player-skip-intro"]
        XCTAssertTrue(skipIntro.waitForExistence(timeout: 20))
        skipIntro.tap()
        XCTAssertTrue(skipIntro.waitForNonExistence(timeout: 4))
        attachScreenshot(named: "mobile-skip-intro-completed")
    }

    @discardableResult
    private func launchApp(environment: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = environment.merging([
            "SKELETON_INTERNAL_PLAYER": "bunny",
            "SKELETON_PLAYER_CONTROLS_LOCKED": "0",
        ]) { requested, _ in requested }
        app.launchArguments = [
            "-watchTogetherEnabled", "false",
            "-playerDebugOverlayEnabled", "false",
        ]
        app.launch()
        return app
    }

    private func waitForLandscape(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { _, _ in
            app.frame.width > app.frame.height
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func startFixturePlayback(in app: XCUIApplication) {
        let startButton = app.buttons["start-player-fixture"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 30))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND hittable == true"),
            object: startButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        startButton.tap()
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
