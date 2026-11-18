import Foundation
import Testing
@testable import Aidoku

struct NativeSourceFontFitGroupsTests {
    private func item(_ id: String, font: Double) -> [String: Any] {
        ["id": id, "text": "표시", "sourceRequestedDisplayFontSize": font,
            "fontSize": font, "lineHeight": font * 1.4, "sourceBounds": [0.1, 0.2, 0.3, 0.4]]
    }

    @Test
    func exactlyEqualInferredEmsGroupAcrossPaletteAndWeightWithoutChangingStyles() throws {
        var regular = item("regular", font: 31.25), bold = item("bold", font: 31.25)
        regular["fill"] = [10, 20, 30]; regular["sourceFontWeight"] = "regular"; regular["renderBold"] = false
        regular["typographyGroupID"] = "existing-family"
        bold["fill"] = [200, 100, 40]; bold["sourceFontWeight"] = "bold"; bold["renderBold"] = true
        let input = [regular, bold], output = NativeSourceFontFitGroups.annotate(input)
        let token = try #require(output[0]["sourceFontFitGroupID"] as? String)
        #expect(output[1]["sourceFontFitGroupID"] as? String == token)
        for index in input.indices {
            #expect(output[index]["sourceFontFitGroupAuthority"] as? String == NativeSourceFontFitGroups.authority)
            let originalFields = output[index].filter { input[index].keys.contains($0.key) }
            #expect(NSDictionary(dictionary: originalFields).isEqual(to: input[index]))
        }
        #expect(output[1]["typographyGroupID"] == nil)
        #expect(output.allSatisfy { $0["sourceClusterAlignment"] == nil && $0["balloonPlacement"] == nil })
    }

    @Test
    func adjacentDoubleValuesNeverShareAFitCohort() throws {
        let font = 31.25, next = font.nextUp
        #expect(font.bitPattern != next.bitPattern)
        let singles = NativeSourceFontFitGroups.annotate([item("a", font: font), item("b", font: next)])
        #expect(singles.allSatisfy { $0["sourceFontFitGroupID"] == nil })
        let grouped = NativeSourceFontFitGroups.annotate([
            item("a", font: font), item("b", font: next), item("c", font: font), item("d", font: next)])
        let exact = try #require(grouped[0]["sourceFontFitGroupID"] as? String)
        let adjacent = try #require(grouped[1]["sourceFontFitGroupID"] as? String)
        #expect(exact != adjacent)
        #expect(grouped[2]["sourceFontFitGroupID"] as? String == exact)
        #expect(grouped[3]["sourceFontFitGroupID"] as? String == adjacent)
    }

    @Test
    func heldInvalidAndEmptyItemsCannotCreateOrJoinGroups() throws {
        var held = item("kept", font: 20), source = item("source", font: 20), empty = item("empty", font: 20)
        held["keptLettering"] = true; source["sourceTextOnly"] = true; empty["text"] = " \n\t "
        let invalid: [[String: Any]] = [
            ["id": "missing", "text": "표시"],
            ["id": "null", "text": "표시", "sourceRequestedDisplayFontSize": NSNull()],
            ["id": "string", "text": "표시", "sourceRequestedDisplayFontSize": "20"],
            ["id": "boolean", "text": "표시", "sourceRequestedDisplayFontSize": true],
            item("zero", font: 0), item("negative", font: -20), item("nan", font: .nan),
            item("infinity", font: .infinity), item("negativeInfinity", font: -.infinity)
        ]
        let inactive = [held, source, empty] + invalid
        let one = NativeSourceFontFitGroups.annotate([item("active", font: 20)] + inactive)
        #expect(one.allSatisfy { $0["sourceFontFitGroupID"] == nil && $0["sourceFontFitGroupAuthority"] == nil })
        let two = NativeSourceFontFitGroups.annotate([item("a", font: 20), item("b", font: 20)] + inactive)
        #expect(two[0]["sourceFontFitGroupID"] as? String == two[1]["sourceFontFitGroupID"] as? String)
        #expect(two[0]["sourceFontFitGroupID"] != nil)
        #expect(two.dropFirst(2).allSatisfy { $0["sourceFontFitGroupID"] == nil && $0["sourceFontFitGroupAuthority"] == nil })
    }

