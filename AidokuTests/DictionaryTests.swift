import Foundation
import Testing
import UIKit
import ZIPFoundation
@testable import Aidoku

/// Dictionary import, lookup, and untrusted-content handling.
@Suite(.serialized) @MainActor
struct DictionaryTests {
    // MARK: Import

    @Test func failedDictionaryReplacementRestoresOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("installed")
        let new = root.appendingPathComponent("incoming")
        for directory in [old, new] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("old dictionary".utf8).write(to: old.appendingPathComponent("index.json"))
        try Data("new dictionary".utf8).write(to: new.appendingPathComponent("index.json"))
        #expect(throws: (any Error).self) {
            try DictionaryFileOperations.install(from: new, to: old) { source, destination in
                if source.lastPathComponent.hasPrefix(".import-") { throw CocoaError(.fileWriteOutOfSpace) }
                try FileManager.default.moveItem(at: source, to: destination)
            }
        }
        #expect(try String(contentsOf: old.appendingPathComponent("index.json"), encoding: .utf8) == "old dictionary")
        try DictionaryFileOperations.install(from: new, to: old)
        #expect(try String(contentsOf: old.appendingPathComponent("index.json"), encoding: .utf8) == "new dictionary")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["incoming", "installed"])
    }

    @Test func archiveTitleCannotEscapeTheInstallDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (offset, title) in ["../Documents", "/tmp/escape", "日本語辞典"].enumerated() {
            let url = root.appendingPathComponent("\(offset).zip")
            let archive = try Archive(url: url, accessMode: .create)
            let data = try JSONSerialization.data(withJSONObject: ["title": title])
            try archive.addEntry(with: "index.json", type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
            if offset < 2 {
                #expect(throws: (any Error).self) { try DictionaryFileOperations.validateArchive(at: url) }
            } else {
                try DictionaryFileOperations.validateArchive(at: url)
            }
        }
    }

    @Test(arguments: [false, true])
    func downloadRejectsOversizedBodyWithOrWithoutLengthHeader(declared: Bool) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedDictionaryProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://dictionary-operation.invalid/oversized?declared=\(declared)")!
        await #expect(throws: (any Error).self) {
            _ = try await DictionaryFileOperations.boundedData(for: URLRequest(url: url), session: session, maximumBytes: 64)
        }
    }

    // MARK: Lookup

    @Test func romajiInputProducesKnownReadings() {
        #expect(RomajiConverter.hiraganaCandidates(for: "yonya") == ["よんや", "よにゃ"])
        #expect(RomajiConverter.hiraganaCandidates(for: "n'ya") == ["んや"])
        #expect(RomajiConverter.hiraganaCandidates(for: " SHI-Tsu ") == ["しつ"])
        #expect(RomajiConverter.hiraganaCandidates(for: "kitte") == ["きって"])
        #expect(RomajiConverter.hiraganaCandidates(for: "") == nil)
        #expect(RomajiConverter.hiraganaCandidates(for: "abc!") == nil)
    }

    @Test func recognizedRowsAreOrderedTopFirst() {
        let recognizer = TextRecognizer()
        recognizer.observations = [observation("下", x: 0.2, y: 0.4), observation("上", x: 0.2, y: 0.55)]
        recognizer.rebuildClusterCache()
        #expect(recognizer.orderedClusterIndices([0, 1]) == [1, 0])
    }

    @Test func overlayMapsWholeUnicodeCharactersToLookupHits() throws {
        for text in ["𠮷野家", "か\u{3099}くせい"] {
            let rect = CGRect(x: 0, y: 0, width: 240, height: 60)
            let suffixes = text.indices.map { String(text[$0...]) }
            let button = DictionaryOverlayButton(type: .system)
            button.apply(overlay: .init(text: text, rect: rect, segments: [
                .init(text: text, rect: rect, charHits: suffixes.map { .init(text: $0, rect: rect) })
            ]))
            var observed = Set<String>()
            for y in stride(from: CGFloat(0), to: rect.height, by: 1) {
                for x in stride(from: CGFloat(0), to: rect.width, by: 1) {
                    if let hit = button.lookupHit(at: CGPoint(x: x, y: y)) { observed.insert(hit.text) }
                }
            }
            #expect(observed == Set(suffixes))
        }
    }

    // MARK: Untrusted content

    @Test func htmlGlossaryStripsScriptsAndLinksCannotInvokeBrowserActions() throws {
        let html = "<script>window.__auditMarker = 71;</script><iframe>unsafe embedded document</iframe>"
            + "<p><b>definition</b> <a href='javascript:window.__auditMarker=71'>script link</a>"
            + " <a href='data:text/html,unsafe'>data link</a> <a href='file:///private/fixture'>file link</a></p>"
        let value = NativeDictionaryContent.glossary(html, dictionary: "security", scale: 1)
        #expect(!value.string.contains("__auditMarker") && !value.string.contains("unsafe embedded document"))
        #expect(value.string.contains("definition"))
        var redirects: [String] = []
        var kanjiRedirects: [String] = []
        let popup = NativeDictionaryPopupView(position: .zero, clearSelection: false, allowsMining: false,
            onRedirect: { redirects.append($0); return [] },
            onKanjiRedirect: { kanjiRedirects.append($0); return nil })
        let coordinator = popup.makeCoordinator()
        defer { NativeDictionaryPopupView.dismantleUIView(UIScrollView(), coordinator: coordinator) }
        let view = UITextView()
        view.attributedText = value
        for label in ["script link", "data link", "file link"] {
            let range = (value.string as NSString).range(of: label)
            try #require(range.location != NSNotFound)
            let link = try #require(value.attribute(.link, at: range.location, effectiveRange: nil) as? URL)
            #expect(!coordinator.textView(view, shouldInteractWith: link, in: range, interaction: .invokeDefaultAction))
        }
        #expect(redirects.isEmpty && kanjiRedirects.isEmpty)
        #expect(coordinator.history.isEmpty)
    }

    @Test func mediaRenderScaleCapsTallBitmaps() {
        #expect(NativeDictionaryImageAttachment.renderScale(for: CGSize(width: 100, height: 100), screenScale: 3) == 3)
        let tall = CGSize(width: 390, height: 4096)
        let scale = NativeDictionaryImageAttachment.renderScale(for: tall, screenScale: 3)
        #expect(scale < 3)
        #expect(tall.width * tall.height * scale * scale <= NativeDictionaryImageAttachment.maximumRenderPixels + 1)
    }

    private func observation(_ text: String, x: CGFloat, y: CGFloat) -> TextRecognizer.OCRObservation {
        let box = CGRect(x: x, y: y, width: 0.1, height: 0.1)
        return .init(text: text, boundingRect: box, direction: .leftToRight, confidence: 1,
                     characters: [.init(text: text, boundingRect: box)])
    }
}

private final class OversizedDictionaryProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "dictionary-operation.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let headers = url.query == "declared=true" ? ["Content-Length": "65"] : [:]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                            headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 65))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
