import Foundation
import Testing
import ZIPFoundation
@testable import Aidoku

@Suite struct DictionaryFileOperationsTests {
    @Test func rejectsMalformedRemoteURLsAndHTTPFailures() throws {
        for value in ["", "/dictionary.json", "file:///tmp/dictionary.json", "https://"] {
            #expect(throws: (any Error).self) { try DictionaryFileOperations.remoteURL(value) }
        }
        let url = try DictionaryFileOperations.remoteURL("https://example.com/dictionary.json")
        try DictionaryFileOperations.validateResponse(try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        #expect(throws: (any Error).self) {
            try DictionaryFileOperations.validateResponse(try #require(HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)))
        }
    }

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

    @Test func invalidDictionaryTitlesCannotEscapeTheInstallDirectory() throws {
        for title in ["", ".", "..", "../Documents", "a/b", "a\\b", "a\0b"] {
            #expect(throws: (any Error).self) { try DictionaryFileOperations.validateTitle(title) }
        }
        try DictionaryFileOperations.validateTitle("日本語辞典")
    }
    @Test func archiveTitleIsValidatedBeforeNativeImportCanWrite() throws {
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

}
