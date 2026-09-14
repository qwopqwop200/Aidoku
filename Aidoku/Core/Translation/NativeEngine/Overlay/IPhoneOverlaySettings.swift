// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation

enum IPhoneUILocale: String, Codable, CaseIterable, Sendable {
    case korean = "ko"
    case english = "en"
    case chinese = "zh"
    case japanese = "ja"
}

enum IPhoneOverlayMode: String, Codable, CaseIterable, Sendable {
    case translateOnly
    case originalAndTranslation
    case subtitle
    case sidePanel
}

enum IPhoneOverlayColorMode: String, Codable, CaseIterable, Sendable {
    case white
    case dark
    case automatic = "auto"
}

enum IPhoneOverlayTextPlacement: String, Codable, CaseIterable, Sendable {
    case replace
    case expanded
}

enum IPhoneOverlayExpansionPolicy: String, Codable, CaseIterable, Sendable {
    case unrestricted
    case sourceBounds
    case panelConstrained
}

enum IPhoneOverlayFontSizing: String, Codable, CaseIterable, Sendable {
    case autoFit
    case fixed
}

enum IPhoneSubtitlePosition: String, Codable, CaseIterable, Sendable {
    case top
    case bottom
}

enum IPhoneAppearanceMode: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

struct IPhoneOverlaySettings: Codable, Equatable, Sendable {
    // Rendering-only metric; not persisted as a user preference.
    var reservesSurfaceBorder = true
    var visible: Bool
    var mode: IPhoneOverlayMode
    var colorMode: IPhoneOverlayColorMode
    var opacity: Double
    var fixedFontSizePoints: Int
    var textPlacement: IPhoneOverlayTextPlacement
    var expansionPolicy: IPhoneOverlayExpansionPolicy
    var fontSizing: IPhoneOverlayFontSizing
    var subtitlePosition: IPhoneSubtitlePosition
    var subtitleMaxLines: Int
    var subtitleContextSentences: Int

    private enum CodingKeys: String, CodingKey {
        case visible
        case mode
        case colorMode
        case opacity
        case fixedFontSizePoints
        case textPlacement
        case expansionPolicy
        case fontSizing
        case subtitlePosition
        case subtitleMaxLines
        case subtitleContextSentences
    }

    init(
        visible: Bool,
        mode: IPhoneOverlayMode,
        colorMode: IPhoneOverlayColorMode,
        opacity: Double,
        fixedFontSizePoints: Int,
        textPlacement: IPhoneOverlayTextPlacement,
        expansionPolicy: IPhoneOverlayExpansionPolicy = .panelConstrained,
        fontSizing: IPhoneOverlayFontSizing,
        subtitlePosition: IPhoneSubtitlePosition,
        subtitleMaxLines: Int,
        subtitleContextSentences: Int
    ) {
        self.visible = visible
        self.mode = mode
        self.colorMode = colorMode
        self.opacity = opacity
        self.fixedFontSizePoints = fixedFontSizePoints
        self.textPlacement = textPlacement
        self.expansionPolicy = expansionPolicy
        self.fontSizing = fontSizing
        self.subtitlePosition = subtitlePosition
        self.subtitleMaxLines = subtitleMaxLines
        self.subtitleContextSentences = subtitleContextSentences
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visible = try container.decode(Bool.self, forKey: .visible)
        mode = try container.decode(IPhoneOverlayMode.self, forKey: .mode)
        colorMode = try container.decode(
            IPhoneOverlayColorMode.self,
            forKey: .colorMode
        )
        opacity = try container.decode(Double.self, forKey: .opacity)
        fixedFontSizePoints = try container.decode(
            Int.self,
            forKey: .fixedFontSizePoints
        )
        textPlacement = try container.decode(
            IPhoneOverlayTextPlacement.self,
            forKey: .textPlacement
        )
        expansionPolicy = try container.decodeIfPresent(
            IPhoneOverlayExpansionPolicy.self,
            forKey: .expansionPolicy
        ) ?? .panelConstrained
        fontSizing = try container.decode(
            IPhoneOverlayFontSizing.self,
            forKey: .fontSizing
        )
        subtitlePosition = try container.decode(
            IPhoneSubtitlePosition.self,
            forKey: .subtitlePosition
        )
        subtitleMaxLines = try container.decode(
            Int.self,
            forKey: .subtitleMaxLines
        )
        subtitleContextSentences = try container.decode(
            Int.self,
            forKey: .subtitleContextSentences
        )
    }

    /// Legacy subtitle/side-panel fields remain decodable so an installed v1
    /// build can migrate without discarding unrelated credentials or settings.
    /// The current iPhone product always renders translated text directly over
    /// its source bbox.
    mutating func enforceSourceReplacement() {
        mode = .translateOnly
        textPlacement = .replace
        subtitlePosition = .bottom
        subtitleMaxLines = 2
        subtitleContextSentences = 0
    }
}

