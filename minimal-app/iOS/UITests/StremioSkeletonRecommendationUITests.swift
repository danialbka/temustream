import XCTest

@MainActor
final class StremioSkeletonRecommendationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testForYouShelfLoadsSuccessiveRecommendationWindows() throws {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "SKELETON_RECOMMENDATION_PAGING_FIXTURE": "1",
        ]
        app.launchArguments = [
            "-watchTogetherEnabled", "false",
        ]
        app.launch()

        let shelf = app.otherElements["home-shelf-for-you"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 15))
        XCTAssertTrue(
            app.descendants(matching: .any)["home-shelf-for-you-item-0"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["home-shelf-for-you-item-12"].exists,
            "Only the first recommendation window should be published initially"
        )
        attachScreenshot(named: "recommendations-infinite-scroll-initial")

        XCTAssertTrue(
            swipe(
                shelf,
                untilExists: "home-shelf-for-you-item-12",
                in: app,
                maximumAttempts: 10
            ),
            "Reaching the end of the first window should append recommendation 13"
        )
        shelf.swipeLeft()
        attachScreenshot(named: "recommendations-infinite-scroll-page-two")

        XCTAssertTrue(
            swipe(
                shelf,
                untilExists: "home-shelf-for-you-item-24",
                in: app,
                maximumAttempts: 12
            ),
            "The recommendation shelf should continue into a third window"
        )
        shelf.swipeLeft()
        attachScreenshot(named: "recommendations-infinite-scroll-page-three")
    }

    func testContinueWatchingLongPressOpensSeriesAndMovieDetails() throws {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "SKELETON_CONTINUE_WATCHING_NAVIGATION_FIXTURE": "1",
        ]
        app.launchArguments = [
            "-watchTogetherEnabled", "false",
        ]
        app.launch()

        let seriesCard = app.descendants(matching: .any)[
            "continue-watching-series:tt-continue-series:episode:tt-continue-series:1:2"
        ]
        XCTAssertTrue(seriesCard.waitForExistence(timeout: 15))
        seriesCard.press(forDuration: 0.7)

        XCTAssertTrue(app.navigationBars["Continue Series"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons["resume-series"].waitForExistence(timeout: 5),
            "A series long press should open its listing instead of resuming playback"
        )
        attachScreenshot(named: "continue-watching-series-long-press-details")

        app.navigationBars["Continue Series"].buttons.element(boundBy: 0).tap()

        let movieCard = app.descendants(matching: .any)[
            "continue-watching-movie:tt-continue-movie"
        ]
        XCTAssertTrue(movieCard.waitForExistence(timeout: 5))
        movieCard.press(forDuration: 0.7)

        XCTAssertTrue(app.navigationBars["Continue Movie"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons["resume-playback"].waitForExistence(timeout: 5),
            "A movie long press should open its listing instead of resuming playback"
        )
        attachScreenshot(named: "continue-watching-movie-long-press-details")
    }

    private func swipe(
        _ shelf: XCUIElement,
        untilExists identifier: String,
        in app: XCUIApplication,
        maximumAttempts: Int
    ) -> Bool {
        let target = app.descendants(matching: .any)[identifier]
        for _ in 0..<maximumAttempts {
            if target.exists { return true }
            shelf.swipeLeft()
        }
        return target.waitForExistence(timeout: 3)
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
