//
//  Bivectors_LabTests.swift
//  Bivectors LabTests
//
//  Created by Jeffrey Barbose on 10/23/26.
//

import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Bivectors_Lab

/// Small PNG with a few saturated colors, for loading into the model.
private func makeTestPNG() -> Data? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return nil }
    let colors: [CGColor] = [
        CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1),
        CGColor(red: 0, green: 0, blue: 1, alpha: 1), CGColor(red: 0.8, green: 0.6, blue: 0.2, alpha: 1),
    ]
    for (index, color) in colors.enumerated() {
        context.setFillColor(color)
        context.fill(CGRect(x: (index % 2) * 4, y: (index / 2) * 4, width: 4, height: 4))
    }
    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

struct Bivectors_LabTests {

    @MainActor
    @Test func animationSweepsHueAngleAndStops() async throws {
        let model = HueLabModel()
        let png = try #require(makeTestPNG())

        // Nothing to animate until an image is loaded.
        model.startAnimation()
        #expect(!model.isAnimating)

        await model.load(data: png)
        model.adjustment.deltaThetaDegrees = 90
        model.startAnimation()
        #expect(model.isAnimating)

        // 36°/s, so after ~0.3 s the angle has advanced past the 90° start.
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.isAnimating)
        #expect(model.adjustment.deltaThetaDegrees > 95)
        #expect(model.adjustment.deltaThetaDegrees < 130)

