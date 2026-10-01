import CoreGraphics

/// The original caption font recovery sequence, driven by the actual shaper.
/// Surface inspectors remain owned by the caller and share their page budgets.
enum NativeTypographyCaptionRecovery {
    struct Input {
        let preserveBackground: Bool
        let automatic: Bool
        let vertical: Bool
        let korean: Bool
        /// JavaScript string length, in UTF-16 code units.
        let length: Int
    }
    struct Budget {
        var readable: Int
        var characters: Int
    }
    struct Profile {
        let breaks: [Int]
        let badStarts: Int
        let badEnds: Int
        let punctuationOnly: Int
        let hangulIsolated: Int
    }
    struct State<Value> {
        let value: Value
        let font: CGFloat
        let padding: [CGFloat]
    }
    enum Reason: String { case accepted, retainedWordFlow = "retained-word-flow", measuredWordFlow = "measured-word-flow" }
    struct Result<Value> {
        let state: State<Value>
        let reason: Reason?
    }

    static func recovering<Value>(_ initial: State<Value>, input: Input, budget: inout Budget,
                                  apply: (CGFloat, [CGFloat]) -> State<Value>,
                                  contentFits: (State<Value>) -> Bool,
                                  lineProfile: (State<Value>) -> Profile?,
                                  inspectInitialSurface: ((State<Value>) -> State<Value>)? = nil,
                                  inspectFinalSurface: ((State<Value>) -> Void)? = nil) -> Result<Value> {
        var current = initial
        var reason: Reason?
        let before = input.preserveBackground ? lineProfile(initial) : nil
        let eligible = input.preserveBackground && input.automatic && !input.vertical && input.length <= 180
        if eligible && initial.font < 10.5 {
            current = apply(10.5, current.padding)
            if !contentFits(current) { current = apply(initial.font, current.padding) }
            else { reason = .accepted }
        }
        if let inspectInitialSurface { current = inspectInitialSurface(current) }
        if reason == .accepted, let before {
            let next = lineProfile(current)
            if next == nil || next!.breaks.count > before.breaks.count || next!.badStarts > before.badStarts ||
                next!.punctuationOnly > before.punctuationOnly || next!.hangulIsolated > before.hangulIsolated {
                current = apply(initial.font, current.padding); reason = .retainedWordFlow
            }
        }
        if eligible && input.korean && input.length <= budget.readable && current.font < 10.25 {
            budget.readable -= input.length
            let original = current, profile = lineProfile(current)
            var paddings = [current.padding]
            if !paddings.contains(initial.padding) { paddings.append(initial.padding) }
            var accepted = false
            if let profile {
                var size: CGFloat = 10.5
                recovery: while size >= original.font + 0.5 {
                    current = apply(size, current.padding)
                    for padding in paddings {
                        current = apply(size, padding)
                        if !contentFits(current) { continue }
                        if input.length > budget.characters { break recovery }
                        budget.characters -= input.length
                        guard let next = lineProfile(current),
                              next.breaks.allSatisfy({ profile.breaks.contains($0) }),
                              next.badStarts <= profile.badStarts, next.badEnds <= profile.badEnds,
                              next.punctuationOnly <= profile.punctuationOnly,
                              next.hangulIsolated <= profile.hangulIsolated else { continue }
                        accepted = true; reason = .measuredWordFlow; break recovery
                    }
                    size -= 0.25
                }
            }
            if !accepted { current = apply(original.font, original.padding) }
        }
        inspectFinalSurface?(current)
        return Result(state: current, reason: reason)
    }
}
