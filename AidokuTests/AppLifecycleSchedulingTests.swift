import Combine
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct AppLifecycleSchedulingTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for lifecycle state")
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func supersededSourceCallbackCannotPublishAfterLatestChange() async throws {
        let scheduler = SettingChangeScheduler()
        var oldCallback: CheckedContinuation<Void, Never>?
        var commits: [String] = []
        scheduler.schedule(delayNanoseconds: 0, operation: {
            await withCheckedContinuation { oldCallback = $0 }
        }, commit: { commits.append("obsolete") })
        try await waitUntil { oldCallback != nil }
        let callback = try #require(oldCallback)
        scheduler.schedule(delayNanoseconds: 0, operation: {}, commit: { commits.append("latest") })
        try await waitUntil { !commits.isEmpty }
        #expect(commits == ["latest"])
        callback.resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(commits == ["latest"])
    }

    @Test func reentrantCommitKeepsNewTaskCancellable() async throws {
        let scheduler = SettingChangeScheduler()
        var scheduledSecond = false
        var obsoleteOperations = 0
        var latestCommitted = false
        scheduler.schedule(delayNanoseconds: 0, operation: {}, commit: {
            scheduler.schedule(delayNanoseconds: 100_000_000, operation: {
                obsoleteOperations += 1
            }, commit: {})
            scheduledSecond = true
        })
        try await waitUntil { scheduledSecond }
        #expect(scheduledSecond)
        scheduler.schedule(delayNanoseconds: 0, operation: {}, commit: { latestCommitted = true })
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(latestCommitted)
        #expect(obsoleteOperations == 0)
    }

    @Test func clearReplacesBufferedStreamAndPreservesNewEntries() async throws {
        let store = LogStore()
        let controller = LogViewController(store: store)
        controller.loadViewIfNeeded()
        let text = try #require(controller.view.subviews.compactMap { $0 as? UITextView }.first)
        controller.viewWillAppear(false)
        await store.addEntry(level: .info, message: "before-clear")
        controller.clearLog()
        await controller.clearTask?.value
        await store.addEntry(level: .info, message: "after-clear")
        try await waitUntil { text.text == "[INFO] after-clear\n" }
        #expect(text.text == "[INFO] after-clear\n")
        controller.viewDidDisappear(false)
        controller.clearLog()
        await controller.clearTask?.value
        await store.addEntry(level: .info, message: "hidden")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(text.text.isEmpty)
    }

    private final class EditCounter: NSObject, NSTextStorageDelegate {
        var edits = 0
        func textStorage(
            _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
            range editedRange: NSRange, changeInLength delta: Int
        ) {
            if editedMask.contains(.editedCharacters) { edits += 1 }
        }
    }

    @Test func logBurstUsesOneTextMutationAndPreservesOrder() async throws {
        let controller = LogViewController(store: LogStore())
        controller.loadViewIfNeeded()
        let text = try #require(controller.view.subviews.compactMap { $0 as? UITextView }.first)
        let counter = EditCounter()
        text.textStorage.delegate = counter
        for index in 0..<1_000 {
            controller.enqueue(entry: .init(date: Date(), type: .info, message: "entry-\(index)"))
        }
        #expect(text.text.isEmpty)
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(counter.edits == 1)
        #expect(text.text == (0..<1_000).map { "[INFO] entry-\($0)\n" }.joined())
    }

    @Test func logSnapshotMountsWithOneTextMutation() async throws {
        let store = LogStore()
        for index in 0..<1_000 { await store.addEntry(level: .warning, message: "snapshot-\(index)") }
        let controller = LogViewController(store: store)
        controller.loadViewIfNeeded()
        let text = try #require(controller.view.subviews.compactMap { $0 as? UITextView }.first)
        let counter = EditCounter()
        text.textStorage.delegate = counter
        controller.viewWillAppear(false)
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(counter.edits == 1)
        #expect(text.text == (0..<1_000).map { "[WARN] snapshot-\($0)\n" }.joined())
        controller.viewDidDisappear(false)
    }

    @Test func logOverflowIsBoundedAndClearDiscardsPendingBatch() async throws {
        let controller = LogViewController(store: LogStore())
        controller.loadViewIfNeeded()
        let text = try #require(controller.view.subviews.compactMap { $0 as? UITextView }.first)
        for index in 0...LogStore.maximumEntries {
            controller.enqueue(entry: .init(date: Date(), type: .default, message: "\(index)"))
        }
        try await waitUntil { !text.text.isEmpty }
        #expect(text.text.split(separator: "\n").count == 9_001)
        #expect(text.text.hasPrefix("1000\n"))
        controller.enqueue(entry: .init(date: Date(), type: .error, message: "must-disappear"))
        controller.clearLog()
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(text.text.isEmpty)
    }

    @Test func disappearingViewerCancelsPendingFlush() async throws {
        let controller = LogViewController(store: LogStore())
        controller.loadViewIfNeeded()
        let text = try #require(controller.view.subviews.compactMap { $0 as? UITextView }.first)
        controller.enqueue(entry: .init(date: Date(), type: .debug, message: "pending"))
        controller.viewDidDisappear(false)
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(text.text.isEmpty)
    }

    @Test func defaultsBurstPublishesWholeLatestSnapshotOnce() async throws {
        let suite = "app-lifecycle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = NotificationCenter()
        let observer = UserDefaultsObserver(keys: ["a", "b"], defaults: defaults, notificationCenter: center)
        var snapshots: [[String: Any?]] = []
        let subscription = observer.$observedValues.dropFirst().sink { snapshots.append($0) }
        for index in 0..<500 {
            defaults.set(index, forKey: "a")
            defaults.set(index * 2, forKey: "b")
            center.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(snapshots.count == 1)
        #expect(observer.observedValues["a", default: nil] as? Int == 499)
        #expect(observer.observedValues["b", default: nil] as? Int == 998)
        withExtendedLifetime(subscription) {}
    }

    @Test func booleanReconciliationDoesNotRecreateRemovedSetting() async throws {
        let suite = "app-lifecycle.bool.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = NotificationCenter()
        defaults.set(false, forKey: "enabled")
        let observer = UserDefaultsBool(key: "enabled", defaultValue: true, defaults: defaults, notificationCenter: center)
        defaults.removeObject(forKey: "enabled")
        center.post(name: UserDefaults.didChangeNotification, object: defaults)
        try await waitUntil { observer.value }
        #expect(observer.value)
        #expect(defaults.object(forKey: "enabled") == nil)
        observer.value = false
        #expect(defaults.object(forKey: "enabled") as? Bool == false)
    }
}
