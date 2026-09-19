//
//  WKWebsiteDataStore.swift
//  AidokuRunner
//
//  Created by skitty on 8/16/26.
//

import WebKit

public extension WKWebsiteDataStore {
    static func forSource(key: String) -> WKWebsiteDataStore {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.init(forIdentifier: UUID(key: key))
        } else {
            Self.nonPersistent()
        }
    }

    func clearRecords() async {
        await withCheckedContinuation { continuation in
            fetchDataRecords(ofTypes: Self.allWebsiteDataTypes()) { records in
                self.removeData(ofTypes: Self.allWebsiteDataTypes(), for: records) {
                    continuation.resume()
                }
            }
        }
    }
}
