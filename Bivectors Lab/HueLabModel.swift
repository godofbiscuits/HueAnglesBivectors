//
//  HueLabModel.swift
//  Bivectors Lab
//

import SwiftUI
import ImageIO
import Observation

@MainActor
@Observable
final class HueLabModel {
    /// The stored metadata: Δθ plus lightness / chroma scale. Both variants below are driven by it.
    var adjustment = OklabAdjustment()

    private(set) var originalImage: CGImage?
    /// Per-pixel luminance (grayscale) difference between the plain hue-altered image (luminance drifts with hue)
    /// and the luminance-preserving one, amplified by `diffGain`. Black means identical.
    private(set) var diffImage: CGImage?
    /// Max / mean of that difference in gamma-encoded 8-bit units (0...255), before gain.
    private(set) var diffMaxError = 0.0
    private(set) var diffMeanError = 0.0
    /// Amplification applied to the difference image so small differences are visible.
    var diffGain = 16.0
    /// Same adjustment as the plain one, with each pixel's luminance Y held at its original value.
    private(set) var preservedImage: CGImage?
    private(set) var restoredImage: CGImage?
    private(set) var restoredPreservedImage: CGImage?
    private(set) var outOfGamut = 0
    private(set) var preservedOutOfGamut = 0
    /// Mean luminance Y (linear light) of the preview: original, plain adjustment, luminance-preserving adjustment.
    private(set) var originalMeanLuminance = 0.0
    private(set) var adjustedMeanLuminance = 0.0
    private(set) var preservedMeanLuminance = 0.0
    private(set) var restoreStats: RestoreStats?
    private(set) var restorePreservedStats: RestoreStats?
    private(set) var isRestoring = false
    private(set) var errorMessage: String?

    /// Full-resolution source (capped at 4096 px) used for restore verification.
    @ObservationIgnored private var fullSource: RGBAF16Image?
    /// ~1 MP source used for live preview while dragging.
    @ObservationIgnored private var previewSource: RGBAF16Image?
    @ObservationIgnored private var isRendering = false
    @ObservationIgnored private var renderPending = false
    /// Latest preview renders, kept so the difference can be recomputed when only the gain changes.
    @ObservationIgnored private var latestPlain: RGBAF16Image?
    @ObservationIgnored private var latestPreserved: RGBAF16Image?
    @ObservationIgnored private var isDiffing = false
    @ObservationIgnored private var diffPending = false

    private static let previewDimension = 1024
    private static let fullDimension = 4096

    // MARK: Animation

    /// Seconds for one full 2π (360°) rotation of the hue angle.
    static let animationSeconds = 10.0

    private(set) var isAnimating = false
    @ObservationIgnored private var animationTask: Task<Void, Never>?

    func toggleAnimation() {
        if isAnimating { stopAnimation() } else { startAnimation() }
    }

    /// Sweeps the hue angle through one full rotation, from its current value back to it, over `animationSeconds`.
    /// Progress follows the wall clock, so slow renders skip frames instead of stretching the animation.
    func startAnimation() {
        guard previewSource != nil, !isAnimating else { return }
        isAnimating = true
        let startAngle = adjustment.deltaThetaDegrees
        let clock = ContinuousClock()
        let startTime = clock.now
        animationTask = Task {
            while !Task.isCancelled {
                let elapsed = clock.now - startTime
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                let progress = seconds / Self.animationSeconds
                if progress >= 1 {
                    adjustment.deltaThetaDegrees = startAngle
                    break
                }
                adjustment.deltaThetaDegrees = (startAngle + 360 * progress).truncatingRemainder(dividingBy: 360)
                try? await Task.sleep(for: .milliseconds(16))
            }
            // A cancelled task was already cleaned up by stopAnimation(); don't clobber a newer animation.
            if !Task.isCancelled {
                isAnimating = false
                animationTask = nil
            }
        }
    }

    func stopAnimation() {
        animationTask?.cancel()
        animationTask = nil
        isAnimating = false
    }

    // MARK: Movie

    private(set) var isMakingMovie = false
    /// 0...1 while a movie is rendering.
    private(set) var movieProgress = 0.0
    private(set) var movieErrorMessage: String?
    /// Set when a movie finishes; the view opens a player for it and clears this.
    var finishedMovieURL: URL?
    @ObservationIgnored private var movieTask: Task<Void, Never>?

    /// Renders one frame per degree (360 frames at 30 fps) starting from the current hue angle, with the current
    /// lightness / chroma scales and diff gain, then publishes the file in `finishedMovieURL`.
    func makeMovie() {
        guard let preview = previewSource, !isMakingMovie else { return }
        stopAnimation()
        isMakingMovie = true
        movieProgress = 0
        movieErrorMessage = nil
        let adjustment = adjustment
        let settings = MovieExporter.Settings(diffGain: Float(diffGain))
        movieTask = Task {
            do {
                // `export` is nonisolated, so the rendering runs off the main actor; awaiting it directly
                // (rather than via a detached task) keeps cancellation connected.
                let url = try await MovieExporter.export(
                    source: preview, adjustment: adjustment, settings: settings
                ) { progress in
                    Task { @MainActor in self.movieProgress = progress }
                }
                finishedMovieURL = url
            } catch is CancellationError {
                // Cancelled by the user; nothing to report.
            } catch {
                movieErrorMessage = error.localizedDescription
            }
            isMakingMovie = false
            movieTask = nil
        }
    }

