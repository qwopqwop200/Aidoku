import CoreGraphics
import Foundation

/// A failed complete-page admission may try one current caller-width hint per
/// explicit owner. No font fitting, historical widths, owner removal or grid.
enum NativeSimpleFinalWidthFallback {
    static let version = "source-plus-caller-width-final-v7"
    @TaskLocal private static var enabledOverride: Bool?
    static var enabled: Bool {
        NativeSimpleTextLayout.widthFitEnabled &&
            (enabledOverride ?? NativeSimpleTextLayout.enabledUnlessZero("AIDOKU_SIMPLE_FINAL_WIDTH_FALLBACK"))
    }
    static func withEnabled<Value>(_ enabled: Bool, operation: () throws -> Value) rethrows -> Value {
        try $enabledOverride.withValue(enabled, operation: operation)
    }

    struct CallerWidth {
        let pixels: CGFloat
        let authority: String
    }
    enum InputFailure: Error { case invalidCallerWidth, invalidOwnerInventory }
    static func callerWidth(frameOutputWidth: CGFloat, slotNormalized: [Double]?, pageOutputWidth: CGFloat) throws -> CallerWidth {
        guard frameOutputWidth.isFinite, frameOutputWidth > 0, pageOutputWidth.isFinite, pageOutputWidth > 0 else {
            throw InputFailure.invalidCallerWidth
        }
        if let slotNormalized {
            guard slotNormalized.count == 4, slotNormalized.allSatisfy(\.isFinite),
                  slotNormalized[2] > 0, slotNormalized[3] > 0 else { throw InputFailure.invalidCallerWidth }
            let width = CGFloat(slotNormalized[2]) * pageOutputWidth
            guard width.isFinite, width > 0 else { throw InputFailure.invalidCallerWidth }
            return CallerWidth(pixels: width, authority: "current-caller-balloon-layout-slot;not-historical-retained-width")
        }
        return CallerWidth(pixels: frameOutputWidth, authority: "current-caller-item-frame;not-historical-retained-width")
    }

    struct Receipt {
        let changedOwners: [String]
        let attempts: [[String: Any]]
        let outcome: String
        var audit: [String: Any] {
            ["version": version, "changedOwners": changedOwners, "attempts": attempts, "outcome": outcome,
             "firstCompletePageAttemptUnchanged": true, "maximumWidthsPerOwner": 2,
             "fontChanged": false, "ownersDropped": 0,
             "widthAuthority": "current caller slot/frame hint;historical cached-width experiment is algorithm evidence only"]
        }
    }
    struct Failure: Error {
        let cause: Error
        let receipt: Receipt
    }

    static func nextOwner(_ encoded: String, owners: [String], eligible: Set<String>, changed: Set<String>) -> String? {
        let implicated: Set<String>
        if owners.contains(encoded) { implicated = [encoded] }
        else {
            let parts = encoded.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard !parts.isEmpty, parts.allSatisfy({ owners.contains($0) }) else { return nil }
            implicated = Set(parts)
        }
        return owners.first { implicated.contains($0) && eligible.contains($0) && !changed.contains($0) }
    }

    /// Called only AFTER the identical first full-page attempt has failed.
    static func recover<Value>(initialFailure: Error, owners: [String], eligible: Set<String>,
                               cause: (Error) -> String?, replace: (String) throws -> Bool,
                               attempt: () throws -> Value) throws -> (value: Value, receipt: Receipt) {
        guard Set(owners).count == owners.count, eligible.isSubset(of: Set(owners)) else {
            throw InputFailure.invalidOwnerInventory
        }
        var changed = Set<String>()
        var attempts: [[String: Any]] = [["attempt": 0, "outcome": "original-complete-page-noSafePlacement",
            "failure": String(describing: initialFailure), "ownerDenominator": owners.count]]
        var lastError = initialFailure
        for index in 0..<eligible.count {
            try Task.checkCancellation()
            guard let encoded = cause(lastError),
                  let owner = nextOwner(encoded, owners: owners, eligible: eligible, changed: changed) else { break }
            do {
                guard try replace(owner) else { break }
                changed.insert(owner)
                let value = try attempt()
                attempts.append(["attempt": index + 1, "changedOwner": owner,
                    "outcome": "complete-page-paint-and-final-verification-passed", "ownerDenominator": owners.count])
                return (value, Receipt(changedOwners: changed.sorted(), attempts: attempts, outcome: "admitted"))
            } catch {
                if error is CancellationError { throw error }
                lastError = error
                attempts.append(["attempt": index + 1, "changedOwner": owner, "outcome": "complete-page-or-shape-failure",
                    "failure": String(describing: error), "ownerDenominator": owners.count])
                if !changed.contains(owner) { break }
            }
        }
        throw Failure(cause: lastError, receipt: Receipt(changedOwners: changed.sorted(), attempts: attempts,
            outcome: "explicit-unresolved;original-recovery-remains-authoritative"))
    }
}
