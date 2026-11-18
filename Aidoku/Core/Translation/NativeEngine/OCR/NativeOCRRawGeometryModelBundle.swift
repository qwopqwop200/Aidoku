import Foundation

/// Explicit, default-OFF resolution of admitted source-only numeric JSON models.
/// Resource presence never activates a mode. The pipeline owns activation and
/// model lifetime after native validation; this resolver neither promotes nor
/// executes a model and never accepts external model paths or row/GT catalogs.
@available(iOS 18.0, *)
enum NativeOCRRawGeometryModelBundle {
    enum Request: Sendable {
        case disabled
        case primaryAndGate
        /// Auxiliary is optional as a mode, but REQUIRED when explicitly asked
        /// for. A missing/invalid auxiliary must not silently alter the bank.
        case primaryGateAndAuxiliary
    }

    enum File: String, CaseIterable, Hashable, Sendable {
        case primary = "NativeOCRRawCanonicalPrimary8D"
        case gate = "NativeOCRRawSourceGate155"
        case auxiliary = "NativeOCRRawCanonicalAuxiliary8D"
        case preRecognition = "NativeOCRPreRecognition165"
        // The accepted CC03 discovery policy compares against this older
        // source-only localization. It is NEVER emitted as final geometry.
        case auxiliaryReference = "NativeOCRAuxiliaryNoveltyReference8D"

        fileprivate var maximumBytes: Int {
            self == .gate ? 1_048_576 : 64 * 1_024 * 1_024
        }
    }

    enum Failure: Error {
        case missingResource(File)
        case invalidResourceSize(File)
        case invalidFeatureContract
    }

    /// Immutable typed models; no URLs, mutable caches, source identifiers,
    /// training records or geometry lookup tables are retained in this payload.
    struct Loaded: Sendable {
        let primary: NativeOCRRawBoundaryGenerator.Model
        let gate: NativeOCRRawSourceAdmission.Model
        let auxiliary: NativeOCRRawBoundaryGenerator.Model?
        let preRecognition: NativeOCRPreRecognitionFilter.Model
        let auxiliaryReference: NativeOCRRawBoundaryGenerator.Model
    }

    enum RequiredHeads: Sendable {
        case full
        case preRecognitionOnly
        case none
    }

    enum Resolved: Sendable {
        case full(Loaded)
        case preRecognition(NativeOCRPreRecognitionFilter.Model)
        case none
    }

    /// Replaces the pipeline's eager retained payload, not a second/global cache.
    /// One lock serializes acquisition and publishes only complete required sets.
    /// Unrequested files are never located/read/decoded; failures stay file-local.
    final class Provider: @unchecked Sendable {
        private struct Heads {
            var primary: NativeOCRRawBoundaryGenerator.Model?
            var gate: NativeOCRRawSourceAdmission.Model?
            var auxiliary: NativeOCRRawBoundaryGenerator.Model?
            var preRecognition: NativeOCRPreRecognitionFilter.Model?
            var auxiliaryReference: NativeOCRRawBoundaryGenerator.Model?
        }
        private let lock = NSLock()
        private let read: @Sendable (File) throws -> Data
        private let geometryFeatureNames: @Sendable () -> [String]
        private let supplied: Result<Loaded, Error>?
        private var heads = Heads()
        private var failures: [File: Error] = [:]

        init(bundle: Bundle = .main) {
            read = { try NativeOCRRawGeometryModelBundle.data($0, bundle: bundle) }
            geometryFeatureNames = { NativeOCRRawCanonicalGeometry.featureNames }
            supplied = nil
        }

        /// Preserve explicit already-resolved test/caller injection without rereads.
        init(supplied: Result<Loaded, Error>) {
            self.supplied = supplied
            read = { throw Failure.missingResource($0) }
            geometryFeatureNames = { NativeOCRRawCanonicalGeometry.featureNames }
        }

        /// Internal deterministic loader seam: no environment/path routing.
        init(read: @escaping @Sendable (File) throws -> Data,
             geometryFeatureNames: @escaping @Sendable () -> [String] = { NativeOCRRawCanonicalGeometry.featureNames }) {
            self.read = read
            self.geometryFeatureNames = geometryFeatureNames
            supplied = nil
        }

        private func decode<Model>(_ file: File, cancellationCheck: () throws -> Void,
                                   construct: (Data) throws -> Model) throws -> Model {
            if let failure = failures[file] { throw failure }
            try cancellationCheck()
            let bytes: Data
            do { bytes = try read(file) }
            catch {
                if !(error is CancellationError) { failures[file] = error }
                throw error
            }
            // Cancellation callbacks stay outside resource/parser catch blocks:
            // even a caller's custom cancellation error must not become sticky.
            try cancellationCheck()
            let model: Model
            do { model = try construct(bytes) }
            catch {
                if !(error is CancellationError) { failures[file] = error }
                throw error
            }
            try cancellationCheck()
            return model
        }

