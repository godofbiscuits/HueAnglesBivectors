//
//  MovieExporter.swift
//  Bivectors Lab
//
//  Renders the hue rotation to a movie: half a degree per frame at 60 fps. Each frame is the three live panes
//  side by side (original | hue-altered, luminance preserved | luminance diff), written with the
//  least-compressed encoder available (ProRes 422 HQ, falling back to maximum-quality HEVC).
//

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo

/// Where in a movie the mean luminance difference was largest.
nonisolated struct MoviePeak: Sendable, Equatable {
    /// Zero-based index of the frame (the earliest, if several tie).
    let frame: Int
    /// The hue angle of that frame, in degrees, 0..<360.
    let angleDegrees: Double
    /// The mean luminance difference on that frame, in gamma-encoded 8-bit units (0...255).
    let meanError: Double
    let frameCount: Int
    let framesPerSecond: Int32

    /// When that frame plays, in seconds from the start of the movie.
    var timeSeconds: Double { Double(frame) / Double(framesPerSecond) }

    /// `degrees` brought into 0..<360.
    static func normalizedAngle(_ degrees: Double) -> Double {
        var angle = degrees.truncatingRemainder(dividingBy: 360)
        if angle < 0 { angle += 360 }
        return angle
    }
}

nonisolated struct ExportResult: Sendable {
    let url: URL
    /// nil only if the movie had no frames.
    let peak: MoviePeak?
}

