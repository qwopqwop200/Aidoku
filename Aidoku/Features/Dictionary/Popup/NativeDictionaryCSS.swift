import UIKit
import SwiftSoup

extension NSAttributedString.Key {
    static let nativeDictionaryCSSDiagnostics = NSAttributedString.Key("AidokuDictionaryCSSDiagnostics")
    static let nativeDictionaryLanguage = NSAttributedString.Key("AidokuDictionaryLanguage")
}

/// A native cascade for text/box declarations. SwiftSoup selectors retain dictionary data-sc selectors,
/// ancestry, classes and language; unsupported layout features remain inspectable as diagnostics.
@MainActor
struct NativeDictionaryCSS {
    struct Rule {
        let selector: String
        let declarations: [String: Any]
        let important: Set<String>
        let specificity: Int
        let order: Int
    }
    let rules: [Rule]
    private let themeVariables: [String: String]
    init(_ source: String, traits: UITraitCollection = .current, viewportWidth: CGFloat = 260) {
        let cleaned = source.replacingOccurrences(of: "/\\*.*?\\*/", with: "", options: .regularExpression)
        var parsed: [Rule] = []
        func parse(_ text: String) {
            var cursor = text.startIndex
            while cursor < text.endIndex, let open = text[cursor...].firstIndex(of: "{") {
                let selectorText = String(text[cursor..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
                var depth = 1, end = text.index(after: open), quote: Character?
                while end < text.endIndex && depth > 0 {
                    let character = text[end]
                    if let active = quote {
                        if character == active { quote = nil }
                    } else if character == "\"" || character == "'" { quote = character }
                    else if character == "{" { depth += 1 }
                    else if character == "}" { depth -= 1 }
                    if depth > 0 { end = text.index(after: end) }
                }
                guard depth == 0 else { break }
                let body = String(text[text.index(after: open)..<end])
                if selectorText.hasPrefix("@media") {
                    if Self.matchesMedia(String(selectorText.dropFirst(6)), traits: traits, width: viewportWidth) { parse(body) }
                } else if !selectorText.hasPrefix("@") {
                    let declaration = Self.parseDeclarations(body)
                    for raw in selectorText.split(separator: ",") {
                        let selector = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !selector.isEmpty else { continue }
                        let specificity = selector.filter { $0 == "#" }.count * 100
                            + selector.filter { $0 == "." || $0 == "[" || $0 == ":" }.count * 10
                            + selector.split(whereSeparator: { " >+~".contains($0) }).count
                        parsed.append(Rule(selector: selector, declarations: declaration.values,
                                           important: declaration.important, specificity: specificity, order: parsed.count))
                    }
                }
                cursor = text.index(after: end)
            }
        }
        parse(cleaned)
        themeVariables = traits.userInterfaceStyle == .dark
            ? ["--text-color": "#fff", "--text-color-light1": "#aaa", "--text-color-light2": "#999",
               "--text-color-light3": "#888", "--text-color-light4": "#777", "--background-color": "#000",
               "--background-color-light": "#000", "--background-color-dark1": "#333"]
            : ["--text-color": "#000", "--text-color-light1": "#555", "--text-color-light2": "#666",
               "--text-color-light3": "#777", "--text-color-light4": "#888", "--background-color": "#fff",
               "--background-color-light": "#fff", "--background-color-dark1": "#eee"]
        rules = parsed.sorted { $0.specificity == $1.specificity ? $0.order < $1.order : $0.specificity < $1.specificity }
    }
    func declarations(for node: Element) -> [String: Any] {
        var variables = themeVariables, ancestors: [Element] = []
        var current: Element? = node
        while let element = current { ancestors.append(element); current = element.parent() }
        for element in ancestors.reversed() {
            for (key, value) in rawDeclarations(for: element) where key.hasPrefix("--") { variables[key] = String(describing: value) }
        }
        return rawDeclarations(for: node).mapValues { value in
            guard let text = value as? String else { return value }
            return Self.resolveVariables(text, variables: variables)
        }
    }
    private func rawDeclarations(for node: Element) -> [String: Any] {
        var normal: [String: Any] = [:], important: [String: Any] = [:]
        for rule in rules where (try? node.iS(rule.selector)) == true {
            for (key, value) in rule.declarations {
                if rule.important.contains(key) { important[key] = value } else { normal[key] = value }
            }
        }
        let inline = Self.parseDeclarations((try? node.attr("style")) ?? "")
        for (key, value) in inline.values {
            if inline.important.contains(key) { important[key] = value } else { normal[key] = value }
        }
        normal.merge(important) { _, new in new }
        return normal
    }
    private static func resolveVariables(_ source: String, variables: [String: String]) -> String {
        var result = source
        let expression = try? NSRegularExpression(pattern: "var\\(\\s*(--[A-Za-z0-9_-]+)\\s*(?:,([^()]*))?\\)")
        for _ in 0..<16 {
            let matches = expression?.matches(in: result, range: NSRange(result.startIndex..., in: result)) ?? []
            guard !matches.isEmpty else { break }
            var changed = false
            for match in matches.reversed() {
                guard let whole = Range(match.range, in: result), let nameRange = Range(match.range(at: 1), in: result) else { continue }
                let fallback = Range(match.range(at: 2), in: result).map { String(result[$0]).trimmingCharacters(in: .whitespaces) }
                guard let replacement = variables[String(result[nameRange])] ?? fallback, replacement != String(result[whole]) else { continue }
                result.replaceSubrange(whole, with: replacement); changed = true
            }
            if !changed { break }
        }
        return result
    }
    static func declarations(_ source: String) -> [String: Any] { parseDeclarations(source).values }
    private static func parseDeclarations(_ source: String) -> (values: [String: Any], important: Set<String>) {
        var result: [String: Any] = [:], important: Set<String> = []
        for entry in source.split(separator: ";") {
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let rawKey = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = rawKey.hasPrefix("--") ? rawKey : rawKey.lowercased()
            var value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let strong = value.range(of: "!\\s*important\\s*$", options: [.regularExpression, .caseInsensitive])
            if let strong { value.removeSubrange(strong); important.insert(key) }
            else if important.contains(key) { continue }
            result[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (result, important)
    }
    private static func matchesMedia(_ condition: String, traits: UITraitCollection, width: CGFloat) -> Bool {
        let expression = try? NSRegularExpression(pattern: "\\(([^:()]+):([^()]+)\\)")
        return condition.split(separator: ",").contains { alternative in
            let text = String(alternative).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("print") { return false }
            let tests = expression?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
            let accepted = tests.allSatisfy { match in
                guard let keyRange = Range(match.range(at: 1), in: text), let valueRange = Range(match.range(at: 2), in: text) else { return false }
                let key = text[keyRange].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = text[valueRange].trimmingCharacters(in: .whitespacesAndNewlines)
                switch key {
                case "prefers-color-scheme": return value == (traits.userInterfaceStyle == .dark ? "dark" : "light")
                case "prefers-reduced-motion": return value == (UIAccessibility.isReduceMotionEnabled ? "reduce" : "no-preference")
                case "min-width": return length(value, font: .systemFont(ofSize: 15), relativeTo: width).map { width >= $0 } ?? false
                case "max-width": return length(value, font: .systemFont(ofSize: 15), relativeTo: width).map { width <= $0 } ?? false
                default: return false
                }
            }
            return text.hasPrefix("not ") ? !accepted : accepted
        }
    }
    static func kebab(_ name: String) -> String {
        name.reduce(into: "") { result, letter in
            if letter.isUppercase { result += "-" + String(letter).lowercased() } else { result.append(letter) }
        }
    }
    static func length(_ value: Any?, font: UIFont, relativeTo: CGFloat) -> CGFloat? {
        guard let value else { return nil }
        if let number = value as? NSNumber { let n = CGFloat(number.doubleValue); return n.isFinite ? n : nil }
        let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("calc("), text.hasSuffix(")") {
            return calculatedLength(String(text.dropFirst(5).dropLast()), font: font, relativeTo: relativeTo)
        }
        let numeric = text.replacingOccurrences(of: "(?i)(px|pt|em|rem|%)$", with: "", options: .regularExpression)
        guard let number = Double(numeric), number.isFinite else { return nil }
        let result: CGFloat
        if text.hasSuffix("rem") { result = CGFloat(number) * 15 }
        else if text.hasSuffix("em") { result = CGFloat(number) * font.pointSize }
        else if text.hasSuffix("%") { result = CGFloat(number) * relativeTo / 100 }
        else { result = CGFloat(number) }
        return result
    }
    private static func calculatedLength(_ source: String, font: UIFont, relativeTo: CGFloat) -> CGFloat? {
        let compact = source.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        let expression = try? NSRegularExpression(pattern: "[0-9]*\\.?[0-9]+(?:rem|em|px|pt|%)?|[+*/()-]")
        let tokens = (expression?.matches(in: compact, range: NSRange(compact.startIndex..., in: compact)) ?? [])
            .compactMap { Range($0.range, in: compact).map { String(compact[$0]) } }
        guard tokens.joined() == compact, tokens.count <= 128 else { return nil }
        var index = 0
        func factor() -> CGFloat? {
            guard index < tokens.count else { return nil }
            let token = tokens[index]; index += 1
            if token == "+" { return factor() }
            if token == "-" { return factor().map { -$0 } }
            if token == "(" {
                guard let result = addition(), index < tokens.count, tokens[index] == ")" else { return nil }
                index += 1; return result
            }
            return length(token, font: font, relativeTo: relativeTo)
        }
        func product() -> CGFloat? {
            guard var value = factor() else { return nil }
            while index < tokens.count, tokens[index] == "*" || tokens[index] == "/" {
                let operation = tokens[index]; index += 1
                guard let rhs = factor(), operation != "/" || rhs != 0 else { return nil }
                value = operation == "*" ? value * rhs : value / rhs
            }
            return value
        }
        func addition() -> CGFloat? {
            guard var value = product() else { return nil }
            while index < tokens.count, tokens[index] == "+" || tokens[index] == "-" {
                let operation = tokens[index]; index += 1
                guard let rhs = product() else { return nil }
                value = operation == "+" ? value + rhs : value - rhs
            }
            return value
        }
        guard let value = addition(), index == tokens.count, value.isFinite else { return nil }
        return value
    }
    static func color(_ value: String, current: UIColor = .label) -> UIColor? {
        let value = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let named: [String: UIColor] = ["black": .black, "white": .white, "red": .red, "blue": .blue,
            "green": UIColor(red: 0, green: 0.5, blue: 0, alpha: 1), "gray": .gray, "grey": .gray,
            "transparent": .clear, "currentcolor": current, "inherit": current]
        if let color = named[value] { return color }
        if value.hasPrefix("var(") { return value.contains("background") ? .secondarySystemBackground : current }
        if value.hasPrefix("#") {
            var hex = String(value.dropFirst())
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard [6, 8].contains(hex.count), let raw = UInt32(hex, radix: 16) else { return nil }
            let rgb = hex.count == 8 ? raw >> 8 : raw
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: hex.count == 8 ? CGFloat(raw & 255) / 255 : 1)
        }
        if value.hasPrefix("rgb"), let begin = value.firstIndex(of: "("), let end = value.lastIndex(of: ")") {
            let channels = value[value.index(after: begin)..<end].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            guard channels.count >= 3 else { return nil }
            let colors = channels.prefix(3).compactMap { text -> CGFloat? in
                let percent = text.hasSuffix("%")
                return Double(text.replacingOccurrences(of: "%", with: "")).map { CGFloat($0) / (percent ? 100 : 255) }
            }
            guard colors.count == 3 else { return nil }
            let alpha = channels.count > 3 ? CGFloat(Double(channels[3]) ?? 1) : 1
            return UIColor(red: colors[0], green: colors[1], blue: colors[2], alpha: alpha)
        }
        return nil
    }
    static func attributes(_ css: [String: Any], inherited: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        let normalized = css.reduce(into: [String: Any]()) { $0[kebab($1.key)] = $1.value }
        var result = inherited
        var font = inherited[.font] as? UIFont ?? .systemFont(ofSize: 15)
        if let size = length(normalized["font-size"], font: font, relativeTo: font.pointSize), size > 0 { font = font.withSize(min(256, size)) }
        if let family = normalized["font-family"] as? String {
            for name in family.split(separator: ",").map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) }) {
                if let chosen = UIFont(name: name, size: font.pointSize) { font = chosen; break }
            }
        }
        var traits = font.fontDescriptor.symbolicTraits
        let weight = String(describing: normalized["font-weight"] ?? "")
        if weight == "bold" || (Int(weight) ?? 0) >= 600 { traits.insert(.traitBold) }
        else if weight == "normal" || (Int(weight).map { $0 < 600 } ?? false) { traits.remove(.traitBold) }
        if normalized["font-style"] as? String == "italic" { traits.insert(.traitItalic) }
        else if normalized["font-style"] as? String == "normal" { traits.remove(.traitItalic) }
        if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: font.pointSize) }
        result[.font] = font
        let foreground = inherited[.foregroundColor] as? UIColor ?? .label
        if let text = normalized["color"] as? String, let chosen = color(text, current: foreground) { result[.foregroundColor] = chosen }
        if let text = normalized["background-color"] as? String, let chosen = color(text, current: foreground) { result[.backgroundColor] = chosen }
        if let value = length(normalized["letter-spacing"], font: font, relativeTo: font.pointSize) { result[.kern] = value }
        let paragraph = (inherited[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        if let align = normalized["text-align"] as? String {
            paragraph.alignment = align == "center" ? .center : align == "right" || align == "end" ? .right : align == "justify" ? .justified : .left
        }
        if let height = normalized["line-height"] {
            let text = String(describing: height)
            let unitless = Double(text)
            let spacing = unitless.map { CGFloat($0) * font.pointSize } ?? length(height, font: font, relativeTo: font.pointSize)
            if let spacing, spacing > 0 { paragraph.minimumLineHeight = spacing; paragraph.maximumLineHeight = spacing }
        }
        if let value = length(normalized["margin-left"], font: font, relativeTo: 260) { paragraph.headIndent += max(0, value) }
        if let value = length(normalized["margin-right"], font: font, relativeTo: 260) { paragraph.tailIndent -= max(0, value) }
        if let value = length(normalized["margin-top"], font: font, relativeTo: font.pointSize) { paragraph.paragraphSpacingBefore = max(0, value) }
        if let value = length(normalized["margin-bottom"], font: font, relativeTo: font.pointSize) { paragraph.paragraphSpacing = max(0, value) }
        result[.paragraphStyle] = paragraph
        let decoration = String(describing: normalized["text-decoration-line"] ?? normalized["text-decoration"] ?? "")
        if decoration.contains("underline") { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if decoration.contains("line-through") { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let align = normalized["vertical-align"] as? String {
            if align == "super" { result[.baselineOffset] = font.pointSize * 0.4 }
            if align == "sub" { result[.baselineOffset] = -font.pointSize * 0.2 }
        }
        let supported: Set<String> = ["font-size", "font-family", "font-weight", "font-style", "color", "background-color", "letter-spacing",
            "text-align", "line-height", "margin-left", "margin-right", "margin-top", "margin-bottom", "text-decoration-line", "text-decoration",
            "vertical-align", "display", "white-space", "width", "height", "padding", "border", "border-width", "border-color", "border-style", "border-radius", "background"]
        var residual = normalized.keys.filter { !supported.contains($0) }
        if let display = normalized["display"] as? String,
           !["none", "inline", "block", "inline-block", "table", "table-row", "table-cell", "table-row-group", "table-header-group", "table-footer-group", "list-item"].contains(display) {
            residual.append("display:" + display)
        }
        residual.sort()
        if !residual.isEmpty { result[.nativeDictionaryCSSDiagnostics] = residual }
        return result
    }
}
