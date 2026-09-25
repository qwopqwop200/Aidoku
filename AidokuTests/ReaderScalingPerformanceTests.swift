import AidokuRunner
import Foundation
import CryptoKit
import Testing
import UIKit
@testable import Aidoku

// Run this foreground-window performance suite alone: Swift Testing can interleave
// other suites despite xcodebuild's process-level parallel-testing flag.
@Suite(.serialized) @MainActor
struct ReaderScalingPerformanceTests {
    @Test func pagedEntryAndNavigation() async throws {
        let defaults = UserDefaults.standard
        let overrides: [String: Any] = ["Reader.pagesToPreload": 2, "Reader.pagedPageLayout": "single", "Reader.splitWideImages": false,
            "Reader.translation.automatic": false, "Reader.liveText": false, "Dictionary.enable": false,
            "Reader.upscaleImages": false, "Reader.downsampleImages": false, "Reader.cropBorders": false]
        let saved = overrides.keys.reduce(into: [String: Any]()) { if let v = defaults.object(forKey: $1) { $0[$1] = v } }
        overrides.forEach { defaults.set($0.value, forKey: $0.key) }
        defer { for key in overrides.keys { if let v = saved[key] { defaults.set(v, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 128), format: format).image { c in
            UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 64, height: 128))
            UIColor.blue.setFill(); c.fill(CGRect(x: 8, y: 16, width: 48, height: 96))
        }
        let expectedPixelHash = try ScalingPixels.hash(image)
        let output = URL.documentsDirectory.appendingPathComponent("ReaderScaling-\(UUID())")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.keyWindow; let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        var rows: [[String: Any]] = []
        for count in [100, 1000] {
            for iteration in 0..<3 {
                let reader = ReaderPagedViewController(source: nil, manga: .init(sourceKey: "scaling", key: "book", title: "Book"), temporaryPageStore: ReaderTemporaryPageStore())
                reader.readingMode = .ltr
                let chapter = AidokuRunner.Chapter(key: "chapter")
                reader.chapter = chapter
                reader.viewModel.pages = (0..<count).map { Page(sourceId: "scaling", chapterId: "chapter", index: $0, image: image) }
                window.rootViewController = reader; window.makeKeyAndVisible()
                reader.loadViewIfNeeded(); reader.view.layoutIfNeeded()
                let begin = CACurrentMediaTime()
                reader.loadPageControllers(chapter: chapter)
                let constructed = CACurrentMediaTime()
                reader.move(toPage: 1, animated: false)
                try await ready(reader, page: 1)
                let shown = CACurrentMediaTime()
                var navigation: [Double] = []
                for page in [2, 3, count / 2, count - 1, count, 1] {
                    let start = CACurrentMediaTime()
                    reader.move(toPage: page, animated: false)
                    try await ready(reader, page: page)
                    navigation.append((CACurrentMediaTime() - start) * 1000)
                    let displayed = try #require(reader.translationPages().first?.imageView?.image)
                    #expect(try ScalingPixels.hash(displayed) == expectedPixelHash)
                }
                let displayed = try #require(reader.translationPages().first?.imageView?.image)
                try #require(displayed.pngData()).write(to: output.appendingPathComponent("display-\(count)-\(iteration).png"))
                #expect(window.isKeyWindow, "Another UI test took the foreground window")
                let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                try #require(shot.pngData()).write(to: output.appendingPathComponent("screen-\(count)-\(iteration).png"))
                rows.append(["pages": count, "iteration": iteration, "constructMS": (constructed-begin)*1000,
                    "entryToVisibleMS": (shown-begin)*1000, "navigationToVisibleMS": navigation, "exactPixels": true])
                window.rootViewController = nil
            }
        }
        try JSONSerialization.data(withJSONObject: ["rows": rows, "scope": "Release real paged controller, same 64x128 image repeated, programmatic navigation, 5ms ready polling plus 34ms settle, no OCR/network; screenshot after timings"], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"))
    }
    private func ready(_ reader: ReaderPagedViewController, page: Int) async throws {
        for _ in 0..<1000 {
            if reader.view.window?.isKeyWindow == true, reader.currentPage == page, reader.translationPages().contains(where: { $0.sourcePage?.index == page - 1 && $0.imageView?.image != nil && $0.imageView?.window != nil }) {
                try await Task.sleep(for: .milliseconds(34)); return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Page did not become visible")
    }
}

@MainActor private enum ScalingPixels {
    static func hash(_ image: UIImage) throws -> String {
        let cgImage = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: cgImage.width,
                height: cgImage.height, bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }
}
