// The MIT License (MIT)
//
// Copyright (c) 2015-2026 Alexander Grebenyuk (github.com/kean).

import AVKit
import Foundation
import Nuke

extension AssetType {
    /// Returns `true` if the asset represents a video file.
    public var isVideo: Bool {
        self == .mp4 || self == .m4v || self == .mov
    }
}

#if !os(watchOS)

private extension AssetType {
    var avFileType: AVFileType? {
        switch self {
        case .mp4: return .mp4
        case .m4v: return .m4v
        case .mov: return .mov
        default: return nil
        }
    }
}

// This class keeps strong pointer to DataAssetResourceLoader
final class AVDataAsset: AVURLAsset, @unchecked Sendable {
    private let resourceLoaderDelegate: DataAssetResourceLoader

    init(data: Data, type: AssetType?) {
        self.resourceLoaderDelegate = DataAssetResourceLoader(
            data: data,
            contentType: type?.avFileType?.rawValue ?? AVFileType.mp4.rawValue
        )

        // The URL is irrelevant
        let url = URL(string: "in-memory-data://\(UUID().uuidString)") ?? URL(fileURLWithPath: "/dev/null")
        super.init(url: url, options: nil)

        resourceLoader.setDelegate(resourceLoaderDelegate, queue: .global())
    }
}

// This allows LazyImage to play video from memory.
private final class DataAssetResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let data: Data
    private let contentType: String

    init(data: Data, contentType: String) {
        self.data = data
        self.contentType = contentType
    }

    // MARK: - DataAssetResourceLoader

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let contentRequest = loadingRequest.contentInformationRequest {
            contentRequest.contentType = contentType
            contentRequest.contentLength = Int64(data.count)
            contentRequest.isByteRangeAccessSupported = true
        }

        if let dataRequest = loadingRequest.dataRequest {
            do {
                let bytes = try videoDataRange(data, offset: dataRequest.requestedOffset,
                    length: dataRequest.requestedLength, toEnd: dataRequest.requestsAllDataToEndOfResource)
                dataRequest.respond(with: bytes)
            } catch {
                loadingRequest.finishLoading(with: error)
                return true
            }
        }

        loadingRequest.finishLoading()

        return true
    }
}

// AVFoundation can probe past the end of a truncated or partially loaded asset.
// Validate offsets before conversion and return only the bytes actually present.
func videoDataRange(_ data: Data, offset: Int64, length: Int, toEnd: Bool) throws -> Data {
    guard offset >= 0, offset <= Int64(data.count), length >= 0 else {
        throw URLError(.badServerResponse)
    }
    let available = data.count - Int(offset)
    let count = toEnd ? available : min(length, available)
    let start = data.index(data.startIndex, offsetBy: Int(offset))
    let end = data.index(start, offsetBy: count)
    return data[start..<end]
}

#endif
