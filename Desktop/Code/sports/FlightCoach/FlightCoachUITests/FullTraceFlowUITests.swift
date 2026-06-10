import XCTest

/// Drives the REAL app end-to-end: new session → import video from Photos →
/// analyse → assert an auto flight trace was produced and rendered on the
/// result screen. This validates auto address detection + tracking + the
/// in-app overlay — the exact path a user experiences.
final class FullTraceFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testImportAnalyseAndTraceLatestVideo() throws {
        let app = XCUIApplication()
        app.launch()

        attach(app, name: "01-home")

        let start = app.buttons["Start New Session"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "Home screen did not appear")
        start.tap()

        let behindBall = app.staticTexts["Behind Ball Flight"]
        XCTAssertTrue(behindBall.waitForExistence(timeout: 10), "Session setup did not appear")
        behindBall.tap()
        attach(app, name: "02-setup")

        app.staticTexts["Import from Photos"].tap()

        // PHPicker cells expose labels like "Video, eight seconds, 30 January, 5:55 pm".
        // IMG_4935.MOV was created 30 Jan 17:55 and runs 8 seconds.
        sleep(6)
        attach(app, name: "03-picker")
        let target = app.images.matching(
            NSPredicate(format: "label CONTAINS 'eight seconds, 30 January'")
        ).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 20), "IMG_4935 cell not found in photos picker")
        // PHPicker remote cells report isHittable == false; coordinate taps bypass that.
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        attach(app, name: "03b-after-pick")

        let analyse = app.buttons["Analyse Now"]
        XCTAssertTrue(analyse.waitForExistence(timeout: 90), "Import did not complete / result screen with Analyse Now not shown")
        attach(app, name: "04-imported")
        analyse.tap()

        // Analysis on a 4K 60fps clip can take several minutes on simulator.
        let tracePredicate = NSPredicate(format: "label CONTAINS[c] 'flight trace'")
        let traceBanner = app.staticTexts.matching(tracePredicate).firstMatch
        XCTAssertTrue(traceBanner.waitForExistence(timeout: 600), "Analysis never completed")
        attach(app, name: "05-result")

        let pointsPredicate = NSPredicate(format: "label CONTAINS[c] 'auto-tracked flight point'")
        let points = app.staticTexts.matching(pointsPredicate).firstMatch
        let traceLabel = traceBanner.label
        let detail = points.exists ? points.label : "(no points label)"
        print("UITEST TRACE STATUS: \(traceLabel) | \(detail)")

        // Capture the trail drawing on during playback (video is ~8s, may loop).
        for i in 0..<16 {
            attach(app, name: String(format: "play-%02d", i))
            usleep(800_000)
        }

        XCTAssertFalse(traceLabel.localizedCaseInsensitiveContains("no reliable"),
                       "App reported no reliable flight trace: \(traceLabel)")
        XCTAssertTrue(points.exists, "No auto-tracked flight points banner on result screen")
    }

    /// Opens the most recent session and captures the trail as it draws during playback.
    func testCaptureTrailPlayback() throws {
        let app = XCUIApplication()
        app.launch()

        let session = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Golf'")).firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 10), "No recent session on home screen")
        session.tap()

        let banner = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'flight trace'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "Result screen did not load")

        for i in 0..<16 {
            attach(app, name: String(format: "play-%02d", i))
            usleep(800_000)
        }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
