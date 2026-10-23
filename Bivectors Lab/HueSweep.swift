//
//  HueSweep.swift
//  Bivectors Lab
//
//  Finds the hue angle with the largest mean luminance difference (ΔY) between the plain hue-altered image and
//  the luminance-preserving one, without rendering either of them.
//
//  The preserved image's luminance is the original's (times lightness scale cubed), so only the plain image's
//  luminance depends on the angle, and per pixel that's a handful of multiply-adds once the pixel is in Oklab.
//  No RGB conversion, float16 images, diff images or encoding are needed, so a sweep is far cheaper than the
//  movie's per-frame rendering and gives the same numbers the movie will report.
//

import Foundation

/// The per-pixel values a sweep needs that don't depend on the hue angle, lightness scale or chroma scale.
nonisolated struct HueSweepSource: Sendable {
    let count: Int
    /// Oklab of the (un-premultiplied) pixel.
    let lightness: [Float]
    let a: [Float]
    let b: [Float]
    let alpha: [Float]
    /// Luminance Y of the premultiplied pixel, as the movie's diff sees it.
    let luminance: [Float]

    init(_ image: RGBAF16Image) {
        let pixelCount = image.width * image.height
        var lightnessValues = [Float](repeating: 0, count: pixelCount)
        var aValues = lightnessValues, bValues = lightnessValues
        var alphaValues = lightnessValues, luminanceValues = lightnessValues
        image.pixels.withUnsafeBufferPointer { pixels in
            for i in 0..<pixelCount {
                let pixelAlpha = Float(pixels[i * 4 + 3])
                var rgb = SIMD3(Float(pixels[i * 4]), Float(pixels[i * 4 + 1]), Float(pixels[i * 4 + 2]))
                alphaValues[i] = pixelAlpha
                luminanceValues[i] = OklabRotor.luminance(rgb)
                // Fully transparent pixels are left untouched by the adjustment and contribute no difference.
                guard pixelAlpha > 0 else { continue }
                if pixelAlpha < 1 { rgb /= pixelAlpha }
                let lab = OklabRotor.linearToOklab(rgb)
                lightnessValues[i] = lab.x
                aValues[i] = lab.y
                bValues[i] = lab.z
            }
        }
        count = pixelCount
        lightness = lightnessValues
        a = aValues
        b = bValues
        alpha = alphaValues
        luminance = luminanceValues
    }
}

