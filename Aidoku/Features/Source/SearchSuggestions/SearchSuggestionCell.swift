import UIKit

/// A compact completion row: matching text and namespace on the left, count on the right.
final class SearchSuggestionCell: UITableViewCell {
    let titleLabel = UILabel()
    let countLabel = UILabel()

    static var rowHeight: CGFloat {
        max(44, UIFont.preferredFont(forTextStyle: .body).lineHeight + 16)
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .secondarySystemBackground
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.adjustsFontForContentSizeCategory = true
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = .secondaryLabel
        countLabel.textAlignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        for label in [titleLabel, countLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(label)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -12),
            countLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            countLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
        isAccessibilityElement = true
        accessibilityTraits.insert(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with suggestion: SearchSuggestion, matching term: String) {
        let font = UIFont.preferredFont(forTextStyle: .body)
        let label = NSMutableAttributedString(string: suggestion.text, attributes: [.font: font, .foregroundColor: UIColor.label])
        if !term.isEmpty {
            let text = suggestion.text as NSString
            var remaining = NSRange(location: 0, length: text.length)
            while remaining.length > 0 {
                let match = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: remaining)
                guard match.location != NSNotFound, match.length > 0 else { break }
                label.addAttributes([
                    .foregroundColor: UIColor.link,
                    .font: UIFont.systemFont(ofSize: font.pointSize, weight: .semibold)
                ], range: match)
                remaining = NSRange(location: NSMaxRange(match), length: text.length - NSMaxRange(match))
            }
        }
        if let namespace = suggestion.namespace, !namespace.isEmpty {
            label.append(NSAttributedString(string: " (\(namespace))", attributes: [
                .font: UIFont.preferredFont(forTextStyle: .subheadline), .foregroundColor: UIColor.secondaryLabel
            ]))
        }
        titleLabel.attributedText = label
        countLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        countLabel.text = suggestion.count.flatMap { $0 >= 0 ? $0.formatted() : nil }
        accessibilityLabel = [label.string, countLabel.text].compactMap { $0 }.joined(separator: ", ")
    }
}
