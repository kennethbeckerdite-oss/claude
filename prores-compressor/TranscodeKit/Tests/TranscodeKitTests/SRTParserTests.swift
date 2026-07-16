import XCTest
@testable import TranscodeKit

final class SRTParserTests: XCTestCase {
    func testBasicCue() {
        let srt = """
        1
        00:00:01,000 --> 00:00:04,000
        Hello world
        """
        let cues = SRTParser.parse(srt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 4.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].text, "Hello world")
    }

    func testMultiLineAndTagStripping() {
        let srt = """
        1
        00:00:01,000 --> 00:00:04,000
        <i>First line</i>
        Second line

        2
        00:01:02,500 --> 00:01:05,250
        {\\an8}Top caption &amp; more
        """
        let cues = SRTParser.parse(srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "First line\nSecond line")
        XCTAssertEqual(cues[1].start, 62.5, accuracy: 0.001)
        XCTAssertEqual(cues[1].end, 65.25, accuracy: 0.001)
        XCTAssertEqual(cues[1].text, "Top caption & more")
    }

    func testCRLFandBOMandDotSeparator() {
        let srt = "\u{FEFF}1\r\n00:00:00.500 --> 00:00:02.000\r\nLine\r\n"
        let cues = SRTParser.parse(srt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 0.5, accuracy: 0.001)
        XCTAssertEqual(cues[0].text, "Line")
    }

    func testConsecutiveCuesWithoutBlankLine() {
        let srt = """
        00:00:01,000 --> 00:00:02,000
        One
        00:00:02,000 --> 00:00:03,000
        Two
        """
        let cues = SRTParser.parse(srt)
        XCTAssertEqual(cues.map(\.text), ["One", "Two"])
    }

    func testEmptyAndZeroLengthCuesDropped() {
        let srt = """
        1
        00:00:01,000 --> 00:00:01,000
        Zero length

        2
        00:00:02,000 --> 00:00:03,000

        """
        // First has zero duration, second has empty text — both dropped.
        XCTAssertTrue(SRTParser.parse(srt).isEmpty)
    }

    func testCursorLookupIsMonotonic() {
        let track = SubtitleTrack(cues: [
            SubtitleCue(start: 1, end: 2, text: "A"),
            SubtitleCue(start: 5, end: 6, text: "B"),
        ])
        var cursor = 0
        XCTAssertNil(track.cue(at: 0.5, cursor: &cursor))
        XCTAssertEqual(track.cue(at: 1.5, cursor: &cursor)?.text, "A")
        XCTAssertNil(track.cue(at: 3.0, cursor: &cursor))
        XCTAssertEqual(track.cue(at: 5.5, cursor: &cursor)?.text, "B")
        XCTAssertNil(track.cue(at: 7.0, cursor: &cursor))
    }
}
