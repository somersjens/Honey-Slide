//
//  ScreenSafeArea.swift
//  Hungry Frog
//
//  The window's own safe-area insets, sampled once rather than read from a
//  nested `GeometryReader`.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The window's own safe area. The scene is laid out edge to edge, so it needs
/// the real insets to keep its content clear of the home indicator and the HUD
/// — and a `GeometryReader` nested inside the playing field reports zero for
/// them, because its container has already been inset.
///
/// Sample this in `onAppear` and keep the value in state. Reading it from
/// inside a `body` wedges SwiftUI's update pass: the view renders once and then
/// stops receiving updates entirely, which shows up as a frozen playing field.
struct ScreenSafeArea: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
    var left: CGFloat = 0
    var right: CGFloat = 0

    @MainActor
    static var current: ScreenSafeArea {
#if canImport(UIKit)
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        guard let insets = window?.safeAreaInsets else { return ScreenSafeArea() }
        return ScreenSafeArea(top: insets.top,
                              bottom: insets.bottom,
                              left: insets.left,
                              right: insets.right)
#else
        return ScreenSafeArea()
#endif
    }
}
