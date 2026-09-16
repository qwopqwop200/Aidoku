import AidokuRunner
import Foundation
import UIKit
import Testing
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct TranslatedDownloadTests {
    private func download() -> Download {
        .from(manga: AidokuRunner.Manga(sourceKey: "test", key: "manga", title: "Test"),
              chapter: AidokuRunner.Chapter(key: "chapter", title: "Chapter"))
    }

    @Test func translationChoiceSurvivesQueuePersistence() throws {
        var item = download()
        item.translatesImages = true
        let restored = try JSONDecoder().decode(Download.self, from: JSONEncoder().encode(item))
        #expect(restored.translatesImages == true)
        #expect(restored.chapterIdentifier == item.chapterIdentifier)
    }

    @Test func oldQueueWithoutTranslationFieldStillDecodesAsOriginalDownload() throws {
        let encoded = try JSONEncoder().encode(download())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "translatesImages")
        let restored = try JSONDecoder().decode(Download.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.translatesImages != true)
    }

    @Test func cancelledTranslationDoesNotWaitForAWindowOrStartOCR() async {
        let operation = Task {
            // Cancellation must be checked before touching a window or OCR models.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DownloadImageTranslator.translate(Data(), settings: ReaderTranslationSettings())
        }
        do {
            _ = try await operation.value
            Issue.record("Cancelled download unexpectedly produced an image")
        } catch is CancellationError {
            // Expected: no unstructured OCR/export work outlives the download.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func downloadEncodesTranslatedPixelsAndPropagatesProviderFailure() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        }
        let input = try #require(original.pngData())
        let translated = try await DownloadImageTranslator.translate(input, settings: ReaderTranslationSettings()) { _, _ in
            [ReaderTranslationRegion(id: "download", rect: CGRect(x: 0.15, y: 0.25, width: 0.7, height: 0.2),
                source: "Hello", translation: "다운로드한 번역 이미지입니다.")]
        }
        let decoded = try #require(UIImage(data: translated))
        #expect(decoded.size == original.size)
        #expect(translated.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]))
        let before = try #require(original.cgImage?.dataProvider?.data) as Data
        let after = try #require(decoded.cgImage?.dataProvider?.data) as Data
        #expect(before != after)
        enum ProviderFailure: Error { case unavailable }
        do {
            _ = try await DownloadImageTranslator.translate(input, settings: ReaderTranslationSettings()) { _, _ in
                throw ProviderFailure.unavailable
            }
            Issue.record("Provider failure must not save the original as a translated download")
        } catch ProviderFailure.unavailable {
            // The download task receives this error and marks the page failed.
        }
    }

}
