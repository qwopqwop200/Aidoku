import AidokuRunner
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationDismissalTests {
    @Test(arguments: [false, true], [false, true])
    func interruptedDismissalKeepsTheDisplayedTranslation(completes: Bool, usesUIKitTransition: Bool) async throws {
        let automaticKey = ReaderTranslationSettings.keyPrefix + "automatic"
        let previousAutomatic = UserDefaults.standard.object(forKey: automaticKey)
        UserDefaults.standard.set(true, forKey: automaticKey)
        defer {
            if let previousAutomatic { UserDefaults.standard.set(previousAutomatic, forKey: automaticKey) }
            else { UserDefaults.standard.removeObject(forKey: automaticKey) }
        }

        let controller = DismissalReaderController(source: nil,
            manga: .init(sourceKey: "dismissal-test", key: UUID().uuidString, title: "Dismissal"),
            chapter: .init(key: "chapter"))
        controller.readingMode = .ltr
        controller.loadViewIfNeeded()
        let reader = DismissalPageController()
        controller.reader = reader
        controller.view.addSubview(reader.view)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let presenter = UIViewController()
        let transition = DismissalTransition()
        if usesUIKitTransition {
            window.rootViewController = presenter
            window.makeKeyAndVisible()
            controller.modalPresentationStyle = .custom
            controller.transitioningDelegate = transition
            await withCheckedContinuation { continuation in
                presenter.present(controller, animated: false) { continuation.resume() }
            }
        } else {
            controller.beginAppearanceTransition(true, animated: false)
            controller.endAppearanceTransition()
        }
        defer {
            controller.close()
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }

        // Let the normal startup debounce activate the real coordinator, without
        // chapter items that would start OCR or make a provider request.
        try await Task.sleep(for: .milliseconds(450))
        var settings = ReaderTranslationSettings()
        settings.overlay.visible = true
        reader.page.displayLoadedImage(.init(image: reader.translated, regions: [], settings: settings))
        controller.translationVisibilityDidChange()
        let overlay = try #require(reader.imageView.subviews.first as? UIImageView)
        #expect(overlay.image === reader.translated)
        #expect(!overlay.isHidden)

        // UIKit calls willDisappear at the start of a pull-to-dismiss, even if
        // the user reverses it. Translation must stay attached throughout it.
        if usesUIKitTransition {
            transition.isInteractive = true
            controller.dismiss(animated: true)
            try await Task.sleep(for: .milliseconds(50))
            transition.interaction.update(0.15)
        } else {
            controller.beginAppearanceTransition(false, animated: true)
        }
        #expect(overlay.superview === reader.imageView)
        #expect(!overlay.isHidden)
        try await Task.sleep(for: .milliseconds(100))
        #expect(reader.page.isUsingCachedRendering)

        if usesUIKitTransition {
            if completes { transition.interaction.finish() } else { transition.interaction.cancel() }
            let deadline = Date().addingTimeInterval(3)
            while !transition.completed, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(transition.completed)
            #expect((presenter.presentedViewController == nil) == completes)
        } else if completes {
            controller.endAppearanceTransition()
        } else {
            controller.beginAppearanceTransition(true, animated: true)
            controller.endAppearanceTransition()
        }
        if completes {
            #expect(overlay.superview == nil, "A completed departure must still release the rendering")
            #expect(!reader.page.isUsingCachedRendering)
        } else {
            // Reverse the appearance transition as UIKit does for a cancelled
            // dismissal. Assert synchronously: a later rebuilt image is a failure.
            #expect(overlay.superview === reader.imageView)
            #expect(!overlay.isHidden)
            #expect(overlay.image === reader.translated)
            #expect(reader.page.hasLoadedCachedPresentation)
            try await Task.sleep(for: .milliseconds(450))
            #expect(reader.imageView.subviews.first === overlay)
            #expect(!overlay.isHidden)
        }
        #expect(ReaderTranslationSettings().automaticallyTranslate)
        withExtendedLifetime(reader) {}
    }
}

@MainActor private final class DismissalTransition: NSObject,
    UIViewControllerTransitioningDelegate, UIViewControllerAnimatedTransitioning {
    let interaction = UIPercentDrivenInteractiveTransition()
    var isInteractive = false
    var completed = false

    func animationController(forDismissed dismissed: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        self
    }

    func interactionControllerForDismissal(using animator: any UIViewControllerAnimatedTransitioning)
        -> (any UIViewControllerInteractiveTransitioning)? {
        isInteractive ? interaction : nil
    }

    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval { 0.25 }

    func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
        guard let view = transitionContext.view(forKey: .from) else {
            transitionContext.completeTransition(false)
            completed = true
            return
        }
        UIView.animate(withDuration: transitionDuration(using: transitionContext), animations: {
            view.transform = CGAffineTransform(translationX: 0, y: transitionContext.containerView.bounds.height)
        }, completion: { _ in
            let cancelled = transitionContext.transitionWasCancelled
            if cancelled { view.transform = .identity }
            transitionContext.completeTransition(!cancelled)
            self.completed = true
        })
    }
}

/// Use the production reader's appearance methods and translation coordinator,
/// while omitting unrelated chapter loading, settings observers, and toolbars.
@MainActor private final class DismissalReaderController: ReaderViewController {
    override func configure() {}
    override func constrain() {}
    override func observe() {}
}

@MainActor private final class DismissalPageController: UIViewController, ReaderReaderDelegate {
    var readingMode: ReadingMode = .ltr
    weak var delegate: ReaderHoldingDelegate?
    let imageView: UIImageView
    let translated: UIImage
    let page: ReaderTranslationPage

    init() {
        let size = CGSize(width: 160, height: 240)
        let renderer = UIGraphicsImageRenderer(size: size)
        let source = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        translated = renderer.image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        imageView = UIImageView(image: source)
        page = ReaderTranslationPage(imageView: imageView)
        page.sourcePage = Page(sourceId: "dismissal-test", chapterId: UUID().uuidString, index: 0)
        super.init(nibName: nil, bundle: nil)
        view.addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func moveLeft() {}
    func moveRight() {}
    func sliderMoved(value: CGFloat) {}
    func sliderStopped(value: CGFloat) {}
    func setChapter(_ chapter: AidokuRunner.Chapter, startPage: Int) {}
    func translationPages() -> [ReaderTranslationPage] { [page] }
}
