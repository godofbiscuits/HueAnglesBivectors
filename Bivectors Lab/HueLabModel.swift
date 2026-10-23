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
    /// The stored metadata: Δθ plus lightness / chroma scale.
    var adjustment = OklabAdjustment()

    private(set) var originalImage: CGImage?
    private(set) var adjustedImage: CGImage?
    private(set) var restoredImage: CGImage?
    private(set) var outOfGamut = 0
    /// Mean luminance Y (linear light) of the preview before and after the adjustment.
    private(set) var originalMeanLuminance = 0.0
    private(set) var adjustedMeanLuminance = 0.0
    private(set) var restoreStats: RestoreStats?
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
        restoreStats = nil
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
            let adjustment = adjustment
            let (result, meanY) = await Task.detached(priority: .userInitiated) {
                let result = OklabRotor.apply(adjustment, to: preview)
                return (result, OklabRotor.meanLuminance(of: result.image))
            }.value
            adjustedImage = result.image.makeCGImage()
            outOfGamut = result.outOfGamut
            adjustedMeanLuminance = meanY
        }
        isRendering = false
    }

    /// Applies the adjustment to the full-res float image, then its inverse, and compares with the original.
    func restore() {
        guard let full = fullSource, !isRestoring else { return }
        let adjustment = adjustment
        isRestoring = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (RGBAF16Image, RestoreStats) in
                let forward = OklabRotor.apply(adjustment, to: full)
                let back = OklabRotor.apply(adjustment.inverse, to: forward.image)
                let diff = OklabRotor.difference(full, back.image)
                return (back.image, RestoreStats(maxError: diff.max, meanError: diff.mean, outOfGamut: forward.outOfGamut))
            }.value
            isRestoring = false
            // Ignore the result if the dials moved while we were working.
            guard adjustment == self.adjustment else { return }
            restoredImage = result.0.makeCGImage()
            restoreStats = result.1
        }
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
