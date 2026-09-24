import AidokuRunner
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Aidoku

private var round2MigrationUIEnabled: Bool {
    #if targetEnvironment(simulator)
    FileManager.default.fileExists(atPath: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Round2Migration/enabled").path)
    #else
    false
    #endif
}

@MainActor
@Suite(.serialized, .enabled(if: round2MigrationUIEnabled))
struct Round2MigrationMatchingUITests {
    private actor SearchRunner: AidokuRunner.Runner {
        nonisolated let features = SourceFeatures()
        var queries: [String] = []
        var pending: [CheckedContinuation<Void, Never>] = []
        var released = false
        var captureFinished = false
        func finishCapture() { captureFinished = true }
        func isCaptureFinished() -> Bool { captureFinished }
        func getSearchMangaList(query: String?, page: Int, filters: [FilterValue]) async throws -> AidokuRunner.MangaPageResult {
            let title = query ?? ""
            queries.append(title)
            if !released { await withCheckedContinuation { pending.append($0) } }
            return AidokuRunner.MangaPageResult(entries: [.init(sourceKey: "round2-migration-target", key: title, title: "Matched " + title)], hasNextPage: false)
        }
        func release() {
            released = true
            let waiters = pending
            pending.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        func snapshot() -> ([String], Bool) { (queries, released) }
        func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga { manga }
        func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] { [] }
    }

    @Test func removingStartedRowCannotSkipFourthActualSourceSearch() async throws {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Round2Migration")
        let ready = directory.appendingPathComponent("ready.json")
        let result = directory.appendingPathComponent("result.json")
        try? FileManager.default.removeItem(at: ready)
        try? FileManager.default.removeItem(at: result)
        let runner = SearchRunner()
        let source = AidokuRunner.Source(key: "round2-migration-target", name: "Round2 Target", version: 1, contentRating: .safe, runner: runner)
        let names = ["Round2 Migration A", "Round2 Migration B", "Round2 Migration C", "Round2 Migration D"]
        let manga = names.map { AidokuRunner.Manga(sourceKey: "round2-migration-original", key: $0, title: $0) }
        let coordinator = NavigationCoordinator(rootViewController: nil)
        let view = VStack {
            Button("Release matching fixture") { Task { await runner.release() } }
                .accessibilityIdentifier("round2.migration.release")
            Button("Finish migration capture") { Task { await runner.finishCapture() } }
                .accessibilityIdentifier("round2.migration.finish")
            MigrateResultsView(targetSources: [source], selectedSeries: manga)
        }.environmentObject(coordinator)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        coordinator.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let readyDeadline = Date().addingTimeInterval(15)
        while await runner.snapshot().0.count < 3, Date() < readyDeadline { try await Task.sleep(for: .milliseconds(20)) }
        let initial = await runner.snapshot().0
        #expect(Set(initial) == Set(names.prefix(3)))
        try JSONSerialization.data(withJSONObject: ["initialQueries": initial, "instruction": "Open first row ellipsis, tap Dont Migrate, verify A disappeared, then tap Release matching fixture"]).write(to: ready, options: .atomic)
        // The independent XCUITest driver performs real row-menu actions. This
        // test never mutates a copied SwiftUI State or reimplements scheduling.
        let interactionDeadline = Date().addingTimeInterval(120)
        while !(await runner.snapshot().1), Date() < interactionDeadline { try await Task.sleep(for: .milliseconds(100)) }
        let userReleased = await runner.snapshot().1
        await runner.release() // release resources even if the external driver failed
        let completionDeadline = Date().addingTimeInterval(3)
        while await runner.snapshot().0.count < 4, Date() < completionDeadline { try await Task.sleep(for: .milliseconds(20)) }
        let final = await runner.snapshot().0
        try JSONSerialization.data(withJSONObject: ["queries": final, "driverReleased": userReleased]).write(to: result, options: .atomic)
        #expect(userReleased, "External UI driver must remove row A and release the controlled source")
        #expect(final.count == 4)
        #expect(Set(final) == Set(names))
        let captureDeadline = Date().addingTimeInterval(30)
        while !(await runner.isCaptureFinished()), Date() < captureDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await runner.isCaptureFinished(), "External driver must verify and capture the final matched D row")
    }
}
