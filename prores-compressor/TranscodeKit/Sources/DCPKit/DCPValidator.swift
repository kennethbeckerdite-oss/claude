import Foundation
import TranscodeKit

/// Post-export self-check. Independent of the writing code path where
/// possible: it re-reads the XML from disk, re-hashes every asset against
/// the PKL, cross-checks CPL ↔ PKL ↔ ASSETMAP, and re-opens both MXFs
/// through asdcplib's reader.
public enum DCPValidator {
    public struct Report {
        public let frameCount: Int
        public let checkedAssets: Int
    }

    @discardableResult
    public static func validate(folderURL: URL, expectedContainer: DCPContainer,
                                expectSound: Bool) throws -> Report {
        let assetMapURL = folderURL.appendingPathComponent("ASSETMAP.xml")
        guard FileManager.default.fileExists(atPath: assetMapURL.path) else {
            throw ExportError.validationFailed("ASSETMAP.xml is missing")
        }
        guard FileManager.default.fileExists(atPath: folderURL.appendingPathComponent("VOLINDEX.xml").path) else {
            throw ExportError.validationFailed("VOLINDEX.xml is missing")
        }

        let assetMap = try xmlDocument(at: assetMapURL)
        let mapAssets = try nodes(assetMap, "//*[local-name()='AssetMap']/*[local-name()='AssetList']/*[local-name()='Asset']")
        guard !mapAssets.isEmpty else {
            throw ExportError.validationFailed("ASSETMAP.xml lists no assets")
        }

        // Id → file URL from the asset map; find the PKL along the way.
        var fileByUUID: [String: URL] = [:]
        var pklURL: URL?
        for asset in mapAssets {
            guard let id = try firstString(asset, "*[local-name()='Id']"),
                  let path = try firstString(asset, ".//*[local-name()='Path']") else {
                throw ExportError.validationFailed("ASSETMAP entry is missing Id or Path")
            }
            let url = folderURL.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ExportError.validationFailed("missing file listed in ASSETMAP: \(path)")
            }
            fileByUUID[normalize(id)] = url
            if try firstString(asset, "*[local-name()='PackingList']") == "true" {
                pklURL = url
            }
        }
        guard let pklURL else {
            throw ExportError.validationFailed("ASSETMAP.xml does not point at a packing list")
        }

        // PKL: every asset must exist, match its size, and match its hash.
        let pkl = try xmlDocument(at: pklURL)
        let pklAssets = try nodes(pkl, "//*[local-name()='PackingList']/*[local-name()='AssetList']/*[local-name()='Asset']")
        guard !pklAssets.isEmpty else {
            throw ExportError.validationFailed("PKL lists no assets")
        }
        var checked = 0
        for asset in pklAssets {
            guard let id = try firstString(asset, "*[local-name()='Id']"),
                  let expectedHash = try firstString(asset, "*[local-name()='Hash']"),
                  let expectedSizeText = try firstString(asset, "*[local-name()='Size']"),
                  let expectedSize = Int64(expectedSizeText) else {
                throw ExportError.validationFailed("PKL entry is missing Id, Hash, or Size")
            }
            guard let url = fileByUUID[normalize(id)] else {
                throw ExportError.validationFailed("PKL asset \(id) is not in the ASSETMAP")
            }
            let actualSize = try DCPPackage.fileSize(url)
            guard actualSize == expectedSize else {
                throw ExportError.validationFailed(
                    "\(url.lastPathComponent): size \(actualSize) ≠ PKL size \(expectedSize)")
            }
            let actualHash = try DCPPackage.sha1Base64(of: url)
            guard actualHash == expectedHash else {
                throw ExportError.validationFailed("\(url.lastPathComponent): hash mismatch — file corrupt or modified")
            }
            checked += 1
        }

