import Foundation
import Testing
@testable import Aidoku

struct ModelColdCancellationTests {
    @Test func preCancelledBundledModelLookupDoesNotTouchColdStorage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cancelled-model-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ModelManager(directory: directory, bundle: .main)
        // Use the real packaged FDAT catalog/resource, without expanding or loading it.
        let catalog = await manager.bundledModels()
        let model = try #require(catalog.first { $0.file == "IllustrationJaNaiV3-FDATM.mlpackage" })
        let resource = try #require(model.bundledResource)
        let resourceURL = try #require(Bundle.main.url(forResource: resource, withExtension: nil))
        #expect(FileManager.default.fileExists(atPath: resourceURL.path))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let fileName = model.file
        let lookup = Task.detached { () throws -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await manager.getModel(fileName: fileName)
                return false
            } catch is CancellationError {
                return true
            }
        }
        let cancelledBeforeLoad = try await lookup.value
        #expect(cancelledBeforeLoad)
        // Before the fix, modelsDirectory creates this path then metadata loading
        // throws a filesystem error. Cancellation must precede both, not merely
        // suppress an inference result after Core ML has already prepared a model.
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
