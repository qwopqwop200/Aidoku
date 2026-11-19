import Foundation

// Kept apart from V2Detection.swift so the standalone S2 harness compiles without the full model set.
@available(iOS 18.0, macOS 15.0, *)
extension V2Detection {
    /// Detection on one pooled resident detector (one page per instance at a time).
    static func detect(
        _ page: V2Page,
        models: V2Models,
        configuration: NativeCoreMLDBPostprocessConfiguration = V2Detection.configuration
    ) async throws -> [V2Line] {
        try await models.detectors.with { try await detect(page, detector: $0, configuration: configuration) }
    }

    /// Frame-sharing variant used by the pipeline (S3 reuses the same frame).
    static func detect(
        frame: NativeOCRRGBAFrame,
        page: V2Page,
        models: V2Models,
        configuration: NativeCoreMLDBPostprocessConfiguration = V2Detection.configuration
    ) async throws -> [V2Line] {
        try await models.detectors.with {
            try await detect(frame: frame, page: page, detector: $0, configuration: configuration)
        }
    }
}
