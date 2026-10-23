//
//  OklabRotor.swift
//  Bivectors Lab
//
//  Oklab color math and the batch "rotor" that rotates every pixel's (a, b)
//  by a single angle. L and chroma can additionally be scaled; the three
//  numbers in `OklabAdjustment` are all that is needed to undo the edit.
//
//  Pixels are held as 16-bit float, premultiplied RGBA in *extended linear
//  sRGB*, so colors pushed outside the sRGB gamut (negative or >1 components)
//  are preserved instead of clipped, and the inverse rotor can recover them.
//

import Foundation
import CoreGraphics

// MARK: - Adjustment metadata

/// The complete restoration metadata: hue rotation plus lightness / chroma scale.
nonisolated struct OklabAdjustment: Equatable, Sendable {
    /// Rotation of the (a, b) plane in degrees (counter-clockwise, a toward b).
    var deltaThetaDegrees: Double = 0
    var lightnessScale: Double = 1
    var chromaScale: Double = 1
    /// When true, each pixel's luminance Y is held at its original value (times `lightnessScale`³,
    /// which is how a lightness scale acts on a gray) after the hue / chroma change.
    var preserveLuminance = false
    /// True for the adjustment returned by `inverse` when `preserveLuminance` is on. The luminance-preserving
    /// map isn't a forward map with different parameters, so the inverse is the same numbers run backwards.
    var isInverse = false

    static let scaleRange: ClosedRange<Double> = 0.5...1.5

    /// The adjustment that undoes this one.
    /// Plain mode: -Δθ, 1/sL, 1/sC (scales are clamped away from zero so the inverse always exists).
    /// Luminance-preserving mode: the same Δθ, sL, sC with the direction flipped.
    var inverse: OklabAdjustment {
        if preserveLuminance {
            var flipped = self
            flipped.isInverse.toggle()
            return flipped
        }
        return OklabAdjustment(
            deltaThetaDegrees: -deltaThetaDegrees,
            lightnessScale: 1 / max(lightnessScale, 1e-6),
            chromaScale: 1 / max(chromaScale, 1e-6)
        )
    }

    /// True when the three dial values are at their defaults (the luminance toggle doesn't count).
    var isIdentity: Bool {
        deltaThetaDegrees == 0 && lightnessScale == 1 && chromaScale == 1
    }

    /// Resets the dial values but keeps the luminance-preservation setting.
    mutating func resetValues() {
        deltaThetaDegrees = 0
        lightnessScale = 1
        chromaScale = 1
    }
}

/// Precomputed rotor `R(θ) = cos θ + sin θ · e₁₂` (acting on the a,b plane) plus scales.
nonisolated struct OklabRotorTransform: Sendable {
    let cosTheta: Float
    let sinTheta: Float
    let lightnessScale: Float
    let chromaScale: Float
    let preserveLuminance: Bool
    let isInverse: Bool

    /// Luminances at or below this are treated as black and left unscaled.
    private static let luminanceFloor: Float = 1e-6

    init(_ adjustment: OklabAdjustment) {
        let theta = adjustment.deltaThetaDegrees * .pi / 180
        cosTheta = Float(cos(theta))
        sinTheta = Float(sin(theta))
        lightnessScale = Float(adjustment.lightnessScale)
        chromaScale = Float(adjustment.chromaScale)
        preserveLuminance = adjustment.preserveLuminance
        isInverse = adjustment.isInverse
    }

    /// Rotates (a, b) by Δθ and scales it by the chroma factor; L is untouched.
    @inline(__always)
    private func rotateAndScaleChroma(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let a = lab.y * cosTheta - lab.z * sinTheta
        let b = lab.y * sinTheta + lab.z * cosTheta
        return SIMD3(lab.x, a * chromaScale, b * chromaScale)
    }

    /// Exact inverse of `rotateAndScaleChroma`.
    @inline(__always)
    private func unrotateAndUnscaleChroma(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let a = lab.y * cosTheta + lab.z * sinTheta
        let b = -lab.y * sinTheta + lab.z * cosTheta
        return SIMD3(lab.x, a / chromaScale, b / chromaScale)
    }

    /// Applies the plain adjustment (rotation, chroma scale, lightness scale) to an Oklab triple (L, a, b).
    @inline(__always)
    func apply(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        var result = rotateAndScaleChroma(lab)
        result.x *= lightnessScale
        return result
    }

    /// Applies the whole adjustment to one pixel in (unpremultiplied) linear sRGB.
    ///
    /// Luminance-preserving mode: scaling linear RGB by k scales Oklab (L, a, b) by k^(1/3) and Y by k, so after
    /// rotating we rescale linear RGB to put Y back at `Y₀ · sL³`. The inverse has a closed form: un-rotate to get
    /// v = k^(1/3)·lab(c), then k = Y(lin(v)) · sL³ / Y(x) and lab(c) = v / k^(1/3).
    @inline(__always)
    func apply(linear c: SIMD3<Float>) -> SIMD3<Float> {
        guard preserveLuminance else {
            return OklabRotor.oklabToLinear(apply(OklabRotor.linearToOklab(c)))
        }
        let lightnessCubed = lightnessScale * lightnessScale * lightnessScale

        if !isInverse {
            let y0 = OklabRotor.luminance(c)
            let rotated = OklabRotor.oklabToLinear(rotateAndScaleChroma(OklabRotor.linearToOklab(c)))
            let y1 = OklabRotor.luminance(rotated)
            guard y0 > Self.luminanceFloor, y1 > Self.luminanceFloor else { return rotated }
            return rotated * (y0 * lightnessCubed / y1)
        }

        let yx = OklabRotor.luminance(c)
        let v = unrotateAndUnscaleChroma(OklabRotor.linearToOklab(c))
        let unscaled = OklabRotor.oklabToLinear(v)
        let yv = OklabRotor.luminance(unscaled)
        guard yx > Self.luminanceFloor, yv > Self.luminanceFloor else { return unscaled }
        let k = yv * lightnessCubed / yx
        return OklabRotor.oklabToLinear(v / cbrtf(k))
    }
}

