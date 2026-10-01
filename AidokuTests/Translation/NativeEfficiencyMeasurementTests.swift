import Darwin
import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Opt-in AidokuFull fixture: measures real production entry points without timing assertions.
/// Run this suite alone; concurrent tests would invalidate its process-memory attribution.
@Suite(.serialized) @MainActor
struct NativeEfficiencyMeasurementTests {
    @Test func boundedNativeLiveAndExportMeasurements() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let output = URL.documentsDirectory.appendingPathComponent("NativeEfficiencyMeasurement", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var records: [[String: Any]] = []
        let settings = fixtureSettings()
        // A normal live Result intentionally omits sourcePatches (they are an export-only payload).
        // Measure the known-admitted repair path directly, using the existing worker bridge test's contract.
        for sample in -1..<3 {
            let measured = try await Self.measureSourceCanvas(scale: window.screen.scale)
            append(measured.record, fixture: "source_canvas", phase: "repair_six_patches", sample: sample, into: &records)
            try save(UIImage(cgImage: measured.image), fixture: "source_canvas", phase: "repair_six_patches", sample: sample, output: output)
        }
        for tall in [false, true] {
            let fixture = makeFixture(tall: tall)
            let liveScale: CGFloat = tall ? 2 : window.screen.scale
            let items = ReaderTranslationRegion.layoutItems(fixture.regions, imageSize: fixture.image.size)
            // First pass is a separately labelled warmup; all three following samples are reported.
            for sample in -1..<3 {
                let context = ReaderTranslationDiagnostics.makeContext(pageKey: tall ? "bbbbbbbbbbbbbbbb" : "aaaaaaaaaaaaaaaa", page: sample)
                try await ReaderTranslationDiagnostics.$context.withValue(context) {
                    let planProbe = NativeEfficiencyMemoryProbe()
                    let layout = try await NativeTranslationLayoutPlanner.prepareLayoutData(
                        items: items, imageSize: fixture.image.size,
                        sourceRect: CGRect(origin: .zero, size: fixture.viewport), settings: settings.overlay,
                        targetLanguage: "ko", viewport: fixture.viewport)
                    var planRecord = planProbe.finish()
                    planRecord["encodedBytes"] = layout.count
                    planRecord["operationCounts"] = ["prepareLayoutCalls": 1]
                    append(planRecord, fixture: fixture.name, phase: "layout", sample: sample, into: &records)
                    let decoded = try JSONDecoder().decode(NativeTranslationLayout.self, from: layout)
                    #expect(decoded.imageSize == fixture.image.size && decoded.viewport == fixture.viewport)
                    #expect(decoded.sourceRect == CGRect(origin: .zero, size: fixture.viewport))
                    #expect(decoded.items.map(\.text) == fixture.regions.compactMap(\.translation))
                    #expect(decoded.items.allSatisfy { $0.fontSize > 0 && $0.rect.width > 0 && $0.rect.height > 0 })
                    if sample == 2 { try layout.write(to: output.appendingPathComponent(fixture.name + "-layout.json")) }

                    // Uncached live rendering: the same worker used by ReaderTranslationOverlayView.
                    let liveProbe = NativeEfficiencyMemoryProbe()
                    let live = try await NativeTranslationRenderer.render(
                        image: fixture.image, imageSize: fixture.image.size, items: items, settings: settings.overlay,
                        targetLanguage: "ko", viewport: fixture.viewport, scale: liveScale, aspectFit: false,
                        preparedLayout: layout, composeSource: false)
                    var liveRecord = liveProbe.finish()
                    liveRecord["liveScale"] = liveScale
                    liveRecord["encodedBytes"] = live.layoutData.count
                    liveRecord["operationCounts"] = ["renderCalls": 1, "renderedItems": live.renderedItemCount,
                                                     "sourcePatchesReturned": live.sourcePatches.count]
                    #expect(live.renderedItemCount == fixture.regions.count)
                    // sourcePatchesReturned describes exported payloads, not the number of live repair draws.
                    #expect(live.overlayImage.cgImage?.width == Int(fixture.viewport.width * liveScale))
                    #expect(live.overlayImage.cgImage?.height == Int(fixture.viewport.height * liveScale))
                    append(liveRecord, fixture: fixture.name, phase: "live", sample: sample, into: &records)
                    try save(live.overlayImage, fixture: fixture.name, phase: "live", sample: sample, output: output)

                    let loadedProbe = NativeEfficiencyMemoryProbe()
                    let loaded = try await ReaderTranslationImageExporter.renderLoadedImage(
                        image: fixture.image, regions: fixture.regions, settings: settings,
                        viewport: fixture.viewport, scale: 2, aspectFit: false, dark: false,
                        host: window, cache: nil, key: "measurement-" + fixture.name)
                    var loadedRecord = loadedProbe.finish()
                    loadedRecord["encodedBytes"] = NSNull() // Private intermediate encodes are intentionally not guessed.
                    loadedRecord["operationCounts"] = ["uncachedLoadedImageCalls": 1]
                    append(loadedRecord, fixture: fixture.name, phase: "loaded", sample: sample, into: &records)
                    try validateComposite(loaded, fixture: fixture)
                    try save(loaded, fixture: fixture.name, phase: "loaded", sample: sample, output: output)

                    let snapshotProbe = NativeEfficiencyMemoryProbe()
                    let prepared = Task<Data, Error> { layout }
                    let snapshot = try await ReaderTranslationImageExporter.renderCacheSnapshot(
                        image: fixture.image, imageSize: fixture.image.size, regions: fixture.regions,
                        settings: settings, viewport: fixture.viewport, scale: 2, aspectFit: false,
                        host: window, dark: false, preparedLayout: prepared)
                    var snapshotRecord = snapshotProbe.finish()
                    snapshotRecord["encodedBytes"] = NSNull()
                    snapshotRecord["operationCounts"] = ["uncachedSnapshotCalls": 1]
                    append(snapshotRecord, fixture: fixture.name, phase: "snapshot", sample: sample, into: &records)
                    try validateComposite(snapshot, fixture: fixture)
                    try save(snapshot, fixture: fixture.name, phase: "snapshot", sample: sample, output: output)

                    // Portrait only keeps the vector export portion bounded. Saved callbacks expose actual encoded bytes.
                    if !tall {
                        var pdfBytes = 0, layerBytes = 0, maskCount = 0, maskPNGBytes = 0
                        let exportProbe = NativeEfficiencyMemoryProbe()
                        let exported = try await ReaderTranslationImageExporter.render(
                            image: fixture.image, regions: fixture.regions, settings: settings,
                            viewport: fixture.viewport, aspectFit: false, host: window, hasImagePermit: true,
                            onNativePDFCapture: { data in pdfBytes = data.count },
                            onNativeLayersCapture: { data in
                                layerBytes = data.count
                                let layers = try JSONDecoder().decode(ReaderTranslationImageExporter.ExportLayers.self, from: data)
                                maskCount = layers.masks.count
                                maskPNGBytes = layers.masks.reduce(0) { total, mask in
                                    let payload = mask.png.split(separator: ",", maxSplits: 1).last.map(String.init) ?? ""
                                    return total + (Data(base64Encoded: payload)?.count ?? 0)
                                }
                            })
                        var exportRecord = exportProbe.finish()
                        exportRecord["encodedBytes"] = pdfBytes + layerBytes
                        exportRecord["pdfBytes"] = pdfBytes
                        exportRecord["layersJSONBytes"] = layerBytes
                        exportRecord["maskPNGBytes"] = maskPNGBytes
                        exportRecord["operationCounts"] = ["imageExportCalls": 1, "capturedMasks": maskCount]
                        #expect(pdfBytes > 0 && layerBytes > 0)
                        append(exportRecord, fixture: fixture.name, phase: "pdf_export", sample: sample, into: &records)
                        try validateComposite(exported, fixture: fixture)
                        try save(exported, fixture: fixture.name, phase: "pdf_export", sample: sample, output: output)
                    }
                }
            }
        }
        let report: [String: Any] = ["schemaVersion": 1, "fixtureKind": "deterministic generated source through production APIs",
            "warmupsPerFixture": 1, "samplesPerFixture": 3, "records": records,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "memoryScope": "process RSS/footprint sampled every 2 ms; lifetimePeakRSSBytes is process lifetime, not phase delta",
            "encodedBytesScope": "only actual returned/captured payload bytes; null means unobservable private intermediates",
            "operationCountsScope": "harness invocations, admitted source-canvas paints and returned payload counts; live sourcePatches is export-only and cannot count repairs"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("measurements.json"), options: .atomic)
        print("NATIVE_EFFICIENCY_OUTPUT \(output.path)")
    }

