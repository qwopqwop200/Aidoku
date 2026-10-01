import UIKit

@MainActor
struct NativeDictionaryBox {
    let children: [NativeDictionaryGlossaryBlock]
    let declarations: [String: Any]
    var plainText: NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for child in children {
            switch child {
            case .text(let text): result.append(text)
            case .table(let table): result.append(table.plainText)
            case .box(let box): result.append(box.plainText)
            }
        }
        return result
    }
}

/// Native boxes keep nested tables and horizontal dictionary content interactive.
@MainActor
final class NativeDictionaryBoxView: UIView {
    private let model: NativeDictionaryBox
    private let children: [UIView]
    private let font: UIFont
    private var measuredHeight: CGFloat = 1
    init(model: NativeDictionaryBox, makeTextView: (NSAttributedString) -> UITextView) {
        self.model = model
        self.font = .systemFont(ofSize: 15)
        children = model.children.map { Self.view(for: $0, makeTextView: makeTextView) }
        super.init(frame: .zero)
        children.forEach { addSubview($0) }
        backgroundColor = NativeDictionaryCSS.color(model.declarations["background-color"] as? String ?? "transparent")
        accessibilityIdentifier = "dictionary.glossary.nativeBox"
    }
    required init?(coder: NSCoder) { nil }
    static func view(for block: NativeDictionaryGlossaryBlock,
                     makeTextView: (NSAttributedString) -> UITextView) -> UIView {
        switch block {
        case .text(let text): return makeTextView(text)
        case .table(let table): return NativeDictionaryTableView(model: table, makeTextView: makeTextView)
        case .box(let box): return NativeDictionaryBoxView(model: box, makeTextView: makeTextView)
        }
    }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight) }
    override func sizeThatFits(_ size: CGSize) -> CGSize { arrange(width: max(1, size.width), apply: false) }
    override func layoutSubviews() {
        super.layoutSubviews()
        let size = arrange(width: bounds.width, apply: true)
        if measuredHeight != size.height { measuredHeight = size.height; invalidateIntrinsicContentSize() }
    }
    private func arrange(width: CGFloat, apply: Bool) -> CGSize {
        guard width.isFinite, width > 0 else { return .zero }
        let css = model.declarations
        let padding = max(0, NativeDictionaryCSS.length(css["padding"], font: font, relativeTo: width) ?? 0)
        let gap = max(0, NativeDictionaryCSS.length(css["gap"], font: font, relativeTo: width) ?? 0)
        let contentWidth = max(1, width - padding * 2)
        let display = css["display"] as? String ?? "block"
        let row = (display == "flex" || display == "inline-flex") && !(css["flex-direction"] as? String ?? "row").hasPrefix("column")
        let grid = display == "grid" || display == "inline-grid"
        var columns = 1
        if grid {
            let template = css["grid-template-columns"] as? String ?? ""
            if template.hasPrefix("repeat("), let number = template.dropFirst(7).split(separator: ",").first.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                columns = min(32, max(1, number))
            } else { columns = min(32, max(1, template.split(separator: " ").count)) }
        } else if row { columns = max(1, children.count) }
        let cellWidth = max(1, (contentWidth - gap * CGFloat(columns - 1)) / CGFloat(columns))
        var y = padding, maxRowHeight: CGFloat = 0, column = 0
        var widths = [CGFloat](repeating: cellWidth, count: children.count)
        if row && css["flex-wrap"] as? String == "wrap" {
            widths = children.map { min(contentWidth, max(1, $0.sizeThatFits(CGSize(width: contentWidth, height: 100_000)).width)) }
        }
        var x = padding
        for (index, child) in children.enumerated() {
            let childWidth = row && css["flex-wrap"] as? String == "wrap" ? widths[index] : cellWidth
            if column > 0 && ((grid && column >= columns) || (row && x + childWidth > width - padding + 0.01)) {
                y += maxRowHeight + gap; x = padding; column = 0; maxRowHeight = 0
            }
            let size = child.sizeThatFits(CGSize(width: childWidth, height: 100_000))
            let childHeight = max(1, size.height)
            if apply { child.frame = CGRect(x: x, y: y, width: childWidth, height: childHeight) }
            maxRowHeight = max(maxRowHeight, childHeight)
            column += 1; x += childWidth + gap
            if !row && !grid { y += childHeight + gap; x = padding; column = 0; maxRowHeight = 0 }
        }
        let natural = row || grid ? y + maxRowHeight + padding : max(padding * 2, y - gap + padding)
        let explicit = NativeDictionaryCSS.length(css["height"], font: font, relativeTo: natural)
        return CGSize(width: width, height: max(1, explicit ?? natural))
    }
}
