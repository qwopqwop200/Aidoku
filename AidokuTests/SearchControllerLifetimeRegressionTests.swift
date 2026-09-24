import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct SearchControllerLifetimeRegressionTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("Round2UI/enabled").path)))
    func dismissedActualSearchControllerReleasesHostedClosures() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UINavigationController(rootViewController: UIViewController())
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        weak var released: SearchViewController?
        var controller: SearchViewController? = SearchViewController()
        released = controller
        host.pushViewController(try #require(controller), animated: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller?.view.window === window)
        host.popViewController(animated: false)
        controller = nil
        let deadline = Date().addingTimeInterval(5)
        while released != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(released == nil)
    }
}
