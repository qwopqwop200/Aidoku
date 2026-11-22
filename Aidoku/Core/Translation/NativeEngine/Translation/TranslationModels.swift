import Foundation
import CryptoKit

private func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 48...57, 65...90, 97...122: true
    default: false
    }
}

enum RemoteTranslationError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration(String)
    case invalidRequest(String)
    case invalidResponse(String)
    case missingCredential
    case credentialAccessFailed
    case insecureEndpoint
    case redirectRejected
    case responseTooLarge
    case httpStatus(Int, requestID: String?)
    case transport(URLError.Code)
    case privateTailnetUnavailable
    case refused

    static func httpStatusKey(_ status: Int) -> String {
        switch status {
        case 401, 403: "TRANSLATION_ERROR_HTTP_KEY"
        case 404: "TRANSLATION_ERROR_HTTP_NOT_FOUND"
        case 429: "TRANSLATION_ERROR_HTTP_LIMIT"
        case 500...: "TRANSLATION_ERROR_HTTP_SERVER"
        default: "TRANSLATION_ERROR_HTTP"
        }
    }

    var errorDescription: String? {
        // Keep diagnostic payloads in the error for logging; user-facing text is localized.
        switch self {
        case .invalidConfiguration: NSLocalizedString("TRANSLATION_ERROR_CONFIGURATION")
        case .invalidRequest: NSLocalizedString("TRANSLATION_ERROR_REQUEST")
        case .invalidResponse: NSLocalizedString("TRANSLATION_ERROR_RESPONSE")
        case .missingCredential: NSLocalizedString("TRANSLATION_ERROR_KEY_REQUIRED")
        case .credentialAccessFailed: NSLocalizedString("TRANSLATION_ERROR_KEY_ACCESS")
        case .insecureEndpoint: NSLocalizedString("TRANSLATION_ERROR_ENDPOINT")
        case .redirectRejected: NSLocalizedString("TRANSLATION_ERROR_REDIRECT")
        case .responseTooLarge: NSLocalizedString("TRANSLATION_ERROR_RESPONSE_SIZE")
        // The request ID stays in the error for logs; people get the likely cause.
        case let .httpStatus(status, _):
            String(format: NSLocalizedString(Self.httpStatusKey(status)), status)
        case let .transport(code): String(format: NSLocalizedString("TRANSLATION_ERROR_NETWORK_CODE"), code.rawValue)
        case .privateTailnetUnavailable: NSLocalizedString("TRANSLATION_ERROR_CONNECTION")
        case .refused: NSLocalizedString("TRANSLATION_ERROR_REFUSED")
        }
    }
}

enum RemoteTranslationProtocol: String, Codable, Hashable, Sendable {
    case responses
    case chatCompletions
}

enum RemoteTranslationProvider: String, Codable, Hashable, Sendable {
    case openAI = "openai"
    case custom

    /// The endpoint host decides: https api.openai.com is OpenAI, every other server is custom.
    init(baseURL: String) {
        let url = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        let isOpenAI = url?.scheme?.lowercased() == "https" && url?.host?.lowercased() == "api.openai.com" &&
            (url?.port ?? 443) == 443
        self = isOpenAI ? .openAI : .custom
    }
}

enum OpenAIReasoningEffort: String, Codable, CaseIterable, Hashable, Sendable {
    case modelDefault, none, minimal, low, medium, high, xhigh, max
}

struct RemoteTranslationSegment: Codable, Hashable, Sendable {
    let id: String
    let text: String
    var bounds: [Double]? = nil
}

/// Provider classification whose spelling/schema was validated, not independent
/// semantic proof. Old cached results omit this optional metadata.
enum RemoteTranslationTextRole: String, Codable, Hashable, CaseIterable, Sendable {
    case dialogue, narration
    case storyText = "story_text"
    case sfx, background, error
}

