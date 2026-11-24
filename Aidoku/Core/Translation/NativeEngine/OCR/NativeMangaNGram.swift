import Foundation

/// Official manga_lm3 numeric tables with a local, visually gated arbiter.
/// No GT, page identity, remote calls or generated language-model text.
final class NativeMangaNGram: @unchecked Sendable {
    enum Failure: Error { case malformedData }
    struct Choice {
        let text: String
        let probability: Double
    }
    struct Correction {
        let choices: [Choice]
        let changedTokens: Int
    }
    private let ids: [String: UInt64]
    private let gramKeys: [UInt64]
    private let gramValues: [Float16]
    private let contextKeys: [UInt64]
    private let contextValues: [Float16]
    private let vocabularySize: Int

    init(data: Data) throws {
        guard data.count >= 28, data.count <= 32 * 1_048_576,
              data.prefix(8) == Data("MNG3DATA".utf8) else { throw Failure.malformedData }
        var offset = 8
        func integer<T: FixedWidthInteger>(_ type: T.Type) -> T {
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
            offset += MemoryLayout<T>.size
            return T(littleEndian: value)
        }
        let version = integer(UInt32.self), order = integer(UInt32.self)
        let v = Int(integer(UInt32.self)), g = Int(integer(UInt32.self)), c = Int(integer(UInt32.self))
        guard version == 1, order == 3, (3..<4096).contains(v), g <= 1_000_000, c <= 500_000,
              data.count == 28 + 4 * v + 10 * g + 10 * c else { throw Failure.malformedData }
        var characters: [String: UInt64] = [:]
        for index in 0..<v {
            guard let scalar = UnicodeScalar(integer(UInt32.self)) else { throw Failure.malformedData }
            characters[String(scalar)] = UInt64(index + 1)
        }
        guard characters["\u{02}"] == 1, characters["\u{03}"] == 2 else { throw Failure.malformedData }
        // Each packed table has a validated extent. Bind its bytes once;
        // UInt64 keys can start at an unaligned offset after an FP16 table.
        func table<Integer: FixedWidthInteger, Value>(_ count: Int, as: Integer.Type, transform: (Integer) -> Value) -> [Value] {
            let start = offset
            let size = MemoryLayout<Integer>.size
            offset += count * size
            return data.withUnsafeBytes { bytes in
                (0..<count).map { index in
                    let value = bytes.loadUnaligned(fromByteOffset: start + index * size, as: Integer.self)
                    return transform(Integer(littleEndian: value))
                }
            }
        }
        // Values stay Float16 (exactly widened at lookup): a quarter of the resident Double tables.
        let gramKeys = table(g, as: UInt64.self) { $0 }
        let gramValues = table(g, as: UInt16.self, transform: Float16.init(bitPattern:))
        let contextKeys = table(c, as: UInt64.self) { $0 }
        let contextValues = table(c, as: UInt16.self, transform: Float16.init(bitPattern:))
        guard gramValues.allSatisfy({ $0.isFinite && $0 <= 0 }), contextValues.allSatisfy({ $0.isFinite && $0 <= 0 }),
              zip(gramKeys, gramKeys.dropFirst()).allSatisfy({ $0 < $1 }),
              zip(contextKeys, contextKeys.dropFirst()).allSatisfy({ $0 < $1 }) else { throw Failure.malformedData }
        ids = characters; vocabularySize = v
        self.gramKeys = gramKeys; self.gramValues = gramValues
        self.contextKeys = contextKeys; self.contextValues = contextValues
    }

    private func logProbability(token: UInt64, history: [UInt64]) -> Double {
        var probability = 1.0 / Double(vocabularySize)
        for order in 1...min(3, history.count + 1) {
            var packed: UInt64 = 0
            if order > 1 {
                for (index, value) in history.suffix(order - 1).enumerated() { packed |= value << (12 * index) }
            }
            let key = (UInt64(order) << 60) | packed | (token << (12 * (order - 1)))
            let context = (UInt64(order - 1) << 60) | packed
            let seen = lookup(key, keys: gramKeys, values: gramValues).map(exp) ?? 0
            let backoff = exp(lookup(context, keys: contextKeys, values: contextValues) ?? 0)
            probability = seen + backoff * probability
        }
        return log(max(1e-30, probability))
    }

    /// Only substitute uncertain, visually plausible characters. Preserve the
    /// greedy CTC length and symbols; do not invent words or add/drop tokens.
    func correct(_ candidates: [[Choice]]) -> Correction {
        let original = candidates.compactMap(\.first)
        guard original.count == candidates.count, !original.isEmpty, original.count <= 400 else {
            return Correction(choices: original, changedTokens: 0)
        }
        func mayChange(_ base: Choice) -> Bool {
            base.probability < 0.9 && isLetter(base.text) && ids[base.text] != nil
        }
        // If no greedy token can be substituted, every surviving beam is
        // identical in text to the original; scoring cannot change the result.
        guard original.contains(where: mayChange) else {
            return Correction(choices: original, changedTokens: 0)
        }
        struct Beam {
            var choices: [Choice]
            var history: [UInt64]
            var score: Double
            var changes: Int
        }
        let weight = 0.25
        let maximumChanges = min(2, max(1, Int(ceil(Double(original.count) * 0.15))))
        func extend(_ beam: Beam, _ choice: Choice, changed: Bool) -> Beam {
            var next = beam
            next.choices.append(choice)
            next.score += log(max(1e-12, choice.probability))
            next.changes += changed ? 1 : 0
            for character in choice.text.map(String.init) {
                let token = ids[character] ?? 0
                next.score += weight * logProbability(token: token, history: next.history)
                next.history = Array((next.history + [token]).suffix(2))
            }
            return next
        }
        var beams = [Beam(choices: [], history: [1, 1], score: 0, changes: 0)]
        var greedy = beams[0]
        for (index, choices) in candidates.enumerated() {
            let base = original[index]
            greedy = extend(greedy, base, changed: false)
            let canChange = mayChange(base)
            var next: [Beam] = []
            for beam in beams {
                for choice in choices.prefix(4) {
                    let changed = choice.text != base.text
                    guard choice.probability.isFinite, choice.probability > 0,
                          !changed || (canChange && beam.changes < maximumChanges &&
                            choice.probability >= base.probability * 0.25 && isLetter(choice.text) && ids[choice.text] != nil) else { continue }
                    next.append(extend(beam, choice, changed: changed))
                }
            }
            beams = Array(next.sorted { a, b in
                a.score == b.score ? a.changes < b.changes : a.score > b.score
            }.prefix(8))
        }
        func finalScore(_ beam: Beam) -> Double {
            beam.score + weight * logProbability(token: 2, history: beam.history)
        }
        guard let winner = beams.max(by: { finalScore($0) < finalScore($1) }),
              winner.changes > 0, finalScore(winner) >= finalScore(greedy) + 0.35 else {
            return Correction(choices: original, changedTokens: 0)
        }
        return Correction(choices: winner.choices, changedTokens: winner.changes)
    }

    private func isLetter(_ text: String) -> Bool {
        guard text.count == 1, let scalar = text.unicodeScalars.first else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter: return true
        default: return false
        }
    }

    private func lookup(_ key: UInt64, keys: [UInt64], values: [Float16]) -> Double? {
        var low = 0, high = keys.count
        while low < high {
            let middle = low + (high - low) / 2
            if keys[middle] < key { low = middle + 1 } else { high = middle }
        }
        return low < keys.count && keys[low] == key ? Double(values[low]) : nil
    }
}
