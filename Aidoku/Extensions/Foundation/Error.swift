//
//  Error.swift
//  Aidoku
//
//  Created by skitty on 8/18/26.
//

import AidokuRunner
import Foundation

extension Error {
    func aidokuDescription() -> String {
        if let error = self as? SourceError {
            switch error {
                case .missingResult:
                    NSLocalizedString("NO_RESULT")
                case .unimplemented:
                    NSLocalizedString("UNIMPLEMENTED")
                case .networkError:
                    NSLocalizedString("NETWORK_ERROR")
                case .message(let string):
                    NSLocalizedString(string)
                case .htmlError:
                    NSLocalizedString("HTML_ERROR")
                case .jsonParseError:
                    NSLocalizedString("JSON_ERROR")
                case .deserializeError:
                    NSLocalizedString("DECODING_ERROR")
                default:
                    NSLocalizedString("UNKNOWN_ERROR")
            }
        } else if let error = self as? AidokuRunner.Source.InitError {
            if case .unsupportedNativeSource(let sourceKey, let version) = error {
                String(format: NSLocalizedString("NATIVE_SOURCE_UNSUPPORTED_VERSION"), sourceKey, version)
            } else {
                error.localizedDescription
            }
        } else if self is DecodingError {
            NSLocalizedString("DECODING_ERROR")
        } else if self is URLError {
            NSLocalizedString("NETWORK_ERROR")
        } else {
            NSLocalizedString("UNKNOWN_ERROR")
        }
    }
}
