import CoreGraphics
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
struct ReaderTranslationTests {
    @Test func unchangedTextKeepsSourcePixelsWithoutDroppingDialogueIDs() {
        let sources = ["18000", "١٢٣", "$60.00", "60Ko", "...", "Bang", "１２", "12"]
        let translations = ["18000", "١٢٣", "$60.00", "60Ko", "...", "Bang", "12", "열둘"]
        let regions = zip(sources, translations).enumerated().map { index, pair in
            ReaderTranslationRegion(id: "r-\(index)", rect: CGRect(x: 0, y: 0, width: 0.1, height: 0.1),
                                    source: pair.0, translation: pair.1)
        }
        let items = ReaderTranslationRegion.overlayItems(regions, imageSize: CGSize(width: 100, height: 100))
        #expect(items.compactMap(\.stableRegionID) == [6, 7])
        #expect(items.compactMap(\.translatedText) == Array(translations.dropFirst(6)))
        // Pending regions still participate in progressive identity matching.
        var pending = regions[0]
        pending.translation = nil
        #expect(!pending.preservesOriginalText)
    }

    @Test func restatedLatinLetteringKeepsSourcePixels() {
        // OCR-corrected logos, credits and UI labels: same letters, a few characters apart.
        let kept = [("MASULAD MAXIMUM", "MASULAO MAXIMUM"), ("MASLOMAXIMUM川", "MASULAO MAXIMUM"), ("MAMIsKITCHEN", "MAMI'S KITCHEN"),
                    ("Uideo Game", "Video Game"), ("A B", "A, B"), ("K.O", "K.O."), ("もう…！", "もう…!"), ("12:500", "12:50")]
        // Real translations, added words and other scripts still paint.
        let painted = [("Please open the door and come inside.", "translated:Please open the door and come inside."),
                       ("RAIDERS", "Splatoon"), ("Campus", "캠퍼스"), ("約10~15%", "10~15%"), ("伊58", "I-58"),
                       ("SAMPLE", "SAMPLE TEXT HERE"), ("Hi", "Hello"), ("ドン", "쾅")]
        for (source, translation) in kept {
            let region = ReaderTranslationRegion(id: source, rect: .zero, source: source, translation: translation)
            #expect(region.restatesOriginalText, "\(source) -> \(translation)")
            #expect(!region.preservesOriginalText)
        }
        for (source, translation) in painted {
            let region = ReaderTranslationRegion(id: source, rect: .zero, source: source, translation: translation)
            #expect(!region.restatesOriginalText, "\(source) -> \(translation)")
        }
        // Kept only when no painted neighbour's box overlaps it; exact copies are always kept.
        let regions = [
            ReaderTranslationRegion(id: "logo", rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05), source: "Uideo Game",
                                    translation: "Video Game"),
            ReaderTranslationRegion(id: "credit", rect: CGRect(x: 0.5, y: 0.5, width: 0.3, height: 0.05), source: "MASULAD MAXIMUM",
                                    translation: "MASULAO MAXIMUM"),
            ReaderTranslationRegion(id: "title", rect: CGRect(x: 0.5, y: 0.45, width: 0.3, height: 0.07), source: "夜の空",
                                    translation: "밤하늘"),
            ReaderTranslationRegion(id: "pending", rect: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.05), source: "BOOM")
        ]
        #expect(ReaderTranslationRegion.keepsOriginalLettering(regions) == [true, false, false, false])
        let items = ReaderTranslationRegion.overlayItems(regions, imageSize: CGSize(width: 100, height: 100))
        #expect(items.compactMap(\.stableRegionID) == [1, 2, 3])
    }

    @Test func repaintedLetteringPropagatesThroughOverlappingRestatements() {
        let regions = [
            ReaderTranslationRegion(id: "outer", rect: CGRect(x: 0.1, y: 0.1, width: 0.15, height: 0.05),
                                    source: "Uideo Game", translation: "Video Game"),
            ReaderTranslationRegion(id: "middle", rect: CGRect(x: 0.2, y: 0.1, width: 0.15, height: 0.05),
                                    source: "K.O", translation: "K.O."),
            ReaderTranslationRegion(id: "dialogue", rect: CGRect(x: 0.3, y: 0.1, width: 0.15, height: 0.05),
                                    source: "夜の空", translation: "밤하늘"),
            ReaderTranslationRegion(id: "exact", rect: CGRect(x: 0.1, y: 0.1, width: 0.15, height: 0.05),
                                    source: "LOGO", translation: "LOGO")
        ]
        #expect(ReaderTranslationRegion.keepsOriginalLettering(regions) == [false, false, false, true])
        // Classification must not depend on the input/reading order of the overlap chain.
        #expect(ReaderTranslationRegion.keepsOriginalLettering(Array(regions.reversed())) == [true, false, false, false])
        let items = ReaderTranslationRegion.layoutItems(regions, imageSize: CGSize(width: 100, height: 100))
        #expect(items.filter(\.keepsSourceLettering).map(\.stableRegionID) == [3])
    }

    @Test func keptLetteringIsReservedAndProtectedInTheLayout() throws {
        // diverse-1921: the SOUND! EUPHONIUM logo stays as printed right above a translated paragraph.
        let regions = [
            ReaderTranslationRegion(id: "logo", rect: CGRect(x: 0.087, y: 0.04, width: 0.302, height: 0.038),
                                    source: "SOUND! EUPHONIUM", translation: "SOUND! EUPHONIUM"),
            ReaderTranslationRegion(id: "paragraph", rect: CGRect(x: 0.066, y: 0.078, width: 0.341, height: 0.177),
                                    source: "From the classroom window, playing music",
                                    translation: "교실 창문에서 연주하는 음악 구절구절 이어가며 한 사람이라도 귀 기울이지 않으면 안 돼"),
            ReaderTranslationRegion(id: "pending", rect: CGRect(x: 0.5, y: 0.7, width: 0.2, height: 0.05), source: "BOOM")
        ]
        let size = CGSize(width: 850, height: 600)
        #expect(ReaderTranslationRegion.overlayItems(regions, imageSize: size).map(\.stableRegionID) == [1, 2])
        let items = ReaderTranslationRegion.layoutItems(regions, imageSize: size)
        #expect(items.map(\.stableRegionID) == [1, 2, 0])
        #expect(items.map(\.keepsSourceLettering) == [false, false, true])
        let viewport = CGSize(width: 402, height: 874)
        let sourceRect = CGRect(x: 0, y: 295.1, width: 402, height: 283.8)
        let payload = BrowserPageImageOverlayRenderer.layoutPayload(
            items: items, imageSize: size, sourceRect: sourceRect,
            settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko", viewport: viewport)
        // The logo is never typeset: it follows the captions as a protected-lettering descriptor.
        let captions = BrowserPageImageOverlayRenderer.layoutPayload(
            items: Array(items.prefix(2)), imageSize: size,
            sourceRect: sourceRect, settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko", viewport: viewport)
        #expect(payload.count == captions.count + 1)
        #expect(payload.dropLast().allSatisfy { $0["keptLettering"] == nil })
        let kept = try #require(payload.last)
        #expect(kept["keptLettering"] as? Bool == true)
        #expect(kept["id"] as? String == "kept-0")
        #expect(kept["text"] == nil)
        let bounds = try #require(kept["sourceBounds"] as? [CGFloat])
        #expect(abs(bounds[1] - 0.04) < 0.000_1 && abs(bounds[3] - 0.038) < 0.000_1)
        #expect((kept["sourceFontSize"] as? CGFloat ?? 0) > 0)
        #expect(kept["fontScript"] as? String == BrowserOverlayTextFlow.fontScript(for: "SOUND! EUPHONIUM").rawValue)
    }

    @Test func effectLetteringEvidenceIsNarrow() throws {
        // Source reads from dataset pages. Sound effects: effect katakana, effect glyphs, one glyph repeated.
        let effects = ["ギャ", "チッ", "ポーーン…", "ヒュー", "ドッカーン", "ゴゴゴ", "ワイワイ", "ハイハイ", "シーン！", "ドン", "ガチャン",
                       "ザワザワ", "キャー", "科科科科", "啪嗒..啪嗒.", "嗡嗡"]
        // Display candidates (effect lettering or a logo only when giant): short pieces, names, loanwords, gasps.
        let display = ["ドキ", "ズスン…", "ガチャンー", "カレー", "コーヒー", "ソーンズ", "ナギサ", "パパ", "ゴハン", "ウチ", "キララ",
                       "プロデューサー", "ブルーアーカイブ", "バッテリー", "ラムネ", "ティレル", "ラビーヤ", "オ", "ッ", "スイッチ", "はっ",
                       "はは", "どきどき", "でもっ", "ぎゅっ", "あ", "啦", "咳!", "驚", "Woooooo", "GOOOOOOD!!"]
        // Speech, captions, titles, particles, questions and word pieces never qualify.
        let never = ["アルセーヌルパン", "は", "を", "ちょうだい", "はえーよ", "んー？", "なーんて", "嗯~嗯~", "大丈夫大丈夫", "喔喔喔喔",
                     "收拾 收拾", "回神", "後悔", "瞥眼…", "熱海", "有種似層相識的感覺", "NOOOO!", "Uwaaaa.", "HAHAHA HA HAHA",
                     "SWITCH BATTERY", "I thought we'd be going.", "推しの子", "ゾワッ!すごいよ!", "", "!!", "ドキ?"]
        for source in effects {
            #expect(ReaderTranslationNonContentText.effectLettering(source, pageHasHiragana: false) == .soundEffect, "\(source)")
        }
        for source in display {
            #expect(ReaderTranslationNonContentText.effectLettering(source, pageHasHiragana: false) == .display, "\(source)")
        }
        for source in never {
            #expect(ReaderTranslationNonContentText.effectLettering(source, pageHasHiragana: false) == nil, "\(source)")
        }
        // On a Japanese page a lone kanji is a piece of a word or a label (美 of 美味, 妹); elsewhere an effect (驚, 拿).
        for source in ["驚", "妹", "料"] {
            #expect(ReaderTranslationNonContentText.effectLettering(source, pageHasHiragana: true) == nil)
        }
        #expect(ReaderTranslationNonContentText.effectLettering("嗡嗡", pageHasHiragana: true) == .soundEffect)

        // The payload carries the evidence; the Japanese-page test uses the page's other regions.
        let regions = [
            ReaderTranslationRegion(id: "sfx", rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), source: "驚", translation: "깜짝!"),
            ReaderTranslationRegion(id: "line", rect: CGRect(x: 0.5, y: 0.5, width: 0.3, height: 0.1), source: "這是什麼", translation: "이게 뭐야")
        ]
        let size = CGSize(width: 800, height: 1200)
        let items = ReaderTranslationRegion.layoutItems(regions, imageSize: size)
        let payload = BrowserPageImageOverlayRenderer.layoutPayload(
            items: items, imageSize: size,
            sourceRect: CGRect(x: 0, y: 100, width: 402, height: 603), settings: ReaderTranslationSettings.defaultOverlay,
            targetLanguage: "ko", viewport: CGSize(width: 402, height: 874))
        let roles = Dictionary(uniqueKeysWithValues: payload.compactMap { entry in
            (entry["text"] as? String).map { ($0, entry["sourceLettering"] as? String) }
        })
        #expect(roles["깜짝!"] == .some("display"))
        #expect(roles["이게 뭐야"] == .some(nil))
    }

    @Test func titleAndPieceLetteringEvidenceIsNarrow() throws {
        typealias Text = ReaderTranslationNonContentText
        // Titles and series logos: short kana/Han lettering on a title page, or in title brackets.
        for source in ["推しの子", "救世主", "かぐや様は告らせたい", "飛と龍子", "新進職員❤生存記！"] {
            #expect(Text.letteringRole(source, pageHasHiragana: true, pageHasCredits: true) == .title, "\(source)")
            #expect(Text.letteringRole(source, pageHasHiragana: true, pageHasCredits: false) == nil, "\(source)")
        }
        for source in ["【推しの子】", "メシア》"] {
            #expect(Text.letteringRole(source, pageHasHiragana: true, pageHasCredits: false) == .title, "\(source)")
        }
        // Sentences, questions, dates, credit vocabulary and Latin-only lettering never qualify as titles.
        for source in ["次回10月22日（木)更新予定。", "最新3巻", "新連載", "何だと？", "今日はいい天気ですね。", "QUESTユズ、弟子をとる",
                       "PERMARKET"] {
            #expect(Text.letteringRole(source, pageHasHiragana: true, pageHasCredits: true) == nil, "\(source)")
        }
        // Off a title page, other short words are no title (the overlay also needs 3x size, horizontal, no balloon).
        for source in ["お弁当", "ちょうだい", "止まら"] {
            #expect(Text.letteringRole(source, pageHasHiragana: true, pageHasCredits: false) == nil, "\(source)")
        }
        // Short kana pieces only join an effect they touch; effects keep their own role.
        for source in ["は", "ない", "ないよ", "啦啦"] {
            #expect(Text.letteringRole(source, pageHasHiragana: true, pageHasCredits: false) == .piece, "\(source)")
        }
        #expect(Text.letteringRole("ぱっ", pageHasHiragana: true, pageHasCredits: true) == .display)
        #expect(Text.letteringRole("ゴゴゴ", pageHasHiragana: true, pageHasCredits: true) == .soundEffect)
        // Only a repeated Han glyph is a piece; interjections and words are not.
        for source in ["嗯嗯", "收拾", "啦啦啦啦"] {
            #expect(Text.letteringRole(source, pageHasHiragana: false, pageHasCredits: false) != .piece, "\(source)")
        }
        // Title-page evidence.
        for (text, credits) in [("第98話", true), ("CHAPTER86", true), ("赤坂アカ原作", true), ("7月17日(金)発売予定!!", true), ("2話", true),
                                ("漫画家になりたい", false), ("お弁当すごい！", false)] {
            #expect(Text.containsTitleCredits(text) == credits, "\(text)")
        }

        // The payload carries the role; the title-page test uses the page's other regions.
        let regions = [
            ReaderTranslationRegion(id: "logo", rect: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.15), source: "推しの子", translation: "최애의 아이"),
            ReaderTranslationRegion(id: "credit", rect: CGRect(x: 0.5, y: 0.8, width: 0.3, height: 0.05), source: "第98話", translation: "제98화"),
            ReaderTranslationRegion(id: "piece", rect: CGRect(x: 0.2, y: 0.5, width: 0.1, height: 0.1), source: "は", translation: "파앗")
        ]
        let size = CGSize(width: 800, height: 1200)
        let items = ReaderTranslationRegion.layoutItems(regions, imageSize: size)
        let payload = BrowserPageImageOverlayRenderer.layoutPayload(
            items: items, imageSize: size,
            sourceRect: CGRect(x: 0, y: 100, width: 402, height: 603), settings: ReaderTranslationSettings.defaultOverlay,
            targetLanguage: "ko", viewport: CGSize(width: 402, height: 874))
        let roles = Dictionary(uniqueKeysWithValues: payload.compactMap { entry in
            (entry["text"] as? String).map { ($0, entry["sourceLettering"] as? String) }
        })
        #expect(roles["최애의 아이"] == .some("title"))
        #expect(roles["제98화"] == .some(nil))
        #expect(roles["파앗"] == .some("piece"))
    }

    @Test func watermarksAndNoticesKeepSourcePixels() {
        // OCR reads from dataset pages (misreadings included): kept whatever the translation says.
        let notices = ["SAMPLE", "SAMP", "SAMPLE SAMPLE MPLE", "無断転载禁止", "低新転载禁止", "AI学图禁止", "学習禁", "転載",
                       "無断耘載A I学习", "無断転載/無断使用/AI学習使用禁止", "@sinokc 0416key無断転載禁止", "無断転載禁止べェ~",
                       "AI学習自作発言", "複装·加工·転載", "Do not reupload my art", "Oo not reupload my art",
                       "REUPLOADING IS PROHIBITED", "Repost Al learning is RROHIBITED.", "No reuploading No AI trs",
                       "DO NOT USE MY ARTWORK", "Donotreuploadmyart. DonotusemyartforAltraining.", "jot Repost",
                       "@nikokosan", "@5ano4610", "Twitter @kedama_tori_ki Instagram-@aika.oz", "maite.co.jp",
                       "https://x.com/TMR15/status/1752676881613439037", "©higgstan.com", "©コオリヤマ",
                       "Copyright (C) 2025 IchiyaARISHIRO", "PATLUS oSEGA All rights reserved."]
        // Dialogue, signs, captions and credits that merely contain a notice word, handle or URL.
        let content = ["ウソつくの禁止", "立入禁止", "禁止令", "残念こないだコロッケも禁止されました～", "禁止", "Do not",
                       "DON'T DO THIS AGAIN, PASTILLE.", "Do NOT, under any circumstances, turn off the lights.",
                       "I'll repost your drawing tomorrow, okay?", "AI学習って何？", "無断で休むな", "確定同盟照断転载AI学",
                       "テレスコープアレイTAさん@アメリカユタ州", "にきり(@Chikuzen_twst) nikiri",
                       "秀丸@hidehidez122センター歌もダンスも下手くそで草",
                       "http://www.funyamora.com宇宙からヒマつぶしにやってきました!",
                       "©ダブリルムーン迷蝶(パンタレイ)3一明けの星は相ともに歌いー", "Here is a SAMPLE of our new product",
                       "SAMPLE TEXT HERE", "Campus", "CUP NOODLE"]
        for source in notices {
            #expect(ReaderTranslationNonContentText.isNotice(source), "\(source)")
        }
        for source in content {
            #expect(!ReaderTranslationNonContentText.isNotice(source), "\(source)")
        }

        // A vocabulary-only fragment is a notice only next to a whole one (tiled or split watermark).
        let rect = { (x: Double, y: Double) in CGRect(x: x, y: y, width: 0.2, height: 0.03) }
        let regions = [
            ReaderTranslationRegion(id: "notice", rect: rect(0.05, 0.50), source: "無断耘載A I学习", translation: "학습 금지."),
            ReaderTranslationRegion(id: "fragment", rect: rect(0.05, 0.46), source: "禁止", translation: "무단전재·AI"),
            ReaderTranslationRegion(id: "english", rect: rect(0.05, 0.54), source: "DO NOY USE MY ARTWORK.",
                                    translation: "DO NOT USE MY ARTWORK."),
            ReaderTranslationRegion(id: "far", rect: rect(0.6, 0.1), source: "禁止", translation: "금지!"),
            ReaderTranslationRegion(id: "dialogue", rect: rect(0.6, 0.8), source: "ウソつくの禁止", translation: "거짓말 금지!"),
            ReaderTranslationRegion(id: "pending", rect: rect(0.6, 0.9), source: "SAMPLE"),
            // A notice under a painted neighbour still paints: the neighbour's erasure would cut it.
            ReaderTranslationRegion(id: "covered", rect: rect(0.6, 0.62), source: "SAMPLE", translation: "샘플"),
            ReaderTranslationRegion(id: "speech", rect: rect(0.65, 0.63), source: "行こう", translation: "가자")
        ]
        #expect(ReaderTranslationRegion.keepsOriginalLettering(regions) == [true, true, true, false, false, false, false, false])
        let items = ReaderTranslationRegion.overlayItems(regions, imageSize: CGSize(width: 100, height: 100))
        #expect(items.compactMap(\.stableRegionID) == [3, 4, 5, 6, 7])

        // A misread piece of a tiled SAMPLE ("Sami") is kept on a page with an exact piece,
        // only when its translation also reads as SAMPLE; ordinary words still paint.
        let tile = { (x: Double, y: Double) in CGRect(x: x, y: y, width: 0.08, height: 0.05) }
        let tiled = [
            ReaderTranslationRegion(id: "exact", rect: tile(0.05, 0.02), source: "Samp", translation: "Sample"),
            ReaderTranslationRegion(id: "misread", rect: tile(0.9, 0.02), source: "Sami", translation: "Sample"),
            ReaderTranslationRegion(id: "korean", rect: tile(0.9, 0.3), source: "Sanple", translation: "샘플"),
            ReaderTranslationRegion(id: "word", rect: tile(0.5, 0.5), source: "Same", translation: "같아"),
            ReaderTranslationRegion(id: "speech", rect: tile(0.5, 0.8), source: "行こう", translation: "가자")
        ]
        #expect(ReaderTranslationRegion.keepsOriginalLettering(tiled) == [true, true, true, false, false])
        let untiled = Array(tiled.dropFirst())
        #expect(ReaderTranslationRegion.keepsOriginalLettering(untiled) == [false, false, false, false])
    }

    @Test func garbledNoticePiecesAndEdgePatternsKeepSourcePixels() {
        // Pixel boxes from dataset pages (844x1200 unless given), OCR reads as recognised.
        func region(_ id: String, _ box: [Double], _ source: String, _ translation: String? = "번역",
                    page: CGSize = CGSize(width: 844, height: 1200)) -> ReaderTranslationRegion {
            ReaderTranslationRegion(id: id, rect: CGRect(x: box[0] / page.width, y: box[1] / page.height,
                                                         width: box[2] / page.width, height: box[3] / page.height),
                                    source: source, translation: translation, sourceImageAspectRatio: page.width / page.height)
        }
        // diverse2-4155 / diverse-3401: pieces of 無断転載禁止 between two kept Latin notices.
        let block = [
            region("reupload", [54, 444, 152, 80], "REUPLOADING IS PROHIBITED", "무단"),
            region("zai", [125, 533, 26, 15], "载", "전재"),
            region("zhi", [160, 534, 21, 12], "止", "금지"),
            region("garbled", [100, 520, 38, 34], "学断工", "무단전재금지"),
            region("training", [59, 568, 141, 40], "No reuploading No AI training", "AI 학습 금지"),
            region("dialogue", [156, 641, 57, 31], "止まら", "멈추지"),
            region("word", [600, 900, 66, 54], "断言", "단언"),
            // A big misread SFX beside a small watermark is not a piece of it (diverse2-3253).
            region("sfx", [230, 420, 143, 146], "加", "파앗")
        ]
        #expect(ReaderTranslationRegion.keepsOriginalLettering(block) == [true, true, true, true, true, false, false, false])

        // diverse-3378: no whole Latin notice; 止 of 学習禁止 negates the misspelt "AI TRANING" line.
        let outlined = [
            region("zai", [530, 474, 246, 89], "載禁止", "전재 금지", page: CGSize(width: 849, height: 1200)),
            region("ai", [392, 604, 384, 115], "止AI TRANING", "금지 AI TRANING", page: CGSize(width: 849, height: 1200))
        ]
        #expect(ReaderTranslationRegion.keepsOriginalLettering(outlined) == [true, true])
        #expect(!ReaderTranslationNonContentText.isNotice("AI TRAINING"))
        #expect(!ReaderTranslationNonContentText.isNotice("載禁止"))

        // Garbled notice lines (two notice words, a few other kanji) versus sentences.
        for source in ["A学習自作共言", "無断転写学習"] {
            #expect(ReaderTranslationNonContentText.isNotice(source), "\(source)")
        }
        for source in ["自作の学習ノート", "学習と自作だ", "無断欠勤", "無断で休むな", "断言", "禁止"] {
            #expect(!ReaderTranslationNonContentText.isNotice(source), "\(source)")
        }
        #expect(ReaderTranslationNonContentText.isNoticeFragment("oduction and secondary"))
        #expect(!ReaderTranslationNonContentText.isNoticeFragment("LOAD"))
        #expect(!ReaderTranslationNonContentText.isNoticeFragment("works"))

        // diverse-0260 (1490x2000): "YURI TETSU" printed down both page borders, pieces as OCR read them.
        let border = CGSize(width: 1490, height: 2000)
        let left: [([Double], String)] = [
            ([62, 146, 161, 49], "TETSU"), ([118, 224, 106, 56], "YUP"), ([59, 324, 171, 297], "TETS YU TETS YU"),
            ([59, 661, 156, 56], "TETS"), ([56, 839, 83, 65], "TF"), ([59, 1016, 169, 145], "TETSI YU"),
            ([59, 1196, 141, 141], "TETS Y"), ([60, 1379, 93, 58], "TE")
        ]
        let right: [([Double], String)] = [
            ([1280, 62, 140, 36], "YURI"), ([1254, 144, 148, 53], "ETSU"), ([1269, 225, 155, 54], "YURIT"),
            ([1254, 324, 148, 57], "ETSU"), ([1254, 406, 172, 134], "YURIT ETSU"), ([1267, 563, 160, 57], "YURIT"),
            ([1253, 658, 176, 141], "ETSU YURIT")
        ]
        var page = (left + right).enumerated().map { region("p\($0.offset)", $0.element.0, $0.element.1, page: border) }
        page.append(region("gasp", [628, 510, 71, 158], "はあっ", "하아", page: border))
        page.append(region("plate", [992, 1737, 111, 48], "637D", "637D", page: border))
        page.append(region("sign", [700, 1300, 300, 60], "YURI TETSU", "유리 테츠", page: border))
        #expect(ReaderTranslationRegion.keepsOriginalLettering(page)
                == [Bool](repeating: true, count: left.count + right.count) + [false, true, false])

        // Repeated names or shouts are not ornament: speaker labels down the left edge are far apart,
        // and a repeated line in the page body is not along an edge.
        let labels = (0..<5).map { region("mika\($0)", [20, 100 + Double($0) * 220, 40, 25], "Mika", "미카") }
        let shouts = (0..<5).map { region("you\($0)", [300, 100 + Double($0) * 60, 90, 40], "YOU YOU", "너 너") }
        let lettered = labels + shouts
        #expect(ReaderTranslationRegion.keepsOriginalLettering(lettered) == [Bool](repeating: false, count: lettered.count))
    }

    @Test func occludedDocumentFinePrintStaysAsPrintedArt() async {
        let doc = OccludedDocumentFixtures.self
        // Pixel boxes and OCR reads from dataset pages (app OCR regions unless noted).
        func regions(_ rows: [([Double], String)], page: CGSize) -> [ReaderTranslationRegion] {
            rows.enumerated().map { index, row in
                let rect = CGRect(x: row.0[0] / page.width, y: row.0[1] / page.height,
                                  width: row.0[2] / page.width, height: row.0[3] / page.height)
                return ReaderTranslationRegion(id: "r\(index)", rect: rect, source: row.1,
                                               sourceImageAspectRatio: page.width / page.height)
            }
        }
        func marked(_ rows: [([Double], String)], _ width: Double, _ height: Double) async -> [Int] {
            let page = await ReaderTranslationNonContentText.markingOccludedDocumentText(regions(rows, page: CGSize(width: width, height: height)))
            return page.indices.filter { page[$0].isOccludedFinePrint }
        }
        func candidates(_ rows: [([Double], String)], _ width: Double, _ height: Double) -> Int {
            ReaderTranslationNonContentText.occludedDocumentCandidates(in: regions(rows, page: CGSize(width: width, height: height))).count
        }
        // Every contract piece, including the isolated scrap "Mu ed", stays as printed; the capital lettering
        // (balloons, captions, chapter logo) and the Japanese credits keep translating.
        #expect(await marked(doc.contract, 1350, 1920) == [6, 9, 11, 12, 13, 14, 15, 16, 17, 18, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29,
                                                       30, 32, 33, 34, 35, 36, 39])
        #expect(await marked(doc.report, 1350, 1920) == [1, 3, 5, 6, 7, 8, 9, 11])
        // Legible documents, UI posts and menus never reach the dictionary check.
        #expect(candidates(doc.posts, 1350, 1920) == 0)
        #expect(candidates(doc.menu, 2408, 1354) == 0)
        #expect(candidates(doc.feed, 1350, 1920) == 0)
        // Split mixed-case balloons and slang comments look like prose pieces, but their words are whole.
        #expect(candidates(doc.balloons, 1814, 1196) > 0)
        #expect(await marked(doc.balloons, 1814, 1196).isEmpty)
        #expect(candidates(doc.comments, 1221, 1729) > 0)
        #expect(await marked(doc.comments, 1221, 1729).isEmpty)
        // French dialogue is not English fine print.
        #expect(candidates(doc.french, 807, 1150) == 0)
        #expect(ReaderTranslationNonContentText.lowercaseWords(["What's she doing now?", "ract pertain-", "'quoted' Ai"])
                == ["she", "doing", "now", "ract", "pertain", "quoted"])

        // Kept like a notice once translated: no overlay item, and the flag survives the OCR/page caches.
        let size = CGSize(width: 1350, height: 1920)
        var page = await ReaderTranslationNonContentText.markingOccludedDocumentText(regions(doc.report, page: size))
        for index in page.indices { page[index].translation = "번역" }
        let items = Set(ReaderTranslationRegion.overlayItems(page, imageSize: size).compactMap(\.stableRegionID))
        #expect(items == Set([0, 2, 4, 10, 12, 13, 14, 15, 16]))
        let stored = page.map { ReaderTranslationStoredRegion($0).region }
        #expect(stored.map(\.isOccludedFinePrint) == page.map(\.isOccludedFinePrint))
        #expect(page[3].cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))?.isOccludedFinePrint == true)
    }

    @Test func keptLetteringOverlapIsTestedOnItsQuad() {
        // comic-8426 (1350x1920): a tilted phone number restated by the translation, beside a caption box that
        // only the empty corner of the number's axis-aligned bounds reaches.
        let page = CGSize(width: 1350, height: 1920)
        func region(_ id: String, _ quad: [[Double]], _ source: String, _ translation: String) -> ReaderTranslationRegion {
            let points = quad.map { CGPoint(x: $0[0] / page.width, y: $0[1] / page.height) }
            let xs = points.map(\.x), ys = points.map(\.y)
            let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            return ReaderTranslationRegion(id: id, rect: rect, source: source, translation: translation, polygon: points)
        }
        let number = region("number", [[170, 1524], [614, 1639], [573, 1797], [129, 1682]], "080-0988- masa-heaven",
                            "080-0988- masa-heaven-")
        let caption = region("caption", [[549, 1525], [667, 1525], [667, 1608], [549, 1608]], "AND ONE OF THEM WAS...",
                             "그리고 그중 한 명은...")
        #expect(number.rect.intersects(caption.rect))
        #expect(ReaderTranslationRegion.keepsOriginalLettering([number, caption]) == [true, false])
        // The tilted name above: the number's bounds reach into the name's bounds, the quads do not meet.
        let name = region("name", [[217, 1479], [504, 1551], [496, 1583], [210, 1510]], "KABURAGI MASAYA", "카부라기 마사야")
        #expect(number.rect.intersects(name.rect))
        #expect(ReaderTranslationRegion.keepsOriginalLettering([name, number, caption]) == [false, true, false])
        // A caption box that the drawn quad does reach still paints the restated lettering.
        let covering = region("covering", [[400, 1560], [520, 1560], [520, 1640], [400, 1640]], "AND ONE", "그리고")
        #expect(ReaderTranslationRegion.keepsOriginalLettering([number, covering]) == [false, false])
        // Without a quadrilateral the box is the lettering.
        var boxOnly = number
        boxOnly.polygon = []
        #expect(ReaderTranslationRegion.keepsOriginalLettering([boxOnly, caption]) == [false, false])
    }

    @Test func pageLetteringRequestsCarryTheNonContentPolicy() throws {
        let suite = "ReaderTranslationLetteringTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.sourceLanguage = "auto"
        settings.translationSourceLanguages = []
        let regions = [ReaderTranslationRegion(id: "sign", rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1), source: "BURGER MONSTER")]
        let requests = try ReaderTranslationService.requests(regions: regions, settings: settings)
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.translatesPageLettering == true })
        // The copy the prompt asks for keeps the printed logo: no overlay item.
        var copied = regions[0]
        copied.translation = "BURGER MONSTER"
        #expect(ReaderTranslationRegion.overlayItems([copied], imageSize: CGSize(width: 100, height: 100)).isEmpty)
    }

    @Test func aspectFitAndWebtoonCoordinates() {
        let region = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        #expect(ReaderTranslationGeometry.displayRect(
            region, imageSize: CGSize(width: 200, height: 400), bounds: bounds, aspectFit: true
        ) == CGRect(x: 150, y: 100, width: 100, height: 200))
        #expect(ReaderTranslationGeometry.displayRect(
            region, imageSize: CGSize(width: 200, height: 400), bounds: bounds, aspectFit: false
        ) == CGRect(x: 100, y: 100, width: 200, height: 200))
    }

    @Test func largeChaptersAreBatchedWithoutLosingIDsOrUTF8Text() throws {
        let suite = "ReaderTranslationBatchTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.sourceLanguage = "auto"
        settings.translationSourceLanguages = []
        let sourceText = String(repeating: "猫", count: 2_000)
        let regions = (0..<100).map { index in
            ReaderTranslationRegion(id: "line-\(index)", rect: .zero, source: sourceText)
        }
        let requests = try ReaderTranslationService.requests(regions: regions, settings: settings)
        #expect(requests.count > 3)
        let capacity = min(RemoteTranslationRequest.maximumSegments,
                           RemoteTranslationRequest.maximumSourceBytes / sourceText.utf8.count)
        #expect(requests.count == (regions.count + capacity - 1) / capacity)
        #expect(requests.dropLast().allSatisfy { $0.segments.count == capacity })
        #expect(requests.allSatisfy { $0.segments.count <= RemoteTranslationRequest.maximumSegments })
        #expect(requests.flatMap(\.segments).map(\.id) == regions.map(\.id))
        #expect(requests.flatMap(\.segments).map(\.text) == regions.map(\.source))
        #expect(requests.allSatisfy { $0.segments.reduce(0) { $0 + $1.text.utf8.count } <= RemoteTranslationRequest.maximumSourceBytes })
        #expect(try ReaderTranslationService.requests(regions: [], settings: settings).isEmpty)
    }

    @Test func invalidSettingsAreRejectedWithoutPersisting() throws {
        let suite = "ReaderTranslationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.model = " "
        #expect(throws: RemoteTranslationError.self) { try settings.save(defaults: defaults) }
        #expect(defaults.string(forKey: ReaderTranslationSettings.keyPrefix + "model") == nil)
        settings.model = "gpt-5-mini"
        settings.targetLanguage = "en"
        settings.modelTier = .small
        try settings.save(defaults: defaults)
        #expect(ReaderTranslationSettings(defaults: defaults) == settings)
        #expect(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.lowercased().contains("apikey") })
    }

    @Test @MainActor func overlayUsesOriginalPixelsAndReusesOCRAcrossLanguages() async throws {
        let source = Self.image()
        let imageView = UIImageView(image: source)
        imageView.frame = CGRect(x: 0, y: 0, width: 320, height: 440)
        let calls = RecognitionCounter()
        let page = ReaderTranslationPage(imageView: imageView, recognize: { _, _ in
            await calls.record()
            return Self.regions
        }, translate: { regions, settings in
            regions.map {
                var result = $0
                result.translation = settings.targetLanguage == "ko" ? "안녕, 세상!" : "Bonjour !"
                return result
            }
        })
        var settings = ReaderTranslationSettings()
        settings.targetLanguage = "ko"
        settings.sourceLanguage = "auto"
        settings.translationSourceLanguages = []
        #expect(try await page.process(translate: true, settings: settings) == 1)
        #expect(imageView.image === source)
        #expect(page.regions.first?.translation == "안녕, 세상!")
        #expect(imageView.subviews.contains { $0 is ReaderTranslationOverlayView && !$0.isHidden })
        settings.targetLanguage = "fr"
        _ = try await page.process(translate: true, settings: settings)
        #expect(page.regions.first?.translation == "Bonjour !")
        #expect(await calls.count == 1)
        page.showOriginal()
        #expect(imageView.subviews.allSatisfy { $0.isHidden })
        _ = try await page.process(translate: false, settings: settings)
        #expect(page.regions.first?.translation == nil)
        #expect(await calls.count == 1)
        page.reset()
        #expect(page.regions.isEmpty)
        #expect(imageView.subviews.isEmpty)
    }

    @Test @MainActor func cancelledOrReplacedPageNeverReceivesLateResults() async throws {
        for replaceImage in [false, true] {
            let imageView = UIImageView(image: Self.image())
            let barrier = RecognitionBarrier()
            let page = ReaderTranslationPage(imageView: imageView, recognize: { _, _ in
                await barrier.wait()
                return Self.regions
            })
            let task = Task { try await page.process(translate: false, settings: ReaderTranslationSettings()) }
            while !(await barrier.started) { await Task.yield() }
            if replaceImage { imageView.image = Self.image() } else { page.cancel() }
            await barrier.release()
            do {
                _ = try await task.value
                Issue.record("An obsolete OCR result was accepted")
            } catch is CancellationError {
                // Expected even when a recognizer ignores cooperative cancellation.
            }
            #expect(page.regions.isEmpty)
            #expect(imageView.subviews.isEmpty)
        }
    }

    @Test @MainActor func bundledCoreMLRecognizesAnActualPage() async throws {
        for tier in IPhoneOCRModelTier.allCases {
            let profile = NativeCoreMLOCRModelProfile.profile(for: tier)
            #expect(Bundle.main.url(forResource: profile.detectorResourceName, withExtension: "mlmodelc") != nil)
            #expect(Bundle.main.url(forResource: profile.recognizerResourceName, withExtension: "mlmodelc") != nil)
            let dictionary = try #require(Bundle.main.url(forResource: profile.dictionaryResourceName, withExtension: "txt"))
            #expect(try String(contentsOf: dictionary, encoding: .utf8).split(separator: "\n").count > 6_000)
        }
        let image = Self.image()
        let pixels = try #require(image.cgImage)
        let regions = try await ReaderOCRService.shared.recognize(image: pixels, tier: .medium)
        #expect(!regions.isEmpty)
        #expect(regions.contains { $0.source.uppercased().contains("HELLO") })
        #expect(regions.allSatisfy { CGRect(x: 0, y: 0, width: 1, height: 1).contains($0.rect) })
        await ReaderOCRService.shared.purge()
    }

    private static let regions = [ReaderTranslationRegion(
        id: "region-0", rect: CGRect(x: 0.1, y: 0.1, width: 0.75, height: 0.2), source: "HELLO WORLD"
    )]

    @MainActor private static func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 640, height: 880), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 880))
            ("HELLO WORLD" as NSString).draw(at: CGPoint(x: 60, y: 100), withAttributes: [
                .font: UIFont.systemFont(ofSize: 48, weight: .bold), .foregroundColor: UIColor.black
            ])
            ("こんにちは" as NSString).draw(at: CGPoint(x: 80, y: 280), withAttributes: [
                .font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.black
            ])
        }
    }
}

