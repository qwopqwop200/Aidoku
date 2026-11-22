import Foundation
import ZIPFoundation

/// Reads the archive directory only; page counting never decompresses image data.
enum DownloadedChapterFile {
    static func comicInfo(in url: URL) -> ComicInfo? {
        if url.pathExtension.lowercased() == "cbz" { return ComicInfo.load(from: url) }
        let xmlURL = url.appendingPathComponent("ComicInfo.xml")
        guard url.isDirectory,
              let size = (try? xmlURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= ComicInfo.maxXMLBytes,
              let data = try? Data(contentsOf: xmlURL),
              let xml = String(data: data, encoding: .utf8) else { return nil }
        return ComicInfo.load(xmlString: xml)
    }

    static func pageCount(in url: URL) -> Int {
        if url.pathExtension.lowercased() == "cbz" {
            return memoized(url) {
                guard let archive = try? Archive(url: url, accessMode: .read) else { return 0 }
                return archive.reduce(0) { count, entry in
                    count + (entry.type == .file && isPage(entry.path) ? 1 : 0)
                }
            }
        }
        guard url.isDirectory else { return 0 }
        return url.contents.filter { !$0.isDirectory && isPage($0.lastPathComponent) }.count
    }

    private static let memoLock = NSLock()
    nonisolated(unsafe) private static var memo: [String: (date: Date, size: Int, value: Any)] = [:]

    /// Reuses a value derived from `file` until its modification date or size changes; archives are costly to reopen.
    static func memoized<T>(_ file: URL, tag: String = #function, _ compute: () -> T) -> T {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let date = values?.contentModificationDate, let size = values?.fileSize else { return compute() }
        let key = tag + "\u{0}" + file.path
        memoLock.lock(); let hit = memo[key]; memoLock.unlock()
        if let hit, hit.date == date, hit.size == size, let value = hit.value as? T { return value }
        let value = compute()
        memoLock.lock(); memo[key] = (date, size, value); memoLock.unlock()
        return value
    }

    private static func isPage(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard !path.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }),
              url.deletingPathExtension().lastPathComponent.lowercased() != "cover" else { return false }
        if LocalFileManager.allowedImageExtensions.contains(url.pathExtension.lowercased()) { return true }
        // Text-page sources store the page itself as .txt; descriptions are sidecars.
        return url.pathExtension.lowercased() == "txt" && !path.lowercased().hasSuffix(".desc.txt")
    }
}
