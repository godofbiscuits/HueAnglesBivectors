//
//  MovieExporter.swift
//  Bivectors Lab
//
//  Renders the hue rotation to a movie: one frame per degree at 30 fps. Each frame is the three live panes
//  side by side (original | hue-altered, luminance preserved | luminance diff), written with the
//  least-compressed encoder available (ProRes 422 HQ, falling back to maximum-quality HEVC).
//

import AVFoundation
import CoreMedia
import CoreVideo

/// The project defaults every type to the main actor, so this is explicitly `nonisolated`, and `export` is
/// `@concurrent`: rendering 360 frames must never run on (and freeze) the main thread.
nonisolated enum MovieExporter {
    struct Settings: Sendable {
        /// 360 frames at one degree each is one full rotation.
        var frameCount = 360
        var framesPerSecond: Int32 = 30
        var degreesPerFrame = 1.0
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

    /// Renders the movie and returns the file URL (in the temporary directory). Cancelling the calling task
    /// stops the export and deletes the partial file.
    ///
    /// Frame `n` uses hue angle `adjustment.deltaThetaDegrees + n · degreesPerFrame`; the adjustment's lightness
    /// and chroma scales are held constant. `progress` is called with 0...1 as frames are written.
    @concurrent static func export(
        source: RGBAF16Image,
        adjustment: OklabAdjustment,
        settings: Settings = Settings(),
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
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
                let diffImage = OklabRotor.differenceMap(plainImage, preservedImage, gain: settings.diffGain).image

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
                encodeBGRA8(diffImage, width: paneWidth, height: paneHeight, into: bytes, bytesPerRow: rowBytes, xOffset: paneWidth * 2)
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
        return url
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
