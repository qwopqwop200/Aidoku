//
//  LocalModels.swift
//  Aidoku
//
//  Created by Skitty on 6/10/25.
//

import UIKit

enum LocalFileManagerError: Error {
    case invalidFileType
    case cannotReadArchive
    case noImagesFound
    case fileCopyFailed
}

struct LocalSeriesInfo: Hashable {
    let id: String
    let coverUrl: String
    let name: String
    let chapterCount: Int
}

enum LocalFileType {
    case cbz
    case zip
    case epub
    case image

    var localizedName: String {
        switch self {
            case .cbz: NSLocalizedString("CBZ_NAME")
            case .zip: NSLocalizedString("ZIP_NAME")
            case .epub: NSLocalizedString("EPUB_NAME")
            case .image: NSLocalizedString("FORMAT_IMAGE")
        }
    }
}

struct ImportFileInfo: Hashable {
    let url: URL
    let previewImages: [UIImage]
    let name: String
    let pageCount: Int
    let fileType: LocalFileType
    let comicInfo: ComicInfo?
    var temporaryImageFile: TemporaryLocalImageFile?
}

// Keeps a prepared image alive through the import sheet and removes it on cancellation or completion.
final class TemporaryLocalImageFile: Hashable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    static func == (lhs: TemporaryLocalImageFile, rhs: TemporaryLocalImageFile) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
