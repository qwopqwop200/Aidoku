import SwiftUI
import UIKit

/// Native settings control with scoped reuse for UIKit's retained visual element.
struct SettingStepper: UIViewRepresentable {
    @Binding private var value: Double
    private let bounds: ClosedRange<Double>
    private let step: Double
    private let label: String
    @Environment(\.isEnabled) private var isEnabled

    init(value: Binding<Double>, in bounds: ClosedRange<Double>, step: Double = 1, accessibilityLabel: String) {
        _value = value
        self.bounds = bounds
        self.step = step
        label = accessibilityLabel
    }

    @MainActor final class Coordinator: NSObject {
        var lease: SettingStepperLease? = SettingStepperLease()
        var binding: Binding<Double>?
        func control() -> UIStepper {
            let lease = lease ?? SettingStepperLease()
            self.lease = lease
            return lease.control
        }
        @objc func changed(_ sender: UIStepper) { binding?.wrappedValue = sender.value }
    }

    /// SwiftUI syncs a root UIControl's enabled state with the environment; a plain
    /// container keeps invalid ranges disabled.
    @MainActor final class Container: UIView {
        let control: UIStepper

        init(control: UIStepper) {
            self.control = control
            super.init(frame: .zero)
            addSubview(control)
            setContentHuggingPriority(.required, for: .horizontal)
            setContentCompressionResistancePriority(.required, for: .horizontal)
            setContentHuggingPriority(.required, for: .vertical)
            setContentCompressionResistancePriority(.required, for: .vertical)
        }

        required init?(coder: NSCoder) { nil }

        override var intrinsicContentSize: CGSize { control.intrinsicContentSize }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard control.superview === self else { return }
            let size = control.intrinsicContentSize
            control.frame = CGRect(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Container {
        let control = context.coordinator.control()
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return Container(control: control)
    }

    func updateUIView(_ container: Container, context: Context) {
        let control = container.control
        context.coordinator.binding = $value
        control.accessibilityLabel = label
        control.accessibilityValue = String(format: "%g", locale: Locale.current, value)
        guard bounds.lowerBound.isFinite, bounds.upperBound.isFinite,
              step.isFinite, step > 0, bounds.lowerBound < bounds.upperBound else {
            // UIKit needs a non-empty range; single-value and invalid ranges stay inert.
            control.isEnabled = false
            return
        }
        control.maximumValue = max(control.maximumValue, bounds.upperBound)
        control.minimumValue = bounds.lowerBound
        control.maximumValue = bounds.upperBound
        control.stepValue = step
        control.value = value.isFinite ? value : bounds.lowerBound
        control.isEnabled = isEnabled
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Container, context: Context) -> CGSize? {
        uiView.intrinsicContentSize
    }

    static func dismantleUIView(_ uiView: Container, coordinator: Coordinator) {
        coordinator.binding = nil
        // Returning the lease resets and detaches the control for reuse.
        coordinator.lease = nil
    }
}
