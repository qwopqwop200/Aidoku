//
//  UIStepper.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 4/21/22.
//

import UIKit

extension UIStepper {
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
                value = UserDefaults.standard.double(forKey: key)
            } else {
                value = 0
            }
            addTarget(self, action: #selector(notifyHandler), for: .valueChanged)
        }
    }

    @objc func handleChange(_ handler: @escaping (Double) -> Void) {
        objc_setAssociatedObject(self, &Self.handlerAssociation, handler, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        addTarget(self, action: #selector(notifyHandler), for: .valueChanged)
    }

    @objc func toggleDefaultsSetting() {
        guard let key = defaultsKey else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    @objc func notifyHandler() {
        if let handler = objc_getAssociatedObject(self, &Self.handlerAssociation) as? (Double) -> Void {
            handler(value)
        }
        if let key = defaultsKey {
            NotificationCenter.default.post(name: Notification.Name(key), object: value)
        }
    }
}

// iOS 26's stepper visual element retains its UIStepper forever; reuse controls instead of leaking one per visit.
@MainActor
final class SettingStepperLease {
    private static var idleControls: [UIStepper] = []
    let control: UIStepper

    init() { control = Self.idleControls.popLast() ?? UIStepper() }

    deinit {
        let control = control
        // The last owner may be released off the main thread by a task.
        if Thread.isMainThread {
            MainActor.assumeIsolated { Self.recycle(control) }
        } else {
            Task { @MainActor in Self.recycle(control) }
        }
    }

    private static func recycle(_ control: UIStepper) {
        control.cancelTracking(with: nil)
        control.removeFromSuperview()
        control.resetSettingBindings()
        control.maximumValue = max(control.maximumValue, 100)
        control.minimumValue = 0
        control.maximumValue = 100
        control.stepValue = 1
        control.value = 0
        control.wraps = false
        control.autorepeat = true
        control.isContinuous = true
        control.isEnabled = true
        control.isHidden = false
        control.alpha = 1
        control.accessibilityLabel = nil
        control.accessibilityValue = nil
        control.accessibilityHint = nil
        control.accessibilityIdentifier = nil
        // Never evict: an evicted control stays alive anyway. Bounded by peak simultaneous use.
        idleControls.append(control)
    }
}

private extension UIStepper {
    func resetSettingBindings() {
        removeTarget(nil, action: nil, for: .allEvents)
        objc_setAssociatedObject(self, &Self.defaultsKeyAssociation, nil, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        objc_setAssociatedObject(self, &Self.handlerAssociation, nil, .OBJC_ASSOCIATION_COPY_NONATOMIC)
    }
}
