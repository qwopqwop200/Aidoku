#!/usr/bin/env python3
"""Owned source-role smoke using the unchanged production Swift sampler.

Synthetic RGB ground truth applies only to these authored pixels. Controlled
ingress hypotheses exercise the role retry independently of upstream priors.
No renderer, OCR, network, app build, or shared build/module cache is used.
Source pen width remains unknown; display correction is outside this test.
"""

import hashlib
import argparse
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
SAMPLER = ROOT / "Aidoku/Core/Translation/NativeEngine/Overlay/NativeSourceColorSampler.swift"

HARNESS = r'''
import Foundation
import CoreGraphics
import ImageIO

typealias Sampler = NativeSourceColorSampler
typealias Payload = Sampler.Payload
let width = 128, height = 96, pixels = width * height
struct Fixture: Sendable {
    let name: String
    let fill: [Double]
    let stroke: [Double]
    let background: [Double]
    var rgba: [UInt8]
    var ownership: [UInt8]
    var backgroundVariants: [[Double]]? = nil
}

func fixture(_ name: String, fill: [Double], stroke: [Double], background: [Double],
             shape: String = "H", mixedStroke: Bool = false) -> Fixture {
    var mask = [Bool](repeating: false, count: pixels)
    for origin in [18, 44, 70, 96] {
        for y in 26..<56 {
            for x in origin..<(origin + 16) {
                let xx = x - origin, yy = y - 26
                switch shape {
                case "stem": mask[y * width + x] = xx < 3
                case "island": mask[y * width + x] = xx < 14 && yy < 18
                case "blob":
                    let dx = Double(xx) - 7.5, dy = Double(yy) - 12
                    mask[y * width + x] = dx * dx / 49 + dy * dy / 100 <= 1
                default: mask[y * width + x] = xx < 3 || xx >= 13 || (yy >= 13 && yy < 16)
                }
            }
        }
    }
    var rgba = [UInt8](repeating: 255, count: pixels * 4)
    var ownership = [UInt8](repeating: 0, count: pixels)
    for y in 0..<height {
        for x in 0..<width {
            let index = y * width + x
            let owned = (8..<120).contains(x) && (8..<84).contains(y)
            ownership[index] = owned ? 1 : 0
            var edge = false
            for dy in -2...2 {
                for dx in -2...2 {
                    let xx = x + dx, yy = y + dy
                    if xx >= 0 && xx < width && yy >= 0 && yy < height && mask[yy * width + xx] { edge = true }
                }
            }
            let color = mask[index] ? fill : (edge ? stroke : background)
            for channel in 0..<3 {
                let value = mixedStroke && edge && !mask[index]
                    ? background[channel] + 0.7 * (stroke[channel] - background[channel]) : color[channel]
                rgba[index * 4 + channel] = UInt8(value.rounded())
            }
        }
    }
    return Fixture(name: name, fill: fill, stroke: stroke, background: background, rgba: rgba, ownership: ownership)
}

func prior(_ f: Fixture, foregroundConfidence: Double, backgroundConfidence: Double,
           blackForeground: Bool = false) -> Payload {
    ["foreground": blackForeground ? f.fill : f.stroke, "background": f.background,
     "stroke": blackForeground ? f.stroke as Any : NSNull(), "outline": NSNull(),
     "widthEvidence": ["samplePixels": 99], // Retry must invalidate this uncalibrated input.
     "sourceInk": ["sentinel": "retain-prior-observation"],
     "confidence": ["foreground": foregroundConfidence, "background": backgroundConfidence, "stroke": 0.0]]
}

func error(_ estimate: [Double]?, _ truth: [Double]) -> Double {
    guard let estimate, estimate.count == truth.count else { return .infinity }
    return zip(estimate, truth).map { abs($0 - $1) }.max() ?? .infinity
}

var passed = 0, failed = 0
func report(_ name: String, _ problems: [String], _ detail: Payload) {
    let row: Payload = ["case": name, "status": problems.isEmpty ? "PASS" : "FAIL",
                        "failures": problems, "output": detail]
    let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    if problems.isEmpty { passed += 1 } else { failed += 1 }
}

func run(_ f: Fixture, name: String? = nil, hypothesis: Payload, shouldAccept: Bool,
         ownership: [UInt8]? = nil, budget initialBudget: Int = pixels,
         expectedCharge: Int = pixels, expectedBlocked: Int = 0,
         expectedBackground: [Double]? = nil, requiresSpatialExterior: Bool = false) {
    var budget = initialBudget, blocked = 0
    let result = Sampler.enclosingPaleRoleRetry(rgba: f.rgba, width: width, height: height,
        ownership: ownership ?? f.ownership, result: hypothesis, observationBudget: &budget,
        onBudgetBlocked: { blocked += 1 })
    let final = result ?? hypothesis
    let fg = Sampler.rgb(final["foreground"]), stroke = Sampler.rgb(final["stroke"])
    let bg = Sampler.rgb(final["background"])
    let evidence = result?["enclosingRoleEvidence"] as? Payload
    let endpoints = evidence?["endpointEvidence"] as? Payload
    var problems: [String] = []
    if (result != nil) != shouldAccept { problems.append(shouldAccept ? "valid owned roles rejected" : "false role swap accepted") }
    if requiresSpatialExterior && evidence?["spatialExteriorObservation"] as? Bool != true {
        problems.append("fixture did not certify independent local exteriors")
    }
    if budget != initialBudget - expectedCharge { problems.append("wrong observation debit: \(initialBudget - budget)") }
    if blocked != expectedBlocked { problems.append("wrong budget callback count: \(blocked)") }
    if bg != (expectedBackground ?? f.background) { problems.append("background RGB mutated") }
    if result != nil {
        if endpoints?["accepted"] as? Bool != true { problems.append("missing accepted direct endpoints") }
        if let localPairs = evidence?["localHypothesisPairs"] {
            if Sampler.number(localPairs) > 32 || Sampler.number(evidence?["localRayWorkSpent"]) > 262_144 {
                problems.append("production local fallback exceeded candidate/ray budget")
            }
            if evidence?["interiorPointObservation"] as? Bool != true {
                problems.append("local source role lacks owned-interior provenance")
            }
        }
        let pairs = Sampler.number(evidence?["testedModePairs"])
        let localPairs = Sampler.number(evidence?["localHypothesisPairs"])
        // Legacy attempts can be zero when the remote extreme fails direct
        // contact. In that case a separately bounded local attempt is required.
        if pairs > 8 || (pairs < 1 && localPairs < 1) { problems.append("missing or unbounded source-role attempts") }
        if !(final["widthEvidence"] is NSNull) || !(evidence?["widthObservation"] is NSNull) {
            problems.append("source-width uncertainty lost")
        }
        let oldConfidence = hypothesis["confidence"] as? Payload
        let newConfidence = final["confidence"] as? Payload
        if Sampler.number(oldConfidence?["background"]) != Sampler.number(newConfidence?["background"]) {
            problems.append("background confidence mutated")
        }
        if !NSDictionary(dictionary: final["sourceInk"] as? Payload ?? [:])
            .isEqual(to: hypothesis["sourceInk"] as? Payload ?? [:]) { problems.append("saved source hypothesis mutated") }
    }
    if shouldAccept {
        if error(fg, f.fill) > 1 { problems.append("foreground differs from authored fill") }
        if error(stroke, f.stroke) > 1 { problems.append("stroke differs from authored stroke") }
    }
    let detail: Payload = ["retryAccepted": result != nil,
        "estimatedFG": fg as Any? ?? NSNull(), "estimatedStroke": stroke as Any? ?? NSNull(),
        "estimatedBG": bg as Any? ?? NSNull(), "trueFG": f.fill, "trueStroke": f.stroke,
        "trueBG": f.backgroundVariants == nil ? f.background as Any : NSNull(),
        "authoredBGVariants": f.backgroundVariants as Any? ?? NSNull(),
        "inputBGHypothesis": hypothesis["background"] as Any? ?? NSNull(),
        "roleExteriorHypothesis": evidence?["roleExteriorHypothesis"] as Any? ?? NSNull(),
        "testedModePairs": evidence?["testedModePairs"] as Any? ?? NSNull(),
        "priorConfidence": hypothesis["confidence"] as Any? ?? NSNull(), "spentPixels": initialBudget - budget,
        "endpointEvidence": endpoints as Any? ?? NSNull(), "sourceWidth": "unknown; no width accuracy claim",
        "displayCorrection": "not invoked; unrelated to source-color ground truth"]
    // Non-finite hypotheses are deliberately tested; avoid invalid JSON numbers.
    var safe = detail
    safe["priorConfidence"] = String(describing: hypothesis["confidence"] ?? "missing")
    report(name ?? f.name, problems, safe)
}

let white = [253.0, 254, 251], blue = [20.0, 45, 100], grey = [172.0, 181, 190]
let orange = [225.0, 90, 3], mint = [227.0, 241, 236]
let palettes: [(String, [Double], [Double])] = [("blue-grey172", blue, grey), ("orange-mint", orange, mint)]
let confidences: [(Double, Double)] = [(0.429, 0.167), (0, 0), (0.1, 0.49), (0.599, 0.499)]
let started = ProcessInfo.processInfo.systemUptime
for (palette, stroke, background) in palettes {
    for shape in ["H", "stem"] {
        let f = fixture(palette + "-" + shape, fill: white, stroke: stroke, background: background, shape: shape)
        for (fgc, bgc) in confidences {
            run(f, name: f.name + "-prior-\(fgc)-\(bgc)",
                hypothesis: prior(f, foregroundConfidence: fgc, backgroundConfidence: bgc), shouldAccept: true)
        }
    }
}

let control = fixture("blue-grey172-H", fill: white, stroke: blue, background: grey)
let goodPrior = prior(control, foregroundConfidence: 0.429, backgroundConfidence: 0.167)
// Diagnostic upstream estimate uses production too, but has no forced prior-accuracy assertion.
let initial = Sampler.estimate(rgba: control.rgba, width: width, height: height, ownership: control.ownership)
print("BASELINE estimate FG=\(String(describing: initial?["foreground"])) stroke=\(String(describing: initial?["stroke"])) BG=\(String(describing: initial?["background"]))")

for shape in ["H", "stem"] {
    let f = fixture("black-FG-white-outline-" + shape, fill: [0, 0, 0], stroke: white, background: grey, shape: shape)
    run(f, hypothesis: prior(f, foregroundConfidence: 0.1, backgroundConfidence: 0.1, blackForeground: true), shouldAccept: false)
}
for (palette, stroke, background) in palettes {
    for shape in ["island", "blob"] {
        let f = fixture(palette + "-pale-counter-or-photo-" + shape,
            fill: white, stroke: stroke, background: background, shape: shape)
        run(f, hypothesis: prior(f, foregroundConfidence: 0.1, backgroundConfidence: 0.1), shouldAccept: false)
    }
}
let mixed = fixture("no-direct-stroke-endpoint-AA-only", fill: white, stroke: blue, background: grey, mixedStroke: true)
// A public unchanged-pair certificate exposes ray support independently of
// the retry gate. This fixture must reach accepted rays but lack endpoints;
// otherwise merely observing nil from retry would not test the new gate.
var certificatePrior = goodPrior
certificatePrior["foreground"] = white; certificatePrior["stroke"] = blue
certificatePrior["confidence"] = ["foreground": 0.8, "stroke": 0.8, "background": 0.167]
var certificateBudget = pixels
let certified = Sampler.certifyObservedColorPair(rgba: mixed.rgba, width: width, height: height,
    ownership: mixed.ownership, result: certificatePrior, observationBudget: &certificateBudget)
let rayEvidence = certified?["enclosingRoleEvidence"] as? Payload
let endpointEvidence = rayEvidence?["endpointEvidence"] as? Payload
let isolatedGate = rayEvidence?["accepted"] as? Bool == true
    && endpointEvidence?["accepted"] as? Bool == false && certificateBudget == 0
report("AA-only-has-rays-but-no-direct-stroke-endpoint",
    isolatedGate ? [] : ["fixture does not isolate endpoint gate"],
    ["rayEvidence": rayEvidence as Any? ?? NSNull(), "sourceWidth": "unknown", "displayCorrection": "not invoked"])
run(mixed, hypothesis: goodPrior, shouldAccept: false)
run(control, name: "no-owned-pixels", hypothesis: goodPrior, shouldAccept: false,
    ownership: [UInt8](repeating: 0, count: pixels))
var clipped = control.ownership
for i in 0..<pixels where control.rgba[i * 4] < 240 { clipped[i] = 0 }
run(control, name: "fill-only-clipped-ownership", hypothesis: goodPrior, shouldAccept: false, ownership: clipped)
var half = control.ownership
for y in 0..<height { for x in 0..<width where x < 106 { half[y * width + x] = 0 } }
run(control, name: "one-glyph-only-clipped-ownership", hypothesis: goodPrior, shouldAccept: false, ownership: half)
run(control, name: "budget-zero", hypothesis: goodPrior, shouldAccept: false,
    budget: 0, expectedCharge: 0, expectedBlocked: 1)
run(control, name: "budget-one-pixel-short", hypothesis: goodPrior, shouldAccept: false,
    budget: pixels - 1, expectedCharge: 0, expectedBlocked: 1)
run(control, name: "budget-exact", hypothesis: goodPrior, shouldAccept: true)
for (name, value) in [("nan", Double.nan), ("infinity", Double.infinity)] {
    var invalid = goodPrior
    invalid["confidence"] = ["foreground": value, "background": 0.167]
    run(control, name: "nonfinite-prior-" + name, hypothesis: invalid, shouldAccept: false, expectedCharge: 0)
}
// Numeric-only ingress must reject absent/string confidence, not coerce it to zero.
for role in ["foreground", "background"] {
    for name in ["missing", "string"] {
        var invalid = goodPrior
        var confidence: Payload = ["foreground": 0.429, "background": 0.167]
        if name == "missing" { confidence.removeValue(forKey: role) }
        else { confidence[role] = "not-a-number" }
        invalid["confidence"] = confidence
        run(control, name: "nonnumeric-prior-" + role + "-" + name,
            hypothesis: invalid, shouldAccept: false, expectedCharge: 0)
    }
}
// The empty async stream prevents entry before the main thread cancels the task.
let gate = AsyncStream<Void>.makeStream()
let cancelled = Task.detached {
    for await _ in gate.stream { break }
    var budget = pixels, blocked = 0
    let result = Sampler.enclosingPaleRoleRetry(rgba: control.rgba, width: width, height: height,
        ownership: control.ownership,
        result: prior(control, foregroundConfidence: 0.429, backgroundConfidence: 0.167),
        observationBudget: &budget, onBudgetBlocked: { blocked += 1 })
    let ok = Task.isCancelled && result == nil && budget == pixels && blocked == 0
    return ok
}
cancelled.cancel(); gate.continuation.finish()
let cancellationGroup = DispatchGroup()
cancellationGroup.enter()
Task.detached {
    let ok = await cancelled.value
    report("pre-cancelled-task", ok ? [] : ["cancellation did not abstain without spending"],
        ["sourceWidth": "unknown", "displayCorrection": "not invoked"])
    cancellationGroup.leave()
}
cancellationGroup.wait()

// Display selection preserves predicted roles; final readability correction is
// a separate policy and is deliberately not invoked by these exact checks.
func displayCase(_ name: String, payload: Payload?, expected: [Double]?) {
    let observed = Sampler.observedDisplayInk(payload)
    let displayed = Sampler.displayedInk(payload)
    var problems: [String] = []
    if observed != expected { problems.append("observedDisplayInk reassigned predicted foreground or wrong fallback") }
    if displayed != expected { problems.append("displayedInk reassigned predicted foreground or wrong fallback") }
    report(name, problems, ["expectedFG": expected as Any? ?? NSNull(),
        "observedDisplayInk": observed as Any? ?? NSNull(), "displayedInk": displayed as Any? ?? NSNull(),
        "sourceWidth": "unknown; no width accuracy claim", "displayCorrection": "not invoked"])
}
for strokeConfidence in [0.55, 0.7, 1.0] {
    displayCase("display-white-orange-mint-stale-orange-confidence-\(strokeConfidence)", payload:
        ["foreground": white, "stroke": orange, "background": mint,
         "displayEvidence": ["color": orange], "lettering": ["color": orange], "displayForeground": orange,
         "confidence": ["foreground": 0.429, "stroke": strokeConfidence]], expected: white)
}
displayCase("display-dark-FG-white-stroke-stale-white", payload:
    ["foreground": blue, "stroke": white, "background": mint,
     "displayEvidence": ["color": white], "lettering": ["color": white], "displayForeground": white,
     "confidence": ["foreground": 0.95, "stroke": 1.0]], expected: blue)
displayCase("display-white-FG-without-fallback", payload:
    ["foreground": white, "stroke": orange, "background": mint,
     "confidence": ["foreground": 0.95, "stroke": 1.0]], expected: white)
displayCase("display-missing-FG-evidence-priority", payload:
    ["stroke": white, "background": mint, "displayEvidence": ["color": orange],
     "lettering": ["color": blue], "displayForeground": white], expected: orange)
displayCase("display-null-FG-lettering-fallback", payload:
    ["foreground": NSNull(), "displayEvidence": ["color": NSNull()],
     "lettering": ["color": blue], "displayForeground": white], expected: blue)
displayCase("display-missing-FG-displayForeground-fallback", payload:
    ["displayEvidence": ["color": [Double.nan, 0, 0]], "lettering": ["color": [12, 34]],
     "displayForeground": white], expected: white)
displayCase("display-missing-FG-no-inferred-stroke-or-BG", payload:
    ["stroke": orange, "background": mint, "confidence": ["stroke": 1.0]], expected: nil)
displayCase("display-missing-FG-invalid-fallbacks", payload:
    ["displayEvidence": ["color": [300, 0, 0]], "lettering": ["color": "invalid"],
     "displayForeground": [0, 0]], expected: nil)
displayCase("display-nil-payload", payload: nil, expected: nil)

// Adversarial additions keep original assertions/fixtures intact. Distances
// below create authored bands, not a copy of production ray classification.
func authored(_ name: String, fill: [Double], stroke: [Double], background: [Double],
              mask: [Bool], aa: Bool = false, thirdColor: [Double]? = nil) -> Fixture {
    var f = fixture(name, fill: fill, stroke: stroke, background: background)
    for y in 0..<height {
        for x in 0..<width {
            let i = y * width + x
            var nearestFill = 4, nearestOutside = 4
            for dy in -3...3 {
                for dx in -3...3 {
                    let xx = x + dx, yy = y + dy
                    if xx >= 0 && xx < width && yy >= 0 && yy < height {
                        let distance = max(abs(dx), abs(dy))
                        if mask[yy * width + xx] { nearestFill = min(nearestFill, distance) }
                        else { nearestOutside = min(nearestOutside, distance) }
                    }
                }
            }
            var color = background
            if mask[i] {
                color = aa && nearestOutside == 1 ? zip(fill, stroke).map { ($0 + $1) / 2 } : fill
            } else if nearestFill <= 2 { color = stroke }
            else if nearestFill == 3 {
                if let thirdColor { color = thirdColor }
                else if aa { color = zip(background, stroke).map { ($0 + $1) / 2 } }
            }
            for c in 0..<3 { f.rgba[i * 4 + c] = UInt8(color[c].rounded()) }
        }
    }
    return f
}
func glyphMask(_ shape: String) -> [Bool] {
    var mask = [Bool](repeating: false, count: pixels)
    let origins = shape == "reentry" ? [18, 25, 56, 63, 94, 101] : [10, 40, 70, 100]
    let glyphWidth = shape == "grid" ? 24 : 18
    for origin in origins {
        for y in 24..<56 {
            for x in origin..<min(width, origin + glyphWidth) {
                let xx = x - origin, yy = y - 24
                switch shape {
                case "reentry": mask[y * width + x] = xx < 3
                case "grid": mask[y * width + x] = xx < 5 || xx >= 19
                    || yy < 5 || (yy >= 13 && yy < 18) || yy >= 27
                case "counter": mask[y * width + x] = xx < 12
                    && !(xx >= 4 && xx < 8 && yy >= 4 && yy < 28)
                default: mask[y * width + x] = xx < 5 || xx >= 13 || (yy >= 13 && yy < 18)
                }
            }
        }
    }
    return mask
}
for background in [grey, mint] {
    var f = authored("narrow-closed-counter-black-white-\(Int(background[0]))",
        fill: [0, 0, 0], stroke: white, background: background, mask: glyphMask("counter"))
    // The actual narrow counter is local pale background, equal to the outer
    // white outline: counter -> black ink -> white outline -> exterior BG.
    for origin in [10, 40, 70, 100] {
        for y in 28..<52 { for x in (origin + 4)..<(origin + 8) {
            for c in 0..<3 { f.rgba[(y * width + x) * 4 + c] = UInt8(white[c]) }
        } }
    }
    run(f, hypothesis: prior(f, foregroundConfidence: 0.1, backgroundConfidence: 0.1, blackForeground: true),
        shouldAccept: false)
}
for (palette, edge, background) in palettes {
    let f = authored("multi-white-glyph-reentry-" + palette, fill: white, stroke: edge,
        background: background, mask: glyphMask("reentry"))
    run(f, hypothesis: prior(f, foregroundConfidence: 0.429, backgroundConfidence: 0.167), shouldAccept: true)
    for shape in ["H", "grid"] {
        let aa = authored("both-side-AA-" + palette + "-" + shape, fill: white, stroke: edge,
            background: background, mask: glyphMask(shape), aa: true)
        run(aa, hypothesis: prior(aa, foregroundConfidence: 0.429, backgroundConfidence: 0.167), shouldAccept: true)
        let unknown = authored("unknown-third-color-after-edge-" + palette + "-" + shape,
            fill: white, stroke: edge, background: background, mask: glyphMask(shape),
            thirdColor: [255, 0, 200])
        run(unknown, hypothesis: prior(unknown, foregroundConfidence: 0.429, backgroundConfidence: 0.167), shouldAccept: false)
    }
}
// Exact production fileprivate classifier is callable in this same-file leaf.
// No access modifiers or implementation are changed to expose it.
let overlapBackground = zip(white, orange).map { ($0 + $1) / 2 }
for (name, fill, edge, background, value) in [
    ("BG-on-fill-edge-AA-segment", white, orange, overlapBackground, overlapBackground),
    ("near-BG-on-fill-edge-AA-segment", white, orange, overlapBackground, overlapBackground.map { $0 + 2 }),
    ("near-BG-also-BG-edge-AA", white, [100.0, 140, 180], [160.0, 184, 208], [151.0, 177.4, 203.8])
] {
    let axis = zip(edge, background).map(-), length = axis.map { $0 * $0 }.reduce(0, +)
    let classification = Sampler.certificatePixelClass(value, fill: fill, edge: edge,
        background: background, edgeAxis: axis, edgeLength: length)
    report(name, classification == 3 ? [] : ["direct BG incorrectly classified as AA edge: \(classification)"],
        ["pixel": value, "trueBG": background, "classification": Int(classification), "expectedClass": 3])
}
func distractors(_ base: Fixture, count: Int) -> Fixture {
    var f = base
    // Dense pale photograph/background regions all exceed true glyph-fill mode
    // area, but have neither narrow stems nor porous interior structure.
    let regions = [(8, 20), (62, 73), (73, 84), (8, 20)]
    let shades = [200.0, 216, 232, 187]
    for n in 0..<count {
        let (top, bottom) = regions[n]
        for y in top..<bottom { for x in 8..<120 {
            // The fourth distinct mode replaces the right half of the first;
            // use narrow-stem foreground for a meaningful fifth-mode fixture.
            if count == 4 && n == 0 && x >= 64 { continue }
            if n == 3 && x < 64 { continue }
            for c in 0..<3 { f.rgba[(y * width + x) * 4 + c] = UInt8(shades[n]) }
        } }
    }
    return f
}
let stemBase = fixture("frontier", fill: white, stroke: blue, background: grey, shape: "stem")
for count in [1, 3, 4] {
    let f = distractors(stemBase, count: count)
    if count == 4 {
        var exactCounts: [[UInt8]: Int] = [:]
        for i in 0..<pixels where f.ownership[i] != 0 {
            let color = Array(f.rgba[(i * 4)..<(i * 4 + 3)])
            exactCounts[color, default: 0] += 1
        }
        let truthCount = exactCounts[white.map { UInt8($0) }] ?? 0
        let dominating = [200, 216, 232, 187].filter {
            (exactCounts[[UInt8($0), UInt8($0), UInt8($0)]] ?? 0) > truthCount
        }.count
        report("four-distinct-pale-distractors-really-dominate-white",
            dominating == 4 ? [] : ["frontier fixture does not put true fill fifth"],
            ["trueFillPixels": truthCount, "largerDistinctPaleModes": dominating])
    }
    run(f, name: "dominant-pale-distractors-\(count)-true-fill-rank-\(count + 1)",
        hypothesis: prior(f, foregroundConfidence: 0.429, backgroundConfidence: 0.167), shouldAccept: count < 4)
}
// A smooth oval pale photo highlight specifically dominates the true mode.
var photo = stemBase
for y in 62..<84 { for x in 8..<120 {
    let dx = (Double(x) - 64) / 50, dy = (Double(y) - 73) / 10
    if dx * dx + dy * dy < 1 {
        for c in 0..<3 { photo.rgba[(y * width + x) * 4 + c] = 216 }
    }
} }
run(photo, name: "dominant-pale-oval-photo-with-real-white-stems",
    hypothesis: prior(photo, foregroundConfidence: 0.429, backgroundConfidence: 0.167), shouldAccept: true)
for (palette, edge, background) in palettes {
    let f = fixture("wrong-BG-" + palette, fill: white, stroke: edge, background: background)
    for offset in [-64.0, -32, 32, 64] {
        let supplied = background.map { max(0, min(255, $0 + offset)) }
        var hypothesis = prior(f, foregroundConfidence: 0.429, backgroundConfidence: 0.167)
        hypothesis["background"] = supplied
        // Authored pixels retain actual BG. Retry may use a rim hypothesis to
        // validate roles, but must preserve the separately supplied BG value.
        run(f, name: f.name + "-offset-\(offset)", hypothesis: hypothesis, shouldAccept: true,
            expectedBackground: supplied)
    }
}
for role in ["foreground", "background"] {
    for (label, value) in [("boolean-true", NSNumber(value: true)), ("boolean-false", NSNumber(value: false)),
                           ("negative", NSNumber(value: -0.01)), ("above-one", NSNumber(value: 1.01))] {
        var hypothesis = goodPrior
        var confidence: Payload = ["foreground": 0.429, "background": 0.167]
        confidence[role] = value; hypothesis["confidence"] = confidence
        run(control, name: "typed-prior-" + role + "-" + label,
            hypothesis: hypothesis, shouldAccept: false, expectedCharge: 0)
    }
}
// Authored roles isolate connected-mode and spatial-exterior failure causes.
let photoEdge = [51.0, 66, 101], photoBG = [182.0, 172, 186]
let connectedControl = fixture("white-mode-component-control", fill: white, stroke: photoEdge, background: photoBG)
let connectedPrior = prior(connectedControl, foregroundConfidence: 0.42905405405405406,
    backgroundConfidence: 0.16748366013071894)
run(connectedControl, hypothesis: connectedPrior, shouldAccept: true)
var remoteExtreme = connectedControl
// A more extreme owned dark mode exists, but never touches white lettering.
// Global endpoint plateaus alone must not nominate it as the text's stroke.
for y in 64..<80 { for x in 14..<114 {
    for c in 0..<3 { remoteExtreme.rgba[(y * width + x) * 4 + c] = UInt8([38,55,92][c]) }
} }
run(remoteExtreme, name: "remote-owned-dark-extreme-is-not-lettering-stroke",
    hypothesis: connectedPrior, shouldAccept: true)
var connected = connectedControl
// Same-color thin decoration joins real white H glyphs to ownership boundary;
// existing glyph pixels/colors stay intact. This is observer contamination.
for x in 18..<114 {
    for c in 0..<3 { connected.rgba[(10 * width + x) * 4 + c] = UInt8(white[c]) }
}
for x in [18, 44, 70, 96] {
    for y in 8..<26 {
        for c in 0..<3 { connected.rgba[(y * width + x) * 4 + c] = UInt8(white[c]) }
    }
}
run(connected, name: "owned-white-glyphs-joined-to-clipped-color-decoration",
    hypothesis: connectedPrior, shouldAccept: true)
var textured = connectedControl
for y in 0..<height { for x in 0..<width {
    let i = (y * width + x) * 4
    if (0..<3).allSatisfy({ textured.rgba[i + $0] == UInt8(photoBG[$0]) }) {
        let quadrant = (x < 64 ? 0 : 1) + (y < 48 ? 0 : 2)
        let offset = [-24.0, 0, 24, 48][quadrant]
        for c in 0..<3 { textured.rgba[i + c] = UInt8(photoBG[c] + offset) }
    }
} }
textured.backgroundVariants = [-24.0, 0, 24, 48].map { offset in photoBG.map { $0 + offset } }
run(textured, name: "white-fill-dark-stroke-on-spatially-varying-exterior",
    hypothesis: connectedPrior, shouldAccept: true)
var twoMasks = glyphMask("H")
for y in 0..<height { for x in 40..<94 { twoMasks[y * width + x] = false } }
var twoExteriors = authored("two-independent-source-exteriors", fill: white, stroke: photoEdge,
    background: photoBG, mask: twoMasks)
let localBackgrounds = [[100.0, 50, 180], [220.0, 230, 170]]
for y in 0..<height { for x in 0..<width {
    let i = (y * width + x) * 4
    if (0..<3).allSatisfy({ twoExteriors.rgba[i + $0] == UInt8(photoBG[$0]) }) {
        for c in 0..<3 { twoExteriors.rgba[i + c] = UInt8(localBackgrounds[x < 64 ? 0 : 1][c]) }
    }
} }
twoExteriors.backgroundVariants = localBackgrounds
run(twoExteriors, hypothesis: connectedPrior, shouldAccept: true, requiresSpatialExterior: true)

extension NativeSourceColorSampler {
    // Analysis prototype ONLY, not a production certificate/accuracy oracle.
    // Retain structural shape restrictions, sample fully owned interior points
    // instead of vetoing a whole connected mode for a few clipped points, and
    // demand support in two independent 32px spatial cells. <=65,536 ray steps.
    static func diagnosticInteriorRays(_ rgba: [UInt8], _ width: Int, _ height: Int,
        _ ownership: [UInt8], _ fill: [Double], _ edge: [Double], _ bg: [Double],
        region: [Int]? = nil) -> Payload {
        let observation = Observation(rgba: rgba, width: width, height: height)!
        let estimator = Estimator(rgba: rgba, width: width, height: height, observation: observation, ownership: ownership)
        let mask = ownership.indices.map { ownership[$0] != 0 && distance(estimator.color($0), fill) <= 12 ? UInt8(1) : 0 }
        var points: [Int] = []
        for c in estimator.components(mask) where !c.boundary && c.height >= 5 && c.points.count >= 6
            && (fill.min()! < 175 || c.width * 5 <= c.height * 2 || Double(c.points.count) <= Double(c.area) * 0.65) {
            points += c.points.filter { i in
                ownership[i - 1] != 0 && ownership[i + 1] != 0
                    && ownership[i - width] != 0 && ownership[i + width] != 0
            }
        }
        let stride = max(1, Int(ceil(Double(points.count) / 512)))
        if let region {
            points = points.filter { $0 % width >= region[0] && $0 % width < region[2]
                && $0 / width >= region[1] && $0 / width < region[3] }
        }
        let directions = [(1,0),(-1,0),(0,1),(0,-1),(1,1),(1,-1),(-1,1),(-1,-1)]
        let axis = subtract(edge, bg), length = dot(axis, axis)
        var tested = 0, supported = 0, unknownStops = 0, directBG = 0, steps = 0
        var cells: [[Int]: (tested: Int, supported: Int)] = [:]
        if length > 0 {
            for offset in Swift.stride(from: 0, to: points.count, by: stride) {
                let i = points[offset], x = i % width, y = i / width
                var decisive = 0, enclosed = 0
                for (dx,dy) in directions {
                    var crossed = false
                    for step in 1...16 {
                        steps += 1
                        let xx = x + dx * step, yy = y + dy * step
                        if xx < 0 || yy < 0 || xx >= width || yy >= height { break }
                        let next = yy * width + xx
                        let label = certificatePixelClass(estimator.color(next), fill: fill, edge: edge,
                            background: bg, edgeAxis: axis, edgeLength: length)
                        if label == 1 {
                            crossed = false
                            if ownership[next] == 0 { decisive += 1; break }
                        } else if label == 2 {
                            if ownership[next] == 0 { decisive += 1; break }
                            crossed = true
                        } else if label == 3 {
                            decisive += 1
                            if crossed { enclosed += 1 } else { directBG += 1 }
                            break
                        } else if crossed { unknownStops += 1; break }
                    }
                }
                if decisive >= 4 {
                    let hit = Double(enclosed) >= Double(decisive) * 0.8
                    tested += 1; supported += hit ? 1 : 0
                    let cell = [x / 32, y / 32], old = cells[cell] ?? (0,0)
                    cells[cell] = (old.tested + 1, old.supported + (hit ? 1 : 0))
                }
            }
        }
        let agreeing = cells.values.filter { $0.tested >= 6 && Double($0.supported) >= Double($0.tested) * 0.7 }.count
        let fillEndpoint = endpointSupport(estimator: estimator, ownership: ownership, width: width, height: height,
            color: fill, background: bg)
        let edgeEndpoint = endpointSupport(estimator: estimator, ownership: ownership, width: width, height: height,
            color: edge, background: bg)
        func endpoint(_ e: Payload) -> Bool {
            number(e["pixels"]) >= 6 && (number(e["owned2x2Plateaus"]) >= 2 || number(e["cubeCornerPixels"]) >= 6
                || (e["rgbCubeRange"] as? NSNumber).map { $0.doubleValue >= 0 && $0.doubleValue <= 24 } == true)
        }
        return ["accepted": tested >= 12 && Double(supported) >= Double(tested) * 0.7 && agreeing >= 2
                    && endpoint(fillEndpoint) && endpoint(edgeEndpoint),
            "tested": tested, "supported": supported, "agreeingCells": agreeing,
            "fullyOwnedInteriorPoints": points.count, "unknownAfterEdge": unknownStops,
            "directBGWithoutEdge": directBG, "raySteps": steps,
            "authority": "test-only bounded interior-ray proposal; not production or ground truth"]
    }
}
for f in [connected, fixture("black-FG-white-outline-proposal-negative", fill: [0,0,0], stroke: white, background: photoBG),
          fixture("pale-photo-proposal-negative", fill: white, stroke: photoEdge, background: photoBG, shape: "blob")] {
    let expected = f.name == connected.name
    let evidence = Sampler.diagnosticInteriorRays(f.rgba, width, height, f.ownership,
        white, f.name == "black-FG-white-outline-proposal-negative" ? [0,0,0] : photoEdge, photoBG)
    var problems = evidence["accepted"] as? Bool == expected ? [] : ["test-only proposal disagrees with authored roles"]
    if Sampler.number(evidence["raySteps"]) > 65_536 { problems.append("prototype exceeded its independent ray budget") }
    report("interior-ray-proposal-" + (expected ? "clipped-connection-positive" : f.name), problems, evidence)
}
#if AIDOKU_SOURCE_ROLE_LOCAL_CANDIDATE
extension NativeSourceColorSampler {
    static func diagnosticLocalQuota(_ f: Fixture) -> [(String, Bool, Payload)] {
        let observation = Observation(rgba: f.rgba, width: width, height: height)!
        let estimator = Estimator(rgba: f.rgba, width: width, height: height,
            observation: observation, ownership: f.ownership)
        let mask = f.ownership.indices.map { f.ownership[$0] != 0
            && distance(estimator.color($0), f.fill) <= 12 ? 1 : 0 }
        let points = mask.indices.filter { i in
            mask[i] != 0 && i / width > 0 && i / width < height - 1 && i % width > 0 && i % width < width - 1
                && f.ownership[i - 1] != 0 && f.ownership[i + 1] != 0
                && f.ownership[i - width] != 0 && f.ownership[i + width] != 0
        }
        var rayWork = 1
        let rayResult = ownedInteriorCertificate(estimator: estimator, ownership: f.ownership,
            width: width, height: height, points: points, fill: f.fill, edge: f.stroke,
            background: f.background, remainingRayWork: &rayWork)
        var pairs = 31, spatialWork = 65_536
        let spatialResult = spatialExteriorCertificate(estimator: estimator, ownership: f.ownership,
            width: width, height: height, points: points, nearFill: estimator.nearOwners(mask, reach: 3).near,
            fill: f.fill, edge: f.stroke, background: f.background, remainingRayWork: &spatialWork,
            hypothesisPairs: &pairs, hypothesisLimit: 32)
        return [
            ("local-production-ray-quota-one", rayResult == nil && rayWork == 0,
             ["remaining": rayWork, "accepted": rayResult != nil]),
            ("local-production-hypothesis-quota-one", spatialResult == nil && pairs == 32 && spatialWork >= 0,
             ["pairs": pairs, "remainingRayWork": spatialWork, "accepted": spatialResult != nil])
        ]
    }
}
for (name, ok, evidence) in Sampler.diagnosticLocalQuota(connectedControl) {
    report(name, ok ? [] : ["production local observer exceeded its quota or accepted partial work"], evidence)
}
#endif
// Ordered source hypotheses are distinct from the pale role-swap tests above.
// Legitimate BlackFG/WhiteStroke must survive; its reversed-role proposal must not.
func orderedPrior(_ f: Fixture) -> Payload {
    ["foreground": f.fill, "stroke": NSNull(), "background": f.background,
     "sourceInk": ["foreground": f.fill, "stroke": f.stroke,
                   "confidence": ["foreground": 0.0, "stroke": 0.0]],
     "confidence": ["foreground": 0.0, "stroke": 0.0, "background": 0.0]]
}
func orderedCase(_ f: Fixture, accept: Bool, budget initial: Int = pixels, reverse: Bool = false) {
    var input = orderedPrior(f), budget = initial
    if reverse {
        input["foreground"] = f.stroke
        input["sourceInk"] = ["foreground": f.stroke, "stroke": f.fill]
    }
    let output = Sampler.certifySourceInkHypothesis(rgba: f.rgba, width: width, height: height,
        ownership: f.ownership, result: input, observationBudget: &budget)
    var errors = (output != nil) == accept ? [] : ["ordered hypothesis acceptance disagrees with authored geometry"]
    if let output {
        if Sampler.rgb(output["foreground"]) != f.fill || Sampler.rgb(output["stroke"]) != f.stroke {
            errors.append("observed ordered endpoints changed")
        }
        if Sampler.rgb(output["background"]) != f.background { errors.append("backing changed") }
        let evidence = output["enclosingRoleEvidence"] as! Payload
        if (evidence["endpointEvidence"] as? Payload)?["accepted"] as? Bool != true { errors.append("no direct endpoints") }
        if Sampler.number(evidence["totalRaySteps"]) > 262_144 || Sampler.number(evidence["candidateModesAttempted"]) > 32 {
            errors.append("candidate generation exceeded quota")
        }
        if !(output["widthEvidence"] is NSNull) { errors.append("source width extrapolated") }
    }
    report("ordered-" + f.name + (reverse ? "-reversed" : "") + "-budget-\(initial)", errors,
        ["accepted": output != nil, "estimatedFG": output?["foreground"] as Any? ?? NSNull(),
         "estimatedStroke": output?["stroke"] as Any? ?? NSNull(), "estimatedBG": f.background,
         "trueFG": f.fill, "trueStroke": f.stroke, "trueBG": f.background,
         "spent": initial - budget, "evidence": output?["enclosingRoleEvidence"] as Any? ?? NSNull()])
}
let orderedBlue = fixture("blue-white", fill: [51,66,101], stroke: white, background: photoBG)
let orderedOrange = fixture("white-orange-mint", fill: white, stroke: orange, background: mint)
let orderedBlack = fixture("black-white", fill: [0,0,0], stroke: white, background: photoBG)
for f in [orderedBlue, orderedOrange, orderedBlack] {
    orderedCase(f, accept: true)
    orderedCase(f, accept: false, reverse: true)
}
orderedCase(fixture("pale-photo", fill: white, stroke: photoEdge, background: photoBG, shape: "blob"), accept: false)
orderedCase(fixture("AA-only-endpoint", fill: white, stroke: orange, background: mint, mixedStroke: true), accept: false)
var thirdBand = orderedBlue
thirdBand = Fixture(name: "unknown-third-band", fill: thirdBand.fill, stroke: thirdBand.stroke,
    background: thirdBand.background, rgba: thirdBand.rgba, ownership: thirdBand.ownership)
for i in 0..<pixels where Sampler.distance((0..<3).map { Double(orderedBlue.rgba[i * 4 + $0]) }, orderedBlue.background) < 1 {
    let x = i % width, y = i / width
    let touches = [(-1,0),(1,0),(0,-1),(0,1)].contains { dx,dy in
        let xx = x + dx, yy = y + dy
        return xx >= 0 && yy >= 0 && xx < width && yy < height &&
            Sampler.distance((0..<3).map { Double(orderedBlue.rgba[(yy * width + xx) * 4 + $0]) }, white) < 1
    }
    if touches { for c in 0..<3 { thirdBand.rgba[i * 4 + c] = [210,35,120][c] } }
}
orderedCase(thirdBand, accept: false)
var missingEdge = orderedBlue
missingEdge = Fixture(name: "unowned-stroke-endpoints", fill: missingEdge.fill, stroke: missingEdge.stroke,
    background: missingEdge.background, rgba: missingEdge.rgba, ownership: missingEdge.ownership)
for i in 0..<pixels where Sampler.distance((0..<3).map { Double(missingEdge.rgba[i * 4 + $0]) }, white) <= 12 {
    missingEdge.ownership[i] = 0
}
orderedCase(missingEdge, accept: false)
var unownedPair = orderedBlue
unownedPair.ownership = [UInt8](repeating: 0, count: pixels)
orderedCase(unownedPair, accept: false)
orderedCase(orderedBlue, accept: false, budget: 0)
orderedCase(orderedBlue, accept: false, budget: pixels - 1)
let orderedGate = AsyncStream<Void>.makeStream()
let orderedCancelled = Task.detached {
    for await _ in orderedGate.stream { break }
    var budget = pixels
    let output = Sampler.certifySourceInkHypothesis(rgba: orderedBlue.rgba, width: width, height: height,
        ownership: orderedBlue.ownership, result: orderedPrior(orderedBlue), observationBudget: &budget)
    return Task.isCancelled && output == nil && budget == pixels
}
orderedCancelled.cancel(); orderedGate.continuation.finish()
let orderedGroup = DispatchGroup(); orderedGroup.enter()
Task.detached {
    let ok = await orderedCancelled.value
    report("ordered-cancelled", ok ? [] : ["cancelled recertifier consumed budget or accepted"], [:])
    orderedGroup.leave()
}
orderedGroup.wait()
// A forecast is a separate uncertainty record; never weaken certificate tests.
func forecastInput(_ f: Fixture) -> Payload {
    var input = orderedPrior(f)
    var raw = input["sourceInk"] as! Payload
    raw["confidence"] = ["foreground": 0.429, "stroke": 0.9]
    raw["widthEvidence"] = ["samplePixels": 1.5, "glyphPixels": 30.0, "relativeToGlyph": 0.05,
        "method": "outer stroke boundary distance to validated ink; external Manhattan band"]
    input["sourceInk"] = raw
    return input
}
func forecastCase(_ f: Fixture, _ name: String, accept: Bool, input: Payload? = nil, abstained: Bool = true) {
    let before = input ?? forecastInput(f)
    let frozen = try! JSONSerialization.data(withJSONObject: before, options: [.sortedKeys])
    let output = Sampler.supportedOriginalStrokeForecast(rgba: f.rgba, width: width, height: height,
        ownership: f.ownership, result: before, independentObserverAbstained: abstained)
    var errors = (output != nil) == accept ? [] : ["forecast retention disagrees with authored source roles"]
    if frozen != (try! JSONSerialization.data(withJSONObject: before, options: [.sortedKeys])) {
        errors.append("input source roles mutated")
    }
    if let output {
        if Sampler.rgb(output["color"]) != f.stroke { errors.append("source stroke RGB changed") }
        if output["certified"] as? Bool != false || output["uncalibrated"] as? Bool != true {
            errors.append("forecast uncertainty not explicit")
        }
        if output["foreground"] != nil || output["stroke"] != nil || output["enclosingRoleEvidence"] != nil {
            errors.append("forecast was exported as verified style or enclosure")
        }
        if Sampler.number(output["supportedGlyphs"]) < 2 || Sampler.number(output["supportedStrokePixels"]) < 6 {
            errors.append("fresh owned band counts absent")
        }
        if output["sourceWidthCalibrated"] as? Bool != false { errors.append("source width accuracy claimed") }
    }
    report("raw-stroke-forecast-" + name, errors, output ?? ["retained": false])
}
for f in [orderedBlue, orderedOrange, orderedBlack] { forecastCase(f, f.name, accept: true) }
forecastCase(fixture("pale-photo", fill: white, stroke: photoEdge, background: photoBG, shape: "blob"), "pale-photo", accept: false)
forecastCase(fixture("black-on-white-paper", fill: [0,0,0], stroke: white, background: white), "black-on-white-paper", accept: false)
forecastCase(fixture("AA-only", fill: white, stroke: orange, background: mint, mixedStroke: true), "AA-only", accept: false)
forecastCase(missingEdge, "unowned-endpoints", accept: false)
forecastCase(unownedPair, "clipped-all-ownership", accept: false)
forecastCase(orderedBlue, "independent-observer-did-not-abstain", accept: false, abstained: false)
for key in ["method", "relativeToGlyph", "glyphPixels", "samplePixels"] {
    var input = forecastInput(orderedBlue), raw = input["sourceInk"] as! Payload
    var width = raw["widthEvidence"] as! Payload; width.removeValue(forKey: key)
    raw["widthEvidence"] = width; input["sourceInk"] = raw
    forecastCase(orderedBlue, "missing-" + key, accept: false, input: input)
}
for (name, value) in [("too-wide", 0.31), ("boolean", true as Any), ("nonfinite", Double.infinity as Any)] {
    var input = forecastInput(orderedBlue), raw = input["sourceInk"] as! Payload
    var band = raw["widthEvidence"] as! Payload; band["relativeToGlyph"] = value
    raw["widthEvidence"] = band; input["sourceInk"] = raw
    // Nonfinite inputs cannot be serialized for the immutability assertion.
    if name == "nonfinite" {
        let output = Sampler.supportedOriginalStrokeForecast(rgba: orderedBlue.rgba, width: width, height: height,
            ownership: orderedBlue.ownership, result: input, independentObserverAbstained: true)
        report("raw-stroke-forecast-nonfinite", output == nil ? [] : ["nonfinite ratio accepted"], [:])
    } else { forecastCase(orderedBlue, name, accept: false, input: input) }
}
var mismatchedForecast = forecastInput(orderedBlue)
mismatchedForecast["foreground"] = white
forecastCase(orderedBlue, "final-fill-mismatch", accept: false, input: mismatchedForecast)
let paperWithWrongBG = fixture("white-paper-wrong-BG", fill: [0,0,0], stroke: white, background: white)
var wrongPaperInput = forecastInput(paperWithWrongBG)
wrongPaperInput["background"] = photoBG
forecastCase(paperWithWrongBG, "white-paper-with-forged-band-and-wrong-BG", accept: false, input: wrongPaperInput)
for name in ["unknown-method", "boolean-confidence", "low-confidence", "existing-stroke", "existing-certificate", "unbounded-glyph"] {
    var input = forecastInput(orderedBlue), raw = input["sourceInk"] as! Payload
    var band = raw["widthEvidence"] as! Payload
    switch name {
    case "unknown-method": band["method"] = "unverified arbitrary exterior color"
    case "boolean-confidence": raw["confidence"] = ["stroke": true]
    case "low-confidence": raw["confidence"] = ["stroke": 0.79]
    case "existing-stroke": input["stroke"] = orderedBlue.stroke
    case "existing-certificate": input["enclosingRoleEvidence"] = ["accepted": true]
    default: band["glyphPixels"] = 1e100; band["samplePixels"] = 5e98
    }
    raw["widthEvidence"] = band; input["sourceInk"] = raw
    forecastCase(orderedBlue, name, accept: false, input: input)
}
let forecastGate = AsyncStream<Void>.makeStream()
let forecastCancelled = Task.detached {
    for await _ in forecastGate.stream { break }
    return Sampler.supportedOriginalStrokeForecast(rgba: orderedBlue.rgba, width: width, height: height,
        ownership: orderedBlue.ownership, result: forecastInput(orderedBlue), independentObserverAbstained: true) == nil
}
forecastCancelled.cancel(); forecastGate.continuation.finish()
let forecastGroup = DispatchGroup(); forecastGroup.enter()
Task.detached {
    let ok = await forecastCancelled.value
    report("raw-stroke-forecast-cancelled", ok ? [] : ["cancelled forecast retained"], [:])
    forecastGroup.leave()
}
forecastGroup.wait()
print("SUMMARY PASS=\(passed) FAIL=\(failed) bodySeconds=\(ProcessInfo.processInfo.systemUptime - started)")
'''

