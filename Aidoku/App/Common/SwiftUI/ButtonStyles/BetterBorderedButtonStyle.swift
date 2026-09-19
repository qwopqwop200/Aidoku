//
//  BetterBorderedButtonStyle.swift
//  Aidoku
//
//  Created by Skitty on 5/11/25.
//

import SwiftUI

// same as BorderedButtonStyle, but with a different background color
struct BetterBorderedButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let backgroundOpacity = configuration.isPressed ? (colorScheme == .dark ? 1.4 : 0.65) : 1
        let labelOpacity = configuration.isPressed && colorScheme == .light ? 0.75 : 1
        let foregroundColor = configuration.isPressed && colorScheme == .dark
            ? Color(uiColor: .accent).mix(with: .white, by: 0.1)
            : Color.accentColor

        HStack {
            configuration.label
                .opacity(labelOpacity)
        }
        .padding(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))
        .foregroundStyle(foregroundColor)
        .background(Color(uiColor: .tertiarySystemFill).opacity(backgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private extension Color {
    func mix(with color: Color, by percentage: Double) -> Color {
        let clampedPercentage = min(max(percentage, 0), 1)

        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard UIColor(self).getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              UIColor(color).getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else { return self }
        let weight = CGFloat(clampedPercentage)
        let red = Double((1 - weight) * r1 + weight * r2)
        let green = Double((1 - weight) * g1 + weight * g2)
        let blue = Double((1 - weight) * b1 + weight * b2)
        let alpha = Double((1 - weight) * a1 + weight * a2)

        return Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}
