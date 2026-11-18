import Combine
import Foundation
import Testing
@testable import Aidoku

@MainActor
struct SettingObservationTests {
    @Test func replayDispatchesOnlyAChangeMissedWhileDetached() async throws {
        let suite = "setting-observation." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = NotificationCenter()
        let observer = UserDefaultsObserver(keys: ["setting"], defaults: defaults, notificationCenter: center)
        var changes: [String] = []

        func subscribe() -> AnyCancellable {
            observer.$observedValues.sink { values in
                guard observer.consumePendingChange(), let value = values["setting", default: nil] as? String else { return }
                changes.append(value)
            }
        }
        func change(to value: String) async throws {
            defaults.set(value, forKey: "setting")
            center.post(name: UserDefaults.didChangeNotification, object: defaults)
            let deadline = ContinuousClock.now + .seconds(3)
            while observer.observedValues["setting", default: nil] as? String != value {
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(1))
            }
        }

        var subscription = subscribe()
        try await change(to: "visible")
        subscription.cancel()
        subscription = subscribe()
        #expect(changes == ["visible"])

        subscription.cancel()
        try await change(to: "hidden")
        subscription = subscribe()
        #expect(changes == ["visible", "hidden"])
        subscription.cancel()
        subscription = subscribe()
        #expect(changes == ["visible", "hidden"])
        subscription.cancel()
    }

    @Test func keylessRowsIgnoreTheEmptyDefaultsKey() throws {
        let suite = "keyless-setting." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unrelated", forKey: "")
        let observer = UserDefaultsObserver(keys: ["", ""], defaults: defaults, notificationCenter: .init())
        #expect(observer.observedValues.isEmpty)
        #expect(!observer.consumePendingChange())
    }
}
