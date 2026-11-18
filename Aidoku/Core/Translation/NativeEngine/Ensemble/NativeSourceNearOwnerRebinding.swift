import Foundation

/// Remap positional source-near references after a permutation of unchanged
/// paragraph owners. This never merges sentences or relaxes geometry guards.
enum NativeSourceNearOwnerRebinding {
    struct Result {
        let items: [[String: Any]]
        let audit: [String: Any]
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue.rounded(.down) == n.doubleValue,
              n.doubleValue >= 0, n.doubleValue <= 4096 else { return nil }
        return n.intValue
    }
    static func apply(before: [[String: Any]], after: [[String: Any]]) -> Result {
        func unchanged(_ reason: String) -> Result {
            Result(items: after, audit: ["status":"unresolved-input-retained", "reason":reason,
                "bindingRepaired":false, "geometryRelaxed":false])
        }
        guard before.count == after.count, before.count <= 4096 else { return unchanged("not-a-bounded-permutation") }
        let oldIDs = before.compactMap { $0["id"] as? String }
        let newIDs = after.compactMap { $0["id"] as? String }
        guard oldIDs.count == before.count, newIDs.count == after.count,
              Set(oldIDs).count == before.count, Set(newIDs) == Set(oldIDs), !oldIDs.contains("") else {
            return unchanged("ambiguous-or-changed-owner-identity")
        }
        guard oldIDs != newIDs else {
            return Result(items: after, audit:["status":"identity-permutation-no-change","changedItems":0])
        }
        let newIndex = Dictionary(uniqueKeysWithValues: newIDs.enumerated().map { ($0.element,$0.offset) })
        let oldIndex = Dictionary(uniqueKeysWithValues: oldIDs.enumerated().map { ($0.element,$0.offset) })
        let remap = oldIDs.map { newIndex[$0]! }
        var output = after, changed = 0, references = 0
        for newPosition in after.indices {
            let oldPosition = oldIndex[newIDs[newPosition]]!
            let old = before[oldPosition], current = after[newPosition]
            guard NSDictionary(dictionary:["source":old["sourceBounds"] ?? NSNull()]).isEqual(to:
                ["source":current["sourceBounds"] ?? NSNull()]) else { return unchanged("source-owner-geometry-changed") }
            guard let raw = current["sourceNearLayout"] else {
                if old["sourceNearLayout"] != nil { return unchanged("source-contract-removed") }
                continue
            }
            guard var contract = raw as? [String: Any], let oldContract = old["sourceNearLayout"] as? [String: Any],
                  NSDictionary(dictionary:contract).isEqual(to:oldContract), NativeSourceNearVerticalAnchor.parse(contract) != nil,
                  integer(contract["outputIndex"]) == oldPosition,
                  let neighbors = contract["protectedNeighbors"] as? [[String: Any]] else {
                return unchanged("contract-changed-or-not-bound-to-original-slot")
            }
            var updatedNeighbors: [[String: Any]] = []
            for var neighbor in neighbors {
                guard let index = integer(neighbor["itemIndex"]), before.indices.contains(index), index != oldPosition else {
                    return unchanged("invalid-neighbor-slot")
                }
                if let declared = neighbor["itemID"] as? String, declared != oldIDs[index] {
                    return unchanged("neighbor-owner-id-mismatch")
                }
                if let declared = neighbor["paragraphOwnerKey"] as? String,
                   let actual = (before[index]["sourceNearLayout"] as? [String: Any])?["paragraphOwnerKey"] as? String,
                   declared != actual { return unchanged("neighbor-paragraph-key-mismatch") }
                neighbor["itemIndex"] = remap[index]
                if index != remap[index] { references += 1 }
                updatedNeighbors.append(neighbor)
            }
            if let rawConflicts = contract["conflictingSourceIndices"] {
                guard let values = rawConflicts as? [Any] else { return unchanged("invalid-conflict-list") }
                let indices = values.compactMap(integer)
                guard indices.count == values.count, indices.allSatisfy(before.indices.contains) else {
                    return unchanged("invalid-conflict-owner-slot")
                }
                contract["conflictingSourceIndices"] = indices.map { remap[$0] }
            }
            contract["outputIndex"] = newPosition
            contract["protectedNeighbors"] = updatedNeighbors
            if !NSDictionary(dictionary:contract).isEqual(to:oldContract) { changed += 1 }
            output[newPosition]["sourceNearLayout"] = contract
        }
        return Result(items:output,audit:["status":"source-owner-permutation-rebound","changedItems":changed,
            "neighborReferencesRemapped":references,"bindingRepaired":true,"geometryRelaxed":false,
            "sourceAndParagraphKeysUnchanged":true,"textMerged":false])
    }
}
