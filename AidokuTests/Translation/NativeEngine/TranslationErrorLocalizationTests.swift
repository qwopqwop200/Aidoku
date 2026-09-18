import Foundation
import Testing
@testable import Aidoku

struct TranslationErrorLocalizationTests {
    private static let locales = ["af", "ar", "bg", "cs", "de", "el", "en", "eo", "es", "fr", "he", "hi", "hr", "hu",
        "id", "it", "ja", "ka", "km", "ko", "ml", "nb-NO", "ne", "nl", "pl", "pt-BR", "pt", "ro", "ru", "sq", "sr",
        "sv", "sw", "ta", "th", "tr", "uk", "ur", "vi", "zh-Hans", "zh-Hant"]

    @Test(arguments: locales)
    func everyLocaleShipsItsOwnTranslationErrorsAndFormatsIdentifiers(locale: String) throws {
        let path = try #require(Bundle.main.path(forResource: locale, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings"))
        let entries = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: 0, format: nil) as? [String: String])
        let englishPath = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let english = try #require(Bundle(path: englishPath))
        let englishURL = try #require(english.url(forResource: "Localizable", withExtension: "strings"))
        let englishEntries = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: englishURL), options: 0, format: nil) as? [String: String])
        let keys = englishEntries.keys.filter { $0.hasPrefix("TRANSLATION_ERROR_") } + [
            "TRANSLATION_IMAGE_UNSUPPORTED", "TRANSLATION_CONNECTION_FAILED_NOTICE", "TRANSLATION_INCLUDE_IMAGE_HELP",
            "TRANSLATION_TEST_SUCCESS", "TRANSLATION_TEST_FAILURE", "TRANSLATION_TEST_HELP"
        ]
        for key in keys {
            let stored = try #require(entries[key], "Missing local entry: \(locale)/\(key)")
            let resolved = bundle.localizedString(forKey: key, value: "MISSING_LOCALIZATION", table: nil)
            #expect(!stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(resolved == stored)
            #expect(resolved != key)
            if locale != "en" { #expect(resolved != englishEntries[key]) }
        }
        let requestID = "req-localization-test"
        let http = String(format: bundle.localizedString(forKey: "TRANSLATION_ERROR_HTTP_REQUEST", value: nil, table: nil),
                          Int32(429), requestID)
        #expect(http.contains("429"))
        #expect(http.contains(requestID))
        #expect(!http.contains("%@"))
        #expect(!http.contains("%d"))
        for key in ["TRANSLATION_ERROR_NETWORK_CODE", "TRANSLATION_ERROR_KEYCHAIN_STATUS"] {
            let message = String(format: bundle.localizedString(forKey: key, value: nil, table: nil), Int32(-1001))
            #expect(message.contains("-1001"))
        }
    }

    @Test func everyTranslationErrorUsesLocalizedUserFacingText() {
        let errors: [any LocalizedError] = [
            RemoteTranslationError.invalidConfiguration("INTERNAL_DIAGNOSTIC"),
            RemoteTranslationError.invalidRequest("INTERNAL_DIAGNOSTIC"),
            RemoteTranslationError.invalidResponse("INTERNAL_DIAGNOSTIC"),
            RemoteTranslationError.missingCredential, RemoteTranslationError.credentialAccessFailed,
            RemoteTranslationError.insecureEndpoint, RemoteTranslationError.redirectRejected,
            RemoteTranslationError.responseTooLarge, RemoteTranslationError.httpStatus(400, requestID: nil),
            RemoteTranslationError.httpStatus(422, requestID: "req-test"), RemoteTranslationError.transport(.timedOut),
            RemoteTranslationError.privateTailnetUnavailable, RemoteTranslationError.refused,
            TranslationCredentialStoreError.invalidAccount, TranslationCredentialStoreError.invalidSecret,
            TranslationCredentialStoreError.notFound, TranslationCredentialStoreError.invalidEncoding,
            TranslationCredentialStoreError.keychainStatus(-25300),
            TranslationCacheError.invalidSizeMiB(-1), TranslationCacheError.invalidStorageRoot,
            TranslationCacheError.unsafeStorageObject, TranslationCacheError.encodingFailure, TranslationCacheError.persistenceFailure
        ]
        for error in errors {
            let description = error.localizedDescription
            #expect(!description.isEmpty)
            #expect(!description.contains("TRANSLATION_ERROR_"))
            #expect(!description.contains("INTERNAL_DIAGNOSTIC"))
            #expect(!description.contains("couldn’t be completed"))
        }
    }

    @Test func diagnosticPayloadsDoNotLeakIntoUserMessages() {
        let diagnostic = "UNLOCALIZED_INTERNAL_DIAGNOSTIC"
        let errors: [any LocalizedError] = [
            RemoteTranslationError.invalidConfiguration(diagnostic),
            RemoteTranslationError.invalidRequest(diagnostic),
            RemoteTranslationError.invalidResponse(diagnostic)
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.errorDescription?.contains(diagnostic) == false)
            #expect(error.errorDescription?.hasPrefix("TRANSLATION_ERROR_") == false)
        }
        // Diagnostic payload remains available to callers despite the localized display text.
        let error = RemoteTranslationError.invalidResponse(diagnostic)
        if case let .invalidResponse(detail) = error {
            #expect(detail == diagnostic)
        }
    }

    @Test func failureMessagesPreserveStatusAndRequestIdentifiers() {
        let requestID = "req-localization-test"
        let message = RemoteTranslationError.httpStatus(429, requestID: requestID).localizedDescription
        #expect(message.contains("429"))
        #expect(message.contains(requestID))
        #expect(RemoteTranslationError.httpStatus(503, requestID: nil).localizedDescription.contains("503"))
        #expect(TranslationCredentialStoreError.keychainStatus(-25300).localizedDescription.contains("-25300"))
        #expect(RemoteTranslationError.transport(.timedOut).localizedDescription.contains("-1001"))
    }

    @available(iOS 18.0, *)
    @Test func ocrDiagnosticsDoNotLeakIntoUserMessages() {
        let diagnostic = "UNLOCALIZED_COREML_DIAGNOSTIC"
        let errors: [any LocalizedError] = [
            NativeCoreMLRecognizerError.modelLoadFailed(diagnostic),
            NativeCoreMLRecognizerError.predictionFailed(diagnostic),
            NativeCoreMLDetectorError.modelLoadFailed(diagnostic),
            NativeCoreMLDetectorError.predictionFailed(diagnostic)
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.errorDescription?.contains(diagnostic) == false)
            #expect(error.errorDescription?.hasPrefix("OCR_ERROR_") == false)
        }
    }
}