    @Test
    func explicitTagsAndAuthorityRemainUntouchedAndDoNotCountAsAutomaticMembers() throws {
        var explicit = item("explicit", font: 20)
        explicit["sourceFontFitGroupID"] = "caller-cohort"
        explicit["sourceFontFitGroupAuthority"] = "caller-authority"
        let singleton = NativeSourceFontFitGroups.annotate([explicit, item("one-new", font: 20)])
        #expect(NSDictionary(dictionary: singleton[0]).isEqual(to: explicit))
        #expect(singleton[1]["sourceFontFitGroupID"] == nil)
        let output = NativeSourceFontFitGroups.annotate([explicit, item("a", font: 20), item("b", font: 20)])
        #expect(NSDictionary(dictionary: output[0]).isEqual(to: explicit))
        #expect(output[1]["sourceFontFitGroupID"] as? String == output[2]["sourceFontFitGroupID"] as? String)
        #expect(output[1]["sourceFontFitGroupID"] as? String != "caller-cohort")
        var blank = item("blank-explicit", font: 20), null = item("null-explicit", font: 20)
        blank["sourceFontFitGroupID"] = ""; null["sourceFontFitGroupID"] = NSNull()
        let preserved = NativeSourceFontFitGroups.annotate([blank, null])
        #expect(preserved[0]["sourceFontFitGroupID"] as? String == "")
        #expect(preserved[1]["sourceFontFitGroupID"] is NSNull)
    }

    @Test
    func tokensAreStableAcrossOrderCallsAndIdempotentAnnotation() throws {
        let input = [item("a", font: 27.5), item("b", font: 27.5)]
        let first = NativeSourceFontFitGroups.annotate(input)
        let second = NativeSourceFontFitGroups.annotate(Array(input.reversed()))
        let token = try #require(first[0]["sourceFontFitGroupID"] as? String)
        #expect(second[0]["sourceFontFitGroupID"] as? String == token)
        let again = NativeSourceFontFitGroups.annotate(first)
        for index in first.indices { #expect(NSDictionary(dictionary: again[index]).isEqual(to: first[index])) }
        // A separate transaction cannot recruit members remembered from this one.
        #expect(NativeSourceFontFitGroups.annotate([item("alone", font: 27.5)])[0]["sourceFontFitGroupID"] == nil)
    }

    @Test
    func replayFontReferencesAndSharedDomainsAreNotInferredEmAuthority() {
        // A display-replay packet is not a same-call source-font inference.
        // Equal saved fonts or equal domains must not silently create a cohort.
        let policy: [String: Any] = ["kind": "inside-balloon-mask",
            "maskIntervalRowsNormalized": [[0.1, 0.2, 0.4], [0.2, 0.25, 0.35]]]
        let input: [[String: Any]] = ["a", "b", "c"].map { id in
            ["id": id, "text": "표시 👩‍💻\n다음", "fontReference": 54.0,
                "sourceFontSize": 54.0, "fontSize": 54.0,
                "textExpansionPolicy": policy, "sourceBounds": [0.1, 0.2, 0.1, 0.3]]
        }
        let output = NativeSourceFontFitGroups.annotate(input)
        for index in input.indices {
            #expect(NSDictionary(dictionary: output[index]).isEqual(to: input[index]))
            #expect(output[index]["sourceFontFitGroupID"] == nil)
        }
    }

    @Test
    func inferredCohortPreservesUTF16DomainsAndExplicitBodyMembership() throws {
        var first = item("first", font: 54), second = item("second", font: 54)
        let text = "표시 👩‍💻\r\n다음 e\u{301}"
        first["text"] = text; second["text"] = text
        let policy: [String: Any] = ["kind": "inside-balloon-mask",
            "maskIntervalRowsNormalized": [[0.1, 0.2, 0.3, 0.4, 0.5]]]
        first["textExpansionPolicy"] = policy; second["textExpansionPolicy"] = policy
        second["balloonPlacement"] = ["bodyID": "explicit-body", "order": 0]
        let input = [first, second], output = NativeSourceFontFitGroups.annotate(input)
        let group = try #require(output[0]["sourceFontFitGroupID"] as? String)
        #expect(output[1]["sourceFontFitGroupID"] as? String == group)
        for index in input.indices {
            let retained = output[index].filter { input[index].keys.contains($0.key) }
            #expect(NSDictionary(dictionary: retained).isEqual(to: input[index]))
            let actual = try #require(output[index]["text"] as? String)
            #expect(Array(actual.utf16) == Array(text.utf16))
        }
        #expect(output[0]["balloonPlacement"] == nil)
        #expect(output.allSatisfy { $0["typographyGroupID"] == nil })
    }

    @Test
    func explicitTokenCollisionCannotJoinDifferentInferredFonts() throws {
        let input = [item("a", font: 20), item("b", font: 20)]
        let token = try #require(NativeSourceFontFitGroups.annotate(input)[0]["sourceFontFitGroupID"] as? String)
        var explicit = item("unrelated-explicit", font: 44)
        explicit["sourceFontFitGroupID"] = token
        let output = NativeSourceFontFitGroups.annotate(input + [explicit])
        #expect(output[0]["sourceFontFitGroupID"] == nil && output[1]["sourceFontFitGroupID"] == nil)
        #expect(NSDictionary(dictionary: output[2]).isEqual(to: explicit))
    }
}
