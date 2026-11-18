import Foundation

/// Two scalar post-decode gates selected by whole TRAIN group-CV and frozen
/// DEV comparison. This never changes or reruns REC, fabricates text, rewrites
/// crop ownership, or treats an unmatched evaluation box as a semantic class.
enum NativeSimpleRecognitionAdmission {
    static let policyVersion = "simple-rec64-confidence-rfdet-v1"
    static let rfSource165Column = 6
    static let detectorSource165Column = 163
    static let source165Count = 165

    struct Configuration: Codable, Equatable, Sendable {
        var confidenceFloor: Double = 0.8
        var agreementFloor: Double? = 0.25
    }

    static let selected = Configuration()
    /// Candidate only until the owner promotes/fences the policy in OCR caches.
    /// Nil preserves the caller's existing decoded-result admission exactly.
    @TaskLocal static var configuration: Configuration? = nil
    /// Exact implementation optimization, independent of admission activation.
    /// Root fences this flag; explicit false remains a full-feature comparison.
    @TaskLocal static var compactAgreementEnabled: Bool = true

    enum FeatureRequirement: Equatable, Sendable { case full165, recognitionAgreement2, notRequired }

    static func featureRequirement(compactEnabled: Bool, allowsCompactMode: Bool, usesSimpleDeduplication: Bool,
                                   observingModules: Bool, configuration: Configuration?) -> FeatureRequirement {
        guard compactEnabled, allowsCompactMode, usesSimpleDeduplication, !observingModules else { return .full165 }
        return configuration?.agreementFloor == nil ? .notRequired : .recognitionAgreement2
    }

    enum Failure: Error { case invalidConfiguration, featureBinding }
    enum Decision: Equatable, Sendable {
        case accepted, acceptedMissingAgreement, empty, invalidConfidence, belowConfidence, belowAgreement
        var kept: Bool { self == .accepted || self == .acceptedMissingAgreement }
    }

    struct Report: Equatable, Sendable {
        let configuration: Configuration
        let inputCount: Int
        let keptCount: Int
        let confidenceRejectedCount: Int
        let agreementRejectedCount: Int
        let emptyOrInvalidCount: Int
        let missingAgreementAcceptedCount: Int
    }

    static func validate(_ configuration: Configuration) throws {
        guard configuration.confidenceFloor.isFinite, (0...1).contains(configuration.confidenceFloor),
              configuration.agreementFloor.map({ $0.isFinite && (0...1).contains($0) }) ?? true else {
            throw Failure.invalidConfiguration
        }
    }

    /// Pure predicate for actual scalars. No Float32 recast, imputation, text
    /// category or source-ID rule is introduced. Missing RF/DET abstains.
    static func decision(hasText: Bool, confidence: Double, rfSupport: Double, detectorAgreement: Double,
                         configuration: Configuration) -> Decision {
        guard hasText else { return .empty }
        guard confidence.isFinite else { return .invalidConfidence }
        guard confidence >= configuration.confidenceFloor else { return .belowConfidence }
        guard let floor = configuration.agreementFloor else { return .accepted }
        guard rfSupport.isFinite, detectorAgreement.isFinite else { return .acceptedMissingAgreement }
        return min(rfSupport, detectorAgreement) >= floor ? .accepted : .belowAgreement
    }

    @available(iOS 18.0, *)
    struct Result: Sendable {
        let reads: [NativeCoreMLRecognizedRegion]
        let report: Report
    }

    /// source165Indices is the ACTUAL scheduled ordinal -> immutable scored
    /// bank row mapping (preIndices), never an accepted-array ordinal. Consume
    /// the existing complete 165-vector; do not manufacture a proxy vector.
    @available(iOS 18.0, *)
    static func apply(_ reads: [NativeCoreMLRecognizedRegion], source165: [[Double]], source165Indices: [Int],
                      configuration: Configuration) throws -> Result {
        try apply(reads, configuration: configuration) { sourceIndex in
            let index = try featureIndex(sourceIndex, mapping: source165Indices, count: source165.count)
            guard source165[index].count == source165Count else { throw Failure.featureBinding }
            return NativeOCRPreRecognitionFeatures.RecognitionAgreement(rfSupport: source165[index][rfSource165Column],
                detectorAgreement: source165[index][detectorSource165Column])
        }
    }

    /// Actual two-signal extraction uses the same original scored-bank row
    /// mapping. These are typed measured values, never a proxy165-vector.
    @available(iOS 18.0, *)
    static func apply(_ reads: [NativeCoreMLRecognizedRegion], agreement: [NativeOCRPreRecognitionFeatures.RecognitionAgreement],
                      source165Indices: [Int], configuration: Configuration) throws -> Result {
        try apply(reads, configuration: configuration) { sourceIndex in
            agreement[try featureIndex(sourceIndex, mapping: source165Indices, count: agreement.count)]
        }
    }

    /// Confidence-only configurations need no RF/DET feature computation.
    @available(iOS 18.0, *)
    static func apply(_ reads: [NativeCoreMLRecognizedRegion], configuration: Configuration) throws -> Result {
        guard configuration.agreementFloor == nil else { throw Failure.featureBinding }
        return try apply(reads, configuration: configuration, signals: { _ in nil })
    }

    private static func featureIndex(_ sourceIndex: Int, mapping: [Int], count: Int) throws -> Int {
        guard mapping.indices.contains(sourceIndex), (0..<count).contains(mapping[sourceIndex]) else {
            throw Failure.featureBinding
        }
        return mapping[sourceIndex]
    }

    @available(iOS 18.0, *)
    private static func apply(_ reads: [NativeCoreMLRecognizedRegion], configuration: Configuration,
                              signals: (Int) throws -> NativeOCRPreRecognitionFeatures.RecognitionAgreement?) throws -> Result {
        try validate(configuration)
        var kept: [NativeCoreMLRecognizedRegion] = []
        kept.reserveCapacity(reads.count)
        var confidenceRejected = 0, agreementRejected = 0, emptyOrInvalid = 0, missingAccepted = 0
        for read in reads {
            let agreement: NativeOCRPreRecognitionFeatures.RecognitionAgreement?
            if configuration.agreementFloor != nil { agreement = try signals(read.sourceIndex) } else { agreement = nil }
            guard agreement != nil || configuration.agreementFloor == nil else { throw Failure.featureBinding }
            let outcome = decision(hasText: !read.text.isEmpty, confidence: read.confidence,
                rfSupport: agreement?.rfSupport ?? .nan, detectorAgreement: agreement?.detectorAgreement ?? .nan,
                configuration: configuration)
            switch outcome {
            case .accepted: kept.append(read)
            case .acceptedMissingAgreement: kept.append(read); missingAccepted += 1
            case .belowConfidence: confidenceRejected += 1
            case .belowAgreement: agreementRejected += 1
            case .empty, .invalidConfidence: emptyOrInvalid += 1
            }
        }
        return .init(reads: kept, report: .init(configuration: configuration, inputCount: reads.count,
            keptCount: kept.count, confidenceRejectedCount: confidenceRejected,
            agreementRejectedCount: agreementRejected, emptyOrInvalidCount: emptyOrInvalid,
            missingAgreementAcceptedCount: missingAccepted))
    }
}
