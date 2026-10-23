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
struct OklabAdjustment: Equatable, Sendable {
    /// Rotation of the (a, b) plane in degrees (counter-clockwise, a toward b).
    var deltaThetaDegrees: Double = 0
    var lightnessScale: Double = 1
    var chromaScale: Double = 1

    static let scaleRange: ClosedRange<Double> = 0.5...1.5

    /// The adjustment that undoes this one: -Δθ, 1/sL, 1/sC.
    /// Scales are clamped away from zero so the inverse always exists.
    var inverse: OklabAdjustment {
        OklabAdjustment(
            deltaThetaDegrees: -deltaThetaDegrees,
            lightnessScale: 1 / max(lightnessScale, 1e-6),
            chromaScale: 1 / max(chromaScale, 1e-6)
        )
    }

    var isIdentity: Bool { self == OklabAdjustment() }
}

/// Precomputed rotor `R(θ) = cos θ + sin θ · e₁₂` (acting on the a,b plane) plus scales.
struct OklabRotorTransform: Sendable {
    let cosTheta: Float
    let sinTheta: Float
    let lightnessScale: Float
    let chromaScale: Float

    init(_ adjustment: OklabAdjustment) {
        let theta = adjustment.deltaThetaDegrees * .pi / 180
        cosTheta = Float(cos(theta))
        sinTheta = Float(sin(theta))
        lightnessScale = Float(adjustment.lightnessScale)
        chromaScale = Float(adjustment.chromaScale)
    }

    /// Applies the adjustment to an Oklab triple (L, a, b).
    @inline(__always)
    func apply(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let a = lab.y * cosTheta - lab.z * sinTheta
        let b = lab.y * sinTheta + lab.z * cosTheta
        return SIMD3(lab.x * lightnessScale, a * chromaScale, b * chromaScale)
    }
}

// MARK: - Pixel buffer

/// 16-bit float, premultiplied-alpha RGBA in extended linear sRGB. Component values are not limited to 0...1.
struct RGBAF16Image: Sendable {
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

struct AdjustmentResult: Sendable {
    let image: RGBAF16Image
    /// Pixels whose adjusted color lies outside the sRGB gamut. They are preserved, not clamped.
    let outOfGamut: Int
}

struct RestoreStats: Sendable, Equatable {
    /// Maximum / mean absolute difference per RGB channel, in gamma-encoded 8-bit units (0...255).
    let maxError: Double
    let meanError: Double
    /// Pixels that were outside sRGB after the forward adjustment (recoverable thanks to extended range).
    let outOfGamut: Int
}

// MARK: - Color math

enum OklabRotor {
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

                        var result = oklabToLinear(transform.apply(linearToOklab(linear)))
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
}
