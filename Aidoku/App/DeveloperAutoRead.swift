#if AIDOKU_DEVELOPER_PERFORMANCE
import UIKit

/// Developer-only unattended reading for on-device timing: launch with
/// `-AidokuAutoRead "<local series folder>" [-AidokuAutoReadChapter 1] [-AidokuAutoReadDwell 2]
///  [-AidokuAutoReadTurns 40] [-AidokuAutoReadClearCache YES]`. Turns pages at the dwell interval, then exits.
@MainActor
enum DeveloperAutoRead {
    private static var started = false

    static func startIfRequested() {
        let defaults = UserDefaults.standard
        guard !started, let series = defaults.string(forKey: "AidokuAutoRead") else { return }
        started = true
        let chapterIndex = max(1, defaults.integer(forKey: "AidokuAutoReadChapter")) - 1
        let dwell = defaults.double(forKey: "AidokuAutoReadDwell") > 0 ? defaults.double(forKey: "AidokuAutoReadDwell") : 2
        let turns = defaults.integer(forKey: "AidokuAutoReadTurns") > 0 ? defaults.integer(forKey: "AidokuAutoReadTurns") : 40
        Task {
            if defaults.bool(forKey: "AidokuAutoReadClearCache") {
                try? await ReaderTranslationDiskCache.shared.clear()
                if #available(iOS 18.0, *) { await ReaderTranslationPipelineService.shared.clearMemory() }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let id = series.normalized
            guard var manga = await LocalFileDataManager.shared.fetchLocalSeries(id: id),
                  let source = await SourceManager.shared.source(for: LocalSourceRunner.sourceKey) else { exit(2) }
            // Keep the source order (newest first) the reader uses for "next chapter"; pick by reading order.
            manga.chapters = await LocalFileDataManager.shared.fetchChapters(mangaId: id)
            let chapters = (manga.chapters ?? []).sorted { ($0.chapterNumber ?? 0) < ($1.chapterNumber ?? 0) }
            guard chapters.indices.contains(chapterIndex),
                  let presenter = UIApplication.shared.firstKeyWindow?.rootViewController else { exit(3) }
            let reader = ReaderViewController(source: source, manga: manga, chapter: chapters[chapterIndex], startPage: 1)
            let navigation = ReaderNavigationController(readerViewController: reader)
            navigation.modalPresentationStyle = .fullScreen
            presenter.present(navigation, animated: false)
            ReaderTranslationDiagnostics.record("autoread_begin", count: turns, elapsedMilliseconds: dwell * 1000)
            // The first page gets the same dwell as every other page.
            for turn in 1...max(1, turns) {
                try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
                reader.developerAdvancePage()
                ReaderTranslationDiagnostics.record("autoread_turn", page: turn)
            }
            try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
            ReaderTranslationDiagnostics.record("autoread_end", count: turns)
            try? await Task.sleep(nanoseconds: 1_500_000_000) // Let the diagnostics writer drain.
            exit(0)
        }
    }
}
#endif