REAL_HARNESS = r'''
// Optional exact-source leaf replay; no renderer, OCR, or remote provider.
'''

ORACLE_HARNESS = r'''
extension NativeSourceColorSampler {
    static func diagnosticOrderedEndpoints(_ bytes: [UInt8], _ width: Int, _ height: Int,
        _ ownership: [UInt8], _ result: Payload) -> Payload {
        let hypothesis = result["sourceInk"] as! Payload
        let observation = Observation(rgba: bytes, width: width, height: height)!
        let estimator = Estimator(rgba: bytes, width: width, height: height, observation: observation, ownership: ownership)
        let bg = rgb(result["background"])!
        return ["fill": endpointSupport(estimator: estimator, ownership: ownership, width: width,
            height: height, color: rgb(hypothesis["foreground"])!, background: bg),
            "stroke": endpointSupport(estimator: estimator, ownership: ownership, width: width,
            height: height, color: rgb(hypothesis["stroke"])!, background: bg),
            "authority": "observed ordered endpoint presence only; not enclosure proof"]
    }
}
func observedOracleErrors(_ name: String, _ final: Payload?) throws -> [String] {
    guard let path = ProcessInfo.processInfo.environment["AIDOKU_ROLE_PIXEL_ORACLE"] else { return [] }
    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! Payload
    guard let expected = (manifest["expectedPairs"] as? Payload)?[name] as? Payload else {
        return ["explicit observed-role oracle absent: " + name]
    }
    let tolerance = (manifest["tolerance"] as! NSNumber).doubleValue
    return ["foreground", "stroke", "background"].compactMap { role in
        error(Sampler.rgb(final?[role]), Sampler.rgb(expected[role])!) <= tolerance ? nil : "observed original ordered " + role + " mismatch"
    }
}
'''