        model.stopAnimation()
        #expect(!model.isAnimating)
        let stopped = model.adjustment.deltaThetaDegrees
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.adjustment.deltaThetaDegrees == stopped)
    }

    @Test func animationCoversFullRotationInTenSeconds() {
        #expect(HueLabModel.animationSeconds == 10)
    }

    private func expectClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, tolerance: Float, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(a.x - b.x) <= tolerance, sourceLocation: sourceLocation)
        #expect(abs(a.y - b.y) <= tolerance, sourceLocation: sourceLocation)
        #expect(abs(a.z - b.z) <= tolerance, sourceLocation: sourceLocation)
    }

    @Test func srgbOklabRoundTrip() {
        let samples: [SIMD3<Float>] = [
            [0, 0, 0], [1, 1, 1], [1, 0, 0], [0, 1, 0], [0, 0, 1], [0.2, 0.5, 0.8], [0.9, 0.3, 0.1],
        ]
        for rgb in samples {
            let back = OklabRotor.oklabToSrgb(OklabRotor.srgbToOklab(rgb))
            expectClose(back.rgb, rgb, tolerance: 1e-4)
            #expect(back.inGamut)
        }
    }

    @Test func knownOklabValues() {
        expectClose(OklabRotor.srgbToOklab([1, 1, 1]), [1, 0, 0], tolerance: 1e-3)
        // sRGB red per Ottosson's reference values.
        expectClose(OklabRotor.srgbToOklab([1, 0, 0]), [0.6280, 0.2249, 0.1258], tolerance: 1e-3)
    }

    @Test func rotorPreservesLightnessAndChroma() {
        let lab = OklabRotor.srgbToOklab([0.8, 0.4, 0.2])
        let rotated = OklabRotorTransform(OklabAdjustment(deltaThetaDegrees: 137)).apply(lab)
        #expect(abs(rotated.x - lab.x) < 1e-6)
        let chroma = (lab.y * lab.y + lab.z * lab.z).squareRoot()
        let rotatedChroma = (rotated.y * rotated.y + rotated.z * rotated.z).squareRoot()
        #expect(abs(chroma - rotatedChroma) < 1e-5)
    }

    @Test func rotationThenNegativeRotationRestoresAB() {
        let lab = OklabRotor.srgbToOklab([0.3, 0.6, 0.9])
        let adjustment = OklabAdjustment(deltaThetaDegrees: 73.5)
        let there = OklabRotorTransform(adjustment).apply(lab)
        let back = OklabRotorTransform(adjustment.inverse).apply(there)
        expectClose(back, lab, tolerance: 1e-5)
    }

    @Test func fullAdjustmentThenInverseRestoresOklab() {
        let lab = OklabRotor.srgbToOklab([0.7, 0.2, 0.5])
        let adjustment = OklabAdjustment(deltaThetaDegrees: -112, lightnessScale: 1.05, chromaScale: 0.9)
        let back = OklabRotorTransform(adjustment.inverse).apply(OklabRotorTransform(adjustment).apply(lab))
        expectClose(back, lab, tolerance: 1e-5)
    }

    @Test func inverseMetadata() {
        let inverse = OklabAdjustment(deltaThetaDegrees: 30, lightnessScale: 1.25, chromaScale: 0.5).inverse
        #expect(inverse.deltaThetaDegrees == -30)
        #expect(abs(inverse.lightnessScale - 0.8) < 1e-12)
        #expect(abs(inverse.chromaScale - 2) < 1e-12)
    }

    @Test func batchRoundTripForInGamutPixels() {
        // Low-chroma colors stay inside sRGB after a hue rotation.
        let width = 32, height = 16
        var bytes = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                let base = 90 + x * 2 + y
                bytes += [UInt8(base), UInt8(base + 6), UInt8(base - 5), 255]
            }
        }
        let image = RGBAF16Image(srgb8: bytes, width: width, height: height)
        let adjustment = OklabAdjustment(deltaThetaDegrees: 40, lightnessScale: 1, chromaScale: 0.9)

        let forward = OklabRotor.apply(adjustment, to: image)
        #expect(forward.outOfGamut == 0)
        let back = OklabRotor.apply(adjustment.inverse, to: forward.image)
        let diff = OklabRotor.difference(image, back.image)
        // Well below one 8-bit step, so an 8-bit export of the restored image is exact.
        #expect(diff.max < 0.5)
        // Alpha is untouched.
        #expect(back.image.pixels.enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 1 })
    }

    @Test func outOfGamutColorsAreNotClippedAndRestore() {
        // Saturated primaries rotated 120° land outside sRGB; the extended-range buffer must keep them.
        let bytes: [UInt8] = [
            255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 0, 255, 0, 255, 255, 255, 200, 40, 120, 255,
        ]
        let image = RGBAF16Image(srgb8: bytes, width: 6, height: 1)
        let adjustment = OklabAdjustment(deltaThetaDegrees: 120, lightnessScale: 1.05, chromaScale: 1.2)

        let forward = OklabRotor.apply(adjustment, to: image)
        #expect(forward.outOfGamut > 0)
        // Stored values really are outside 0...1 (negative or above one), not clamped.
        #expect(forward.image.pixels.contains { $0 < 0 || $0 > 1 })

        let back = OklabRotor.apply(adjustment.inverse, to: forward.image)
        let diff = OklabRotor.difference(image, back.image)
        #expect(diff.max < 1)
    }

    @Test func translucentPixelsKeepAlphaAndRestore() {
        let image = RGBAF16Image(srgb8: [200, 60, 90, 128, 30, 140, 220, 64], width: 2, height: 1)
        let adjustment = OklabAdjustment(deltaThetaDegrees: 75, lightnessScale: 0.9, chromaScale: 1.1)
        let forward = OklabRotor.apply(adjustment, to: image)
        #expect(forward.image.pixels[3] == image.pixels[3])
        #expect(forward.image.pixels[7] == image.pixels[7])
        let back = OklabRotor.apply(adjustment.inverse, to: forward.image)
        #expect(OklabRotor.difference(image, back.image).max < 1)
    }

    // MARK: Luminance preservation

    private static let colorfulBytes: [UInt8] = [
        255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 0, 255,
        0, 255, 255, 255, 200, 40, 120, 255, 128, 128, 128, 255, 12, 90, 200, 255,
    ]

    private func luminances(_ image: RGBAF16Image) -> [Float] {
        stride(from: 0, to: image.pixels.count, by: 4).map { i in
            OklabRotor.luminance(SIMD3(Float(image.pixels[i]), Float(image.pixels[i + 1]), Float(image.pixels[i + 2])))
        }
    }

    @Test func preserveLuminanceKeepsEveryPixelsY() {
        let image = RGBAF16Image(srgb8: Self.colorfulBytes, width: 8, height: 1)
        let adjustment = OklabAdjustment(deltaThetaDegrees: 120, chromaScale: 1.2, preserveLuminance: true)
        let result = OklabRotor.apply(adjustment, to: image)
        for (before, after) in zip(luminances(image), luminances(result.image)) {
            #expect(abs(before - after) <= 0.002 * max(before, 0.01))
        }
        let meanBefore = OklabRotor.meanLuminance(of: image)
        let meanAfter = OklabRotor.meanLuminance(of: result.image)
        #expect(abs(meanBefore - meanAfter) < 0.002 * meanBefore)
    }

    @Test func withoutPreserveLuminanceYDrifts() {
        // Sanity check that the toggle matters: a hue rotation alone shifts luminance.
        let image = RGBAF16Image(srgb8: Self.colorfulBytes, width: 8, height: 1)
        let result = OklabRotor.apply(OklabAdjustment(deltaThetaDegrees: 120), to: image)
        let drift = zip(luminances(image), luminances(result.image)).map { abs($0 - $1) / max($0, 0.01) }
        #expect(drift.max() ?? 0 > 0.05)
    }

    @Test func preserveLuminanceInverseIsExactInFloat32() {
        // The closed-form inverse, with no float16 storage in between, is exact to rounding error.
        let adjustments = [
            OklabAdjustment(deltaThetaDegrees: 150, lightnessScale: 1.1, chromaScale: 0.9, preserveLuminance: true),
            OklabAdjustment(deltaThetaDegrees: -75, chromaScale: 1.5, preserveLuminance: true),
        ]
        let bytes = Self.colorfulBytes
        for adjustment in adjustments {
            let forward = OklabRotorTransform(adjustment)
            let inverse = OklabRotorTransform(adjustment.inverse)
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let linear = SIMD3(
                    OklabRotor.srgbDecode(Float(bytes[i]) / 255),
                    OklabRotor.srgbDecode(Float(bytes[i + 1]) / 255),
                    OklabRotor.srgbDecode(Float(bytes[i + 2]) / 255)
                )
                let back = inverse.apply(linear: forward.apply(linear: linear))
                expectClose(back, linear, tolerance: 1e-5)
            }
        }
    }

    @Test func preserveLuminanceRoundTripThroughFloat16Storage() {
        // Luminance preservation can push saturated greens / cyans to linear values above 3, where float16
        // steps (~0.002) are amplified by the cube roots and Y rescale. Observed worst case is ~2 steps of 255.
        let image = RGBAF16Image(srgb8: Self.colorfulBytes, width: 8, height: 1)
        let adjustment = OklabAdjustment(
            deltaThetaDegrees: 150, lightnessScale: 1.1, chromaScale: 0.9, preserveLuminance: true
        )
        let forward = OklabRotor.apply(adjustment, to: image)
        let back = OklabRotor.apply(adjustment.inverse, to: forward.image)
        #expect(OklabRotor.difference(image, back.image).max < 1.5)

        let vivid = OklabAdjustment(deltaThetaDegrees: -75, chromaScale: 1.5, preserveLuminance: true)
        let vividBack = OklabRotor.apply(vivid.inverse, to: OklabRotor.apply(vivid, to: image).image)
        #expect(OklabRotor.difference(image, vividBack.image).max < 3)
    }

    @Test func preserveLuminanceScalesYByLightnessCubed() {
        let image = RGBAF16Image(srgb8: Self.colorfulBytes, width: 8, height: 1)
        let adjustment = OklabAdjustment(deltaThetaDegrees: 60, lightnessScale: 1.2, preserveLuminance: true)
        let result = OklabRotor.apply(adjustment, to: image)
        for (before, after) in zip(luminances(image), luminances(result.image)) {
            #expect(abs(before * 1.728 - after) <= 0.003 * max(before * 1.728, 0.01))
        }
    }

    @Test func luminancePreservingInverseFlipsDirectionAndResetKeepsToggle() {
        let adjustment = OklabAdjustment(deltaThetaDegrees: 30, lightnessScale: 1.25, chromaScale: 0.5, preserveLuminance: true)
        #expect(adjustment.inverse.isInverse)
        #expect(adjustment.inverse.deltaThetaDegrees == 30)
        #expect(adjustment.inverse.inverse == adjustment)

        var reset = adjustment
        reset.resetValues()
        #expect(reset.isIdentity)
        #expect(reset.preserveLuminance)
    }

    // MARK: Difference map

    @Test func differenceMapOfIdenticalImagesIsBlack() {
        let image = RGBAF16Image(srgb8: Self.colorfulBytes, width: 8, height: 1)
        let map = OklabRotor.differenceMap(image, image, gain: 16)
        #expect(map.maxError == 0)
        #expect(map.meanError == 0)
        for i in stride(from: 0, to: map.image.pixels.count, by: 4) {
            #expect(map.image.pixels[i] == 0 && map.image.pixels[i + 1] == 0 && map.image.pixels[i + 2] == 0)
            #expect(map.image.pixels[i + 3] == 1)
        }
    }

    @Test func differenceMapMeasuresAndAmplifiesKnownDifference() {
        // Gray 100 vs gray 110 in 8-bit sRGB: a 10-unit difference on every channel.
        let a = RGBAF16Image(srgb8: [100, 100, 100, 255], width: 1, height: 1)
        let b = RGBAF16Image(srgb8: [110, 110, 110, 255], width: 1, height: 1)

        let weak = OklabRotor.differenceMap(a, b, gain: 2)
        #expect(abs(weak.maxError - 10) < 0.3)
        #expect(abs(weak.meanError - 10) < 0.3)
        // Encoded 10/255 × 2 ≈ 0.0784 is stored as linear light.
        let expected = OklabRotor.srgbDecode(10.0 / 255 * 2)
        #expect(abs(Float(weak.image.pixels[0]) - expected) < 0.05 * expected)

        // Luminance only: all three channels of the output carry the same gray value.
        #expect(weak.image.pixels[0] == weak.image.pixels[1] && weak.image.pixels[1] == weak.image.pixels[2])

        // Large gain saturates to white.
        let strong = OklabRotor.differenceMap(a, b, gain: 64)
        #expect(strong.image.pixels[0] == 1)
    }

    @Test func differenceMapIgnoresColorAtEqualLuminance() {
        // A gray and a pure (out-of-gamut) red with the same luminance Y = 0.5 differ in color but not luminance.
        let gray = RGBAF16Image(width: 1, height: 1, pixels: [0.5, 0.5, 0.5, 1])
        let red = RGBAF16Image(width: 1, height: 1, pixels: [Float16(0.5 / 0.2126), 0, 0, 1])
        let map = OklabRotor.differenceMap(gray, red, gain: 16)
        #expect(map.maxError < 0.2)
    }

    @Test func plainAndLuminancePreservedVariantsDiffer() {
        let image = RGBAF16Image(srgb8: Self.colorfulBytes, width: 8, height: 1)
        let plain = OklabAdjustment(deltaThetaDegrees: 120)
        let preserved = OklabAdjustment(deltaThetaDegrees: 120, preserveLuminance: true)
        let map = OklabRotor.differenceMap(
            OklabRotor.apply(plain, to: image).image,
            OklabRotor.apply(preserved, to: image).image,
            gain: 16
        )
        #expect(map.maxError > 1)
        #expect(map.meanError > 0)
    }

    @Test func identityAdjustmentIsNearlyLossless() {
        let image = RGBAF16Image(srgb8: [
            255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 12, 200, 99, 255,
        ], width: 2, height: 2)
        let result = OklabRotor.apply(OklabAdjustment(), to: image)
        #expect(OklabRotor.difference(image, result.image).max < 0.01)
    }
}
