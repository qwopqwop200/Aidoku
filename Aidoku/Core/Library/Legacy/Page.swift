//
//  Page.swift
//  Aidoku
//
//  Created by Skitty on 12/22/21.
//

import Foundation
import AidokuRunner

struct Page: Hashable {

    enum PageType: Int {
        case imagePage
        case prevInfoPage
        case nextInfoPage
    }

    var type: PageType = .imagePage
    var sourceId: String
    var chapterId: String
    var index: Int = 0
    var imageURL: String?
    @HashedReaderBase64 var base64: String? = nil
    var text: String?
    var image: PlatformImage?
    var zipURL: String?
    var language: String?

    var context: PageContext?
    var hasDescription: Bool = false
    var description: String?
    // Split reader pages reuse the full source page's prepared translation.
    var translationOriginalKey: String?
    var translationSourceRect: CGRect?

    var key: String {
        "\(chapterId)|\(index)"
    }

    var isTextPage: Bool {
        text != nil || (zipURL != nil && imageURL?.lowercased().hasSuffix(".txt") == true)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(chapterId)
        hasher.combine(index)
    }
}

extension Page {
    func toNew() -> AidokuRunner.Page {
        let content: AidokuRunner.PageContent = if let zipURL, let url = URL(string: zipURL), let imageURL {
            .zipFile(url: url, filePath: imageURL)
        } else if let imageURL, let url = URL(string: imageURL) {
            .url(url: url, context: context)
        } else if let text {
            .text(text)
        } else if let image {
            .image(image)
        } else {
            .text(NSLocalizedString("INVALID_URL"))
        }
        return AidokuRunner.Page(
            content: content,
            hasDescription: hasDescription,
            description: description
        )
    }
}
