import Foundation
import Testing
@testable import Aidoku

struct BuiltInSourceModelTests {
    @Test(arguments: [false, true])
    func sharingLabelSearchUsesItsOwnField(excluded: Bool) throws {
        for label in ["family", ""] {
            let data = try JSONEncoder().encode(KomgaSearchCondition.sharingLabel(label, exclude: excluded))
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: String]])
            #expect(body["genre"] == nil)
            let condition = try #require(body["sharingLabel"])
            #expect(condition["value"] == (label.isEmpty ? nil : label))
            #expect(condition["operator"] == (label.isEmpty
                ? (excluded ? "isNull" : "isNotNull") : (excluded ? "isNot" : "is")))
        }
    }
}