struct RemoteTranslatedSegment: Codable, Hashable, Sendable {
    let id: String
    let text: String
    var isSFX: Bool? = nil
    var textRole: RemoteTranslationTextRole? = nil
}

/// Request-local derived value; it retains no image bytes and is shared only
/// while request copies refer to the same immutable Data value.
private final class TranslationImageDigestMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func digest(of data: Data) -> String {
        lock.lock(); defer { lock.unlock() }
        if let value { return value }
        let digest = Self.compute(data)
        value = digest
        return digest
    }

    static func compute(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct RemoteTranslationRequest: Codable, Hashable, Sendable {
    static let singleSegmentID = "segment-0"
    static let maximumSegments = 64
    static let maximumSegmentIDBytes = 128
    static let maximumSegmentTextBytes = 16 * 1024
    static let maximumSourceBytes = 128 * 1024

    var imageJPEG: Data? = nil {
        didSet {
            imageDigestMemo = imageJPEG == nil ? nil : TranslationImageDigestMemo()
        }
    }
    private var imageDigestMemo: TranslationImageDigestMemo?
    var imageDigest: String? {
        guard let imageJPEG else { return nil }
        return imageDigestMemo?.digest(of: imageJPEG) ?? TranslationImageDigestMemo.compute(imageJPEG)
    }

    mutating func copyImageRepresentation(from request: Self) {
        imageJPEG = request.imageJPEG
        imageDigestMemo = request.imageDigestMemo
    }
    private enum CodingKeys: String, CodingKey {
        case imageJPEG, filtersSFX, filtersBackground, translatesPageLettering, sourceLanguage, targetLanguage, segments
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.imageJPEG == rhs.imageJPEG && lhs.filtersSFX == rhs.filtersSFX && lhs.filtersBackground == rhs.filtersBackground
            && lhs.translatesPageLettering == rhs.translatesPageLettering && lhs.sourceLanguage == rhs.sourceLanguage && lhs.targetLanguage == rhs.targetLanguage
            && lhs.segments == rhs.segments
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(imageJPEG); hasher.combine(filtersSFX); hasher.combine(filtersBackground); hasher.combine(translatesPageLettering)
        hasher.combine(sourceLanguage); hasher.combine(targetLanguage)
        hasher.combine(segments)
    }

    var filtersSFX: Bool? = nil
    var filtersBackground: Bool? = nil
    /// Page OCR requires an image and text-role classification, unlike metadata.
    var translatesPageLettering: Bool? = nil

    let sourceLanguage: String
    let targetLanguage: String
    let segments: [RemoteTranslationSegment]

    init(sourceLanguage: String, targetLanguage: String, segments: [RemoteTranslationSegment]) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.segments = segments
    }

    init(sourceLanguage: String, targetLanguage: String, sourceText: String) {
        self.init(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
                  segments: [RemoteTranslationSegment(id: Self.singleSegmentID, text: sourceText)])
    }

    func validate() throws {
        if let imageJPEG, imageJPEG.isEmpty || imageJPEG.count > 4 * 1024 * 1024 {
            throw RemoteTranslationError.invalidRequest("translation image exceeds its safe size limit")
        }
        try validateLanguage(sourceLanguage, field: "source language", permitsAuto: true)
        try validateLanguage(targetLanguage, field: "target language", permitsAuto: false)

        guard !segments.isEmpty, segments.count <= Self.maximumSegments else {
            throw RemoteTranslationError.invalidRequest("translation batch must contain 1...\(Self.maximumSegments) segments")
        }
        var segmentIDs = Set<String>()
        var sourceBytes = 0
        for segment in segments {
            if let bounds = segment.bounds {
                guard bounds.count == 4, bounds.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    throw RemoteTranslationError.invalidRequest("invalid segment bounds")
                }
            }
            guard Self.hasValidIdentifier(segment), segmentIDs.insert(segment.id).inserted else {
                throw RemoteTranslationError.invalidRequest("segment IDs must be unique, stable, and URL-safe")
            }
            guard Self.hasNonBlankSourceText(segment) else {
                throw RemoteTranslationError.invalidRequest("translation segments cannot be blank")
            }
            guard Self.hasSafeSourceTextSize(segment) else {
                throw RemoteTranslationError.invalidRequest("source segments exceed their safe size limit")
            }
            sourceBytes += segment.text.utf8.count
        }
        guard sourceBytes <= Self.maximumSourceBytes else {
            throw RemoteTranslationError.invalidRequest("source segments exceed their safe size limit")
        }
    }

    /// Individually safe, unambiguous candidates, so one bad OCR line cannot fail its whole batch.
    static func admissibleSegmentIndices(in segments: [RemoteTranslationSegment]) -> [Int] {
        let identifierCounts = segments.reduce(into: [String: Int]()) { $0[$1.id, default: 0] += 1 }
        return segments.indices.filter { index in
            let segment = segments[index]
            return hasValidIdentifier(segment) && hasNonBlankSourceText(segment) &&
                hasSafeSourceTextSize(segment) && identifierCounts[segment.id] == 1
        }
    }

    private static func hasValidIdentifier(_ segment: RemoteTranslationSegment) -> Bool {
        !segment.id.isEmpty && segment.id.utf8.count <= maximumSegmentIDBytes &&
            segment.id.unicodeScalars.allSatisfy {
                isASCIIAlphaNumeric($0) || $0 == "-" || $0 == "_" || $0 == "." || $0 == ":"
            }
    }

    private static func hasNonBlankSourceText(_ segment: RemoteTranslationSegment) -> Bool {
        !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func hasSafeSourceTextSize(_ segment: RemoteTranslationSegment) -> Bool {
        segment.text.utf8.count <= maximumSegmentTextBytes
    }

    private func validateLanguage(_ value: String, field: String, permitsAuto: Bool) throws {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.utf8.count <= 35,
              value.unicodeScalars.allSatisfy({ isASCIIAlphaNumeric($0) || $0 == "-" }),
              permitsAuto || value.caseInsensitiveCompare("auto") != .orderedSame
        else {
            throw RemoteTranslationError.invalidRequest("\(field) is invalid")
        }
    }
}

