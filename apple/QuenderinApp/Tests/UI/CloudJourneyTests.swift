import XCTest

/// One ordered journey per fresh Cloud destination. Do not run against an existing
/// user profile: an unexpected welcome/connection/chat state fails instead of reset.
/// QUENDERIN_MOCK_UI is honored by the app only in Debug; replies are synthetic.
final class CloudJourneyTests: XCTestCase {
    @MainActor private lazy var app = XCUIApplication()
    private let timeout: TimeInterval = 15
    private let draft = "What is 17% of 240?"
    private let deepSeekConsent = "Send this key to DeepSeek for validation and save it securely on this device."

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFreshOfflineEntryConnectionsChatAndRecovery() throws {
        app.launchEnvironment["QUENDERIN_MOCK_UI"] = "1"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        // No defaults overrides, removal, or reset: fail if this is not a fresh install.
        require(app.staticTexts["Meet Quenderin"], "Fresh welcome screen is required")
        capture("01-fresh-welcome")
        tap(app.buttons["Continue"])
        require(app.staticTexts["Use with judgement"])
        require(app.buttons["I understand and agree"])
        capture("02-ai-consent")
        tap(app.buttons["I understand and agree"])
        require(app.buttons["deepseek-before-download"])
        require(app.buttons["remote-before-download"])
        require(app.staticTexts["RECOMMENDED FOR YOUR DEVICE"])
        capture("03-default-local-model-route")

        checkDeepSeekFormWithoutNetwork()
        checkComputerFormWithoutNetwork()

        // This invokes only the app's existing Debug MockModelDownloader and
        // MockInferenceEngine. It does not establish real artifact/inference proof.
        tap(app.buttons["Download & continue"])
        let composer = app.textFields["Message"]
        require(composer, "Mock local setup must reach the real chat composer")
        require(app.staticTexts["Try one"], "A fresh install must open an empty local conversation")
        XCTAssertFalse(app.buttons["deepseek-before-download"].exists)
        capture("08-local-chat-empty")
        tap(composer)
        composer.typeText(draft)
        XCTAssertEqual(composer.value as? String, draft)
        checkDraftSurvivesDestinationNavigation()
        XCTAssertEqual(composer.value as? String, draft)
        capture("09-local-draft-after-navigation")
        tap(app.buttons["Send message"])
        let canned = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "reply is canned")).firstMatch
        require(canned, "The synthetic reply must identify its canned provenance")
        require(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "40.8")).firstMatch,
                "The known mock math prompt must display its expected answer")
        require(app.buttons["Send message"])
        XCTAssertFalse(app.buttons["Send message"].isEnabled)
        capture("10-local-canned-reply")

        #if os(macOS)
        checkMacSettingsAndLastWindowRecovery()
        #else
        checkPhoneSettingsHistoryAndRelaunch()
        #endif
    }

    @MainActor private func checkDeepSeekFormWithoutNetwork() {
        tap(app.buttons["deepseek-before-download"])
        let key = app.secureTextFields["deepseek-api-key"]
        let connect = app.buttons["deepseek-connect"]
        require(key, "A fresh install must show the disconnected DeepSeek form")
        require(connect)
        let consent = deepSeekConsentControl
        require(consent)
        XCTAssertEqual(consent.label, deepSeekConsent)
        XCTAssertEqual(switchValue(consent), "0", "Provider validation consent must start off")
        XCTAssertFalse(connect.isEnabled)
        capture("04-deepseek-consent-default-off")

        tap(key)
        // Spaces are rejected by DeepSeekAPIKey before the client can make a request.
        key.typeText("invalid fixture key")
        XCTAssertFalse(connect.isEnabled, "Typing alone must not grant validation consent")
        tap(consent)
        XCTAssertEqual(switchValue(consent), "1", "The explicit consent action must turn the switch on")
        XCTAssertTrue(connect.isEnabled)
        tap(connect)
        require(app.staticTexts["Enter a valid DeepSeek API key without spaces."])
        XCTAssertFalse(connect.isEnabled, "The rejected key must be cleared")
        XCTAssertTrue(key.isEnabled, "Validation failure must leave an editable form")
        capture("05-deepseek-local-validation-recovery")
        tap(consent)
        XCTAssertEqual(switchValue(consent), "0")
        tap(app.buttons["Done"])
        require(app.buttons["deepseek-before-download"])
    }

    @MainActor private func checkComputerFormWithoutNetwork() {
        tap(app.buttons["remote-before-download"])
        let server = app.textFields["remote-server"]
        let email = app.textFields["remote-email"]
        let password = app.secureTextFields["remote-password"]
        let authorize = app.buttons["remote-authorize"]
        // Missing secure runtime is a failure, never a skipped form check.
        require(server, "The Cloud SDK build must include the secure computer runtime")
        require(email)
        require(password)
        require(authorize)
        XCTAssertFalse(authorize.isEnabled)
        XCTAssertEqual(app.textFields["remote-device-name"].value as? String, "Quenderin")
        capture("06-computer-disconnected-form")
        tap(server)
        server.typeText("http://fixture.invalid")
        tap(email)
        email.typeText("cloud-fixture@example.invalid")
        XCTAssertFalse(authorize.isEnabled)
        tap(password)
        password.typeText("synthetic-fixture-password")
        XCTAssertTrue(authorize.isEnabled)
        tap(authorize)
        let error = app.staticTexts["remote-error"]
        require(error)
        XCTAssertEqual(error.label, "Enter the HTTPS origin of your self-hosted Remote Harness server.")
        XCTAssertFalse(authorize.isEnabled, "A rejected authorization must clear the password")
        // A scrolled SwiftUI Form can omit earlier rows from its accessibility tree.
        revealFormControl(server, towardStart: true)
        XCTAssertTrue(server.isEnabled)
        XCTAssertEqual(server.value as? String, "http://fixture.invalid")
        revealFormControl(email, towardStart: false)
        XCTAssertEqual(email.value as? String, "cloud-fixture@example.invalid")
        capture("07-computer-local-validation-recovery")
        tap(app.buttons["Done"])
        require(app.buttons["remote-before-download"])
    }

    @MainActor private var deepSeekConsentControl: XCUIElement {
        app.switches["deepseek-validation-consent"]
    }

    @MainActor private func switchValue(_ element: XCUIElement) -> String? {
        // iOS exposes String values; macOS exposes numeric accessibility values.
        let value = element.value
        return (value as? String) ?? (value as? NSNumber)?.stringValue
    }

    @MainActor private func checkDraftSurvivesDestinationNavigation() {
        #if os(macOS)
        tap(app.buttons["DeepSeek cloud chat"])
        require(app.secureTextFields["deepseek-api-key"])
        XCTAssertEqual(switchValue(deepSeekConsentControl), "0")
        tap(app.buttons["Chats (⌘1)"])
        require(app.textFields["Message"])
        #else
        tap(app.tabBars.buttons["DeepSeek"])
        require(app.secureTextFields["deepseek-api-key"])
        XCTAssertEqual(switchValue(deepSeekConsentControl), "0")
        tap(app.tabBars.buttons["Chat"])
        require(app.textFields["Message"])
        #endif
    }

    #if os(macOS)
    @MainActor private func checkMacSettingsAndLastWindowRecovery() {
        let main = app.windows.containing(.textField, identifier: "Message").firstMatch
        require(main)
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.containing(.switch, identifier: "automatic-model-selection").firstMatch
        require(settings, "The standard Settings command must open a usable settings window")
        XCTAssertEqual(settings.switches["automatic-model-selection"].label, "Automatic model selection")
        capture("11-mac-main-and-settings")
        tap(main.buttons[XCUIIdentifierCloseWindow])
        requireGone(main)
        XCTAssertTrue(settings.exists, "Settings must remain usable after the main window closes")
        XCTAssertNotEqual(app.state, .notRunning)
        capture("12-mac-settings-only")

        // The production command is in Window (before its window list). Exercise
        // that visible menu once, then its shortcut without creating a second main.
        tap(app.menuBars.menuBarItems["Window"])
        tap(app.menuBars.menuItems["Show Main Window"])
        let reopened = app.windows.containing(.textField, identifier: "Message").firstMatch
        require(reopened, "Show Main Window must recover the main scene while Settings is open")
        requireSavedSyntheticReply()
        XCTAssertEqual(app.windows.containing(.textField, identifier: "Message").count, 1)
        app.typeKey("0", modifierFlags: .command)
        requireSavedSyntheticReply()
        XCTAssertEqual(app.windows.containing(.textField, identifier: "Message").count, 1,
                       "Repeated Show Main Window must focus the existing main scene")
        capture("12b-mac-show-main-preserves-conversation")
        tap(reopened.buttons[XCUIIdentifierCloseWindow])
        requireGone(reopened)
        XCTAssertTrue(settings.exists)
        tap(settings.buttons[XCUIIdentifierCloseWindow])
        XCTAssertTrue(app.wait(for: .notRunning, timeout: timeout), "Closing the last window must quit")

        app.launch()
        require(app.textFields["Message"])
        requireSavedSyntheticReply()
        capture("13-mac-relaunch-after-settings-last-window")
        let restoredMain = app.windows.containing(.textField, identifier: "Message").firstMatch
        tap(restoredMain.buttons[XCUIIdentifierCloseWindow])
        XCTAssertTrue(app.wait(for: .notRunning, timeout: timeout), "Closing the sole main window must quit")
        app.launch()
        require(app.textFields["Message"])
        requireSavedSyntheticReply()
        capture("14-mac-relaunch-after-main-last-window")

        // Check New Chat last, after proving restoration of the saved conversation.
        let finalMain = app.windows.containing(.textField, identifier: "Message").firstMatch
        app.typeKey(",", modifierFlags: .command)
        require(settings)
        tap(finalMain.buttons[XCUIIdentifierCloseWindow])
        requireGone(finalMain)
        XCTAssertTrue(settings.exists)
        app.typeKey("n", modifierFlags: .command)
        let newComposer = app.textFields["Message"]
        require(newComposer, "New Chat must recover a main window from Settings alone")
        require(app.staticTexts["Try one"], "New Chat must open an empty conversation")
        XCTAssertEqual(app.windows.containing(.textField, identifier: "Message").count, 1)
        let savedRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", draft)).firstMatch
        require(savedRow, "The prior saved conversation must remain in the sidebar")
        let focusedDraft = "Unsent cloud focus fixture"
        app.typeText(focusedDraft) // No click: the command must focus the new composer.
        XCTAssertEqual(newComposer.value as? String, focusedDraft)
        capture("15-mac-new-chat-recovers-and-focuses-main")
    }
    #else
    @MainActor private func checkPhoneSettingsHistoryAndRelaunch() {
        // The native TabView exposes destinations beyond its first four through More.
        tap(app.tabBars.buttons["More"])
        tap(app.staticTexts["Settings"])
        let automatic = app.switches["automatic-model-selection"]
        for _ in 0..<5 where !automatic.exists || !automatic.isHittable {
            app.swipeUp()
        }
        require(automatic)
        XCTAssertEqual(automatic.label, "Automatic model selection")
        capture("11-iphone-settings")
        tap(app.tabBars.buttons["Chat"])
        require(app.textFields["Message"])
        tap(app.navigationBars.buttons["Chats"])
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", draft)).firstMatch
        require(row, "The completed synthetic conversation must appear in history")
        capture("12-iphone-saved-history")
        tap(row)
        requireSavedSyntheticReply()
        app.terminate()
        app.launch()
        // Returning iPhone users land on the conversation list.
        let restoredRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", draft)).firstMatch
        require(restoredRow, "Saved history must survive an app relaunch")
        tap(restoredRow)
        require(app.textFields["Message"])
        requireSavedSyntheticReply()
        capture("13-iphone-history-after-relaunch")
    }
    #endif

    @MainActor private func requireSavedSyntheticReply() {
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "reply is canned")).firstMatch
        require(reply)
    }

    @MainActor private func require(_ element: XCUIElement, _ message: String = "Required screen or control is missing",
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), message, file: file, line: line)
    }

    @MainActor private func requireGone(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: timeout), .completed, file: file, line: line)
    }

    @MainActor private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        require(element, file: file, line: line)
        revealFormControl(element, towardStart: false, file: file, line: line)
        #if os(macOS)
        element.click()
        #else
        if element.elementType == .switch {
            // SwiftUI exposes the labelled row as the switch. Its center can hit
            // only the multiline label; the native switch is at the trailing end.
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        } else {
            element.tap()
        }
        #endif
    }

    @MainActor private func revealFormControl(_ element: XCUIElement, towardStart: Bool,
                                             file: StaticString = #filePath, line: UInt = #line) {
        // Forms can extend below the software keyboard or a short Mac window.
        // Scroll before requiring existence because Form can virtualize offscreen rows.
        for _ in 0..<5 where !element.exists || !element.isHittable {
            #if os(macOS)
            let surface = app.scrollViews.firstMatch
            require(surface, "The required control has no reachable scroll surface", file: file, line: line)
            surface.scroll(byDeltaX: 0, deltaY: towardStart ? 250 : -250)
            #else
            let surface: XCUIElement
            if app.collectionViews.firstMatch.exists {
                surface = app.collectionViews.firstMatch
            } else if app.tables.firstMatch.exists {
                surface = app.tables.firstMatch
            } else {
                surface = app
            }
            let appFrame = app.frame
            var visible = surface.frame.intersection(appFrame)
            let keyboard = app.keyboards.firstMatch
            if keyboard.exists, visible.intersects(keyboard.frame) {
                visible.size.height = max(0, keyboard.frame.minY - visible.minY)
            }
            guard !visible.isNull, !visible.isEmpty else {
                XCTFail("The required control has no visible scroll surface", file: file, line: line)
                return
            }
            // Default swipes can start beneath the keyboard and never reach the form.
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: visible.midX - appFrame.minX,
                                                  dy: visible.minY + visible.height * (towardStart ? 0.2 : 0.8) - appFrame.minY))
            let end = origin.withOffset(CGVector(dx: visible.midX - appFrame.minX,
                                                dy: visible.minY + visible.height * (towardStart ? 0.8 : 0.2) - appFrame.minY))
            start.press(forDuration: 0.05, thenDragTo: end)
            #endif
        }
        if !element.exists { require(element, file: file, line: line) }
        XCTAssertTrue(element.isHittable, "Required control is not reachable", file: file, line: line)
    }

    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
