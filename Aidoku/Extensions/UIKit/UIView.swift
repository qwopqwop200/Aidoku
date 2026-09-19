//
//  UIView.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 5/26/22.
//

import UIKit

extension UIView {
//    var parentViewController: UIViewController? {
//        var parentResponder: UIResponder? = self.next
//        while parentResponder != nil {
//            if let viewController = parentResponder as? UIViewController {
//                return viewController
//            }
//            parentResponder = parentResponder?.next
//        }
//        return nil
//    }

    func addOverlay(color: UIColor) {
        let overlay = UIView()
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.frame = bounds
        overlay.backgroundColor = color
        overlay.alpha = 0
        overlay.tag = color.hash
        addSubview(overlay)
    }

    func showOverlay(color: UIColor, alpha: CGFloat = 1) {
        if let overlay = viewWithTag(color.hash) {
            overlay.alpha = alpha
        }
    }

    func hideOverlay(color: UIColor) {
        if let overlay = viewWithTag(color.hash) {
            overlay.alpha = 0
        }
    }
}

extension UIView {
    /// Finds the first scroll view in the view hierarchy, searching depth-first.
    func firstScrollView() -> UIScrollView? {
        if let scrollView = self as? UIScrollView {
            return scrollView
        }
        for subview in subviews {
            if let scrollView = subview.firstScrollView() {
                return scrollView
            }
        }
        return nil
    }
}

extension UIScrollView {
    /// Whether the scroll view is scrolled to the top of its content.
    var isScrolledToTop: Bool {
        contentOffset.y <= -adjustedContentInset.top + 1
    }
}

extension UIView {
    func forceNoClip() {
        guard let originalClass = object_getClass(self) else { return }
        let suffix = "_AidokuNoClip"
        let originalName = NSStringFromClass(originalClass)
        guard !originalName.hasSuffix(suffix) else {
            clipsToBounds = false
            return
        }
        let subclassName = originalName + suffix
        if let subclass = NSClassFromString(subclassName) {
            object_setClass(self, subclass)
            clipsToBounds = false
            return
        }
        let selector = #selector(setter: UIView.clipsToBounds)
        guard let method = class_getInstanceMethod(originalClass, selector),
              let subclass = objc_allocateClassPair(originalClass, subclassName, 0) else { return }
        // Capture the original setter once. Looking it up from the object's current
        // class inside the replacement would recurse if a subclass is added later.
        typealias Setter = @convention(c) (UIView, Selector, Bool) -> Void
        let setter = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        let block: @convention(block) (UIView, Bool) -> Void = { view, _ in
            setter(view, selector, false)
        }
        class_addMethod(subclass, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        objc_registerClassPair(subclass)
        object_setClass(self, subclass)
        clipsToBounds = false
    }
}
