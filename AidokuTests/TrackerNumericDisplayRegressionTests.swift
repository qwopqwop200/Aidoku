import AidokuRunner
import SwiftUI
import Testing
import UIKit
@testable import Aidoku

/// Actual TrackerView task -> SwiftUI onChange execution. Fixed provider replay,
/// no HTTP or database writes. Baseline can trap for Int.max score/volume.
@Suite(.serialized) @MainActor
struct TrackerNumericDisplayRegressionTests {
    @Test(arguments: ["normal", "decimal", "score-max", "volume-max"])
    func remoteStateDisplaysWithoutTrapOrUnrequestedUpdate(scenario: String) async throws {
        let decimal = scenario == "decimal"
        let state = TrackState(score: scenario == "score-max" ? Int.max : decimal ? 85 : 8,
            lastReadChapter: 3, lastReadVolume: scenario == "volume-max" ? Int.max : 12,
            totalChapters: 50, totalVolumes: scenario == "volume-max" ? Int.max : 20)
        let tracker = R2NumericTracker(state: state)
        let manga = AidokuRunner.Manga(sourceKey: "round2-ui-numeric", key: UUID().uuidString, title: "Numeric fixture")
        let item = TrackItem(id: "fixture", trackerId: tracker.id, mangaId: manga.identifier, title: manga.title, chapterOffset: 0)
        let info = TrackerInfo(supportedStatuses: [], scoreType: decimal ? .tenPointDecimal : .tenPoint, supportsReadingDates: false)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        window.rootViewController = UIHostingController(rootView: TrackerView(tracker: tracker, item: item, info: info, manga: manga, refresh: .constant(false)))
        window.makeKeyAndVisible()
        let deadline = Date().addingTimeInterval(5)
        while !(await tracker.recorder.loaded), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await tracker.recorder.loaded)
        // Give SwiftUI its real layout/change delivery turn after remote state is installed.
        try await Task.sleep(for: .milliseconds(250))
        try #require(window.rootViewController?.view.window === window)
        window.rootViewController = UIViewController()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await tracker.recorder.updates == 0, "Displaying a provider value must not rewrite it on dismiss")
    }
}

private actor R2NumericRecorder {
    var loaded = false
    var updates = 0
    func markLoaded() { loaded = true }
    func markUpdated() { updates += 1 }
}
private final class R2NumericTracker: Tracker, Sendable {
    let id = "round2-numeric"
    let name = "Numeric fixture"
    var icon: UIImage? { nil }
    let isLoggedIn = true
    let value: TrackState
    let recorder = R2NumericRecorder()
    init(state: TrackState) { value = state }
    func getTrackerInfo() async throws -> TrackerInfo { .init(supportedStatuses: [], scoreType: .tenPoint) }
    func register(trackId: String, highestChapterRead: Float?, earliestReadDate: Date?) async throws -> String? { nil }
    func update(trackId: String, update: TrackUpdate) async throws { await recorder.markUpdated() }
    func getState(trackId: String) async throws -> TrackState { await recorder.markLoaded(); return value }
    func getUrl(trackId: String) async -> URL? { nil }
    func search(for manga: AidokuRunner.Manga, includeNsfw: Bool) async throws -> [TrackSearchItem] { [] }
    func search(title: String, includeNsfw: Bool) async throws -> [TrackSearchItem] { [] }
    func logout() async throws {}
}
