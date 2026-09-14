// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CryptoKit
import Foundation

/// Immutable, tightly described RGBA pixels. Row padding is accepted but is not
/// included in fingerprints, so only visible pixels affect identity.
@available(iOS 18.0, *)
struct NativeOCRRGBAFrame: Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]

    init?(width: Int, height: Int, bytesPerRow: Int? = nil, bytes: [UInt8]) {
        guard width > 0, height > 0 else { return nil }
        let minimumBytesPerRow = width.multipliedReportingOverflow(by: 4)
        guard !minimumBytesPerRow.overflow else { return nil }
        let resolvedBytesPerRow = bytesPerRow ?? minimumBytesPerRow.partialValue
        guard resolvedBytesPerRow >= minimumBytesPerRow.partialValue else {
            return nil
        }
        let requiredBytes = resolvedBytesPerRow.multipliedReportingOverflow(
            by: height
        )
        guard !requiredBytes.overflow, bytes.count >= requiredBytes.partialValue
        else {
            return nil
        }
        self.width = width
        self.height = height
        self.bytesPerRow = resolvedBytesPerRow
        self.bytes = bytes
    }
}

/// A SHA-256 identity of every visible RGBA byte plus the frame dimensions.
/// `primary` and `verifier` remain available for cache/API compatibility while
/// equality and hashing retain the remaining SHA-256 words as collision guards.
@available(iOS 18.0, *)
struct NativeOCRFrameFingerprint: Codable, Hashable, Sendable {
    let width: Int
    let height: Int
    let primary: UInt64
    let verifier: UInt64

    private let continuation1: UInt64
    private let continuation2: UInt64

    init(
        width: Int,
        height: Int,
        primary: UInt64,
        verifier: UInt64
    ) {
        self.width = width
        self.height = height
        self.primary = primary
        self.verifier = verifier
        continuation1 = 0
        continuation2 = 0
    }

    fileprivate init(
        width: Int,
        height: Int,
        sha256: NativeOCRSHA256Words
    ) {
        self.width = width
        self.height = height
        primary = sha256.word0
        verifier = sha256.word1
        continuation1 = sha256.word2
        continuation2 = sha256.word3
    }
}

/// Fixed-width representation avoids retaining `Data`/pixel storage while
/// preserving all 256 SHA bits for exact-change comparisons.
@available(iOS 18.0, *)
fileprivate struct NativeOCRSHA256Words: Hashable, Sendable {
    let word0: UInt64
    let word1: UInt64
    let word2: UInt64
    let word3: UInt64

    init(_ digest: SHA256.Digest) {
        let words = digest.withUnsafeBytes { bytes in
            (
                Self.word(in: bytes, at: 0),
                Self.word(in: bytes, at: 8),
                Self.word(in: bytes, at: 16),
                Self.word(in: bytes, at: 24)
            )
        }
        word0 = words.0
        word1 = words.1
        word2 = words.2
        word3 = words.3
    }

    private static func word(
        in bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt64 {
        var result: UInt64 = 0
        for index in offset..<(offset + MemoryLayout<UInt64>.size) {
            result = (result << 8) | UInt64(bytes[index])
        }
        return result
    }
}

@available(iOS 18.0, *)
enum NativeOCRFrameDigestBuilder {
    static func fingerprint(
        of frame: NativeOCRRGBAFrame
    ) -> NativeOCRFrameFingerprint {
        var hasher = SHA256()
        let visibleBytesPerRow = frame.width * 4
        frame.bytes.withUnsafeBytes { bytes in
            let visibleByteCount = visibleBytesPerRow * frame.height
            if frame.bytesPerRow == visibleBytesPerRow {
                hasher.update(bufferPointer: UnsafeRawBufferPointer(
                    rebasing: bytes[0..<visibleByteCount]
                ))
            } else {
                for y in 0..<frame.height {
                    let rowStart = y * frame.bytesPerRow
                    let visibleRow = UnsafeRawBufferPointer(
                        rebasing: bytes[
                            rowStart..<(rowStart + visibleBytesPerRow)
                        ]
                    )
                    hasher.update(bufferPointer: visibleRow)
                }
            }
        }

        return NativeOCRFrameFingerprint(
            width: frame.width,
            height: frame.height,
            sha256: NativeOCRSHA256Words(hasher.finalize())
        )
    }

    static func fingerprintOffMain(
        of frame: NativeOCRRGBAFrame
    ) async -> NativeOCRFrameFingerprint {
        await Task.detached(priority: .userInitiated) {
            fingerprint(of: frame)
        }.value
    }
}
