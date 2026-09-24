import Darwin
import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Real window attachment of an empty production collection controller.
/// This isolates controller lifetime; it does not measure image/OCR/network workloads.
@Suite(.serialized) @MainActor
struct FullAuditNavigationMemoryTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("FullAuditNavigationMemory/enabled").path)))
    func repeatedVisibleEmptyListReleasesControllers() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("FullAuditNavigationMemory")
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        var references: [AuditWeakCollection] = []
        var rows: [[String: Any]] = []
        func save() throws {
            try JSONSerialization.data(withJSONObject: [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "device": UIDevice.current.model,
                "scope": "Empty MangaCollectionViewController list layout; real UIWindow attach/detach; 5 warmup + 25 measured iterations; no image requests, OCR or network",
                "metricsLimit": "RSS/phys_footprint samples are process-wide, not allocation peaks; display-link gaps and main-queue delay are not Instruments hitch classification",
                "rows": rows
            ], options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("navigation-memory.json"), options: .atomic)
        }
        for iteration in 0..<30 {
            let before = memory()
            let start = CACurrentMediaTime()
            // A separate async scope drops all strong local controller references
            // before the post-detach frames and weak-reference check.
            let result = try await attachAndDetach(window: window, screenshot:
                iteration == 0 || iteration == 29 ? directory.appendingPathComponent("visible-\(iteration).png") : nil)
            references.append(result.reference)
            let detachedProbe = AuditDisplayFrames()
            try await detachedProbe.wait()
            let callbackStart = CACurrentMediaTime()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            let callbackDelay = (CACurrentMediaTime() - callbackStart) * 1000
            let after = memory()
            rows.append([
                "iteration": iteration, "phase": iteration < 5 ? "warmup" : "measured",
                "attachedTwoFramesMS": result.visibleMS,
                "attachedFrameGapsMS": result.frameGaps,
                "iterationMS": (CACurrentMediaTime() - start) * 1000,
                "mainQueueCallbackDelayMS": callbackDelay,
                "rssBeforeBytes": before.rss, "rssAfterBytes": after.rss,
                "physFootprintBeforeBytes": before.footprint, "physFootprintAfterBytes": after.footprint,
                "memoryStatusBefore": before.status, "memoryStatusAfter": after.status,
                "retainedControllers": references.filter { $0.value != nil }.count,
                "createdControllers": references.count
            ])
            try save()
        }
        // Allow pending UIKit autorelease work to drain without hiding baseline leaks.
        let finalFrames = AuditDisplayFrames()
        try await finalFrames.wait()
        let retained = references.filter { $0.value != nil }.count
        rows.append(["phase": "final", "retainedControllers": retained, "createdControllers": references.count])
        try save()
        #expect(retained == 0, "Released empty controllers must not remain retained by their compositional layout")
    }

    private func attachAndDetach(window: UIWindow, screenshot: URL?) async throws
        -> (reference: AuditWeakCollection, visibleMS: Double, frameGaps: [Double]) {
        let controller = MangaCollectionViewController()
        controller.usesListLayout = true
        controller.entries = []
        let reference = AuditWeakCollection(controller)
        let probe = AuditDisplayFrames()
        let start = CACurrentMediaTime()
        window.rootViewController = controller
        controller.loadViewIfNeeded()
        controller.hideLoadingView()
        controller.updateDataSource()
        controller.view.layoutIfNeeded()
        try await probe.wait()
        let visibleMS = (CACurrentMediaTime() - start) * 1000
        try #require(controller.view.window === window)
        #expect(controller.dataSource.snapshot().numberOfItems == 0)
        if let screenshot {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try #require(image.pngData()).write(to: screenshot, options: .atomic)
        }
        window.rootViewController = UIViewController()
        return (reference, visibleMS, probe.gaps)
    }

    private func memory() -> (rss: UInt64, footprint: UInt64, status: Int32) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return (info.resident_size, info.phys_footprint, status)
    }
}

@MainActor private final class AuditWeakCollection {
    weak var value: MangaCollectionViewController?
    init(_ value: MangaCollectionViewController) { self.value = value }
}

@MainActor private final class AuditDisplayFrames: NSObject {
    private var displayLink: CADisplayLink?
    private var pending: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var last = 0.0
    private(set) var gaps: [Double] = []
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            last = CACurrentMediaTime()
            displayLink = CADisplayLink(target: self, selector: #selector(tick))
            displayLink?.add(to: .main, forMode: .common)
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.finish(error: AuditFrameError.timeout)
            }
        }
    }
    @objc private func tick() {
        let now = CACurrentMediaTime()
        gaps.append((now - last) * 1000)
        last = now
        if gaps.count == 2 { finish(error: nil) }
    }
    private func finish(error: Error?) {
        displayLink?.invalidate(); displayLink = nil
        timeout?.cancel(); timeout = nil
        let continuation = pending; pending = nil
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }
}
private enum AuditFrameError: Error { case timeout }
