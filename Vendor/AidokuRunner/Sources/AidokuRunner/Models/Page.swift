//
//  Page.swift
//  AidokuRunner
//
//  Created by Skitty on 8/21/23.
//

import Foundation

public typealias PageContext = [String: String]

public struct Page: Sendable, Hashable {
    public var content: PageContent
    /// Optional thumbnail image url for the page
    public var thumbnail: URL?
    public var hasDescription: Bool
    public var description: String?

    public init(
        content: PageContent,
        thumbnail: URL? = nil,
        hasDescription: Bool = false,
        description: String? = nil
    ) {
        self.content = content
        self.thumbnail = thumbnail
        self.hasDescription = hasDescription
        self.description = description
    }

}

public enum PageContent: Sendable, Hashable {
    case url(url: URL, context: PageContext? = nil)
    case text(String)
    case image(PlatformImage)
    case zipFile(url: URL, filePath: String)
}