// MARK: - Pixel buffer

/// 16-bit float, premultiplied-alpha RGBA in extended linear sRGB. Component values are not limited to 0...1.
nonisolated struct RGBAF16Image: Sendable {
    let width: Int
    let height: Int
    var pixels: [Float16]

    init(width: Int, height: Int, pixels: [Float16]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Builds an opaque-or-translucent image from gamma-encoded 8-bit sRGB RGBA bytes (non-premultiplied).
    init(srgb8 bytes: [UInt8], width: Int, height: Int) {
        var pixels = [Float16](repeating: 0, count: bytes.count)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Float(bytes[i + 3]) / 255
            for c in 0..<3 {
                pixels[i + c] = Float16(OklabRotor.srgbDecode(Float(bytes[i + c]) / 255) * alpha)
            }
            pixels[i + 3] = Float16(alpha)
        }
        self.init(width: width, height: height, pixels: pixels)
    }

    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.floatComponents.rawValue
        | CGBitmapInfo.byteOrder16Little.rawValue

    /// Renders `cgImage` into an extended linear sRGB buffer (wide-gamut sources keep out-of-sRGB colors),
    /// optionally downsampling so the long edge is at most `maxDimension`.
    init?(cgImage: CGImage, maxDimension: Int? = nil) {
        var w = cgImage.width
        var h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        if let maxDimension, max(w, h) > maxDimension {
            let scale = Double(maxDimension) / Double(max(w, h))
            w = max(1, Int((Double(w) * scale).rounded()))
            h = max(1, Int((Double(h) * scale).rounded()))
        }
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        var data = [Float16](repeating: 0, count: w * h * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 16,
                bytesPerRow: w * 8,
                space: space,
                bitmapInfo: Self.bitmapInfo
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        self.init(width: w, height: h, pixels: data)
    }

    func makeCGImage() -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 16,
            bitsPerPixel: 64,
            bytesPerRow: width * 8,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

nonisolated struct AdjustmentResult: Sendable {
    let image: RGBAF16Image
    /// Pixels whose adjusted color lies outside the sRGB gamut. They are preserved, not clamped.
    let outOfGamut: Int
}

nonisolated struct RestoreStats: Sendable, Equatable {
    /// Maximum / mean absolute difference per RGB channel, in gamma-encoded 8-bit units (0...255).
    let maxError: Double
    let meanError: Double
    /// Pixels that were outside sRGB after the forward adjustment (recoverable thanks to extended range).
    let outOfGamut: Int
}

// MARK: - Color math

nonisolated enum OklabRotor {
    // MARK: sRGB transfer

    @inline(__always)
    static func srgbDecode(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
    }

    @inline(__always)
    static func srgbEncode(_ v: Float) -> Float {
        v <= 0.0031308 ? v * 12.92 : 1.055 * powf(v, 1 / 2.4) - 0.055
    }

    /// Sign-symmetric encode so negative (out-of-gamut) linear values can be compared in perceptual units.
    @inline(__always)
    static func srgbEncodeExtended(_ v: Float) -> Float {
        v < 0 ? -srgbEncode(-v) : srgbEncode(v)
    }

    // MARK: Linear sRGB <-> Oklab (Björn Ottosson)

    @inline(__always)
    static func linearToOklab(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let l = 0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z
        let m = 0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z
        let s = 0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z
        let l_ = cbrtf(l), m_ = cbrtf(m), s_ = cbrtf(s)
        return SIMD3(
            0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        )
    }

    @inline(__always)
    static func oklabToLinear(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        let m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        let s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return SIMD3(
            +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    /// Relative luminance Y of a linear sRGB color.
    @inline(__always)
    static func luminance(_ linear: SIMD3<Float>) -> Float {
        0.2126 * linear.x + 0.7152 * linear.y + 0.0722 * linear.z
    }

    /// Mean luminance Y over the image (premultiplied, so translucent pixels contribute proportionally).
    static func meanLuminance(of image: RGBAF16Image) -> Double {
        let count = image.width * image.height
        guard count > 0 else { return 0 }
        var total: Double = 0
        for i in stride(from: 0, to: image.pixels.count, by: 4) {
            total += Double(luminance(SIMD3(Float(image.pixels[i]), Float(image.pixels[i + 1]), Float(image.pixels[i + 2]))))
        }
        return total / Double(count)
    }

    /// True if every linear component lies within 0...1 (allowing a small tolerance).
    @inline(__always)
    static func isInSRGBGamut(_ linear: SIMD3<Float>) -> Bool {
        let tolerance: Float = 0.0005
        return linear.x >= -tolerance && linear.x <= 1 + tolerance
            && linear.y >= -tolerance && linear.y <= 1 + tolerance
            && linear.z >= -tolerance && linear.z <= 1 + tolerance
    }

    /// Gamma-encoded sRGB (0...1) to Oklab.
    static func srgbToOklab(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        linearToOklab(SIMD3(srgbDecode(rgb.x), srgbDecode(rgb.y), srgbDecode(rgb.z)))
    }

    /// Oklab to gamma-encoded sRGB, clamped to 0...1. `inGamut` is false if clamping was needed.
    /// (Display / UI use only: the pixel pipeline keeps out-of-gamut values.)
    static func oklabToSrgb(_ lab: SIMD3<Float>) -> (rgb: SIMD3<Float>, inGamut: Bool) {
        let linear = oklabToLinear(lab)
        let clamped = linear.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))
        return (SIMD3(srgbEncode(clamped.x), srgbEncode(clamped.y), srgbEncode(clamped.z)), isInSRGBGamut(linear))
    }

    /// A display color for a hue angle in Oklab at the given lightness and chroma (used by the dial's ring).
    static func srgb(hueDegrees: Double, lightness: Float, chroma: Float) -> SIMD3<Float> {
        let h = Float(hueDegrees * .pi / 180)
        return oklabToSrgb(SIMD3(lightness, chroma * cosf(h), chroma * sinf(h))).rgb
    }

    // MARK: Batch rotor

    /// Applies `adjustment` to every pixel. Alpha is preserved. Out-of-sRGB-gamut results are kept
    /// (no clamping) and counted.
    static func apply(_ adjustment: OklabAdjustment, to image: RGBAF16Image) -> AdjustmentResult {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return AdjustmentResult(image: image, outOfGamut: 0) }

        let transform = OklabRotorTransform(adjustment)
        var output = image.pixels
        var rowCounts = [Int](repeating: 0, count: height)

        output.withUnsafeMutableBufferPointer { pixelBuffer in
            rowCounts.withUnsafeMutableBufferPointer { countBuffer in
                guard let pixels = pixelBuffer.baseAddress, let counts = countBuffer.baseAddress else { return }
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    var rowOutOfGamut = 0
                    for x in 0..<width {
                        let i = (y * width + x) * 4
                        let alpha = Float(pixels[i + 3])
                        if alpha <= 0 { continue }

                        // Un-premultiply, adjust in Oklab, re-premultiply. No clamping anywhere.
                        var linear = SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
                        if alpha < 1 { linear /= alpha }

                        var result = transform.apply(linear: linear)
                        if !isInSRGBGamut(result) { rowOutOfGamut += 1 }
                        if alpha < 1 { result *= alpha }

                        pixels[i] = Float16(result.x)
                        pixels[i + 1] = Float16(result.y)
                        pixels[i + 2] = Float16(result.z)
                    }
                    counts[y] = rowOutOfGamut
                }
            }
        }

        return AdjustmentResult(
            image: RGBAF16Image(width: width, height: height, pixels: output),
            outOfGamut: rowCounts.reduce(0, +)
        )
    }

    /// Maximum and mean absolute per-channel (RGB) difference between two same-sized buffers,
    /// measured in gamma-encoded 8-bit units (0...255).
    static func difference(_ a: RGBAF16Image, _ b: RGBAF16Image) -> (max: Double, mean: Double) {
        guard a.width == b.width, a.height == b.height, !a.pixels.isEmpty else { return (0, 0) }
        var maxError: Float = 0
        var total: Double = 0
        var count = 0
        for i in stride(from: 0, to: a.pixels.count, by: 4) {
            for c in 0..<3 {
                let d = abs(srgbEncodeExtended(Float(a.pixels[i + c])) - srgbEncodeExtended(Float(b.pixels[i + c]))) * 255
                maxError = max(maxError, d)
                total += Double(d)
                count += 1
            }
        }
        return (Double(maxError), total / Double(count))
    }

    /// Per-pixel absolute *luminance* difference between two same-sized images, as a displayable grayscale image
    /// (opaque; black = identical) plus the max / mean difference in gamma-encoded 8-bit units (0...255).
    ///
    /// Each pixel's luminance Y is gamma-encoded (what a viewer perceives), the two are subtracted, and the
    /// result is multiplied by `gain`, clamped to 0...1, and stored as linear light so it displays at that
    /// encoded brightness. Color differences at equal luminance therefore show as black.
    static func differenceMap(_ a: RGBAF16Image, _ b: RGBAF16Image, gain: Float) -> DifferenceMap {
        let width = a.width, height = a.height
        guard b.width == width, b.height == height, width > 0, height > 0 else {
            return DifferenceMap(image: a, maxError: 0, meanError: 0)
        }

        var output = [Float16](repeating: 1, count: a.pixels.count)  // alpha stays 1; RGB overwritten below
        var rowMax = [Float](repeating: 0, count: height)
        var rowSum = [Double](repeating: 0, count: height)

        a.pixels.withUnsafeBufferPointer { aBuffer in
            b.pixels.withUnsafeBufferPointer { bBuffer in
                output.withUnsafeMutableBufferPointer { outBuffer in
                    rowMax.withUnsafeMutableBufferPointer { maxBuffer in
                        rowSum.withUnsafeMutableBufferPointer { sumBuffer in
                            guard let pa = aBuffer.baseAddress, let pb = bBuffer.baseAddress,
                                  let po = outBuffer.baseAddress,
                                  let maxes = maxBuffer.baseAddress, let sums = sumBuffer.baseAddress else { return }
                            DispatchQueue.concurrentPerform(iterations: height) { y in
                                var rowMaximum: Float = 0
                                var rowTotal: Double = 0
                                for x in 0..<width {
                                    let i = (y * width + x) * 4
                                    let ya = luminance(SIMD3(Float(pa[i]), Float(pa[i + 1]), Float(pa[i + 2])))
                                    let yb = luminance(SIMD3(Float(pb[i]), Float(pb[i + 1]), Float(pb[i + 2])))
                                    let d = abs(srgbEncodeExtended(ya) - srgbEncodeExtended(yb))
                                    rowMaximum = max(rowMaximum, d * 255)
                                    rowTotal += Double(d * 255)
                                    let shown = Float16(srgbDecode(min(d * gain, 1)))
                                    po[i] = shown
                                    po[i + 1] = shown
                                    po[i + 2] = shown
                                }
                                maxes[y] = rowMaximum
                                sums[y] = rowTotal
                            }
                        }
                    }
                }
            }
        }

        return DifferenceMap(
            image: RGBAF16Image(width: width, height: height, pixels: output),
            maxError: Double(rowMax.max() ?? 0),
            meanError: rowSum.reduce(0, +) / Double(width * height)
        )
    }
}

