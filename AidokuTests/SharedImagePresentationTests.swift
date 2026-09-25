import SwiftUI
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct SharedImagePresentationTests {
    @Test(arguments: [false, true])
    func presentsOverNavigationAndSwiftUISettings(settingsSelected: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let tabs = UITabBarController()
        tabs.viewControllers = [UINavigationController(rootViewController: UIViewController()),
                                UIHostingController(rootView: Text("Settings"))]
        tabs.selectedIndex = settingsSelected ? 1 : 0
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let presenter = try #require(AppDelegate.sharedImagePresenter(in: window))
        #expect(presenter === tabs)
        let reader = UIViewController()
        AppDelegate.presentSharedImageController(reader, from: presenter)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(tabs.presentedViewController === reader)
        #expect(reader.view.window === window)
        tabs.dismiss(animated: false)
    }

    @Test func unavailableWindowDoesNotConsumeSharedImages() {
        #expect(AppDelegate.sharedImagePresenter(in: nil) == nil)
        #expect(AppDelegate.sharedImagePresenter(in: UIWindow()) == nil)
        let detachedWindow = UIWindow()
        detachedWindow.rootViewController = UIViewController()
        #expect(AppDelegate.sharedImagePresenter(in: detachedWindow) == nil)
    }

    @Test func replacesSharedImageWhileFullScreenControllerIsOpen() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            root.dismiss(animated: false)
            window.isHidden = true
        }
        let first = UIViewController()
        first.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in
            root.present(first, animated: false) { continuation.resume() }
        }
        // UIKit removes the presenting view after a full-screen presentation.
        #expect(root.viewIfLoaded?.window == nil)
        #expect(first.view.window === window)
        let presenter = try #require(AppDelegate.sharedImagePresenter(in: window))
        #expect(presenter === root)
        let second = UIViewController()
        AppDelegate.presentSharedImageController(second, from: presenter)
        for _ in 0..<100 {
            if root.presentedViewController === second, !second.isBeingPresented { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(root.presentedViewController === second)
        #expect(second.view.window === window)
        #expect(first.presentingViewController == nil)
    }
}
