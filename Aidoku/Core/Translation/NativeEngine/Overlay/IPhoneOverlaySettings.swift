import Foundation

enum IPhoneOverlayMode: String, Codable, Sendable {
    case translateOnly, originalAndTranslation, subtitle, sidePanel
}

enum IPhoneOverlayColorMode: String, Codable, Sendable {
    case white, dark

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
    case replace, expanded
}

enum IPhoneSubtitlePosition: String, Codable, Sendable {
    case top, bottom
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

    /// Legacy subtitle/side-panel fields stay decodable for migration; text is
    /// always rendered directly over its source box.
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

// In an extension so the memberwise initializer stays available.
extension IPhoneOverlaySettings {
    init(from decoder: any Decoder) throws {
        // Removed font-size and expansion preferences are ignored.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visible = try container.decode(Bool.self, forKey: .visible)
        mode = try container.decode(IPhoneOverlayMode.self, forKey: .mode)
        colorMode = try container.decode(IPhoneOverlayColorMode.self, forKey: .colorMode)
        opacity = try container.decode(Double.self, forKey: .opacity)
        textPlacement = try container.decode(IPhoneOverlayTextPlacement.self, forKey: .textPlacement)
        subtitlePosition = try container.decode(IPhoneSubtitlePosition.self, forKey: .subtitlePosition)
        subtitleMaxLines = try container.decode(Int.self, forKey: .subtitleMaxLines)
        subtitleContextSentences = try container.decode(Int.self, forKey: .subtitleContextSentences)
    }
}
