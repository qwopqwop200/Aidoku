import CoreML
import Foundation
import Testing
@testable import Aidoku

struct NativeCoreMLModelStoreTests {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func identicalModelsAcrossInstallsUseOneDurableURL() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeCoreMLModelStore(root: root.appendingPathComponent("stable"), runtimeCache: root.appendingPathComponent("runtime"))
        var destinations: [URL] = []
        for install in ["install-A", "install-B"] {
            let source = root.appendingPathComponent(install + "/OCR.mlmodelc")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("same model".utf8).write(to: source.appendingPathComponent("model.mil"))
            try Data(repeating: 123, count: 2_100_000).write(to: source.appendingPathComponent("weight.bin"))
            destinations.append(try store.modelURL(for: source))
        }
        #expect(destinations[0] == destinations[1])
        #expect(try Data(contentsOf: destinations[0].appendingPathComponent("weight.bin")) == Data(repeating: 123, count: 2_100_000))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("stable").path).count == 1)
    }

    @Test func changedModelHasNewIdentityWithoutRemovingResidentModel() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeCoreMLModelStore(root: root.appendingPathComponent("stable"), runtimeCache: root.appendingPathComponent("runtime"))
        func model(_ version: String) throws -> URL {
            let source = root.appendingPathComponent(version + "/OCR.mlmodelc")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data(version.utf8).write(to: source.appendingPathComponent("model.mil"))
            return try store.modelURL(for: source)
        }
        let first = try model("one"), second = try model("two")
        #expect(first != second)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test func bundledOCRAssetsLoadFromDurableCopy() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["PP-OCRv6-Medium-DetShapes", "PP-OCRv6-Medium-RecWidths"] {
            let source = try #require(Bundle.main.url(forResource: name, withExtension: "mlmodelc"))
            let store = NativeCoreMLModelStore(root: root.appendingPathComponent("stable"), runtimeCache: root.appendingPathComponent("runtime"))
            let stable = try store.modelURL(for: source)
            let relaunched = NativeCoreMLModelStore(root: root.appendingPathComponent("stable"), runtimeCache: root.appendingPathComponent("runtime"))
            #expect(try relaunched.modelURL(for: source) == stable)
            let asset = try MLModelAsset(url: stable)
            let functions = try await asset.functionNames
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly
            if !functions.isEmpty { configuration.functionName = functions.contains("main") ? "main" : functions[0] }
            let model = try await MLModel.load(asset: asset, configuration: configuration)
            #expect(!model.modelDescription.inputDescriptionsByName.isEmpty)
            #expect(!model.modelDescription.outputDescriptionsByName.isEmpty)
        }
    }

    @Test func reclamationOnlyRemovesKnownBundledOCRPackages() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime")
        let prefix = "/private/var/containers/Bundle/Application/00000000-0000-0000-0000-000000000001/Aidoku.app/"
        let cases = ["old": prefix + "PP-OCRv6-Medium-RecWidths.mlmodelc/model.mil",
                     "stable": "/Application Support/ReaderCoreMLModels-v1/model/model.mil",
                     "other": prefix + "Other.mlmodelc/model.mil", "mixed": prefix + "PP-OCRv6-Medium-DetShapes.mlmodelc/model.mil"]
        for (name, text) in cases {
            let package = runtime.appendingPathComponent("OS/" + name)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: package.appendingPathComponent("model.mpsgraph"))
            if name == "mixed" { try Data("unknown".utf8).write(to: package.appendingPathComponent("second.mpsgraph")) }
        }
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data((prefix + "PP-OCRv6-Medium-RecWidths.mlmodelc/model.mil").utf8).write(to: outside.appendingPathComponent("model.mpsgraph"))
        try FileManager.default.createSymbolicLink(at: runtime.appendingPathComponent("OS/link"), withDestinationURL: outside)
        NativeCoreMLModelStore(root: root.appendingPathComponent("stable"), runtimeCache: runtime).reclaimLegacyExecutionCache()
        #expect(!FileManager.default.fileExists(atPath: runtime.appendingPathComponent("OS/old").path))
        for name in ["stable", "other", "mixed", "link"] {
            #expect(FileManager.default.fileExists(atPath: runtime.appendingPathComponent("OS/" + name).path))
        }
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("model.mpsgraph").path))
    }
}
