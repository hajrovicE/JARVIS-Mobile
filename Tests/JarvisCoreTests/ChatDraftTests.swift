import XCTest
@testable import JarvisCore

final class ChatDraftTests: XCTestCase, @unchecked Sendable {
    func testReplyClearsOnlyItsUneditedSubmittedDraft() async {
        var draft = ChatDraft(text: "ilk soru")
        let submitted = draft.submission()
        XCTAssertEqual(submitted.text, "ilk soru")
        XCTAssertTrue(draft.complete(submitted))
        XCTAssertEqual(draft.text, "")
        XCTAssertFalse(draft.complete(submitted), "A duplicate callback must not clear a later revision")
    }

    func testTypedNextQuestionSurvivesEarlierReply() async {
        var draft = ChatDraft(text: "ilk soru")
        let first = draft.submission()
        draft.edit("yanıt beklerken yazılan yeni soru")
        XCTAssertFalse(draft.complete(first))
        XCTAssertEqual(draft.text, "yanıt beklerken yazılan yeni soru")
    }

    func testFreshVoiceEditSurvivesEarlierReply() async {
        var draft = ChatDraft(text: "ilk soru")
        let first = draft.submission()
        draft.edit("yeni Türkçe sesli komut")
        XCTAssertFalse(draft.complete(first))
        XCTAssertEqual(draft.text, "yeni Türkçe sesli komut")
    }

    func testReenteringIdenticalTextIsNotAnOldSubmission() async {
        var draft = ChatDraft(text: "aynı soru")
        let first = draft.submission()
        draft.edit("başka soru")
        draft.edit("aynı soru")
        XCTAssertFalse(draft.complete(first))
        XCTAssertEqual(draft.text, "aynı soru")
    }

    func testOutOfOrderCompletionCannotDiscardLaterSubmission() async {
        var draft = ChatDraft(text: "birinci")
        let first = draft.submission()
        draft.edit("ikinci")
        let second = draft.submission()
        XCTAssertFalse(draft.complete(first))
        XCTAssertEqual(draft.text, "ikinci")
        XCTAssertTrue(draft.complete(second))
        draft.edit("üçüncü")
        XCTAssertFalse(draft.complete(first))
        XCTAssertFalse(draft.complete(second))
        XCTAssertEqual(draft.text, "üçüncü")
    }
}
