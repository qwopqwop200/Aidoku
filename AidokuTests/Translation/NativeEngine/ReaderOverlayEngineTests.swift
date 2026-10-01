// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
struct ReaderOverlayEngineTests {

    @Test
    func separateHorizontalSourceLinesDoNotBecomeASideBySideBand() {
        let sources = [
            CGRect(x: 207.9453125, y: 118.25, width: 191.8203125, height: 9.7421875),
            CGRect(x: 207.9453125, y: 131.6875, width: 204.921875, height: 9.0703125)
        ]
        let preferred = [
            CGRect(x: 207.9453125, y: 115.62109375, width: 191.8203125, height: 15),
            CGRect(x: 207.9453125, y: 128.72265625, width: 204.921875, height: 15)
        ]
        let layouts = preferred.map {
            BrowserOverlayCardLayout(rect: $0, maximumFontSize: 8, contentInsets: .zero)
        }
        let result = BrowserOverlayLayoutPlanner.relaxingCardPositions(
            layouts, sources: sources, sourceVerticals: [false, false],
            viewport: CGSize(width: 430, height: 241.875),
            preferredRects: preferred, allowsDetachedPlacements: [true, true]
        )
        #expect(result.count == 2)
        for index in result.indices {
            // Original failure moved one caption 175px over a house illustration.
            #expect(abs(result[index].rect.midX - sources[index].midX) <= 1)
            let intersection = result[index].rect.intersection(sources[index])
            #expect(!intersection.isNull)
            #expect(intersection.width * intersection.height >= sources[index].width * sources[index].height * 0.99)
            #expect(result[index].rect.size == layouts[index].rect.size)
            #expect(result[index].maximumFontSize == layouts[index].maximumFontSize)
        }
        let intersection = result[0].rect.intersection(result[1].rect)
        #expect(intersection.isNull || intersection.width <= 0.25 || intersection.height <= 0.25)
    }

    @Test
    func mixedSourceCaptionKeepsLegacyPlacementInsteadOfExposingOriginal() {
        // Actual 0356 sources16/17 are vertical; source20 is horizontal.
        // Broad source-Y veto moved20 down15.25px onto the hat and exposed クライ.
        let sources = [
            CGRect(x: 29.29440389, y: 256.32603406, width: 11.50851582, height: 36.09489051),
            CGRect(x: 56.49635036, y: 256.84914842, width: 30.86374696, height: 35.57177616),
            CGRect(x: 85.26763990, y: 279.34306569, width: 29.29440389, height: 13.60097324)
        ]
        let preferred = [
            CGRect(x: 17.04866180, y: 256.32603406, width: 36, height: 36.09489051),
            CGRect(x: 50.72822384, y: 256.84914842, width: 42.4, height: 35.57177616),
            CGRect(x: 85.26763990, y: 279.34306569, width: 29.29440389, height: 13.60097324)
        ]
        let layouts = preferred.map {
            BrowserOverlayCardLayout(rect: $0, maximumFontSize: 8, contentInsets: .zero)
        }
        func solve(_ orientations: [Bool]?) -> [BrowserOverlayCardLayout] {
            BrowserOverlayLayoutPlanner.relaxingCardPositions(
                layouts, sources: sources, sourceVerticals: orientations,
                viewport: CGSize(width: 430, height: 700), preferredRects: preferred,
                allowsDetachedPlacements: [true, true, true]
            )
        }
        let legacy = solve(nil)
        let mixed = solve([true, true, false])
        let unknown = solve([])
        #expect(mixed.count == legacy.count)
        for index in legacy.indices {
            #expect(mixed[index].rect == legacy[index].rect)
            #expect(unknown[index].rect == legacy[index].rect)
            #expect(mixed[index].maximumFontSize == legacy[index].maximumFontSize)
        }
    }

    @MainActor
    @Test func pageImageDOMOverlayUsesExistingCollisionAwareCardLayout() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        let sources = (0..<10).map { column in
            CGRect(
                x: 20 + CGFloat(column) * 34,
                y: 90,
                width: 20,
                height: 150
            )
        }
        let items = sources.enumerated().map { index, source in
            BrowserOverlayItem(
                stableRegionID: UInt64(index + 1),
                rect: source,
                sourceText: "縦書きの台詞です",
                translatedText:
                    "서로 겹치지 않는 번역 말풍선입니다 \(index + 1)",
                confidence: 0.99,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: false
            )
        }
        let viewport = CGSize(width: 390, height: 715)
        let payload = NativeTranslationLayoutPlanner.payload(
            items: items,
            imageSize: viewport,
            sourceRect: CGRect(origin: .zero, size: viewport),
            settings: settings,
            targetLanguage: "ko",
            viewport: viewport
        )
        let cards = payload.compactMap { item -> CGRect? in
            guard let x = item["x"] as? CGFloat,
                  let y = item["y"] as? CGFloat,
                  let width = item["width"] as? CGFloat,
                  let height = item["height"] as? CGFloat
            else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }

