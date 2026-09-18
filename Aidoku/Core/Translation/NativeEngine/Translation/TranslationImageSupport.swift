import CryptoKit
import Foundation

/// Shared by connection probes, reader batches and translated downloads. Persist
/// only capability metadata, never credentials, images or provider error bodies.
final class TranslationImageSupport: @unchecked Sendable {
    static let shared = TranslationImageSupport()
    static let changed = Notification.Name("TranslationImageSupport.changed")

    enum Status: String { case unknown, supported, unsupported }
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func status(for configuration: RemoteTranslationConfiguration) -> Status {
        lock.lock()
        defer { lock.unlock() }
        return Status(rawValue: defaults.string(forKey: key(configuration)) ?? "") ?? .unknown
    }

    func revision(for configuration: RemoteTranslationConfiguration) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return defaults.integer(forKey: key(configuration) + ".revision")
    }

    func record(_ status: Status, for configuration: RemoteTranslationConfiguration) {
        lock.lock()
        let key = key(configuration)
        let old = Status(rawValue: defaults.string(forKey: key) ?? "") ?? .unknown
        guard old != status else { lock.unlock(); return }
        // Reject text-only fallback caches when an explicit retest restores
        // image support. Unknown -> supported does not change request semantics.
        if old == .unsupported || status == .unsupported {
            defaults.set(defaults.integer(forKey: key + ".revision") + 1, forKey: key + ".revision")
        }
        defaults.set(status.rawValue, forKey: key)
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    private func key(_ configuration: RemoteTranslationConfiguration) -> String {
        let fields = [configuration.provider.rawValue, configuration.apiProtocol.rawValue,
            (try? configuration.validatedEndpoint().absoluteString) ?? configuration.baseURL,
            configuration.model, configuration.credentialAccount, String(configuration.credentialGeneration)]
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return "Reader.translation.imageSupport.v1." + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isUnsupportedResponse(status: Int, body: Data) -> Bool {
        guard [400, 415, 422].contains(status),
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        let error = root["error"] as? [String: Any] ?? root
        let code = (error["code"] as? String ?? "").lowercased()
        if ["image_input_not_supported", "unsupported_image_input", "vision_not_supported"].contains(code) {
            return true
        }
        let message = ((error["message"] as? String) ?? (root["error"] as? String) ?? "").lowercased()
        let parameter = (error["param"] as? String ?? "").lowercased()
        // A malformed/oversized image does not establish model capability.
        if ["image format", "image size", "image dimensions", "image resolution", "invalid image", "image data",
            "base64", "download", "too large"].contains(where: { message.contains($0) }) {
            return false
        }
        let mentionsImage = ["image", "vision", "multimodal"].contains { message.contains($0) || parameter.contains($0) }
        let rejectsInput = ["does not support", "doesn't support", "not support", "unsupported", "only supported",
            "text-only", "text only", "only supports text", "not a vision model"].contains { message.contains($0) }
        return mentionsImage && rejectsInput
    }
}
