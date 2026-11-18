import Foundation

/// The admitted signal-only policy ships with the app. Runtime never opens an
/// experiment folder, GT file or page-specific table to obtain these defaults.
enum NativeOCRPremergePolicyBundle {
    static let cacheVersion = "premerge-signals-auto-v2"
    enum File: String, CaseIterable {
        case content = "NativeOCRPremergeContent"
        case quality = "NativeOCRPremergeQuality"
        case duplicates = "NativeOCRPremergeDuplicates"
        case automatic = "NativeOCRPremergeAuto"
    }
    struct Loaded: Sendable {
        let content: NativeOCRPremergeCandidateModel
        let selection: NativeOCRPremergeCandidateSelection
        let automatic: NativeOCRPremergeAutoPolicy
    }
    static func resourceURL(_ file: File, bundle: Bundle) -> URL? {
        for directory in [nil, "PremergeSignalPolicy", "Translation/PremergeSignalPolicy", "Resources/Translation/PremergeSignalPolicy"] as [String?]
        {
            if let url = bundle.url(forResource: file.rawValue, withExtension: "json", subdirectory: directory) { return url }
        }
        return nil
    }
    static func load(bundle: Bundle = .main) -> Loaded? {
        guard let content = resourceURL(.content, bundle: bundle), let quality = resourceURL(.quality, bundle: bundle),
            let duplicates = resourceURL(.duplicates, bundle: bundle), let automatic = resourceURL(.automatic, bundle: bundle)
        else { return nil }
        let model = NativeOCRPremergeCandidateModel(contentsOf: content)
        let selection = NativeOCRPremergeCandidateSelection(qualityURL: quality, policyURL: duplicates)
        let policy = NativeOCRPremergeAutoPolicy(contentsOf: automatic)
        // A research model or malformed replacement cannot silently become a
        // production filter. Missing evidence retains the existing fail-open path.
        guard model.isAdmittedSignalFilter, selection.usesOnlyFixedConfidenceAndIoU, policy.isAvailable else { return nil }
        return .init(content: model, selection: selection, automatic: policy)
    }
}
