//
//  EpochDate.swift
//  AidokuRunner
//
//  Created by Skitty on 5/11/25.
//

import Foundation

@propertyWrapper
public struct EpochDate: Codable, Hashable, Sendable {
    public var wrappedValue: Date?

    public init(wrappedValue: Date?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let intValue = try container.decode(Int64?.self)
        if let intValue {
            self.wrappedValue = Date(timeIntervalSince1970: TimeInterval(intValue))
        } else {
            self.wrappedValue = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let seconds: Int64?
        if let wrappedValue {
            guard let value = Int64(exactly: wrappedValue.timeIntervalSince1970.rounded(.towardZero)) else {
                throw EncodingError.invalidValue(wrappedValue, .init(
                    codingPath: encoder.codingPath, debugDescription: "Date is outside the epoch range"))
            }
            seconds = value
        } else {
            seconds = nil
        }
        if encoder is PostcardEncoding {
            if let seconds {
                try container.encode(UInt8(1))
                try container.encode(seconds)
            } else {
                try container.encode(UInt8(0))
            }
        } else {
            try container.encode(seconds)
        }
    }
}
