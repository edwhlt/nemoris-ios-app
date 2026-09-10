//
//  NemorisUITests.swift
//  NemorisUITests
//
//  Created by Edwin Helet on 8/14/26.
//

import XCTest

final class NemorisUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    /// Whether `openMoreItem` has already switched into the "Plus"/"More" tab once
    /// this test run. Used to skip the pop-to-root dance on the FIRST entry, where
    /// there's nothing pushed yet and the current tab (Dashboard/Transactions/…)
    /// might have its OWN unrelated leading nav-bar button (e.g. Patrimoine's "+"),
    /// which `popToMoreRoot` must never touch.
    private var hasEnteredMoreTab = false

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    // MARK: - Marketing screenshots (App Store)
    //
    // Language and theme are driven by the app's OWN `AppState.preferredLanguage`
    // / `AppState.colorSchemeRaw` overrides (see NemorisApp.init's `-nemorisLangEN`
    // / `-nemorisThemeDark` handling), NOT by `-AppleLanguages` or
    // `simctl ui appearance` — `xcodebuild test` runs against a CLONED simulator
    // that doesn't reliably inherit either of those.

    private func launchApp(language: String, theme: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-nemorisScreenshotMode",
            language == "fr" ? "-nemorisLangFR" : "-nemorisLangEN",
            theme == "dark" ? "-nemorisThemeDark" : "-nemorisThemeLight",
            // `AppState.preferredLanguage` (via `.environment(\.locale, …)`) only
            // affects date/number formatting, NOT which `.lproj` string table a
            // `Text("French literal key")` resolves against — that's governed by
            // `Bundle.main.preferredLocalizations`, driven by the actual UI
            // language below. Both are needed together.
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", language == "fr" ? "fr_FR" : "en_US",
        ]
        app.launch()
        return app
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tapTabBarButton(_ index: Int, app: XCUIApplication) {
        let bar = app.tabBars.firstMatch
        let button = bar.buttons.element(boundBy: index)
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
    }

    /// Re-tapping an already-selected tab pops its NavigationStack to root — but
    /// when we're arriving at "Plus" for the FIRST time from a different tab, that
    /// pop doesn't happen, and any push left over from a *previous* visit (this
    /// method is called repeatedly across the flow) would still be showing. Pop
    /// explicitly via the back button until the "Plus" title reappears.
    private func popToMoreRoot(app: XCUIApplication, moreTitle: String) {
        var attempts = 0
        while !app.staticTexts[moreTitle].firstMatch.exists && attempts < 4 {
            let backButton = app.navigationBars.buttons.element(boundBy: 0)
            guard backButton.exists else { break }
            backButton.tap()
            attempts += 1
            usleep(400_000)
        }
    }

    private func openMoreItem(_ label: String, app: XCUIApplication, moreTitle: String = "Plus") {
        // Index 4 = "Plus"/"More" tab on iPhone's 5-slot tab bar (4 visible + more).
        if hasEnteredMoreTab {
            popToMoreRoot(app: app, moreTitle: moreTitle)
        }
        tapTabBarButton(4, app: app)
        hasEnteredMoreTab = true
        sleep(1)
        let row = app.staticTexts[label].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        // The row tap can land mid-transition (e.g. right after popToMoreRoot's own
        // animation) and silently miss — verify we actually LEFT the "Plus" root
        // before moving on, retrying the tap once if not.
        sleep(1)
        if app.staticTexts[moreTitle].firstMatch.exists {
            let retryRow = app.staticTexts[label].firstMatch
            if retryRow.waitForExistence(timeout: 5) {
                retryRow.tap()
                sleep(1)
            }
        }
    }

    private func runIPhoneFlow(prefix: String, language: String, theme: String) {
        hasEnteredMoreTab = false
        let app = launchApp(language: language, theme: theme)

        let dashboardTitle = app.staticTexts["Dashboard"].firstMatch
        XCTAssertTrue(dashboardTitle.waitForExistence(timeout: 30))
        sleep(2)
        capture("\(prefix)-01-dashboard", app: app)

        tapTabBarButton(1, app: app)
        sleep(2)
        capture("\(prefix)-02-transactions", app: app)

        tapTabBarButton(2, app: app)
        sleep(2)
        capture("\(prefix)-03-investissements", app: app)

        tapTabBarButton(3, app: app)
        sleep(2)
        capture("\(prefix)-04-patrimoine", app: app)

        let moreTitle = language == "fr" ? "Plus" : "More"

        openMoreItem("Budget", app: app, moreTitle: moreTitle)
        sleep(2)
        capture("\(prefix)-05-budget", app: app)

        openMoreItem("Tricount", app: app, moreTitle: moreTitle)
        sleep(1)
        let firstGroupCell = app.cells.firstMatch
        if firstGroupCell.waitForExistence(timeout: 5) {
            firstGroupCell.tap()
            sleep(1)
        }
        capture("\(prefix)-06-tricount", app: app)

        openMoreItem("SQL", app: app, moreTitle: moreTitle)
        sleep(2)
        capture("\(prefix)-07-sql-assistant", app: app)

        let donneesLabel = language == "fr" ? "Données" : "Data"
        openMoreItem(donneesLabel, app: app, moreTitle: moreTitle)
        sleep(1)
        let tiersSegment = app.buttons[language == "fr" ? "Tiers" : "Payees"].firstMatch
        if tiersSegment.waitForExistence(timeout: 5) {
            tiersSegment.tap()
            sleep(1)
        }
        capture("\(prefix)-08-donnees-tiers", app: app)

        let reglagesLabel = language == "fr" ? "Paramètres" : "Settings"
        openMoreItem(reglagesLabel, app: app, moreTitle: moreTitle)
        sleep(1)
        let syncLabel = language == "fr" ? "Synchronisation iCloud" : "iCloud Sync"
        var syncRow = app.staticTexts[syncLabel].firstMatch
        if !syncRow.exists {
            app.swipeUp()
            sleep(1)
            syncRow = app.staticTexts[syncLabel].firstMatch
        }
        if syncRow.waitForExistence(timeout: 5) {
            syncRow.tap()
            sleep(1)
        }
        capture("\(prefix)-09-confidentialite", app: app)
    }

    private func runIPadFlow(prefix: String, language: String, theme: String) {
        let app = launchApp(language: language, theme: theme)

        let dashboardTitle = app.staticTexts["Dashboard"].firstMatch
        XCTAssertTrue(dashboardTitle.waitForExistence(timeout: 30))
        sleep(2)
        capture("\(prefix)-ipad-01-dashboard", app: app)

        func openSidebar(_ label: String) {
            let row = app.staticTexts[label].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.tap()
        }

        openSidebar("Transactions")
        sleep(1)
        capture("\(prefix)-ipad-02-transactions", app: app)

        openSidebar(language == "fr" ? "Investissements" : "Investments")
        sleep(2)
        capture("\(prefix)-ipad-03-investissements", app: app)

        openSidebar(language == "fr" ? "Patrimoine" : "Net Worth")
        sleep(1)
        capture("\(prefix)-ipad-04-patrimoine", app: app)

        openSidebar("Budget")
        sleep(2)
        capture("\(prefix)-ipad-05-budget", app: app)
    }

    // MARK: iPhone — 4 combinations

    @MainActor
    func testShotsIPhone_fr_light() throws { runIPhoneFlow(prefix: "fr-light", language: "fr", theme: "light") }

    @MainActor
    func testShotsIPhone_fr_dark() throws { runIPhoneFlow(prefix: "fr-dark", language: "fr", theme: "dark") }

    @MainActor
    func testShotsIPhone_en_light() throws { runIPhoneFlow(prefix: "en-light", language: "en", theme: "light") }

    @MainActor
    func testShotsIPhone_en_dark() throws { runIPhoneFlow(prefix: "en-dark", language: "en", theme: "dark") }

    // MARK: iPad — 4 combinations

    @MainActor
    func testShotsIPad_fr_light() throws { runIPadFlow(prefix: "fr-light", language: "fr", theme: "light") }

    @MainActor
    func testShotsIPad_fr_dark() throws { runIPadFlow(prefix: "fr-dark", language: "fr", theme: "dark") }

    @MainActor
    func testShotsIPad_en_light() throws { runIPadFlow(prefix: "en-light", language: "en", theme: "light") }

    @MainActor
    func testShotsIPad_en_dark() throws { runIPadFlow(prefix: "en-dark", language: "en", theme: "dark") }
}
