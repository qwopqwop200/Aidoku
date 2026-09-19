//
//  UISwitch.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 2/12/22.
//

import UIKit

extension UISwitch {
    private static var defaultsKeyAssociation: UInt8 = 0
    private static var handlerAssociation: UInt8 = 0

    var defaultsKey: String? {
        get {
            objc_getAssociatedObject(self, &Self.defaultsKeyAssociation) as? String
        }
        set {
            objc_setAssociatedObject(self, &Self.defaultsKeyAssociation, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC)
            addTarget(self, action: #selector(toggleDefaultsSetting), for: .valueChanged)
            if let key = newValue {
                isOn = UserDefaults.standard.bool(forKey: key)
            } else {
                isOn = false
            }
            addTarget(self, action: #selector(notifyHandler), for: .valueChanged)
        }
    }

    @objc func handleChange(_ handler: @escaping (Bool) -> Void) {
        objc_setAssociatedObject(self, &Self.handlerAssociation, handler, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        addTarget(self, action: #selector(notifyHandler), for: .valueChanged)
    }

    @objc func toggleDefaultsSetting() {
        if let key = defaultsKey {
            UserDefaults.standard.set(isOn, forKey: key)
        }
    }

    @objc func notifyHandler() {
        if let handler = objc_getAssociatedObject(self, &Self.handlerAssociation) as? (Bool) -> Void {
            handler(isOn)
        }
        if let key = defaultsKey {
            NotificationCenter.default.post(name: Notification.Name(key), object: isOn)
        }
    }
}
