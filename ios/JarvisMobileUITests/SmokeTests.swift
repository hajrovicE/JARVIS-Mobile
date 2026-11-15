import XCTest

/// Exercises the production UI and storage, without test-only authentication or storage bypasses.
final class SmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTypedMemorySurvivesRelaunchAndDeletion() throws {
        let app = XCUIApplication()
        app.launch()
        let onboarding = app.buttons["onboarding.start"]
        if onboarding.waitForExistence(timeout: 3) {
            XCTAssertTrue(app.staticTexts["JARVIS'e hoş geldiniz"].exists)
            onboarding.tap()
        }
        XCTAssertTrue(app.tabBars.buttons["Sohbet"].waitForExistence(timeout: 10))

        // Clear through the same explicit confirmation used by the user.
        app.tabBars.buttons["Hafıza"].tap()
        let clear = app.buttons["memory.deleteAll"]
        XCTAssertTrue(reveal(clear, in: app))
        XCTAssertTrue(waitUntilEnabled(clear))
        clear.tap()
        let confirm = app.buttons["Tümünü sil"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(waitUntilEnabled(clear))

        app.tabBars.buttons["Sohbet"].tap()
        try send("hatırla ki test tercihim sade kahve", in: app)
        let reply = app.staticTexts["chat.reply"]
        XCTAssertTrue(waitForLabel(reply, containing: "Kişisel hafızaya kaydedildi."))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Sohbet"].waitForExistence(timeout: 10))
        try send("ne hatırlıyorsun", in: app)
        XCTAssertTrue(waitForLabel(reply, containing: "test tercihim sade kahve"))
        attachScreenshot(app, name: "Şifreli hafıza — yeniden açma sonrası test kaydı")

        app.tabBars.buttons["Hafıza"].tap()
        let memoryFields = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "memory.text."))
        XCTAssertTrue(reveal(memoryFields.firstMatch, in: app, towardTop: true))
        let delete = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "memory.delete.")).firstMatch
        XCTAssertTrue(reveal(delete, in: app))
        delete.tap()
        XCTAssertTrue(waitForAbsence(memoryFields.firstMatch))

        // A second restart demonstrates that deletion reached encrypted storage.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Sohbet"].waitForExistence(timeout: 10))
        try send("ne hatırlıyorsun", in: app)
        XCTAssertTrue(waitForLabel(reply, containing: "Kişisel hafıza boş."))

        app.tabBars.buttons["Durum"].tap()
        let speakerStatus = app.staticTexts["status.speakerIdentity"]
        XCTAssertTrue(speakerStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(speakerStatus.label.contains("ETKİN DEĞİL"))
        attachScreenshot(app, name: "Yetenek durumu — konuşmacı doğrulaması etkin değil")
        // No microphone or Speech authorization is needed for this complete interaction.
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) -> Bool {
        let collection = app.collectionViews.firstMatch
        let list = collection.waitForExistence(timeout: 2) ? collection : app.tables.firstMatch
        guard list.waitForExistence(timeout: 5) else { return false }
        for _ in 0..<8 {
            if element.exists && element.isHittable { return true }
            if towardTop { list.swipeDown() } else { list.swipeUp() }
        }
        return element.exists && element.isHittable
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func send(_ command: String, in app: XCUIApplication) throws {
        let input = app.descendants(matching: .any).matching(identifier: "chat.input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText(command)
        let send = app.buttons["chat.send"]
        XCTAssertTrue(waitUntilEnabled(send))
        if !send.isHittable { app.swipeUp() }
        send.tap()
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, containing text: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", text), object: element)], timeout: 10) == .completed
    }

    @MainActor
    private func waitUntilEnabled(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true", argumentArray: nil), object: element)], timeout: 10) == .completed
    }

    @MainActor
    private func waitForAbsence(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false", argumentArray: nil), object: element)], timeout: 10) == .completed
    }
}
