import Testing
import UIKit
import Vision
@testable import Aidoku

/// Local incident originals and translations are deliberately kept outside the repository.
@Suite(.serialized)
@MainActor
struct ReaderSevenDefectReplayTests {
    @Test
    func originalPages() async throws {
        try #require(FileManager.default.fileExists(atPath:
            URL.documentsDirectory.appendingPathComponent("SevenDefectReplay/run.json").path), "Required local replay fixture is missing")
        let directory = URL.documentsDirectory.appendingPathComponent("SevenDefectReplay")
        let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: directory.appendingPathComponent("run.json")))
        try #require(!names.isEmpty, "The real-image replay manifest must execute at least one case")
        try #require(Set(names).count == names.count, "Replay cases must be unique")
        for name in names {
            try Task.checkCancellation()
            var failure: Error?
            do {
                try await replay(name: name, directory: directory)
            } catch {
                failure = error
            }
            // Each fixture owns model resources even if a required assertion throws.
            await ReaderOCRService.shared.purge()
            try Task.checkCancellation()
            if let failure {
                Issue.record("Replay fixture \(name) failed: \(String(describing: failure))")
            }
        }
    }

    private func replay(name: String, directory: URL) async throws {
        let image = try #require(UIImage(contentsOfFile: directory.appendingPathComponent(name + ".png").path))
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(name + ".vision-audit").path) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ja-JP"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: #require(image.cgImage)).perform([request])
            let reads: [[String: Any]] = (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first else { return nil }
                let b = observation.boundingBox
                return ["text": text.string, "confidence": text.confidence,
                    "rect": [b.minX, 1-b.maxY, b.width, b.height]]
            }
            try JSONSerialization.data(withJSONObject: reads, options: .prettyPrinted)
                .write(to: directory.appendingPathComponent(name + ".vision-audit.json"))
        }
        let prepared = try ReaderTranslationBackgroundImage.prepare(image)
        try #require(prepared.pngData()).write(to: directory.appendingPathComponent(name + ".prepared.png"))
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(name + ".audit").path) {
            let profile = NativeCoreMLOCRModelProfile.profile(for: .medium)
            let pipeline = NativeCoreMLOCRPipeline(
                detector: NativeCoreMLDetector(modelResourceName: profile.detectorResourceName, maximumSide: 2000),
                recognizer: NativeCoreMLRecognizer(modelResourceName: profile.recognizerResourceName,
                    dictionaryResourceName: profile.dictionaryResourceName,
                    expectedDictionaryCharacterCount: profile.expectedDictionaryCharacterCount, maximumRecognitionWidth: 1600),
                postprocessConfiguration: profile.postprocessConfiguration)
            let raw = try await pipeline.recognize(image: #require(image.cgImage), requestID: name, confidenceThreshold: 0.35,
                detectorConfiguration: .init(threshold: 0.3, boxThreshold: 0.3, unclipRatio: 1.5,
                                             maximumCandidates: 3000, recoveryBoxThreshold: 0.2))
            func rows(_ lines: [NativeCoreMLOCRLine]) -> [[String: Any]] {
                lines.map { ["text": $0.text, "score": $0.score, "polygon": $0.polygon.map { [$0.x, $0.y] },
                             "orientation": $0.orientation.rawValue] }
            }
            try JSONSerialization.data(withJSONObject: ["lines": rows(raw.lines), "gaps": rows(raw.gapLines.map(\.line)),
                "recovered": rows(raw.recoveryCandidates)], options: [.prettyPrinted])
                .write(to: directory.appendingPathComponent(name + ".raw.json"))
            if name == "phone-1" {
                let recovered = raw.lines.map(\.text)
                #expect(recovered.contains("しっかり飲んで"))
                #expect(recovered.contains("オキシトシンは"))
                #expect(recovered.contains("プロラクチンと"))
            }
            await pipeline.purgeResources()
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent(name + ".baseline.raw.json")),
           let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let lines = object["lines"] as? [[String: Any]] {
            let reads = lines.enumerated().compactMap { index, line -> NativeCoreMLRecognizedRegion? in
                guard let text = line["text"] as? String, let score = line["score"] as? Double,
                      let points = line["polygon"] as? [[Double]] else { return nil }
                return .init(sourceIndex: index, polygon: points.map { CGPoint(x: $0[0], y: $0[1]) }, text: text, confidence: score)
            }
            let cgImage = try #require(image.cgImage)
            let frame = try #require(await NativeOCRCGImageAdapter.makeRGBAFrameOffMain(from: cgImage))
            let grid = NativeOCRGridColumnRecovery.proposals(reads, width: frame.width, height: frame.height)
            let extraBase = max(reads.map(\.sourceIndex).max() ?? 0,
                                grid.flatMap(\.regions).map(\.sourceIndex).max() ?? 0) + 1
            let proposals = grid.enumerated().map { index, proposal in
                NativeOCRGridColumnRecovery.pixelRefined(proposal, reads: reads,
                    frame: frame, addedID: extraBase + index) ?? proposal
            }
            let profile = NativeCoreMLOCRModelProfile.profile(for: .medium)
            let recognizer = NativeCoreMLRecognizer(modelResourceName: profile.recognizerResourceName,
                dictionaryResourceName: profile.dictionaryResourceName,
                expectedDictionaryCharacterCount: profile.expectedDictionaryCharacterCount, maximumRecognitionWidth: 1600)
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name + ".column-crops.json")),
               let crops = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let requested: [NativeCoreMLRecognitionRegion] = crops.enumerated().compactMap { index, crop in
                    guard let b = crop["box"] as? [Double], b.count == 4 else { return nil }
                    return .init(sourceIndex: index, polygon: [CGPoint(x: b[0], y: b[1]), CGPoint(x: b[2], y: b[1]),
                        CGPoint(x: b[2], y: b[3]), CGPoint(x: b[0], y: b[3])])
                }
                let probe = try await recognizer.recognize(frame: frame, regions: requested, requestID: name, confidenceThreshold: 0.35)
                let audit = probe.regions.map { ["text": $0.text, "confidence": $0.confidence, "index": $0.sourceIndex] as [String: Any] }
                try JSONSerialization.data(withJSONObject: audit, options: .prettyPrinted)
                    .write(to: directory.appendingPathComponent(name + ".column-results.json"))
            }
            let result = try await recognizer.recognize(frame: frame, regions: proposals.flatMap(\.regions),
                requestID: name, confidenceThreshold: 0.35)
            try JSONSerialization.data(withJSONObject: [
                "columns": proposals.reduce(0) { $0 + $1.regions.count },
                "totalMilliseconds": result.diagnostics.totalMilliseconds,
                "modelLoadMilliseconds": result.diagnostics.modelLoadMilliseconds,
                "predictionMilliseconds": result.diagnostics.predictionMilliseconds,
                "preprocessingMilliseconds": result.diagnostics.preprocessingMilliseconds
            ], options: .prettyPrinted).write(to: directory.appendingPathComponent(name + ".grid-timing.json"))
            let audit: [[String: Any]] = proposals.map { proposal in
                ["evidence": proposal.evidence, "suffixes": proposal.suffixes,
                 "pixelAdded": Array(proposal.pixelAdded).sorted(),
                 "accepted": NativeOCRGridColumnRecovery.replacements(proposal, reads: result.regions) != nil,
                 "reads": proposal.regions.map { region -> [String: Any] in
                     let read = result.regions.first { $0.sourceIndex == region.sourceIndex }
                     let box = NativeOCRScopeGeometry.bounds(for: region.polygon) ?? .zero
                     return ["text": read?.text ?? "", "confidence": read?.confidence ?? 0,
                             "box": [box.minX, box.minY, box.maxX, box.maxY]]
                 }]
            }
            if name == "phone-2", reads.contains(where: { $0.text.contains("セク八") }) {
                #expect(proposals.contains { !$0.pixelAdded.isEmpty &&
                    NativeOCRGridColumnRecovery.replacements($0, reads: result.regions)?.count == 6 })
            }
            try JSONSerialization.data(withJSONObject: audit, options: .prettyPrinted)
                .write(to: directory.appendingPathComponent(name + ".grid-audit.json"))
            let vertical = NativeOCRGridColumnRecovery.shortVerticalProposals(reads, frame: frame,
                startingID: (reads.map(\.sourceIndex).max() ?? 0) + 1)
            if !vertical.isEmpty {
                let reread = try await recognizer.recognize(frame: frame, regions: vertical.flatMap(\.regions),
                    requestID: name, confidenceThreshold: 0.35)
                let rows: [[String: Any]] = vertical.map { proposal in
                    ["evidence": proposal.evidence,
                     "accepted": NativeOCRGridColumnRecovery.replacements(proposal, reads: reread.regions) != nil,
                     "reads": proposal.regions.map { region -> [String: Any] in
                         let read = reread.regions.first { $0.sourceIndex == region.sourceIndex }
                         return ["text": read?.text ?? "", "confidence": read?.confidence ?? 0]
                     }]
                }
                try JSONSerialization.data(withJSONObject: rows, options: .prettyPrinted)
                    .write(to: directory.appendingPathComponent(name + ".vertical-audit.json"))
            }
            let singleRows = NativeOCRGridColumnRecovery.singleRowProposals(reads, frame: frame,
                startingID: (reads.map(\.sourceIndex).max() ?? 0) + 1)
            if !singleRows.isEmpty {
                let reread = try await recognizer.recognize(frame: frame, regions: singleRows.flatMap(\.regions),
                    requestID: name, confidenceThreshold: 0.35)
                if name == "phone-1", reads.contains(where: { $0.text == "大密揉おう" }) {
                    #expect(singleRows.contains { proposal in
                        proposal.evidence == ["大", "密", "揉", "お", "う"] &&
                            NativeOCRGridColumnRecovery.replacements(proposal, reads: reread.regions)?.count == 5
                    })
                }
                let rows: [[String: Any]] = singleRows.map { proposal in
                    ["evidence": proposal.evidence,
                     "replaced": Array(proposal.replaced).sorted(),
                     "accepted": NativeOCRGridColumnRecovery.replacements(proposal, reads: reread.regions) != nil,
                     "reads": proposal.regions.map { region -> [String: Any] in
                         let read = reread.regions.first { $0.sourceIndex == region.sourceIndex }
                         return ["text": read?.text ?? "", "confidence": read?.confidence ?? 0]
                     }]
                }
                try JSONSerialization.data(withJSONObject: rows, options: .prettyPrinted)
                    .write(to: directory.appendingPathComponent(name + ".single-row-audit.json"))
            }
            await recognizer.purgeResources()
        }
        if let cached = try? Data(contentsOf: directory.appendingPathComponent(name + ".cached-regions.json")) {
            let saved = try JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: cached).map(\.region)
            let viewport = CGSize(width: 430, height: 574)
            let frameHeight = 430 * image.size.height / image.size.width
            let frame = CGRect(x: 0, y: (viewport.height - frameHeight) / 2, width: 430, height: frameHeight)
            let items = BrowserPageImageOverlayRenderer.layoutPayload(
                items: ReaderTranslationRegion.layoutItems(saved, imageSize: image.size), imageSize: image.size,
                sourceRect: frame, settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko", viewport: viewport)
            let payload: [String: Any] = ["items": items, "imageSize": [image.size.width, image.size.height],
                "viewport": [430, 574], "scale": 3, "displayRect": [frame.minX, frame.minY, frame.width, frame.height],
                "appearance": ["inpaintingEnabled": true, "preserveSourceBackgroundColor": true,
                    "preserveSourceTextColor": true, "opacity": 1, "minimumReadableFontSize": 5]]
            try JSONSerialization.data(withJSONObject: payload)
                .write(to: directory.appendingPathComponent(name + ".cached.payload.json"))
        }
        let regions = try await ReaderOCRService.shared.recognize(image: #require(image.cgImage), configuration: .init(
            detectorMaximumSide: 2000, confidenceThreshold: 0.35, detectorPixelThreshold: 0.3, detectorConfidenceThreshold: 0.3))
        try JSONEncoder().encode(regions.map(ReaderTranslationStoredRegion.init))
            .write(to: directory.appendingPathComponent(name + ".actual.regions.json"))
        if name == "phone-1" {
            #expect(regions.contains { $0.source == "プロラクチンとオキシトシンはしっかり飲んできましたか？" })
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent(name + ".expectations.json")),
           let expected = try JSONSerialization.jsonObject(with: data) as? [String: Int] {
            #expect(regions.count >= (expected["minimumRegions"] ?? 1), "Reject a wrong or already processed source fixture")
            #expect(regions.filter { $0.unitMemberRects.count >= 2 }.count >= (expected["minimumUnits"] ?? 0))
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent(name + ".required-source.json")) {
            let required = try JSONDecoder().decode([String].self, from: data)
            for source in required {
                #expect(regions.contains { $0.source.contains(source) }, "Missing independently checked source phrase: \(source)")
            }
        }
        if name == "case-4" {
            #expect(regions.contains { $0.source.hasSuffix("!?") && !$0.auxiliaryInkRects.isEmpty })
        }
        if name == "case-10" {
            // Five equally sized pink columns form one sentence in the upper lobe.
            // Its final column was previously translated separately and collided with
            // the first three columns; the next lobe remains a separate utterance.
            let dialogue = try #require(regions.first { $0.source.contains("何でクラスの") })
            #expect(dialogue.source.contains("男の子たちに見られながらやらないといけないの"))
            #expect(!dialogue.source.contains("動画"))
            #expect(regions.contains { $0.source.contains("動画まで") && $0.id != dialogue.id })
            #expect(!regions.contains { $0.id != dialogue.id &&
                ($0.source.contains("やらないと") || $0.source.contains("いけないの")) })
        }
        if name == "case-11" {
            #expect(regions.contains { $0.rect.minY > 0.85 && $0.rect.minX < 0.15 && $0.source.contains("つ") })
        }
        if name == "panel-1" {
            let caption = try #require(regions.first { $0.source.hasPrefix("イキ") })
            let tail = CGRect(x: 0.156597, y: 0.705078, width: 0.003009, height: 0.041189)
            #expect(caption.auxiliaryInkRects.contains { $0.intersects(tail) && $0.maxY >= 0.744 },
                    "The long pink source stroke must remain part of the erasure geometry")
        }
        if name == "panel-5" {
            let large = try #require(regions.first { $0.source.contains("オナニー") && $0.rect.minY > 0.25 })
            #expect(try #require(large.balloonInterior).center.y > 0.34)
        }
        if name == "lobe-5" {
            #expect(regions.contains { $0.source.hasPrefix("イキ") && !$0.auxiliaryInkRects.isEmpty })
        }
        if name == "lobe-7" {
            #expect(regions.contains { $0.source == "あああああ" && !$0.auxiliaryInkRects.isEmpty })
        }
        if name == "lobe-8" {
            #expect(regions.contains { $0.source.hasPrefix("このびちゃ") && $0.balloonInterior?.contourVerified == true })
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent(name + ".payload.json")),
           let old = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = old["items"] as? [[String: Any]] {
            let overrides = (try? Data(contentsOf: directory.appendingPathComponent(name + ".translations.json")))
                .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            // Reusing cached translations must not assign one old caption to
            // multiple overlapping fresh OCR regions. This is replay ownership,
            // not a production translation or merge heuristic.
            let owners: [String: Int] = Dictionary(uniqueKeysWithValues: items.compactMap { item in
                guard let id = item["id"] as? String, let b = item["sourceBounds"] as? [Double], b.count == 4,
                      let text = item["text"] as? String, !text.isEmpty else { return nil }
                let box = CGRect(x: b[0], y: b[1], width: b[2], height: b[3])
                let owner = regions.indices.max { a, b in
                    let x = regions[a].rect.intersection(box), y = regions[b].rect.intersection(box)
                    return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
                }
                return owner.map { (id, $0) }
            })
            var translated: [ReaderTranslationRegion] = []
            for (regionIndex, originalRegion) in regions.enumerated() {
                var region = originalRegion
                if let text = overrides[region.source] {
                    region.translation = text; translated.append(region); continue
                }
                let members = items.filter { item in
                    guard let id = item["id"] as? String, owners[id] == regionIndex else { return false }
                    guard let text = item["text"] as? String, !text.isEmpty,
                          let b = item["sourceBounds"] as? [Double], b.count == 4 else { return false }
                    let box = CGRect(x: b[0], y: b[1], width: b[2], height: b[3])
                    let shared = region.rect.intersection(box)
                    return !shared.isNull && shared.width * shared.height >= box.width * box.height * 0.55
                }.sorted { a, b in
                    let x = a["sourceBounds"] as? [Double] ?? [], y = b["sourceBounds"] as? [Double] ?? []
                    return x.count == 4 && y.count == 4 && x[0] > y[0]
                }
                guard !members.isEmpty else { continue }
                region.translation = members.compactMap { $0["text"] as? String }.joined(separator: " ")
                translated.append(region)
            }
            #expect(!translated.isEmpty, "The fixture must have actual source text with matching translations")
            let size = image.size, viewport = CGSize(width: 430, height: 574)
            let frameHeight = 430 * size.height / size.width
            let frame = CGRect(x: 0, y: (viewport.height - frameHeight) / 2, width: 430, height: frameHeight)
            let layout = BrowserPageImageOverlayRenderer.layoutPayload(
                items: ReaderTranslationRegion.layoutItems(translated, imageSize: size), imageSize: size,
                sourceRect: frame, settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko", viewport: viewport)
            var payload = old; payload["items"] = layout
            payload["viewport"] = [viewport.width, viewport.height]
            payload["imageSize"] = [size.width, size.height]
            var appearance = old["appearance"] as? [String: Any] ?? [:]
            appearance["minimumReadableFontSize"] = BrowserOverlayLayoutPlanner.minimumRenderedFontSize
            payload["appearance"] = appearance
            payload["displayRect"] = [frame.minX, frame.minY, frame.width, frame.height]
            try JSONSerialization.data(withJSONObject: payload).write(to: directory.appendingPathComponent(name + ".fresh.payload.json"))
        }
        #expect(!regions.isEmpty)
    }
}
