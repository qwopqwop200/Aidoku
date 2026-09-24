import Foundation
import Testing
@testable import Aidoku

struct DownloadDescriptionPersistenceTests {
    @Test func writeFailureIsNotSilenced() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("001.desc.txt")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let image = root.appendingPathComponent("001.png")
        let original = Data([137, 80, 78, 71, 0, 1])
        try original.write(to: image)
        #expect(throws: (any Error).self) {
            try DownloadTask.writePageDescription(Data("Caption".utf8), to: destination)
        }
        #expect(try Data(contentsOf: image) == original)
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func successfulUnicodeDescriptionBytesRemainExact() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let data = Data("한글\n日本語\n  exact spacing \r\n".utf8)
        try DownloadTask.writePageDescription(data, to: destination)
        #expect(try Data(contentsOf: destination) == data)
    }
}
