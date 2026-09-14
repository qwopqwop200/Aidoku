import CoreGraphics
import Testing
@testable import Aidoku

struct ReaderSupplementalOCRTests {
    @Test func supplementsUnsupportedScriptsWithoutChangingCJKOrLatin() {
        for text in ["Доброе утро, сэр", "لا يزال لدي يوم كامل", "안녕하세요", "สวัสดี"] {
            #expect(ReaderSupplementalOCR.needsSupplement(text))
        }
        for text in ["Good morning", "おはようございます", "別擔心", "60Ko*", "", "Ж", "AЖ B"] {
            #expect(!ReaderSupplementalOCR.needsSupplement(text))
        }
    }

    @Test func replacesHallucinatedTranscriptionOnlyAtTheSamePosition() {
        let native = [line("BOCeMb TbIKBeHHbIX", 100, 100, 240, 30),
                      line("別擔心", 400, 100, 100, 30), line("60Ko", 100, 180, 80, 30)]
        let replacement = line("восемь тыквенных", 102, 101, 236, 28)
        let result = ReaderSupplementalOCR.reconcile(native: native, supplemental: [replacement])
        #expect(result.map(\.text) == ["別擔心", "60Ko", "восемь тыквенных"])
        #expect(result.last?.orientationIsEstimated == false)
        #expect(ReaderSupplementalOCR.reconcile(native: native, supplemental: []) == native)
    }

    @Test func neighboringRubyAndCaptionsSurvive() {
        let ruby = line("ruby", 100, 80, 70, 12)
        let caption = line("caption", 100, 135, 170, 24)
        let replacement = line("Доброе утро", 100, 100, 180, 30)
        let result = ReaderSupplementalOCR.reconcile(native: [ruby, caption], supplemental: [replacement])
        #expect(result.count == 3)
    }

    private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NativeCoreMLOCRLine {
        NativeCoreMLOCRLine(polygon: [CGPoint(x: x, y: y), CGPoint(x: x + width, y: y),
                                    CGPoint(x: x + width, y: y + height), CGPoint(x: x, y: y + height)],
                           text: text, score: 0.9, orientation: .horizontal)
    }
}
