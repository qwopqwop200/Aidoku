import Foundation
import Testing
import ZIPFoundation
@testable import Aidoku

struct EHentaiErrorBodyBoundsTests {
    @Test func everyResponseUsesTheMetadataCap() {
        // The policy no longer depends on status, so error pages and challenges are capped too.
        guard case let .limited(maximum) = EHentaiSourceRunner.metadataBodyPolicy() else {
            Issue.record("Expected a limited body policy")
            return
        }
        #expect(maximum == EHentaiSourceRunner.maximumMetadataBytes)
        guard case let .limited(custom) = EHentaiSourceRunner.metadataBodyPolicy(maximum: 512) else {
            Issue.record("Expected a limited body policy")
            return
        }
        #expect(custom == 512)
    }
}

struct KavitaPageCountBoundsTests {
    @Test func rejectsNegativeAndClampsHugeCounts() {
        #expect(KavitaVolume.Chapter.boundedPageCount(-1) == nil)
        #expect(KavitaVolume.Chapter.boundedPageCount(Int.min) == nil)
        #expect(KavitaVolume.Chapter.boundedPageCount(0) == 0)
        #expect(KavitaVolume.Chapter.boundedPageCount(42) == 42)
        #expect(KavitaVolume.Chapter.boundedPageCount(10_000) == 10_000)
        #expect(KavitaVolume.Chapter.boundedPageCount(Int.max) == KavitaVolume.Chapter.maximumPageCount)
        #expect(KavitaVolume.Chapter.boundedPageCount(50, maximum: 8) == 8)
    }
}

struct SourcePackageExtractorTests {
    private struct Fixture {
        let folder: URL
        var archiveURL: URL { folder.appendingPathComponent("source.aix") }
        var destination: URL { folder.appendingPathComponent("out", isDirectory: true) }

        init() {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        func makeArchive(_ files: [(path: String, data: Data)], symlink: (path: String, target: String)? = nil) throws {
            let archive = try Archive(url: archiveURL, accessMode: .create)
            for file in files {
                try archive.addEntry(with: file.path, type: .file, uncompressedSize: Int64(file.data.count),
                                     compressionMethod: .deflate) { position, size in
                    file.data.subdata(in: Int(position)..<Int(position) + size)
                }
            }
            if let symlink {
                let target = Data(symlink.target.utf8)
                try archive.addEntry(with: symlink.path, type: .symlink, uncompressedSize: Int64(target.count)) { position, size in
                    target.subdata(in: Int(position)..<Int(position) + size)
                }
            }
        }

        func remove() { try? FileManager.default.removeItem(at: folder) }
    }

    @Test func extractsValidPackage() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.makeArchive([("Payload/source.json", Data("{}".utf8)), ("./Payload/res/icon.png", Data(repeating: 7, count: 300))])
        try SourcePackageExtractor.extract(fixture.archiveURL, to: fixture.destination)
        let manifest = fixture.destination.appendingPathComponent("Payload/source.json")
        #expect(try Data(contentsOf: manifest) == Data("{}".utf8))
        #expect(try Data(contentsOf: fixture.destination.appendingPathComponent("Payload/res/icon.png")).count == 300)
    }

    @Test(arguments: ["../escape.txt", "Payload/../../escape.txt", "/absolute.txt", "..\\escape.txt"])
    func rejectsTraversalWithoutWriting(path: String) throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.makeArchive([("Payload/source.json", Data("{}".utf8)), (path, Data("x".utf8))])
        #expect(throws: SourcePackageExtractor.Failure.unsafePath(path)) {
            try SourcePackageExtractor.extract(fixture.archiveURL, to: fixture.destination)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent("escape.txt").path))
    }

    @Test func rejectsSymlinkEntries() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.makeArchive([("Payload/source.json", Data("{}".utf8))], symlink: ("Payload/link", "/etc"))
        #expect(throws: SourcePackageExtractor.Failure.unsupportedEntry("Payload/link")) {
            try SourcePackageExtractor.extract(fixture.archiveURL, to: fixture.destination)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func enforcesEntryCount() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.makeArchive((0..<4).map { ("Payload/\($0).txt", Data("x".utf8)) })
        var limits = SourcePackageExtractor.Limits()
        limits.maximumEntryCount = 3
        #expect(throws: SourcePackageExtractor.Failure.tooManyEntries) {
            try SourcePackageExtractor.extract(fixture.archiveURL, to: fixture.destination, limits: limits)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        limits.maximumEntryCount = 4
        try SourcePackageExtractor.extract(fixture.archiveURL, to: fixture.destination, limits: limits)
    }

    @Test func enforcesPerEntrySize() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        // Highly compressible data stands in for a small zip bomb.
        try fixture.makeArchive([("Payload/source.json", Data("{}".utf8)), ("Payload/bomb.bin", Data(count: 4096))])
        var limits = SourcePackageExtractor.Limits()
        limits.maximumEntryBytes = 1024
        #expect(throws: SourcePackageExtractor.Failure.entryTooLarge("Payload/bomb.bin")) {
            try SourcePackageExtractor.extract(fixture.archiveURL, to: fixture.destination, limits: limits)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func enforcesTotalSize() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.makeArchive([("Payload/a.bin", Data(count: 600)), ("Payload/b.bin", Data(count: 600))])
        var limits = SourcePackageExtractor.Limits()
        limits.maximumEntryBytes = 1000
        limits.maximumTotalBytes = 1000
        #expect(throws: SourcePackageExtractor.Failure.totalTooLarge) {
            try SourcePackageExtractor.extract(fixture.archiveURL, to: fixture.destination, limits: limits)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        limits.maximumTotalBytes = 1200
        try SourcePackageExtractor.extract(fixture.archiveURL, to: fixture.destination, limits: limits)
    }

    @Test func refusesExistingDestination() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.makeArchive([("Payload/source.json", Data("{}".utf8))])
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        #expect(throws: SourcePackageExtractor.Failure.destinationExists) {
            try SourcePackageExtractor.extract(fixture.archiveURL, to: fixture.destination)
        }
        // The caller's directory is not removed for this precondition failure.
        #expect(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func normalizesSafePaths() {
        #expect(SourcePackageExtractor.safeRelativePath("./Payload/x") == "Payload/x")
        #expect(SourcePackageExtractor.safeRelativePath("Payload/") == "Payload")
        #expect(SourcePackageExtractor.safeRelativePath("./") == "")
        #expect(SourcePackageExtractor.safeRelativePath("C:/x") == nil)
        #expect(SourcePackageExtractor.safeRelativePath("") == nil)
    }
}
