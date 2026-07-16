import XCTest
@testable import DCPKit

final class ChannelMapTests: XCTestCase {
    func testStereoMapsToLRWithSilencePadding() {
        let map = AudioConformer.ChannelMap.make(sourceChannels: 2, labels: [1, 2])
        XCTAssertEqual(map.slots, [0, 1, nil, nil, nil, nil])
        XCTAssertTrue(map.verified)
    }

    func testMonoDuplicatesToLR() {
        let map = AudioConformer.ChannelMap.make(sourceChannels: 1, labels: [])
        XCTAssertEqual(map.slots, [0, 0, nil, nil, nil, nil])
        XCTAssertTrue(map.verified)
    }

    func testSMPTEOrdered51PassesThrough() {
        // L R C LFE Ls Rs stored in SMPTE order already.
        let map = AudioConformer.ChannelMap.make(sourceChannels: 6, labels: [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(map.slots, [0, 1, 2, 3, 4, 5])
        XCTAssertTrue(map.verified)
    }

    func testFilmOrder51GetsReordered() {
        // L C R Ls Rs LFE (film order) must land in SMPTE slots.
        let map = AudioConformer.ChannelMap.make(sourceChannels: 6, labels: [1, 3, 2, 5, 6, 4])
        XCTAssertEqual(map.slots, [0, 2, 1, 5, 3, 4])
        XCTAssertTrue(map.verified)
    }

    func testRearSurroundLabelsAccepted() {
        // Some files label surrounds 33/34 (rear) instead of 5/6.
        let map = AudioConformer.ChannelMap.make(sourceChannels: 6, labels: [1, 2, 3, 4, 33, 34])
        XCTAssertEqual(map.slots, [0, 1, 2, 3, 4, 5])
        XCTAssertTrue(map.verified)
    }

    func testUnlabeled6ChannelFallsBackUnverified() {
        let map = AudioConformer.ChannelMap.make(sourceChannels: 6, labels: [])
        XCTAssertEqual(map.slots, [0, 1, 2, 3, 4, 5])
        XCTAssertFalse(map.verified, "must flag unverified order for the QC report")
    }

    func testQuantize24Range() {
        XCTAssertEqual(AudioConformer.quantize24(0), 0)
        XCTAssertEqual(AudioConformer.quantize24(1.0), 8_388_607)
        XCTAssertEqual(AudioConformer.quantize24(-1.0), -8_388_607)
        XCTAssertEqual(AudioConformer.quantize24(2.0), 8_388_607, "clamps above full scale")
    }
}
