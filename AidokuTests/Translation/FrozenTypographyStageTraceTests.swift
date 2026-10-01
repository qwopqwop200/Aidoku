import Foundation
import Testing
import JavaScriptCore

@Suite
struct FrozenTypographyStageTraceTests {
    @Test func assembledFrozenScriptSupportsEveryCheckpoint() throws {
        // The helper library and the render body share some comment prefixes.
        // Exercise their real concatenation, not just the render-body literal.
        let frozen = LegacyReaderTranslationRenderScript.renderScript
        let instrumented = try FrozenTypographyStageTrace.instrument(frozen, regionIDs: ["5"])
        #expect(instrumented.components(separatedBy: "__aidokuTypographyStageTrace ||= ").count - 1 == 15)
        #expect(instrumented.components(separatedBy: "__aidokuRestorationInputTrace").count - 1 == 1)
        #expect(instrumented.components(separatedBy: "__aidokuRestorationResultTrace").count - 1 == 1)
        let unchangedOracle = frozen == LegacyReaderTranslationRenderScript.renderScript
        #expect(unchangedOracle)
    }
}

@Suite
@MainActor
struct FrozenReferenceInputTransportTests {
    @Test(arguments: [false, true])
    func originalJSONMatchesNativeDoubleAtPixelBoundary(objectPayload: Bool) throws {
        let itemsJSON = #"[{"sourceBounds":[0.090789473684210531,0.115,0.8342105263157895,0.0775]}]"#
        let payload = objectPayload ? "{\"items\":\(itemsJSON)}" : itemsJSON
        struct Item: Decodable { let sourceBounds: [Double] }
        let native = try JSONDecoder().decode([Item].self, from: Data(itemsJSON.utf8))
        let context = try #require(JSContext())
        context.setObject(payload, forKeyedSubscript: "aidokuReferenceLayoutJSON" as NSString)
        context.evaluateScript("var items = [{sourceBounds:[0]}];")
        context.evaluateScript(LegacyReaderTranslationOverlayView.serializedLayoutInputScript)
        #expect(context.exception == nil)
        let actual = try #require(context.evaluateScript("items[0].sourceBounds[0]")).toDouble()
        #expect(actual == native[0].sourceBounds[0])
        #expect(floor(actual * 760) == 69)
        #expect(floor(actual * 760) - 24 == 45)
    }

    @Test func invalidSerializedLayoutCannotSilentlyUseRoundedItems() throws {
        let context = try #require(JSContext())
        context.setObject("{\"items\":null}", forKeyedSubscript: "aidokuReferenceLayoutJSON" as NSString)
        context.evaluateScript("var items = [{sourceBounds:[0]}];")
        context.evaluateScript(LegacyReaderTranslationOverlayView.serializedLayoutInputScript)
        let message = context.exception?.toString() ?? ""
        #expect(message.contains("items array"))
    }
}
