import XCTest

@MainActor
final class StremioSkeletonPlayerUITests: XCTestCase {
    private let fixtureBaseURL = "http://127.0.0.1:18766"
    private let interruptedRangeFixtureBaseURL = "http://127.0.0.1:18767"
    private let stressFixtureDuration: CGFloat = 60

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
        let actionable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND hittable == true"),
            object: skipIntro
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [actionable], timeout: 4),
            .completed,
            "Skip Intro should become actionable before accepting a tap"
        )
        skipIntro.tap()
        XCTAssertTrue(skipIntro.waitForNonExistence(timeout: 4))
        attachScreenshot(named: "mobile-skip-intro-completed")
    }

    func testInterruptedRangeSeekRecoversWithoutTimeoutUI() throws {
        let app = launchApp(
            environment: [
                "SKELETON_PLAYER_FIXTURE_URL":
                    "\(interruptedRangeFixtureBaseURL)/stress-subtitles.mkv",
                "SKELETON_PLAYER_FIXTURE_MANUAL_START": "1",
                "SKELETON_PLAYER_CONTROLS_LOCKED": "1",
                "SKELETON_PLAYER_DEBUG_OVERLAY": "1",
            ]
        )
        startFixturePlayback(in: app)

        XCTAssertTrue(
            waitForDebugState("Playing", in: app, timeout: 20),
            "The custom player should render before the interrupted-read seek"
        )
        let timeline = app.descendants(matching: .any)["player-timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        let timelineValueBeforeSeek = String(describing: timeline.value)
        let forward = app.buttons["Forward 15 seconds"]
        XCTAssertTrue(forward.waitForExistence(timeout: 5))

        // The test server leaves the decoder's next range request open. A seek
        // must cancel that obsolete request and immediately read the target.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        forward.tap()

        let deadline = Date().addingTimeInterval(7)
        var recovered = false
        var sawTimeoutToast = false
        while Date() < deadline {
            sawTimeoutToast = sawTimeoutToast
                || app.descendants(matching: .any)["bunny-player-toast"].exists
            XCTAssertFalse(app.otherElements["player-error"].exists)
            let timelineAdvanced = String(describing: timeline.value)
                != timelineValueBeforeSeek
            if timelineAdvanced,
               waitForDebugState("Playing", in: app, timeout: 0.15) {
                recovered = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        }

        XCTAssertTrue(recovered, "Playback should resume after superseding the stalled read")
        XCTAssertFalse(
            sawTimeoutToast,
            "A slow seek must stay on the active stream without timeout UI"
        )
        XCTAssertEqual(app.state, .runningForeground)
        attachScreenshot(named: "mobile-interrupted-range-seek-recovered")
    }

    func testDebugOverlayReportsDecodedDynamicRange() throws {
        let app = launchApp(
            environment: [
                "SKELETON_PLAYER_FIXTURE_URL":
                    "\(fixtureBaseURL)/sample-autoplay.mkv",
                "SKELETON_PLAYER_FIXTURE_MANUAL_START": "1",
                "SKELETON_PLAYER_CONTROLS_LOCKED": "1",
                "SKELETON_PLAYER_DEBUG_OVERLAY": "1",
            ]
        )
        startFixturePlayback(in: app)

        XCTAssertTrue(waitForDebugState("Playing", in: app, timeout: 20))
        let dynamicRange = app.descendants(matching: .any)[
            "player-debug-dynamic-range"
        ]
        XCTAssertTrue(dynamicRange.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["SDR"].waitForExistence(timeout: 5),
            "The debug overlay should classify the decoded SDR fixture"
        )
        attachScreenshot(named: "mobile-debug-dynamic-range-sdr")
    }

    func testUserStylePlayerInteractionStressRemainsResponsive() throws {
        let app = launchApp(
            environment: [
                "SKELETON_PLAYER_FIXTURE_URL": "\(fixtureBaseURL)/stress-subtitles.mkv",
                "SKELETON_PLAYER_FIXTURE_MANUAL_START": "1",
                "SKELETON_PLAYER_CONTROLS_LOCKED": "1",
                "SKELETON_PLAYER_DEBUG_OVERLAY": "1",
            ]
        )
        startFixturePlayback(in: app)
        XCTAssertTrue(waitForDebugState("Playing", in: app, timeout: 20))

        let timeline = app.descendants(matching: .any)["player-timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        for position in [0.72, 0.18, 0.88, 0.35] {
            // XCTest can spend several seconds resolving each coordinate. A
            // real finger follows the moving thumb continuously; pause first
            // so the synthetic coordinate cannot drift away before contact.
            app.buttons["Pause"].tap()
            XCTAssertTrue(waitForDebugState("Paused", in: app, timeout: 3))
            let startingPosition = normalizedSliderPosition(timeline) ?? 0.03
            let dragStart = timeline.coordinate(
                withNormalizedOffset: CGVector(dx: startingPosition, dy: 0.5)
            )
            let dragEnd = timeline.coordinate(
                withNormalizedOffset: CGVector(dx: position, dy: 0.5)
            )
            dragStart.press(
                forDuration: 0.15,
                thenDragTo: dragEnd,
                withVelocity: 200,
                thenHoldForDuration: 0.12
            )
            XCTAssertTrue(
                waitForSliderMovement(
                    timeline,
                    from: startingPosition,
                    toward: position,
                    timeout: 3
                ),
                "A real thumb drag should move the timeline in the intended direction; value=\(String(describing: timeline.value))"
            )
            XCTAssertTrue(waitForDebugState("Paused", in: app, timeout: 8))
            XCTAssertFalse(app.otherElements["player-error"].exists)
            app.buttons["Play"].tap()
            XCTAssertTrue(waitForDebugState("Playing", in: app, timeout: 5))
        }

        for _ in 0..<4 {
            app.buttons["Pause"].tap()
            XCTAssertTrue(waitForDebugState("Paused", in: app, timeout: 3))
            app.buttons["Play"].tap()
            XCTAssertTrue(waitForDebugState("Playing", in: app, timeout: 5))
        }

        for _ in 0..<6 {
            app.buttons["Forward 15 seconds"].tap()
            app.buttons["Back 15 seconds"].tap()
        }
        let rapidSeekDeadline = Date().addingTimeInterval(10)
        var sawSeekFailure = false
        while Date() < rapidSeekDeadline {
            sawSeekFailure = sawSeekFailure
                || app.descendants(matching: .any)["bunny-player-toast"].exists
            XCTAssertFalse(app.otherElements["player-error"].exists)
            if waitForDebugState("Playing", in: app, timeout: 0.15),
               !app.descendants(matching: .any)["player-seeking-indicator"].exists {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        }
        XCTAssertFalse(
            sawSeekFailure,
            "Superseded rapid taps must not be reported as failed seeks"
        )
        XCTAssertTrue(waitForDebugState("Playing", in: app, timeout: 1))
        XCTAssertFalse(
            app.descendants(matching: .any)["player-seeking-indicator"].exists,
            "The newest rapid seek should settle and own the final playback state"
        )

        app.buttons["player-content-mode"].tap()
        app.buttons["player-content-mode"].tap()
        app.buttons["Mute"].tap()
        app.buttons["Unmute"].tap()

        app.buttons["player-subtitles"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["bunny-subtitles-track-picker"]
                .waitForExistence(timeout: 3)
        )
        app.buttons["Off"].tap()
        app.buttons["player-audio-tracks"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["bunny-audio-track-picker"]
                .waitForExistence(timeout: 3)
        )
        app.buttons["Close audio"].tap()

        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.activate()
        XCTAssertTrue(waitForDebugState("Playing", in: app, timeout: 8))
        XCTAssertFalse(app.otherElements["player-error"].exists)
        XCTAssertEqual(app.state, .runningForeground)
        attachScreenshot(named: "mobile-user-style-player-stress-pass")
    }

    func testOptInLiveBunnyLargeFileScrubbing() throws {
        // Attach to the already authenticated, explicitly selected live
        // provider stream. Launching a fresh test app here would replace that
        // exact source with a deterministic fixture and defeat this audit.
        let app = XCUIApplication(bundleIdentifier: "local.bunny.player")
        guard app.state == .runningForeground || app.state == .runningBackground else {
            throw XCTSkip("Requires an already running live Bunny player session")
        }
        app.activate()

        let timeline = app.descendants(matching: .any)["player-timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        guard app.staticTexts["Memories.1995.4K.REMASTER.mkv"].waitForExistence(timeout: 5) else {
            throw XCTSkip("Requires the exact prepared 82.35 GB Memories source")
        }

        let initialPosition = normalizedSliderPosition(timeline) ?? 0
        let checkpoints = initialPosition > 0.5
            ? [0.08, 0.72, 0.25, 0.50]
            : [0.72, 0.08, 0.50, 0.25]
        for (index, position) in checkpoints.enumerated() {
            if app.buttons["Pause"].exists {
                app.buttons["Pause"].tap()
            }
            XCTAssertTrue(waitForDebugState("Paused", in: app, timeout: 5))

            let startingPosition = normalizedSliderPosition(timeline) ?? 0.01
            let dragStart = timeline.coordinate(
                withNormalizedOffset: CGVector(dx: startingPosition, dy: 0.5)
            )
            let dragEnd = timeline.coordinate(
                withNormalizedOffset: CGVector(dx: position, dy: 0.5)
            )
            dragStart.press(
                forDuration: 0.15,
                thenDragTo: dragEnd,
                withVelocity: 200,
                thenHoldForDuration: 0.12
            )

            let seekingIndicator = app.descendants(matching: .any)[
                "player-seeking-indicator"
            ]
            if seekingIndicator.waitForExistence(timeout: 1) {
                XCTAssertTrue(
                    seekingIndicator.waitForNonExistence(timeout: 30),
                    "Live seek \(index + 1) should finish loading its target"
                )
            }
            XCTAssertTrue(
                waitForSliderPosition(
                    timeline,
                    near: position,
                    tolerance: 0.08,
                    timeout: 3
                ),
                "Live seek \(index + 1) should settle near \(position); value=\(String(describing: timeline.value))"
            )
            XCTAssertFalse(app.otherElements["player-error"].exists)

            let settledSeconds = sliderElapsedSeconds(timeline)
            if app.buttons["Play"].exists {
                app.buttons["Play"].tap()
            }
            XCTAssertTrue(
                waitForLivePlaybackAdvance(
                    timeline,
                    fromSeconds: settledSeconds,
                    timeout: 30
                ),
                "The media clock should advance after live seek \(index + 1)"
            )
            XCTAssertTrue(app.buttons["Pause"].exists)
            XCTAssertFalse(app.otherElements["player-error"].exists)
        }

        attachScreenshot(named: "live-bunny-82gb-four-seek-pass")
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

    private func waitForDebugState(
        _ state: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let overlay = app.descendants(matching: .any)["player-debug-overlay"]
        guard overlay.waitForExistence(timeout: timeout) else { return false }
        if overlay.label.localizedCaseInsensitiveContains(state) {
            return true
        }
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", state)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: overlay)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func normalizedSliderPosition(_ slider: XCUIElement) -> CGFloat? {
        // `value` is not stable across slider implementations: the same live
        // SwiftUI slider exposes elapsed seconds through XCTest while its
        // accessibility value remains normalized. Ask XCUIAutomation for the
        // thumb position directly before falling back to older fixture logic.
        let normalizedPosition = slider.normalizedSliderPosition
        if normalizedPosition.isFinite,
           (0...1).contains(normalizedPosition) {
            return normalizedPosition
        }
        if let number = slider.value as? NSNumber {
            let value = CGFloat(truncating: number)
            return value > 1 ? value / stressFixtureDuration : value
        }
        guard let rawValue = slider.value as? String else { return nil }
        let usesPercent = rawValue.contains("%")
        let numericText = rawValue.filter { $0.isNumber || $0 == "." || $0 == "," }
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(numericText) else { return nil }
        if usesPercent {
            return CGFloat(value / 100)
        }
        return CGFloat(value > 1 ? value / Double(stressFixtureDuration) : value)
    }

    private func waitForSliderMovement(
        _ slider: XCUIElement,
        from start: CGFloat,
        toward target: CGFloat,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let direction: CGFloat = target >= start ? 1 : -1
        while Date() < deadline {
            if let actual = normalizedSliderPosition(slider),
               (actual - start) * direction >= 0.12 {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        }
        return false
    }

    private func waitForSliderPosition(
        _ slider: XCUIElement,
        near target: CGFloat,
        tolerance: CGFloat,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let actual = normalizedSliderPosition(slider),
               abs(actual - target) <= tolerance {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func waitForLivePlaybackAdvance(
        _ slider: XCUIElement,
        fromSeconds start: Double?,
        timeout: TimeInterval
    ) -> Bool {
        guard let start else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let actual = sliderElapsedSeconds(slider),
               actual >= start + 0.75 {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func sliderElapsedSeconds(_ slider: XCUIElement) -> Double? {
        if let number = slider.value as? NSNumber {
            let value = number.doubleValue
            return value > 1 ? value : nil
        }
        guard let rawValue = slider.value as? String,
              !rawValue.contains("%")
        else { return nil }
        let numericText = rawValue.filter { $0.isNumber || $0 == "." || $0 == "," }
            .replacingOccurrences(of: ",", with: "")
        guard let value = Double(numericText), value > 1 else { return nil }
        return value
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
        if !startButton.waitForNonExistence(timeout: 3), startButton.isHittable {
            startButton.tap()
        }
        XCTAssertTrue(
            startButton.waitForNonExistence(timeout: 5),
            "The simulator fixture should leave its start gate after tapping"
        )
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