private actor RecognitionCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor RecognitionBarrier {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}

/// Dataset pages for `occludedDocumentFinePrintStaysAsPrintedArt`: pixel boxes and OCR reads.
private enum OccludedDocumentFixtures {
    // comic-8327 (1350x1920): a contract under the hand, lettering in capitals over it.
    static let contract: [([Double], String)] = [
        ([396, 77, 112, 54], "大反響感謝！"),
        ([1102, 82, 109, 76], "Chapter"),
        ([1211, 101, 20, 20], "☆"),
        ([8, 111, 182, 151], "TOWARDS THE LAUNCH OF A NEW IDOL GROUP FOR THE FIRST TIME IN OVER A DECADE, THE FIRST MEMBER IS.….!?"),
        ([406, 122, 96, 88], "第卷大好評発売中!!"),
        ([1111, 140, 95, 60], "ormalities"),
        ([631, 186, 188, 50], "Exclusive Contr"),
        ([250, 203, 118, 36], "【推しの子】"),
        ([264, 237, 91, 11], "赤拔アカ・横袖メンゴ"),
        ([421, 229, 269, 82], "Strawberry Productions (hereafte known as party B) hereby enter into recording "
                              + "activities. writing and creatiy"),
        ([841, 244, 136, 115], "NEXT, YOU PLACE YOUR SEAL ACROSS THESE TWO PAGES."),
        ([711, 266, 101, 60], "wn as party ract pertaining ties as well as"),
        ([446, 296, 148, 36], "First Article: (Terming"),
        ([401, 322, 149, 35], "What follows will bed"),
        ([685, 357, 143, 35], "e individual terms use"),
        ([366, 367, 71, 88], "and all Ana sou are"),
        ([585, 380, 29, 30], "Mu ed"),
        ([645, 385, 324, 182], "rmances, Oral Presentatio tainment ve of sizes and bitrate, all compact discs (CD), Tapes "
                               + "(DAT), As well as all other forms of ction, form or materials composed of, that sed in "
                               + "the future and bitrate, all Video Cassettes·Video Discs, deo Recording devices, "
                               + "irrespective of con- re currently in use or may be developed and"),
        ([351, 459, 43, 39], "DVD struct"),
        ([431, 456, 105, 46], "MY SEAL ACROSS..."),
        ([347, 493, 43, 19], "used i"),
        ([714, 556, 25, 13], "nsu"),
        ([747, 555, 32, 37], "ing ice"),
        ([701, 566, 38, 23], "at p"),
        ([634, 575, 37, 20], "ansra"),
        ([877, 569, 52, 43], "(This that"),
        ([693, 583, 45, 17], "I thee."),
        ([569, 600, 102, 74], "mance on magr iscovered, ests that corre"),
        ([820, 597, 44, 21], "Ipubl"),
        ([684, 612, 68, 58], "ompar tape lings or"),
        ([877, 604, 40, 21], "udio"),
        ([300, 615, 165, 136], "I'M NOT REALLY SURE WHAT YOU MEAN, DO I JUST STAMP LIKE THIS?"),
        ([873, 636, 32, 19], "ack-"),
        ([697, 661, 52, 22], "s to di"),
        ([759, 654, 18, 31], "de bu"),
        ([793, 659, 68, 38], "re of music"),
        ([530, 672, 245, 46], "other terminology, refer to the lanan"),
        ([655, 702, 235, 68], "赤坂アカ"),
        ([963, 702, 292, 66], "横槍メンゴ"),
        ([469, 742, 230, 64], "of this contract, will follow party will engage in the"),
        ([1065, 882, 193, 94], "YES, AND WITH THAT, YOU ARE OFFICIALLY A PERFORMER AFFILIATED WITH STRAWBERRY PRODUCTIONS."),
        ([698, 923, 152, 59], "IF YOU MESS UP, I'LL SEE YOU IN COURT."),
        ([328, 951, 114, 40], "THAT'S, LIKE, SO SCARY."),
        ([621, 1182, 154, 142], "THIS IS ALSO A NECES- SARY PROCEDURE FOR APPLYING FOR ENTRY INTO THE PERFORMING ARTS PROGRAM"),
        ([437, 1229, 136, 41], "SO DON'T BE MAD, AQLUIA."),
        ([572, 1590, 131, 71], "IT'S NOT LIKE I'M AGAINST IT.")
    ]
    // comic-8621 (1350x1920): a DNA test report under black caption boxes.
    static let report: [([Double], String)] = [
        ([688, 16, 148, 84], "BIOL"),
        ([167, 204, 110, 84], "Result Biologi"),
        ([313, 266, 137, 113], "THERE WAS NO BLOOD RELATION WHATSO- EVER."),
        ([485, 272, 176, 96], "y test: jonship Neg"),
        ([670, 279, 186, 67], "THE RESULT OF THE CIGARETTE BUTT ANALYSIS:"),
        ([126, 306, 148, 103], "Based on ou no biological statistical"),
        ([482, 381, 334, 143], "CR, the conclusic e alleged fathe plogically related aoes not exist"),
        ([101, 424, 43, 35], "The"),
        ([51, 447, 117, 164], "vesi refer the p respor intentic before b"),
        ([302, 473, 474, 237], "rivate appraisal (appraised samples were har- sence of an observer) is purely for "
                               + "personal rt does not constitute a legal document for oceedings. XXXLab does not assume or "
                               + "manner in the event the y, mistakenly"),
        ([174, 507, 119, 72], "IN A WAY, I'M RELIEVED."),
        ([328, 628, 52, 25], "liente"),
        ([995, 797, 70, 26], "...BUT"),
        ([522, 832, 146, 96], "YOU'RE WITH STRAWBERRY PRODUCTIONS, AREN'T YOU?"),
        ([954, 1258, 154, 87], "YOUR FACE REMINDS ME OF AI'S."),
        ([220, 1270, 68, 88], "IS THAT SO?"),
        ([481, 1581, 58, 114], "1")
    ]
    // comic-8519: a legible forum page (whole posts) keeps translating.
    static let posts: [([Double], String)] = [
        ([957, 195, 81, 65], "IT'S TRUE."),
        ([248, 354, 106, 96], "I HAD A VERY LONG DRY SPELL."),
        ([523, 691, 83, 40], "DWW."),
        ([704, 689, 302, 97], "Girl Actresses Current That appearance lolold"),
        ([597, 709, 37, 23], "COM"),
        ([1028, 742, 101, 96], "WHERE I COULDN'T GET ANY WORK."),
        ([253, 784, 170, 94], "NOT EVEN I KNEW WHY I WAS WORKING SO HARD."),
        ([699, 796, 98, 31], "1. Anonymous"),
        ([692, 813, 304, 67], "What's she doing now?"),
        ([504, 864, 169, 97], "ONLINE, PEOPLE ACTED LIKE MY CAREER WAS OVER."),
        ([690, 865, 101, 31], "2. Anonymous"),
        ([687, 884, 381, 78], "Did she mess up growing up?"),
        ([684, 938, 265, 82], ". Anonymous She used to be cute."),
        ([966, 1171, 167, 72], "BUT I NEVER STOPPED PRACTICING."),
        ([869, 1611, 184, 94], "THE THOUGHT OF RETIRING WAS ALWAYS, ALWAYS ON MY MIND.")
    ]
    // diverse2-0099: lowercase VN menu words are not prose.
    static let menu: [([Double], String)] = [
        ([533, 931, 194, 75], "Merel"),
        ([374, 1054, 717, 43], "Or somethin' like that, wahahaha!"),
        ([1199, 1239, 89, 38], "back"),
        ([1326, 1236, 80, 45], "skip"),
        ([1448, 1243, 84, 32], "auto"),
        ([1578, 1245, 80, 30], "save"),
        ([1699, 1239, 81, 38], "load"),
        ([1821, 1239, 144, 40], "settings"),
        ([2005, 1237, 89, 40], "title")
    ]
    // comic-8606: a legible review feed.
    static let feed: [([Double], String)] = [
        ([866, 178, 150, 103], "GLIYS, COME LOÓK AT THIS LAST EPISODE!"),
        ([327, 269, 115, 104], "THIS IS THE REAL SWEET TODÁY!"),
        ([497, 1146, 160, 26], "Sweet Tooth"),
        ([687, 1148, 129, 26], "2 hours ago"),
        ([496, 1211, 406, 35], "The final episode was great!"),
        ([856, 1458, 145, 115], "MOST VIEWERS HAVE GIVEN UP ON THE SERIES."),
        ([176, 1471, 312, 130], "Wasn't Arima Kana's acting quite something? As expected of the child actress who had "
                                + "taken the world by storm..."),
        ([1011, 1499, 229, 148], "The final episode managed to bring out the charm of the manga. Why couldn't they o this "
                                 + "from the start?"),
        ([624, 1530, 129, 111], "ONLY THE HARD- CORE FANS OF THE MANGA"),
        ([442, 1645, 172, 158], "OR FANS OF THE CAST MEMBERS CONTINUED TO WATCH THE REST OF THE SERIES."),
        ([986, 1664, 185, 97], "The story continues in the manga, so I recommend it."),
        ([172, 1762, 194, 51], "I was literally reduced to tears."),
        ([856, 1755, 88, 32], "30 mins ago"),
        ([954, 1766, 259, 152], "Was the manga also like this? The final episode was great. Maybe I'll check out the manga, too.")
    ]
    // diverse2-0833 dataset lines (every balloon line split): whole English words.
    static let balloons: [([Double], String)] = [
        ([243, 158, 241, 64], "アビドス"),
        ([1449, 177, 98, 15], "This old man doesn't"),
        ([1450, 194, 69, 11], "have the same"),
        ([1450, 208, 94, 11], "cravings for food as"),
        ([150, 219, 431, 82], "廃校対策委員会"),
        ([1266, 221, 90, 11], "No, no, no! Hoshino-"),
        ([1449, 221, 91, 14], "you youngsters, so"),
        ([1269, 234, 87, 11], "senpai, you take the"),
        ([1449, 234, 90, 14], "you guys go ahead"),
        ([1727, 235, 86, 14], "Uhe~ Serika-chan is"),
        ([1272, 247, 79, 11], "initiative to go on"),
        ([1450, 249, 64, 11], "and eat first~"),
        ([1733, 249, 74, 11], "such a good girl~"),
        ([1265, 259, 93, 14], "patrol every night, so"),
        ([1733, 260, 75, 14], "But rumor has it"),
        ([1265, 272, 92, 14], "you should definitely"),
        ([1733, 274, 74, 11], "that kemonomimi"),
        ([1269, 284, 84, 14], "have the first bite!"),
        ([1732, 287, 76, 11], "girls have massive"),
        ([1746, 298, 50, 14], "appetites~"),
        ([169, 486, 103, 24], "Nn. It's an"),
        ([683, 491, 100, 17], "Phew... Abydos"),
        ([171, 517, 149, 22], "efficient way to"),
        ([683, 511, 119, 14], "winters are as cold"),
        ([684, 528, 84, 17], "as ever, huh~"),
        ([171, 545, 138, 23], "replenish both"),
        ([172, 575, 116, 20], "calories and"),
        ([169, 602, 106, 25], "body heat."),
        ([271, 707, 41, 37], "(1="),
        ([164, 1011, 89, 14], "Geez, hurry it up"),
        ([163, 1026, 74, 14], "already! I just"),
        ([539, 1028, 120, 17], "On a freezing night"),
        ([163, 1043, 86, 14], "got off my part-"),
        ([537, 1045, 102, 17], "like this, there's"),
        ([163, 1058, 90, 14], "time job, and I'm"),
        ([162, 1073, 64, 16], "so hungry I"),
        ([538, 1066, 121, 14], "nothing better than"),
        ([163, 1090, 61, 14], "could eat a"),
        ([537, 1084, 122, 17], "everyone gathering"),
        ([681, 1090, 109, 23], "That's exactly"),
        ([162, 1103, 62, 17], "whole cow!"),
        ([537, 1102, 123, 17], "around a piping hot"),
        ([225, 1124, 74, 14], "...But since you"),
        ([537, 1121, 88, 17], "hotpot, right?"),
        ([681, 1115, 102, 20], "why we're all"),
        ([225, 1138, 90, 14], "upperclassmen are"),
        ([681, 1138, 108, 19], "having hotpot"),
        ([224, 1152, 72, 14], "here, you guys"),
        ([225, 1165, 96, 14], "should take the first"),
        ([680, 1160, 76, 21], "together!"),
        ([224, 1180, 31, 15], "bite...")
    ]
    // comic-8665 dataset lines: French dialogue, not English.
    static let french: [([Double], String)] = [
        ([322, 53, 23, 48], "Uh..."),
        ([311, 102, 26, 53], "Um..."),
        ([586, 239, 205, 20], "Merci beaucoup pour votre"),
        ([586, 260, 185, 19], "invitation d' aujourd' hui."),
        ([525, 502, 135, 31], "C' est nous"),
        ([527, 537, 230, 26], "qui vous remercions"),
        ([526, 565, 280, 29], "d'être venus d'aussi loin."),
        ([436, 667, 195, 30], "Nous ferons tout"),
        ([435, 700, 166, 28], "notre possible"),
        ([436, 733, 167, 25], "pour que vous"),
        ([436, 761, 226, 29], "gardiez un souvenir"),
        ([436, 792, 287, 29], "impérissable durant votre"),
        ([435, 823, 213, 30], "séjour parmi nous."),
        ([137, 1063, 155, 21], "Je vous remercie."),
        ([574, 1058, 203, 25], "Si vous avez besoin de"),
        ([574, 1085, 145, 21], "quoi que ce soit,"),
        ([573, 1105, 186, 23], "n' hésitez pas à nous"),
        ([573, 1128, 123, 21], "le faire savoir.")
    ]
    // comic-8969 dataset lines: slang comments (12 % unknown words).
    static let comments: [([Double], String)] = [
        ([829, 1, 287, 17], "There's no point to your existence."),
        ([828, 21, 55, 21], "Gross"),
        ([828, 76, 217, 23], "Kinmokusei@kinmokusei"),
        ([1128, 76, 84, 23], "5 min. ago"),
        ([828, 101, 104, 20], "So fucking d"),
        ([826, 158, 107, 23], "Majishanto"),
        ([828, 181, 104, 20], "You're an ug"),
        ([907, 203, 26, 20], "2"),
        ([1027, 202, 18, 23], "I"),
        ([613, 224, 63, 27], "THIS"),
        ([980, 225, 111, 23], "DESERVE"),
        ([827, 235, 105, 20], "Todensetsu"),
        ([600, 248, 92, 26], "IS HOW"),
        ([971, 246, 128, 25], "THIS, I DID"),
        ([827, 258, 105, 20], "How did this"),
        ([581, 273, 128, 23], "EVERYONE"),
        ([967, 269, 138, 23], "SOMETHING"),
        ([828, 280, 106, 23], "And an equa"),
        ([595, 296, 97, 22], "FEELS..."),
        ([991, 290, 90, 26], "WRONG"),
        ([996, 313, 79, 25], "AFTER"),
        ([162, 335, 16, 20], "I"),
        ([828, 336, 104, 20], "Yawarakaha"),
        ([1008, 335, 54, 28], "ALL."),
        ([103, 357, 134, 23], "SHOULDN'T"),
        ([828, 359, 104, 20], "You're still al"),
        ([108, 378, 122, 29], "AVERT MY"),
        ([907, 384, 26, 21], "2"),
        ([123, 400, 84, 29], "EYES.."),
        ([828, 415, 105, 20], "Broken wing"),
        ([1138, 412, 82, 23], "5 min. ago"),
        ([828, 438, 105, 20], "She was a n"),
        ([1136, 435, 68, 27], "ea what"),
        ([827, 460, 374, 24], "you've done? You woulan t get it considering"),
        ([828, 483, 282, 23], "how fucking ugly you are I guess."),
        ([911, 510, 28, 21], "2"),
        ([827, 547, 160, 21], "Ageha@ageha000"),
        ([1030, 548, 90, 19], "17 min. ago"),
        ([825, 570, 348, 21], "No one will be sad if it's your face getting"),
        ([826, 592, 43, 21], "hurt."),
        ([587, 694, 138, 15], "Piyopiyo@piyopee2210"),
        ([587, 710, 188, 14], "Don't come back, in fact remove"),
        ([586, 723, 199, 19], "yourself from the gene pool just to"),
        ([588, 766, 141, 18], "Pankushit@pankcy1100"),
        ([588, 784, 137, 15], "You don't have a future."),
        ([631, 802, 20, 17], "t2"),
        ([869, 798, 20, 25], "I"),
        ([387, 809, 109, 25], "TO READ"),
        ([587, 824, 135, 14], "Babylon@babirooon24"),
        ([830, 820, 97, 30], "DID MY"),
        ([370, 833, 143, 25], "ALL OF THE"),
        ([587, 839, 198, 15], "Make no mistake, you're underesti"),
        ([587, 855, 53, 16], "her fans."),
        ([843, 846, 71, 27], "BEST"),
        ([382, 857, 119, 23], "CRITICISM"),
        ([633, 871, 15, 11], "t"),
        ([389, 878, 105, 29], "AGAINST"),
        ([586, 892, 187, 18], "Pumpkinknight@panpkinknit00"),
        ([417, 902, 48, 28], "ME."),
        ([586, 910, 197, 15], "I hope you have eyes on the back"),
        ([586, 926, 199, 14], "your head, you're gonna need then"),
        ([586, 969, 123, 14], "Yuukari@youkari555"),
        ([586, 984, 270, 15], "I hope the tabloids have a field day on this one."),
        ([325, 1171, 44, 25], "THE"),
        ([292, 1198, 110, 20], "ONES WHO"),
        ([669, 1201, 105, 22], "WHEN THE"),
        ([283, 1222, 129, 20], "TAKE THINGS"),
        ([659, 1225, 124, 22], "MOB COMES"),
        ([270, 1246, 154, 20], "SERIOUSLY ARE"),
        ([663, 1250, 115, 23], "AFTER YOUI,"),
        ([270, 1270, 154, 20], "THE ONES WHO"),
        ([288, 1294, 118, 20], "GET REALLY"),
        ([315, 1316, 62, 24], "HURT."),
        ([955, 1566, 94, 25], "THERE'S"),
        ([230, 1583, 115, 25], "YOU TEND"),
        ([497, 1594, 44, 28], "IT'S"),
        ([935, 1592, 135, 27], "NO NEED TO"),
        ([220, 1610, 138, 26], "TO TRY AND"),
        ([468, 1622, 102, 26], "BECAUSE"),
        ([943, 1621, 120, 22], "TAKE HEED"),
        ([210, 1640, 156, 23], "FACE ALL THE"),
        ([462, 1651, 116, 22], "WHEN YOU"),
        ([938, 1645, 129, 27], "OF ALL THE"),
        ([224, 1667, 127, 25], "HATE HEAD"),
        ([449, 1677, 141, 23], "TAKE THINGS"),
        ([946, 1672, 110, 25], "CRITICISM."),
        ([264, 1692, 47, 29], "ON."),
        ([457, 1703, 124, 25], "SERIOUSLY,")
    ]
}