nonisolated enum HueSweep {
    // Y = wl·l'³ + wm·m'³ + ws·s'³, folding the Oklab LMS → linear RGB matrix and the luminance row into 3 weights.
    private static let weightL: Float = 0.2126 * 4.0767416621 + 0.7152 * -1.2684380046 + 0.0722 * -0.0041960863
    private static let weightM: Float = 0.2126 * -3.3077115913 + 0.7152 * 2.6097574011 + 0.0722 * -0.7034186147
    private static let weightS: Float = 0.2126 * 0.2309699292 + 0.7152 * -0.3413193965 + 0.0722 * 1.7076147010

    /// Mean luminance difference at any hue angle for one image and one choice of lightness / chroma scale.
    struct Evaluator: Sendable {
        let source: HueSweepSource
        let lightnessScale: Float
        let chromaScale: Float
        /// Gamma-encoded luminance of what the preserved image shows: the original's Y times lightness scale cubed.
        private let targets: [Float]

        init(_ source: HueSweepSource, adjustment: OklabAdjustment) {
            self.source = source
            lightnessScale = Float(adjustment.lightnessScale)
            chromaScale = Float(adjustment.chromaScale)
            let lightnessCubed = lightnessScale * lightnessScale * lightnessScale
            targets = source.luminance.map { OklabRotor.srgbEncodeExtended($0 * lightnessCubed) }
        }

        /// Mean over pixels of |encoded Y of the hue-altered image − encoded Y of the preserved image|, in
        /// gamma-encoded 8-bit units (0...255): the same quantity the movie and the diff pane report. With
        /// `stride` above 1 only every `stride`-th pixel is used, for a quick estimate.
        func meanError(atDegrees degrees: Double, stride step: Int = 1) -> Double {
            let count = source.count
            guard count > 0 else { return 0 }
            let theta = degrees * .pi / 180
            let c = Float(cos(theta)), s = Float(sin(theta))
            let sL = lightnessScale, sC = chromaScale
            let chunks = min(64, count)
            var sums = [Double](repeating: 0, count: chunks)
            var counts = [Int](repeating: 0, count: chunks)

            source.lightness.withUnsafeBufferPointer { lightness in
            source.a.withUnsafeBufferPointer { aValues in
            source.b.withUnsafeBufferPointer { bValues in
            source.alpha.withUnsafeBufferPointer { alphas in
            targets.withUnsafeBufferPointer { targets in
            sums.withUnsafeMutableBufferPointer { sumOut in
            counts.withUnsafeMutableBufferPointer { countOut in
                guard let sumOut = sumOut.baseAddress, let countOut = countOut.baseAddress else { return }
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    let lower = chunk * count / chunks, upper = (chunk + 1) * count / chunks
                    var total: Float = 0
                    var used = 0
                    // Pixels are picked by global index, so the subsample doesn't depend on the chunking.
                    var i = (lower + step - 1) / step * step
                    while i < upper {
                        // Rotate (a, b) by θ and scale chroma, scale lightness, then take Y of the result.
                        let rotatedA = (aValues[i] * c - bValues[i] * s) * sC
                        let rotatedB = (aValues[i] * s + bValues[i] * c) * sC
                        let base = lightness[i] * sL
                        let l = base + 0.3963377774 * rotatedA + 0.2158037573 * rotatedB
                        let m = base - 0.1055613458 * rotatedA - 0.0638541728 * rotatedB
                        let sCone = base - 0.0894841775 * rotatedA - 1.2914855480 * rotatedB
                        let y = (weightL * l * l * l + weightM * m * m * m + weightS * sCone * sCone * sCone) * alphas[i]
                        total += abs(OklabRotor.srgbEncodeExtended(y) - targets[i]) * 255
                        used += 1
                        i += step
                    }
                    sumOut[chunk] = Double(total)
                    countOut[chunk] = used
                }
            }}}}}}}

            let used = counts.reduce(0, +)
            return used > 0 ? sums.reduce(0, +) / Double(used) : 0
        }
    }

    /// Finds the frame of the movie described by `settings` (frame `n` is at hue angle
    /// `adjustment.deltaThetaDegrees + n · degreesPerFrame`) whose mean luminance difference is largest, using the
    /// same lightness and chroma scales as `adjustment`. Ties go to the earliest frame.
    ///
    /// By default it is coarse-to-fine: a quick estimate roughly every 5° on a subsample of the pixels, then every
    /// frame within one coarse step of the three best local maxima using every pixel. `exhaustive` evaluates every
    /// frame on every pixel instead (slower; the reference the quick search is checked against).
    ///
    /// Runs off the main actor and stops with `CancellationError` if the calling task is cancelled.
    @concurrent static func findPeak(
        in image: RGBAF16Image,
        adjustment: OklabAdjustment,
        settings: MovieExporter.Settings,
        exhaustive: Bool = false
    ) async throws -> MoviePeak? {
        let frameCount = settings.frameCount
        guard frameCount > 0, image.width * image.height > 0 else { return nil }
        let evaluator = Evaluator(HueSweepSource(image), adjustment: adjustment)
        let pixelCount = evaluator.source.count

        func degrees(of frame: Int) -> Double {
            adjustment.deltaThetaDegrees + Double(frame) * settings.degreesPerFrame
        }
        // A full 360° sweep is circular: the frame after the last is the first.
        let isFullRotation = abs(Double(frameCount) * settings.degreesPerFrame - 360) < 1e-6

        func best(of frames: [Int], stride: Int) throws -> (frame: Int, value: Double)? {
            var best: (frame: Int, value: Double)?
            for frame in frames.sorted() {  // ascending, so a strict > keeps the earliest of equal frames
                try Task.checkCancellation()
                let value = evaluator.meanError(atDegrees: degrees(of: frame), stride: stride)
                if best == nil || value > best!.value { best = (frame, value) }
            }
            return best
        }

        let winner: (frame: Int, value: Double)?
        if exhaustive || frameCount <= 16 {
            winner = try best(of: Array(0..<frameCount), stride: 1)
        } else {
            // Coarse pass: about one frame per 5°, on a subsample. The stride is odd and not a divisor of the
            // width, so it doesn't line up with periodic image content.
            let spacing = settings.degreesPerFrame == 0 ? 1 : max(1, Int((5 / abs(settings.degreesPerFrame)).rounded()))
            let coarseStride = pixelCount > 40_000 ? (image.width % 17 == 0 ? 19 : 17) : 1
            let coarseFrames = Array(Swift.stride(from: 0, to: frameCount, by: spacing))
            var coarseValues = [Double]()
            for frame in coarseFrames {
                try Task.checkCancellation()
                coarseValues.append(evaluator.meanError(atDegrees: degrees(of: frame), stride: coarseStride))
            }

            // The best few local maxima of the coarse curve, so one broad peak doesn't use up every candidate.
            let n = coarseValues.count
            func neighbor(_ index: Int) -> Double {
                if isFullRotation { return coarseValues[(index + n) % n] }
                return coarseValues.indices.contains(index) ? coarseValues[index] : -.infinity
            }
            var maxima = coarseValues.indices.filter { coarseValues[$0] >= neighbor($0 - 1) && coarseValues[$0] >= neighbor($0 + 1) }
            if maxima.isEmpty { maxima = Array(coarseValues.indices) }
            let candidates = maxima.sorted { coarseValues[$0] > coarseValues[$1] }.prefix(3)

            // Refine: every frame within one coarse step of each candidate, with every pixel.
            var refineFrames = Set<Int>()
            for candidate in candidates {
                for offset in -spacing...spacing {
                    let frame = coarseFrames[candidate] + offset
                    if isFullRotation {
                        refineFrames.insert(((frame % frameCount) + frameCount) % frameCount)
                    } else if (0..<frameCount).contains(frame) {
                        refineFrames.insert(frame)
                    }
                }
            }
            winner = try best(of: Array(refineFrames), stride: 1)
        }

        guard let winner else { return nil }
        return MoviePeak(
            frame: winner.frame,
            angleDegrees: MoviePeak.normalizedAngle(degrees(of: winner.frame)),
            meanError: winner.value,
            frameCount: frameCount,
            framesPerSecond: settings.framesPerSecond
        )
    }
}