        #expect(payload.count == items.count)
        #expect(cards.count == payload.count)
        #expect(Set(payload.compactMap { $0["id"] as? String }) == Set(
            items.compactMap(\.stableRegionID).map { String($0) }
        ))
        #expect(Set(payload.compactMap { $0["text"] as? String }) == Set(
            items.compactMap(\.translatedText)
        ))
        for (item, card) in zip(payload, cards) {
            let text = item["text"] as? String
            let vertical = item["vertical"] as? Bool
            let fontSize = item["fontSize"] as? CGFloat
            let lineHeight = item["lineHeight"] as? CGFloat
            let lightSurface = item["lightSurface"] as? Bool
            let clipsText = item["clipsText"] as? Bool
            let top = item["paddingTop"] as? CGFloat
            let left = item["paddingLeft"] as? CGFloat
            let bottom = item["paddingBottom"] as? CGFloat
            let right = item["paddingRight"] as? CGFloat

            #expect(items.compactMap(\.translatedText).contains(text ?? ""))
            #expect(text?.contains("\n") == false)
            #expect(vertical == false)
            #expect(lightSurface == true)
            #expect(clipsText == false)
            #expect(item["callout"] == nil)
            #expect((fontSize ?? 0) >= 5)
            #expect((lineHeight ?? 0) >= (fontSize ?? .infinity))
            #expect(CGRect(origin: .zero, size: viewport).contains(card))
            #expect(card.width < viewport.width / 2)
            #expect(card.height < viewport.height / 2)
            #expect(sources.contains { source in
                card.insetBy(dx: -0.5, dy: -0.5).contains(source)
            })
            if let text, let fontSize, let top, let left, let bottom,
               let right
            {
                #expect(BrowserOverlayDisplayVariant.plain(
                    text,
                    vertical: false
                ).fits(
                    available: CGSize(
                        width: card.width - left - right,
                        height: card.height - top - bottom
                    ),
                    fontSize: fontSize
                ))
            }
        }
        for left in cards.indices {
            for right in cards.indices where right > left {
                let overlap = cards[left].intersection(cards[right])
                #expect(
                    overlap.isNull || overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
    }

    @Test func paddleOCRLineOrientationDecodeIsBackwardAndForwardTolerant()
        throws
    {
        let missing = try JSONDecoder().decode(
            PaddleOCRLine.self,
            from: Data(
                #"{"poly":[{"x":0,"y":0},{"x":10,"y":20}],"text":"縦","score":0.9}"#
                    .utf8
            )
        )
        #expect(missing.orientationRaw == nil)
        #expect(missing.sourceOrientation == .unknown)

        let vertical = try JSONDecoder().decode(
            PaddleOCRLine.self,
            from: Data(
                #"{"poly":[{"x":0,"y":0},{"x":10,"y":20}],"text":"縦","score":0.9,"orientation":"vertical"}"#
                    .utf8
            )
        )
        #expect(vertical.orientationRaw == "vertical")
        #expect(vertical.sourceOrientation == .vertical)

        let future = try JSONDecoder().decode(
            PaddleOCRLine.self,
            from: Data(
                #"{"poly":[{"x":0,"y":0},{"x":10,"y":20}],"text":"斜","score":0.9,"orientation":"diagonal"}"#
                    .utf8
            )
        )
        #expect(future.orientationRaw == "diagonal")
        #expect(future.sourceOrientation == .unknown)
    }

    @Test func sidePanelHistoryUpdatesRowsWithoutSourceOnlyReuse() {
        var history = BrowserSidePanelSessionHistory(maximumItems: 3)
        history.remember([
            .init(
                id: "ocr-0",
                item: overlayItem(
                    source: "同じ文字",
                    translation: "이전 번역"
                )
            ),
            .init(
                id: "ocr-1",
                item: overlayItem(
                    source: "次の文字",
                    translation: "다음 번역"
                )
            ),
        ])

        history.remember([
            .init(
                id: "ocr-0",
                item: overlayItem(
                    source: "同じ文字",
                    translation: nil
                )
            ),
        ])

        #expect(history.entries.map(\.id) == ["ocr-0", "ocr-1"])
        #expect(history.items[0].translatedText == nil)
        #expect(history.items[1].translatedText == "다음 번역")
    }

    @Test func sidePanelHistoryIsBoundedAndExplicitlyEphemeral() {
        var history = BrowserSidePanelSessionHistory(maximumItems: 2)
        history.remember((0..<4).map { index in
            .init(
                id: "ocr-\(index)",
                item: overlayItem(
                    source: "source-\(index)",
                    translation: "translation-\(index)"
                )
            )
        })

        #expect(history.entries.map(\.id) == ["ocr-2", "ocr-3"])
        history.removeAll()
        #expect(history.entries.isEmpty)

        var disabled = BrowserSidePanelSessionHistory(maximumItems: 0)
        disabled.remember([
            .init(
                id: "discarded",
                item: overlayItem(
                    source: "source",
                    translation: "translation"
                )
            ),
        ])
        #expect(disabled.entries.isEmpty)
    }

    @Test func sidePanelHistoryResetIsLimitedToSessionInvalidation() {
        #expect(
            !BrowserOCRInvalidationScope.display
                .clearsSidePanelSessionHistory
        )
        #expect(
            BrowserOCRInvalidationScope.session
                .clearsSidePanelSessionHistory
        )
    }

    @Test func verticalOverlayRequiresTallCJKText() {
        let tall = CGRect(x: 0, y: 0, width: 30, height: 120)
        #expect(BrowserOverlayTextFlow.usesVerticalLayout(
            rect: tall,
            texts: ["縦書き", "세로쓰기"]
        ))
        #expect(!BrowserOverlayTextFlow.usesVerticalLayout(
            rect: tall,
            texts: ["Vertical text", "세로쓰기"]
        ))
        #expect(!BrowserOverlayTextFlow.usesVerticalLayout(
            rect: CGRect(x: 0, y: 0, width: 120, height: 30),
            texts: ["縦書き"]
        ))
        #expect(
            BrowserOverlayTextFlow.verticalized("字幕") ==
                "字\n幕"
        )
    }

    @Test func explicitOCRSourceOrientationStillRespectsWritingScript() {
        let tall = CGRect(x: 0, y: 0, width: 30, height: 120)
        let wide = CGRect(x: 0, y: 0, width: 120, height: 30)
        #expect(!BrowserOverlayTextFlow.usesVerticalSourceLayout(
            rect: tall,
            text: "縦書き",
            sourceOrientation: .horizontal
        ))
        #expect(!BrowserOverlayTextFlow.usesVerticalSourceLayout(
            rect: wide,
            text: "Horizontal text",
            sourceOrientation: .vertical
        ))
        #expect(!BrowserOverlayTextFlow.usesVerticalSourceLayout(
            rect: tall,
            text: "세로로 검출된 한국어",
            sourceOrientation: .vertical
        ))
        #expect(BrowserOverlayTextFlow.usesVerticalSourceLayout(
            rect: wide,
            text: "縦書きの日本語",
            sourceOrientation: .vertical
        ))
        #expect(BrowserOverlayTextFlow.usesVerticalSourceLayout(
            rect: tall,
            text: "縦書き",
            sourceOrientation: .unknown
        ))
    }

    @Test func overlayWrappingScriptMatchesTheDisplayedLanguage() {
        #expect(
            BrowserOverlayTextFlow.wrappingScript(for: "日本語の文章") ==
                .cjk
        )
        #expect(
            BrowserOverlayTextFlow.wrappingScript(for: "中文换行") == .cjk
        )
        #expect(
            BrowserOverlayTextFlow.wrappingScript(for: "한국어 줄바꿈") ==
                .korean
        )
        #expect(
            BrowserOverlayTextFlow.wrappingScript(for: "English wrapping") ==
                .word
        )
        #expect(
            BrowserOverlayTextFlow.wrappingScript(for: "مرحبا بالعالم") ==
                .rightToLeft
        )
    }

    @Test func overlayTextFlowDetectsRTLConservatively() {
        #expect(BrowserOverlayTextFlow.isRightToLeft("مرحبا بالعالم"))
        #expect(BrowserOverlayTextFlow.isRightToLeft("שלום"))
        #expect(!BrowserOverlayTextFlow.isRightToLeft("English text"))
        #expect(!BrowserOverlayTextFlow.isRightToLeft("日本語"))
        #expect(!BrowserOverlayTextFlow.isRightToLeft("English مرحبا"))
    }

    @Test func visibleItemsPublishOCRBeforeTranslation() {
        let sourceOnly = overlayItem(source: "原文", translation: nil)
        let blank = overlayItem(source: "空白", translation: "  \n")
        let translated = overlayItem(source: "翻訳", translation: "번역")

        let translateOnly = BrowserOverlayVisibility.visibleItems(
            [sourceOnly, blank, translated]
        )
        #expect(translateOnly.map(\.sourceText) == ["原文", "空白", "翻訳"])
        #expect(translateOnly.map(\.translatedText) == [nil, nil, "번역"])
        #expect(BrowserOverlayVisibility.visibleItems(
            [sourceOnly, translated]
        ) == [sourceOnly, translated])

    }

    @Test func koreanTranslationStaysHorizontalOnVerticalSource() {
        #expect(!BrowserOverlayTextFlow.translatedTextUsesVerticalLayout(
            sourceIsVertical: true,
            targetLanguage: "ko",
            text: "세로 문장을 인식합니다"
        ))
        #expect(BrowserOverlayTextFlow.translatedTextUsesVerticalLayout(
            sourceIsVertical: true,
            targetLanguage: "ja",
            text: "縦書きの翻訳"
        ))
    }

    @Test func singleLogicalLineRejectsEveryActualLineBreak() {
        #expect(BrowserOverlayTextFlow.isSingleLogicalLine("縦書き"))
        #expect(BrowserOverlayTextFlow.isSingleLogicalLine(" 세로 쓰기 "))
        #expect(!BrowserOverlayTextFlow.isSingleLogicalLine("縦書き\n二列"))
        #expect(!BrowserOverlayTextFlow.isSingleLogicalLine("縦書き\n"))
        #expect(!BrowserOverlayTextFlow.isSingleLogicalLine("\n縦書き"))
        #expect(!BrowserOverlayTextFlow.isSingleLogicalLine(" \n "))
    }

    @Test @MainActor
    func coreTextVerticalPainterUsesRawMixedOrientationText() throws {
        let text = "「縦書き。」…ABC"
        let attributed = BrowserOverlayVerticalTextRenderer.attributedString(
            text: text,
            fontSize: 16,
            weight: .heavy,
            foregroundColor: .label
        )

        #expect(attributed.string == text)
        #expect(!attributed.string.contains("\n"))
        #expect(attributed.attribute(
            BrowserOverlayVerticalTextRenderer.verticalFormsAttributeKey,
            at: 0,
            effectiveRange: nil
        ) as? Bool == true)
        let punctuationOffset = (text as NSString).range(of: "。").location
        #expect(attributed.attribute(
            BrowserOverlayVerticalTextRenderer.verticalFormsAttributeKey,
            at: punctuationOffset,
            effectiveRange: nil
        ) as? Bool == true)
        let paragraph = try #require(attributed.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(paragraph.alignment == .center)

        let snapshot = BrowserOverlayVerticalTextRenderer.snapshot(
            text: text,
            bounds: CGSize(width: 128, height: 52),
            fontSize: 16
        )
        #expect(snapshot.fits)
        #expect(snapshot.usesVerticalForms)
        #expect(snapshot.progressesRightToLeft)
        #expect(snapshot.lineOrigins.count >= 2)
        for pair in zip(
            snapshot.lineOrigins,
            snapshot.lineOrigins.dropFirst()
        ) {
            #expect(pair.0.x > pair.1.x)
        }
    }

    @Test @MainActor
    func verticalDualLanguagePainterKeepsTheC1ComposedPayload() throws {
        let item = BrowserOverlayItem(
            stableRegionID: 996,
            rect: CGRect(x: 220, y: 40, width: 40, height: 160),
            sourceText: "縦書き原文",
            translatedText: "縦書き翻訳",
            confidence: 0.99,
            sourceOrientation: .vertical
        )
        let content = BrowserOverlayCardContent.make(
            item: item,
            mode: .originalAndTranslation,
            sourceVertical: true,
            translatedVertical: true
        )

        #expect(BrowserOverlayVerticalTextPainter.text(
            for: item,
            content: content,
            mode: .originalAndTranslation
        ) == content.displayed.displayText)
    }

    @Test func finalImageBoundaryDropsOnlyExactTextDuplicateLikeBaseline()
        throws
    {
        let items = [
            BrowserOverlayItem(
                stableRegionID: 100,
                rect: CGRect(x: 68, y: 104, width: 18, height: 119),
                sourceText: "どうしよ……ここで私が断って寄付が止んじゃったらしい",
                translatedText: nil,
                confidence: 0.96,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: true
            ),
            BrowserOverlayItem(
                stableRegionID: 101,
                rect: CGRect(x: 69, y: 105, width: 17, height: 117),
                sourceText: "どうしよ……ここで私が断って寄付が止んじゃったらしい",
                translatedText: nil,
                confidence: 0.94,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: true
            ),
        ]

        let result = BrowserImageSourceOverlayConsolidator.consolidate(items)
        let remaining = try #require(result.first)
        #expect(result.count == 1)
        #expect(remaining.sourceText ==
            "どうしよ……ここで私が断って寄付が止んじゃったらしい")
        #expect(remaining.rect == CGRect(x: 68, y: 104, width: 18, height: 119))
        #expect(remaining.stableRegionID == 100)
    }

    @Test func finalImageBoundaryOnlyTrimsAndCaseFoldsForDeduplication() {
        let rect = CGRect(x: 80, y: 120, width: 42, height: 96)
        func consolidatedCount(_ left: String, _ right: String) -> Int {
            BrowserImageSourceOverlayConsolidator.consolidate([
                BrowserOverlayItem(
                    stableRegionID: 1,
                    rect: rect,
                    sourceText: left,
                    translatedText: nil,
                    confidence: 0.99,
                    sourceOrientation: .vertical
                ),
                BrowserOverlayItem(
                    stableRegionID: 2,
                    rect: rect,
                    sourceText: right,
                    translatedText: nil,
                    confidence: 0.98,
                    sourceOrientation: .vertical
                ),
            ]).count
        }

        #expect(consolidatedCount(" \nAb C\t", "aB c") == 1)
        #expect(consolidatedCount("A B", "AB") == 2)
        #expect(consolidatedCount("縦\n書き", "縦書き") == 2)
        #expect(consolidatedCount("Ａ", "A") == 2)
    }

    @Test func finalImageBoundaryDoesNotInventVerticalJoin() {
        let result = BrowserImageSourceOverlayConsolidator.consolidate([
            BrowserOverlayItem(
                stableRegionID: 300,
                rect: CGRect(x: 338, y: 42, width: 34, height: 21),
                sourceText: "どう",
                translatedText: nil,
                confidence: 0.98,
                sourceOrientation: .horizontal,
                sourceSingleVerticalColumn: false
            ),
            BrowserOverlayItem(
                stableRegionID: 301,
                rect: CGRect(x: 339, y: 55, width: 31, height: 112),
                sourceText: "しよ……ここで私が断って寄付が止んじゃったらしい",
                translatedText: nil,
                confidence: 0.96,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: true
            ),
        ])

        #expect(result.count == 2)
    }

    @Test func finalImageBoundaryKeepsNeighboringVerticalColumnsSeparate() {
        let result = BrowserImageSourceOverlayConsolidator.consolidate([
            BrowserOverlayItem(
                rect: CGRect(x: 40, y: 100, width: 16, height: 90),
                sourceText: "右の文章",
                translatedText: nil,
                confidence: 0.95,
                sourceOrientation: .vertical
            ),
            BrowserOverlayItem(
                rect: CGRect(x: 66, y: 101, width: 16, height: 90),
                sourceText: "左の文章",
                translatedText: nil,
                confidence: 0.95,
                sourceOrientation: .vertical
            ),
        ])

        #expect(result.count == 2)
    }

    @Test func finalImageBoundaryPreservesDifferentContainedText() {
        let full = BrowserOverlayItem(
            stableRegionID: 200,
            rect: CGRect(x: 274, y: 96, width: 38, height: 104),
            sourceText: "イさが頑張ってくれてるのに何もしないなんて",
            translatedText: nil,
            confidence: 0.91,
            sourceOrientation: .vertical,
            sourceSingleVerticalColumn: true
        )
        let contained = BrowserOverlayItem(
            stableRegionID: 201,
            rect: CGRect(x: 294, y: 124, width: 17, height: 70),
            sourceText: "何もしないなんて",
            translatedText: nil,
            confidence: 0.99,
            sourceOrientation: .vertical,
            sourceSingleVerticalColumn: true
        )

        let result = BrowserImageSourceOverlayConsolidator.consolidate([
            contained, full,
        ])
        #expect(result.count == 2)
    }

    @Test func wrappedEnglishLinesBecomeOnePresentationCard() throws {
        let groups = BrowserOverlayPresentationGrouper.groups([
            presentationSegment(
                rect: CGRect(x: 210, y: 100, width: 128, height: 24),
                source: "設定画面を開いて",
                translation: "Open the"
            ),
            presentationSegment(
                rect: CGRect(x: 210, y: 128, width: 118, height: 24),
                source: "設定を",
                translation: "settings"
            ),
            presentationSegment(
                rect: CGRect(x: 210, y: 156, width: 108, height: 24),
                source: "開いてください",
                translation: "screen."
            ),
        ])

        let group = try #require(groups.first)
        #expect(groups.count == 1)
        #expect(group.segments.count == 3)
        #expect(group.overlayItem.translatedText == "Open the settings screen.")
    }

    @Test func overlappingContainedPriceDuplicateKeepsOneFullLabel() throws {
        let full = presentationSegment(
            rect: CGRect(x: 210, y: 500, width: 142, height: 40),
            source: "価格 12,345円",
            translation: "가격 12,345엔"
        )
        let contained = presentationSegment(
            rect: CGRect(x: 226, y: 508, width: 104, height: 24),
            source: "12,345円",
            translation: "12,345엔"
        )

        let unique = BrowserOverlayPresentationDeduplicator.deduplicate([
            contained,
            full,
        ])
        let remaining = try #require(unique.first)
        #expect(unique.count == 1)
        #expect(remaining.sourceText == "価格 12,345円")
        #expect(remaining.translatedText == "가격 12,345엔")
    }

    @Test func overlappingDistinctPricePartsAreNotDeduplicated() {
        let label = presentationSegment(
            rect: CGRect(x: 210, y: 500, width: 80, height: 30),
            source: "価格",
            translation: "가격"
        )
        let amount = presentationSegment(
            rect: CGRect(x: 230, y: 500, width: 122, height: 30),
            source: "12,345円",
            translation: "12,345엔"
        )
        let confidence = presentationSegment(
            rect: CGRect(x: 260, y: 500, width: 70, height: 30),
            source: "95%",
            translation: "95%"
        )

        let unique = BrowserOverlayPresentationDeduplicator.deduplicate([
            label,
            amount,
            confidence,
        ])
        #expect(unique.count == 3)
    }

    @Test func narrowVerticalSourceGetsReadableHorizontalKoreanCard() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.textPlacement = .replace
        let source = CGRect(x: 220, y: 80, width: 24, height: 150)
        let plan = BrowserOverlayLayoutPlanner.plan(
            source: source,
            text: "세로 문장을 인식합니다",
            vertical: false,
            settings: settings,
            viewport: CGSize(width: 390, height: 715),
            occupied: [],
            sourceVertical: true
        )

        #expect(
            plan.maximumFontSize >=
                BrowserOverlayLayoutPlanner.minimumReadableHorizontalFontSize
        )
        #expect(
            plan.rect.width - plan.contentInsets.left -
                plan.contentInsets.right >=
                plan.maximumFontSize * 6
        )
        #expect(plan.rect.minX <= source.minX)
        #expect(plan.rect.maxX >= source.maxX)
        #expect(plan.rect.minY <= source.minY)
        #expect(plan.rect.maxY >= source.maxY)
    }

    @Test func longTranslationRemainsAttachedInsideTheImageRegion() {
        let source = CGRect(x: 220, y: 80, width: 24, height: 150)
        let viewport = CGSize(width: 390, height: 715)
        let plan = BrowserOverlayLayoutPlanner.plan(
            source: source,
            text: String(repeating: "세로문장을인식합니다", count: 40),
            vertical: false,
            settings: ReaderTranslationSettings.defaultOverlay,
            viewport: viewport,
            occupied: [],
            sourceVertical: true
        )
        #expect(!plan.rect.isNull)
        #expect(plan.rect.intersects(source))
        #expect(CGRect(origin: .zero, size: viewport).contains(plan.rect))
        #expect(plan.maximumFontSize >= BrowserOverlayLayoutPlanner.minimumReadableHorizontalFontSize)
    }

    @Test func readableReplacementKeepsTheExactSourceRect() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.textPlacement = .replace
        let source = CGRect(x: 24, y: 90, width: 132, height: 32)
        let plan = BrowserOverlayLayoutPlanner.plan(
            source: source,
            text: "설정 화면을",
            vertical: false,
            settings: settings,
            viewport: CGSize(width: 390, height: 715),
            occupied: []
        )

        #expect(
            plan.maximumFontSize >=
                BrowserOverlayLayoutPlanner.minimumAutoFontSize
        )
        #expect(plan.rect == source)
    }

    @Test func denseTwoColumnReplacementsDoNotExpandAcrossEachOther() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.textPlacement = .replace
        let sources = [
            CGRect(x: 20, y: 100, width: 142, height: 32),
            CGRect(x: 180, y: 100, width: 142, height: 32),
            CGRect(x: 20, y: 142, width: 142, height: 32),
            CGRect(x: 180, y: 142, width: 142, height: 32),
        ]
        let translations = [
            "설정 화면을",
            "번역 화면을",
            "자막을 표시합니다",
            "작은 글자와 대비",
        ]
        var occupied: [CGRect] = []
        var plans: [BrowserOverlayCardLayout] = []

        for (index, source) in sources.enumerated() {
            let plan = BrowserOverlayLayoutPlanner.plan(
                source: source,
                text: translations[index],
                vertical: false,
                settings: settings,
                viewport: CGSize(width: 390, height: 715),
                occupied: occupied,
                reservedSources: sources.enumerated().compactMap {
                    otherIndex, rect in
                    otherIndex == index ? nil : rect
                }
            )
            plans.append(plan)
            occupied.append(plan.rect)
        }

        #expect(plans.map(\.rect) == sources)
        for left in plans.indices {
            for right in plans.indices where right > left {
                #expect(
                    plans[left].rect.intersection(plans[right].rect).isNull
                )
            }
        }
    }

    @Test func largerConstrainedCardClaimsSpaceBeforeSmallerNeighbor() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.textPlacement = .replace
        let viewport = CGSize(width: 210, height: 400)
        let sources = [
            CGRect(x: 110, y: 80, width: 20, height: 100),
            CGRect(x: 145, y: 60, width: 20, height: 280),
        ]
        let variants = [
            BrowserOverlayDisplayVariant.plain("응…… 네……", vertical: false),
            BrowserOverlayDisplayVariant.plain(
                "그만 먹고 쓴 돈이니까 즐겁게 해줘야 한다?",
                vertical: false
            ),
        ]
        let intrinsic = [
            BrowserOverlayCardLayout(
                rect: CGRect(x: 50, y: 60, width: 90, height: 140),
                maximumFontSize: 14,
                contentInsets: .zero
            ),
            BrowserOverlayCardLayout(
                rect: CGRect(x: 130, y: 20, width: 75, height: 350),
                maximumFontSize: 14,
                contentInsets: .zero
            ),
        ]

        func plans(in order: [Int]) -> [BrowserOverlayCardLayout] {
            var occupied: [CGRect] = []
            var result = intrinsic
            for index in order {
                let plan = BrowserOverlayLayoutPlanner.resolvePositionedLayout(
                    intrinsic[index],
                    source: sources[index],
                    variants: [variants[index]],
                    settings: settings,
                    viewport: viewport,
                    occupied: occupied,
                    sourceVertical: false,
                    singleVerticalColumn: false,
                    reservedSources: sources.enumerated().compactMap {
                        otherIndex, rect in
                        otherIndex == index ? nil : rect
                    }
                )
                result[index] = plan
                occupied.append(plan.rect)
            }
            return result
        }

        let packingOrder = BrowserOverlayLayoutPlanner.packingOrder(intrinsic)
        let packedPlans = plans(in: packingOrder)

        #expect(packingOrder == [1, 0])
        let overlap = packedPlans[0].rect.intersection(packedPlans[1].rect)
        #expect(
            overlap.isNull || overlap.width <= 0.25 || overlap.height <= 0.25
        )
        #expect(packedPlans[0].rect.minX == 40)
        #expect(packedPlans[1].rect.minX == 130)
        #expect(packedPlans[0].rect.size == intrinsic[0].rect.size)
        #expect(packedPlans[1].rect.size == intrinsic[1].rect.size)
        #expect(packedPlans[0].rect.contains(sources[0]))
        #expect(packedPlans[1].rect.contains(sources[1]))
    }

    @Test func fourCardClusterReflowsAfterGreedyOverlapWhenSpaceExists() {
        let viewport = CGSize(width: 470, height: 450)
        let sources = [
            CGRect(x: 70, y: 70, width: 20, height: 60),
            CGRect(x: 180, y: 100, width: 20, height: 240),
            CGRect(x: 270, y: 90, width: 20, height: 220),
            CGRect(x: 370, y: 100, width: 20, height: 250),
        ]
        let intrinsic = [
            BrowserOverlayCardLayout(
                rect: CGRect(x: 25, y: 50, width: 105, height: 105),
                maximumFontSize: 14,
                contentInsets: .zero
            ),
            BrowserOverlayCardLayout(
                rect: CGRect(x: 133, y: 50, width: 110, height: 374),
                maximumFontSize: 14,
                contentInsets: .zero
            ),
            BrowserOverlayCardLayout(
                rect: CGRect(x: 241, y: 50, width: 88, height: 310),
                maximumFontSize: 14,
                contentInsets: .zero
            ),
            BrowserOverlayCardLayout(
                rect: CGRect(x: 306, y: 50, width: 139, height: 349),
                maximumFontSize: 14,
                contentInsets: .zero
            ),
        ]

        func positiveOverlapArea(
            _ layouts: [BrowserOverlayCardLayout]
        ) -> CGFloat {
            var area: CGFloat = 0
            for left in layouts.indices {
                for right in layouts.indices where right > left {
                    let overlap = layouts[left].rect.intersection(
                        layouts[right].rect
                    )
                    if !overlap.isNull,
                       overlap.width > 0.25,
                       overlap.height > 0.25
                    {
                        area += overlap.width * overlap.height
                    }
                }
            }
            return area
        }

        let initialArea = positiveOverlapArea(intrinsic)
        let relaxedPlans = BrowserOverlayLayoutPlanner.relaxingCardPositions(
            intrinsic,
            sources: sources,
            viewport: viewport
        )

        #expect(initialArea > 0.25)
        #expect(positiveOverlapArea(relaxedPlans) <= 0.25)
        for index in relaxedPlans.indices {
            #expect(relaxedPlans[index].rect.size == intrinsic[index].rect.size)
            #expect(relaxedPlans[index].rect.contains(sources[index]))
            #expect(CGRect(origin: .zero, size: viewport).contains(
                relaxedPlans[index].rect
            ))
        }
    }

    @Test @MainActor
    func detachedTranslationsStayInsideOffsetSourceImage() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        let imageSize = CGSize(width: 300, height: 450)
        let sourceRect = CGRect(x: 35, y: 360, width: 300, height: 450)
        let items = (0..<4).map { index in
            BrowserOverlayItem(
                stableRegionID: UInt64(960 + index),
                rect: CGRect(
                    x: 160 + CGFloat(index) * 6,
                    y: 50,
                    width: 20,
                    height: 150
                ),
                sourceText: "原文\(index + 1)",
                translatedText: "번역 \(index + 1)",
                confidence: 0.99,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: false
            )
        }

        let payload = NativeTranslationLayoutPlanner.payload(
            items: items,
            imageSize: imageSize,
            sourceRect: sourceRect,
            settings: settings,
            targetLanguage: "ko",
            viewport: CGSize(width: 390, height: 844)
        )
        let frames = payload.compactMap { item -> CGRect? in
            guard let x = item["x"] as? CGFloat,
                  let y = item["y"] as? CGFloat,
                  let width = item["width"] as? CGFloat,
                  let height = item["height"] as? CGFloat
            else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }

        #expect(frames.count == items.count)
        for frame in frames {
            #expect(sourceRect.contains(frame))
        }
        for left in frames.indices {
            for right in frames.indices where right > left {
                let overlap = frames[left].intersection(frames[right])
                #expect(
                    overlap.isNull ||
                        overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
    }

    @Test
    func jointPackingLimitsTheWorstIndividualCardTravel() {
        let sourceRects = (0..<4).map { index in
            CGRect(
                x: 220 + CGFloat(index) * 6,
                y: 100,
                width: 46,
                height: 120
            )
        }
        let layouts = sourceRects.map { source in
            BrowserOverlayCardLayout(
                rect: source,
                maximumFontSize: 12,
                contentInsets: .zero
            )
        }

        let packed = BrowserOverlayLayoutPlanner.relaxingCardPositions(
            layouts,
            sources: sourceRects,
            viewport: CGSize(width: 390, height: 300),
            placementBounds: CGRect(x: 35, y: 80, width: 300, height: 180),
            allowsDetachedPlacements: Array(repeating: true, count: 4)
        )

        #expect(packed.count == layouts.count)
        for left in packed.indices {
            let dx = packed[left].rect.midX - layouts[left].rect.midX
            let dy = packed[left].rect.midY - layouts[left].rect.midY
            #expect(hypot(dx, dy) <= 75)
            for right in packed.indices where right > left {
                let overlap = packed[left].rect.intersection(
                    packed[right].rect
                )
                #expect(
                    overlap.isNull ||
                        overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
    }

    @Test
    func adjacentCardsShiftTogetherInsteadOfEjectingTheLastCard() {
        let xPositions: [CGFloat] = [100, 142, 184, 226, 250]
        let sourceRects = xPositions.map { x in
            CGRect(x: x, y: 100, width: 40, height: 120)
        }
        let layouts = sourceRects.map { source in
            BrowserOverlayCardLayout(
                rect: source,
                maximumFontSize: 12,
                contentInsets: .zero
            )
        }

        let packed = BrowserOverlayLayoutPlanner.relaxingCardPositions(
            layouts,
            sources: sourceRects,
            viewport: CGSize(width: 390, height: 300),
            placementBounds: CGRect(x: 80, y: 80, width: 216, height: 180),
            allowsDetachedPlacements: Array(repeating: true, count: 5)
        )

        var movedCards = 0
        for left in packed.indices {
            let dx = packed[left].rect.midX - layouts[left].rect.midX
            let dy = packed[left].rect.midY - layouts[left].rect.midY
            if hypot(dx, dy) > 1 { movedCards += 1 }
            #expect(hypot(dx, dy) <= 22)
            #expect(abs(dy) <= 1)
            for right in packed.indices where right > left {
                let overlap = packed[left].rect.intersection(
                    packed[right].rect
                )
                #expect(
                    overlap.isNull ||
                        overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
        #expect(movedCards >= 4)
    }

    @Test
    func jointPackingNeverKeepsAnOverlapAtTheFormerTravelLimit() {
        let sourceRects = [
            CGRect(x: 110, y: 80, width: 104, height: 180),
            CGRect(x: 138, y: 96, width: 48, height: 70),
            CGRect(x: 216, y: 80, width: 58, height: 180),
        ]
        let layouts = sourceRects.map { source in
            BrowserOverlayCardLayout(
                rect: source,
                maximumFontSize: 12,
                contentInsets: .zero
            )
        }

        let packed = BrowserOverlayLayoutPlanner.relaxingCardPositions(
            layouts,
            sources: sourceRects,
            viewport: CGSize(width: 390, height: 300),
            placementBounds: CGRect(x: 40, y: 40, width: 310, height: 240),
            allowsDetachedPlacements: Array(repeating: true, count: 3)
        )

        for left in packed.indices {
            for right in packed.indices where right > left {
                let overlap = packed[left].rect.intersection(
                    packed[right].rect
                )
                #expect(
                    overlap.isNull ||
                        overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
    }

    @Test
    func jointPackingReplacesAnAlreadyScatteredGreedyLayout() {
        let preferredRects = (0..<4).map { index in
            CGRect(
                x: 180 + CGFloat(index) * 6,
                y: 100,
                width: 40,
                height: 120
            )
        }
        let scatteredRects = (0..<4).map { index in
            CGRect(
                x: 40 + CGFloat(index) * 70,
                y: 100,
                width: 40,
                height: 120
            )
        }
        let layouts = scatteredRects.map { rect in
            BrowserOverlayCardLayout(
                rect: rect,
                maximumFontSize: 12,
                contentInsets: .zero
            )
        }

        let packed = BrowserOverlayLayoutPlanner.relaxingCardPositions(
            layouts,
            sources: preferredRects,
            viewport: CGSize(width: 390, height: 300),
            placementBounds: CGRect(x: 20, y: 40, width: 350, height: 240),
            preferredRects: preferredRects,
            allowsDetachedPlacements: Array(repeating: true, count: 4)
        )

        let ordered = packed.map(\.rect).sorted { $0.minX < $1.minX }
        for index in ordered.indices.dropFirst() {
            #expect(ordered[index].minX - ordered[index - 1].maxX <= 2.25)
        }
        let sourceCentroid = CGPoint(
            x: preferredRects.reduce(CGFloat.zero) { $0 + $1.midX } / 4,
            y: preferredRects.reduce(CGFloat.zero) { $0 + $1.midY } / 4
        )
        let packedCentroid = CGPoint(
            x: packed.reduce(CGFloat.zero) { $0 + $1.rect.midX } / 4,
            y: packed.reduce(CGFloat.zero) { $0 + $1.rect.midY } / 4
        )
        #expect(abs(packedCentroid.x - sourceCentroid.x) <= 4)
        #expect(abs(packedCentroid.y - sourceCentroid.y) <= 4)
        for left in packed.indices {
            for right in packed.indices where right > left {
                let overlap = packed[left].rect.intersection(
                    packed[right].rect
                )
                #expect(
                    overlap.isNull ||
                        overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
    }

    @Test
    func sitePageNineUsesDynamicNeighborSlotsForShorterChainShift() {
        let sources = [
            CGRect(x: 258.5635, y: 57.9889, width: 20.1563, height: 99.0474),
            CGRect(x: 301.0433, y: 58.6391, width: 10.1865, height: 38.1452),
            CGRect(x: 341.3558, y: 57.9889, width: 11.4869, height: 126.7893),
            CGRect(x: 366.0635, y: 58.2056, width: 19.7228, height: 99.9143),
            CGRect(x: 292.3740, y: 61.0232, width: 18.6391, height: 61.3357),
            CGRect(x: 267.4496, y: 128.8609, width: 10.4032, height: 51.7994),
            CGRect(x: 292.3740, y: 130.5948, width: 9.7530, height: 46.5978),
        ]
        let preferred = [
            CGRect(x: 246.7816, y: 57.9889, width: 43.72, height: 99.0474),
            CGRect(x: 288.1366, y: 58.6391, width: 36, height: 38.1452),
            CGRect(x: 329.0993, y: 57.9889, width: 36, height: 126.7893),
            CGRect(x: 354.0949, y: 58.2056, width: 43.66, height: 99.9143),
            CGRect(x: 283.6635, y: 61.0232, width: 36.06, height: 61.3357),
            CGRect(x: 260.1512, y: 128.8609, width: 25, height: 51.7994),
            CGRect(x: 279.2505, y: 130.5948, width: 36, height: 46.5978),
        ]
        let greedyRects = [
            CGRect(x: 258.5635, y: 57.9889, width: 20.1563, height: 99.0474),
            CGRect(x: 301.0433, y: 58.6391, width: 19, height: 38.1452),
            CGRect(x: 329.0993, y: 57.9889, width: 36, height: 126.7893),
            CGRect(x: 366.0635, y: 58.2056, width: 43.66, height: 99.9143),
            CGRect(x: 291.9531, y: 61.0232, width: 19.06, height: 61.3357),
            CGRect(x: 267.4496, y: 128.8609, width: 19, height: 51.7994),
            CGRect(x: 279.2505, y: 130.5948, width: 36, height: 46.5978),
        ]
        let previousJoint = [
            CGRect(x: 258.5635, y: 57.9889, width: 20.1563, height: 99.0474),
            CGRect(x: 296.6366, y: 20.8780, width: 19, height: 38.1452),
            CGRect(x: 318, y: 57.9889, width: 36, height: 126.7893),
            CGRect(x: 354.0949, y: 58.2056, width: 43.66, height: 99.9143),
            CGRect(x: 292.1635, y: 61.0232, width: 19.06, height: 61.3357),
            CGRect(x: 237.5635, y: 128.8609, width: 19, height: 51.7994),
            CGRect(x: 279.2505, y: 130.5948, width: 36, height: 46.5978),
        ]
        let layouts = greedyRects.map { rect in
            BrowserOverlayCardLayout(
                rect: rect,
                maximumFontSize: 12,
                contentInsets: .zero
            )
        }

        let packed = BrowserOverlayLayoutPlanner.relaxingCardPositions(
            layouts,
            sources: sources,
            viewport: CGSize(width: 430, height: 715),
            placementBounds: CGRect(x: 0, y: 0, width: 430, height: 715),
            preferredRects: preferred,
            allowsDetachedPlacements: Array(repeating: true, count: layouts.count)
        )
        func totalSquaredMovement(_ rects: [CGRect]) -> CGFloat {
            zip(rects, preferred).reduce(CGFloat.zero) { total, pair in
                let dx = pair.0.midX - pair.1.midX
                let dy = pair.0.midY - pair.1.midY
                return total + dx * dx + dy * dy
            }
        }

        #expect(
            totalSquaredMovement(packed.map(\.rect)) + 0.25 <
                totalSquaredMovement(previousJoint)
        )
        let sourceAlignedTopRow = [0, 4, 1, 2, 3]
        for index in sourceAlignedTopRow {
            #expect(abs(packed[index].rect.minY - preferred[index].minY) <= 2)
        }
        for position in sourceAlignedTopRow.indices.dropFirst() {
            let previous = sourceAlignedTopRow[position - 1]
            let current = sourceAlignedTopRow[position]
            #expect(packed[previous].rect.maxX <= packed[current].rect.minX)
        }
        for left in packed.indices {
            for right in packed.indices where right > left {
                let overlap = packed[left].rect.intersection(
                    packed[right].rect
                )
                #expect(
                    overlap.isNull ||
                        overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
    }

    @Test
    func sourceRowRestoresOrderAfterGreedyAlreadyRemovedOverlap() {
        let preferred = [
            CGRect(x: 76, y: 130, width: 104, height: 245),
            CGRect(x: 190, y: 130, width: 66, height: 188),
        ]
        let greedilyEjected = [
            CGRect(x: 76, y: 130, width: 104, height: 245),
            CGRect(x: 0, y: 130, width: 66, height: 188),
        ]
        let layouts = greedilyEjected.map {
            BrowserOverlayCardLayout(
                rect: $0,
                maximumFontSize: 12,
                contentInsets: .zero
            )
        }
        let packed = BrowserOverlayLayoutPlanner.relaxingCardPositions(
            layouts,
            sources: preferred,
            viewport: CGSize(width: 430, height: 715),
            placementBounds: CGRect(x: 0, y: 0, width: 430, height: 536),
            preferredRects: preferred,
            allowsDetachedPlacements: [true, true]
        )

        #expect(packed[0].rect.maxX <= packed[1].rect.minX)
        #expect(abs(packed[0].rect.minY - preferred[0].minY) <= 0.25)
        #expect(abs(packed[1].rect.minY - preferred[1].minY) <= 0.25)
    }

    @Test
    func sitePageFifteenRepacksTheWholeTopRowBeforeEjectingCards() {
        let sources = [
            CGRect(x: 45.51, y: 57.34, width: 18.21, height: 126.57),
            CGRect(x: 95.15, y: 56.04, width: 10.19, height: 105.12),
            CGRect(x: 119.85, y: 56.04, width: 10.40, height: 84.09),
            CGRect(x: 144.99, y: 56.26, width: 18.21, height: 97.75),
            CGRect(x: 185.74, y: 56.04, width: 18.86, height: 146.73),
            CGRect(x: 218.47, y: 55.82, width: 11.49, height: 36.84),
            CGRect(x: 243.83, y: 56.26, width: 27.09, height: 139.36),
            CGRect(x: 285.22, y: 56.26, width: 27.09, height: 97.96),
            CGRect(x: 326.18, y: 56.04, width: 11.27, height: 84.31),
            CGRect(x: 351.33, y: 59.07, width: 18.64, height: 95.15),
            CGRect(x: 377.12, y: 58.86, width: 16.69, height: 80.41),
        ]
        let preferred = [
            CGRect(x: 34.37, y: 57.34, width: 40.50, height: 126.57),
            CGRect(x: 82.24, y: 56.04, width: 36.00, height: 105.12),
            CGRect(x: 107.06, y: 56.04, width: 36.00, height: 84.09),
            CGRect(x: 133.85, y: 56.26, width: 40.50, height: 97.75),
            CGRect(x: 174.13, y: 56.04, width: 42.08, height: 146.73),
            CGRect(x: 206.21, y: 55.82, width: 36.00, height: 36.84),
            CGRect(x: 232.88, y: 56.26, width: 48.98, height: 139.36),
            CGRect(x: 275.06, y: 56.26, width: 47.41, height: 97.96),
            CGRect(x: 313.82, y: 56.04, width: 36.00, height: 84.31),
            CGRect(x: 339.68, y: 59.07, width: 41.94, height: 95.15),
            CGRect(x: 367.46, y: 58.86, width: 36.00, height: 80.41),
        ]
        let greedy = [
            CGRect(x: 34.37, y: 57.34, width: 40.50, height: 126.57),
            CGRect(x: 82.24, y: 56.04, width: 36.00, height: 105.12),
            CGRect(x: 133.85, y: 155.57, width: 19.00, height: 84.09),
            CGRect(x: 133.85, y: 55.82, width: 40.50, height: 97.75),
            CGRect(x: 174.13, y: 56.04, width: 42.08, height: 146.73),
            CGRect(x: 215.96, y: 18.49, width: 16.50, height: 36.84),
            CGRect(x: 228.08, y: 56.26, width: 48.98, height: 139.36),
            CGRect(x: 277.97, y: 56.26, width: 44.33, height: 97.96),
            CGRect(x: 326.06, y: 56.04, width: 11.52, height: 84.31),
            CGRect(x: 339.58, y: 59.07, width: 39.91, height: 95.15),
            CGRect(x: 380.00, y: 58.86, width: 36.00, height: 80.41),
        ]
        let layouts = greedy.map {
            BrowserOverlayCardLayout(
                rect: $0,
                maximumFontSize: 12,
                contentInsets: .zero
            )
        }
        let packed = BrowserOverlayLayoutPlanner.relaxingCardPositions(
            layouts,
            sources: sources,
            viewport: CGSize(width: 430, height: 715),
            placementBounds: CGRect(x: 0, y: 0, width: 430, height: 292.5),
            preferredRects: preferred,
            allowsDetachedPlacements: Array(repeating: true, count: 11)
        )

        #expect(abs(packed[2].rect.midY - preferred[2].midY) < 4)
        #expect(abs(packed[5].rect.midY - preferred[5].midY) < 4)
        let preferredBounds = preferred.dropFirst().reduce(preferred[0]) {
            $0.union($1)
        }
        let packedBounds = packed.dropFirst().reduce(packed[0].rect) {
            $0.union($1.rect)
        }
        #expect(abs(packedBounds.midX - preferredBounds.midX) < 5)
        for left in packed.indices {
            for right in packed.indices where right > left {
                let overlap = packed[left].rect.intersection(
                    packed[right].rect
                )
                #expect(
                    overlap.isNull ||
                        overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
    }

    @Test @MainActor
    func sitePageFifteenRealTranslationsPreferHorizontalRedistribution() {
        let sources = [
            CGRect(x: 45.51, y: 57.34, width: 18.21, height: 126.57),
            CGRect(x: 95.15, y: 56.04, width: 10.19, height: 105.12),
            CGRect(x: 119.85, y: 56.04, width: 10.40, height: 84.09),
            CGRect(x: 144.99, y: 56.26, width: 18.21, height: 97.75),
            CGRect(x: 185.74, y: 56.04, width: 18.86, height: 146.73),
            CGRect(x: 218.47, y: 55.82, width: 11.49, height: 36.84),
            CGRect(x: 243.83, y: 56.26, width: 27.09, height: 139.36),
            CGRect(x: 285.22, y: 56.26, width: 27.09, height: 97.96),
            CGRect(x: 326.18, y: 56.04, width: 11.27, height: 84.31),
            CGRect(x: 351.33, y: 59.07, width: 18.64, height: 95.15),
            CGRect(x: 377.12, y: 58.86, width: 16.69, height: 80.41),
        ]
        let translations = [
            "……아아, 정말 둔하다니까! 이리 내! 자, 전부 벗어!",
            "「그러니까 사과 안 해도 된다니까!」",
            "「미안…… 미안해……」",
            "자, 물 끓었으니까 얼른 몸 깨끗이 씻으렴!",
            "그런 건 내 일이야! 당신은 애들이나 돌보고 있으라고!",
            "\"아우...\"",
            "어차피 밀어붙여서 거절 못 한 거지? 맨날 그렇게 손해만 보고 말이야!",
            "정말! 왜 당신이 사과하는 건데! 사과해야 할 쪽은 나라고!",
            "\"미... 미안해...\"",
            "왜 그런 짓을 한 거야! 당신은 처음이란 말이야!",
            "이 멍청아!",
        ]
        let items = sources.indices.map { index in
            BrowserOverlayItem(
                stableRegionID: UInt64(15_000 + index),
                rect: sources[index],
                sourceText: "縦書き原文\(index)",
                translatedText: translations[index],
                confidence: 0.99,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: false
            )
        }
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        let payload = NativeTranslationLayoutPlanner.payload(
            items: items,
            imageSize: CGSize(width: 430, height: 322.5),
            sourceRect: CGRect(x: 0, y: 0, width: 430, height: 322.5),
            settings: settings,
            targetLanguage: "ko",
            viewport: CGSize(width: 430, height: 715)
        )
        #expect(payload.count == items.count)
        for index in payload.indices {
            let y = payload[index]["y"] as? CGFloat
            #expect(y != nil)
            if let y {
                #expect(abs(y - sources[index].minY) < 12)
            }
            #expect(payload[index]["vertical"] as? Bool == false)
        }
        let firstX = payload[0]["x"] as? CGFloat
        #expect(firstX != nil)
        if let firstX {
            #expect(abs(firstX - 34.3669) < 18)
        }
        let frames = payload.compactMap { entry -> CGRect? in
            guard let x = entry["x"] as? CGFloat,
                  let y = entry["y"] as? CGFloat,
                  let width = entry["width"] as? CGFloat,
                  let height = entry["height"] as? CGFloat
            else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        #expect(frames.count == payload.count)
        if let firstFrame = frames.first {
            let bounds = frames.dropFirst().reduce(firstFrame) {
                $0.union($1)
            }
            #expect(abs(bounds.midX - 218.9136) < 4)
        }
    }

    @Test
    func denseVerticalColumnsChooseWritingDirectionBeforeMovingCards() {
        let horizontal = [
            CGRect(x: 0, y: 20, width: 60, height: 120),
            CGRect(x: 5, y: 20, width: 60, height: 120),
            CGRect(x: 120, y: 20, width: 50, height: 120),
        ].map {
            BrowserOverlayCardLayout(
                rect: $0,
                maximumFontSize: 12,
                contentInsets: .zero
            )
        }
        let vertical = [
            0: BrowserOverlayCardLayout(
                rect: CGRect(x: -15, y: 20, width: 20, height: 120),
                maximumFontSize: 12,
                contentInsets: .zero
            ),
            1: BrowserOverlayCardLayout(
                rect: CGRect(x: 25, y: 20, width: 20, height: 120),
                maximumFontSize: 12,
                contentInsets: .zero
            ),
        ]

        let selected =
            BrowserOverlayLayoutPlanner.adaptiveVerticalTranslationIndices(
                horizontalLayouts: horizontal,
                verticalLayouts: vertical
            )

        #expect(selected == Set([0]))
    }

    @Test
    func minorDenseColumnOverlapDoesNotTriggerVerticalTranslation() {
        let horizontal = [
            CGRect(x: 0, y: 20, width: 60, height: 120),
            CGRect(x: 40, y: 20, width: 60, height: 120),
        ].map {
            BrowserOverlayCardLayout(
                rect: $0,
                maximumFontSize: 12,
                contentInsets: .zero
            )
        }
        let vertical = [
            0: BrowserOverlayCardLayout(
                rect: CGRect(x: 20, y: 20, width: 20, height: 120),
                maximumFontSize: 12,
                contentInsets: .zero
            ),
            1: BrowserOverlayCardLayout(
                rect: CGRect(x: 60, y: 20, width: 20, height: 120),
                maximumFontSize: 12,
                contentInsets: .zero
            ),
        ]

        #expect(
            BrowserOverlayLayoutPlanner.adaptiveVerticalTranslationIndices(
                horizontalLayouts: horizontal,
                verticalLayouts: vertical
            ).isEmpty
        )
    }

    @Test
    func separatedVerticalSourcesKeepKoreanTranslationHorizontal() {
        let horizontal = [
            CGRect(x: 0, y: 20, width: 40, height: 120),
            CGRect(x: 60, y: 20, width: 40, height: 120),
        ].map {
            BrowserOverlayCardLayout(
                rect: $0,
                maximumFontSize: 12,
                contentInsets: .zero
            )
        }
        let vertical = [
            0: BrowserOverlayCardLayout(
                rect: CGRect(x: 10, y: 20, width: 20, height: 120),
                maximumFontSize: 12,
                contentInsets: .zero
            ),
            1: BrowserOverlayCardLayout(
                rect: CGRect(x: 70, y: 20, width: 20, height: 120),
                maximumFontSize: 12,
                contentInsets: .zero
            ),
        ]

        #expect(
            BrowserOverlayLayoutPlanner.adaptiveVerticalTranslationIndices(
                horizontalLayouts: horizontal,
                verticalLayouts: vertical
            ).isEmpty
        )
    }

    @Test
    func adaptiveVerticalCandidateIsLimitedToNarrowKoreanReplacement() {
        let item = BrowserOverlayItem(
            rect: CGRect(x: 100, y: 50, width: 24, height: 160),
            sourceText: "「どうして謝るの」",
            translatedText: "왜 사과하는 거야",
            confidence: 0.99,
            sourceOrientation: .vertical,
            sourceSingleVerticalColumn: true
        )
        let horizontal = BrowserOverlayCardContent.make(
            item: item,
            mode: .translateOnly,
            sourceVertical: true,
            translatedVertical: false
        )

        let candidate = BrowserOverlayCardContent.adaptiveVerticalCandidate(
            item: item,
            current: horizontal,
            mode: .translateOnly,
            textPlacement: .replace,
            sourceVertical: true,
            sourceRect: item.rect
        )
        #expect(candidate?.displayed.vertical == true)
        #expect(BrowserOverlayCardContent.adaptiveVerticalCandidate(
            item: item,
            current: horizontal,
            mode: .translateOnly,
            textPlacement: .expanded,
            sourceVertical: true,
            sourceRect: item.rect
        ) == nil)
    }

    @Test func longTranslationExpandsAroundItsSourceWithoutClippingScreen() {
        var settings = ReaderTranslationSettings.defaultOverlay
        let source = CGRect(x: 120, y: 120, width: 42, height: 22)
        let plan = BrowserOverlayLayoutPlanner.plan(
            source: source,
            text: "자동 맞춤으로 배경이 함께 확장되어 잘리지 않습니다",
            vertical: false,
            settings: settings,
            viewport: CGSize(width: 390, height: 715),
            occupied: []
        )

        #expect(plan.maximumFontSize >= BrowserOverlayLayoutPlanner.minimumReadableHorizontalFontSize)
        #expect(plan.rect.width > source.width)
        #expect(plan.rect.height > source.height)
        #expect(plan.rect.minX >= 0)
        #expect(plan.rect.minY >= 0)
        #expect(plan.rect.maxX <= 390)
        #expect(plan.rect.maxY <= 715)
        #expect(plan.rect.contains(source))
    }

    @Test func replacementPlannerUsesUIKitMeasurementWithoutClipping() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.textPlacement = .replace
        let text = "Open the AidokuReader settings screen."
        let plan = BrowserOverlayLayoutPlanner.plan(
            source: CGRect(x: 120, y: 120, width: 42, height: 22),
            text: text,
            vertical: false,
            settings: settings,
            viewport: CGSize(width: 390, height: 715),
            occupied: []
        )

        #expect(BrowserOverlayLayoutPlanner.horizontalTextFits(
            text,
            available: CGSize(
                width: plan.rect.width -
                    plan.contentInsets.left - plan.contentInsets.right,
                height: plan.rect.height -
                    plan.contentInsets.top - plan.contentInsets.bottom
            ),
            fontSize: plan.maximumFontSize
        ))
    }

    @Test func shortTranslationCanUseAReadableLargeAutoFont() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.textPlacement = .replace
        let plan = BrowserOverlayLayoutPlanner.plan(
            source: CGRect(x: 24, y: 90, width: 180, height: 56),
            text: "설정 화면",
            vertical: false,
            settings: settings,
            viewport: CGSize(width: 390, height: 715),
            occupied: []
        )

        #expect(plan.maximumFontSize >= 28)
    }

    @Test @MainActor
    func impossibleForcedLinesRejectWithoutShapingTheWholeResponse() {
        let cache = BrowserOverlayTextMeasurementCache()
        let text = BrowserOverlayTextFlow.verticalized(String(repeating: "가", count: 6_000))
        let variant = BrowserOverlayDisplayVariant.plain(text, vertical: true)
        #expect(!variant.fits(available: CGSize(width: 40, height: 250), fontSize: 5, measurementCache: cache))
        #expect(cache.passStatistics.misses == 0)
        // Check the conservative bound against the original exact measurement
        // for both fitting and non-fitting strings, including explicit blank lines.
        for vertical in [false, true] {
            for sample in ["가", "가\n나", "가\n\n나", "가\n나\n다\n라"] {
                let candidate = BrowserOverlayDisplayVariant.plain(sample, vertical: vertical)
                for height in [CGFloat(4), 10, 20, 50] {
                    let measured = candidate.measuredSize(width: 40, fontSize: 5)
                    let expected = measured.width <= 40.5 && measured.height <= height + 0.5
                    #expect(candidate.fits(available: CGSize(width: 40, height: height), fontSize: 5) == expected)
                }
            }
        }
    }

    @Test func wrappedTwoColumnGroupsStaySeparateAndDoNotOverlap() throws {
        var segments: [BrowserOverlayPresentationSegment] = []
        let translations = ["Open the", "settings", "screen."]
        for (column, x) in [CGFloat(20), CGFloat(210)].enumerated() {
            for row in translations.indices {
                segments.append(presentationSegment(
                    rect: CGRect(
                        x: x,
                        y: 100 + CGFloat(row) * 28,
                        width: 128 - CGFloat(row) * 10,
                        height: 24
                    ),
                    source: "source-\(column)-\(row)",
                    translation: translations[row]
                ))
            }
        }
        let groups = BrowserOverlayPresentationGrouper.groups(segments)
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.segments.count == 3 })

        var settings = ReaderTranslationSettings.defaultOverlay
        settings.textPlacement = .replace
        var occupied: [CGRect] = []
        var plans: [BrowserOverlayCardLayout] = []
        for (index, group) in groups.enumerated() {
            let plan = BrowserOverlayLayoutPlanner.plan(
                source: group.sourceBounds,
                text: try #require(group.overlayItem.translatedText),
                vertical: false,
                settings: settings,
                viewport: CGSize(width: 390, height: 715),
                occupied: occupied,
                reservedSources: groups.enumerated().compactMap {
                    $0.offset == index ? nil : $0.element.sourceBounds
                }
            )
            plans.append(plan)
            occupied.append(plan.rect)
        }
        #expect(plans.count == 2)
        #expect(plans[0].rect.intersection(plans[1].rect).isNull)
        #expect(!plans[0].rect.intersects(groups[1].sourceBounds))
        #expect(!plans[1].rect.intersects(groups[0].sourceBounds))
    }

    @Test @MainActor
    func positionedCollisionDependenciesExcludeDistantCards() {
        var settings = ReaderTranslationSettings.defaultOverlay
        let intrinsic = BrowserOverlayCardLayout(
            rect: CGRect(x: 70, y: 90, width: 100, height: 60),
            maximumFontSize: 14,
            contentInsets: BrowserOverlayCardTextInsets.regular
        )
        let dependencies = BrowserOverlayLayoutPlanner.collisionDependencies(
            intrinsicLayout: intrinsic,
            source: CGRect(x: 100, y: 100, width: 40, height: 40),
            variants: [.plain("translated", vertical: false)],
            settings: settings,
            viewport: CGSize(width: 390, height: 715),
            occupied: [
                BrowserOverlayPositionedCollisionDependency(
                    key: "near",
                    rect: CGRect(x: 130, y: 100, width: 40, height: 40)
                ),
                BrowserOverlayPositionedCollisionDependency(
                    key: "far",
                    rect: CGRect(x: 280, y: 500, width: 50, height: 50)
                ),
            ],
            sourceVertical: false,
            singleVerticalColumn: false
        )
        #expect(dependencies.map(\.key) == ["near"])
    }

    @Test @MainActor
    func overlayTextMeasurementsAreMemoizedExactly() {
        let cache = BrowserOverlayTextMeasurementCache()
        let variant = BrowserOverlayDisplayVariant.plain(
            "설정 화면을 여세요",
            vertical: false
        )
        cache.beginPass()
        let first = variant.measuredSize(
            width: 132,
            fontSize: 14,
            measurementCache: cache
        )
        let afterFirst = cache.passStatistics
        let second = variant.measuredSize(
            width: 132,
            fontSize: 14,
            measurementCache: cache
        )
        let afterSecond = cache.passStatistics

        #expect(first == second)
        #expect(afterFirst.misses > 0)
        #expect(afterSecond.misses == afterFirst.misses)
        #expect(afterSecond.hits > afterFirst.hits)

        _ = variant.measuredSize(
            width: 133,
            fontSize: 14,
            measurementCache: cache
        )
        #expect(cache.passStatistics.misses > afterSecond.misses)
    }

    @MainActor
    private func button(
        in view: UIView,
        identifier: String
    ) -> UIButton? {
        if let button = view as? UIButton,
           button.accessibilityIdentifier == identifier
        {
            return button
        }
        for subview in view.subviews {
            if let match = button(in: subview, identifier: identifier) {
                return match
            }
        }
        return nil
    }

    private func overlayItem(
        source: String,
        translation: String?
    ) -> BrowserOverlayItem {
        BrowserOverlayItem(
            rect: CGRect(x: 1, y: 2, width: 30, height: 12),
            sourceText: source,
            translatedText: translation,
            confidence: 0.98
        )
    }

    private func presentationSegment(
        rect: CGRect,
        source: String,
        translation: String?
    ) -> BrowserOverlayPresentationSegment {
        BrowserOverlayPresentationSegment(
            sourceRect: rect,
            sourceText: source,
            translatedText: translation,
            confidence: 0.98,
            sourceVertical: false,
            translatedVertical: false,
            displayVertical: false
        )
    }

    @MainActor
    private func view(
        in root: UIView,
        identifier: String
    ) -> UIView? {
        if root.accessibilityIdentifier == identifier {
            return root
        }
        for subview in root.subviews {
            if let match = view(in: subview, identifier: identifier) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func replacementBackdrop(in card: UIView) -> UIVisualEffectView? {
        view(
            in: card,
            identifier: "aidoku.reader.overlay.item.backdrop"
        ) as? UIVisualEffectView
    }

    @MainActor
    private func replacementSurface(in card: UIView) -> UIView? {
        view(
            in: card,
            identifier: "aidoku.reader.overlay.item.surface"
        )
    }

    @MainActor
    private func views(
        in root: UIView,
        identifier: String
    ) -> [UIView] {
        var matches: [UIView] = []
        if root.accessibilityIdentifier == identifier {
            matches.append(root)
        }
        for subview in root.subviews {
            matches.append(contentsOf: views(
                in: subview,
                identifier: identifier
            ))
        }
        return matches
    }

    @MainActor
    private func firstLabel(in root: UIView) -> UILabel? {
        if let label = root as? UILabel {
            return label
        }
        for subview in root.subviews {
            if let match = firstLabel(in: subview) {
                return match
            }
        }
        return nil
    }

    private func colorsMatch(
        _ left: UIColor?,
        _ right: UIColor?,
        tolerance: CGFloat = 0.001
    ) -> Bool {
        switch (left, right) {
        case (nil, nil):
            return true
        case let (left?, right?):
            var leftRed: CGFloat = 0
            var leftGreen: CGFloat = 0
            var leftBlue: CGFloat = 0
            var leftAlpha: CGFloat = 0
            var rightRed: CGFloat = 0
            var rightGreen: CGFloat = 0
            var rightBlue: CGFloat = 0
            var rightAlpha: CGFloat = 0
            guard left.getRed(
                &leftRed,
                green: &leftGreen,
                blue: &leftBlue,
                alpha: &leftAlpha
            ), right.getRed(
                &rightRed,
                green: &rightGreen,
                blue: &rightBlue,
                alpha: &rightAlpha
            ) else {
                return left.isEqual(right)
            }
            return abs(leftRed - rightRed) <= tolerance &&
                abs(leftGreen - rightGreen) <= tolerance &&
                abs(leftBlue - rightBlue) <= tolerance &&
                abs(leftAlpha - rightAlpha) <= tolerance
        default:
            return false
        }
    }

    @MainActor
    private func displayedTextFits(
        _ label: UILabel,
        contentInsets: UIEdgeInsets = BrowserOverlayCardTextInsets.regular
    ) -> Bool {
        let available = label.bounds.inset(by: contentInsets)
        guard available.width > 0, available.height > 0 else {
            return false
        }
        let measured = label.textRect(
            forBounds: CGRect(origin: .zero, size: available.size),
            limitedToNumberOfLines: 0
        )
        return ceil(measured.width) <= available.width + 0.5 &&
            ceil(measured.height) <= available.height + 0.5
    }

    @MainActor
    private func alphaPixelBounds(
        of view: UIView,
        margin: Int
    ) -> CGRect? {
        view.layoutIfNeeded()
        let pixelWidth = max(1, Int(ceil(view.bounds.width)) + margin * 2)
        let pixelHeight = max(1, Int(ceil(view.bounds.height)) + margin * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(
            size: CGSize(
                width: CGFloat(pixelWidth),
                height: CGFloat(pixelHeight)
            ),
            format: format
        ).image { context in
            context.cgContext.translateBy(
                x: CGFloat(margin) - view.bounds.minX,
                y: CGFloat(margin) - view.bounds.minY
            )
            view.layer.render(in: context.cgContext)
        }
        guard let cgImage = image.cgImage,
              let frame = NativeOCRCGImageAdapter.makeRGBAFrame(from: cgImage)
        else { return nil }
        var minimumX = frame.width
        var minimumY = frame.height
        var maximumX = -1
        var maximumY = -1
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let alpha = frame.bytes[
                    y * frame.bytesPerRow + x * 4 + 3
                ]
                guard alpha > 2 else { continue }
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
            }
        }
        guard maximumX >= minimumX, maximumY >= minimumY else { return nil }
        return CGRect(
            x: CGFloat(minimumX),
            y: CGFloat(minimumY),
            width: CGFloat(maximumX - minimumX + 1),
            height: CGFloat(maximumY - minimumY + 1)
        )
    }

    private func image(color: UIColor) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 3))
        return renderer.image { context in
            color.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        }
    }

}
