// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation

enum IPhoneOverlayMode: String, Codable, Sendable {
    case translateOnly
    case originalAndTranslation
    case subtitle
    case sidePanel
}

enum IPhoneOverlayColorMode: String, Codable, Sendable {
    case white
    case dark

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case "white", "auto": self = .white // Migrate the retired automatic palette.
        case "dark": self = .dark
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown overlay color mode")
        }
    }
}

enum IPhoneOverlayTextPlacement: String, Codable, Sendable {
    case replace
    case expanded
}

enum IPhoneSubtitlePosition: String, Codable, Sendable {
    case top
    case bottom
}

struct IPhoneOverlaySettings: Codable, Equatable, Sendable {
    var visible: Bool
    var mode: IPhoneOverlayMode
    var colorMode: IPhoneOverlayColorMode
    var preserveSourceTextColor = false
    var preserveSourceBackgroundColor = false
    var inpaintingEnabled = false
    var opacity: Double
    var textPlacement: IPhoneOverlayTextPlacement
    var subtitlePosition: IPhoneSubtitlePosition
    var subtitleMaxLines: Int
    var subtitleContextSentences: Int

    private enum CodingKeys: String, CodingKey {
        case visible
        case mode
        case colorMode
        case preserveSourceTextColor
        case preserveSourceBackgroundColor
        case inpaintingEnabled
        case opacity
        case textPlacement
        case subtitlePosition
        case subtitleMaxLines
        case subtitleContextSentences
    }

    init(
        visible: Bool,
        mode: IPhoneOverlayMode,
        colorMode: IPhoneOverlayColorMode,
        opacity: Double,
        textPlacement: IPhoneOverlayTextPlacement,
        subtitlePosition: IPhoneSubtitlePosition,
        subtitleMaxLines: Int,
        subtitleContextSentences: Int
    ) {
        self.visible = visible
        self.mode = mode
        self.colorMode = colorMode
        self.opacity = opacity
        self.textPlacement = textPlacement
        self.subtitlePosition = subtitlePosition
        self.subtitleMaxLines = subtitleMaxLines
        self.subtitleContextSentences = subtitleContextSentences
    }

    init(from decoder: any Decoder) throws {
        // Removed font-size and expansion preferences are deliberately ignored.
        // Rendering always fits text automatically inside the image region.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visible = try container.decode(Bool.self, forKey: .visible)
        mode = try container.decode(IPhoneOverlayMode.self, forKey: .mode)
        colorMode = try container.decode(
            IPhoneOverlayColorMode.self,
            forKey: .colorMode
        )
        preserveSourceTextColor = try container.decodeIfPresent(Bool.self, forKey: .preserveSourceTextColor) ?? false
        preserveSourceBackgroundColor = try container.decodeIfPresent(Bool.self, forKey: .preserveSourceBackgroundColor) ?? false
        inpaintingEnabled = false
        preserveSourceTextColor = false
        preserveSourceBackgroundColor = false
        opacity = try container.decode(Double.self, forKey: .opacity)
        textPlacement = try container.decode(
            IPhoneOverlayTextPlacement.self,
            forKey: .textPlacement
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
        inpaintingEnabled = false
        preserveSourceTextColor = false
        preserveSourceBackgroundColor = false
        opacity = 1
        mode = .translateOnly
        textPlacement = .replace
        subtitlePosition = .bottom
        subtitleMaxLines = 2
        subtitleContextSentences = 0
    }
}
