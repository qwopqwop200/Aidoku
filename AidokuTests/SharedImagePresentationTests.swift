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
    }
}
