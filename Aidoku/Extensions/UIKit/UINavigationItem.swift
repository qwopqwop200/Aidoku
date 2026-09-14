//
//  UINavigationItem.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 8/15/22.
//

import UIKit

extension UINavigationItem {

    func setTitle(upper: String?, lower: String, translateLowerTitle: Bool = false) {
        if let upper = upper {
            let upperLabel = UILabel()
            upperLabel.text = upper
            upperLabel.font = UIFont.systemFont(ofSize: 11)
            upperLabel.textColor = .secondaryLabel

            let lowerLabel = UILabel()
            lowerLabel.text = lower
            lowerLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
            lowerLabel.textAlignment = .center

            let stackView = UIStackView(arrangedSubviews: [upperLabel, lowerLabel])
            stackView.distribution = .equalCentering
            stackView.axis = .vertical
            stackView.alignment = .center

            let width = max(upperLabel.frame.size.width, lowerLabel.frame.size.width)
            stackView.frame = CGRect(x: 0, y: 0, width: width, height: 35)

            upperLabel.sizeToFit()
            lowerLabel.sizeToFit()

            self.titleView = stackView
        } else if translateLowerTitle {
            let label = TranslatedTitleLabel()
            label.kind = .chapter
            label.font = .systemFont(ofSize: 17, weight: .semibold)
            label.textAlignment = .center
            label.text = lower
            label.sizeToFit()
            self.title = lower
            self.titleView = label
        } else {
            self.titleView = nil
            self.title = lower
        }
    }
}
