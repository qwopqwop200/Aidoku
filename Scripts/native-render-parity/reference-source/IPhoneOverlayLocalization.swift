// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation

enum IPhoneLocalizedStringKey: String, Sendable {
    case overlayCopyHint = "overlay.accessibility.copyHint"
    case overlayCopySource = "overlay.menu.copySource"
    case overlayCopyTranslation = "overlay.menu.copyTranslation"
    case overlayTranslationFormat =
        "overlay.accessibility.translationFormat"
}

struct IPhoneLocalizer: Sendable {
    let locale: IPhoneUILocale

    init(locale: IPhoneUILocale) {
        self.locale = locale
    }

    func string(_ key: IPhoneLocalizedStringKey) -> String {
        Self.catalog[locale]?[key]
            ?? Self.catalog[.english]?[key]
            ?? key.rawValue
    }

    func format(
        _ key: IPhoneLocalizedStringKey,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: string(key),
            locale: Locale(identifier: locale.rawValue),
            arguments: arguments
        )
    }

    private static let catalog: [IPhoneUILocale: [IPhoneLocalizedStringKey: String]] = [
        .korean: [
            .overlayCopyHint: "길게 눌러 텍스트를 복사할 수 있습니다.",
            .overlayCopySource: "원문 복사",
            .overlayCopyTranslation: "번역 복사",
            .overlayTranslationFormat: "번역: %@",
        ],
        .english: [
            .overlayCopyHint: "Long-press to copy text.",
            .overlayCopySource: "Copy Source",
            .overlayCopyTranslation: "Copy Translation",
            .overlayTranslationFormat: "Translation: %@",
        ],
        .chinese: [
            .overlayCopyHint: "长按可复制文本。",
            .overlayCopySource: "复制原文",
            .overlayCopyTranslation: "复制翻译",
            .overlayTranslationFormat: "翻译：%@",
        ],
        .japanese: [
            .overlayCopyHint: "長押しするとテキストをコピーできます。",
            .overlayCopySource: "原文をコピー",
            .overlayCopyTranslation: "翻訳をコピー",
            .overlayTranslationFormat: "翻訳：%@",
        ],
    ]
}
