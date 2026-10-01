import SwiftUI
import UIKit
import SwiftSoup

/// Dictionary data is rendered by TextKit and UIKit, without a browser document.
@available(iOS 18.0, *)
struct NativeDictionaryPopupView: UIViewRepresentable {
    let position: CGPoint
    var scale: CGFloat = 1
    var contentWidth: CGFloat = 260
    var clearSelection: Bool
    var lookupEntries: [[String: Any]] = []
    var allowsMining = true
    var scanNonJapaneseText = true
    var scanLength = 16
    var backTrigger = false
    var forwardTrigger = false
    var onMine: (([String: String], UUID) async -> Bool)?
    var onTextSelected: ((SelectionData) -> Int?)?
    var onTapOutside: (() -> Void)?
    var onSwipeDismiss: (() -> Void)?
    var onRedirect: ((String) -> [[String: Any]])?
    var onKanjiRedirect: ((String) -> [String: Any]?)?
    var scrollViewBounces = false
    var isScrollEnabled = true
    var onContentHeightChanged: ((CGFloat) -> Void)?
    var onScrollViewOffsetChanged: ((CGFloat) -> Void)?
    var onScrollViewWillBeginDragging: (() -> Void)?
    var onScrollViewDidEndDragging: (() -> Void)?
    var onScrollViewDidEndDecelerating: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = NativeDictionaryScrollView()
        scroll.onHeightChanged = { [weak coordinator = context.coordinator] height in
            coordinator?.parent.onContentHeightChanged?(height)
        }
        scroll.backgroundColor = .clear
        scroll.showsHorizontalScrollIndicator = false
        scroll.keyboardDismissMode = .onDrag
        scroll.delegate = context.coordinator
        let stack = context.coordinator.stack
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -24)
        ])
        context.coordinator.scroll = scroll
        scroll.onAppearanceChanged = { [weak coordinator = context.coordinator] in
            guard let coordinator, coordinator.history.indices.contains(coordinator.historyIndex) else { return }
            let offset = coordinator.scroll?.contentOffset ?? .zero
            coordinator.render(coordinator.history[coordinator.historyIndex])
            coordinator.scroll?.setContentOffset(offset, animated: false)
        }
        let outsideTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tappedOutside(_:)))
        outsideTap.cancelsTouchesInView = false
        outsideTap.delegate = context.coordinator
        scroll.addGestureRecognizer(outsideTap)
        scroll.accessibilityIdentifier = "dictionary.popup.native"
        return scroll
    }

    func updateUIView(_ view: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let key = (try? JSONSerialization.data(withJSONObject: lookupEntries, options: [.sortedKeys])) ?? Data()
        if coordinator.sourceKey != key || coordinator.renderScale != scale {
            coordinator.sourceKey = key
            coordinator.renderScale = scale
            coordinator.renderWidth = contentWidth
            coordinator.history = [lookupEntries]
            coordinator.historyIndex = 0
            coordinator.historyOffsets = [.zero]
            coordinator.collapsedGroups.removeAll()
            coordinator.render(lookupEntries)
        }
        if coordinator.renderWidth != contentWidth, contentWidth.isFinite, contentWidth > 0,
           coordinator.history.indices.contains(coordinator.historyIndex) {
            let offset = view.contentOffset
            coordinator.renderWidth = contentWidth
            coordinator.render(coordinator.history[coordinator.historyIndex])
            view.setContentOffset(offset, animated: false)
        }
        if coordinator.clearSelection != clearSelection {
            coordinator.clearSelection = clearSelection
            coordinator.stack.arrangedSubviews.forEach { container in
                coordinator.clearSelections(in: container)
            }
        }
        if coordinator.back != backTrigger {
            coordinator.back = backTrigger
            coordinator.navigate(-1)
        }
        if coordinator.forward != forwardTrigger {
            coordinator.forward = forwardTrigger
            coordinator.navigate(1)
        }
        view.isScrollEnabled = isScrollEnabled
        view.bounces = scrollViewBounces
    }

    static func dismantleUIView(_ view: UIScrollView, coordinator: Coordinator) {
        view.delegate = nil
        (view as? NativeDictionaryScrollView)?.onHeightChanged = nil
        (view as? NativeDictionaryScrollView)?.onAppearanceChanged = nil
        coordinator.tasks.forEach { $0.cancel() }
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: NativeDictionaryPopupView
        let stack = UIStackView()
        weak var scroll: UIScrollView?
        var sourceKey: Data?
        var renderScale: CGFloat = 0
        var renderWidth: CGFloat = 0
        var clearSelection = false
        var back = false
        var forward = false
        var history: [[[String: Any]]] = []
        var historyIndex = 0
        var historyOffsets: [CGPoint] = []
        var collapsedGroups: [Int: Set<String>] = [:]
        var tasks: [Task<Void, Never>] = []
        var observer: NSObjectProtocol?
        private var renderingSelection = false
        private var generation = 0

        init(parent: NativeDictionaryPopupView) {
            self.parent = parent
            super.init()
            observer = NotificationCenter.default.addObserver(forName: AnkiManager.wordAddedNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.history.indices.contains(self.historyIndex) else { return }
                    let offset = self.scroll?.contentOffset ?? .zero
                    self.render(self.history[self.historyIndex])
                    self.scroll?.setContentOffset(offset, animated: false)
                }
            }
        }

        func navigate(_ delta: Int) {
            let next = historyIndex + delta
            guard history.indices.contains(next) else { return }
            if historyOffsets.indices.contains(historyIndex) { historyOffsets[historyIndex] = scroll?.contentOffset ?? .zero }
            historyIndex = next
            render(history[next])
            if historyOffsets.indices.contains(next) { scroll?.setContentOffset(historyOffsets[next], animated: false) }
        }

        func redirect(_ entries: [[String: Any]]) {
            guard !entries.isEmpty else { return }
            history = Array(history.prefix(historyIndex + 1))
            if historyOffsets.indices.contains(historyIndex) { historyOffsets[historyIndex] = scroll?.contentOffset ?? .zero }
            historyOffsets = Array(historyOffsets.prefix(historyIndex + 1))
            historyOffsets.append(.zero)
            collapsedGroups = collapsedGroups.filter { $0.key <= historyIndex }
            history.append(entries)
            historyIndex += 1
            render(entries)
        }

        func render(_ entries: [[String: Any]]) {
            generation += 1
            tasks.forEach { $0.cancel() }; tasks.removeAll()
            stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
            let scale = min(3, max(0.5, parent.scale.isFinite ? parent.scale : 1))
            for (entryIndex, entry) in entries.enumerated() {
                let card = UIStackView()
                card.axis = .vertical; card.spacing = 5 * scale
                let expression = entry["expression"] as? String ?? entry["character"] as? String ?? ""
                let reading = entry["reading"] as? String ?? ""
                let heading = UIStackView(); heading.axis = .horizontal; heading.spacing = 8
                let expressionView = textView(NativeDictionaryContent.expression(expression, reading: reading, scale: scale))
                heading.addArrangedSubview(expressionView)
                if entry["expression"] != nil {
                    for (slot, format) in AnkiManager.shared.cardFormats.enumerated() where parent.onMine != nil && parent.allowsMining {
                        let button = UIButton(type: .system)
                        button.setImage(UIImage(systemName: format.icon.replacingOccurrences(of: ".small", with: "")), for: .normal)
                        button.accessibilityLabel = NSLocalizedString("ADD")
                        button.accessibilityIdentifier = "dictionary.mine"
                        button.addAction(UIAction { [weak self, weak button] _ in
                            guard let self, let button else { return }
                            button.isEnabled = false
                            let token = self.generation
                            self.tasks.append(Task { [weak self, weak button] in
                                guard let self else { return }
                                let content = NativeDictionaryContent.miningFields(entry, slot: slot)
                                let saved = await self.parent.onMine?(content, format.id) ?? false
                                guard !Task.isCancelled, token == self.generation else { return }
                                button?.isEnabled = !saved
                                if saved { button?.setImage(UIImage(systemName: "checkmark"), for: .normal) }
                            })
                        }, for: .touchUpInside)
                        heading.addArrangedSubview(button)
                        let token = generation
                        tasks.append(Task { [weak self, weak button] in
                            let fields = ["{expression}": expression, "{reading}": reading]
                            let duplicate = await AnkiManager.shared.checkDuplicates(fields: fields).first ?? false
                            guard let self, !Task.isCancelled, token == self.generation else { return }
                            if duplicate {
                                button?.setImage(UIImage(systemName: "checkmark"), for: .normal)
                                button?.isEnabled = false
                                let notes = UIButton(type: .system)
                                notes.setImage(UIImage(systemName: "magnifyingglass"), for: .normal)
                                notes.accessibilityLabel = NSLocalizedString("VOCABULARY")
                                notes.addAction(UIAction { _ in Task { await AnkiManager.shared.showNotes(fields: fields, formatIndex: slot) } },
                                                for: .touchUpInside)
                                heading.addArrangedSubview(notes)
                            }
                        })
                    }
                }
                card.addArrangedSubview(heading)
                if !reading.isEmpty && reading != expression && expression.isEmpty {
                    card.addArrangedSubview(textView(NSAttributedString(string: reading,
                        attributes: [.font: UIFont.systemFont(ofSize: 15 * scale), .foregroundColor: UIColor.secondaryLabel])))
                }
                if let trace = entry["deinflectionTrace"] as? [[String: String]], !trace.isEmpty {
                    let tags = UIStackView(); tags.axis = .vertical; tags.spacing = 3 * scale
                    let explanation = UILabel()
                    explanation.font = .systemFont(ofSize: 12 * scale)
                    explanation.textColor = .secondaryLabel
                    explanation.numberOfLines = 0
                    explanation.isHidden = true
                    explanation.accessibilityIdentifier = "dictionary.deinflection.description"
                    for step in trace {
                        guard let name = step["name"], !name.isEmpty else { continue }
                        let button = UIButton(type: .system)
                        button.setTitle(name, for: .normal)
                        button.contentHorizontalAlignment = .leading
                        button.titleLabel?.font = .systemFont(ofSize: 12 * scale)
                        button.accessibilityIdentifier = "dictionary.deinflection.tag"
                        let description = step["description"] ?? ""
                        button.accessibilityHint = description
                        button.addAction(UIAction { [weak explanation, weak self] _ in
                            guard let explanation else { return }
                            let close = !explanation.isHidden && explanation.text == description
                            explanation.text = description
                            explanation.isHidden = close || description.isEmpty
                            self?.scroll?.setNeedsLayout()
                        }, for: .touchUpInside)
                        tags.addArrangedSubview(button)
                    }
                    tags.addArrangedSubview(explanation)
                    card.addArrangedSubview(tags)
                }
                for frequency in entry["frequencies"] as? [[String: Any]] ?? [] {
                    let values = (frequency["frequencies"] as? [[String: Any]] ?? []).map {
                        ($0["displayValue"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(describing: $0["value"] ?? "")
                    }
                    card.addArrangedSubview(textView(NSAttributedString(string:
                        (frequency["dictionary"] as? String ?? "") + ": " + values.joined(separator: ", "),
                        attributes: [.font: UIFont.systemFont(ofSize: 12 * scale), .foregroundColor: UIColor.secondaryLabel])))
                }
                for pitch in entry["pitches"] as? [[String: Any]] ?? [] {
                    let label = UILabel(); label.text = pitch["dictionary"] as? String
                    label.font = .systemFont(ofSize: 12 * scale); label.textColor = .secondaryLabel
                    card.addArrangedSubview(label)
                    let accents = pitch["pitches"] as? [[String: Any]] ?? []
                    for accent in accents {
                        card.addArrangedSubview(textView(NativeDictionaryContent.pitch(reading: reading.isEmpty ? expression : reading,
                                                                                      accent: accent, scale: scale)))
                    }
                    for transcription in pitch["transcriptions"] as? [String] ?? [] {
                        card.addArrangedSubview(textView(NSAttributedString(string: transcription,
                            attributes: [.font: UIFont.systemFont(ofSize: 13 * scale), .foregroundColor: UIColor.label])))
                    }
                }
                for (glossaryIndex, glossary) in (entry["glossaries"] as? [[String: Any]] ?? []).enumerated() {
                    let name = glossary["dictionary"] as? String ?? ""
                    let section = UIStackView(); section.axis = .vertical; section.spacing = 5 * scale
                    let body = UIStackView(); body.axis = .vertical; body.spacing = 5 * scale
                    let disclosure = UIButton(type: .system)
                    disclosure.setTitle(name, for: .normal)
                    disclosure.setImage(UIImage(systemName: "chevron.down"), for: .normal)
                    disclosure.contentHorizontalAlignment = .leading
                    disclosure.titleLabel?.font = .systemFont(ofSize: 12 * scale, weight: .semibold)
                    disclosure.tintColor = .secondaryLabel
                    disclosure.accessibilityIdentifier = "dictionary.disclosure"
                    let groupKey = "\(entryIndex):\(glossaryIndex):\(name)"
                    let groupHistoryIndex = historyIndex
                    body.isHidden = collapsedGroups[groupHistoryIndex]?.contains(groupKey) == true
                    disclosure.accessibilityValue = body.isHidden ? "collapsed" : "expanded"
                    disclosure.setImage(UIImage(systemName: body.isHidden ? "chevron.right" : "chevron.down"), for: .normal)
                    disclosure.addAction(UIAction { [weak body, weak disclosure, weak self] _ in
                        guard let body, let disclosure else { return }
                        body.isHidden.toggle()
                        if body.isHidden { self?.collapsedGroups[groupHistoryIndex, default: []].insert(groupKey) }
                        else { self?.collapsedGroups[groupHistoryIndex]?.remove(groupKey) }
                        disclosure.setImage(UIImage(systemName: body.isHidden ? "chevron.right" : "chevron.down"), for: .normal)
                        disclosure.accessibilityValue = body.isHidden ? "collapsed" : "expanded"
                        self?.scroll?.setNeedsLayout()
                    }, for: .touchUpInside)
                    section.addArrangedSubview(disclosure); section.addArrangedSubview(body)
                    card.addArrangedSubview(section)
                    let tags = glossary["definitionTags"] as? String ?? ""
                    if !tags.isEmpty {
                        let tag = UILabel(); tag.text = tags; tag.font = .systemFont(ofSize: 11 * scale); tag.textColor = .secondaryLabel
                        body.addArrangedSubview(tag)
                    }
                    let stylesheet = LookupEngine.shared.getStyles().first { String($0.dict_name) == name }.map { String($0.styles) } ?? ""
                    let availableWidth = max(1, parent.contentWidth)
                    for block in NativeDictionaryContent.glossaryBlocks(glossary["content"] as? String ?? "",
                        dictionary: name, scale: scale, stylesheet: stylesheet, availableWidth: availableWidth) {
                        switch block {
                        case .text(let content): body.addArrangedSubview(textView(content))
                        case .table(let model): body.addArrangedSubview(NativeDictionaryTableView(model: model, makeTextView: textView))
                        case .box(let model): body.addArrangedSubview(NativeDictionaryBoxView(model: model, makeTextView: textView))
                        }
                    }
                }
                for kanji in entry["entries"] as? [[String: Any]] ?? [] {
                    let text = [kanji["dictName"] as? String ?? "", kanji["onyomi"] as? String ?? "",
                                kanji["kunyomi"] as? String ?? "", (kanji["meanings"] as? [String] ?? []).joined(separator: "; ")]
                        .filter { !$0.isEmpty }.joined(separator: "\n")
                    card.addArrangedSubview(textView(NSAttributedString(string: text,
                        attributes: [.font: UIFont.systemFont(ofSize: 15 * scale), .foregroundColor: UIColor.label])))
                }
                stack.addArrangedSubview(card)
                let separator = UIView(); separator.backgroundColor = .separator
                separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
                stack.addArrangedSubview(separator)
            }
            scroll?.setContentOffset(.zero, animated: false)
            scroll?.layoutIfNeeded()

        }

        private func textView(_ value: NSAttributedString) -> UITextView {
            let storage = NSTextStorage()
            let manager = NativeDictionaryRubyLayoutManager()
            let container = NSTextContainer(size: .zero)
            container.widthTracksTextView = true
            storage.addLayoutManager(manager); manager.addTextContainer(container)
            let view = UITextView(frame: .zero, textContainer: container)
            let laidOut = NSMutableAttributedString(attributedString: value)
            var rubyReserve: CGFloat = 0
            value.enumerateAttribute(.nativeDictionaryRuby, in: NSRange(location: 0, length: value.length)) { reading, range, _ in
                if reading != nil {
                    rubyReserve = max(rubyReserve, ((value.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont)?.pointSize ?? 15) * 0.65)
                }
            }
            if rubyReserve > 0 {
                value.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: value.length)) { style, range, _ in
                    let paragraph = (style as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                    paragraph.lineSpacing = max(paragraph.lineSpacing, rubyReserve)
                    paragraph.paragraphSpacingBefore = max(paragraph.paragraphSpacingBefore, rubyReserve)
                    laidOut.addAttribute(.paragraphStyle, value: paragraph, range: range)
                }
            }
            view.attributedText = laidOut; view.delegate = self
            view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = false
            view.backgroundColor = .clear; view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
            var rubyFontSize: CGFloat = 0
            value.enumerateAttribute(.nativeDictionaryRuby, in: NSRange(location: 0, length: value.length)) { reading, range, _ in
                if reading != nil { rubyFontSize = max(rubyFontSize, (value.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont)?.pointSize ?? 15) }
            }
            if rubyFontSize > 0 { view.textContainerInset.top = rubyFontSize * 0.65 }
            view.adjustsFontForContentSizeCategory = true
            let tap = UITapGestureRecognizer(target: self, action: #selector(tappedText(_:)))
            tap.cancelsTouchesInView = false
            view.addGestureRecognizer(tap)
            return view
        }

        func clearSelections(in view: UIView) {
            if let text = view as? UITextView { text.selectedRange = NSRange(location: 0, length: 0) }
            view.subviews.forEach { clearSelections(in: $0) }
        }

        @objc func tappedOutside(_ recognizer: UITapGestureRecognizer) {
            clearSelections(in: stack)
            parent.onTapOutside?()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view, current !== scroll {
                if current is UITextView || current is UIControl { return false }
                view = current.superview
            }
            return true
        }

        @objc private func tappedText(_ recognizer: UITapGestureRecognizer) {
            guard let textView = recognizer.view as? UITextView, let scroll,
                  let position = textView.closestPosition(to: recognizer.location(in: textView)) else { return }
            let offset = textView.offset(from: textView.beginningOfDocument, to: position)
            let sentence = textView.text ?? ""
            let value = sentence as NSString
            guard offset >= 0, offset < value.length else {
                clearSelections(in: stack); parent.onTapOutside?(); return
            }
            guard textView.attributedText.attribute(.link, at: offset, effectiveRange: nil) == nil else { return }
            let suffix = value.substring(from: offset)
            if NSLocationInRange(offset, textView.selectedRange) {
                clearSelections(in: stack); parent.onTapOutside?(); return
            }
            let text = NativeDictionarySelection.scan(sentence, offset: offset, length: parent.scanLength,
                                                       includeNonJapanese: parent.scanNonJapaneseText)
            guard !text.isEmpty else { clearSelections(in: stack); parent.onTapOutside?(); return }
            let context = NativeDictionarySelection.sentence(sentence, offset: offset)
            let selected = textView.textRange(from: position, to: textView.position(from: position, offset: (String(text.prefix(1)) as NSString).length) ?? position)
            let local = selected.map { textView.firstRect(for: $0) } ?? textView.caretRect(for: position)
            let rect = textView.convert(local, to: scroll).offsetBy(dx: parent.position.x - scroll.bounds.minX,
                                                                   dy: parent.position.y - scroll.bounds.minY)
            let selection = SelectionData(text: text, sentence: context.text, rect: rect, clozeOffset: context.offset)
            if let count = parent.onTextSelected?(selection), count > 0 {
                renderingSelection = true
                textView.selectedRange = NSRange(location: offset, length: (String(suffix.prefix(count)) as NSString).length)
                renderingSelection = false
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !renderingSelection, textView.selectedRange.length > 0, let scroll,
                  let range = textView.selectedTextRange else { return }
            let sentence = textView.text ?? ""
            let selected = (sentence as NSString).substring(with: textView.selectedRange)
            if !parent.scanNonJapaneseText && !selected.contains(where: NativeDictionarySelection.isJapanese) { return }
            let rect = textView.convert(textView.firstRect(for: range), to: scroll)
                .offsetBy(dx: parent.position.x - scroll.bounds.minX, dy: parent.position.y - scroll.bounds.minY)
            let context = NativeDictionarySelection.sentence(sentence, offset: textView.selectedRange.location)
            let selection = SelectionData(text: String(selected.prefix(max(1, parent.scanLength))), sentence: context.text,
                                          rect: rect, clozeOffset: context.offset)
            if let count = parent.onTextSelected?(selection), count > 0 {
                renderingSelection = true
                let suffix = (sentence as NSString).substring(from: textView.selectedRange.location)
                let length = (String(suffix.prefix(count)) as NSString).length
                textView.selectedRange = NSRange(location: textView.selectedRange.location, length: length)
                renderingSelection = false
            }
        }

        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange,
                      interaction: UITextItemInteraction) -> Bool {
            if URL.scheme == "http" || URL.scheme == "https" { UIApplication.shared.open(URL); return false }
            if URL.scheme == "kanji", let query = URLComponents(url: URL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value,
               let entry = parent.onKanjiRedirect?(query) { redirect([entry]); return false }
            if let query = URLComponents(url: URL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "query" })?.value {
                redirect(parent.onRedirect?(query) ?? [])
            }
            return false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.onScrollViewOffsetChanged?(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { parent.onScrollViewWillBeginDragging?() }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { parent.onScrollViewDidEndDragging?() }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { parent.onScrollViewDidEndDecelerating?() }
    }
}

@available(iOS 18.0, *)
@MainActor
enum NativeDictionaryContent {
    static func expression(_ value: String, reading: String = "", scale: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(string: value, attributes: [
            .font: UIFont.systemFont(ofSize: 24 * scale, weight: .semibold), .foregroundColor: UIColor.label])
        var rubyOffset = 0
        for segment in NativeDictionaryFurigana.segments(value, reading: reading) {
            let length = (segment.text as NSString).length
            if !segment.reading.isEmpty && length > 0 {
                result.addAttribute(.nativeDictionaryRuby, value: segment.reading, range: NSRange(location: rubyOffset, length: length))
            }
            rubyOffset += length
        }
        var offset = 0
        for character in value {
            let text = String(character)
            let length = (text as NSString).length
            if NativeDictionarySelection.isKanji(character) {
                var url = URLComponents(); url.scheme = "kanji"; url.host = "lookup"
                url.queryItems = [URLQueryItem(name: "query", value: text)]
                if let link = url.url { result.addAttribute(.link, value: link, range: NSRange(location: offset, length: length)) }
            }
            offset += length
        }
        return result
    }

    static func glossary(_ content: String, dictionary: String, scale: CGFloat, stylesheet: String = "",
                         availableWidth: CGFloat = 260) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        for block in glossaryBlocks(content, dictionary: dictionary, scale: scale, stylesheet: stylesheet, availableWidth: availableWidth) {
            switch block {
            case .text(let text): output.append(text)
            case .table(let table): output.append(table.plainText)
            case .box(let box): output.append(box.plainText)
            }
        }
        return output
    }

    static func glossaryBlocks(_ content: String, dictionary: String, scale: CGFloat, stylesheet: String = "",
                               availableWidth: CGFloat = 260) -> [NativeDictionaryGlossaryBlock] {
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 15 * scale), .foregroundColor: UIColor.label]
        guard let document = try? SwiftSoup.parseBodyFragment(""), let body = document.body() else {
            return [.text(NSAttributedString(string: content, attributes: attributes))]
        }
        try? body.addClass("glossary-content glossary-group")
        try? body.attr("data-dictionary", dictionary)
        if let data = content.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            appendStructured(value, parent: body, depth: 0)
        } else if content.contains("<") {
            try? body.html(content)
        } else { try? body.appendText(content) }
        let css = NativeDictionaryCSS(stylesheet, viewportWidth: availableWidth)
        func containsNativeLayout(_ node: SwiftSoup.Node, depth: Int = 0) -> Bool {
            guard depth < 64 else { return false }
            return node.getChildNodes().contains { child in
                if let element = child as? Element {
                    let display = css.declarations(for: element)["display"] as? String ?? ""
                    if display == "none" { return false }
                    if element.tagName().lowercased() == "table" || ["flex", "inline-flex", "grid", "inline-grid"].contains(display) { return true }
                }
                return containsNativeLayout(child, depth: depth + 1)
            }
        }
        func extract(_ nodes: [SwiftSoup.Node], inherited: [NSAttributedString.Key: Any], depth: Int) -> [NativeDictionaryGlossaryBlock] {
            guard depth < 64 else { return [] }
            var blocks: [NativeDictionaryGlossaryBlock] = []
            var text = NSMutableAttributedString(string: "")
            func flush() {
                if text.length > 0 { blocks.append(.text(text.copy() as! NSAttributedString)); text = NSMutableAttributedString(string: "") }
            }
            for node in nodes {
                if let element = node as? Element {
                    let declarations = css.declarations(for: element)
                    guard declarations["display"] as? String != "none" else { continue }
                    var styled = style(declarations, attributes: inherited)
                    if let language = try? element.attr("lang"), !language.isEmpty { styled[.nativeDictionaryLanguage] = language }
                    let tag = element.tagName().lowercased()
                    let display = declarations["display"] as? String ?? ""
                    if ["flex", "inline-flex", "grid", "inline-grid"].contains(display) {
                        flush()
                        let children = element.getChildNodes().flatMap { child -> [NativeDictionaryGlossaryBlock] in
                            if let text = child as? TextNode, text.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
                            let content = extract([child], inherited: styled, depth: depth + 1)
                            return content.count > 1 ? [.box(.init(children: content, declarations: [:]))] : content
                        }
                        blocks.append(.box(.init(children: children, declarations: declarations)))
                        continue
                    }
                    if tag == "table" {
                        flush()
                        let font = styled[.font] as? UIFont ?? .systemFont(ofSize: 15 * scale)
                        func inheritedCell(_ cell: Element, header: Bool) -> [NSAttributedString.Key: Any] {
                            var value = styled, ancestors: [Element] = []
                            var ancestor = cell.parent()
                            while let current = ancestor, current !== element { ancestors.append(current); ancestor = current.parent() }
                            for current in ancestors.reversed() { value = style(css.declarations(for: current), attributes: value) }
                            if header {
                                let inheritedFont = value[.font] as? UIFont ?? font
                                let descriptor = inheritedFont.fontDescriptor.withSymbolicTraits(.traitBold) ?? inheritedFont.fontDescriptor
                                value[.font] = UIFont(descriptor: descriptor, size: inheritedFont.pointSize)
                            }
                            return value
                        }
                        let model = NativeDictionaryTable.model(element, stylesheet: css, font: font, contentBlocks: { cell, header in
                            guard containsNativeLayout(cell) else { return [] }
                            return extract(cell.getChildNodes(), inherited: style(css.declarations(for: cell), attributes: inheritedCell(cell, header: header)),
                                           depth: depth + 1)
                        }) { cell, header in
                            let result = NSMutableAttributedString(string: "")
                            appendHTML(cell, to: result, attributes: inheritedCell(cell, header: header), dictionary: dictionary,
                                       depth: depth + 1, stylesheet: css, availableWidth: availableWidth)
                            if result.string.hasSuffix("\t") { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
                            return result
                        }
                        blocks.append(.table(model)); continue
                    }
                    if containsNativeLayout(element) {
                        flush()
                        blocks += extract(element.getChildNodes(), inherited: styled, depth: depth + 1)
                        continue
                    }
                }
                appendHTML(node, to: text, attributes: inherited, dictionary: dictionary, depth: depth,
                           stylesheet: css, availableWidth: availableWidth)
            }
            flush()
            return blocks
        }
        let inherited = style(css.declarations(for: body), attributes: attributes)
        return extract(body.getChildNodes(), inherited: inherited, depth: 0)
    }

    private static func appendStructured(_ value: Any, parent: Element, depth: Int) {
        guard depth < 64 else { return }
        if let text = value as? String { try? parent.appendText(text); return }
        if let array = value as? [Any] {
            let strings = array.allSatisfy { $0 is String }
            let links = array.allSatisfy { child in
                guard let object = child as? [String: Any] else { return false }
                let content = object["type"] as? String == "structured-content" ? object["content"] as? [String: Any] : object
                return content?["tag"] as? String == "a"
            }
            if array.count > 1, (strings && parent.tagName().uppercased() != "SPAN") || links,
               let tag = try? Tag.valueOf("ul"), let itemTag = try? Tag.valueOf("li") {
                let list = Element(tag, ""); try? list.addClass("glossary-list")
                try? parent.appendChild(list)
                for child in array {
                    let item = Element(itemTag, ""); try? list.appendChild(item)
                    appendStructured(child, parent: item, depth: depth + 1)
                }
            } else {
                for child in array { appendStructured(child, parent: parent, depth: depth + 1) }
            }
            return
        }
        guard let node = value as? [String: Any], let tag = try? Tag.valueOf(node["tag"] as? String ?? "span") else { return }
        let element = Element(tag, "")
        let tagName = element.tagName().lowercased()
        guard !["script", "style", "iframe"].contains(tagName) else { return }
        try? element.addClass("gloss-sc-" + tagName)
        if node["type"] as? String == "structured-content" { try? element.addClass("structured-content") }
        for key in ["href", "title", "lang", "id"] {
            if let value = node[key] as? String { try? element.attr(key, value) }
        }
        if let classes = node["class"] as? String { try? element.addClass(classes) }
        for key in ["colSpan", "rowSpan"] {
            if let value = node[key] { try? element.attr(key.lowercased(), String(describing: value)) }
        }
        for (key, value) in node["data"] as? [String: Any] ?? [:] {
            let cjk = key.unicodeScalars.first.map { (0x3000...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) } ?? false
            try? element.attr("data-sc" + (cjk ? "" : "-") + NativeDictionaryCSS.kebab(key), String(describing: value))
        }
        if let style = node["style"] as? [String: Any] {
            let declarations = style.map { key, value -> String in
                let units = key.hasPrefix("margin") && value is NSNumber ? "em" : ""
                return NativeDictionaryCSS.kebab(key) + ":" + String(describing: value) + units
            }.joined(separator: ";")
            try? element.attr("style", declarations)
        }
        if tagName == "img", let data = try? JSONSerialization.data(withJSONObject: node), let metadata = String(data: data, encoding: .utf8) {
            try? element.attr("data-native-media", metadata)
            if let path = node["path"] as? String { try? element.attr("src", path) }
        }
        try? parent.appendChild(element)
        if let child = node["content"] { appendStructured(child, parent: element, depth: depth + 1) }
    }

    private static func appendHTML(_ node: SwiftSoup.Node, to output: NSMutableAttributedString,
                                   attributes: [NSAttributedString.Key: Any], dictionary: String, depth: Int, stylesheet: NativeDictionaryCSS,
                                   availableWidth: CGFloat = 260) {
        guard depth < 64, output.length < 250_000 else { return }
        if let text = node as? TextNode { output.append(NSAttributedString(string: text.getWholeText(), attributes: attributes)); return }
        var styled = attributes
        if let element = node as? Element {
            let tag = element.tagName().lowercased()
            guard !["script", "style", "iframe"].contains(tag) else { return }
            let css = stylesheet.declarations(for: element)
            guard css["display"] as? String != "none" else { return }
            styled = style(css, attributes: styled)
            if tag == "ruby" {
                let start = output.length
                var reading = ""
                for child in node.getChildNodes() {
                    if let ruby = child as? Element, ruby.tagName() == "rt" { reading += (try? ruby.text()) ?? "" }
                    else if (child as? Element)?.tagName() != "rp" {
                        appendHTML(child, to: output, attributes: styled, dictionary: dictionary, depth: depth + 1,
                                   stylesheet: stylesheet, availableWidth: availableWidth)
                    }
                }
                if output.length > start && !reading.isEmpty {
                    output.addAttribute(.nativeDictionaryRuby, value: reading, range: NSRange(location: start, length: output.length - start))
                }
                return
            }
            guard tag != "rt", tag != "rp" else { return }
            if let language = try? element.attr("lang"), !language.isEmpty { styled[.nativeDictionaryLanguage] = language }
            if tag == "img", let src = try? element.attr("src") {
                var metadata: [String: Any] = [:]
                if let json = try? element.attr("data-native-media"), let data = json.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { metadata = object }
                var path = src
                if let components = URLComponents(string: src), components.scheme == "image" {
                    path = components.queryItems?.first(where: { $0.name == "path" })?.value ?? src
                }
                metadata["path"] = path
                for key in ["width", "height", "alt", "title"] {
                    if let value = try? element.attr(key), !value.isEmpty { metadata[key] = value }
                }
                metadata["style"] = css
                output.append(NativeDictionaryMedia.attachment(metadata, dictionary: dictionary,
                    attributes: styled, availableWidth: availableWidth))
                return
            }
            if tag == "br" { output.append(NSAttributedString(string: "\n", attributes: styled)); return }
            if let font = styled[.font] as? UIFont, ["i", "em"].contains(tag) { styled[.font] = UIFont.italicSystemFont(ofSize: font.pointSize) }
            if let font = styled[.font] as? UIFont, ["b", "strong"].contains(tag) { styled[.font] = UIFont.boldSystemFont(ofSize: font.pointSize) }
            if tag == "a", let href = try? element.attr("href"), let url = URL(string: href) { styled[.link] = url }
            if tag == "li" { output.append(NSAttributedString(string: "\n• ", attributes: styled)) }
            for child in node.getChildNodes() { appendHTML(child, to: output, attributes: styled, dictionary: dictionary, depth: depth + 1,
                                   stylesheet: stylesheet, availableWidth: availableWidth) }
            if tag == "td" || tag == "th" { output.append(NSAttributedString(string: "\t", attributes: styled)) }
            if ["p", "div", "li", "tr"].contains(tag) { output.append(NSAttributedString(string: "\n", attributes: styled)) }
        } else {
            for child in node.getChildNodes() {
                appendHTML(child, to: output, attributes: styled, dictionary: dictionary, depth: depth + 1,
                           stylesheet: stylesheet, availableWidth: availableWidth)
            }
        }
    }

    private static func style(_ css: [String: Any], attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        NativeDictionaryCSS.attributes(css, inherited: attributes)
    }

    static func morae(_ reading: String) -> [String] {
        let small = Set("ぁぃぅぇぉゃゅょゎァィゥェォャュョヮ")
        var result: [String] = []
        for character in reading {
            if small.contains(character), !result.isEmpty { result[result.count - 1].append(character) }
            else { result.append(String(character)) }
        }
        return result
    }

    static func pitch(reading: String, accent: [String: Any], scale: CGFloat) -> NSAttributedString {
        let mora = morae(reading)
        let position = accent["position"] as? Int ?? 0
        let pattern = (accent["position"] as? String).map(Array.init)
        let nasal = Set(accent["nasal"] as? [Int] ?? [])
        let devoice = Set(accent["devoice"] as? [Int] ?? [])
        func high(_ index: Int) -> Bool {
            if let pattern { return pattern.indices.contains(index) && pattern[index] == "H" }
            return position == 1 ? index == 0 : index > 0 && (position == 0 || index < position)
        }
        let cell = 20 * scale, width = CGFloat(max(1, mora.count) + 1) * cell
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: 38 * scale)).image { renderer in
            let context = renderer.cgContext
            context.setStrokeColor(UIColor.label.cgColor); context.setLineWidth(1.3 * scale)
            for (index, text) in mora.enumerated() {
                let x = CGFloat(index) * cell, y = (high(index) ? 2.0 : 9.0) * scale
                context.move(to: CGPoint(x: x, y: y)); context.addLine(to: CGPoint(x: x + cell, y: y))
                context.addLine(to: CGPoint(x: x + cell, y: (high(index + 1) ? 2 : 9) * scale)); context.strokePath()
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 13 * scale), .foregroundColor: UIColor.label]
                let size = (text as NSString).size(withAttributes: attributes)
                (text as NSString).draw(at: CGPoint(x: x + (cell - size.width) / 2, y: 15 * scale), withAttributes: attributes)
                if nasal.contains(index + 1) {
                    context.strokeEllipse(in: CGRect(x: x + cell / 2 - 2 * scale, y: 30 * scale, width: 4 * scale, height: 4 * scale))
                }
                if devoice.contains(index + 1) {
                    context.saveGState(); context.setLineDash(phase: 0, lengths: [2 * scale, 2 * scale])
                    context.strokeEllipse(in: CGRect(x: x + 2 * scale, y: 13 * scale, width: cell - 4 * scale, height: 18 * scale))
                    context.restoreGState()
                }
            }
        }
        let attachment = NSTextAttachment(); attachment.image = image
        attachment.bounds = CGRect(origin: .zero, size: image.size)
        let result = NSMutableAttributedString(attachment: attachment)
        let positions: String
        if let pattern {
            var downs: [Int] = []
            for index in 1..<max(1, pattern.count) where pattern[index - 1] == "H" && pattern[index] == "L" { downs.append(index) }
            positions = downs.isEmpty ? (pattern.first == "L" ? "0" : "-1") : downs.map(String.init).joined(separator: ", ")
        } else { positions = String(position) }
        result.append(NSAttributedString(string: " [" + positions + "]", attributes: [
            .font: UIFont.systemFont(ofSize: 13 * scale), .foregroundColor: UIColor.label]))
        return result
    }

    static func miningFields(_ entry: [String: Any], slot: Int) -> [String: String] {
        ["expression": entry["expression"] as? String ?? "", "reading": entry["reading"] as? String ?? "",
         "matched": entry["matched"] as? String ?? "", "slotIndex": String(slot)]
    }
}

private final class NativeDictionaryScrollView: UIScrollView {
    var onHeightChanged: ((CGFloat) -> Void)?
    var onAppearanceChanged: (() -> Void)?
    private var reportedHeight: CGFloat = -1

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        traitCollection.performAsCurrent { onAppearanceChanged?() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = ceil(contentSize.height)
        guard height.isFinite, height > 0, height != reportedHeight else { return }
        reportedHeight = height
        DispatchQueue.main.async { [weak self] in
            guard let self, self.reportedHeight == height else { return }
            self.onHeightChanged?(height)
        }
    }
}