REAL_HARNESS += r'''
// Optional exact-source leaf replay; no renderer, OCR, or remote provider.
final class RecordingReader: NativeSourcePixelReading {
    struct Capture {
        let x: Double, y: Double, sw: Double, sh: Double
        let width: Int, height: Int
        let rgba: [UInt8]
    }
    let reader: NativeSourcePixelReader
    var captures: [Capture] = []
    init(_ image: CGImage) { reader = NativeSourcePixelReader(image: image, preservesSamplingGeometry: true) }
    func read(x: Double, y: Double, sourceWidth: Double, sourceHeight: Double,
              width: Int, height: Int) throws -> [UInt8] {
        let rgba = try reader.read(x: x, y: y, sourceWidth: sourceWidth, sourceHeight: sourceHeight, width: width, height: height)
        captures.append(.init(x: x, y: y, sw: sourceWidth, sh: sourceHeight, width: width, height: height, rgba: rgba))
        return rgba
    }
}
extension NativeSourceColorSampler {
    // Same-file extension invokes the unchanged private certificate for analysis;
    // this is not a replacement implementation or a production visibility edit.
    static func diagnosticCertificate(_ rgba: [UInt8], _ width: Int, _ height: Int,
                                      _ ownership: [UInt8], _ fill: [Double], _ edge: [Double], _ bg: [Double]) -> Payload? {
        guard let observation = Observation(rgba: rgba, width: width, height: height) else { return nil }
        return enclosingCertificate(estimator: Estimator(rgba: rgba, width: width, height: height,
            observation: observation, ownership: ownership), ownership: ownership, width: width, height: height,
            fill: fill, edge: edge, background: bg, requiresInteriorStructure: fill.min()! >= 175)
    }
}
func cleanJSON(_ value: Any) -> Any {
    if let object = value as? [String: Any] { return object.mapValues(cleanJSON) }
    if let rows = value as? [Any] { return rows.map(cleanJSON) }
    if let number = value as? NSNumber, !number.doubleValue.isFinite { return NSNull() }
    return value
}
func saveROI(_ capture: RecordingReader.Capture, to path: String) {
    let provider = CGDataProvider(data: Data(capture.rgba) as CFData)!
    let image = CGImage(width: capture.width, height: capture.height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: capture.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    if !CGImageDestinationFinalize(destination) { fatalError("ROI output failed") }
}
func replay(_ input: String, _ layoutPath: String, _ identifier: String) throws {
    let url = URL(fileURLWithPath: input)
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    let layout = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: layoutPath))) as! Payload
    let items = layout["items"] as! [Payload]
    var bounds = items.map { $0["sourceBounds"] as! [Double] }
    // Preserve renderer owner normalization/ULP contacts. Reading the input's
    // normalized sourceBounds directly can move floor/ceil by one source pixel.
    let diagnosticsURL = URL(fileURLWithPath: layoutPath).deletingLastPathComponent()
        .appendingPathComponent("001-native-render-diagnostics.json")
    let diagnostics = try JSONSerialization.jsonObject(with: Data(contentsOf: diagnosticsURL)) as! Payload
    let cards = (diagnostics["value"] as! Payload)["cards"] as! [Payload]
    let encodedFrame = layout["sourceRect"] as! [[Double]]
    let frame = encodedFrame.flatMap { $0 }
    for index in items.indices {
        if let card = cards.first(where: { $0["id"] as? String == items[index]["id"] as? String }),
           let owner = card["sourceOwner"] as? [Double] {
            bounds[index] = [(owner[0] - frame[0]) / frame[2], (owner[1] - frame[1]) / frame[3],
                             owner[2] / frame[2], owner[3] / frame[3]]
        }
    }
    func polygon(_ b: [Double]) -> [[Double]] {
        [[b[0], b[1]], [b[0] + b[2], b[1]], [b[0] + b[2], b[1] + b[3]], [b[0], b[1] + b[3]]]
    }
    let recording = RecordingReader(image)
    let stage = NativeSourceColorSamplingStage(image: image, enabled: true, phase: "translation",
        budget: .init(remainingSamples: items.count), pixelReader: recording)
    for index in items.indices {
        let id = items[index]["id"] as! String
        let geometry: Payload = ["polygon": polygon(bounds[index]),
            "excluded": bounds.indices.filter { $0 != index }.map { polygon(bounds[$0]) }]
        recording.captures = []
        let result = stage.sampleOriginalStyle(bounds: bounds[index], geometry: geometry)
        guard id == identifier, let capture = recording.captures.first else { continue }
        func local(_ p: [[Double]]) -> [[Double]] {
            p.map { [($0[0] * Double(image.width) - capture.x) * Double(capture.width) / capture.sw,
                     ($0[1] * Double(image.height) - capture.y) * Double(capture.height) / capture.sh] }
        }
        let ownership = NativeSourceColorSamplingStage.geometryMask(width: capture.width, height: capture.height,
            polygons: [local(polygon(bounds[index]))],
            excluded: bounds.indices.filter { $0 != index }.map { local(polygon(bounds[$0])) }, margin: 1)!
        let observation = Sampler.Observation(rgba: capture.rgba, width: capture.width, height: capture.height)!
        let estimator = Sampler.Estimator(rgba: capture.rgba, width: capture.width, height: capture.height,
            observation: observation, ownership: ownership)
        var modes: [Int: Sampler.Bin] = [:]
        for i in ownership.indices where ownership[i] != 0 {
            let p = i * 4
            let key = Int(capture.rgba[p] >> 4) * 256 + Int(capture.rgba[p + 1] >> 4) * 16 + Int(capture.rgba[p + 2] >> 4)
            if modes[key] == nil { modes[key] = Sampler.Bin(key: key, order: modes.count) }
            modes[key]!.add(capture.rgba, p)
        }
        let pale = modes.values.filter { $0.count >= 12 && $0.mean.min()! >= 175
            && $0.mean.max()! - $0.mean.min()! <= 32 }.sorted { $0.count > $1.count }
        let rims = observation.bins.sorted { (observation.rim[$0.key] ?? 0) > (observation.rim[$1.key] ?? 0) }
        let priorBG = Sampler.rgb(result?["background"])!
        let priorFG = Sampler.rgb(result?["foreground"])!
        let roleSeed = priorFG.min()! >= 175
            ? Sampler.rgb((result?["sourceInk"] as? Payload)?["stroke"]) ?? Sampler.rgb(result?["stroke"]) ?? priorFG
            : priorFG
        let axis = Sampler.subtract(roleSeed, priorBG), squared = Sampler.dot(axis, axis)
        let extremes = modes.values.filter { mode in
            let delta = Sampler.subtract(mode.mean, priorBG), fraction = Sampler.dot(delta, axis) / squared
            return mode.count >= 6 && fraction >= 1 && fraction <= 2
                && (zip(delta, axis).map { abs($0 - fraction * $1) }.max() ?? 0) <= 24
        }.sorted { Sampler.distance($0.mean, priorBG) > Sampler.distance($1.mean, priorBG) }
        let edgePrototype = extremes.first?.mean ?? roleSeed
        let rawOwned = Sampler.estimate(rgba: capture.rgba, width: capture.width, height: capture.height, ownership: ownership)
        var candidates: [Payload] = []
        for mode in pale.prefix(6) {
            let fill = mode.mean
            let mask = ownership.indices.map { ownership[$0] != 0 && Sampler.distance(estimator.color($0), fill) <= 12 ? UInt8(1) : 0 }
            let components = estimator.components(mask).map { c -> Payload in
                let owned = !c.boundary && c.points.allSatisfy { i in
                    ownership[i - 1] != 0 && ownership[i + 1] != 0 && ownership[i - capture.width] != 0 && ownership[i + capture.width] != 0
                }
                return ["bounds": [c.left, c.top, c.width, c.height], "points": c.points.count,
                    "density": Double(c.points.count) / Double(c.area), "ownedInterior": owned,
                    "structuralMember": owned && c.points.count >= 6 && c.height >= 5
                        && (c.width * 5 <= c.height * 2 || Double(c.points.count) <= Double(c.area) * 0.65)]
            }
            let backgrounds = [priorBG] + rims.prefix(3).map(\.mean)
            let certificates = backgrounds.map { bg -> Payload in
                ["exterior": bg, "certificate": Sampler.diagnosticCertificate(capture.rgba, capture.width,
                    capture.height, ownership, fill, edgePrototype, bg) as Any? ?? NSNull()]
            }
            candidates.append(["rgb": fill, "ownedBinPixels": mode.count, "components": components,
                               "knownSeedCertificates": certificates])
        }
        var budget = 98_304
        let certified = (result?["enclosingRoleEvidence"] as? Payload)?["accepted"] as? Bool == true
        let retry = certified ? result : Sampler.certifySourceInkHypothesis(rgba: capture.rgba,
            width: capture.width, height: capture.height, ownership: ownership,
            result: result, observationBudget: &budget)
        var ownershipTrials: [Payload] = []
        if let whiteMode = pale.first(where: { $0.mean.min()! > 240 }) {
            for margin in [1.0, 2, 4, 8] {
                let trialMask = NativeSourceColorSamplingStage.geometryMask(width: capture.width, height: capture.height,
                    polygons: [local(polygon(bounds[index]))],
                    excluded: bounds.indices.filter { $0 != index }.map { local(polygon(bounds[$0])) }, margin: margin)!
                ownershipTrials.append(["margin": margin,
                    "whiteFill": Sampler.diagnosticCertificate(capture.rgba, capture.width, capture.height,
                        trialMask, whiteMode.mean, edgePrototype, priorBG) as Any? ?? NSNull(),
                    "darkFill": Sampler.diagnosticCertificate(capture.rgba, capture.width, capture.height,
                        trialMask, priorFG, whiteMode.mean, priorBG) as Any? ?? NSNull()])
            }
        }
        let details: Payload = ["image": input, "layout": layoutPath, "id": id,
            "roi": [capture.x, capture.y, capture.sw, capture.sh], "sampleSize": [capture.width, capture.height],
            "sourceBounds": bounds[index], "captureCount": recording.captures.count,
            "stageResult": result as Any? ?? NSNull(), "rawOwnedEstimate": rawOwned as Any? ?? NSNull(),
            "selectedEdgePrototype": edgePrototype, "ownershipTrials": ownershipTrials,
            "interiorRayProposal": pale.filter { priorFG.min()! < 175 || Sampler.distance($0.mean, priorFG) <= 12 }.prefix(1).map { mode in
                Sampler.diagnosticInteriorRays(capture.rgba, capture.width, capture.height, ownership,
                    mode.mean, edgePrototype, priorBG)
            },
            "postStageRetry": retry as Any? ?? NSNull(), "retrySpent": 98_304 - budget,
            "paleCandidates": candidates,
            "ownedModes": modes.values.sorted { $0.count > $1.count }.prefix(16).map { ["rgb": $0.mean, "count": $0.count] as Payload },
            "rimModes": rims.prefix(8).map { ["rgb": $0.mean, "count": observation.rim[$0.key] ?? 0] as Payload }]
        let data = try JSONSerialization.data(withJSONObject: cleanJSON(details), options: [.sortedKeys, .prettyPrinted])
        if let directory = ProcessInfo.processInfo.environment["AIDOKU_ROLE_DIAGNOSTICS_DIR"] {
            let stem = directory + "/" + url.deletingLastPathComponent().lastPathComponent + "-card-" + id
            try data.write(to: URL(fileURLWithPath: stem + ".json"))
            saveROI(capture, to: stem + "-roi.png")
            try Data(capture.rgba).write(to: URL(fileURLWithPath: stem + ".rgba"))
            try Data(ownership).write(to: URL(fileURLWithPath: stem + ".ownership"))
            print("REAL_DIAGNOSTIC \(stem).json")
        } else { print(String(data: data, encoding: .utf8)!) }
        if ProcessInfo.processInfo.environment["AIDOKU_REQUIRE_PIXEL_PAIR"] != nil {
            var problems: [String] = []
            let final = retry ?? result
            problems += try observedOracleErrors(url.deletingLastPathComponent().lastPathComponent + "-card-" + id, final)
            if Sampler.rgb(final?["foreground"]) != Sampler.rgb(result?["foreground"]) {
                problems.append("full source replay foreground changed")
            }
            if Sampler.rgb(final?["stroke"]) == nil { problems.append("full source replay ordered stroke still unresolved") }
            let pair = final?["enclosingRoleEvidence"] as? Payload
            if (pair?["endpointEvidence"] as? Payload)?["accepted"] as? Bool != true {
                problems.append("full source replay lacks accepted observed endpoints")
            }
            if let directory = ProcessInfo.processInfo.environment["AIDOKU_ROLE_BASELINE_DIR"] {
                let originalPath = directory + "/" + url.deletingLastPathComponent().lastPathComponent + "-card-" + id + ".json"
                let original = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: originalPath))) as! Payload
                let before = original["stageResult"] as! Payload
                if Sampler.rgb(result?["background"]) != Sampler.rgb(before["background"]) {
                    problems.append("full source replay BG changed from archived observation")
                }
            }
            report("required-full-source-pair-" + url.deletingLastPathComponent().lastPathComponent + "-" + id,
                problems, ["foreground": final?["foreground"] as Any? ?? NSNull(),
                    "stroke": final?["stroke"] as Any? ?? NSNull(), "background": final?["background"] as Any? ?? NSNull(),
                    "authority": "source-role replay; RGBGT/width/rendering quality unmeasured"])
        }
        break
    }
    recording.reader.release()
}
if CommandLine.arguments.count > 1 {
    for index in stride(from: 1, to: CommandLine.arguments.count, by: 3) {
        try replay(CommandLine.arguments[index], CommandLine.arguments[index + 1], CommandLine.arguments[index + 2])
    }
}
print("REAL_SUMMARY PASS=\(passed) FAIL=\(failed)")
'''

