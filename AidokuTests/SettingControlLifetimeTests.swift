import Testing
import UIKit
@testable import Aidoku

@MainActor @Suite(.serialized) struct SettingControlLifetimeTests {
    private final class Capture {}

    @MainActor private final class DisplayCycle: NSObject {
        private var frames = 0
        private var link: CADisplayLink?
        private var completion: CheckedContinuation<Void, Never>?

        static func wait() async {
            await withCheckedContinuation { continuation in
                let cycle = DisplayCycle()
                cycle.completion = continuation
                let link = CADisplayLink(target: cycle, selector: #selector(cycle.tick))
                cycle.link = link
                link.add(to: .main, forMode: .common)
            }
        }

        @objc private func tick() {
            frames += 1
            // The second callback follows a complete mounted display interval.
            guard frames == 2 else { return }
            link?.invalidate()
            link = nil
            let completion = completion
            self.completion = nil
            completion?.resume()
        }
    }

    @Test func switchReleasesHandlerWithControl() {
        weak var captured: Capture?
        autoreleasepool {
            let object = Capture()
            captured = object
            let control = UISwitch()
            control.handleChange { _ in _ = object }
        }
        #expect(captured == nil)
    }

    @Test func stepperReleasesHandlerWithControl() async throws {
        // Native iOS 26 UIStepper has an independently confirmed framework cycle.
        // The modern settings lease must release its callback on pool return.
        var hostedLease: SettingStepperLease?
        weak var releasedLease: SettingStepperLease?
        weak var captured: Capture?
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        var hostedWindow: UIWindow? = autoreleasepool {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
            let controller = UIViewController()
            window.rootViewController = controller
            window.isHidden = false
            let lease = SettingStepperLease()
            hostedLease = lease
            releasedLease = lease
            let control = lease.control
            control.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
            let object = Capture()
            captured = object
            control.handleChange { _ in _ = object }
            controller.view.addSubview(control)
            window.layoutIfNeeded()
            control.layoutIfNeeded()
            return window
        }
        await DisplayCycle.wait()
        #expect(hostedLease != nil)
        autoreleasepool {
            hostedWindow?.rootViewController?.view.subviews.forEach { $0.removeFromSuperview() }
            hostedWindow?.isHidden = true
            hostedWindow?.rootViewController = nil
            hostedWindow = nil
            hostedLease = nil
        }
        for _ in 0..<200 {
            let didRelease = autoreleasepool { releasedLease == nil && captured == nil }
            if didRelease { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(releasedLease == nil)
        #expect(captured == nil)
    }

    @Test func repeatedSettingsLeasesReuseControlAndResetAllBindings() {
        var originalIdentity: ObjectIdentifier?
        var createdAfterWarmup = 0
        for index in 0..<100 {
            weak var releasedLease: SettingStepperLease?
            weak var releasedCapture: Capture?
            autoreleasepool {
                let lease = SettingStepperLease()
                releasedLease = lease
                let control = lease.control
                let identity = ObjectIdentifier(control)
                if let originalIdentity { #expect(identity == originalIdentity) }
                else { originalIdentity = identity }
                #expect(control.defaultsKey == nil)
                #expect(control.accessibilityLabel == nil && control.accessibilityValue == nil)
                #expect(control.accessibilityHint == nil && control.accessibilityIdentifier == nil)
                #expect(control.allTargets.isEmpty)
                #expect(control.minimumValue == 0 && control.maximumValue == 100)
                #expect(control.stepValue == 1 && control.value == 0)
                #expect(!control.wraps && control.autorepeat && control.isContinuous && control.isEnabled)
                let captured = Capture()
                releasedCapture = captured
                control.handleChange { _ in _ = captured }
                control.defaultsKey = "audit.stepper.lease"
                control.accessibilityLabel = "old setting"
                control.accessibilityValue = "old value"
                control.accessibilityHint = "old hint"
                control.accessibilityIdentifier = "old identifier"
                if index.isMultiple(of: 2) {
                    control.maximumValue = 300
                    control.minimumValue = 200
                } else {
                    control.minimumValue = -300
                    control.maximumValue = -200
                }
                control.stepValue = 3
                control.value = 12
                control.wraps = true
                control.autorepeat = false
                control.isContinuous = false
                control.isEnabled = false
            }
            #expect(releasedLease == nil)
            #expect(releasedCapture == nil)
            if index == 0 { createdAfterWarmup = SettingStepperLease.createdControlCount }
            #expect(SettingStepperLease.createdControlCount == createdAfterWarmup)
        }
    }

    @Test func simultaneousLeasesNeverShareAControl() {
        let first = SettingStepperLease()
        let second = SettingStepperLease()
        #expect(first.control !== second.control)
        first.control.value = 17
        second.control.value = 29
        #expect(first.control.value == 17)
        #expect(second.control.value == 29)
    }

    @Test func stepperReplacingHandlerReleasesPreviousCaptureAndUsesLatestValue() {
        let lease = SettingStepperLease()
        let control = lease.control
        weak var previous: Capture?
        autoreleasepool {
            let object = Capture()
            previous = object
            control.handleChange { _ in _ = object }
        }
        #expect(previous != nil)
        var observed: Double?
        control.handleChange { observed = $0 }
        #expect(previous == nil)
        control.value = 7
        control.sendActions(for: .valueChanged)
        #expect(observed == 7)
    }

}