struct RemoteTranslationConfiguration: Hashable, Sendable {
    static let defaultInstructions = "Preserve tone, emphasis and vocal expression naturally."

    static let maximumTimeout: Double = 600

    let provider: RemoteTranslationProvider
    let apiProtocol: RemoteTranslationProtocol
    let baseURL: String
    let model: String
    let credentialAccount: String
    /// Increment whenever an API key, organization, project, or tenant binding
    /// changes. Secrets themselves never enter cache keys or persistence.
    var credentialGeneration: UInt64 = 0
    var instructions = RemoteTranslationConfiguration.defaultInstructions
    var reasoningEffort = OpenAIReasoningEffort.modelDefault
    var timeout: TimeInterval = 60
    var maximumResponseBytes = 1024 * 1024
    /// Development-only; endpoint policy limits it to canonical loopback hosts.
    var allowsInsecureLocalhostForDevelopment = false

    static func openAI(
        model: String, credentialAccount: String = "openai", credentialGeneration: UInt64 = 0,
        instructions: String = Self.defaultInstructions, reasoningEffort: OpenAIReasoningEffort = .modelDefault,
        timeout: TimeInterval = 60
    ) -> Self {
        Self(provider: .openAI, apiProtocol: .responses, baseURL: "https://api.openai.com", model: model,
             credentialAccount: credentialAccount, credentialGeneration: credentialGeneration, instructions: instructions,
             reasoningEffort: reasoningEffort, timeout: timeout)
    }

