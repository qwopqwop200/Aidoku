import UIKit
import SwiftSoup

@MainActor
enum NativeDictionaryGlossaryBlock {
    case text(NSAttributedString)
    case table(NativeDictionaryTable.Model)
    case box(NativeDictionaryBox)
}

@MainActor
enum NativeDictionaryTable {
    struct Cell {
        let row: Int
        let column: Int
        let rowSpan: Int
        let columnSpan: Int
        let content: NSAttributedString
        let padding: CGFloat
        let borderWidth: CGFloat
        let borderColor: UIColor
        let background: UIColor
        let verticalAlignment: String
        var blocks: [NativeDictionaryGlossaryBlock] = []
    }
    struct Model {
        let cells: [Cell]
        let rows: Int
        let columns: Int
        var plainText: NSAttributedString {
            let result = NSMutableAttributedString(string: "")
            for row in 0..<rows {
                for cell in cells.filter({ $0.row == row }).sorted(by: { $0.column < $1.column }) {
                    result.append(cell.content); result.append(NSAttributedString(string: "\t"))
                }
                result.append(NSAttributedString(string: "\n"))
            }
            return result
        }
    }
    static func model(_ table: Element, stylesheet: NativeDictionaryCSS, font: UIFont,
                      contentBlocks: ((Element, Bool) -> [NativeDictionaryGlossaryBlock])? = nil,
                      content: (Element, Bool) -> NSAttributedString) -> Model {
        let rows = ((try? table.select("tr").array()) ?? []).filter { row in
            var parent = row.parent()
            while let element = parent {
                if stylesheet.declarations(for: element)["display"] as? String == "none" { return false }
                if element.tagName().lowercased() == "table" { return element === table }
                parent = element.parent()
            }
            return false
        }
        let visibleRows = rows.filter { stylesheet.declarations(for: $0)["display"] as? String != "none" }
        var cells: [Cell] = [], occupied: Set<Int> = []
        var rowCount = min(128, visibleRows.count), columnCount = 0
        for (rowIndex, row) in visibleRows.prefix(128).enumerated() {
            var column = 0
            for child in row.children().array() where ["td", "th"].contains(child.tagName().lowercased()) {
                guard stylesheet.declarations(for: child)["display"] as? String != "none" else { continue }
                while occupied.contains(rowIndex * 64 + column), column < 32 { column += 1 }
                guard column < 32, cells.count < 1024 else { break }
                let span = min(32 - column, max(1, Int((try? child.attr("colspan")) ?? "") ?? 1))
                let rowSpan = min(128 - rowIndex, max(1, Int((try? child.attr("rowspan")) ?? "") ?? 1))
                for y in rowIndex..<(rowIndex + rowSpan) { for x in column..<(column + span) { occupied.insert(y * 64 + x) } }
                let css = stylesheet.declarations(for: child)
                let foreground = NativeDictionaryCSS.color(css["color"] as? String ?? "currentColor") ?? .label
                let border = css["border"] as? String ?? ""
                let suppressesBorder = ["none", "hidden"].contains(css["border-style"] as? String ?? "")
                    || border.split(separator: " ").contains(where: { $0 == "none" || $0 == "hidden" })
                let borderWidth = suppressesBorder ? 0 : NativeDictionaryCSS.length(css["border-width"], font: font, relativeTo: 1)
                    ?? border.split(separator: " ").first.flatMap { NativeDictionaryCSS.length(String($0), font: font, relativeTo: 1) } ?? 1
                let borderColor = NativeDictionaryCSS.color(css["border-color"] as? String ?? "currentColor", current: foreground) ?? foreground
                let header = child.tagName().lowercased() == "th" || row.parent()?.tagName().lowercased() == "thead"
                let background = NativeDictionaryCSS.color(css["background-color"] as? String ?? (header ? "var(--background-color-dark1)" : "transparent")) ?? .clear
                let padding = NativeDictionaryCSS.length(css["padding"], font: font, relativeTo: font.pointSize) ?? font.pointSize * 0.25
                cells.append(Cell(row: rowIndex, column: column, rowSpan: rowSpan, columnSpan: span,
                    content: content(child, header), padding: max(0, padding), borderWidth: max(0, borderWidth), borderColor: borderColor,
                    background: background, verticalAlignment: css["vertical-align"] as? String ?? "top",
                    blocks: contentBlocks?(child, header) ?? []))
                column += span; columnCount = max(columnCount, column); rowCount = max(rowCount, rowIndex + rowSpan)
            }
        }
        return Model(cells: cells, rows: rowCount, columns: max(1, columnCount))
    }
}

