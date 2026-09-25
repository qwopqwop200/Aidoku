import AidokuRunner
import CoreData
import CryptoKit
import SwiftUI
import Testing
import UIKit
@testable import Aidoku

/// Dedicated simulator opt-in. Presentations are evidence of screen attachment,
/// not evidence that every button, provider or asynchronous operation succeeded.
@Suite(.serialized) @MainActor
struct FullAuditSettingsFlowTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("FullAuditSettings/enabled").path)))
    func settingsDestinations() async throws {
        #if !targetEnvironment(simulator)
        throw SettingsFlowError.simulatorRequired
        #endif
        let defaults = UserDefaults.standard
        let bundleID = try #require(Bundle.main.bundleIdentifier)
        let savedDomain = defaults.persistentDomain(forName: bundleID) ?? [:]
        defer { defaults.setPersistentDomain(savedDomain, forName: bundleID) }
        try #require(AppSettings.browse.sourceLists.get().isEmpty)
        let sources = await SourceManager.shared.getLoadedSources()
        try #require(sources.allSatisfy { $0.key == LocalSourceRunner.sourceKey })
        let emptyUserData = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.getLibraryManga(context: context).isEmpty &&
            CoreDataManager.shared.getHistory(context: context).isEmpty
        }
        try #require(emptyUserData, "Never run this opt-in against a populated user simulator")
        let countsBefore = try await entityCounts()
        let output = URL.documentsDirectory.appendingPathComponent("FullAuditSettings")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let documentsBefore = try documentHashes()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }
        let navigation = UINavigationController()
        let coordinator = NavigationCoordinator(rootViewController: navigation)
        window.rootViewController = navigation
        window.makeKeyAndVisible()

        var pages: [(String, Setting, PageSetting)] = []
        var controls: [[String: String]] = []
        func visit(_ settings: [Setting], path: String) {
            for (index, setting) in settings.enumerated() {
                let current = path + "/" + String(index)
                controls.append(["path": current, "key": setting.key, "title": setting.title,
                    "requires": String(describing: setting.requires),
                    "requiresFalse": String(describing: setting.requiresFalse),
                    "actionStatus": "not_invoked_presentation_only"])
                switch setting.value {
                case .group(let group): visit(group.items, path: current)
                case .page(let page):
                    pages.append((current, setting, page)); visit(page.items, path: current)
                default: break
                }
            }
        }
        visit(Settings.settings, path: "settings")
        var destinations: [(String, String, AnyView)] = [("root", "Settings", AnyView(SettingsView()))]
        for (path, setting, page) in pages {
            let content = SettingPageDestination(setting: setting, value: page)
                .environment(\.settingPageContent, { key in customPage(key) })
                .settingCustomContent(SettingsView().customContentHandler)
            destinations.append((path.replacingOccurrences(of: "/", with: "-"), setting.title, AnyView(content)))
        }
        destinations += [
            ("backup-create", "Backup creation form", AnyView(BackupCreateView())),
            ("backup-automatic", "Automatic backup settings", AnyView(AutomaticBackupsView())),
            ("translation-language-filter", "Translation language filter", AnyView(ReaderTranslationLanguageFilterView(selection: .constant([]))))
        ]
        var rows: [[String: Any]] = []
        func save(_ final: [String: Any] = [:]) throws {
            var report: [String: Any] = ["schema": 1, "rows": rows, "controls": controls,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "idiom": UIDevice.current.userInterfaceIdiom.rawValue,
                "optimized": !_isDebugAssertConfiguration(), "repetitionsPerDestination": 3,
                "countsBefore": countsBefore,
                "scope": "Actual production views; programmatic navigation attachment plus two display callbacks; asynchronous load completion and button action correctness not established",
                "customCategoryBindings": "Dedicated empty categories; custom handlers from SettingsView use initial empty state; category edits not exercised",
                "excludedActions": ["destructive reset/clear/migrate", "credential login/logout", "remote provider mutation", "iCloud synchronization", "dictionary/model download", "backup restore/create", "external links", "photo/library permission prompts"],
                "conditionsNotForced": ["iCloud entitlement", "iPad-only presentation", "other OS branches", "enabled dictionary overlay controls", "populated tracker/source rows"],
                "notMeasured": ["cold launch", "Instruments hitches", "memory peak", "actual button touch latency", "all rows below viewport", "populated user data"],
                "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                "physicalMemory": ProcessInfo.processInfo.physicalMemory]
            for (key, value) in final { report[key] = value }
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: output.appendingPathComponent("measurements.json"), options: .atomic)
        }
        for (name, title, content) in destinations {
            for iteration in 0..<3 {
                let probe = SettingsFlowFrames()
                defer { probe.cancel() }
                probe.start()
                let host = UIHostingController(rootView: content.environmentObject(coordinator))
                host.title = title
                navigation.setViewControllers([host], animated: false)
                host.view.layoutIfNeeded()
                try await probe.finish()
                try #require(host.view.window === window)
                try #require(!host.view.bounds.isEmpty)
                let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
                var drawn = false
                let screenshot = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try #require(drawn)
                let png = try #require(screenshot.pngData())
                let filename = name + "-" + String(iteration) + ".png"
                try png.write(to: output.appendingPathComponent(filename), options: .atomic)
                rows.append(["destination": name, "title": title, "iteration": iteration,
                    "status": "screen_attached_and_snapshot_written_actions_not_verified",
                    "displayAfterTwoFramesMS": probe.elapsedMS, "displayCallbackGapsMS": probe.gaps,
                    "screenshot": filename, "pngSHA256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
                    "cacheState": iteration == 0 ? "first_observed_services_unspecified" : "same_process_repeat"])
                try save()
            }
        }
        // Detach views before restoring defaults so observers do not start work.
        navigation.setViewControllers([UIViewController()], animated: false)
        await Task.yield()
        let countsAfter = try await entityCounts()
        let documentsAfter = try documentHashes()
        defaults.setPersistentDomain(savedDomain, forName: bundleID)
        let defaultsRestored = NSDictionary(dictionary: defaults.persistentDomain(forName: bundleID) ?? [:])
            .isEqual(to: savedDomain)
        try save(["countsAfter": countsAfter, "databaseCountsUnchanged": countsBefore == countsAfter,
                  "documentContentHashesUnchanged": documentsBefore == documentsAfter,
                  "documentsChecked": documentsBefore.count, "persistentSettingsRestored": defaultsRestored,
                  "dataLimit": "DB entity counts do not prove equality of every field; only dedicated empty library/history allowed"])
        #expect(countsBefore == countsAfter)
        #expect(documentsBefore == documentsAfter)
        #expect(defaultsRestored)
    }

    private func customPage(_ key: String) -> AnyView? {
        switch key {
        case "Library.categories": return AnyView(CategoriesView(categories: .constant([])))
        case "Library.filterGroups": return AnyView(FilterGroupsView())
        case "Reader.tapZones": return AnyView(TapZonesSelectView())
        case "Network.httpsBypassPage":
            if #available(iOS 17.0, *) { return AnyView(HTTPSBypassSettingsView()) }
        case "Reader.translation":
            if #available(iOS 18.0, *) { return AnyView(ReaderTranslationSettingsView()) }
        case "Dictionary.dictionaries":
            if #available(iOS 18.0, *) { return AnyView(DictionaryListView()) }
        case "Dictionary.vocabulary":
            if #available(iOS 18.0, *) { return AnyView(DictionaryVocabListView()) }
        case "Tracking": return AnyView(SettingsTrackingView())
        case "About": return AnyView(SettingsAboutView())
        case "Insights": return AnyView(InsightsView())
        case "SourceLists": return AnyView(SourceListsView())
        case "Backups": return AnyView(BackupsView())
        case "Downloads": return AnyView(DownloadsView())
        default: break
        }
        return nil
    }

    private func entityCounts() async throws -> [String: Int] {
        try await CoreDataManager.shared.container.performBackgroundTask { context in
            var result: [String: Int] = [:]
            for entity in CoreDataManager.shared.container.managedObjectModel.entities {
                guard let name = entity.name else { continue }
                result[name] = try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: name))
            }
            return result
        }
    }

    private func documentHashes() throws -> [String: String] {
        var result: [String: String] = [:]
        let base = URL.documentsDirectory
        let enumerator = try #require(FileManager.default.enumerator(at: base,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
        for case let file as URL in enumerator {
            let relative = String(file.path.dropFirst(base.path.count + 1))
            if relative == "FullAuditSettings" || relative.hasPrefix("FullAuditSettings/") {
                enumerator.skipDescendants(); continue
            }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 65_536), !data.isEmpty { hash.update(data: data) }
            result[relative] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
}

@MainActor private final class SettingsFlowFrames: NSObject {
    private var link: CADisplayLink?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var startTime = 0.0
    private var previous = 0.0
    private var ticks = 0
    private(set) var elapsedMS = 0.0
    private(set) var gaps: [Double] = []
    func start() {
        startTime = CACurrentMediaTime(); previous = startTime
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }
    func finish() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.stop(SettingsFlowError.displayTimeout)
            }
        }
    }
    @objc private func tick() {
        let now = CACurrentMediaTime(); gaps.append((now - previous) * 1_000); previous = now
        if continuation != nil { ticks += 1; if ticks == 2 { stop(nil) } }
    }
    private func stop(_ error: Error?) {
        elapsedMS = (CACurrentMediaTime() - startTime) * 1_000
        link?.invalidate(); link = nil; timeout?.cancel(); timeout = nil
        let pending = continuation; continuation = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
    func cancel() { if link != nil { stop(CancellationError()) } }
}
private enum SettingsFlowError: Error { case simulatorRequired, displayTimeout }
