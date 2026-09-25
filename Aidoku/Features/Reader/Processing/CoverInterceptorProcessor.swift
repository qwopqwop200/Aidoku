//
//  CoverInterceptorProcessor.swift
//  Aidoku
//
//  Created by skitty on 8/30/26.
//

import AidokuRunner
import Foundation
import Nuke

struct CoverInterceptorProcessor: ImageProcessing {
    let source: AidokuRunner.Source

    let identifier: String = "coverProcessor"

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
        container.image = output?.image
            ?? container.data.flatMap { PlatformImage(data: $0) }
            ?? container.image
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
            let result = try await source.processCoverImage(response: response)
            try await source.remove(value: imageDescriptor)
            return result
        } catch {
            // Release runner-owned pixels even when the source throws or is cancelled.
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

extension CoverInterceptorProcessor: Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source.key == rhs.source.key
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(source.key)
    }

    var hashableIdentifier: AnyHashable {
        AnyHashable(self)
    }
}

/// Source interceptors can replace all pixels (and may start from Nuke's empty
/// decoder). Apply display sizing only after the final source image exists.
enum CoverImageProcessing {
    @MainActor
    static func processors(source: AidokuRunner.Source?, downsampleWidth: CGFloat?) -> [any ImageProcessing] {
        var processors: [any ImageProcessing] = []
        if let source, source.features.processesCovers {
            processors.append(CoverInterceptorProcessor(source: source))
        }
        if let downsampleWidth {
            processors.append(DownsampleProcessor(width: downsampleWidth))
        }
        return processors
    }
}
