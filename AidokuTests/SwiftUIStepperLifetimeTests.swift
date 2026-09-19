import SwiftUI
import Testing
import UIKit
@testable import Aidoku

@MainActor @Suite(.serialized)
struct SwiftUIStepperLifetimeTests {
    private final class Capture { var value: Double = 5 }
    private final class WeakStepper {
        weak var value: UIStepper?
        init(_ value: UIStepper) { self.value = value }
    }
    private final class DisplayCycle: NSObject {
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
            guard frames == 2 else { return }
            link?.invalidate()
            link = nil
            let completion = completion
            self.completion = nil
            completion?.resume()
        }
    }
    private func steppers(in view: UIView) -> [UIStepper] {
        (view as? UIStepper).map { [$0] } ?? view.subviews.flatMap { steppers(in: $0) }
    }
    private func hierarchy(in view: UIView) -> [String] {
        [String(describing: type(of: view))] + view.subviews.flatMap { hierarchy(in: $0) }
    }

    @Test(arguments: [false, true], [false, true])
    func hostedSwiftUIStepperReleasesItsBindingAndNativeControls(inForm: Bool, integer: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        weak var capture: Capture?
        weak var host: UIViewController?
        var probes: [WeakStepper] = []
        var window: UIWindow? = autoreleasepool {
            let marker = Capture()
            capture = marker
            let stepper: AnyView
            if integer {
                let binding = Binding<Int>(get: { Int(marker.value) }, set: { marker.value = Double($0) })
                stepper = AnyView(SettingStepper(value: binding, in: 0...10, accessibilityLabel: "Audit value"))
            } else {
                let binding = Binding<Double>(get: { marker.value }, set: { marker.value = $0 })
                stepper = AnyView(SettingStepper(value: binding, in: 0...10, step: 1, accessibilityLabel: "Audit value"))
            }
            let content = inForm ? AnyView(Form { stepper }) : AnyView(stepper.padding())
            let controller = UIHostingController(rootView: content)
            host = controller
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
            window.rootViewController = controller
            window.isHidden = false
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            return window
        }
        await DisplayCycle.wait()
        autoreleasepool {
            if let root = window?.rootViewController?.view {
                let native = steppers(in: root)
                probes = native.map(WeakStepper.init)
                #expect(native.count == 1)
                if let control = native.first {
                    #expect(control.minimumValue == 0 && control.maximumValue == 10 && control.stepValue == 1)
                    #expect(control.isEnabled)
                    #expect(control.accessibilityLabel == "Audit value")
                    control.value = 6
                    control.sendActions(for: .valueChanged)
                    #expect(capture?.value == 6)
                }
                print("SWIFTUI_STEPPER_AUDIT form=\(inForm) integer=\(integer) nativeCount=\(native.count) hierarchy=\(hierarchy(in: root).joined(separator: ","))")
            }
            window?.isHidden = true
            window?.rootViewController = nil
            window = nil
        }
        await DisplayCycle.wait()
        for _ in 0..<200 {
            let released = autoreleasepool { host == nil && capture == nil }
            if released { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(host == nil)
        #expect(capture == nil)
        #expect(probes.count == 1)
        #expect(probes.allSatisfy { $0.value?.superview == nil && $0.value?.allTargets.isEmpty == true })
    }

    @Test func oneHundredSwiftUIVisitsReuseOneNativeControl() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let createdBefore = SettingStepperLease.createdControlCount
        var identities = Set<ObjectIdentifier>()
        for _ in 0..<100 {
            weak var marker: Capture?
            weak var host: UIViewController?
            autoreleasepool {
                let capture = Capture()
                marker = capture
                let binding = Binding<Double>(get: { capture.value }, set: { capture.value = $0 })
                let controller = UIHostingController(rootView:
                    SettingStepper(value: binding, in: 0...10, accessibilityLabel: "Repeated value"))
                host = controller
                window.rootViewController = controller
                window.layoutIfNeeded()
            }
            await DisplayCycle.wait()
            autoreleasepool {
                let native = window.rootViewController.map { steppers(in: $0.view) } ?? []
                #expect(native.count == 1)
                native.forEach { identities.insert(ObjectIdentifier($0)) }
                window.rootViewController = nil
            }
            await DisplayCycle.wait()
            #expect(host == nil)
            #expect(marker == nil)
        }
        #expect(identities.count == 1)
        #expect(SettingStepperLease.createdControlCount - createdBefore <= 1)
    }

    @Test func disabledAndSingleValueOrInvalidRangesRemainInert() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        for (range, step, disabled) in [(3.0...3.0, 1.0, false), (0.0...10.0, 0.0, false),
                                       (0.0...10.0, -1.0, false), (0.0...10.0, Double.infinity, false),
                                       (-Double.infinity...10.0, 1.0, false), (0.0...10.0, 1.0, true)] {
            window.rootViewController = UIHostingController(rootView:
                SettingStepper(value: .constant(3.0), in: range, step: step, accessibilityLabel: "Inert")
                    .disabled(disabled))
            window.layoutIfNeeded()
            await DisplayCycle.wait()
            autoreleasepool {
                let native = window.rootViewController.map { steppers(in: $0.view) } ?? []
                #expect(native.count == 1)
                #expect(native.first?.isEnabled == false)
                #expect(native.first?.accessibilityValue == "3")
                window.rootViewController = nil
            }
            await DisplayCycle.wait()
        }
    }

}