nonisolated struct DifferenceMap: Sendable {
    let image: RGBAF16Image
    /// Maximum / mean absolute luminance difference, in gamma-encoded 8-bit units (0...255).
    let maxError: Double
    let meanError: Double

    /// The text shown in the diff pane and burned into movie frames: this frame's mean luminance difference and
    /// the peak that mean has reached so far. Gain-independent: these are the true differences, not the
    /// amplified ones the image displays.
    static func caption(mean: Double, peak: Double) -> String {
        String(format: "ΔY mean %.2f  peak %.2f  (of 255)", mean, peak)
    }
}

/// Tracks the largest value seen: each new value replaces the peak only if it is larger, and the index of the
/// sample that set the peak is kept (the earliest one, if several tie).
nonisolated struct PeakTracker: Sendable {
    private(set) var peak = 0.0
    /// The `index` passed with the sample that set the peak, if any index was given.
    private(set) var peakIndex: Int?

    /// Records `value` (optionally labelled with the `index` of its sample) and returns the peak so far.
    @discardableResult
    mutating func record(_ value: Double, at index: Int? = nil) -> Double {
        if value > peak {
            peak = value
            peakIndex = index
        } else if peakIndex == nil {
            // Nothing has beaten the starting peak of 0 yet; the first sample stands in for it.
            peakIndex = index
        }
        return peak
    }

    mutating func reset() {
        peak = 0
        peakIndex = nil
    }
}
