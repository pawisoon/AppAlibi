import AppKit
import SwiftUI

// Adapted from ZuckOff's macOS target (ZuckoffCore/MacUI/MacComponents.swift and UI/Theme.swift).

struct AnimatedSymbol: View {
    enum Effect {
        case pulse, bounce, variableColor, breathe, none
    }

    let name: String
    var size: CGFloat = 72
    var effect: Effect = .none

    var body: some View {
        image
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var image: some View {
        let base = Image(systemName: name)
            .scaledFont(size, weight: .light)
            .foregroundStyle(.tint)
        switch effect {
        case .pulse: base.symbolEffect(.pulse, options: .repeating)
        case .bounce: base.symbolEffect(.bounce, options: .repeat(.continuous))
        case .variableColor: base.symbolEffect(.variableColor.iterative.reversing, options: .repeating)
        case .breathe: base.symbolEffect(.breathe, options: .repeating)
        case .none: base
        }
    }
}

struct CapsuleBadge: View {
    let title: LocalizedStringResource
    var tint: Color = .accentColor

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.16)))
            .foregroundStyle(tint)
    }
}

extension Image {
    /// The app icon from the asset catalog. `NSApp.applicationIconImage` is
    /// blank while the app runs without a Dock icon.
    @MainActor static var appIcon: Image {
        if let icon = NSImage(named: "AppIcon") {
            return Image(nsImage: icon)
        }
        return Image(nsImage: NSApp.applicationIconImage)
    }
}

private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: size)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    /// Use instead of `.font(.system(size:))`, which never scales.
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }
}
