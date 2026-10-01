import AidokuRunner
import CoreData
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct NativeAdapterBoundarySafetyTests {
    @Test func customSourceConfigDecodesNonzeroBasedData() throws {
        let config = CustomSourceConfig.komga(.init(key: "slice-key", name: "Slice", server: "https://example.invalid"))
        let encoded = config.encode()
        let wrapped = Data([0xff, 0xff]) + encoded
        let decoded = try CustomSourceConfig(from: wrapped[2...])
        #expect(decoded.encode() == encoded)
        #expect(try CustomSourceConfig(from: Data([0xff, 2])[1...]).encode() == Data([2]))
    }

    @Test func malformedSliceCountsReturnOriginalImage() async throws {
        let context = try #require(CGContext(data: nil, width: 2, height: 7, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = UIImage(cgImage: try #require(context.makeImage()))
        let runner = RawOtakuSourceRunner()
        let descriptor = try await runner.store(value: image)
        let response = AidokuRunner.Response(code: 200, headers: [:], request: .init(url: nil, headers: [:]), image: descriptor)
        for count in [65, Int.max] {
            let result = try await runner.processPageImage(response: response, context: ["slice": String(count - 1), "slices": String(count)])
            #expect(result === image)
        }
        try await runner.remove(value: descriptor)
    }

    @Test func unreadableRootCannotEraseLocalMetadata() async throws {
        let fixture = try AdapterLocalStore()
        defer { fixture.close() }
        let writer = LocalFileDataManager(context: fixture.context())
        try await fixture.commit(writer)
        let notDirectory = fixture.directory.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: notDirectory)
        let manager = LocalFileManager(dataManager: writer, startsListener: false, localDirectory: notDirectory)
        await manager.scanLocalFiles()
        #expect(await writer.hasSeries(id: "fixture"))
        #expect(await writer.fetchChapters(mangaId: "fixture").map(\.key) == ["chapter"])
    }

    @Test func failedChildReadCannotEraseChapters() async throws {
        let fixture = try AdapterLocalStore()
        defer { fixture.close() }
        let writer = LocalFileDataManager(context: fixture.context())
        try await fixture.commit(writer)
        let root = fixture.directory.appendingPathComponent("Local", isDirectory: true)
        let child = root.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let manager = LocalFileManager(dataManager: writer, startsListener: false, localDirectory: root,
            scanCheckpoint: { try? FileManager.default.removeItem(at: child) })
        await manager.scanLocalFiles()
        #expect(await writer.hasSeries(id: "fixture"))
        #expect(await writer.fetchChapters(mangaId: "fixture").map(\.key) == ["chapter"])
    }

    @Test func listenerStartsOnceAndClosesItsOwnDescriptorOnRelease() async throws {
        let fixture = try AdapterLocalStore()
        defer { fixture.close() }
        let root = fixture.directory.appendingPathComponent("Local", isDirectory: true)
        let closes = DescriptorCloses()
        var manager: LocalFileManager? = LocalFileManager(dataManager: LocalFileDataManager(context: fixture.context()),
            startsListener: false, localDirectory: root, closeListenerDescriptor: { descriptor in
                closes.append(close(descriptor))
            })
        weak var released = manager
        await manager?.startFileSystemListener()
        await manager?.startFileSystemListener()
        manager = nil
        for _ in 0..<200 where closes.results.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(released == nil)
        #expect(closes.results == [0])
    }
}

private final class DescriptorCloses: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CInt] = []
    func append(_ result: CInt) { lock.lock(); defer { lock.unlock() }; storage.append(result) }
    var results: [CInt] { lock.lock(); defer { lock.unlock() }; return storage }
}

@MainActor private final class AdapterLocalStore {
    let directory: URL
    let coordinator: NSPersistentStoreCoordinator
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("adapter-safety-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        coordinator = NSPersistentStoreCoordinator(managedObjectModel: CoreDataManager.shared.container.managedObjectModel)
        for configuration in ["Cloud", "Local"] {
            try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: configuration,
                at: directory.appendingPathComponent(configuration + ".sqlite"))
        }
    }
    func context() -> NSManagedObjectContext {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }
    func commit(_ writer: LocalFileDataManager) async throws {
        try await writer.commitImport(folder: directory, mangaId: "fixture", mangaTitle: "Fixture", cover: nil,
            description: nil, archive: directory.appendingPathComponent("chapter.cbz"), chapterId: "chapter",
            chapterTitle: "Chapter", volume: nil, chapter: 1, comicInfo: nil)
    }
    func close() {
        for store in coordinator.persistentStores { try? coordinator.remove(store) }
        try? FileManager.default.removeItem(at: directory)
    }
}
