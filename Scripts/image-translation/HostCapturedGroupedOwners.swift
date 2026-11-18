import CoreGraphics
import Foundation

@available(macOS 15.0, *)
extension HostSavedOCRReplay {
    /// The Reader cohort was observed BEFORE source-mask construction. Its
    /// authenticated module artifact therefore remains usable when the later
    /// source factory fails. No final.json or successful source output is faked.
    static func loadCapturedGroupedOwners(from directory: URL, expectedInput: URL, original: CGImage,
                                         expected: HostModuleBank.Contract,
                                         expectedGroupedArtifactSHA256: String) throws -> [ReaderTranslationRegion] {
        let page = try HostObservedOCRReplay.load(directory: directory, sourceURL: expectedInput, original: original, expected: expected)
        guard let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("module-bank.json"))) as? [String: Any],
              let artifacts = manifest["artifacts"] as? [[String: Any]],
              let availability = manifest["availability"] as? [String: [String: Any]],
              availability["actualGroupedRegions"]?["status"] as? String == "observed" else { throw CocoaError(.coderReadCorrupt) }
        let matches = artifacts.filter { $0["stage"] as? String == "actualGroupedRegions" }
        guard matches.count == 1, let path = matches[0]["path"] as? String, !path.hasPrefix("/"),
              !path.split(separator: "/").contains(".."), matches[0]["SHA256"] as? String == expectedGroupedArtifactSHA256 else {
            throw CocoaError(.coderReadCorrupt)
        }
        let file = directory.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"),
              try HostSavedOCRIdentity.fileSHA256(file) == expectedGroupedArtifactSHA256,
              let records = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]],
              records.count == availability["actualGroupedRegions"]?["records"] as? Int,
              records.count <= 4096 else { throw CocoaError(.coderReadCorrupt) }
        var regions: [ReaderTranslationRegion] = []
        for record in records {
            let saved = try HostTaggedObservationDecoder.decode(Region.self, value: record, blob: { value in
                // HostDump's observed Reader JSON has exact base64 Data leaves;
                // it is not a reconstruction from image/geometry.
                guard let data = value as? [String: String], let base64 = data["base64"],
                      let bytes = Data(base64Encoded: base64) else { throw CocoaError(.coderReadCorrupt) }
                return bytes
            })
            var region = saved.native
            region.acceptedSource = try page.restoringCapturedMetadata(record["acceptedSource"] as Any)
            regions.append(region)
        }
        guard Set(regions.map(\.id)).count == regions.count else { throw CocoaError(.coderReadCorrupt) }
        return regions
    }
}
