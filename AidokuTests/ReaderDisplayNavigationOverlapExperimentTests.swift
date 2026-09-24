import Darwin
import Foundation
import Testing
import UIKit
import WebKit
@testable import Aidoku

/// Investigation only: no product scheduling change, provider call, or shared data store.
/// Opt in with Documents/DisplayPerformance/navigation-overlap.json and existing run.json.
@Suite(.serialized) @MainActor
struct ReaderDisplayNavigationOverlapExperimentTests {
    private nonisolated static var root: URL { URL.documentsDirectory.appendingPathComponent("DisplayPerformance") }
    @Test(.enabled(if: FileManager.default.fileExists(atPath: root.appendingPathComponent("navigation-overlap.json").path)))
    func sameFutureViewNavigationOverlapsFixedResponseWait() async throws {
        struct Inputs: Decodable {
            let sourceImage: String; let regions: String
            let targetLanguage: String?; let viewportWidth: CGFloat?; let viewportHeight: CGFloat?
            let aspectFit: Bool?; let preserveSourceTextColor: Bool?; let preserveSourceBackgroundColor: Bool?
        }
        struct Options: Decodable { let repetitions: Int; let delayMilliseconds: Int }
        let inputs = try JSONDecoder().decode(Inputs.self, from: Data(contentsOf: Self.root.appendingPathComponent("run.json")))
        let options = try JSONDecoder().decode(Options.self, from: Data(contentsOf: Self.root.appendingPathComponent("navigation-overlap.json")))
        try #require((1...5).contains(options.repetitions) && (0...2000).contains(options.delayMilliseconds))
        let data = try Data(contentsOf: Self.root.appendingPathComponent(inputs.sourceImage))
        let regions = try JSONDecoder().decode([ReaderTranslationStoredRegion].self,
            from: Data(contentsOf: Self.root.appendingPathComponent(inputs.regions))).map(\.region)
        try #require(!regions.isEmpty && regions.allSatisfy { $0.translation?.isEmpty == false })
        let original = try #require(UIImage(data: data))
        let width = inputs.viewportWidth ?? 430
        let viewport = CGSize(width: width, height: inputs.viewportHeight ?? width * original.size.height / original.size.width)
        let suite = "NavigationOverlap-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.targetLanguage = inputs.targetLanguage ?? "ko"
        if let value = inputs.preserveSourceTextColor { settings.overlay.preserveSourceTextColor = value }
        if let value = inputs.preserveSourceBackgroundColor { settings.overlay.preserveSourceBackgroundColor = value }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.overrideUserInterfaceStyle = .light; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); ReaderTranslationImageExporter.clearIdleRenderer() }
        let folder = Self.root.appendingPathComponent("navigation-overlap-output")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var rows: [[String: Any]] = []
        for iteration in 0..<options.repetitions {
            var exports: [Bool: Data] = [:]
            var displays: [Bool: Data] = [:]
            // Alternate order so process warm-up cannot systematically favor the experiment.
            for early in iteration.isMultiple(of: 2) ? [false, true] : [true, false] {
                ReaderTranslationImageExporter.clearIdleRenderer()
                let image = try #require(UIImage(data: data))
                let imageView = UIImageView(image: image); imageView.frame = CGRect(origin: .zero, size: viewport)
                window.addSubview(imageView)
                let startFootprint = Self.footprint()
                let started = ProcessInfo.processInfo.systemUptime
                var overlay: ReaderTranslationOverlayView?
                if early {
                    overlay = ReaderTranslationOverlayView(frame: imageView.bounds)
                    imageView.addSubview(try #require(overlay))
                }
                defer { overlay?.cancelWork(); overlay?.removeFromSuperview(); imageView.removeFromSuperview() }
                try await Task.sleep(for: .milliseconds(options.delayMilliseconds))
                #expect(imageView.image === image)
                if let overlay {
                    #expect(overlay.webView.isHidden)
                    #expect(overlay.lastDiagnostic?.outcome != .committed)
                    #expect(overlay.webView.configuration.websiteDataStore.isPersistent == false)
                }
                let responseAt = ProcessInfo.processInfo.systemUptime
                let waitingFootprint = Self.footprint()
                if overlay == nil {
                    overlay = ReaderTranslationOverlayView(frame: imageView.bounds)
                    imageView.addSubview(try #require(overlay))
                }
                let active = try #require(overlay)
                var commit: Double?
                active.onRenderCommitted = { commit = ProcessInfo.processInfo.systemUptime }
                active.update(regions: regions, imageSize: image.size, aspectFit: inputs.aspectFit ?? false,
                    settings: settings, image: image)
                active.layoutIfNeeded()
                let deadline = Date().addingTimeInterval(20)
                while commit == nil {
                    try #require(Date() < deadline)
                    try await Task.sleep(for: .milliseconds(5))
                }
                _ = try await active.webView.callAsyncJavaScript(
                    "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))",
                    arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
                let paintedAt = ProcessInfo.processInfo.systemUptime
                let texts = try await active.webView.evaluateJavaScript(
                    "Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay=\"item\"]')).map(x=>x.textContent)")
                let display: UIImage = try await withCheckedThrowingContinuation { continuation in
                    active.webView.takeSnapshot(with: nil) { image, error in
                        if let image { continuation.resume(returning: image) }
                        else { continuation.resume(throwing: error ?? URLError(.cannotDecodeContentData)) }
                    }
                }
                let png = try #require(display.pngData()); displays[early] = png
                try png.write(to: folder.appendingPathComponent("display-\(iteration)-\(early).png"))
                let exported = try await ReaderTranslationImageExporter.render(image: image, regions: regions,
                    settings: settings, viewport: viewport, aspectFit: inputs.aspectFit ?? false, host: window)
                let exportPNG = try #require(exported.pngData()); exports[early] = exportPNG
                try exportPNG.write(to: folder.appendingPathComponent("export-\(iteration)-\(early).png"))
                rows.append(["iteration": iteration, "earlyNavigation": early, "regions": regions.count,
                    "fixedResponseDelayMilliseconds": options.delayMilliseconds,
                    "startToResponseSeconds": responseAt - started,
                    "responseToCommitSeconds": try #require(commit) - responseAt,
                    "responseToTwoRAFSeconds": paintedAt - responseAt,
                    "startFootprintBytes": startFootprint, "waitingFootprintBytes": waitingFootprint,
                    "endFootprintBytes": Self.footprint(), "displayTexts": texts as Any? ?? NSNull(),
                    "scope": "test-only same-view precreation; fixed wait, no actual provider; app footprint excludes WebContent; root must sample child processes/host pressure"])
                try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                    .write(to: folder.appendingPathComponent("measurements.json"), options: .atomic)
            }
            #expect(exports[false] == exports[true], "Exact exported PNG equality; no tolerance")
            #expect(displays[false] == displays[true], "Exact visible PNG equality; no tolerance")
        }
    }
    private nonisolated static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