    func cancelMovie() {
        movieTask?.cancel()
    }

    func load(data: Data) async {
        stopAnimation()
        cancelMovie()
        errorMessage = nil
        let decoded = await Task.detached(priority: .userInitiated) {
            Self.decode(data)
        }.value
        guard let (full, preview) = decoded else {
            errorMessage = "Couldn't read that image."
            return
        }
        fullSource = full
        previewSource = preview
        originalImage = preview.makeCGImage()
        originalMeanLuminance = OklabRotor.meanLuminance(of: preview)
        adjustment.resetValues()
        adjustmentChanged()
    }

    func load(url: URL) async {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Couldn't open \(url.lastPathComponent)."
            return
        }
        await load(data: data)
    }

    /// Call whenever `adjustment` changes: invalidates any restore and re-renders the preview.
    ///
    /// Renders are coalesced: only one runs at a time, and when it finishes it re-renders if the
    /// adjustment moved in the meantime, so dragging never queues up stale work.
    func adjustmentChanged() {
        restoredImage = nil
        restoredPreservedImage = nil
        restoreStats = nil
        restorePreservedStats = nil
        renderPending = true
        guard !isRendering else { return }
        isRendering = true
        Task {
            await renderLoop()
        }
    }

    private func renderLoop() async {
        while renderPending, let preview = previewSource {
            renderPending = false
            let plain = adjustment
            let preserved = preservingLuminance(adjustment)
            let (plainRender, preservedRender) = await Task.detached(priority: .userInitiated) {
                (Self.render(plain, of: preview), Self.render(preserved, of: preview))
            }.value
            latestPlain = plainRender.image
            latestPreserved = preservedRender.image
            outOfGamut = plainRender.outOfGamut
            adjustedMeanLuminance = plainRender.meanLuminance
            preservedImage = preservedRender.image.makeCGImage()
            preservedOutOfGamut = preservedRender.outOfGamut
            preservedMeanLuminance = preservedRender.meanLuminance
            diffGainChanged()
        }
        isRendering = false
    }

    /// Recomputes the difference image from the latest renders. Call when `diffGain` changes; also runs after
    /// every render. Coalesced the same way as renders so dragging the gain never queues stale work.
    func diffGainChanged() {
        diffPending = true
        guard !isDiffing else { return }
        isDiffing = true
        Task {
            await diffLoop()
        }
    }

    private func diffLoop() async {
        while diffPending, let plain = latestPlain, let preserved = latestPreserved {
            diffPending = false
            let gain = Float(diffGain)
            let map = await Task.detached(priority: .userInitiated) {
                OklabRotor.differenceMap(plain, preserved, gain: gain)
            }.value
            diffImage = map.image.makeCGImage()
            diffMaxError = map.maxError
            diffMeanError = map.meanError
        }
        isDiffing = false
    }

    private struct Render: Sendable {
        let image: RGBAF16Image
        let outOfGamut: Int
        let meanLuminance: Double
    }

    nonisolated private static func render(_ adjustment: OklabAdjustment, of source: RGBAF16Image) -> Render {
        let result = OklabRotor.apply(adjustment, to: source)
        return Render(
            image: result.image,
            outOfGamut: result.outOfGamut,
            meanLuminance: OklabRotor.meanLuminance(of: result.image)
        )
    }

    private func preservingLuminance(_ adjustment: OklabAdjustment) -> OklabAdjustment {
        var preserved = adjustment
        preserved.preserveLuminance = true
        return preserved
    }

    /// Applies each variant to the full-res float image, then its inverse, and compares with the original.
    func restore() {
        guard let full = fullSource, !isRestoring else { return }
        let plain = adjustment
        let preserved = preservingLuminance(adjustment)
        isRestoring = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                (Self.roundTrip(plain, of: full), Self.roundTrip(preserved, of: full))
            }.value
            isRestoring = false
            // Ignore the result if the dials moved while we were working.
            guard plain == adjustment else { return }
            restoredImage = result.0.image.makeCGImage()
            restoreStats = result.0.stats
            restoredPreservedImage = result.1.image.makeCGImage()
            restorePreservedStats = result.1.stats
        }
    }

    private struct RoundTrip: Sendable {
        let image: RGBAF16Image
        let stats: RestoreStats
    }

    nonisolated private static func roundTrip(_ adjustment: OklabAdjustment, of full: RGBAF16Image) -> RoundTrip {
        let forward = OklabRotor.apply(adjustment, to: full)
        let back = OklabRotor.apply(adjustment.inverse, to: forward.image)
        let diff = OklabRotor.difference(full, back.image)
        return RoundTrip(
            image: back.image,
            stats: RestoreStats(maxError: diff.max, meanError: diff.mean, outOfGamut: forward.outOfGamut)
        )
    }

    nonisolated private static func decode(_ data: Data) -> (RGBAF16Image, RGBAF16Image)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: fullDimension,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let full = RGBAF16Image(cgImage: cgImage),
              let preview = RGBAF16Image(cgImage: cgImage, maxDimension: previewDimension) else { return nil }
        return (full, preview)
    }
}