    func validatedEndpoint() throws -> URL {
        func isTrimmedPlainText(_ value: String, maximumBytes: Int) -> Bool {
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) && !value.isEmpty &&
                value.utf8.count <= maximumBytes &&
                !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        guard isTrimmedPlainText(model, maximumBytes: 256) else {
            throw RemoteTranslationError.invalidConfiguration("model is invalid")
        }
        guard isTrimmedPlainText(credentialAccount, maximumBytes: 256) else {
            throw RemoteTranslationError.invalidConfiguration("credential account is invalid")
        }
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              instructions.utf8.count <= 32 * 1024 else {
            throw RemoteTranslationError.invalidConfiguration("instructions exceed their safe size limit or are blank")
        }
        guard (1...Self.maximumTimeout).contains(timeout) else {
            throw RemoteTranslationError.invalidConfiguration("timeout must be between 1 and 600 seconds")
        }
        guard (4 * 1024...4 * 1024 * 1024).contains(maximumResponseBytes) else {
            throw RemoteTranslationError.invalidConfiguration("response limit is outside the supported range")
        }
        guard provider == .custom || !allowsInsecureLocalhostForDevelopment else {
            throw RemoteTranslationError.invalidConfiguration("the OpenAI provider cannot enable insecure development transport")
        }

        let endpoint = try TranslationEndpointPolicy.endpoint(for: self)
        guard provider != .openAI || (endpoint.scheme == "https" && endpoint.host?.lowercased() == "api.openai.com") else {
            throw RemoteTranslationError.invalidConfiguration("the OpenAI provider endpoint is fixed to api.openai.com")
        }
        return endpoint
    }
}

/// Every field that can change translation semantics is stored directly.
/// Deliberately avoid lossy hashes here: cache equality must remain exact.
struct TranslationCacheKey: Codable, Hashable, Sendable {
    static let schemaVersion = 25

    let imageDigest: String?
    let roleVerificationPolicy: String?
    let imageSupportRevision: Int?
    let sfxPolicy: String?
    let backgroundPolicy: String?
    let letteringPolicy: String?
    let version: Int
    let provider: RemoteTranslationProvider
    let apiProtocol: RemoteTranslationProtocol
    let endpointNamespace: String
    let model: String
    let credentialAccount: String
    let credentialGeneration: UInt64
    let sourceLanguage: String
    let targetLanguage: String
    let segments: [RemoteTranslationSegment]
    let instructions: String
    let reasoningEffort: OpenAIReasoningEffort
    let samplingTemperature: Double?
    let samplingTopP: Double?
    let maxOutputTokens: Int

    init(configuration: RemoteTranslationConfiguration, endpoint: URL, request: RemoteTranslationRequest) {
        let canonicalRequest = request.canonicalizedForTranslationSemantics().request
        backgroundPolicy = request.filtersBackground == true
            ? (request.imageJPEG == nil ? TranslationHTTPCodec.textOnlyBackgroundPolicy : TranslationHTTPCodec.backgroundPolicy)
            : nil
        sfxPolicy = request.filtersSFX == true
            ? (request.imageJPEG == nil ? TranslationHTTPCodec.textOnlySFXPolicy : TranslationHTTPCodec.sfxPolicy)
            : nil
        letteringPolicy = request.translatesPageLettering == true ? TranslationHTTPCodec.letteringPolicy : nil
        imageDigest = request.imageDigest
        roleVerificationPolicy = request.imageJPEG != nil && (request.filtersSFX == true || request.filtersBackground == true)
            ? TranslationHTTPCodec.roleVerificationPolicy : nil
        imageSupportRevision = request.imageJPEG == nil ? nil : TranslationImageSupport.shared.revision(for: configuration)
        version = Self.schemaVersion
        provider = configuration.provider
        apiProtocol = configuration.apiProtocol
        endpointNamespace = endpoint.absoluteString
        model = configuration.model
        credentialAccount = configuration.credentialAccount
        credentialGeneration = configuration.credentialGeneration
        sourceLanguage = canonicalRequest.sourceLanguage
        targetLanguage = canonicalRequest.targetLanguage
        segments = canonicalRequest.segments
        instructions = configuration.instructions
        reasoningEffort = configuration.reasoningEffort
        samplingTemperature = TranslationHTTPCodec.samplingTemperature == 0 ? nil : TranslationHTTPCodec.samplingTemperature
        samplingTopP = TranslationHTTPCodec.samplingTopP
        maxOutputTokens = TranslationHTTPCodec.maxOutputTokens
    }
}