        // CPL: assets must resolve, durations must agree with the MXFs.
        guard let cplURL = fileByUUID.values.first(where: { $0.lastPathComponent.hasPrefix("CPL_") }) else {
            throw ExportError.validationFailed("no CPL in the ASSETMAP")
        }
        let cpl = try xmlDocument(at: cplURL)
        guard let pictureId = try firstString(cpl, "//*[local-name()='MainPicture']/*[local-name()='Id']"),
              let pictureDurationText = try firstString(cpl, "//*[local-name()='MainPicture']/*[local-name()='Duration']"),
              let cplDuration = Int(pictureDurationText) else {
            throw ExportError.validationFailed("CPL has no readable MainPicture")
        }
        guard let pictureURL = fileByUUID[normalize(pictureId)] else {
            throw ExportError.validationFailed("CPL MainPicture \(pictureId) is not in the ASSETMAP")
        }

        let pictureInfo = try J2KTrackInfo.read(url: pictureURL)
        guard pictureInfo.frameCount == cplDuration else {
            throw ExportError.validationFailed(
                "picture MXF has \(pictureInfo.frameCount) frames but the CPL says \(cplDuration)")
        }
        guard pictureInfo.editRate == (24, 1) else {
            throw ExportError.validationFailed("picture MXF edit rate is not 24/1")
        }
        guard pictureInfo.storedWidth == expectedContainer.width,
              pictureInfo.storedHeight == expectedContainer.height else {
            throw ExportError.validationFailed(
                "picture is \(pictureInfo.storedWidth)×\(pictureInfo.storedHeight), expected \(expectedContainer.width)×\(expectedContainer.height)")
        }
        guard normalize("urn:uuid:" + pictureInfo.assetUUID.uuidString) == normalize(pictureId) else {
            throw ExportError.validationFailed("picture MXF asset UUID does not match the CPL")
        }

        let soundId = try firstString(cpl, "//*[local-name()='MainSound']/*[local-name()='Id']")
        if expectSound {
            guard let soundId, let soundURL = fileByUUID[normalize(soundId)] else {
                throw ExportError.validationFailed("CPL is missing the MainSound asset")
            }
            let soundInfo = try PCMTrackInfo.read(url: soundURL)
            guard soundInfo.frameCount == cplDuration else {
                throw ExportError.validationFailed(
                    "audio MXF has \(soundInfo.frameCount) frames but the CPL says \(cplDuration)")
            }
            guard soundInfo.channelCount == AudioConformer.channelCount,
                  soundInfo.quantizationBits == 24,
                  soundInfo.sampleRate == AudioConformer.sampleRate else {
                throw ExportError.validationFailed(
                    "audio MXF is \(soundInfo.channelCount)ch/\(soundInfo.quantizationBits)-bit/\(soundInfo.sampleRate)Hz, expected 6ch/24-bit/48000Hz")
            }
            guard normalize("urn:uuid:" + soundInfo.assetUUID.uuidString) == normalize(soundId) else {
                throw ExportError.validationFailed("audio MXF asset UUID does not match the CPL")
            }
        }

        return Report(frameCount: cplDuration, checkedAssets: checked)
    }

    // MARK: - XML helpers

    private static func xmlDocument(at url: URL) throws -> XMLDocument {
        do {
            return try XMLDocument(contentsOf: url, options: [])
        } catch {
            throw ExportError.validationFailed(
                "\(url.lastPathComponent) is not well-formed XML: \(error.localizedDescription)")
        }
    }

    private static func nodes(_ node: XMLNode, _ xpath: String) throws -> [XMLNode] {
        do {
            return try node.nodes(forXPath: xpath)
        } catch {
            throw ExportError.validationFailed("XPath \(xpath) failed: \(error.localizedDescription)")
        }
    }

    private static func firstString(_ node: XMLNode, _ xpath: String) throws -> String? {
        try nodes(node, xpath).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalize(_ urn: String) -> String {
        urn.lowercased().replacingOccurrences(of: "urn:uuid:", with: "")
    }
}
