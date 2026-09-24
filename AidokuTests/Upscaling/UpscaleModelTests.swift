import CoreML
import Darwin
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
struct UpscaleModelTests {
    @Test func bundledModelsInstallOfflineProcessAndRemove() async throws {
        let auditRoot = URL.documentsDirectory.appendingPathComponent("FullAuditUpscale", isDirectory: true)
        let auditEnabled = FileManager.default.fileExists(atPath: auditRoot.appendingPathComponent("enabled").path)
        let auditDirectory = auditRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var auditRows: [[String: Any]] = []
        if auditEnabled { try FileManager.default.createDirectory(at: auditDirectory, withIntermediateDirectories: true) }
        @Sendable func memorySample() -> [String: Double] {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return ["time": CFAbsoluteTimeGetCurrent(),
                "rssMiB": status == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1,
                "footprintMiB": status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1]
        }
        func savePNG(_ image: CGImage, _ name: String) throws {
            guard auditEnabled else { return }
            try #require(UIImage(cgImage: image).pngData()).write(to: auditDirectory.appendingPathComponent(name), options: .atomic)
        }
        func rgba(_ image: CGImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try bytes.withUnsafeMutableBytes { storage in
                let context = try #require(CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        func saveAudit() throws {
            guard auditEnabled else { return }
            let payload: [String: Any] = ["rows": auditRows, "sampleIntervalMS": 10,
                "scope": "Sequential model.process wall time only. First call includes first inference costs; later calls same model/source. PNG and pixel verification excluded from timing. Sampled process RSS/footprint are not true transient peak or device Jetsam proof."]
            try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
                .write(to: auditDirectory.appendingPathComponent("results.json"), options: .atomic)
        }
        let realInputURL = auditRoot.appendingPathComponent("input.png")
        let realInput: CGImage?
        if auditEnabled && FileManager.default.fileExists(atPath: realInputURL.path) {
            let image = try #require(UIImage(contentsOfFile: realInputURL.path)?.cgImage)
            try #require(image.width > 0 && image.height > 0 && image.width <= 256 && image.height <= 256,
                "Real-image audit is bounded to 256x256; prepare the exact crop before execution")
            realInput = image
        } else { realInput = nil }
        func requiresColorBypass(_ image: CGImage) throws -> Bool {
            var bytes = [UInt8](repeating: 255, count: image.width * image.height * 4)
            try bytes.withUnsafeMutableBytes { storage in
                let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
                let context = try #require(CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue))
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            for index in stride(from: 0, to: bytes.count, by: 4) {
                let red = Int(bytes[index])
                let green = Int(bytes[index + 1])
                let blue = Int(bytes[index + 2])
                let largest = max(red, max(green, blue))
                let smallest = min(red, min(green, blue))
                if largest - smallest > 8 { return true }
            }
            return false
        }
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
            let source = try realInput ?? makeImage(width: 17, height: 29, color: false)
            let expectedColorBypass = try entry.config?["grayscaleOnly"]?.boolValue == true && requiresColorBypass(source)
            try savePNG(source, "\(entry.file)-source.png")
            var firstPixels: [UInt8]?
            for iteration in 0..<(auditEnabled ? 3 : 1) {
                let before = auditEnabled ? memorySample() : [:]
                let sampler: Task<[[String: Double]], Never>? = auditEnabled ? Task.detached(priority: .utility) {
                    var samples: [[String: Double]] = []
                    while !Task.isCancelled {
                        samples.append(memorySample())
                        do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
                    }
                    return samples
                } : nil
                let start = CFAbsoluteTimeGetCurrent()
                let processed = await model.process(source)
                let milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1_000
                let after = auditEnabled ? memorySample() : [:]
                sampler?.cancel()
                let samples = await sampler?.value ?? []
                let output = try #require(processed)
                if expectedColorBypass {
                    #expect(output === source)
                    #expect(try rgba(output) == rgba(source))
                } else {
                    #expect(output.width == source.width * scale)
                    #expect(output.height == source.height * scale)
                }
                if auditEnabled {
                    let pixels = try rgba(output)
                    let exact = firstPixels.map { $0 == pixels } ?? true
                    #expect(exact, "Same model/input must produce exactly equal decoded RGBA across repeats")
                    if firstPixels == nil { firstPixels = pixels }
                    let name = "\(entry.file)-output-\(iteration).png"
                    try savePNG(output, name)
                    let allSamples = [before] + samples + [after]
                    auditRows.append(["model": entry.file, "iteration": iteration, "milliseconds": milliseconds,
                        "inputWidth": source.width, "inputHeight": source.height,
                        "inputKind": realInput == nil ? "synthetic17x29" : "realOptInCrop",
                        "expectedColorBypass": expectedColorBypass,
                        "outputWidth": output.width, "outputHeight": output.height, "outputPNG": name,
                        "exactRGBAWithFirst": exact, "memorySamples": allSamples,
                        "sampledPeakRSSMiB": allSamples.compactMap { $0["rssMiB"] }.max() ?? -1,
                        "sampledPeakFootprintMiB": allSamples.compactMap { $0["footprintMiB"] }.max() ?? -1])
                    try saveAudit()
                }
            }
            if entry.config?["grayscaleOnly"]?.boolValue == true {
                let colored = try makeImage(width: 17, height: 29, color: true)
                let unchanged = try #require(await model.process(colored))
                #expect(unchanged === colored)
                try savePNG(colored, "\(entry.file)-colored-source.png")
                try savePNG(unchanged, "\(entry.file)-colored-unchanged.png")
                if auditEnabled { #expect(try rgba(colored) == rgba(unchanged)) }
            }
            if entry.file == "SwinUNetV3Art2x.mlpackage" {
                // Partial right/bottom tiles, spanning three horizontal and two vertical cores.
                let odd = try makeImage(width: 227, height: 117, color: false)
                let tiled = try #require(await model.process(odd))
                #expect(tiled.width == 454)
                #expect(tiled.height == 234)
                try savePNG(odd, "\(entry.file)-partial-tiles-source.png")
                try savePNG(tiled, "\(entry.file)-partial-tiles-output.png")
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
