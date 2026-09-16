import AidokuRunner
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct TemporarySharedImageSessionTests {
    @Test(arguments: [1, 3])
    func temporaryReaderDoesNotRecordHistoryAndRemovesFiles(count: Int) async throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: input) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 40)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 30, height: 40))
        }
        try #require(image.pngData()).write(to: input)
        let prepared = await LocalFileManager.shared.prepareImageImport(from: Array(repeating: input, count: count), name: "Temporary")
        let session = try TemporarySharedImageSession(fileInfo: #require(prepared))
        defer { session.removeFiles() }
        #expect(LocalFileManager.shared.readPages(from: session.archiveURL).count == count)
        let reader = ReaderViewController(source: session.source, manga: session.manga, chapter: session.chapter,
            startPage: 1, temporaryImageSession: session)
        #expect(!reader.translationPersistsCache)
        await reader.updateReadPosition(currentPage: count, totalPages: count)
        reader.setCompleted()
        let id = ChapterIdentifier(sourceKey: session.source.key, mangaKey: session.manga.key, chapterKey: session.chapter.key)
        let progress = CoreDataManager.shared.getProgress(chapterId: id)
        #expect(!progress.completed && progress.progress == nil)
        let saved = await LocalFileDataManager.shared.fetchLocalSeries(id: session.manga.key)
        #expect(saved == nil)
        session.removeFiles()
        #expect(!FileManager.default.fileExists(atPath: session.directory.path))
    }
}
