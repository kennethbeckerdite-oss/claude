import XCTest
@testable import TranscodeKit

final class RenderSizeTests: XCTestCase {
    func testNoBoundsKeepsSize() {
        let size = RenderSize.fit(width: 3840, height: 2160)
        XCTAssertEqual(size.width, 3840)
        XCTAssertEqual(size.height, 2160)
    }

    func testDownscalesUHDToSmallHQBounds() {
        let size = RenderSize.fit(width: 3840, height: 2160, maxWidth: 1920, maxHeight: 1080)
        XCTAssertEqual(size.width, 1920)
        XCTAssertEqual(size.height, 1080)
    }

    func testNeverUpscales() {
        let size = RenderSize.fit(width: 1280, height: 720, maxWidth: 1920, maxHeight: 1080)
        XCTAssertEqual(size.width, 1280)
        XCTAssertEqual(size.height, 720)
    }

    func testTallSourceBoundByHeight() {
        // 9:16 vertical: height is the binding constraint.
        let size = RenderSize.fit(width: 2160, height: 3840, maxWidth: 1920, maxHeight: 1080)
        XCTAssertEqual(size.height, 1080)
        XCTAssertEqual(size.width, 608)   // 2160 × (1080/3840) = 607.5 → rounds to 608 (even)
    }

    func testResultsAreEven() {
        let size = RenderSize.fit(width: 1279, height: 533, maxWidth: 1000, maxHeight: nil)
        XCTAssertEqual(size.width % 2, 0)
        XCTAssertEqual(size.height % 2, 0)
    }

    func testAnamorphicFlattenedSizePassesThrough() {
        // Coded 1080×1080 with 2:1 PAR probes as natural 2160×1080 — output
        // keeps the display shape.
        let size = RenderSize.fit(width: 2160, height: 1080)
        XCTAssertEqual(size.width, 2160)
        XCTAssertEqual(size.height, 1080)
    }
}
