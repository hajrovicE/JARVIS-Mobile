import XCTest

/// Exercises the production UI and storage, without test-only authentication or storage bypasses.
final class SmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTypedMemorySurvivesRelaunchAndDirectDeletionPersists() throws {
        let app = XCUIApplication()
        app.launch()
        let onboarding = app.buttons["onboarding.start"]
        if onboarding.waitForExistence(timeout: 3) {
            XCTAssertTrue(app.staticTexts["JARVIS'e hoş geldiniz"].exists)
            onboarding.tap()
        }
        XCTAssertTrue(app.tabBars.buttons["Sohbet"].waitForExistence(timeout: 10))

        app.tabBars.buttons["Sohbet"].tap()
        let marker = "arayuz-kaydi-" + UUID().uuidString.lowercased()
        try send("hatırla ki " + marker, in: app)
        let reply = app.staticTexts["chat.reply"]
        XCTAssertTrue(waitForLabel(reply, containing: "Kişisel hafızaya kaydedildi."))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Sohbet"].waitForExistence(timeout: 10))
        try send("ne hatırlıyorsun", in: app)
        XCTAssertTrue(waitForLabel(reply, containing: marker))
        attachScreenshot(app, name: "Yerel JSON hafızası — yeniden açma sonrası test kaydı")

        app.tabBars.buttons["Hafıza"].tap()
        let savedMemory = app.textFields.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND value == %@", "memory.text.", marker)).firstMatch
        XCTAssertTrue(reveal(savedMemory, in: app, towardTop: true))
        let memoryID = String(savedMemory.identifier.dropFirst("memory.text.".count))
        let delete = app.buttons["memory.delete." + memoryID]
        XCTAssertTrue(reveal(delete, in: app))
        delete.tap()
        // The direct owner UI command is sufficient; no application-level second approval.
        XCTAssertTrue(waitForAbsence(savedMemory))
        XCTAssertFalse(app.buttons["Onayla ve biyometriyle doğrula"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Sohbet"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Hafıza"].tap()
        XCTAssertTrue(waitForAbsence(app.textFields["memory.text." + memoryID]))
        app.tabBars.buttons["Sohbet"].tap()
        try send("ne hatırlıyorsun", in: app)
        XCTAssertTrue(waitForLabel(reply, excluding: marker))

        app.tabBars.buttons["Durum"].tap()
        let speakerStatus = app.staticTexts["status.speakerIdentity"]
        XCTAssertTrue(speakerStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(speakerStatus.label.contains("ETKİN DEĞİL"))
        attachScreenshot(app, name: "Yetenek durumu — konuşmacı doğrulaması etkin değil")
        // No microphone or Speech authorization is needed for this complete interaction.
    }

    @MainActor
    func testOwnerInstructionsPersistAcrossRelaunch() throws {
        let app = XCUIApplication()
        app.launch()
        let onboarding = app.buttons["onboarding.start"]
        if onboarding.waitForExistence(timeout: 3) { onboarding.tap() }
        XCTAssertTrue(app.tabBars.buttons["AI"].waitForExistence(timeout: 10))
        app.tabBars.buttons["AI"].tap()
        let editor = app.textViews["model.ownerInstructions"]
        XCTAssertTrue(reveal(editor, in: app))
        let marker = "Talimat " + UUID().uuidString + ": Türkçe yanıtla."
        editor.tap()
        editor.typeText(marker)
        let savedValue = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(savedValue.contains(marker))
        // Leave the field before terminating so the normal SwiftUI binding persists.
        app.tabBars.buttons["Sohbet"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["AI"].waitForExistence(timeout: 10))
        app.tabBars.buttons["AI"].tap()
        XCTAssertTrue(reveal(editor, in: app))
        XCTAssertEqual(editor.value as? String, savedValue)
        // Actual generation and settings propagation are verified by the runtime harness,
        // rather than presenting an editable settings field as proof of model inference.
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
    private func waitForLabel(_ element: XCUIElement, excluding text: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "exists == true AND label != '' AND NOT (label CONTAINS %@)", text),
            object: element)], timeout: 10) == .completed
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