    private func append(_ record: [String: Any], fixture: String, phase: String, sample: Int, into records: inout [[String: Any]]) {
        var value = record
        value["fixture"] = fixture; value["phase"] = phase; value["sample"] = sample; value["warmup"] = sample < 0
        records.append(value)
        print("NATIVE_EFFICIENCY \(fixture) \(phase) sample=\(sample) elapsed_ms=\(record["elapsedMS"] ?? 0) peak_rss=\(record["sampledPeakRSSBytes"] ?? 0)")
    }

    private struct SourceCanvasMeasurement: @unchecked Sendable {
        let record: [String: Any]
        let image: CGImage
    }

    private nonisolated static func measureSourceCanvas(scale: CGFloat) async throws -> SourceCanvasMeasurement {
        try await Task.detached {
            let viewport = CGSize(width: 390, height: 585), bounds = CGRect(origin: .zero, size: viewport)
            let bitmap = try NativeTranslationRenderer.WorkerLiveBitmap(
                pixels: CGSize(width: viewport.width * scale, height: viewport.height * scale), bounds: bounds)
            defer { bitmap.close() }
            let context = try #require(bitmap.context)
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(bounds)
            let source = try #require(CGContext(data: nil, width: 160, height: 160, bitsPerComponent: 8,
                bytesPerRow: 640, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            source.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
            source.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
            let sourceImage = try #require(source.makeImage())
            let patches = (0..<6).map { index in
                NativeTranslationRenderer.SourcePatch(image: sourceImage,
                    rect: CGRect(x: 24 + index % 2 * 170, y: 40 + index / 2 * 150, width: 40, height: 40))
            }
            for patch in patches {
                #expect(NativeTranslationRenderer.admittedHierarchySourceFrame(patch, viewport: viewport, scale: scale) == patch.rect)
            }
            let probe = NativeEfficiencyMemoryProbe()
            var accepted = 0
            for patch in patches {
                if try await NativeTranslationRenderer.paintHierarchySourcePatch(patch,
                    context: context, backing: bitmap.backing, viewport: viewport) { accepted += 1 }
            }
            var record = probe.finish()
            record["liveScale"] = scale
            record["encodedBytes"] = 0 // This production bridge returns a Bool and mutates the existing bitmap.
            record["operationCounts"] = ["sourceCanvasPaintCalls": patches.count, "admittedSourceCanvasPaintCalls": accepted]
            #expect(accepted == 6, "All six requests must reach the actual source-canvas bridge, never fallback")
            // A later draw must stay above the repair; a remote prefix pixel must remain untouched.
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 30, y: 47, width: 5, height: 5))
            let pixels = try #require(bitmap.backing?.backgroundRGBA(context: context, userRect: bounds))
            func pixel(_ x: CGFloat, _ y: CGFloat) -> [UInt8] {
                let offset = Int(y * scale) * context.width * 4 + Int(x * scale) * 4
                return Array(pixels[offset..<offset + 4])
            }
            #expect(pixel(3, 3) == [255, 0, 0, 255])
            #expect(pixel(31, 48) == [0, 0, 255, 255])
            for patch in patches { #expect(pixel(patch.rect.midX, patch.rect.midY) == [0, 255, 0, 255]) }
            return SourceCanvasMeasurement(record: record, image: try #require(context.makeImage()))
        }.value
    }

