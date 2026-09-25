import Testing
@testable import Aidoku

struct ReaderImageContentIdentityTests {
    @Test func identityUsesContentAndProcessingSettings() {
        let first = ReaderImageContentIdentity.base64Key("abc", processorSettingsKey: "plain")
        #expect(first == "reader-base64-v2-ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad-plain")
        #expect(first == ReaderImageContentIdentity.base64Key(String(["a", "b", "c"].joined()), processorSettingsKey: "plain"))
        #expect(first != ReaderImageContentIdentity.base64Key("abd", processorSettingsKey: "plain"))
        #expect(first != ReaderImageContentIdentity.base64Key("abc", processorSettingsKey: "cropped"))
    }

    @Test func largePayloadIdentityIsRepeatableAndSensitiveToLastByte() {
        let payload = String(repeating: "YWJj", count: 32_768)
        let first = ReaderImageContentIdentity.base64Key(payload, processorSettingsKey: "plain")
        #expect(first == ReaderImageContentIdentity.base64Key(payload, processorSettingsKey: "plain"))
        #expect(first != ReaderImageContentIdentity.base64Key(payload + "AA==", processorSettingsKey: "plain"))
    }
}
