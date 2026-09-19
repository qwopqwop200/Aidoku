import Foundation
import ObjectiveC.runtime
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct TranslatedTitleLabelNotificationTests {
    @Test func backgroundSettingsNotificationRefreshesLabelOnMainThread() async throws {
        let label = TranslatedTitleLabel(frame: .zero)
        // Nil source avoids unrelated translation tasks regardless of user defaults.
        label.text = nil
        let updates = LabelUpdateRecorder()
        let selector = #selector(setter: UILabel.text)
        let method = try #require(class_getInstanceMethod(UILabel.self, selector))
        let original = method_getImplementation(method)
        let replacement = labelTextProbe(original: original, selector: selector,
            target: ObjectIdentifier(label), updates: updates)
        method_setImplementation(method, replacement)
        defer {
            method_setImplementation(method, original)
            imp_removeBlock(replacement)
        }

        await Task.detached {
            NotificationCenter.default.post(name: ReaderTranslationSettings.changed, object: nil)
        }.value
        for _ in 0..<100 where updates.snapshot().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let recorded = updates.snapshot()
        #expect(!recorded.isEmpty, "The settings event must reach UILabel.text, not just finish posting")
        #expect(recorded.allSatisfy { $0 }, "Every actual UILabel.text change must run on the main thread")
        #expect(label.text == nil)
    }

    @Test func settingsSubscriptionDoesNotRetainReleasedLabel() async {
        weak var released: TranslatedTitleLabel?
        autoreleasepool {
            let label = TranslatedTitleLabel(frame: .zero)
            released = label
            label.text = nil
        }
        #expect(released == nil)
        await Task.detached {
            NotificationCenter.default.post(name: ReaderTranslationSettings.changed, object: nil)
        }.value
        #expect(released == nil)
    }
}

private final class LabelUpdateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var mainThreadUpdates: [Bool] = []

    func record(isMainThread: Bool) {
        lock.lock()
        defer { lock.unlock() }
        mainThreadUpdates.append(isMainThread)
    }

    func snapshot() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return mainThreadUpdates
    }
}

// UILabel's super.text setter bypasses the subclass KVO wrapper. Observe the actual
// public UIKit setter instead, forwarding every call unchanged and filtering by identity.
// Keep this block nonisolated so a regressed background call is recorded rather than
// failing an actor check before the thread assertion can describe the regression.
nonisolated private func labelTextProbe(
    original: IMP, selector: Selector, target: ObjectIdentifier, updates: LabelUpdateRecorder
) -> IMP {
    typealias Setter = @convention(c) (AnyObject, Selector, NSString?) -> Void
    let setter = unsafeBitCast(original, to: Setter.self)
    let block: @convention(block) (AnyObject, NSString?) -> Void = { object, text in
        if ObjectIdentifier(object) == target {
            updates.record(isMainThread: Thread.isMainThread)
        }
        setter(object, selector, text)
    }
    return imp_implementationWithBlock(block)
}
