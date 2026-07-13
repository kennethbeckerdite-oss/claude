import XCTest
@testable import DCPKit

final class FramingTests: XCTestCase {
    func testHD1080FillsFlatHeight() {
        // 1920×1080 (1.78:1) into Flat 1998×1080 → pillarboxed.
        let geometry = FramingGeometry.fit(sourceWidth: 1920, sourceHeight: 1080, in: .flat)
        XCTAssertEqual(geometry.scaledWidth, 1920)
        XCTAssertEqual(geometry.scaledHeight, 1080)
        XCTAssertEqual(geometry.xOffset, 39)
        XCTAssertEqual(geometry.yOffset, 0)
    }

    func testUHDScalesDownIntoFlat() {
        // 3840×2160 → same 1.78:1 aspect, scaled to fit 1080 high.
        let geometry = FramingGeometry.fit(sourceWidth: 3840, sourceHeight: 2160, in: .flat)
        XCTAssertEqual(geometry.scaledHeight, 1080)
        XCTAssertEqual(geometry.scaledWidth, 1920)
        XCTAssertEqual(geometry.xOffset, 39)
    }

    func testDCI2KScopeIsExactFit() {
        let geometry = FramingGeometry.fit(sourceWidth: 2048, sourceHeight: 858, in: .scope)
        XCTAssertEqual(geometry, FramingGeometry(scaledWidth: 2048, scaledHeight: 858,
                                                 xOffset: 0, yOffset: 0))
    }

    func testCinemascopeSourceLetterboxesInFlat() {
        // 2.39:1 source into Flat → letterbox top/bottom.
        let geometry = FramingGeometry.fit(sourceWidth: 4096, sourceHeight: 1716, in: .flat)
        XCTAssertEqual(geometry.scaledWidth, 1998)
        XCTAssertEqual(geometry.xOffset, 0)
        XCTAssertGreaterThan(geometry.yOffset, 0)
        XCTAssertEqual(geometry.yOffset * 2 + geometry.scaledHeight, 1080)
    }

    func testDimensionsAlwaysEven() {
        let geometry = FramingGeometry.fit(sourceWidth: 1279, sourceHeight: 533, in: .scope)
        XCTAssertEqual(geometry.scaledWidth % 2, 0)
        XCTAssertEqual(geometry.scaledHeight % 2, 0)
        XCTAssertLessThanOrEqual(geometry.scaledWidth, 2048)
        XCTAssertLessThanOrEqual(geometry.scaledHeight, 858)
    }

    func testContainerSuggestion() {
        XCTAssertEqual(DCPContainer.suggested(width: 1920, height: 1080), .flat)
        XCTAssertEqual(DCPContainer.suggested(width: 4096, height: 1716), .scope)
        XCTAssertEqual(DCPContainer.suggested(width: 2048, height: 858), .scope)
        XCTAssertEqual(DCPContainer.suggested(width: 0, height: 0), .flat)
    }
}