/// Actual native cells retain TextKit selection/ruby/link handlers instead of flattening a table into tabs or a bitmap.
@MainActor
final class NativeDictionaryTableView: UIView {
    let model: NativeDictionaryTable.Model
    private let cellViews: [(container: UIView, text: UIView)]
    private var measuredHeight: CGFloat = 44
    init(model: NativeDictionaryTable.Model, makeTextView: (NSAttributedString) -> UITextView) {
        self.model = model
        cellViews = model.cells.map { cell in
            let container = UIView()
            let text: UIView = cell.blocks.isEmpty ? makeTextView(cell.content)
                : NativeDictionaryBoxView(model: .init(children: cell.blocks, declarations: [:]), makeTextView: makeTextView)
            container.backgroundColor = cell.background
            container.layer.borderWidth = cell.borderWidth / 2
            container.layer.borderColor = cell.borderColor.cgColor
            container.addSubview(text)
            return (container, text)
        }
        super.init(frame: .zero)
        cellViews.forEach { addSubview($0.container) }
        accessibilityIdentifier = "dictionary.glossary.nativeTable"
        layer.borderWidth = model.cells.map(\.borderWidth).max() ?? 0
        layer.borderColor = model.cells.first?.borderColor.cgColor
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight) }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        guard size.width.isFinite, size.width > 0 else { return .zero }
        bounds.size.width = size.width
        layoutSubviews()
        return CGSize(width: size.width, height: measuredHeight)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, model.rows > 0 else { return }
        var columnWidths = [CGFloat](repeating: 1, count: model.columns)
        for (index, cell) in model.cells.enumerated() {
            let preferred = min(bounds.width, cellViews[index].text.sizeThatFits(CGSize(width: 10_000, height: 10_000)).width + cell.padding * 2)
            for column in cell.column..<(cell.column + cell.columnSpan) {
                columnWidths[column] = max(columnWidths[column], preferred / CGFloat(cell.columnSpan))
            }
        }
        let total = columnWidths.reduce(0, +)
        columnWidths = columnWidths.map { bounds.width * $0 / max(1, total) }
        var heights = [CGFloat](repeating: 1, count: model.rows)
        var contentHeights = [CGFloat](repeating: 0, count: model.cells.count)
        for (index, cell) in model.cells.enumerated() {
            let width = columnWidths[cell.column..<(cell.column + cell.columnSpan)].reduce(0, +)
            let height = cellViews[index].text.sizeThatFits(CGSize(width: max(1, width - cell.padding * 2), height: 10_000)).height
            contentHeights[index] = height
            let required = height + cell.padding * 2
            let existing = heights[cell.row..<(cell.row + cell.rowSpan)].reduce(0, +)
            if required > existing {
                let addition = (required - existing) / CGFloat(cell.rowSpan)
                for row in cell.row..<(cell.row + cell.rowSpan) { heights[row] += addition }
            }
        }
        for (index, cell) in model.cells.enumerated() {
            let x = columnWidths.prefix(cell.column).reduce(0, +), y = heights.prefix(cell.row).reduce(0, +)
            let width = columnWidths[cell.column..<(cell.column + cell.columnSpan)].reduce(0, +)
            let height = heights[cell.row..<(cell.row + cell.rowSpan)].reduce(0, +)
            let views = cellViews[index]
            views.container.frame = CGRect(x: x, y: y, width: width, height: height)
            views.container.layer.borderColor = cell.borderColor.resolvedColor(with: traitCollection).cgColor
            let top: CGFloat
            switch cell.verticalAlignment {
            case "middle": top = (height - contentHeights[index]) / 2
            case "bottom": top = height - contentHeights[index] - cell.padding
            default: top = cell.padding
            }
            views.text.frame = CGRect(x: cell.padding, y: max(cell.padding, top),
                                      width: max(1, width - cell.padding * 2), height: contentHeights[index])
        }
        let height = ceil(heights.reduce(0, +))
        if height != measuredHeight { measuredHeight = height; invalidateIntrinsicContentSize() }
    }
}
