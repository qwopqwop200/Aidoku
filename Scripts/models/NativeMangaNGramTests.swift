import Foundation

@main struct NativeMangaNGramTests {
    static func check(_ condition: Bool, _ name: String) throws {
        if !condition { throw NSError(domain: name, code: 1) }
    }
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let model = try NativeMangaNGram(data: data)
        try check(abs(model.score("こんにちは") - (-11.947071886820067)) < 1e-10, "Japanese n-gram score parity")
        try check(abs(model.score("ありがとう") - (-7.824432607500054)) < 1e-10, "BOS/EOS and interpolation parity")
        var choices = "こんにちわ".map { [NativeMangaNGram.Choice(text: String($0), probability: 0.99)] }
        choices[4] = [.init(text: "わ", probability: 0.55), .init(text: "は", probability: 0.50)]
        let correction = model.correct(choices)
        try check(correction.choices.map(\.text).joined() == "こんにちは" && correction.changedTokens == 1,
                  "plausible uncertain character corrected")
        choices[4] = [.init(text: "わ", probability: 0.99), .init(text: "は", probability: 0.98)]
        try check(model.correct(choices).changedTokens == 0, "confident visual character preserved")
        let punctuation = model.correct([[.init(text: "?", probability: 0.5), .init(text: "!", probability: 0.49)]])
        try check(punctuation.changedTokens == 0 && punctuation.choices.first?.text == "?", "standalone punctuation preserved")
        try check(model.correct([]).choices.isEmpty, "empty decode remains empty")
        var rejected = false
        do { _ = try NativeMangaNGram(data: Data(data.prefix(30))) } catch { rejected = true }
        try check(rejected, "truncated LM rejected")
        print("7 native n-gram checks passed")
    }
}
