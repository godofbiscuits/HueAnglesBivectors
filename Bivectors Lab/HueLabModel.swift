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
    /// Plain hue / chroma adjustment (luminance drifts with hue).
    private(set) var adjustedImage: CGImage?
    /// Same adjustment with each pixel's luminance Y held at its original value.
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

    private static let previewDimension = 1024
    private static let fullDimension = 4096

    func load(data: Data) async {
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
            adjustedImage = plainRender.image.makeCGImage()
            outOfGamut = plainRender.outOfGamut
            adjustedMeanLuminance = plainRender.meanLuminance
            preservedImage = preservedRender.image.makeCGImage()
            preservedOutOfGamut = preservedRender.outOfGamut
            preservedMeanLuminance = preservedRender.meanLuminance
        }
        isRendering = false
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
