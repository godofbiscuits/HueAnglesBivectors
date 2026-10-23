//
//  Bivectors_LabTests.swift
//  Bivectors LabTests
//
//  Created by Jeffrey Barbose on 10/23/26.
//

import Testing
@testable import Bivectors_Lab

struct Bivectors_LabTests {

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

    @Test func eightBitBatchRoundTripForInGamutPixels() {
        // Low-chroma colors stay inside sRGB after a hue rotation.
        let width = 32, height = 16
        var pixels = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                let base = 90 + x * 2 + y
                pixels += [UInt8(base), UInt8(base + 6), UInt8(base - 5), 255]
            }
        }
        let image = RGBA8Image(width: width, height: height, pixels: pixels)
        let adjustment = OklabAdjustment(deltaThetaDegrees: 40, lightnessScale: 1, chromaScale: 0.9)

        let forward = OklabRotor.apply(adjustment, to: image)
        #expect(forward.outOfGamut == 0)
        let back = OklabRotor.apply(adjustment.inverse, to: forward.image)
        let diff = OklabRotor.difference(image, back.image)
        #expect(diff.max <= 2)
        #expect(diff.mean < 1)
        // Alpha is untouched.
        #expect(back.image.pixels.enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 255 })
    }

    @Test func identityAdjustmentIsNearlyLossless() {
        let image = RGBA8Image(width: 2, height: 2, pixels: [
            255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 12, 200, 99, 255,
        ])
        let result = OklabRotor.apply(OklabAdjustment(), to: image)
        #expect(OklabRotor.difference(image, result.image).max == 0)
    }
}
