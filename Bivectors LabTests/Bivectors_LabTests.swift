//
//  Bivectors_LabTests.swift
//  Bivectors LabTests
//
//  Created by Jeffrey Barbose on 10/23/26.
//

import Testing
import AVFoundation
import CoreGraphics
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
@testable import Bivectors_Lab

/// Small square PNG made of four saturated colors, for loading into the model.
private func makeTestPNG(size: Int = 8) -> Data? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return nil }
    let colors: [CGColor] = [
        CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1),
        CGColor(red: 0, green: 0, blue: 1, alpha: 1), CGColor(red: 0.8, green: 0.6, blue: 0.2, alpha: 1),
    ]
    let half = size / 2
    for (index, color) in colors.enumerated() {
        context.setFillColor(color)
        context.fill(CGRect(x: (index % 2) * half, y: (index / 2) * half, width: half, height: half))
    }
    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

/// A smooth, non-repeating, colorful image: sine waves of different frequency in each channel.
private func makeSmoothImage(width: Int, height: Int) -> RGBAF16Image {
    var bytes = [UInt8]()
    bytes.reserveCapacity(width * height * 4)
    func channel(_ value: Double) -> UInt8 { UInt8(max(0, min(255, (128 + 120 * value).rounded()))) }
    for y in 0..<height {
        for x in 0..<width {
            let fx = Double(x), fy = Double(y)
            bytes += [
                channel(sin(fx * 0.045 + fy * 0.021)),
                channel(sin(fx * 0.017 - fy * 0.050 + 1)),
                channel(sin(fx * 0.030 + fy * 0.030 + 2.5)),
                255,
            ]
        }
    }
    return RGBAF16Image(srgb8: bytes, width: width, height: height)
}

/// An image of 8×8-pixel blocks in deterministic pseudo-random saturated colors (a simple LCG, so no run-to-run change).
private func makeBlockImage(width: Int, height: Int, seed: UInt64) -> RGBAF16Image {
    var state = seed
    func next() -> UInt8 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: state >> 33)
    }
    let blocksAcross = (width + 7) / 8, blocksDown = (height + 7) / 8
    let colors: [[UInt8]] = (0..<(blocksAcross * blocksDown)).map { _ in [next(), next(), next()] }
    var bytes = [UInt8]()
    for y in 0..<height {
        for x in 0..<width { bytes += colors[(y / 8) * blocksAcross + x / 8] + [255] }
    }
    return RGBAF16Image(srgb8: bytes, width: width, height: height)
}

/// How far a rotation is from no rotation, going the short way round: 0...180 degrees.
private func angularDistanceFromZero(_ degrees: Double) -> Double {
    let angle = MoviePeak.normalizedAngle(degrees)
    return min(angle, 360 - angle)
}

struct Bivectors_LabTests {

    @MainActor
    @Test func animationSweepsHueAngleAndStops() async throws {
        let model = HueLabModel()
        model.autoGeneratesMovie = false  // these tests aren't about the movie
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

    // MARK: Movie export

    @Test func encodeBGRA8ConvertsClampsAndOffsets() {
        // Two pixels: (0.5, 0.25, 1) and an out-of-gamut (-0.2, 3, 0.5), written one pixel column in.
        let image = RGBAF16Image(width: 2, height: 1, pixels: [0.5, 0.25, 1, 1, -0.2, 3, 0.5, 1])
        var output = [UInt8](repeating: 7, count: 12 * 1)  // 3 pixels wide, so pixel 0 is left untouched
        output.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            MovieExporter.encodeBGRA8(image, width: 2, height: 1, into: base, bytesPerRow: 12, xOffset: 1)
        }
        func expected(_ linear: Float) -> Int { Int((OklabRotor.srgbEncode(linear) * 255).rounded()) }

        #expect(Array(output[0..<4]) == [7, 7, 7, 7])
        // Pixel at column 1: BGRA order, opaque.
        #expect(abs(Int(output[4]) - expected(1)) <= 1)
        #expect(abs(Int(output[5]) - expected(0.25)) <= 1)
        #expect(abs(Int(output[6]) - expected(0.5)) <= 1)
        #expect(output[7] == 255)
        // Column 2: negative clamps to 0, >1 clamps to 255.
        #expect(abs(Int(output[8]) - expected(0.5)) <= 1)
        #expect(output[9] == 255)
        #expect(output[10] == 0)
        #expect(output[11] == 255)
    }

