import XCTest

@MainActor
final class TemuStreamTVUITests: XCTestCase {
  private let app = XCUIApplication()
  private let remote = XCUIRemote.shared

  override func setUp() async throws {
    continueAfterFailure = false
    app.launchEnvironment = [
      "SKELETON_ADDON_URL": "https://v3-cinemeta.strem.io/manifest.json",
      "SKELETON_LETTERBOXD_ADDON_URL": "https://api.stremboxd.com/manifest.json",
      "SKELETON_CINEMETA_CATALOG_ID": "top",
      "SKELETON_LETTERBOXD_CATALOG_ID": "letterboxd-popular",
      "SKELETON_SELECTED_TAB": "home",
    ]
    app.launch()
  }

  func testPrimaryTVScreensAndRemoteFocus() throws {
    XCTAssertTrue(element("tvos-home").waitForExistence(timeout: 30))
    let firstCard = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'tv-media-'")
    ).firstMatch
    XCTAssertTrue(firstCard.waitForExistence(timeout: 30))
    closeSidebarIfNeeded()
    snapshot("01-home")

    let heroAction = app.buttons["View Details"]
    XCTAssertTrue(heroAction.waitForExistence(timeout: 5))
    focus(heroAction, moving: .down, attempts: 5)
    XCTAssertTrue(heroAction.hasFocus, "Remote focus never reached the hero action")
    snapshot("02-home-hero-focused")

    focus(firstCard, moving: .down, attempts: 3)
    XCTAssertTrue(firstCard.hasFocus, "Remote focus never reached the first shelf card")
    snapshot("03-home-card-focused")

    remote.press(.select)
    XCTAssertTrue(element("tvos-details").waitForExistence(timeout: 20))
    snapshot("04-details")

    remote.press(.menu)
    XCTAssertTrue(element("tvos-home").waitForExistence(timeout: 10))

    launchTab("search", identifier: "tvos-search")
    snapshot("05-search")

    launchTab("library", identifier: "tvos-library")
    snapshot("06-my-list")

    launchTab("addons", identifier: "tvos-addons")
    snapshot("07-addons")

    launchTab("settings", identifier: "tvos-settings")
    snapshot("08-settings")
  }

  private func closeSidebarIfNeeded() {
    let home = app.buttons["Home"]
    if home.exists, home.hasFocus {
      remote.press(.select)
      Thread.sleep(forTimeInterval: 0.6)
    }
  }

  private func focus(
    _ element: XCUIElement,
    moving direction: XCUIRemote.Button,
    attempts: Int
  ) {
    for _ in 0..<attempts where !element.hasFocus {
      remote.press(direction)
    }
  }

  private func launchTab(_ tab: String, identifier: String) {
    app.terminate()
    var environment = app.launchEnvironment
    environment["SKELETON_SELECTED_TAB"] = tab
    app.launchEnvironment = environment
    app.launch()
    XCTAssertTrue(element(identifier).waitForExistence(timeout: 10))
    let tabButton = app.buttons[
      [
        "search": "Search",
        "library": "My List",
        "addons": "Add-ons",
        "settings": "Settings",
      ][tab] ?? tab
    ]
    XCTAssertTrue(tabButton.hasFocus, "Cold-launched \(tab) tab did not receive sidebar focus")
    remote.press(.select)
    Thread.sleep(forTimeInterval: 0.6)
    if tab == "search" {
      remote.press(.down)
      Thread.sleep(forTimeInterval: 0.4)
    }
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func snapshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