enum TranslationResultSource: String, Codable, Hashable, Sendable {
    case network
    case memoryCache
}

struct RemoteTranslationBatchResult: Hashable, Sendable {
    let translations: [RemoteTranslatedSegment]
    let source: TranslationResultSource
    let providerRequestID: String?
}

/// Caller (OCR tracker) IDs replaced by batch-local ordinals so identical ordered
/// text shares the cache and in-flight requests; results get the caller IDs back.
struct CanonicalRemoteTranslationRequest: Sendable {
    let request: RemoteTranslationRequest
    private let callerSegmentIDs: [String]

    init(request: RemoteTranslationRequest, callerSegmentIDs: [String]) {
        self.request = request
        self.callerSegmentIDs = callerSegmentIDs
    }

    /// Every result leaves the service here, so leaked JSON escapes are decoded once.
    private func repairedText(_ text: String, at index: Int) -> String {
        TranslationHTTPCodec.decodingLeakedEscapes(
            in: text, source: request.segments.indices.contains(index) ? request.segments[index].text : nil)
    }

    func restoringCallerSegmentIDs(
        in result: RemoteTranslationBatchResult
    ) throws -> RemoteTranslationBatchResult {
        let expectedCanonicalIDs = request.segments.map(\.id)
        guard expectedCanonicalIDs.count == callerSegmentIDs.count,
              result.translations.count == expectedCanonicalIDs.count else {
            throw RemoteTranslationError.invalidResponse("canonical translation result count does not match the caller request")
        }

        var translationsByCanonicalID: [String: RemoteTranslatedSegment] = [:]
        for translation in result.translations {
            guard expectedCanonicalIDs.contains(translation.id), translationsByCanonicalID[translation.id] == nil else {
                throw RemoteTranslationError.invalidResponse("canonical translation result contains an unexpected segment")
            }
            translationsByCanonicalID[translation.id] = translation
        }

        let restored = try expectedCanonicalIDs.enumerated().map { index, canonicalID in
            guard let translation = translationsByCanonicalID[canonicalID] else {
                throw RemoteTranslationError.invalidResponse("canonical translation result omitted a segment")
            }
            let text = repairedText(translation.text, at: index)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RemoteTranslationError.invalidResponse("restored translation text is blank")
            }
            return RemoteTranslatedSegment(
                id: callerSegmentIDs[index], text: text, isSFX: translation.isSFX, textRole: translation.textRole
            )
        }
        return RemoteTranslationBatchResult(
            translations: restored, source: result.source, providerRequestID: result.providerRequestID
        )
    }
}

extension RemoteTranslationRequest {
    static func batchLocalSegmentID(at index: Int) -> String {
        precondition(index >= 0)
        return "segment-\(index)"
    }

    func canonicalizedForTranslationSemantics() -> CanonicalRemoteTranslationRequest {
        let canonical = replacingSegments(segments.enumerated().map { index, segment in
            RemoteTranslationSegment(id: Self.batchLocalSegmentID(at: index), text: segment.text, bounds: segment.bounds)
        })
        return CanonicalRemoteTranslationRequest(request: canonical, callerSegmentIDs: segments.map(\.id))
    }

    /// The same image, languages and role settings over different segments.
    func replacingSegments(_ segments: [RemoteTranslationSegment]) -> Self {
        var copy = Self(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, segments: segments)
        copy.copyImageRepresentation(from: self)
        copy.filtersSFX = filtersSFX
        copy.filtersBackground = filtersBackground
        copy.translatesPageLettering = translatesPageLettering
        return copy
    }
}
