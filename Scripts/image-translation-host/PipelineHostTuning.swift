import CryptoKit
import Foundation

/// AIDOKU_PIPELINE_TUNING for the host: a JSON object of `PipelineTuning` field: number, inline
/// (starting with "{") or as a file path. Unknown fields are an error, so a typo cannot pass as a default.
enum PipelineHostTuning {
    static func apply(_ setting: String?) throws {
        guard let setting, !setting.isEmpty else { return }
        let text = setting.hasPrefix("{") ? setting : try String(contentsOfFile: setting, encoding: .utf8)
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw PipelineHostError("AIDOKU_PIPELINE_TUNING must be a JSON object")
        }
        var tuning = PipelineTuning()
        for (key, raw) in object {
            guard let value = (raw as? NSNumber)?.doubleValue, value.isFinite else {
                throw PipelineHostError("AIDOKU_PIPELINE_TUNING \(key): not a number")
            }
            guard tuning.set(key, value) else {
                throw PipelineHostError("AIDOKU_PIPELINE_TUNING: unknown field \(key) (known: \(PipelineTuning.keys.joined(separator: ", ")))")
            }
        }
        PipelineTuning.current = tuning
    }

    /// The fields that differ from the defaults, "key=value" joined.
    static func describe(_ tuning: PipelineTuning) -> String {
        let defaults = PipelineTuning().values
        let changed = tuning.values.filter { defaults[$0.key] != $0.value }.sorted { $0.key < $1.key }
        return changed.isEmpty ? "defaults" : changed.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }

    /// Writes every page's S6 mask as DIR/ID.z (raw deflate of width x height bytes) and DIR/ID.json
    /// ({w, h, ids}), the layout port-eval/convmask/tools/mscore.py scores.
    static func dumpMasks(into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        TranslationPipeline.removalObserver = { id, width, height, mask, ids in
            guard let packed = try? (Data(mask) as NSData).compressed(using: .zlib) as Data else { return }
            try? packed.write(to: directory.appendingPathComponent(id + ".z"))
            let meta: [String: Any] = ["w": width, "h": height, "ids": ids]
            try? JSONSerialization.data(withJSONObject: meta).write(to: directory.appendingPathComponent(id + ".json"))
        }
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