    private func save(_ image: UIImage, fixture: String, phase: String, sample: Int, output: URL) throws {
        guard sample == 2 else { return }
        // Artifact encoding is excluded from the phase measurement and is never reported as production encoding work.
        try #require(image.pngData()).write(to: output.appendingPathComponent(fixture + "-" + phase + ".png"))
    }

    private struct Fixture {
        let name: String
        let image: UIImage
        let viewport: CGSize
        let regions: [ReaderTranslationRegion]
    }

    private func fixtureSettings() -> ReaderTranslationSettings {
        var value = ReaderTranslationSettings()
        value.overlay = ReaderTranslationSettings.defaultOverlay
        value.overlay.preserveSourceColors = true
        value.targetLanguage = "ko"
        return value
    }

    private func makeFixture(tall: Bool) -> Fixture {
        let size = CGSize(width: 780, height: tall ? 2340 : 1170)
        let count = tall ? 6 : 4
        let regions = (0..<count).map { index in
            let rect = CGRect(x: index % 2 == 0 ? 0.12 : 0.57,
                              y: 0.08 + CGFloat(index / 2) * (tall ? 0.3 : 0.45), width: 0.27, height: tall ? 0.1 : 0.19)
            return ReaderTranslationRegion(id: "fixture-\(index)", rect: rect,
                source: "明日はきっと大丈夫", translation: "내일은 분명 괜찮을 거야. \(index)", sourceOrientation: .horizontal)
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        let source = UIGraphicsImageRenderer(size: size, format: format).image { drawing in
            UIColor(white: 0.94, alpha: 1).setFill(); drawing.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1).setFill()
            drawing.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            for region in regions {
                let box = CGRect(x: region.rect.minX * size.width, y: region.rect.minY * size.height,
                                 width: region.rect.width * size.width, height: region.rect.height * size.height)
                UIColor.white.setFill(); UIBezierPath(roundedRect: box.insetBy(dx: -12, dy: -12), cornerRadius: 24).fill()
                (region.source as NSString).draw(in: box.insetBy(dx: 12, dy: 15), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 25), .foregroundColor: UIColor.black])
            }
        }
        return Fixture(name: tall ? "tall" : "portrait", image: source,
                       viewport: CGSize(width: 390, height: size.height / 2), regions: regions)
    }

    private func validateComposite(_ image: UIImage, fixture: Fixture) throws {
        let actual = try #require(image.cgImage)
        #expect(actual.width == Int(fixture.image.size.width) && actual.height == Int(fixture.image.size.height))
        let reference = try #require(fixture.image.cgImage)
        let crop = CGRect(x: 4, y: 4, width: 8, height: 8)
        let a = try #require(actual.cropping(to: crop).flatMap { NativeOCRCGImageAdapter.makeRGBAFrame(from: $0) })
        let b = try #require(reference.cropping(to: crop).flatMap { NativeOCRCGImageAdapter.makeRGBAFrame(from: $0) })
        #expect(a.bytes.count == b.bytes.count)
        // A remote solid source-art marker must remain intact; AA tolerance applies only to glyph contours.
        #expect(zip(a.bytes, b.bytes).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
    }
}

