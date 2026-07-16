import XCTest
@testable import DCPKit

final class EditRateTests: XCTestCase {
    func testSupportedRatesMap() {
        XCTAssertEqual(EditRate.forSource(frameRate: 24.0)?.rate, .fps24)
        XCTAssertEqual(EditRate.forSource(frameRate: 24.0)?.needsPullUp, false)

        XCTAssertEqual(EditRate.forSource(frameRate: 23.976)?.rate, .fps24)
        XCTAssertEqual(EditRate.forSource(frameRate: 23.976)?.needsPullUp, true)

        XCTAssertEqual(EditRate.forSource(frameRate: 25.0)?.rate, .fps25)
        XCTAssertEqual(EditRate.forSource(frameRate: 25.0)?.needsPullUp, false)

        XCTAssertEqual(EditRate.forSource(frameRate: 30.0)?.rate, .fps30)
        XCTAssertEqual(EditRate.forSource(frameRate: 30.0)?.needsPullUp, false)

        XCTAssertEqual(EditRate.forSource(frameRate: 29.97)?.rate, .fps30)
        XCTAssertEqual(EditRate.forSource(frameRate: 29.97)?.needsPullUp, true)
    }

    func testUnsupportedRatesRejected() {
        XCTAssertNil(EditRate.forSource(frameRate: 50.0))
        XCTAssertNil(EditRate.forSource(frameRate: 60.0))
        XCTAssertNil(EditRate.forSource(frameRate: 15.0))
        XCTAssertNil(EditRate.forSource(frameRate: 0))
    }

    func testAudioSamplesPerFrameAreIntegerAndCorrect() {
        XCTAssertEqual(EditRate.fps24.audioSamplesPerFrame, 2000)
        XCTAssertEqual(EditRate.fps25.audioSamplesPerFrame, 1920)
        XCTAssertEqual(EditRate.fps30.audioSamplesPerFrame, 1600)
        // All must divide 48000 exactly — no fractional audio frames.
        for rate in [EditRate.fps24, .fps25, .fps30] {
            XCTAssertEqual(rate.audioSamplesPerFrame * rate.fps, 48_000)
        }
    }

    func testXMLString() {
        XCTAssertEqual(EditRate.fps24.xmlString, "24 1")
        XCTAssertEqual(EditRate.fps25.xmlString, "25 1")
        XCTAssertEqual(EditRate.fps30.xmlString, "30 1")
    }
}
