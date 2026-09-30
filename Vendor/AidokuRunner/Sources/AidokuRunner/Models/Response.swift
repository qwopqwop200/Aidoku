//
//  Response.swift
//  AidokuRunner
//
//  Created by Skitty on 7/21/24.
//

import Foundation

public typealias ImageRef = Int32

public struct Request: Sendable, Codable {
    @URLAsString public private(set) var url: URL?
    public let headers: [String: String]

    public init(url: URL?, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }
}

public struct Response: Sendable, Codable {
    public let code: UInt16
    public let headers: [String: String]
    public let request: Request
    public let image: ImageRef

    public init(code: Int, headers: [String: String], request: Request, image: ImageRef) {
        self.code = UInt16(code)
        self.headers = headers
        self.request = request
        self.image = image
    }
}
