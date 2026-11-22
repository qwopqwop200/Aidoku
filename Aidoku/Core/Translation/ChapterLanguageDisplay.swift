import Foundation

/// Some sources place a language name in the scanlator field. Match whole language names only.
enum ChapterLanguageDisplay {
    private static let englishNames: [String: String] = {
        let english = Locale(identifier: "en")
        return Locale.isoLanguageCodes.sorted().reduce(into: [:]) { result, code in
            if let name = english.localizedString(forLanguageCode: code) {
                result[name.lowercased()] = code
            }
        }
    }()
    // Bundle localizations are fixed for the process; built once instead of per chapter row.
    static let displayLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? Locale.current.identifier)

    static func localized(_ original: String, acceptsCode: Bool = true, locale: Locale = displayLocale) -> String {
        let value = original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let code = englishNames[value] ?? (acceptsCode && Locale.isoLanguageCodes.contains(value) ? value : nil)
        guard let code else { return original }
        return locale.localizedString(forLanguageCode: code) ?? original
    }
}
