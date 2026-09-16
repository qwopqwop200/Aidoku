import CoreML
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
struct UpscaleModelTests {
    @Test func bundledModelsInstallOfflineProcessAndRemove() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ModelManager(directory: directory)
        let catalog = await manager.bundledModels()
        #expect(catalog.count == 5)
        #expect(Set(catalog.map(\.file)).count == 5)
        let oldSelection = manager.getEnabledModelFileName()
        defer { manager.setEnabledModel(fileName: oldSelection) }
        for entry in catalog {
            #expect((entry.size ?? Int.max) < 35_000_000)
            try await manager.downloadModel(entry)
            let installed = await manager.getInstalledModels()
            #expect(installed.contains { $0.file == entry.file })
            let available = await manager.getAvailableModels(includeRemote: false)
            #expect(available?.contains { $0.file == entry.file } == false)
            manager.setEnabledModel(fileName: entry.file)
            let model = try #require(try await manager.getEnabledModel())
            let scale = try #require(entry.config?["scale"]?.intValue)
            // Smaller than every model's tile, with non-square/odd dimensions.
            let source = try makeImage(width: 17, height: 29, color: false)
            let output = try #require(await model.process(source))
            #expect(output.width == source.width * scale)
            #expect(output.height == source.height * scale)
            if entry.config?["grayscaleOnly"]?.boolValue == true {
                let colored = try makeImage(width: 17, height: 29, color: true)
                let unchanged = try #require(await model.process(colored))
                #expect(unchanged === colored)
            }
            if entry.file == "SwinUNetV3Art2x.mlpackage" {
                // Partial right/bottom tiles, spanning three horizontal and two vertical cores.
                let odd = try makeImage(width: 227, height: 117, color: false)
                let tiled = try #require(await model.process(odd))
                #expect(tiled.width == 454)
                #expect(tiled.height == 234)
            }
            await manager.removeModel(withFile: entry.file)
            #expect(manager.getEnabledModelFileName() == nil)
            #expect(await manager.getInstalledModels().isEmpty)
            #expect(await manager.getAvailableModels(includeRemote: false)?.count == 5)
        }
    }

    @Test func tamperedCatalogCannotInstallAndLeavesNoPartialModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ModelManager(directory: directory)
        var entry = try #require(await manager.bundledModels().first)
        entry.sha256 = String(repeating: "0", count: 64)
        do {
            try await manager.downloadModel(entry)
            Issue.record("Tampered model was installed")
        } catch { }
        #expect(await manager.getInstalledModels().isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.isEmpty)
    }

    @Test func imageCacheIdentityTracksModelAndHeight() {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "Data.enabledModelFile")
        let previousHeight = defaults.object(forKey: "Reader.upscaleMaxHeight")
        defer {
            defaults.set(previous, forKey: "Data.enabledModelFile")
            defaults.set(previousHeight, forKey: "Reader.upscaleMaxHeight")
        }
        defaults.set("AnimeSharpV4.mlpackage", forKey: "Data.enabledModelFile")
        defaults.set(1500, forKey: "Reader.upscaleMaxHeight")
        let anime = UpscaleProcessor()
        defaults.set("MangaJaNaiV1-4x1200p.mlpackage", forKey: "Data.enabledModelFile")
        let manga = UpscaleProcessor()
        #expect(anime.identifier != manga.identifier)
        defaults.set(2000, forKey: "Reader.upscaleMaxHeight")
        #expect(manga.identifier != UpscaleProcessor().identifier)
        #expect(anime.identifier.contains("AnimeSharpV4"))
    }

    private func makeImage(width: Int, height: Int, color: Bool) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(color ? UIColor.red.cgColor : UIColor.black.cgColor)
        context.fill(CGRect(x: 2, y: 3, width: 9, height: 13))
        return try #require(context.makeImage())
    }
}
