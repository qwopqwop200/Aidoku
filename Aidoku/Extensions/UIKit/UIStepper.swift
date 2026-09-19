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

// iOS 26's UIStepperDesignLibraryVisualElement retains its UIStepper owner even
// after window removal. Reuse controls by scoped settings-cell ownership instead
// of allocating another native retain cycle on every settings visit.
@MainActor
final class SettingStepperLease {
    private static var idleControls: [UIStepper] = []
    private(set) static var createdControlCount = 0
    let control: UIStepper

    init() {
        if let idle = Self.idleControls.popLast() {
            control = idle
        } else {
            control = UIStepper()
            Self.createdControlCount += 1
        }
    }

    deinit {
        let control = control
        // UIKit owners normally die on the main thread. Keep cleanup safe when
        // the final Swift owner is released by an asynchronous task instead.
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
        // Do not evict idle controls: the OS cycle would keep the evicted object
        // alive while its next replacement added another. Storage is bounded by
        // the largest number of simultaneously owned settings controls.
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
