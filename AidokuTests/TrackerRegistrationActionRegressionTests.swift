import AidokuRunner
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Aidoku

/// Hosted production TrackerSearchView driven only by external real XCTest touches.
/// Provider calls are held until explicit release and always fail: no saved TrackItem.
@Suite(.serialized) @MainActor
struct TrackerRegistrationActionRegressionTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("Round2TrackerRegistration/enabled").path)))
    func repeatedDoneWhilePendingStartsOneRegistrationAndFailureAllowsRetry() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("Round2TrackerRegistration")
        let ready = directory.appendingPathComponent("ready.json")
        try? FileManager.default.removeItem(at: ready)
        let tracker = R2RegistrationTracker()
        let manga = AidokuRunner.Manga(sourceKey: "round2-ui-register", key: UUID().uuidString, title: "Registration fixture")
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: R2RegistrationHost(tracker: tracker, manga: manga))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey(); try? FileManager.default.removeItem(at: ready) }
        try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier,
            "instruction": "Select fixture; double-tap actual Done; require calls=1 while held; release; retry Done; require calls=2; finish"])
            .write(to: ready, options: .atomic)
        let deadline = Date().addingTimeInterval(120)
        while !(await tracker.recorder.snapshot().finished), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let snapshot = await tracker.recorder.snapshot()
        await tracker.recorder.release() // bounded cleanup on driver failure; captured snapshot stays authoritative
        try await Task.sleep(for: .milliseconds(200))
        let evidence: [String: Any] = ["scope": "Production TrackerSearchView; external XCTest touches; held failing provider; no HTTP or saved registration",
            "firstBurstRemoteCalls": snapshot.burstCount ?? -1, "afterRetryRemoteCalls": snapshot.calls,
            "driverFinished": snapshot.finished, "driverReleased": snapshot.burstCount != nil,
            "pid": ProcessInfo.processInfo.processIdentifier]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("tracker-registration.json"), options: .atomic)
        #expect(snapshot.finished, "External real-touch driver must complete the interaction")
        #expect(snapshot.burstCount == 1, "Repeated Done while provider held must start exactly one registration")
        #expect(snapshot.calls == 2, "Failure must allow exactly one subsequent retry")
    }
}

@MainActor private struct R2RegistrationHost: View {
    let tracker: R2RegistrationTracker
    let manga: AidokuRunner.Manga
    @State private var calls = 0
    var body: some View {
        VStack(spacing: 4) {
            Text("Registration calls: \(calls)").accessibilityIdentifier("round2.registration.count")
            HStack {
                Button("Release registration fixture") { Task { await tracker.recorder.release() } }
                    .accessibilityIdentifier("round2.registration.release")
                Button("Finish registration capture") { Task { await tracker.recorder.finish() } }
                    .accessibilityIdentifier("round2.registration.finish")
            }
            TrackerSearchView(tracker: tracker, manga: manga)
        }.task {
            while !Task.isCancelled {
                calls = await tracker.recorder.snapshot().calls
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }
}
private actor R2RegistrationRecorder {
    private var calls = 0
    private var released = false
    private var finished = false
    private var burstCount: Int?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func beginAndWait() async {
        calls += 1
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() {
        if !released { burstCount = calls }
        released = true
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume() }
    }
    func finish() { finished = true }
    func snapshot() -> (calls: Int, burstCount: Int?, finished: Bool) { (calls, burstCount, finished) }
}
private final class R2RegistrationTracker: Tracker, Sendable {
    let id = "round2-register"
    let name = "Registration fixture"
    var icon: UIImage? { nil }
    let isLoggedIn = true
    let recorder = R2RegistrationRecorder()
    func getTrackerInfo() async throws -> TrackerInfo { .init(supportedStatuses: [], scoreType: .tenPoint) }
    func register(trackId: String, highestChapterRead: Float?, earliestReadDate: Date?) async throws -> String? {
        await recorder.beginAndWait()
        throw URLError(.notConnectedToInternet)
    }
    func update(trackId: String, update: TrackUpdate) async throws {}
    func getState(trackId: String) async throws -> TrackState { .init() }
    func getUrl(trackId: String) async -> URL? { nil }
    func search(for manga: AidokuRunner.Manga, includeNsfw: Bool) async throws -> [TrackSearchItem] { try await search(title: manga.title, includeNsfw: includeNsfw) }
    func search(title: String, includeNsfw: Bool) async throws -> [TrackSearchItem] {
        [.init(id: "fixture", title: "Registration fixture", tracked: false)]
    }
    func logout() async throws {}
}
