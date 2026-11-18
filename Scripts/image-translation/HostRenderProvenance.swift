import CryptoKit
import Foundation

/// Bind a saved raster to the actual launcher build and encoded input bytes.
/// A successful render is not a visual-quality or model-weight validation.
enum HostRenderProvenance {
    static func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fingerprint(_ environment: [String: String]) -> String? {
        guard let value = environment["AIDOKU_PIPELINE_FINGERPRINT"], value.count == 64,
              value.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return value
    }

    static func directMainPNGRequested(_ environment: [String: String]) -> Bool {
        environment["AIDOKU_REPLAY_PNG_ONLY"] == "1" && (environment["AIDOKU_PNG_DIRECT_MAIN"] ?? "1") == "1"
    }

    static func write(directory: URL, sourceURL: URL?, payloadURL: URL?,
                      effectivePayload: [String: Any], environment: [String: String]) throws {
        let encoded = try JSONSerialization.data(withJSONObject: effectivePayload, options: [.sortedKeys])
        let value: [String: Any] = [
            "schemaVersion": 1,
            "pipelineFingerprint": fingerprint(environment) as Any? ?? NSNull(),
            "pipelineFingerprintAuthority": "launcher source/kernel/build identity; not model-weight identity or quality",
            "encodedSourceSHA256": try sourceURL.map(fileSHA256) as Any? ?? NSNull(),
            "encodedPayloadSHA256": try payloadURL.map(fileSHA256) as Any? ?? NSNull(),
            "effectivePayloadSHA256": SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined(),
            "effectivePayloadAuthority": "Swift sorted-key JSON of actual renderer arguments; not cross-language canonical JSON",
            "finalPNGFileSHA256": try fileSHA256(directory.appendingPathComponent("final.png")),
            "parameterOverridesFileSHA256": try environment["AIDOKU_ENSEMBLE_PARAMETERS"]
                .map { try fileSHA256(URL(fileURLWithPath: $0)) } as Any? ?? NSNull(),
            "pngOnlyPersistence": environment["AIDOKU_REPLAY_PNG_ONLY"] == "1",
            "directMainPNGRequested": directMainPNGRequested(environment),
            "qualityAccepted": false, "deviceMeasured": false
        ]
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("render-provenance.json"), options: .atomic)
    }
}