    @Test func movieDefaultsAreHalfADegreePerFrameAtSixtyFPSForOneFullTwelveSecondRotation() {
        let settings = MovieExporter.Settings()
        #expect(settings.degreesPerFrame == 0.5)
        #expect(settings.framesPerSecond == 60)
        #expect(settings.frameCount == 720)
        // One full rotation, same speed as before: 360° over 12 s.
        #expect(Double(settings.frameCount) * settings.degreesPerFrame == 360)
        #expect(Double(settings.frameCount) / Double(settings.framesPerSecond) == 12)
    }

    @Test func movieExportWritesSixtyFPSLowCompressionMovie() async throws {
        let width = 96, height = 64
        var bytes = [UInt8]()
        for y in 0..<height {
            for x in 0..<width { bytes += [UInt8(x * 2), UInt8(y * 3), 160, 255] }
        }
        let source = RGBAF16Image(srgb8: bytes, width: width, height: height)

        let url = try await MovieExporter.export(
            source: source,
            adjustment: OklabAdjustment(deltaThetaDegrees: 30),
            settings: MovieExporter.Settings(frameCount: 10)
        ).url
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 10.0 / 60.0) < 0.02)

        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let (size, frameRate, formats) = try await track.load(.naturalSize, .nominalFrameRate, .formatDescriptions)
        // Three panes side by side.
        #expect(size == CGSize(width: width * 3, height: height))
        #expect(abs(frameRate - 60) < 1)
        // ProRes 422 HQ when available, otherwise maximum-quality HEVC.
        let codec = try #require(formats.first).mediaSubType.rawValue
        #expect(codec == kCMVideoCodecType_AppleProRes422HQ || codec == kCMVideoCodecType_HEVC)
    }

    @Test func movieExportCancellationRemovesPartialFileAndThrows() async throws {
        let source = RGBAF16Image(srgb8: [UInt8](repeating: 128, count: 64 * 64 * 4), width: 64, height: 64)
        let task = Task {
            try await MovieExporter.export(
                source: source, adjustment: OklabAdjustment(), settings: MovieExporter.Settings(frameCount: 5000)
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func movieExportRendersOffTheMainThread() async throws {
        // Regression: the project defaults to the main actor, which once made the exporter render every frame
        // on the main thread and freeze the UI. Progress callbacks run on the exporter's own executor.
        final class Flag: @unchecked Sendable { var sawMainThread = false; var calls = 0 }
        let flag = Flag()
        let source = RGBAF16Image(srgb8: [UInt8](repeating: 128, count: 64 * 64 * 4), width: 64, height: 64)
        // Start from the main actor, like the app's Movie button does.
        let url = try await MainActor.run {
            Task { @MainActor in
                try await MovieExporter.export(
                    source: source, adjustment: OklabAdjustment(), settings: MovieExporter.Settings(frameCount: 4)
                ) { _ in
                    flag.calls += 1
                    if Thread.isMainThread { flag.sawMainThread = true }
                }
            }
        }.value.url
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(flag.calls == 4)
        #expect(!flag.sawMainThread)
    }

    // MARK: Ping-pong playback

    @Test func pingPongFlipsOnlyAtTheEndsWhenPlayingTowardThem() {
        let flip = PingPongController.flip
        let duration = 12.0
        let tolerance = PingPongController.edgeTolerance

        // Forward, mid-movie: keep going.
        #expect(flip(1, 5, duration, true) == nil)
        // Forward, at the end: reverse.
        #expect(flip(1, duration, duration, true)?.rate == -1)
        #expect(flip(1, duration - tolerance / 2, duration, true)?.rate == -1)
        #expect(flip(1, duration, duration, true)?.restartFromBeginning == false)
        // Reverse, mid-movie: keep going. Reverse, at the start: go forward again.
        #expect(flip(-1, 5, duration, true) == nil)
        #expect(flip(-1, 0, duration, true)?.rate == 1)
        // Paused (last rate 0) at either end: leave it alone, so scrubbing to an end doesn't restart playback.
        #expect(flip(0, duration, duration, true) == nil)
        #expect(flip(0, 0, duration, true) == nil)
        // Playing forward at the *start* or reverse at the *end* is not an end condition.
        #expect(flip(1, 0, duration, true) == nil)
        #expect(flip(-1, duration, duration, true) == nil)
        // An item that can't play backward just loops from the beginning.
        let loop = flip(1, duration, duration, false)
        #expect(loop?.rate == 1)
        #expect(loop?.restartFromBeginning == true)
        // Unknown duration: do nothing.
        #expect(flip(1, 0, 0, true) == nil)
    }

    @MainActor
    @Test func pingPongPlayerReversesAtTheEndAndTurnsAroundAtTheStart() async throws {
        let source = RGBAF16Image(srgb8: [UInt8](repeating: 128, count: 64 * 64 * 4), width: 64, height: 64)
        // One second of movie (60 frames at the default 60 fps).
        let url = try await MovieExporter.export(
            source: source, adjustment: OklabAdjustment(), settings: MovieExporter.Settings(frameCount: 60)
        ).url
        defer { try? FileManager.default.removeItem(at: url) }

        let controller = PingPongController(url: url)
        defer { controller.stop() }
        let player = controller.player
        let duration = try await #require(player.currentItem).asset.load(.duration).seconds

        func waitUntil(_ condition: () -> Bool) async throws -> Bool {
            for _ in 0..<150 {  // up to 3 s
                if condition() { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
            return condition()
        }

        controller.start()
        #expect(try await waitUntil { player.rate > 0 })

        // Jump near the end: playback should reach it and turn around.
        await player.seek(to: CMTime(seconds: duration - 0.1, preferredTimescale: 600))
        #expect(try await waitUntil { player.rate < 0 })

        // Jump near the start while reversing: it should turn around and play forward again.
        await player.seek(to: CMTime(seconds: 0.1, preferredTimescale: 600))
        #expect(try await waitUntil { player.rate > 0 })
    }

    // MARK: Diff caption

    @Test func diffCaptionShowsMeanAndPeakLuminanceDifference() {
        #expect(DifferenceMap.caption(mean: 1.234, peak: 9.876) == "ΔY mean 1.23  peak 9.88  (of 255)")
        #expect(DifferenceMap.caption(mean: 0, peak: 0) == "ΔY mean 0.00  peak 0.00  (of 255)")
    }

    @Test func peakTrackerKeepsTheLargestValueEverRecorded() {
        var tracker = PeakTracker()
        #expect(tracker.peak == 0)
        // A new value replaces the peak only when it is larger.
        let peaks = [1.0, 3.0, 2.0, 5.0, 4.0, 5.0, 0.0].map { tracker.record($0) }
        #expect(peaks == [1, 3, 3, 5, 5, 5, 5])
        #expect(tracker.peak == 5)
        tracker.reset()
        #expect(tracker.peak == 0)
        #expect(tracker.record(0.5) == 0.5)
    }

    @Test func movieCaptionPeakIsTheRunningMaximumOfTheMeanDiff() async throws {
        final class Frames: @unchecked Sendable { var means = [Double](); var peaks = [Double]() }
        let frames = Frames()
        // A saturated gradient, so hue rotation changes luminance a lot.
        var bytes = [UInt8]()
        for y in 0..<64 {
            for x in 0..<64 { bytes += [UInt8(x * 4), UInt8(y * 4), UInt8(255 - x * 4), 255] }
        }
        // Eight frames of 45° is one full rotation, starting at no hue change.
        let result = try await MovieExporter.export(
            source: RGBAF16Image(srgb8: bytes, width: 64, height: 64),
            adjustment: OklabAdjustment(),
            settings: MovieExporter.Settings(frameCount: 8, degreesPerFrame: 45),
            frameDiff: { mean, peak in
                frames.means.append(mean)
                frames.peaks.append(peak)
            }
        )
        defer { try? FileManager.default.removeItem(at: result.url) }

        #expect(frames.means.count == 8)
        #expect(frames.means[0] < 0.05)  // no hue change yet, so no difference
        #expect(frames.means.max() ?? 0 > 0.5)  // the sweep really does produce a difference
        // The peak at each frame is the largest mean from the first frame up to it, and never falls.
        for index in frames.means.indices {
            #expect(frames.peaks[index] == frames.means[0...index].max())
        }
        #expect(zip(frames.peaks, frames.peaks.dropFirst()).allSatisfy { $0 <= $1 })
        // The last frame shows the maximum the diff ever hit, even though the current mean has fallen below it.
        #expect(frames.peaks.last == frames.means.max())
        #expect(frames.means.contains { $0 < (frames.peaks.last ?? 0) - 0.1 })

        // The result reports which frame and which hue angle that maximum was on.
        let peak = try #require(result.peak)
        let expectedFrame = try #require(frames.means.firstIndex(of: frames.means.max() ?? 0))  // earliest on a tie
        #expect(peak.frame == expectedFrame)
        #expect(peak.angleDegrees == Double(expectedFrame) * 45)
        #expect(peak.meanError == frames.means.max())
        #expect(peak.frameCount == 8)
        #expect(peak.timeSeconds == Double(expectedFrame) / 60)
    }

    @Test func peakTrackerRemembersWhichSampleSetThePeak() {
        var tracker = PeakTracker()
        #expect(tracker.peakIndex == nil)
        for (index, value) in [0.5, 2.0, 1.0, 2.0, 0.1].enumerated() { tracker.record(value, at: index) }
        #expect(tracker.peak == 2.0)
        #expect(tracker.peakIndex == 1)  // the first of the two equal maxima
        tracker.reset()
        #expect(tracker.peakIndex == nil)
        // All zeros: nothing beats the starting peak, so the first sample stands in for it.
        for index in 0..<3 { tracker.record(0, at: index) }
        #expect(tracker.peakIndex == 0)
        // Unlabelled samples never produce an index.
        var plain = PeakTracker()
        plain.record(3)
        #expect(plain.peakIndex == nil)
    }

    @Test func moviePeakReportsFrameAngleAndTime() {
        let peak = MoviePeak(frame: 312, angleDegrees: 156, meanError: 2.1, frameCount: 720, framesPerSecond: 60)
        #expect(peak.timeSeconds == 5.2)
    }

    // MARK: Automatic movie generation

    /// Waits (up to `seconds`) for `condition`, polling on the main actor.
    @MainActor
    private func waitUntil(seconds: Double = 20, _ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<Int(seconds / 0.02) {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @MainActor
    private func makeModelWithQuickMovie(autoGenerates: Bool = true) throws -> HueLabModel {
        let model = HueLabModel()
        model.autoGeneratesMovie = autoGenerates
        // Eight frames of 45° is one full rotation, and renders in a moment.
        model.movieSettings = MovieExporter.Settings(frameCount: 8, degreesPerFrame: 45)
        return model
    }

    @MainActor
    @Test func movieIsGeneratedAutomaticallyOnceTheImageLoads() async throws {
        let model = try makeModelWithQuickMovie()
        #expect(model.movieURL == nil)
        await model.load(data: try #require(makeTestPNG(size: 64)))

        // Nobody asked for it: generation starts as soon as the image (its data) is ready.
        #expect(model.isMakingMovie || model.movieURL != nil)
        #expect(try await waitUntil { model.movieURL != nil })
        let url = try #require(model.movieURL)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!model.isMakingMovie)

        // The frame and hue angle of the peak are available for the view to show.
        let peak = try #require(model.moviePeak)
        #expect(peak.frameCount == 8)
        #expect((0..<8).contains(peak.frame))
        #expect(peak.angleDegrees == Double(peak.frame) * 45)
        #expect(peak.meanError > 0)
        // It did not open a player by itself.
        #expect(model.finishedMovieURL == nil)
    }

    @MainActor
    @Test func movieAlwaysStartsAtZeroDegreesWhateverTheDialSays() async throws {
        let model = try makeModelWithQuickMovie()
        await model.load(data: try #require(makeTestPNG(size: 64)))
        #expect(try await waitUntil { model.movieURL != nil })
        let first = try #require(model.moviePeak)
        let firstURL = try #require(model.movieURL)
        defer { try? FileManager.default.removeItem(at: firstURL) }

        // Moving the dial isn't a dependency: the movie is neither discarded nor regenerated.
        model.adjustment.deltaThetaDegrees = 200
        model.adjustmentChanged()
        try await Task.sleep(for: .seconds(HueLabModel.movieSettleSeconds + 0.5))
        #expect(model.movieURL == firstURL)
        #expect(model.moviePeak == first)
    }

    @MainActor
    @Test func changingAScaleDiscardsTheMovieAndRegeneratesItWhenSettled() async throws {
        let model = try makeModelWithQuickMovie()
        await model.load(data: try #require(makeTestPNG(size: 64)))
        #expect(try await waitUntil { model.movieURL != nil })
        let oldURL = try #require(model.movieURL)

        model.adjustment.chromaScale = 0.6
        model.adjustmentChanged()
        // Out of date immediately: the old movie no longer counts and its file is removed.
        #expect(model.movieURL == nil)
        #expect(model.moviePeak == nil)
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))

        // Once the change settles, a fresh movie is made without anyone asking.
        #expect(try await waitUntil { model.movieURL != nil })
        let newURL = try #require(model.movieURL)
        defer { try? FileManager.default.removeItem(at: newURL) }
        #expect(newURL != oldURL)
        #expect(model.moviePeak != nil)

        // The diff gain is part of the movie too.
        model.diffGain = 40
        model.diffGainEdited()
        #expect(model.movieURL == nil)
        #expect(try await waitUntil { model.movieURL != nil })
        if let url = model.movieURL { try? FileManager.default.removeItem(at: url) }
    }

    @MainActor
    @Test func aMovieThatWasOpenedIsKeptWhenItIsSuperseded() async throws {
        let model = try makeModelWithQuickMovie()
        await model.load(data: try #require(makeTestPNG(size: 64)))
        #expect(try await waitUntil { model.movieURL != nil })
        let playedURL = try #require(model.movieURL)
        defer { try? FileManager.default.removeItem(at: playedURL) }

        model.playMovie()
        #expect(model.finishedMovieURL == playedURL)  // opens right away when ready

        // A player may still be showing it, so a newer movie must not delete it.
        model.adjustment.lightnessScale = 1.2
        model.adjustmentChanged()
        #expect(FileManager.default.fileExists(atPath: playedURL.path))
        #expect(try await waitUntil { model.movieURL != nil })
        if let url = model.movieURL { try? FileManager.default.removeItem(at: url) }
    }

    @MainActor
    @Test func playingBeforeTheMovieIsReadyOpensItAsSoonAsItIs() async throws {
        let model = try makeModelWithQuickMovie()
        await model.load(data: try #require(makeTestPNG(size: 64)))
        model.playMovie()
        if model.movieURL == nil {
            #expect(model.openMovieWhenReady)
            #expect(model.finishedMovieURL == nil)
        }
        #expect(try await waitUntil { model.finishedMovieURL != nil })
        let url = try #require(model.finishedMovieURL)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(url == model.movieURL)
        #expect(!model.openMovieWhenReady)
    }

    @MainActor
    @Test func withAutoGenerationOffTheMovieOnlyAppearsWhenPlayIsPressed() async throws {
        let model = try makeModelWithQuickMovie(autoGenerates: false)
        await model.load(data: try #require(makeTestPNG(size: 64)))
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.movieURL == nil && !model.isMakingMovie)

        model.playMovie()  // generates on demand
        #expect(try await waitUntil { model.finishedMovieURL != nil })
        if let url = model.finishedMovieURL { try? FileManager.default.removeItem(at: url) }
    }

    @MainActor
    @Test func appDiffPeakHoldsTheMaximumAndResetsOnScaleChangeOrReset() async throws {
        let model = HueLabModel()
        model.autoGeneratesMovie = false  // these tests aren't about the movie
        let png = try #require(makeTestPNG())
        await model.load(data: png)

        func settle(_ condition: () -> Bool) async throws -> Bool {
            for _ in 0..<150 {  // up to 3 s for the coalesced render and diff tasks
                if condition() { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
            return condition()
        }
        func setHue(_ degrees: Double) {
            model.adjustment.deltaThetaDegrees = degrees
            model.adjustmentChanged()
        }

        // A big hue change raises the mean diff, and the peak follows it.
        setHue(120)
        #expect(try await settle { model.diffMeanError > 0.5 })
        let high = model.diffMeanError
        #expect(try await settle { model.diffPeakMeanError >= high })

        // Back to no hue change: the current mean falls but the peak holds.
        setHue(0)
        #expect(try await settle { model.diffMeanError < high / 2 })
        #expect(model.diffPeakMeanError >= high)

        // A new chroma scale starts a new peak, which is back down near the current (small) mean.
        model.adjustment.chromaScale = 0.95
        model.adjustmentChanged()
        #expect(try await settle { model.diffPeakMeanError < high / 2 })

        // Raising the peak again, then resetting it explicitly.
        setHue(120)
        #expect(try await settle { model.diffPeakMeanError > 0.5 })
        model.resetPeak()
        #expect(model.diffPeakMeanError == 0)
    }

    @Test func drawCaptionWritesOnlyInsideTheGivenPaneAtTheBottomLeft() {
        let width = 300, height = 100, bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 128, count: bytesPerRow * height)
        let pane = CGRect(x: 100, y: 0, width: 100, height: 100)  // the middle third
        buffer.withUnsafeMutableBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            MovieExporter.drawCaption(
                "ΔY mean 1.00", into: base, bytesPerRow: bytesPerRow, frameWidth: width, frameHeight: height, pane: pane
            )
        }
        func pixels(x: Range<Int>, rows: Range<Int>) -> [UInt8] {
            rows.flatMap { row in x.flatMap { column in (0..<3).map { buffer[row * bytesPerRow + column * 4 + $0] } } }
        }

        // Outside the pane: untouched.
        #expect(pixels(x: 0..<100, rows: 0..<height).allSatisfy { $0 == 128 })
        #expect(pixels(x: 200..<300, rows: 0..<height).allSatisfy { $0 == 128 })
        // Top of the pane: untouched.
        #expect(pixels(x: 100..<200, rows: 0..<50).allSatisfy { $0 == 128 })
        // Bottom-left of the pane: a dark plate with white text on it.
        let caption = pixels(x: 100..<200, rows: 70..<100)
        #expect(caption.contains { $0 < 90 })
        #expect(caption.contains { $0 > 200 })
    }

    @Test func movieFramesCarryTheLuminanceDiffCaption() async throws {
        let width = 96, height = 64
        var bytes = [UInt8]()
        for y in 0..<height {
            for x in 0..<width { bytes += [UInt8(x * 2), UInt8(y * 3), 160, 255] }
        }
        // Frame 0 has no hue change, so the diff pane is black and any bright pixel there is the caption.
        let url = try await MovieExporter.export(
            source: RGBAF16Image(srgb8: bytes, width: width, height: height),
            adjustment: OklabAdjustment(),
            settings: MovieExporter.Settings(frameCount: 3)
        ).url
        defer { try? FileManager.default.removeItem(at: url) }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        let (frame, _) = try await generator.image(at: .zero)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: frame.width, height: frame.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        let data = try #require(context.data).bindMemory(to: UInt8.self, capacity: context.bytesPerRow * frame.height)
        func brightest(x: Range<Int>, rows: Range<Int>) -> UInt8 {
            rows.flatMap { row in x.flatMap { column in (0..<3).map { data[row * context.bytesPerRow + column * 4 + $0] } } }.max() ?? 0
        }

        // Sample a few pixels in from the pane edges: ProRes 422 subsamples chroma horizontally, so color from the
        // neighboring pane bleeds a little way across the seam.
        let diffPane = (width * 2 + 8)..<(width * 3 - 8)
        #expect(brightest(x: diffPane, rows: 0..<16) < 30)  // top of the diff pane: black
        #expect(brightest(x: diffPane, rows: 40..<64) > 150)  // bottom-left: the caption text
    }

    // MARK: Quick peak search

    @Test func sweepEvaluatorMatchesTheRenderedDifference() {
        // The sweep never renders either image; it must still report what the rendered diff would.
        let image = makeSmoothImage(width: 64, height: 64)
        for var adjustment in [
            OklabAdjustment(),
            OklabAdjustment(lightnessScale: 1.15, chromaScale: 0.8),
            OklabAdjustment(lightnessScale: 0.85, chromaScale: 1.3),
        ] {
            let evaluator = HueSweep.Evaluator(HueSweepSource(image), adjustment: adjustment)
            for degrees in [0.0, 37.5, 120, 210, 301.5] {
                adjustment.deltaThetaDegrees = degrees
                var preserved = adjustment
                preserved.preserveLuminance = true
                let rendered = OklabRotor.differenceMap(
                    OklabRotor.apply(adjustment, to: image).image,
                    OklabRotor.apply(preserved, to: image).image,
                    gain: 16
                ).meanError
                #expect(abs(evaluator.meanError(atDegrees: degrees) - rendered) < 0.02)
            }
        }
    }

    @Test func quickSearchFindsTheSamePeakAsTheExhaustiveSweep() async throws {
        // Big enough (> 40k pixels) that the coarse pass really does use a pixel subsample.
        let image = makeSmoothImage(width: 256, height: 192)
        let settings = MovieExporter.Settings()  // 720 frames, 0.5° apart
        for adjustment in [
            OklabAdjustment(),
            OklabAdjustment(lightnessScale: 1.15, chromaScale: 0.7),
            OklabAdjustment(lightnessScale: 0.8, chromaScale: 1.4),
        ] {
            let quick = try #require(try await HueSweep.findPeak(in: image, adjustment: adjustment, settings: settings))
            let exhaustive = try #require(
                try await HueSweep.findPeak(in: image, adjustment: adjustment, settings: settings, exhaustive: true)
            )
            #expect(quick.frame == exhaustive.frame)
            #expect(quick.angleDegrees == exhaustive.angleDegrees)
            #expect(abs(quick.meanError - exhaustive.meanError) < 1e-6)
            #expect(exhaustive.meanError > 0.5)  // a real peak, not a flat curve
            #expect(quick.frameCount == 720 && quick.framesPerSecond == 60)
        }
    }

    @Test func sweepPeakAgreesWithTheMovieItPredicts() async throws {
        let image = makeSmoothImage(width: 64, height: 64)
        let settings = MovieExporter.Settings(frameCount: 8, degreesPerFrame: 45)
        let adjustment = OklabAdjustment(lightnessScale: 1.1, chromaScale: 0.9)

        let predicted = try #require(try await HueSweep.findPeak(in: image, adjustment: adjustment, settings: settings))
        let result = try await MovieExporter.export(source: image, adjustment: adjustment, settings: settings)
        defer { try? FileManager.default.removeItem(at: result.url) }
        let measured = try #require(result.peak)

        #expect(predicted.frame == measured.frame)
        #expect(predicted.angleDegrees == measured.angleDegrees)
        #expect(abs(predicted.meanError - measured.meanError) < 0.02)
    }

    @Test func sweepCoversPartialSweepsAndStopsOnCancellation() async throws {
        // A sweep that isn't a full turn is searched without wrapping, and reports real angles.
        let image = makeSmoothImage(width: 64, height: 64)
        let partial = MovieExporter.Settings(frameCount: 40, degreesPerFrame: 1)  // 0°...39° only
        let peak = try #require(try await HueSweep.findPeak(in: image, adjustment: OklabAdjustment(), settings: partial))
        let exhaustive = try #require(
            try await HueSweep.findPeak(in: image, adjustment: OklabAdjustment(), settings: partial, exhaustive: true)
        )
        #expect(peak.frame == exhaustive.frame)
        #expect((0..<40).contains(peak.frame))

        // Cancelling the calling task stops a long sweep.
        let task = Task {
            try await HueSweep.findPeak(
                in: image, adjustment: OklabAdjustment(), settings: MovieExporter.Settings(frameCount: 200_000), exhaustive: true
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @MainActor
    @Test func predictedPeakAppearsAfterLoadAndFollowsTheScales() async throws {
        let model = try makeModelWithQuickMovie(autoGenerates: false)  // no movie involved
        #expect(model.predictedPeak == nil)
        await model.load(data: try #require(makeTestPNG(size: 64)))

        // Nobody asked for it: the sweep starts with the image and finishes quickly.
        #expect(model.isFindingPeak || model.predictedPeak != nil)
        #expect(try await waitUntil(seconds: 5) { model.predictedPeak != nil })
        let first = try #require(model.predictedPeak)
        #expect(first.frameCount == 8)
        #expect(first.angleDegrees == Double(first.frame) * 45)
        #expect(!model.isFindingPeak)

        // The dial isn't a dependency of the peak.
        model.adjustment.deltaThetaDegrees = 100
        model.adjustmentChanged()
        try await Task.sleep(for: .seconds(HueLabModel.sweepSettleSeconds + 0.4))
        #expect(model.predictedPeak == first)

        // A new chroma scale makes the old answer wrong: it's dropped at once and a new one arrives.
        model.adjustment.chromaScale = 0.5
        model.adjustmentChanged()
        #expect(model.predictedPeak == nil)
        #expect(model.isFindingPeak)
        #expect(try await waitUntil(seconds: 5) { model.predictedPeak != nil })
        #expect(model.predictedPeak?.meanError != first.meanError)
    }

    @MainActor
    @Test func theMoviesMeasuredPeakConfirmsTheQuickSweep() async throws {
        let model = try makeModelWithQuickMovie()
        await model.load(data: try #require(makeTestPNG(size: 64)))
        #expect(try await waitUntil { model.movieURL != nil && model.predictedPeak != nil })
        defer { if let url = model.movieURL { try? FileManager.default.removeItem(at: url) } }

        let predicted = try #require(model.predictedPeak)
        let measured = try #require(model.moviePeak)
        #expect(predicted.frame == measured.frame)
        #expect(predicted.angleDegrees == measured.angleDegrees)
        #expect(abs(predicted.meanError - measured.meanError) < 0.02)
    }

    // MARK: Sanity check: where the peak can fall
    //
    // ΔY is zero at 0° of rotation and grows from there. At a fixed lightness and chroma, luminance varies roughly
    // sinusoidally around the hue circle, so a pixel differs most from its original at the opposite extreme of that
    // wave: normally 90°...180° of rotation away. A peak close to 0° on a colorful image means something is wrong.

    @Test func aPixelsLuminanceDifferencePeaksAboutNinetyDegreesOrMoreAwayFromItsOriginalHue() {
        var distances = [Double]()
        for chroma: Float in [0.03, 0.08, 0.15, 0.25] {
            for lightness: Float in [0.3, 0.5, 0.7, 0.9] {
                for hue in stride(from: 0.0, to: 360, by: 10) {
                    let radians = Float(hue * .pi / 180)
                    let linear = OklabRotor.oklabToLinear(SIMD3(lightness, chroma * cosf(radians), chroma * sinf(radians)))
                    guard OklabRotor.isInSRGBGamut(linear) else { continue }  // only colors a display can show
                    let pixel = RGBAF16Image(
                        width: 1, height: 1, pixels: [Float16(linear.x), Float16(linear.y), Float16(linear.z), 1]
                    )
                    let evaluator = HueSweep.Evaluator(HueSweepSource(pixel), adjustment: OklabAdjustment())
                    let curve = (0..<720).map { evaluator.meanError(atDegrees: Double($0) * 0.5) }
                    guard let peak = curve.max(), peak > 0.5, let frame = curve.firstIndex(of: peak) else { continue }
                    distances.append(angularDistanceFromZero(Double(frame) * 0.5))
                }
            }
        }
        #expect(distances.count > 200)  // plenty of in-gamut pixels with a real luminance difference
        // The rule is an approximation (the cubes in the light conversion bend the sine): measured minimum is 84.5°.
        #expect((distances.min() ?? 0) > 75)
        #expect(Double(distances.filter { $0 < 90 }.count) / Double(distances.count) < 0.1)
        // Typically well past 90°: the median measured is about 135°.
        #expect(distances.sorted()[distances.count / 2] > 110)
    }

    @Test func aColorfulImagesPeakIsNeverNearNoRotation() async throws {
        let images: [(name: String, image: RGBAF16Image)] = [
            ("smooth", makeSmoothImage(width: 128, height: 96)),
            ("blocks 1", makeBlockImage(width: 128, height: 96, seed: 1)),
            ("blocks 2", makeBlockImage(width: 128, height: 96, seed: 2)),
            ("blocks 3", makeBlockImage(width: 128, height: 96, seed: 3)),
        ]
        let adjustments = [
            OklabAdjustment(),
            OklabAdjustment(lightnessScale: 1.2, chromaScale: 0.7),
            OklabAdjustment(lightnessScale: 0.8, chromaScale: 1.4),
        ]
        for (name, image) in images {
            for adjustment in adjustments {
                let peak = try #require(
                    try await HueSweep.findPeak(in: image, adjustment: adjustment, settings: MovieExporter.Settings())
                )
                let distance = angularDistanceFromZero(peak.angleDegrees)
                #expect(peak.meanError > 0.5, "\(name): expected a real luminance difference")
                // The flag: a peak within 60° of no rotation would be suspicious on a colorful image.
                #expect(distance > 60, "\(name) peaked at \(peak.angleDegrees)°, only \(distance)° from no rotation")
            }
        }
    }

    @Test func aGrayImageHasNoMeaningfulPeak() async throws {
        // The check above doesn't apply to colorless images: hue rotation can't change a gray's luminance.
        var bytes = [UInt8]()
        for y in 0..<64 { for x in 0..<64 { bytes += [UInt8(x * 4), UInt8(x * 4), UInt8(x * 4), 255]; _ = y } }
        let gray = RGBAF16Image(srgb8: bytes, width: 64, height: 64)
        let peak = try #require(try await HueSweep.findPeak(in: gray, adjustment: OklabAdjustment(), settings: MovieExporter.Settings()))
        #expect(peak.meanError < 0.05)
    }

    @Test func movieExportRejectsTinyImages() async {
        let source = RGBAF16Image(width: 1, height: 1, pixels: [0, 0, 0, 1])
        await #expect(throws: MovieExporter.ExportError.self) {
            try await MovieExporter.export(source: source, adjustment: OklabAdjustment())
        }
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
