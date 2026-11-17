import Foundation
import XCTest
@testable import JarvisCore

final class SpeechStreamingTests: XCTestCase, @unchecked Sendable {
    func testSentenceStartsBeforeWholeResponseButWaitsForBoundaryLookahead() async {
        var stream = TurkishSpeechStream()
        XCTAssertEqual(stream.append("Merhaba."), [])
        XCTAssertEqual(stream.append(" İkinci"), ["Merhaba."])
        XCTAssertEqual(stream.append(" cümle!"), [])
        XCTAssertEqual(stream.finish(), ["İkinci cümle!"])
        XCTAssertEqual(stream.finish(), [])
        XCTAssertEqual(stream.append(" Geç token."), [])
    }

    func testSplitAbbreviationsDecimalsURLsAndUnicodeDoNotSpeakEarly() async {
        var stream = TurkishSpeechStream()
        let input = "Dr. Ali 3.14 ölçüsünü https://örnek.test/sonuç adresinde açıkladı. Türkçe doğru!"
        var emitted: [String] = []
        for character in input { emitted += stream.append(String(character)) }
        XCTAssertEqual(emitted, ["Dr. Ali 3.14 ölçüsünü https://örnek.test/sonuç adresinde açıkladı."])
        emitted += stream.finish()
        XCTAssertEqual(emitted.last, "Türkçe doğru!")
        XCTAssertEqual(emitted.joined(separator: " "), input)
    }

    func testThoughtAndCodeAreNotSpokenEvenWhenMarkersSplitAcrossTokens() async {
        var stream = TurkishSpeechStream()
        let input = "<think>Gizli akıl yürütme. Devam?</think>Merhaba. ```swift\nprint(\"Kod!\")\n``` Sonuç `a.b()` hazır."
        var spoken: [String] = []
        for character in input { spoken += stream.append(String(character)) }
        spoken += stream.finish()
        XCTAssertEqual(spoken, ["Merhaba.", "Sonuç hazır."])
        XCTAssertFalse(spoken.joined().contains("Gizli"))
        XCTAssertFalse(spoken.joined().contains("Kod"))
    }

    func testUnclosedMarkupNeverBecomesSpokenTail() async {
        for input in ["<thi", "<think>tamamlanmamış düşünce.", "```swift\nprint(1)", "`gizli kod"] {
            var stream = TurkishSpeechStream()
            XCTAssertEqual(stream.append(input), [])
            XCTAssertEqual(stream.finish(), [])
        }
    }

    func testQueueGapWhileModelProducesDoesNotFinishSpokenTurn() async throws {
        var queue = SpeechResponseQueue()
        let response = queue.begin()
        let first = try XCTUnwrap(queue.enqueue(responseID: response))
        XCTAssertEqual(queue.complete(utteranceID: first, responseID: response, finished: true), .waiting)
        XCTAssertTrue(queue.isActive)
        XCTAssertFalse(queue.hasPendingUtterances)
        let second = try XCTUnwrap(queue.enqueue(responseID: response))
        XCTAssertEqual(queue.finishInput(responseID: response), .waiting)
        XCTAssertEqual(queue.complete(utteranceID: second, responseID: response, finished: true), .completed(response))
        XCTAssertFalse(queue.isActive)
        XCTAssertEqual(queue.complete(utteranceID: second, responseID: response, finished: true), .ignored)
    }

    func testFinishAfterAudioDrainedCompletesOnceAndEmptyResponseCannotFakeSpeech() async throws {
        var queue = SpeechResponseQueue()
        let response = queue.begin()
        let utterance = try XCTUnwrap(queue.enqueue(responseID: response))
        XCTAssertEqual(queue.complete(utteranceID: utterance, responseID: response, finished: true), .waiting)
        XCTAssertEqual(queue.finishInput(responseID: response), .completed(response))
        XCTAssertEqual(queue.finishInput(responseID: response), .ignored)
        let empty = queue.begin()
        XCTAssertEqual(queue.finishInput(responseID: empty), .empty(empty))
    }

    func testCancellationAndOldUtterancesCannotCompleteNewResponse() async throws {
        var queue = SpeechResponseQueue()
        let old = queue.begin()
        let oldUtterance = try XCTUnwrap(queue.enqueue(responseID: old))
        queue.cancel()
        let next = queue.begin()
        let current = try XCTUnwrap(queue.enqueue(responseID: next))
        XCTAssertEqual(queue.complete(utteranceID: oldUtterance, responseID: old, finished: true), .ignored)
        XCTAssertTrue(queue.isActive)
        XCTAssertEqual(queue.complete(utteranceID: current, responseID: next, finished: false), .cancelled(next))
        XCTAssertFalse(queue.isActive)
        XCTAssertEqual(queue.finishInput(responseID: next), .ignored)
    }
}
