import AidokuRunner
import Foundation

/// A reader-owned session with no source, manga, chapter, or history records in the database.
final class TemporarySharedImageSession {
    static let sourcePrefix = "temporary-images."
    static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("SharedImageSessions", isDirectory: true) }
    let directory: URL
    let archiveURL: URL
    let source: AidokuRunner.Source
    let manga: AidokuRunner.Manga
    let chapter: AidokuRunner.Chapter

    init(fileInfo: ImportFileInfo) throws {
        let id = UUID().uuidString
        directory = Self.root.appendingPathComponent(id, isDirectory: true)
        archiveURL = directory.appendingPathComponent("images.cbz")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { try FileManager.default.copyItem(at: fileInfo.url, to: archiveURL) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        let key = Self.sourcePrefix + id
        source = .init(url: nil, key: key, name: NSLocalizedString("LOCAL_FILES"), version: 1,
            languages: ["multi"], urls: [], contentRating: .safe, config: .init(languageSelectType: .single),
            staticListings: [], staticFilters: [], staticSettings: [], runner: TemporaryImageRunner(archiveURL: archiveURL))
        chapter = .init(key: id, title: fileInfo.name)
        var manga = AidokuRunner.Manga(sourceKey: key, key: id, title: fileInfo.name)
        manga.chapters = [chapter]
        self.manga = manga
    }

    func removeFiles() { try? FileManager.default.removeItem(at: directory) }
    deinit { removeFiles() }
    static func removeAllSessions() { try? FileManager.default.removeItem(at: root) }
}

private final class TemporaryImageRunner: AidokuRunner.Runner {
    let features = LocalSourceRunner().features
    let archiveURL: URL
    init(archiveURL: URL) { self.archiveURL = archiveURL }
    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        .init(entries: [], hasNextPage: false)
    }
    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga { manga }
    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        LocalFileManager.shared.readPages(from: archiveURL)
    }
}
