import XCTest
@testable import DCPKit

/// Exercises the XML/packaging layer for multi-composition packages. No real
/// MXFs — `writePackage` only hashes and sizes the track files, it doesn't
/// parse them, so fake essence bytes are fine here. (Essence parsing is
/// covered by the on-device validator during real exports.)
final class MultiCompositionTests: XCTestCase {
    private var folderURL: URL!

    override func setUpWithError() throws {
        folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiComp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folderURL)
    }

    private func makeComposition(name: String, editRate: EditRate,
                                 hasSound: Bool, frames: Int) throws -> DCPPackage.Composition {
        let pictureUUID = UUID()
        let pictureURL = folderURL.appendingPathComponent("j2c_\(pictureUUID.uuidString.lowercased()).mxf")
        try Data("picture-\(name)".utf8).write(to: pictureURL)

        var soundURL: URL?
        var soundUUID: UUID?
        if hasSound {
            let uuid = UUID()
            let url = folderURL.appendingPathComponent("pcm_\(uuid.uuidString.lowercased()).mxf")
            try Data("sound-\(name)".utf8).write(to: url)
            soundURL = url
            soundUUID = uuid
        }

        return DCPPackage.Composition(
            dcncName: name, contentTitle: name, contentKind: "short",
            container: .flat, editRate: editRate,
            pictureURL: pictureURL, pictureUUID: pictureUUID,
            soundURL: soundURL, soundUUID: soundUUID, frameCount: frames)
    }

    func testTwoCompositionsProduceOnePackageTwoCPLs() throws {
        let first = try makeComposition(name: "FilmOne", editRate: .fps24, hasSound: true, frames: 240)
        let second = try makeComposition(name: "FilmTwo", editRate: .fps25, hasSound: true, frames: 300)

        let output = try DCPPackage.writePackage(folderURL: folderURL,
                                                 compositions: [first, second])

        // Two CPLs, one PKL, one ASSETMAP, one VOLINDEX.
        XCTAssertEqual(output.cplURLs.count, 2)
        let xmlFiles = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xml" }
        XCTAssertEqual(xmlFiles.filter { $0.lastPathComponent.hasPrefix("CPL_") }.count, 2)
        XCTAssertEqual(xmlFiles.filter { $0.lastPathComponent.hasPrefix("PKL_") }.count, 1)
        XCTAssertTrue(xmlFiles.contains { $0.lastPathComponent == "ASSETMAP.xml" })
        XCTAssertTrue(xmlFiles.contains { $0.lastPathComponent == "VOLINDEX.xml" })

        // PKL lists all 6 assets: 2 pictures + 2 sounds + 2 CPLs.
        let pkl = try XMLDocument(contentsOf: output.pklURL, options: [])
        let pklAssets = try pkl.nodes(forXPath: "//*[local-name()='Asset']")
        XCTAssertEqual(pklAssets.count, 6)

        // ASSETMAP lists PKL + 2 CPLs + 2 pictures + 2 sounds = 7.
        let assetMap = try XMLDocument(contentsOf: output.assetMapURL, options: [])
        let mapAssets = try assetMap.nodes(forXPath: "//*[local-name()='Asset']")
        XCTAssertEqual(mapAssets.count, 7)
        // Exactly one PackingList flag.
        XCTAssertEqual(try assetMap.nodes(forXPath: "//*[local-name()='PackingList']").count, 1)

        // The two CPLs carry distinct titles and their own edit rates.
        var titles = Set<String>()
        var editRates = Set<String>()
        for cplURL in output.cplURLs {
            let cpl = try XMLDocument(contentsOf: cplURL, options: [])
            if let title = try cpl.nodes(forXPath: "//*[local-name()='ContentTitleText']").first?.stringValue {
                titles.insert(title)
            }
            if let rate = try cpl.nodes(forXPath: "//*[local-name()='MainPicture']/*[local-name()='EditRate']").first?.stringValue {
                editRates.insert(rate)
            }
        }
        XCTAssertEqual(titles, ["FilmOne", "FilmTwo"])
        XCTAssertEqual(editRates, ["24 1", "25 1"])

        // Every PKL hash matches the file actually on disk.
        for (name, sha1) in output.assetHashes {
            let url = folderURL.appendingPathComponent(name)
            XCTAssertEqual(try DCPPackage.sha1Base64(of: url), sha1, "hash for \(name)")
        }
    }

    func testMixedSoundAndSilentCompositions() throws {
        let withSound = try makeComposition(name: "Talkie", editRate: .fps24, hasSound: true, frames: 100)
        let silent = try makeComposition(name: "Silent", editRate: .fps24, hasSound: false, frames: 100)

        let output = try DCPPackage.writePackage(folderURL: folderURL,
                                                 compositions: [withSound, silent])

        // PKL: 2 pictures + 1 sound + 2 CPLs = 5.
        let pkl = try XMLDocument(contentsOf: output.pklURL, options: [])
        XCTAssertEqual(try pkl.nodes(forXPath: "//*[local-name()='Asset']").count, 5)

        // The silent CPL has no MainSound; the talkie does.
        var soundCounts: [Int] = []
        for cplURL in output.cplURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let cpl = try XMLDocument(contentsOf: cplURL, options: [])
            soundCounts.append(try cpl.nodes(forXPath: "//*[local-name()='MainSound']").count)
        }
        XCTAssertEqual(soundCounts.sorted(), [0, 1])
    }
}
