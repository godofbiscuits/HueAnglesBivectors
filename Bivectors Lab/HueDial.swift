//
//  HueDial.swift
//  Bivectors Lab
//

import SwiftUI

/// A circular dial for the hue rotation Δθ in degrees (0..<360, counter-clockwise like the (a, b) plane).
struct HueDial: View {
    @Binding var degrees: Double

    /// Ring colors: at screen angle φ (clockwise from 3 o'clock) the Oklab hue is -φ,
    /// so the knob sitting at θ counter-clockwise shows hue θ.
    private static let ringColors: [Color] = (0...72).map { step in
        let rgb = OklabRotor.srgb(hueDegrees: -Double(step) * 5, lightness: 0.75, chroma: 0.12)
        return Color(.sRGB, red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let ringWidth = size * 0.14
            let knobRadius = size / 2 - ringWidth / 2
            let radians = degrees * .pi / 180

            ZStack {
                Circle()
                    .strokeBorder(AngularGradient(colors: Self.ringColors, center: .center), lineWidth: ringWidth)

                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(.black.opacity(0.6), lineWidth: 2))
                    .frame(width: ringWidth * 1.1, height: ringWidth * 1.1)
                    .shadow(radius: 2)
                    .position(
                        x: size / 2 + knobRadius * cos(radians),
                        y: size / 2 - knobRadius * sin(radians)
                    )

                VStack(spacing: 2) {
                    Text("Δθ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(degrees, specifier: "%.1f")°")
                        .font(.title2.monospacedDigit())
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let dx = value.location.x - size / 2
                    let dy = size / 2 - value.location.y
                    var angle = atan2(dy, dx) * 180 / .pi
                    if angle < 0 { angle += 360 }
                    degrees = angle
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hue rotation")
        .accessibilityValue("\(Int(degrees.rounded())) degrees")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: degrees = (degrees + 1).truncatingRemainder(dividingBy: 360)
            case .decrement: degrees = (degrees - 1 + 360).truncatingRemainder(dividingBy: 360)
            @unknown default: break
            }
        }
    }
}

#Preview {
    @Previewable @State var degrees = 45.0
    HueDial(degrees: $degrees)
        .frame(width: 220, height: 220)
        .padding()
}
