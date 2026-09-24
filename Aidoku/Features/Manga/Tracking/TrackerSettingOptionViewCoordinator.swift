//
//  TrackerSettingOptionViewCoordinator.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 7/19/22.
//

import UIKit

class TrackerSettingOptionViewCoordinator: NSObject, UIPickerViewDelegate, UIPickerViewDataSource {

    var total: Int
    var numberType: NumberType

    let pickerView = UIPickerView(frame: CGRect(x: 10, y: 40, width: 250, height: 150))

    init(total: Int = 0, numberType: NumberType = .int) {
        self.total = total
        self.numberType = numberType
        super.init()
        pickerView.delegate = self
        pickerView.dataSource = self
    }

    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        1
    }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        guard total >= 0 else { return 0 }
        let scaled = total.multipliedReportingOverflow(by: numberType == .int ? 1 : 10)
        let rows = scaled.partialValue.addingReportingOverflow(1)
        return scaled.overflow || rows.overflow ? 0 : rows.partialValue
    }

    func selectionRow(for count: Float?) -> Int? {
        let value = numberType == .int ? count ?? 0 : (count ?? 0) * 10
        guard let row = Int(exactly: value.rounded(.towardZero)),
              row >= 0, row < pickerView(pickerView, numberOfRowsInComponent: 0) else { return nil }
        return row
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        row == 0 ? "-" : numberType == .int ? String(row) : String(format: "%g", locale: Locale.current, Float(row) / 10)
    }
}
