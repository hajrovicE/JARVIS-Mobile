import Foundation
import XCTest
@testable import JarvisCore

final class TurkishSpeechChunkerTests: XCTestCase {
    func testTurkishSentenceBoundariesRemainIntact() {
        let chunks = TurkishSpeechChunker.chunks(
            "Merhaba. Nasılsın? İyiyim, teşekkürler!", maxCharacters: 40)
        XCTAssertEqual(chunks.joined(separator: " "),
                       "Merhaba. Nasılsın? İyiyim, teşekkürler!")
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 40 })
    }

    func testAbbreviationsAndDecimalNumbersDoNotCauseSentenceBreaks() {
        let chunks = TurkishSpeechChunker.chunks(
            "Dr. Ali 3.14 değerini hesapladı. Gerçekten mi?",
            maxCharacters: 40)
        XCTAssertEqual(chunks.first, "Dr. Ali 3.14 değerini hesapladı.")
        XCTAssertEqual(chunks.last, "Gerçekten mi?")
    }

    func testEmptyAndWhitespaceInputsProduceNoSpeech() {
        XCTAssertTrue(TurkishSpeechChunker.chunks("").isEmpty)
        XCTAssertTrue(TurkishSpeechChunker.chunks(" \n  \t ").isEmpty)
    }

    func testVeryLongResponseGetsBoundedSpeechChunksWithoutDroppingCharacters() {
        let input = "Biri " + String(repeating: "uzuncakelime", count: 35) + " bitiyor!"
        let chunks = TurkishSpeechChunker.chunks(input, maxCharacters: 40)
        XCTAssertGreaterThan(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 40 })
        XCTAssertEqual(chunks.joined(separator: "").replacingOccurrences(of: " ", with: ""),
                       input.replacingOccurrences(of: " ", with: ""))
    }

    func testDialogueNewlinesAreNormalizedForSpokenResponseOnly() {
        let original = "Merhaba.\n\nBugün\n ne yapıyoruz? "
        let chunks = TurkishSpeechChunker.chunks(original, maxCharacters: 180)
        XCTAssertEqual(chunks, ["Merhaba. Bugün ne yapıyoruz?"])
    }
}
