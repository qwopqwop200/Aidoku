import CoreGraphics
import Foundation

/// Atomic source/target revision admission, distinct from display-only joins.
/// The producer proves accepted-primary ancestry before translation. Rendering
/// rebinds exact new display targets, while removal retains every prior owner.
enum NativeMainSourceRevision {
    enum Failure: Error { case schema, ownership, target, geometry }
    struct Result {
        let removalItems: [[String: Any]]
        let transactions: [[String: Any]]
        let ownCapacityOwnerIDs: [String]
    }

    static func validate(_ revision: [String: Any], displayItems: [[String: Any]], imageSize: CGSize,
                         canonicalSourceIdentity: String? = nil,
                         localize: ([String: Any]) throws -> [String: Any], historyDepth: Int = 0) throws -> Result {
        let history = try NativeCumulativeSourceRevisionHistory.resolve(revision, imageSize: imageSize,
            canonicalSourceIdentity: canonicalSourceIdentity, depth: historyDepth, localize: localize)
        guard revision["requireOwnSourceCapacity"] == nil || revision["requireOwnSourceCapacity"] is Bool else { throw Failure.schema }
        let prior = history.validationItems
        guard let transactions = revision["transactions"] as? [[String: Any]],
              !transactions.isEmpty, transactions.count <= 64 else { throw Failure.schema }
        var consumed = Set<String>(), replacements = Set<String>()
        let priorIDs = prior.compactMap { $0["id"] as? String }
        guard Set(priorIDs).count == prior.count else { throw Failure.ownership }
        for transaction in transactions {
            guard let old = transaction["oldItems"] as? [[String: Any]], (1...16).contains(old.count),
                  let fresh = transaction["newItem"] as? [String: Any],
                  let id = fresh["id"] as? String, replacements.insert(id).inserted,
                  transaction["acceptedPrimaryUnionVerified"] as? Bool == true,
                  let source = transaction["correctedSource"] as? String, !source.isEmpty,
                  let target = fresh["text"] as? String, !target.isEmpty,
                  let before = transaction["primaryBefore"] as? [Int],
                  let after = transaction["primaryAfter"] as? [Int],
                  !before.isEmpty, Set(before) == Set(after), Set(before).count == before.count
            else { throw Failure.schema }
            if old.count == 1 {
                guard NativeCausalPacketColumnRevision.validates(transaction, old: old[0], fresh: fresh,
                    sourceIdentity: canonicalSourceIdentity, imageSize: imageSize) else { throw Failure.ownership }
            }
            for item in old {
                guard let owner = item["id"] as? String, consumed.insert(owner).inserted,
                      prior.contains(where: { NSDictionary(dictionary: $0).isEqual(to: item) })
                else { throw Failure.ownership }
            }
            let matches = displayItems.filter { $0["id"] as? String == id }
            guard matches.count == 1, matches[0]["text"] as? String == target,
                  let observed = matches[0]["sourceBounds"] as? [Double],
                  let expected = fresh["sourceBounds"] as? [Double], observed.count == 4, expected.count == 4,
                  zip(observed, expected).allSatisfy({ abs($0 - $1) < 1e-9 }) else { throw Failure.target }
            for item in old where item["id"] as? String != id {
                guard !displayItems.contains(where: { $0["id"] as? String == item["id"] as? String })
                else { throw Failure.ownership }
            }
        }
        let displayIDs = displayItems.compactMap { $0["id"] as? String }
        guard displayIDs.count == displayItems.count, Set(displayIDs).count == displayIDs.count,
              Set(displayIDs) == Set(priorIDs).subtracting(consumed).union(replacements) else { throw Failure.ownership }
        // Every unrelated original display owner must remain exactly unchanged.
        for item in prior where !consumed.contains(item["id"] as? String ?? "") {
            let matches = displayItems.filter { $0["id"] as? String == item["id"] as? String }
            let expected = try localize(item)
            guard matches.count == 1, NSDictionary(dictionary: matches[0]).isEqual(to: expected)
            else { throw Failure.target }
        }
        let localized = try history.removalItems.map(localize)
        for item in localized {
            guard let b = item["sourceBounds"] as? [Double], b.count == 4,
                  b.allSatisfy(\.isFinite), b[2] > 0, b[3] > 0,
                  b[0] >= 0, b[1] >= 0, b[0] + b[2] <= 1.000000001, b[1] + b[3] <= 1.000000001,
                  imageSize.width > 0, imageSize.height > 0 else { throw Failure.geometry }
        }
        guard history.priorTransactions.count + transactions.count <= 64 else { throw Failure.schema }
        let capacity = Set(history.priorCapacityNewOwnerIDs).subtracting(consumed).intersection(displayIDs).union(
            revision["requireOwnSourceCapacity"] as? Bool == true ? replacements : [])
        return Result(removalItems: localized, transactions: history.priorTransactions + transactions.map { row in
            ["oldOwnerIDs": (row["oldItems"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String },
             "newOwnerID": (row["newItem"] as? [String: Any])?["id"] ?? "",
             "correctedSource": row["correctedSource"] ?? "",
             "primaryBefore": row["primaryBefore"] ?? [], "primaryAfter": row["primaryAfter"] ?? [],
             "sourceAndTargetRevisionApplied": true, "originalRemovalOwnersRetained": true]
        }, ownCapacityOwnerIDs: capacity.sorted())
    }
}
