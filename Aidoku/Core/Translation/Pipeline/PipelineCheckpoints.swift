import Foundation

/// Host-only stage checkpoints of one page (the app never sets them): saved outputs to reuse instead of
/// recomputing, and the ones this run produced. Reuse is only valid while the stages before the
/// resumed one, their models and their `PipelineTuning` knobs are unchanged.
final class PipelineCheckpoints: @unchecked Sendable {
    /// S1-S4b: layout regions, the S4 blocks S5 reads and the S4b blocks.
    struct Front: Codable, Sendable {
        var layout: [PipelineLayoutRegion]
        var classified: [PipelineBlock]
        var blocks: [PipelineBlock]
    }
    /// S6 removal mask (page-sized, nonzero = erase) for one paint set, and S7's restored pixels of the
    /// regions it writes (lossless; nil when only the mask is reused).
    struct Erase: Sendable {
        var paintable: [Int]
        var removal: [UInt8]
        var restored: [PipelineBackgroundPatch]?
    }

    let savedFront: Front?
    let savedErase: Erase?
    private let lock = NSLock()
    private var recordedFront: Front?
    private var recordedErase: Erase?

    init(front: Front? = nil, erase: Erase? = nil) {
        savedFront = front
        savedErase = erase
    }

    var front: Front? { lock.withLock { recordedFront } }
    var erase: Erase? { lock.withLock { recordedErase } }

    func record(front: Front) { lock.withLock { recordedFront = front } }
    func record(erase: Erase) { lock.withLock { recordedErase = erase } }

    /// The saved erase of this paint set, if any.
    func savedErase(for paintable: [PipelineBlock]) -> Erase? {
        guard let savedErase, savedErase.paintable == paintable.map(\.id) else { return nil }
        return savedErase
    }
}