PIXEL_HARNESS = r'''
for prefix in CommandLine.arguments.dropFirst() {
    let data = try Data(contentsOf: URL(fileURLWithPath: prefix + ".json"))
    let record = try JSONSerialization.jsonObject(with: data) as! Payload
    let size = record["sampleSize"] as! [Int], w = size[0], h = size[1]
    let rgba = Array(try Data(contentsOf: URL(fileURLWithPath: prefix + ".rgba")))
    let ownership = Array(try Data(contentsOf: URL(fileURLWithPath: prefix + ".ownership")))
    let before = record["stageResult"] as! Payload
    var budget = 98_304
    let alreadyCertified = (before["enclosingRoleEvidence"] as? Payload)?["accepted"] as? Bool == true
    let result = alreadyCertified ? before : Sampler.certifySourceInkHypothesis(rgba: rgba, width: w, height: h,
        ownership: ownership, result: before, observationBudget: &budget)
    let forecast = Sampler.supportedOriginalStrokeForecast(rgba: rgba, width: w, height: h,
        ownership: ownership, result: before, independentObserverAbstained: !alreadyCertified && Sampler.rgb(before["stroke"]) == nil)
    let row: Payload = ["pixelReplay": prefix, "before": before, "after": result as Any? ?? NSNull(),
        "uncalibratedStrokeForecast": forecast as Any? ?? NSNull(),
        "spent": 98_304 - budget,
        "orderedEndpoints": Sampler.diagnosticOrderedEndpoints(rgba, w, h, ownership, before)]
    print(String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
    if ProcessInfo.processInfo.environment["AIDOKU_REQUIRE_STROKE_FORECAST"] != nil {
        var errors: [String] = []
        if alreadyCertified {
            if forecast != nil { errors.append("existing certified pair was replaced by raw forecast") }
        } else {
            if forecast == nil { errors.append("source-backed raw stroke forecast not retained") }
            if forecast?["certified"] as? Bool != false { errors.append("forecast falsely certified") }
            let raw = before["sourceInk"] as! Payload
            if Sampler.rgb(forecast?["color"]) != Sampler.rgb(raw["stroke"]) { errors.append("raw ordered stroke changed") }
        }
        report("actual-raw-stroke-forecast-" + URL(fileURLWithPath: prefix).lastPathComponent, errors,
            forecast ?? ["retained": false, "alreadyCertified": alreadyCertified])
    }
    if ProcessInfo.processInfo.environment["AIDOKU_REQUIRE_PIXEL_PAIR"] != nil {
        var problems: [String] = []
        let final = result ?? before
        problems += try observedOracleErrors(URL(fileURLWithPath: prefix).lastPathComponent, final)
        let foreground = Sampler.rgb(final["foreground"])
        let stroke = Sampler.rgb(final["stroke"])
        let evidence = final["enclosingRoleEvidence"] as? Payload
        let ordered = before["sourceInk"] as! Payload
        if foreground != Sampler.rgb(before["foreground"]) { problems.append("final foreground changed") }
        if stroke != Sampler.rgb(alreadyCertified ? before["stroke"] : ordered["stroke"]) {
            problems.append("ordered observed stroke not recertified")
        }
        if (evidence?["endpointEvidence"] as? Payload)?["accepted"] as? Bool != true {
            problems.append("actual source pair lacks accepted observed endpoints")
        }
        if Sampler.rgb(final["background"]) != Sampler.rgb(before["background"]) { problems.append("sampling BG was recolored") }
        report("required-real-pixel-pair-" + URL(fileURLWithPath: prefix).lastPathComponent, problems,
            ["foreground": foreground as Any? ?? NSNull(), "stroke": stroke as Any? ?? NSNull(),
             "background": final["background"] as Any? ?? NSNull(), "sourceWidth": "unknown",
             "authority": "source-pixel role evidence only; no RGBGT or rendering quality claim"])
    }
    if let directory = ProcessInfo.processInfo.environment["AIDOKU_ROLE_DIAGNOSTICS_DIR"] {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let destination = directory + "/" + URL(fileURLWithPath: prefix).lastPathComponent + "-pixel-replay.json"
        try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL(fileURLWithPath: destination))
    }
    if ProcessInfo.processInfo.environment["AIDOKU_ROLE_SEARCH"] != nil {
        let ordered = before["sourceInk"] as! Payload
        let fill = Sampler.rgb(ordered["foreground"])!
        let observation = Sampler.Observation(rgba: rgba, width: w, height: h)!
        let estimator = Sampler.Estimator(rgba: rgba, width: w, height: h, observation: observation, ownership: ownership)
        let fillMask = ownership.indices.map { ownership[$0] != 0
            && Sampler.distance(estimator.color($0), fill) <= 12 ? 1 : 0 }
        let near = estimator.nearOwners(fillMask, reach: 3).near
        var local: [Int: Sampler.Bin] = [:]
        for i in near.indices where near[i] > 0 && ownership[i] != 0
            && Sampler.distance(estimator.color(i), fill) >= 48 {
            let p = i * 4, key = Int(rgba[p] >> 4) * 256 + Int(rgba[p + 1] >> 4) * 16 + Int(rgba[p + 2] >> 4)
            if local[key] == nil { local[key] = Sampler.Bin(key: key, order: local.count) }
            local[key]!.add(rgba, p)
        }
        let edges = [Sampler.rgb(ordered["stroke"])!]
        var best: [Payload] = []
        for y in stride(from: 0, to: h, by: 32) {
            let region = [0, y, w, min(h, y + 32)]
            var exterior: [Int: Sampler.Bin] = [:]
            for yy in y..<min(h, y + 32) { for x in 0..<w {
                let i = yy * w + x
                guard ownership[i] == 0 else { continue }
                let p = i * 4, key = Int(rgba[p] >> 4) * 256 + Int(rgba[p + 1] >> 4) * 16 + Int(rgba[p + 2] >> 4)
                if exterior[key] == nil { exterior[key] = Sampler.Bin(key: key, order: exterior.count) }
                exterior[key]!.add(rgba, p)
            } }
            let exteriors = exterior.values.filter { $0.count >= 6 }.sorted { $0.count > $1.count }.prefix(6)
            var top: Payload = ["supported": 0, "tested": 0]
            for edge in edges { for bg in exteriors where Sampler.distance(edge, bg.mean) >= 48 {
                let e = Sampler.diagnosticInteriorRays(rgba, w, h, ownership, fill, edge, bg.mean, region: region)
                let fraction = Sampler.number(e["supported"]) / max(1, Sampler.number(e["tested"]))
                let previous = Sampler.number(top["supported"]) / max(1, Sampler.number(top["tested"]))
                if Sampler.number(e["tested"]) >= 12 && fraction > previous {
                    top = e; top["edge"] = edge; top["exterior"] = bg.mean; top["region"] = region
                }
            } }
            best.append(top)
        }
        print("LOCAL_SEARCH " + String(data: try JSONSerialization.data(withJSONObject: best, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
print("PIXEL_SUMMARY PASS=\(passed) FAIL=\(failed)")
'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--real-case", action="append", nargs=3, metavar=("IMAGE", "LAYOUT", "ID"), default=[])
    parser.add_argument("--pixel-case", action="append", default=[], help="Existing JSON/RGBA/ownership filename prefix")
    parser.add_argument("--sampler-source", type=Path, default=SAMPLER, help="Immutable baseline source for causal ablation")
    parser.add_argument("--require-pixel-pair", action="store_true", help="Require unchanged final FG and certified ordered sourceInk stroke; historical white-only oracle was invalid")
    parser.add_argument("--pixel-oracle", type=Path, help="Explicit original-geometry expectedPairs JSON; test oracle only")
    parser.add_argument("--require-stroke-forecast", action="store_true", help="Evaluate separate uncalibrated forecast; does not waive strict pair failures")
    args = parser.parse_args()
    # Snapshot just this real production file, unchanged, to isolate a concurrent
    # parent edit. Same-file harness accesses the existing fileprivate classifier
    # without visibility rewrites or replacing any production implementation.
    production = args.sampler_source.read_bytes()
    print(f"PRODUCTION {args.sampler_source} sha256={hashlib.sha256(production).hexdigest()}", flush=True)
    with tempfile.TemporaryDirectory(prefix="aidoku-source-role-evidence-") as directory:
        temporary = Path(directory)
        harness = temporary / "main.swift"
        binary = temporary / "smoke"
        cache = temporary / "module-cache"
        replay_sources = b""
        if args.real_case:
            for name in ["NativeTranslationPixelKernels.swift", "NativeSourceROIFeatures.swift", "NativeCaptionSourcePalette.swift",
                         "NativeObservedSourcePalette.swift", "NativeSourceLetteringScale.swift", "NativeSourceColorSamplingStage.swift"]:
                path = SAMPLER.parent / name
                source_bytes = path.read_bytes()
                print(f"PRODUCTION {path.name} sha256={hashlib.sha256(source_bytes).hexdigest()}", flush=True)
                replay_sources += source_bytes + b"\n"
        harness.write_bytes(production + b"\n" + replay_sources + HARNESS.encode() + ORACLE_HARNESS.encode()
                            + (REAL_HARNESS.encode() if args.real_case else b"")
                            + (PIXEL_HARNESS.encode() if args.pixel_case else b"")
                            + b"\nif failed != 0 { exit(1) }\n")
        cache.mkdir()
        environment = os.environ.copy()
        environment.update({"CLANG_MODULE_CACHE_PATH": str(cache), "SWIFT_MODULECACHE_PATH": str(cache)})
        if args.require_pixel_pair:
            environment["AIDOKU_REQUIRE_PIXEL_PAIR"] = "1"
        if args.pixel_oracle:
            environment["AIDOKU_ROLE_PIXEL_ORACLE"] = str(args.pixel_oracle.resolve())
        if args.require_stroke_forecast:
            environment["AIDOKU_REQUIRE_STROKE_FORECAST"] = "1"
        extra_flags = []
        if args.real_case:
            kernel_started = time.perf_counter()
            rustc = "rustc"
            library = temporary / "libAidokuOverlayKernels.a"
            subprocess.run([rustc, "--crate-type", "staticlib", "--crate-name", "aidoku_overlay_kernels",
                            "-C", "opt-level=3", "-C", "panic=abort", "-C", "debuginfo=0",
                            str(ROOT / "Scripts/overlay-kernels/kernels.rs"), "-o", str(library)],
                           cwd=temporary, env=environment, check=True)
            extra_flags = ["-I", str(ROOT / "Scripts/overlay-kernels/native"), str(library)]
            print(f"Private pixel-kernel leaf compile={time.perf_counter() - kernel_started:.2f}s", flush=True)
        if b"static func ownedInteriorCertificate" in production:
            extra_flags += ["-D", "AIDOKU_SOURCE_ROLE_LOCAL_CANDIDATE"]
        started = time.perf_counter()
        subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(cache),
                        str(harness), *extra_flags, "-o", str(binary)],
                       cwd=temporary, env=environment, check=True)
        compiled = time.perf_counter()
        if args.real_case and args.pixel_case:
            raise ValueError("Use either real-case or pixel-case in one leaf invocation")
        result = subprocess.run([str(binary), *[value for case in args.real_case for value in case], *args.pixel_case], cwd=temporary, env=environment)
        finished = time.perf_counter()
        print(f"Host-only standalone compile={compiled - started:.2f}s execution={finished - compiled:.2f}s", flush=True)
        if args.sampler_source.read_bytes() != production:
            print("NOTE production changed during smoke; results describe the printed source hash", flush=True)
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