/// The project defaults every type to the main actor, so this is explicitly `nonisolated`, and `export` is
/// `@concurrent`: rendering hundreds of frames must never run on (and freeze) the main thread.
nonisolated enum MovieExporter {
    struct Settings: Sendable {
        /// 720 frames at half a degree each is one full rotation; at 60 fps that's 12 seconds.
        var frameCount = 720
        var framesPerSecond: Int32 = 60
        var degreesPerFrame = 0.5
        /// Gain applied to the luminance-diff pane, matching the on-screen diff.
        var diffGain: Float = 16
    }

    enum ExportError: LocalizedError {
        case sourceTooSmall
        case noSupportedEncoder
        case cannotCreateFrame
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .sourceTooSmall: "The image is too small to make a movie."
            case .noSupportedEncoder: "No suitable video encoder is available."
            case .cannotCreateFrame: "Couldn't allocate a video frame."
            case .writerFailed(let message): "Writing the movie failed: \(message)"
            }
        }
    }

    /// Renders the movie and returns its file URL (in the temporary directory) and where its peak difference
    /// fell. Cancelling the calling task stops the export and deletes the partial file.
    ///
    /// Frame `n` uses hue angle `adjustment.deltaThetaDegrees + n · degreesPerFrame`; the adjustment's lightness
    /// and chroma scales are held constant. `progress` is called with 0...1 as frames are written.
    ///
    /// The caption on each frame's diff pane shows that frame's mean luminance difference and the peak of that
    /// mean from the first frame up to and including this one, so the last frame shows the peak for the whole
    /// rotation. `frameDiff`, if given, receives the same (mean, peak) pair for every frame.
    ///
    /// The result also reports which frame (and hue angle) had the largest mean difference.
    @concurrent static func export(
        source: RGBAF16Image,
        adjustment: OklabAdjustment,
        settings: Settings = Settings(),
        frameDiff: (@Sendable (_ mean: Double, _ peak: Double) -> Void)? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> ExportResult {
        // Video dimensions must be even.
        let paneWidth = source.width & ~1
        let paneHeight = source.height & ~1
        guard paneWidth >= 2, paneHeight >= 2 else { throw ExportError.sourceTooSmall }
        let frameWidth = paneWidth * 3

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HueRotation-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoSettings = try makeVideoSettings(width: frameWidth, height: paneHeight, writer: writer)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: frameWidth,
                kCVPixelBufferHeightKey as String: paneHeight,
            ]
        )
        guard writer.canAdd(input) else { throw ExportError.noSupportedEncoder }
        writer.add(input)
        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "couldn't start")
        }
        writer.startSession(atSourceTime: .zero)

        // Frames are rendered in order, so this is the peak mean difference from frame 0 up to the current frame.
        var peakTracker = PeakTracker()

        do {
            for frame in 0..<settings.frameCount {
                try Task.checkCancellation()

                var plain = adjustment
                plain.deltaThetaDegrees = adjustment.deltaThetaDegrees + Double(frame) * settings.degreesPerFrame
                plain.preserveLuminance = false
                var preserved = plain
                preserved.preserveLuminance = true

                let plainImage = OklabRotor.apply(plain, to: source).image
                let preservedImage = OklabRotor.apply(preserved, to: source).image
                let diff = OklabRotor.differenceMap(plainImage, preservedImage, gain: settings.diffGain)

                guard let pool = adaptor.pixelBufferPool else { throw ExportError.cannotCreateFrame }
                var created: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
                guard let pixelBuffer = created else { throw ExportError.cannotCreateFrame }

                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                    throw ExportError.cannotCreateFrame
                }
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
                encodeBGRA8(source, width: paneWidth, height: paneHeight, into: bytes, bytesPerRow: rowBytes, xOffset: 0)
                encodeBGRA8(preservedImage, width: paneWidth, height: paneHeight, into: bytes, bytesPerRow: rowBytes, xOffset: paneWidth)
                encodeBGRA8(diff.image, width: paneWidth, height: paneHeight, into: bytes, bytesPerRow: rowBytes, xOffset: paneWidth * 2)
                // Write this frame's mean luminance difference, and the peak so far, on the diff pane.
                let runningPeak = peakTracker.record(diff.meanError, at: frame)
                frameDiff?(diff.meanError, runningPeak)
                drawCaption(
                    DifferenceMap.caption(mean: diff.meanError, peak: runningPeak),
                    into: bytes, bytesPerRow: rowBytes, frameWidth: frameWidth, frameHeight: paneHeight,
                    pane: CGRect(x: paneWidth * 2, y: 0, width: paneWidth, height: paneHeight)
                )
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(5))
                }
                let time = CMTime(value: CMTimeValue(frame), timescale: settings.framesPerSecond)
                guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                    throw ExportError.writerFailed(writer.error?.localizedDescription ?? "couldn't append frame \(frame)")
                }
                progress(Double(frame + 1) / Double(settings.frameCount))
            }
        } catch {
            input.markAsFinished()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        input.markAsFinished()
        // End the session after the last frame's full duration so the movie is exactly frameCount / fps long.
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(settings.frameCount), timescale: settings.framesPerSecond))
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown error")
        }

        let peak = peakTracker.peakIndex.map { frame in
            MoviePeak(
                frame: frame,
                angleDegrees: MoviePeak.normalizedAngle(adjustment.deltaThetaDegrees + Double(frame) * settings.degreesPerFrame),
                meanError: peakTracker.peak,
                frameCount: settings.frameCount,
                framesPerSecond: settings.framesPerSecond
            )
        }
        return ExportResult(url: url, peak: peak)
    }

    /// Picks the least-compressed encoder the writer accepts: ProRes 422 HQ, else maximum-quality HEVC.
    /// The pixels are sRGB-encoded, so the movie is tagged Rec. 709 primaries / matrix with the sRGB transfer
    /// function (or plain 709 transfer if the encoder rejects that combination).
    private static func makeVideoSettings(width: Int, height: Int, writer: AVAssetWriter) throws -> [String: Any] {
        let colorTagging: [[String: Any]] = [
            [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        let encoders: [[String: Any]] = [
            [AVVideoCodecKey: AVVideoCodecType.proRes422HQ],
            [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 1.0],
            ],
        ]
        for encoder in encoders {
            for color in colorTagging {
                var candidate = encoder
                candidate[AVVideoWidthKey] = width
                candidate[AVVideoHeightKey] = height
                candidate[AVVideoColorPropertiesKey] = color
                if writer.canApply(outputSettings: candidate, forMediaType: .video) {
                    return candidate
                }
            }
        }
        throw ExportError.noSupportedEncoder
    }

    // MARK: Pixel conversion

    /// Draws `text` in white on a translucent dark plate at the bottom-left of `pane`, directly into BGRA8 frame
    /// memory (as written by `encodeBGRA8`). `pane` is in pixels with the origin at the bottom-left; text is
    /// clipped to it.
    static func drawCaption(
        _ text: String,
        into base: UnsafeMutablePointer<UInt8>,
        bytesPerRow: Int,
        frameWidth: Int,
        frameHeight: Int,
        pane: CGRect
    ) {
        // premultipliedFirst + 32-bit little-endian is BGRA in memory, matching the pixel buffer.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: base, width: frameWidth, height: frameHeight, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return }
        context.clip(to: pane)

        let fontSize = max(10, min(pane.height * 0.05, pane.width * 0.04))
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1),
        ]
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

        let margin = pane.height * 0.02
        let padding = fontSize * 0.4
        // Baseline position that puts the plate's bottom edge exactly `margin` above the pane's bottom.
        let origin = CGPoint(x: pane.minX + margin + padding, y: pane.minY + margin + padding - bounds.minY)
        let plate = CGRect(
            x: origin.x - padding, y: origin.y + bounds.minY - padding,
            width: bounds.width + 2 * padding, height: bounds.height + 2 * padding
        )
        context.setFillColor(CGColor(gray: 0, alpha: 0.6))
        context.addPath(CGPath(roundedRect: plate, cornerWidth: padding, cornerHeight: padding, transform: nil))
        context.fillPath()

        context.textPosition = origin
        CTLineDraw(line, context)
    }

    /// sRGB encode of linear 0...1, quantized to 8 bits, indexed by `round(linear * 65535)`.
    private static let encodeTable: [UInt8] = (0...65535).map { index in
        UInt8((OklabRotor.srgbEncode(Float(index) / 65535) * 255).rounded())
    }

    /// Converts the top-left `width` × `height` pixels of an extended-linear float image to gamma-encoded 8-bit
    /// BGRA (opaque), clamping out-of-gamut values, and writes them into `destination` starting at pixel column
    /// `xOffset`. Premultiplied color is written as-is, i.e. composited over black.
    static func encodeBGRA8(
        _ image: RGBAF16Image,
        width: Int,
        height: Int,
        into destination: UnsafeMutablePointer<UInt8>,
        bytesPerRow: Int,
        xOffset: Int
    ) {
        let table = encodeTable
        let sourceWidth = image.width
        image.pixels.withUnsafeBufferPointer { buffer in
            guard let source = buffer.baseAddress else { return }
            table.withUnsafeBufferPointer { lookup in
                guard let lookup = lookup.baseAddress else { return }
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    let sourceRow = source + y * sourceWidth * 4
                    let destinationRow = destination + y * bytesPerRow + xOffset * 4
                    for x in 0..<width {
                        let s = sourceRow + x * 4
                        let d = destinationRow + x * 4
                        d[0] = lookup[Int(min(max(Float(s[2]), 0), 1) * 65535 + 0.5)]
                        d[1] = lookup[Int(min(max(Float(s[1]), 0), 1) * 65535 + 0.5)]
                        d[2] = lookup[Int(min(max(Float(s[0]), 0), 1) * 65535 + 0.5)]
                        d[3] = 255
                    }
                }
            }
        }
    }
}
