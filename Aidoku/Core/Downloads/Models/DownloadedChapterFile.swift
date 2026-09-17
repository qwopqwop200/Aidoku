import Foundation
import ZIPFoundation

/// Reads the archive directory only; page counting never decompresses image data.
enum DownloadedChapterFile {
    static func comicInfo(in url: URL) -> ComicInfo? {
        if url.pathExtension.lowercased() == "cbz" { return ComicInfo.load(from: url) }
        guard url.isDirectory,
              let data = try? Data(contentsOf: url.appendingPathComponent("ComicInfo.xml")),
              let xml = String(data: data, encoding: .utf8) else { return nil }
        return ComicInfo.load(xmlString: xml)
    }

    static func pageCount(in url: URL) -> Int {
        if url.pathExtension.lowercased() == "cbz" {
            guard let archive = try? Archive(url: url, accessMode: .read) else { return 0 }
            return archive.reduce(0) { count, entry in
                count + (entry.type == .file && isPage(entry.path) ? 1 : 0)
            }
        }
        guard url.isDirectory else { return 0 }
        return url.contents.filter { !$0.isDirectory && isPage($0.lastPathComponent) }.count
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
