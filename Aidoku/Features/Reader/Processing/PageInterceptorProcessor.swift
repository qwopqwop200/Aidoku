//
//  PageInterceptorProcessor.swift
//  Aidoku
//
//  Created by Skitty on 5/8/25.
//

import AidokuRunner
import Foundation
import Nuke
import UIKit

extension ImageRequest.UserInfoKey {
    static let processesKey: Self = "aidoku/usesPageProcessor"
}

struct PageInterceptorProcessor: ImageProcessing {
    let source: AidokuRunner.Source
    let pageContext: PageContext?

    let identifier: String = "pageProcessor"

    func process(_ image: PlatformImage) -> PlatformImage? {
        nil
    }

    func process(_ container: ImageContainer, context: ImageProcessingContext) throws -> ImageContainer {
        // image processing should be async so we don't have to block, but Nuke doesn't support this...
        // this isn't run on the main thread anyways, so appears to be fine for now
        let output: AidokuRunner.PlatformImage? = try BlockingThrowingTask {
            try await processAsync(container, context: context)
        }.get()

        var container = container
        // Only GIF data is read back; drop the empty decoder's transport bytes from the cached result.
        let isTransport = context.request.userInfo[.processesKey] as? Bool == true && container.type == nil && container.image.size == .zero
        let image = output?.image
            ?? container.data.flatMap { ImagePixelCap.decodeImage($0) }
            ?? container.image
        container.image = image
        // Cap only after the source has unscrambled at native pixel positions.
        if let cgImage = image.cgImage, let capped = ImagePixelCap.downscaled(cgImage), capped !== cgImage {
            container.image = PlatformImage(cgImage: capped, scale: image.scale, orientation: image.imageOrientation)
        }
        if isTransport { container.data = nil }
        return container
    }

    func processAsync(_ container: ImageContainer, context: ImageProcessingContext) async throws -> AidokuRunner.PlatformImage? {
        guard let request = context.request.urlRequest else {
            return nil
        }

        let urlResponse = context.response.urlResponse as? HTTPURLResponse
        let code = urlResponse?.statusCode ?? 200
        let headers = urlResponse?.allHeaderFields

        func toStringMap<K, V>(_ dict: [K: V]) -> [String: String] {
            dict
                .compactMapKeys { $0 as? String }
                .compactMapValues { $0 as? String }
        }

        let imageDescriptor = if let data = container.data {
            if let image = PlatformImage(data: data) {
                try await source.store(value: image)
            } else {
                try await source.store(value: data)
            }
        } else {
            try await source.store(value: container.image)
        }

        let response = Response(
            code: code,
            headers: toStringMap(headers ?? [:]),
            request: .init(
                url: request.url,
                headers: toStringMap(request.allHTTPHeaderFields ?? [:])
            ),
            image: imageDescriptor
        )

        do {
            let result = try await source.processPageImage(response: response, context: pageContext)
            try await source.remove(value: imageDescriptor)
            return result
        } catch {
            // Cleanup must outlive caller cancellation and keep the original error.
            await Task.detached { try? await source.remove(value: imageDescriptor) }.value
            throw error
        }
    }

    func processWithoutImage(request: ImageRequest) throws -> ImageContainer {
        let container = ImageContainer(image: .mangaPlaceholder)
        let context = ImageProcessingContext(
            request: request,
            response: .init(
                container: container,
                request: request,
                urlResponse: (request.url ?? request.urlRequest?.url).flatMap {
                    HTTPURLResponse(
                        url: $0,
                        statusCode: 404,
                        httpVersion: nil,
                        headerFields: nil
                    )
                }
            ),
            isCompleted: true
        )
        return try self.process(container, context: context)
    }
}

extension PageInterceptorProcessor: Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source.key == rhs.source.key && lhs.pageContext == rhs.pageContext
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(source.key)
        hasher.combine(pageContext)
    }

    var hashableIdentifier: AnyHashable {
        AnyHashable(self)
    }
}
