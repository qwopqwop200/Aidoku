import Gifu
import ImageIO
import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Aidoku

@MainActor @Suite(.serialized)
struct GIFImageLifetimeTests {
    private func gifData() throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        for color in [UIColor.red, UIColor.blue] {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            let cgImage = try #require(image.cgImage)
            CGImageDestinationAddImage(destination, cgImage, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]
            ] as CFDictionary)
        }
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func imageView(in view: UIView) -> GIFImageView? {
        if let image = view as? GIFImageView { return image }
        return view.subviews.lazy.compactMap { imageView(in: $0) }.first
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for GIF lifecycle")
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func dismantledViewReleasesFramesAndIdenticalDataAnimatesOnRemount() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let data = try gifData()
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        for _ in 0..<2 {
            host.rootView = AnyView(GIFImage(data: data).frame(width: 32, height: 32))
            try await waitUntil {
                host.view.layoutIfNeeded()
                return imageView(in: host.view)?.frameCount == 2
            }
            let native = try #require(imageView(in: host.view))
            #expect(native.isAnimatingGIF)
            host.rootView = AnyView(EmptyView())
            try await waitUntil {
                host.view.layoutIfNeeded()
                return imageView(in: host.view) == nil
            }
            // Hold the UIKit view deliberately: SwiftUI teardown must release
            // decoded frames even when the discarded view has another owner.
            #expect(native.frameCount == 0)
            #expect(native.activeFrame == nil)
            #expect(native.image == nil)
            #expect(!native.isAnimatingGIF)
        }
    }
}
