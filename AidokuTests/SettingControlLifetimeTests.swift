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
        // Native iOS 26 UIStepper has an independently confirmed framework cycle
        // (stepper-native-retain.txt). Test the actual production ownership unit:
        // the cell and lease must die and release their callback on pool return.
        weak var releasedCell: StepperTableViewCell?
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
            let cell = StepperTableViewCell(style: .default, reuseIdentifier: nil)
            cell.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
            releasedCell = cell
            releasedLease = cell.stepperLease
            let object = Capture()
            captured = object
            cell.stepperView.handleChange { _ in _ = object }
            controller.view.addSubview(cell)
            window.layoutIfNeeded()
            cell.layoutIfNeeded()
            return window
        }
        await DisplayCycle.wait()
        autoreleasepool {
            hostedWindow?.rootViewController?.view.subviews.forEach { $0.removeFromSuperview() }
            hostedWindow?.isHidden = true
            hostedWindow?.rootViewController = nil
            hostedWindow = nil
        }
        for _ in 0..<200 {
            let didRelease = autoreleasepool { releasedCell == nil && releasedLease == nil && captured == nil }
            if didRelease { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(releasedCell == nil)
        #expect(releasedLease == nil)
        #expect(captured == nil)
    }

    @Test func repeatedSettingsCellsReuseControlAndResetAllBindings() {
        var originalIdentity: ObjectIdentifier?
        var createdAfterWarmup = 0
        for index in 0..<100 {
            weak var releasedCell: StepperTableViewCell?
            weak var releasedLease: SettingStepperLease?
            weak var releasedCapture: Capture?
            autoreleasepool {
                let cell = StepperTableViewCell(style: .default, reuseIdentifier: nil)
                releasedCell = cell
                releasedLease = cell.stepperLease
                let control = cell.stepperView
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
            #expect(releasedCell == nil)
            #expect(releasedLease == nil)
            #expect(releasedCapture == nil)
            if index == 0 { createdAfterWarmup = SettingStepperLease.createdControlCount }
            #expect(SettingStepperLease.createdControlCount == createdAfterWarmup)
        }
    }

    @Test func recycledStepperIgnoresPreviousCellsRequirementNotifications() async throws {
        let requirement = "audit.stepper.requirement.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: requirement) }
        for inverted in [false, true] {
            UserDefaults.standard.set(!inverted, forKey: requirement)
            let controller = SettingsTableViewController()
            var originalIdentity: ObjectIdentifier?
            weak var releasedCell: StepperTableViewCell?
            autoreleasepool {
                var item = SettingItem(type: "stepper")
                if inverted { item.requiresFalse = requirement }
                else { item.requires = requirement }
                let cell = controller.stepperCell(for: item) as! StepperTableViewCell
                originalIdentity = ObjectIdentifier(cell.stepperView)
                releasedCell = cell
                #expect(cell.stepperView.isEnabled)
                // Enqueue an old callback before release as well as delivering one after reuse.
                NotificationCenter.default.post(name: .init(requirement), object: nil)
            }
            #expect(releasedCell == nil)
            let replacement = try #require(controller.stepperCell(for: SettingItem(type: "stepper")) as? StepperTableViewCell)
            #expect(ObjectIdentifier(replacement.stepperView) == originalIdentity)
            UserDefaults.standard.set(inverted, forKey: requirement)
            NotificationCenter.default.post(name: .init(requirement), object: nil)
            await DisplayCycle.wait()
            #expect(replacement.stepperView.isEnabled)
        }
    }

    @Test func legacyStepperValidatesSourceRangesAndStepSizes() throws {
        let controller = SettingsTableViewController()
        for (minimum, maximum) in [(10.0, 5.0), (1, 1), (.infinity, 10), (0, .nan)] {
            var item = SettingItem(type: "stepper")
            item.minimumValue = minimum
            item.maximumValue = maximum
            let cell = try #require(controller.stepperCell(for: item) as? StepperTableViewCell)
            #expect(!cell.stepperView.isEnabled)
            #expect(cell.stepperView.allTargets.isEmpty)
            #expect(cell.detailLabel.text == NSLocalizedString("SETTING_INVALID_STEPPER_RANGE"))
        }
        for step in [0.0, -1, .infinity, .nan, 2] {
            for (minimum, maximum) in [(-300.0, -200.0), (200, 300)] {
                var item = SettingItem(type: "stepper")
                item.minimumValue = minimum
                item.maximumValue = maximum
                item.stepValue = step
                let cell = try #require(controller.stepperCell(for: item) as? StepperTableViewCell)
                #expect(cell.stepperView.minimumValue == minimum)
                #expect(cell.stepperView.maximumValue == maximum)
                #expect(cell.stepperView.stepValue == (step == 2 ? 2 : 1))
            }
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
