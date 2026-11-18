import CoreGraphics
import CryptoKit
import Foundation

/// Bounded replay of a previously admitted source transaction. The embedded
/// previous packet is hash-bound byte-for-byte, then independently validated;
/// a trusted boolean never substitutes for its ancestry/target/geometry guards.
enum NativeCumulativeSourceRevisionHistory {
    struct State {
        let validationItems: [[String: Any]]
        let removalItems: [[String: Any]]
        let priorTransactions: [[String: Any]]
        let priorCapacityNewOwnerIDs: [String]
    }

    static func resolve(_ revision: [String: Any], imageSize: CGSize,
        canonicalSourceIdentity: String?, depth: Int,
        localize: ([String: Any]) throws -> [String: Any]) throws -> State {
        typealias Failure = NativeMainSourceRevision.Failure
        guard depth < 8, let ultimate = revision["originalRemovalItems"] as? [[String: Any]],
              ultimate.count <= 4096 else { throw Failure.schema }
        if revision["version"] as? Int == 1 {
            return State(validationItems: ultimate, removalItems: ultimate, priorTransactions: [], priorCapacityNewOwnerIDs: [])
        }
        guard revision["version"] as? Int == 2,
              let source = revision["sourceSHA256"] as? String, source.utf8.count == 64,
              let display = revision["priorDisplayItems"] as? [[String: Any]], display.count <= 4096,
              let proof = revision["priorRevisionProof"] as? [String: Any],
              let artifact = proof["artifact"] as? String, !artifact.isEmpty,
              let payload = proof["canonicalPayloadArtifact"] as? String, !payload.isEmpty,
              let payloadHash = proof["canonicalPayloadSHA256"] as? String, payloadHash.utf8.count == 64,
              let hash = proof["fileSHA256"] as? String,
              let text = proof["packetJSON"] as? String, let bytes = text.data(using: .utf8),
              bytes.count <= 2 * 1024 * 1024,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == hash,
              let previous = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              previous["sourceSHA256"] as? String == source,
              let original = previous["originalRemovalItems"] as? [[String: Any]],
              NSArray(array: original).isEqual(to: ultimate) else { throw Failure.schema }
        // Earlier versions checked new text/bounds only. A subsequent revision
        // must preserve the ENTIRE previously admitted target/style descriptor.
        guard let priorTransactions = previous["transactions"] as? [[String: Any]] else { throw Failure.schema }
        for transaction in priorTransactions {
            guard let fresh = transaction["newItem"] as? [String: Any], let id = fresh["id"] as? String else { throw Failure.schema }
            let matches = display.filter { $0["id"] as? String == id }
            guard matches.count == 1,
                  NSDictionary(dictionary: try localize(matches[0])).isEqual(to: try localize(fresh)) else { throw Failure.target }
        }
        let verified = try NativeMainSourceRevision.validate(previous, displayItems: display.map(localize),
            imageSize: imageSize, canonicalSourceIdentity: canonicalSourceIdentity,
            localize: localize, historyDepth: depth + 1)
        guard verified.transactions.count <= 64,
              NSArray(array: verified.removalItems).isEqual(to: try ultimate.map(localize)) else { throw Failure.ownership }
        return State(validationItems: display, removalItems: ultimate, priorTransactions: verified.transactions,
            priorCapacityNewOwnerIDs: verified.ownCapacityOwnerIDs)
    }
}