        func acquire(_ required: RequiredHeads, cancellationCheck: () throws -> Void) throws -> Resolved {
            try cancellationCheck()
            if case .none = required { return .none }
            lock.lock(); defer { lock.unlock() }
            try cancellationCheck()
            if let supplied {
                let loaded = try supplied.get()
                switch required {
                case .full: return .full(loaded)
                case .preRecognitionOnly: return .preRecognition(loaded.preRecognition)
                case .none: return .none
                }
            }
            // A failed required file short-circuits the same set on repeat;
            // unrelated modes remain usable without retrying successful decodes.
            let requiredFiles: [File] = required == .full ?
                [.primary, .gate, .auxiliary, .preRecognition, .auxiliaryReference] : [.preRecognition]
            for file in requiredFiles {
                if let failure = failures[file] { throw failure }
            }
            var pending = heads
            func preRecognition() throws -> NativeOCRPreRecognitionFilter.Model {
                if let model = pending.preRecognition { return model }
                let model = try decode(.preRecognition, cancellationCheck: cancellationCheck) {
                    try NativeOCRPreRecognitionFilter.Model(data: $0,
                        expectedFeatureNames: NativeOCRPreRecognitionFeatures.featureNames)
                }
                pending.preRecognition = model
                return model
            }
            if case .preRecognitionOnly = required {
                let model = try preRecognition()
                try cancellationCheck()
                heads = pending
                return .preRecognition(model)
            }
            func geometry(_ file: File) throws -> NativeOCRRawBoundaryGenerator.Model {
                let names = geometryFeatureNames()
                guard names.count == NativeOCRRawBoundaryGenerator.featureCount,
                      names.count == 422, Set(names).count == names.count else {
                    throw Failure.invalidFeatureContract
                }
                return try decode(file, cancellationCheck: cancellationCheck) {
                    try NativeOCRRawBoundaryGenerator.Model(data: $0, expectedFeatureNames: names)
                }
            }
            // Original full-load order and original model constructors/bytes.
            if pending.primary == nil { pending.primary = try geometry(.primary) }
            if pending.gate == nil {
                pending.gate = try decode(.gate, cancellationCheck: cancellationCheck) {
                    try NativeOCRRawSourceAdmission.Model(data: $0)
                }
            }
            if pending.auxiliary == nil { pending.auxiliary = try geometry(.auxiliary) }
            let pre = try preRecognition()
            if pending.auxiliaryReference == nil { pending.auxiliaryReference = try geometry(.auxiliaryReference) }
            guard let primary = pending.primary, let gate = pending.gate,
                  let auxiliary = pending.auxiliary, let reference = pending.auxiliaryReference else {
                throw Failure.invalidFeatureContract
            }
            let loaded = Loaded(primary: primary, gate: gate, auxiliary: auxiliary,
                                preRecognition: pre, auxiliaryReference: reference)
            try cancellationCheck()
            heads = pending
            return .full(loaded)
        }
    }

    /// Same deterministic root/subdirectory search pattern as PremergePolicyBundle,
    /// with separate filenames and directory for the new canonical mode.
    private static func resourceURL(_ file: File, bundle: Bundle) throws -> URL {
        let directories: [String?] = [nil, "RawCanonicalGeometry",
            "Translation/RawCanonicalGeometry", "Resources/Translation/RawCanonicalGeometry"]
        for directory in directories {
            if let url = bundle.url(forResource: file.rawValue, withExtension: "json", subdirectory: directory) {
                return url
            }
        }
        throw Failure.missingResource(file)
    }

    private static func data(_ file: File, bundle: Bundle) throws -> Data {
        let url = try resourceURL(file, bundle: bundle)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size > 0, size <= file.maximumBytes else {
            throw Failure.invalidResourceSize(file)
        }
        let bytes = try Data(contentsOf: url)
        guard !bytes.isEmpty, bytes.count <= file.maximumBytes else {
            throw Failure.invalidResourceSize(file)
        }
        return bytes
    }

    /// Default request performs NO resource reads and returns nil. An enabled
    /// request either returns the whole validated payload or throws: there is
    /// no partial success, implicit auxiliary omission or environment override.
    static func load(bundle: Bundle = .main, request: Request = .disabled) throws -> Loaded? {
        switch request {
        case .disabled:
            return nil
        case .primaryAndGate, .primaryGateAndAuxiliary:
            break
        }
        let names = NativeOCRRawCanonicalGeometry.featureNames
        guard names.count == NativeOCRRawBoundaryGenerator.featureCount,
              names.count == 422, Set(names).count == names.count else {
            throw Failure.invalidFeatureContract
        }
        // Generator validates exact422 names, 8D geometry/pixel ABI, strict keys
        // and no row/label tables. Decode ORIGINAL bytes; never JSON round-trip.
        let primary = try NativeOCRRawBoundaryGenerator.Model(
            data: data(.primary, bundle: bundle), expectedFeatureNames: names)
        // Gate validates exact155 + missingFeatureFraction internally, including
        // schema, numeric nodes and its frozen strict comparison semantics.
        let gate = try NativeOCRRawSourceAdmission.Model(data: data(.gate, bundle: bundle))
        let auxiliary: NativeOCRRawBoundaryGenerator.Model?
        switch request {
        case .primaryGateAndAuxiliary:
            auxiliary = try NativeOCRRawBoundaryGenerator.Model(
                data: data(.auxiliary, bundle: bundle), expectedFeatureNames: names)
        case .primaryAndGate:
            auxiliary = nil
        case .disabled:
            // The first switch returns before any IO for this case.
            return nil
        }
        let preRecognition = try NativeOCRPreRecognitionFilter.Model(
            data: data(.preRecognition, bundle: bundle), expectedFeatureNames: NativeOCRPreRecognitionFeatures.featureNames)
        let reference = try NativeOCRRawBoundaryGenerator.Model(
            data:data(.auxiliaryReference,bundle:bundle),expectedFeatureNames:names)
        return Loaded(primary: primary, gate: gate, auxiliary: auxiliary, preRecognition: preRecognition,
            auxiliaryReference:reference)
    }
}
