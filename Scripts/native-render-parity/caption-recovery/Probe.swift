import Foundation
import CoreGraphics
@main enum Probe {
 static func main() throws {
  let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
  let results: [Any] = fixtures.map { f in
   typealias Policy = NativeTypographyCaptionRecovery
   let samples = f["samples"] as! [[String: Any]]
   func pad(_ string: String) -> [CGFloat] { string.split(separator: ",").map { CGFloat(Double($0)!) } }
   func padKey(_ values: [CGFloat]) -> String { values.map { String(Int($0)) }.joined(separator: ",") }
   func sample(_ state: Policy.State<Int>) -> [String: Any]? {
    samples.first { ($0["font"] as! Double) == Double(state.font) && ($0["padding"] as! String) == padKey(state.padding) }
   }
   var events: [[Any]] = []
   func event(_ name: String, _ state: Policy.State<Int>) { events.append([name, Double(state.font), padKey(state.padding)]) }
   let initial = Policy.State(value: 0, font: CGFloat(f["font"] as! Double), padding: pad(f["padding"] as! String))
   let input = Policy.Input(preserveBackground: f["preserveBackground"] as! Bool, automatic: f["automatic"] as! Bool,
       vertical: f["vertical"] as! Bool, korean: f["korean"] as! Bool, length: f["length"] as! Int)
   var budget = Policy.Budget(readable: f["readable"] as! Int, characters: f["characters"] as! Int)
   let result = Policy.recovering(initial, input: input, budget: &budget,
    apply: { Policy.State(value: 0, font: $0, padding: $1) },
    contentFits: { state in event("fit", state); return sample(state)?["fits"] as? Bool ?? false },
    lineProfile: { state in
     event("profile", state)
     guard let p = sample(state)?["profile"] as? [String: Any] else { return nil }
     return Policy.Profile(breaks: p["breaks"] as! [Int], badStarts: p["badStarts"] as! Int, badEnds: p["badEnds"] as! Int,
        punctuationOnly: p["punctuationOnly"] as! Int, hangulIsolated: p["hangulIsolated"] as! Int)
    },
    inspectInitialSurface: { state in
     event("initial", state)
     return Policy.State(value: state.value, font: state.font, padding: (f["surfacePadding"] as? String).map(pad) ?? state.padding)
    }, inspectFinalSurface: { event("final", $0) })
   return ["font": Double(result.state.font), "padding": padKey(result.state.padding), "reason": result.reason?.rawValue as Any? ?? NSNull(),
    "readable": budget.readable, "characters": budget.characters, "events": events] as [String: Any]
  }
  try JSONSerialization.data(withJSONObject: results).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
 }
}
