import UIKit

struct ReaderTranslationImageGeometry: Equatable {
    let viewport: CGSize
    let scale: CGFloat
    let aspectFit: Bool
    let dark: Bool

    var isValid: Bool {
        viewport.width.isFinite && viewport.height.isFinite && viewport.width > 0 && viewport.height > 0 &&
            scale.isFinite && scale > 0
    }
}

/// A source-aspect bitmap, ready to attach together with the original UIImage.
/// The loader retains the original for OCR, dictionary lookup and image export.
@MainActor
struct ReaderTranslationPreparedImage {
    let image: UIImage
    let regions: [ReaderTranslationRegion]
    let settings: ReaderTranslationSettings
    var isCurrent: @MainActor () -> Bool = { true }
}

typealias ReaderTranslationImagePreparer = @MainActor (UIImage, Page) async throws -> ReaderTranslationPreparedImage?

/// Legacy text-only caches need a rendering host once. Layout and window events
/// resume that request; decoded images never poll UIKit or wait on image display.
@MainActor
final class ReaderTranslationLayoutAwaiter: UIView {
    nonisolated static let invalidated = Notification.Name("Reader.translation.presentationInvalidated")
    nonisolated static let geometryChanged = Notification.Name("Reader.translation.presentationGeometryChanged")
    private var condition: (() -> Bool)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var observers: [NSObjectProtocol] = []

    static func wait(in view: UIView, until condition: @escaping @MainActor () -> Bool) async throws {
        try Task.checkCancellation()
        if condition() { return }
        let signal = ReaderTranslationLayoutAwaiter(frame: view.bounds)
        signal.condition = condition
        signal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        signal.isUserInteractionEnabled = false
        signal.alpha = 0
        view.addSubview(signal)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        defer { signal.removeFromSuperview() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                signal.continuation = continuation
                signal.check()
            }
        } onCancel: {
            Task { @MainActor [weak signal] in signal?.finish(throwing: CancellationError()) }
        }
        try Task.checkCancellation()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for name in [UIApplication.didBecomeActiveNotification, ReaderTranslationSettings.changed, Self.invalidated, Self.geometryChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.check() }
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    override func layoutSubviews() {
        super.layoutSubviews()
        check()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        check()
    }

    private func check() {
        guard condition?() == true else { return }
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    private func finish(throwing error: Error) {
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: error)
    }
}
