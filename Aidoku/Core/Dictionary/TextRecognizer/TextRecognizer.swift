//
//  TextRecognizer.swift
//  Aidoku (iOS)
//
//  Created by GameFuzzy on 7/11/26.
//

import UIKit
import Vision

@available(iOS 18.0, *)
class TextRecognizer {
    enum ReadingOrientation {
        case vertical
        case leftToRight
        case rightToLeft
    }

    enum ObservationDirection {
        case topToBottom
        case leftToRight
        case rightToLeft
        case unknown
    }

    struct OCRCharacter {
        let text: String
        let boundingRect: CGRect
    }

    struct OCRObservation {
        let text: String
        let boundingRect: CGRect
        let direction: ObservationDirection
        let confidence: Float
        let characters: [OCRCharacter]
    }

    struct Result {
        let text: String
        let fullText: String
        var charRect: CGRect
        var charRects: [CGRect]
    }

    struct ParagraphOverlay {
        struct CharHit {
            let text: String
            let rect: CGRect
        }

        struct Segment {
            let text: String
            let rect: CGRect
            let charHits: [CharHit]
        }

        let text: String
        let rect: CGRect
        let segments: [Segment]
    }

    // Publication, reset and lookup share a lock. Vision and cluster construction
    // happen on a private instance before publication, outside this lock.
    let stateLock = NSRecursiveLock()
    private var stateGeneration: UInt64 = 0

    struct PreparedAnalysis {
        let observations: [OCRObservation]
        let clusters: [[Int]]
        let orderedClusters: [[Int]]
        let indexByObservation: [Int: Int]
    }

    func analysisGeneration() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stateGeneration
    }

    static func prepareAnalysis(_ observations: [OCRObservation]) -> PreparedAnalysis {
        let staging = TextRecognizer()
        staging.observations = observations
        staging.rebuildClusterCache()
        return PreparedAnalysis(observations: staging.observations,
                                clusters: staging.cachedClusters,
                                orderedClusters: staging.cachedOrderedClusters,
                                indexByObservation: staging.clusterIndexByObservation)
    }

    @discardableResult
    func commitAnalysis(_ prepared: PreparedAnalysis, generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard generation == stateGeneration, !Task.isCancelled else { return false }
        observations = prepared.observations
        cachedClusters = prepared.clusters
        cachedOrderedClusters = prepared.orderedClusters
        clusterIndexByObservation = prepared.indexByObservation
        return true
    }

    var observations: [OCRObservation] = []
    var cachedClusters: [[Int]] = []
    var cachedOrderedClusters: [[Int]] = []
    var clusterIndexByObservation: [Int: Int] = [:]

    func reset() {
        stateLock.lock()
        defer { stateLock.unlock() }
        stateGeneration &+= 1
        observations = []
        cachedClusters = []
        cachedOrderedClusters = []
        clusterIndexByObservation = [:]
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
