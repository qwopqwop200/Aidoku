import UIKit
@testable import Aidoku

// Flattened views of native glossary blocks, used only to assert on rendered content.

@available(iOS 18.0, *)
extension NativeDictionaryContent {
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
}

extension NativeDictionaryBox {
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

extension NativeDictionaryTable.Model {
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
