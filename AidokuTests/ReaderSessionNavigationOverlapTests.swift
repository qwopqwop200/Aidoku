import Darwin
import Foundation
import Testing
import UIKit
import WebKit
@testable import Aidoku

/// Same public-internal Session API on baseline/candidate. No provider/network.
@Suite(.serialized) @MainActor
struct ReaderSessionNavigationOverlapTests {
    private nonisolated static var root: URL { URL.documentsDirectory.appendingPathComponent("DisplayPerformance") }
    struct Inputs: Decodable {
        let sourceImage: String; let regions: String
        let targetLanguage: String?; let viewportWidth: CGFloat?; let viewportHeight: CGFloat?
        let aspectFit: Bool?; let preserveSourceTextColor: Bool?; let preserveSourceBackgroundColor: Bool?
    }
    struct Options: Decodable { let repetitions: Int; let delayMilliseconds: Int }
    @Test(.enabled(if: FileManager.default.fileExists(atPath: root.appendingPathComponent("session-navigation.json").path)))
    func foregroundSessionDelayedResultAndCleanup() async throws {
        let input = try JSONDecoder().decode(Inputs.self, from: Data(contentsOf: Self.root.appendingPathComponent("run.json")))
        let options = try JSONDecoder().decode(Options.self, from: Data(contentsOf: Self.root.appendingPathComponent("session-navigation.json")))
        try #require((2...5).contains(options.repetitions) && (500...2000).contains(options.delayMilliseconds))
        let data = try Data(contentsOf: Self.root.appendingPathComponent(input.sourceImage))
        let regions = try JSONDecoder().decode([ReaderTranslationStoredRegion].self,
            from: Data(contentsOf: Self.root.appendingPathComponent(input.regions))).map(\.region)
        try #require(!regions.isEmpty && regions.allSatisfy { $0.translation?.isEmpty == false })
        let image = try #require(UIImage(data: data))
        let width = input.viewportWidth ?? 430
        let viewport = CGSize(width: width, height: input.viewportHeight ?? width * image.size.height / image.size.width)
        let domain = "SessionNavigation-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.targetLanguage = input.targetLanguage ?? "ko"
        if let value = input.preserveSourceTextColor { settings.overlay.preserveSourceTextColor = value }
        if let value = input.preserveSourceBackgroundColor { settings.overlay.preserveSourceBackgroundColor = value }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.overrideUserInterfaceStyle = .light; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); ReaderTranslationImageExporter.clearIdleRenderer() }
        let folder = Self.root.appendingPathComponent("session-navigation-output")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(image.pngData()).write(to: folder.appendingPathComponent("source.png"))
        var rows: [[String: Any]] = []
        var phases: [[String: Any]] = []
        func recordPhase(_ phase: String, iteration: Int) throws {
            phases.append(["phase": phase, "iteration": iteration, "epoch": Date().timeIntervalSince1970,
                           "uptime": ProcessInfo.processInfo.systemUptime, "footprint": Self.footprint()])
            try JSONSerialization.data(withJSONObject: phases, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("phases.json"), options: .atomic)
        }
        let modes = Array(repeating: "complete", count: options.repetitions) + ["terminate", "post-terminate", "cancel", "leave", "warning", "failure"]
        for (iteration, mode) in modes.enumerated() {
            ReaderTranslationImageExporter.clearIdleRenderer()
            let imageView = UIImageView(image: image)
            imageView.frame = CGRect(origin: .zero, size: viewport)
            imageView.contentMode = input.aspectFit == true ? .scaleAspectFit : .scaleToFill
            window.addSubview(imageView)
            let source = Page(sourceId: "session-navigation", chapterId: "\(domain)-\(iteration)", index: 0, image: image)
            let page = ReaderTranslationPage(imageView: imageView); page.sourcePage = source
            var progressDone = false
            var responseAt: Double?
            var failureDelivered = false
            let startEpoch = Date().timeIntervalSince1970
            try recordPhase("start", iteration: iteration)
            let began = ProcessInfo.processInfo.systemUptime
            let initialMemory = Self.footprint()
            let session = ReaderTranslationSession(process: { _, _, progress in
                var ocr = regions
                for index in ocr.indices { ocr[index].translation = nil }
                try await progress?(ocr)
                // Repeated progress must not create repeated empty documents.
                for _ in 0..<3 { try await progress?(ocr) }
                try recordPhase("progress", iteration: iteration)
                progressDone = true
                try await Task.sleep(for: .milliseconds(options.delayMilliseconds))
                try Task.checkCancellation()
                try recordPhase("response", iteration: iteration)
                responseAt = ProcessInfo.processInfo.systemUptime
                if mode == "failure" { throw RemoteTranslationError.refused }
                return regions
            })
            session.onFailure = { _ in failureDelivered = true }
            defer { session.close(); page.reset(); imageView.removeFromSuperview() }
            session.update(items: [.init(source)], visible: [page], context: "\(domain)-\(iteration)")
            session.enable(settings: settings)
            try await Self.wait { progressDone }
            var waitingViews = imageView.subviews.compactMap { $0 as? ReaderTranslationOverlayView }
            #expect(waitingViews.count <= 1)
            #expect(imageView.image === image && page.regions.isEmpty && !page.canExportTranslation)
            #expect(!page.isShowingProvisionalTranslation)
            for view in waitingViews {
                #expect(view.isHidden && view.webView.isHidden && view.lastDiagnostic?.outcome != .committed)
            }
            // Do not retain this array across cleanup: weak observation must test ownership.
            weak var pending = waitingViews.first
            let pendingIdentity = pending.map(ObjectIdentifier.init)
            let pendingCount = waitingViews.count
            waitingViews.removeAll()
            if mode == "terminate" {
                let doomed = try #require(pending, "Candidate must have a pending document to exercise this regression")
                // Delegate simulation only: real WKWebView navigation/recovery,
                // but no external OS WebContent process was killed by this test.
                doomed.webViewWebContentProcessDidTerminate(doomed.webView)
                #expect(doomed.contentTerminationCount == 1)
                try recordPhase("simulated-pending-process-termination", iteration: iteration)
            }
            let waitingMemory = Self.footprint()
            let pendingDisplay = UIGraphicsImageRenderer(size: viewport).image { _ in
                imageView.drawHierarchy(in: imageView.bounds, afterScreenUpdates: true)
            }
            try #require(pendingDisplay.pngData()).write(to: folder.appendingPathComponent("pending-\(iteration).png"))
            if mode == "complete" || mode == "terminate" || mode == "post-terminate" {
                try await Self.wait { page.hasCompletedTranslation(settings: settings) }
                let overlay = try #require(imageView.subviews.first as? ReaderTranslationOverlayView)
                if let pendingIdentity {
                    if mode == "terminate" {
                        #expect(ObjectIdentifier(overlay) != pendingIdentity)
                        #expect(overlay.contentTerminationCount == 0)
                    } else { #expect(ObjectIdentifier(overlay) == pendingIdentity) }
                }
                try await Self.wait { overlay.lastDiagnostic?.outcome == .committed }
                let commitAt = ProcessInfo.processInfo.systemUptime
                _ = try await overlay.webView.callAsyncJavaScript(
                    "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))",
                    arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
                let paintAt = ProcessInfo.processInfo.systemUptime
                try recordPhase("paint", iteration: iteration)
                #expect(!overlay.isHidden && !overlay.webView.isHidden && imageView.image === image)
                let expected = regions.compactMap { $0.cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)) }
                #expect(page.regions == expected)
                let text = try await overlay.webView.evaluateJavaScript(
                    "Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay=\"item\"]')).map(x=>x.textContent)")
                let displayed: UIImage = try await withCheckedThrowingContinuation { c in
                    overlay.webView.takeSnapshot(with: nil) { result, error in
                        if let result { c.resume(returning: result) }
                        else { c.resume(throwing: error ?? URLError(.cannotDecodeContentData)) }
                    }
                }
                try #require(displayed.pngData()).write(to: folder.appendingPathComponent("display-\(iteration).png"))
                // Diagnostic-only: retain the original first screenshot and strict
                // clean/recovery assertion below. Never replace reference pixels.
                var snapshotDiagnostics: [[String: Any]] = []
                for sample in 1...3 {
                    let geometry = try await overlay.webView.callAsyncJavaScript("""
                    await document.fonts.ready;
                    const source = document.getElementById('reader-source-image');
                    if (source) await source.decode();
                    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
                    const rect = e => {const r=e.getBoundingClientRect();return [r.x,r.y,r.width,r.height]};
                    return {dpr:devicePixelRatio, width:innerWidth,height:innerHeight,
                      viewport:visualViewport ? [visualViewport.width,visualViewport.height,visualViewport.scale] : [],
                      source:source ? {rect:rect(source),natural:[source.naturalWidth,source.naturalHeight],complete:source.complete,
                        transform:getComputedStyle(source).transform,fit:getComputedStyle(source).objectFit,srcLength:source.src.length} : null,
                      items:Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')).map(e=>{
                        const c=getComputedStyle(e);return {text:e.textContent,rect:rect(e),font:c.font,lineHeight:c.lineHeight,
                          color:c.color,background:c.backgroundColor,transform:c.transform,opacity:c.opacity};})};
                    """, arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
                    let repeated: UIImage = try await withCheckedThrowingContinuation { continuation in
                        overlay.webView.takeSnapshot(with: nil) { image, error in
                            if let image { continuation.resume(returning: image) }
                            else { continuation.resume(throwing: error ?? URLError(.cannotDecodeContentData)) }
                        }
                    }
                    let repeatedPNG = try #require(repeated.pngData())
                    try repeatedPNG.write(to: folder.appendingPathComponent("display-\(iteration)-settled-\(sample).png"))
                    snapshotDiagnostics.append(["sample": sample, "epoch": Date().timeIntervalSince1970,
                        "geometry": geometry as Any? ?? NSNull(), "samePNGBytesAsFirst": repeatedPNG == displayed.pngData(),
                        "bounds": NSCoder.string(for: overlay.bounds), "frame": NSCoder.string(for: overlay.frame),
                        "screenScale": overlay.traitCollection.displayScale])
                }
                try JSONSerialization.data(withJSONObject: snapshotDiagnostics, options: [.sortedKeys, .prettyPrinted])
                    .write(to: folder.appendingPathComponent("display-\(iteration)-settled.json"), options: .atomic)
                let export = try await page.exportTranslatedImage(host: window)
                try #require(export.pngData()).write(to: folder.appendingPathComponent("export-\(iteration).png"))
                if mode == "terminate" || mode == "post-terminate" {
                    // Compare matched warm views on both sides of termination.
                    // The original first-cold-vs-warm failure remains archived;
                    // no tolerance or automatic reference replacement is used.
                    let reference = mode == "terminate" ? options.repetitions - 1 : options.repetitions
                    #expect(try Data(contentsOf: folder.appendingPathComponent("display-\(reference).png")) == displayed.pngData(),
                            "Matched warm clean/recovered/clean views must have exact complete pixels")
                    #expect(try Data(contentsOf: folder.appendingPathComponent("export-0.png")) == export.pngData(),
                            "Terminated empty navigation must preserve final exported pixels exactly")
                }
                rows.append(["iteration": iteration, "mode": mode, "startEpoch": startEpoch, "pendingCount": pendingCount,
                    "responseToCommitSeconds": commitAt - (try #require(responseAt)),
                    "responseToTwoRAFSeconds": paintAt - (try #require(responseAt)),
                    "totalToTwoRAFSeconds": paintAt - began, "texts": text as Any? ?? NSNull(),
                    "initialFootprint": initialMemory, "waitingFootprint": waitingMemory, "finalFootprint": Self.footprint()])
            } else {
                try recordPhase(mode, iteration: iteration)
                switch mode {
                case "cancel": session.disable()
                case "leave":
                    let replacementImageView = UIImageView(image: image)
                    let replacement = ReaderTranslationPage(imageView: replacementImageView)
                    session.refreshVisiblePages([replacement])
                    session.pauseForPageTurn()
                case "warning":
                    _ = session.handleMemoryWarning()
                    NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
                default: try await Self.wait { failureDelivered }
                }
                try await Task.sleep(for: .milliseconds(100))
                #expect(imageView.subviews.isEmpty && imageView.image === image)
                #expect(page.regions.isEmpty && !page.canExportTranslation)
                try await Self.wait { pending == nil }
                try recordPhase("released", iteration: iteration)
                session.close()
                rows.append(["iteration": iteration, "mode": mode, "startEpoch": startEpoch, "pendingCount": pendingCount,
                    "initialFootprint": initialMemory, "waitingFootprint": waitingMemory, "finalFootprint": Self.footprint()])
            }
            session.close(); page.reset()
            try await Self.wait { pending == nil }
            try recordPhase("end", iteration: iteration)
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("measurements.json"), options: .atomic)
        }
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() { try #require(Date() < deadline); try await Task.sleep(for: .milliseconds(5)) }
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
