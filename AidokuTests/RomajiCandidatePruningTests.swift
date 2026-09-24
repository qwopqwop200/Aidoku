import Testing
@testable import Aidoku

struct RomajiCandidatePruningTests {
    @Test func preservesKnownReadingsAndInputNormalization() {
        #expect(RomajiConverter.hiraganaCandidates(for: "yonya") == ["よんや", "よにゃ"])
        #expect(RomajiConverter.hiraganaCandidates(for: "n'ya") == ["んや"])
        #expect(RomajiConverter.hiraganaCandidates(for: " SHI-Tsu ") == ["しつ"])
        #expect(RomajiConverter.hiraganaCandidates(for: "kitte") == ["きって"])
        #expect(RomajiConverter.hiraganaCandidates(for: "konnichiwa") == ["こんにちわ"])
        #expect(RomajiConverter.hiraganaCandidates(for: "") == nil)
        #expect(RomajiConverter.hiraganaCandidates(for: "abc!") == nil)
    }

    @Test func impossibleSuffixDoesNotProducePartialReadings() {
        #expect(RomajiConverter.hiraganaCandidates(for: String(repeating: "nya", count: 12) + "z") == nil)
    }

    @Test func ambiguousReadingRetainsHistoricalFirst32Results() {
        // Captured from the unchanged DFS on the round-two snapshot; no oracle
        // implementation is duplicated in the retained regression test.
        let expected: Set<String> = [
            "にゃにゃにゃにゃにゃにゃ",
            "にゃにゃにゃにゃにゃんや",
            "にゃにゃにゃにゃんやにゃ",
            "にゃにゃにゃにゃんやんや",
            "にゃにゃにゃんやにゃにゃ",
            "にゃにゃにゃんやにゃんや",
            "にゃにゃにゃんやんやにゃ",
            "にゃにゃにゃんやんやんや",
            "にゃにゃんやにゃにゃにゃ",
            "にゃにゃんやにゃにゃんや",
            "にゃにゃんやにゃんやにゃ",
            "にゃにゃんやにゃんやんや",
            "にゃにゃんやんやにゃにゃ",
            "にゃにゃんやんやにゃんや",
            "にゃにゃんやんやんやにゃ",
            "にゃにゃんやんやんやんや",
            "にゃんやにゃにゃにゃにゃ",
            "にゃんやにゃにゃにゃんや",
            "にゃんやにゃにゃんやにゃ",
            "にゃんやにゃにゃんやんや",
            "にゃんやにゃんやにゃにゃ",
            "にゃんやにゃんやにゃんや",
            "にゃんやにゃんやんやにゃ",
            "にゃんやにゃんやんやんや",
            "にゃんやんやにゃにゃにゃ",
            "にゃんやんやにゃにゃんや",
            "にゃんやんやにゃんやにゃ",
            "にゃんやんやにゃんやんや",
            "にゃんやんやんやにゃにゃ",
            "にゃんやんやんやにゃんや",
            "にゃんやんやんやんやにゃ",
            "にゃんやんやんやんやんや",
        ]
        #expect(expected.count == 32)
        #expect(RomajiConverter.hiraganaCandidates(for: String(repeating: "nya", count: 6)) == expected)
    }
}
