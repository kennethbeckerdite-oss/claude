import XCTest
@testable import DCPKit

final class DCPPackageTests: XCTestCase {
    private var folderURL: URL!

    override func setUpWithError() throws {
        folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DCPPackageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folderURL)
    }

    /// Fixed UUIDs + fixed date + fixed asset bytes → the generated XML is
    /// deterministic and cross-checkable by hand.
    func testGeneratedXMLStructure() throws {
        let pictureUUID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let soundUUID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let cplUUID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let pklUUID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

        let pictureURL = folderURL.appendingPathComponent("picture.mxf")
        let soundURL = folderURL.appendingPathComponent("sound.mxf")
        try Data("fake picture essence".utf8).write(to: pictureURL)
        try Data("fake sound essence".utf8).write(to: soundURL)

        let output = try DCPPackage.write(
            DCPPackage.Input(folderURL: folderURL,
                             contentTitle: "Test & Title",
                             container: .flat,
                             pictureURL: pictureURL,
                             pictureUUID: pictureUUID,
                             soundURL: soundURL,
                             soundUUID: soundUUID,
                             frameCount: 240,
                             issueDate: Date(timeIntervalSince1970: 1_780_000_000)),
            cplUUID: cplUUID,
            pklUUID: pklUUID)

        let cpl = try XMLDocument(contentsOf: output.cplURL, options: [])
        let pkl = try XMLDocument(contentsOf: output.pklURL, options: [])
        let assetMap = try XMLDocument(contentsOf: output.assetMapURL, options: [])

        // Namespaces are the SMPTE (not Interop) ones.
        XCTAssertEqual(cpl.rootElement()?.uri, "http://www.smpte-ra.org/schemas/429-7/2006/CPL")
        XCTAssertEqual(pkl.rootElement()?.uri, "http://www.smpte-ra.org/schemas/429-8/2007/PKL")
        XCTAssertEqual(assetMap.rootElement()?.uri, "http://www.smpte-ra.org/schemas/429-9/2007/AM")

        // CPL: escaped title, correct picture geometry and durations.
        let title = try cpl.nodes(forXPath: "//*[local-name()='ContentTitleText']").first?.stringValue
        XCTAssertEqual(title, "Test & Title")
        let aspect = try cpl.nodes(forXPath: "//*[local-name()='ScreenAspectRatio']").first?.stringValue
        XCTAssertEqual(aspect, "1998 1080")
        let durations = try cpl.nodes(forXPath: "//*[local-name()='Duration']").compactMap(\.stringValue)
        XCTAssertEqual(durations, ["240", "240"], "picture and sound durations")
        let pictureId = try cpl.nodes(forXPath: "//*[local-name()='MainPicture']/*[local-name()='Id']").first?.stringValue
        XCTAssertEqual(pictureId, "urn:uuid:11111111-1111-4111-8111-111111111111")
        let kind = try cpl.nodes(forXPath: "//*[local-name()='ContentKind']").first?.stringValue
        XCTAssertEqual(kind, "short")

        // PKL: three assets (picture, sound, CPL) with real hashes and sizes.
        let pklAssets = try pkl.nodes(forXPath: "//*[local-name()='Asset']")
        XCTAssertEqual(pklAssets.count, 3)
        let pictureHash = try pkl.nodes(
            forXPath: "//*[local-name()='Asset'][*[local-name()='Id']='urn:uuid:11111111-1111-4111-8111-111111111111']/*[local-name()='Hash']"
        ).first?.stringValue
        XCTAssertEqual(pictureHash, try DCPPackage.sha1Base64(of: pictureURL))
        let types = try pkl.nodes(forXPath: "//*[local-name()='Type']").compactMap(\.stringValue)
        XCTAssertEqual(types, ["application/mxf", "application/mxf", "text/xml"])

        // ASSETMAP: four entries (PKL, CPL, picture, sound); only the PKL is flagged.
        let mapAssets = try assetMap.nodes(forXPath: "//*[local-name()='Asset']")
        XCTAssertEqual(mapAssets.count, 4)
        let packingListFlags = try assetMap.nodes(forXPath: "//*[local-name()='PackingList']")
        XCTAssertEqual(packingListFlags.count, 1)
        let paths = try assetMap.nodes(forXPath: "//*[local-name()='Path']").compactMap(\.stringValue)
        XCTAssertTrue(paths.contains("picture.mxf"))
        XCTAssertTrue(paths.contains(output.cplURL.lastPathComponent))

        // VOLINDEX exists with index 1.
        let volIndex = try XMLDocument(contentsOf: output.volIndexURL, options: [])
        XCTAssertEqual(try volIndex.nodes(forXPath: "//*[local-name()='Index']").first?.stringValue, "1")
    }

    func testValidatorAcceptsGeneratedXMLAndCatchesTampering() throws {
        // Note: no real MXFs here, so we only exercise the XML/hash layers —
        // the validator must fail cleanly at the MXF step, not crash.
        let pictureURL = folderURL.appendingPathComponent("picture.mxf")
        try Data("fake picture essence".utf8).write(to: pictureURL)

        _ = try DCPPackage.write(DCPPackage.Input(
            folderURL: folderURL, contentTitle: "T", container: .flat,
            pictureURL: pictureURL, pictureUUID: UUID(),
            soundURL: nil, soundUUID: nil, frameCount: 24))

        // Fake essence is not an MXF, so validation must throw — but only
        // after the hash checks pass (error mentions the MXF read).
        XCTAssertThrowsError(try DCPValidator.validate(
            folderURL: folderURL, expectedContainer: .flat, expectSound: false)) { error in
            XCTAssertTrue("\(error)".contains("MXF"), "expected MXF-stage failure, got: \(error)")
        }

        // Now corrupt the essence: the hash check must catch it first.
        try Data("tampered".utf8).write(to: pictureURL)
        XCTAssertThrowsError(try DCPValidator.validate(
            folderURL: folderURL, expectedContainer: .flat, expectSound: false)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("size") || message.contains("hash"),
                          "expected size/hash mismatch, got: \(message)")
        }
    }

    func testFolderNameFollowsConvention() {
        let name = DCPPackage.folderName(contentTitle: "my great film!",
                                         container: .scope,
                                         frameCount: 24 * 60 * 10, // 10 minutes → short
                                         hasAudio: true,
                                         issueDate: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertTrue(name.hasPrefix("MyGreatFilm_SHR-1_S_XX-XX_51_2K_"))
        XCTAssertTrue(name.hasSuffix("_PRC_SMPTE_OV"))
        XCTAssertFalse(name.contains(" "))
    }

    func testFolderNameHandlesAwkwardTitles() {
        XCTAssertEqual(DCPPackage.sanitizeTitleForName(""), "Untitled")
        XCTAssertEqual(DCPPackage.sanitizeTitleForName("!!!"), "Untitled")
        XCTAssertEqual(DCPPackage.sanitizeTitleForName("a very long title that keeps going"),
                       String("AVeryLongTitleThatKeepsGoing".prefix(14)))
    }
}
