import Foundation

/// Original page allocation and admission for represented small-text references.
/// Paragraph references must be supplied by their generating stage before admission.
struct NativeReferenceRecoveryBudget {
    struct Reference {
        var length: Int
        var fontSize: Double?
        var paddingIsValid: Bool
    }
    private(set) var refinementRemaining = 16384
    private(set) var readableRemaining: Int

    init(references: [Reference], readableRemaining: Int? = nil) {
        let emergency = references.reduce(0) { total, reference in
            total + (reference.length <= 512 && (reference.fontSize ?? .infinity) < 8 ? reference.length : 0)
        }
        self.readableRemaining = readableRemaining ?? min(2048, max(0, refinementRemaining - emergency))
    }

    mutating func admit(_ reference: Reference) -> Bool {
        guard let font = reference.fontSize, font.isFinite, reference.paddingIsValid else { return false }
        let emergency = font < 8
        guard reference.length <= 512, reference.length <= refinementRemaining,
              emergency || reference.length <= readableRemaining else { return false }
        refinementRemaining -= reference.length
        if !emergency { readableRemaining -= reference.length }
        return true
    }
}
