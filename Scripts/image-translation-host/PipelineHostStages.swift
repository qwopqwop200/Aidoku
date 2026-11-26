import Foundation

/// Stage checkpoints on disk (`--save-stages`, `--from-stages DIR --from S`): a later run reuses the
/// expensive stages before S and recomputes the rest. Per page, in OUTPUT/stages:
///   ID.front.json    S1-S4b (layout regions, S3 lines, S4 blocks, S4b blocks)
///   ID.erase.json    S6/S7 paint set, page size and the regions S7 writes
///   ID.removal.z     S6 mask, raw deflate of width x height bytes
///   ID.restored.z    S7 restored pixels of those regions (canonical RGBA, concatenated), raw deflate
/// Reuse is valid only while the reused stages, their models and their tuning knobs are unchanged.
enum PipelineHostStages {
    /// The first recomputed stage: s4 reuses S1-S3, s5 S1-S4b, s7 also the S6 mask, s8 also the S7 restore.
    enum Resume: String, CaseIterable { case s4, s5, s7, s8 }

    private struct EraseMeta: Codable {
        var paintable: [Int]
        var width: Int
        var height: Int
        var regions: [[Int]]
    }

    static func directory(_ run: URL) -> URL { run.appendingPathComponent("stages") }

    /// The saved checkpoints of one page up to `resume` (missing files: those stages recompute).
    static func load(_ run: URL, pageID: String, resume: Resume) -> PipelineCheckpoints {
        let directory = directory(run)
        var front = (try? Data(contentsOf: directory.appendingPathComponent(pageID + ".front.json")))
            .flatMap { try? JSONDecoder().decode(PipelineCheckpoints.Front.self, from: $0) }
        if resume == .s4 {
            front?.classified = nil
            front?.blocks = nil
            return PipelineCheckpoints(front: front?.recognized == nil ? nil : front)
        }
        guard resume != .s5, let meta = (try? Data(contentsOf: directory.appendingPathComponent(pageID + ".erase.json")))
                .flatMap({ try? JSONDecoder().decode(EraseMeta.self, from: $0) }),
              let removal = inflate(directory.appendingPathComponent(pageID + ".removal.z")),
              removal.count == meta.width * meta.height else {
            return PipelineCheckpoints(front: front)
        }
        var restored: [PipelineBackgroundPatch]?
        if resume == .s8, let bytes = inflate(directory.appendingPathComponent(pageID + ".restored.z")) {
            var patches: [PipelineBackgroundPatch] = []
            var offset = 0
            for region in meta.regions where region.count == 4 {
                let count = region[2] * region[3] * 4
                guard offset + count <= bytes.count else { break }
                patches.append(PipelineBackgroundPatch(rect: CGRect(x: region[0], y: region[1], width: region[2], height: region[3]),
                                                 rgba: Array(bytes[offset..<offset + count])))
                offset += count
            }
            if offset == bytes.count, patches.count == meta.regions.count { restored = patches }
        }
        return PipelineCheckpoints(front: front, erase: .init(paintable: meta.paintable, removal: Array(removal), restored: restored))
    }

    /// Writes the checkpoints this page used or produced.
    static func save(_ checkpoints: PipelineCheckpoints, run: URL, pageID: String, width: Int, height: Int) throws {
        let directory = directory(run)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if var front = checkpoints.front ?? checkpoints.savedFront {
            if front.recognized == nil { front.recognized = checkpoints.savedFront?.recognized }
            try JSONEncoder().encode(front).write(to: directory.appendingPathComponent(pageID + ".front.json"))
        }
        guard let erase = checkpoints.erase, erase.removal.count == width * height, let restored = erase.restored else { return }
        let meta = EraseMeta(paintable: erase.paintable, width: width, height: height,
                             regions: restored.map { [Int($0.rect.minX), Int($0.rect.minY), Int($0.rect.width), Int($0.rect.height)] })
        try JSONEncoder().encode(meta).write(to: directory.appendingPathComponent(pageID + ".erase.json"))
        try deflate(Data(erase.removal)).write(to: directory.appendingPathComponent(pageID + ".removal.z"))
        var pixels = Data()
        for patch in restored { pixels.append(contentsOf: patch.rgba) }
        try deflate(pixels).write(to: directory.appendingPathComponent(pageID + ".restored.z"))
    }

    private static func deflate(_ data: Data) throws -> Data { try (data as NSData).compressed(using: .zlib) as Data }

    private static func inflate(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? (data as NSData).decompressed(using: .zlib) as Data
    }
}