private final class NativeEfficiencyMemoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "native-efficiency-memory", qos: .utility))
    private let start = ProcessInfo.processInfo.systemUptime
    private let initial: (rss: UInt64, footprint: UInt64)
    private var peakRSS: UInt64 = 0
    private var peakFootprint: UInt64 = 0
    private var samples = 0

    init() {
        initial = Self.memory()
        sample()
        timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }

    deinit { timer.cancel() }

    func finish() -> [String: Any] {
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        timer.cancel()
        sample()
        let end = Self.memory()
        var usage = rusage()
        let usageStatus = getrusage(RUSAGE_SELF, &usage)
        return lock.withLock {
            ["elapsedMS": elapsed, "rssBeforeBytes": initial.rss, "rssAfterBytes": end.rss,
             "sampledPeakRSSBytes": peakRSS, "sampledPeakFootprintBytes": peakFootprint,
             "footprintBeforeBytes": initial.footprint, "footprintAfterBytes": end.footprint,
             "memorySamples": samples, "lifetimePeakRSSBytes": usageStatus == 0 ? Int64(usage.ru_maxrss) : -1]
        }
    }

    private func sample() {
        let value = Self.memory()
        lock.withLock { peakRSS = max(peakRSS, value.rss); peakFootprint = max(peakFootprint, value.footprint); samples += 1 }
    }

    private static func memory() -> (rss: UInt64, footprint: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? (info.resident_size, info.phys_footprint) : (0, 0)
    }
}
