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
    /// Mean of that difference in gamma-encoded 8-bit units (0...255), before gain.
    private(set) var diffMeanError = 0.0
    /// The largest `diffMeanError` seen since the peak was last reset: on loading an image, pressing Reset,
    /// starting Animate, or changing the lightness / chroma scale. Dragging the hue dial keeps raising it.
    private(set) var diffPeakMeanError = 0.0
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

    // Peak tracking. Renders and diffs finish asynchronously, so a result computed before a reset must not count
    // toward the new peak: each render remembers the epoch it started in and only counts if it's still current.
    @ObservationIgnored private var peakTracker = PeakTracker()
    @ObservationIgnored private var peakEpoch = 0
    @ObservationIgnored private var latestRenderEpoch = 0
    @ObservationIgnored private var peakLightnessScale = 1.0
    @ObservationIgnored private var peakChromaScale = 1.0

    /// Forgets the peak so the next measurement starts a new one.
    func resetPeak() {
        peakTracker.reset()
        diffPeakMeanError = 0
        peakEpoch += 1
    }

    nonisolated private static let previewDimension = 1024
    nonisolated private static let fullDimension = 4096

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
        resetPeak()  // so the sweep ends showing the peak over this rotation
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

    // MARK: Quick peak search

    // Before (and independently of) the movie, a cheap sweep over the movie's frame angles finds which one has the
    // largest mean luminance difference. It needs no rendering, so the answer is on screen within about a second;
    // the movie later measures the same thing from its actual frames and its result replaces this one.
    // The sweep depends on the image and the lightness / chroma scales (not on the dial or the diff gain).

    /// Where the sweep expects the movie's peak to fall; nil until the sweep has run for the current inputs.
    private(set) var predictedPeak: MoviePeak?
    /// A sweep is running, or waiting for the inputs to settle.
    private(set) var isFindingPeak = false

    /// How long the scales must stay unchanged before the sweep re-runs; much shorter than the movie's wait.
    nonisolated static let sweepSettleSeconds = 0.15

    @ObservationIgnored private var sweepTask: Task<Void, Never>?
    @ObservationIgnored private var sweepDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var sweepGeneration = 0

    private func invalidateSweep() {
        sweepDebounceTask?.cancel()
        sweepDebounceTask = nil
        sweepTask?.cancel()
        sweepTask = nil
        sweepGeneration += 1
        predictedPeak = nil
        isFindingPeak = false
    }

    /// Discards the predicted peak and finds a new one once `delay` passes without another change.
    private func scheduleSweep(after delay: Duration) {
        guard previewSource != nil else { return }
        invalidateSweep()
        guard delay > .zero else {
            startSweep()
            return
        }
        isFindingPeak = true
        sweepDebounceTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            startSweep()
        }
    }

    private func startSweep() {
        guard let preview = previewSource else { return }
        sweepDebounceTask = nil
        sweepGeneration += 1
        let generation = sweepGeneration
        isFindingPeak = true
        // The sweep covers the same frame angles as the movie, which always starts at 0°.
        var adjustment = adjustment
        adjustment.deltaThetaDegrees = 0
        let settings = movieSettings
        sweepTask = Task(priority: .userInitiated) {
            let peak = try? await HueSweep.findPeak(in: preview, adjustment: adjustment, settings: settings)
            guard generation == sweepGeneration, !Task.isCancelled else { return }  // superseded
            predictedPeak = peak
            isFindingPeak = false
            sweepTask = nil
        }
    }

    // The movie is a full rotation of the hue angle starting at 0°, so its data depends only on the image, the
    // lightness and chroma scales, and the diff gain. It is generated automatically as soon as those are known
    // (right after an image loads) and regenerated, after they've stopped changing for a moment, when they change.
    // The hue dial and Animate don't affect it.

    /// Frames, rate and step of the generated movie. (`diffGain` is taken from the model when generating.)
    var movieSettings = MovieExporter.Settings()
    /// When false, nothing is generated until `playMovie()` asks for it. For tests.
    var autoGeneratesMovie = true

    /// How long the movie's inputs must stay unchanged before it is regenerated.
    nonisolated static let movieSettleSeconds = 0.75

    /// A movie is being rendered.
    private(set) var isMakingMovie = false
    /// 0...1 while a movie is rendering.
    private(set) var movieProgress = 0.0
    /// The inputs changed and a regeneration is waiting for them to settle.
    private(set) var isMoviePending = false
    /// The finished movie for the current image and settings, or nil while it's out of date or being generated.
    private(set) var movieURL: URL?
    /// Where in that movie the luminance difference peaked: which frame and which hue angle.
    private(set) var moviePeak: MoviePeak?
    /// The user asked to play the movie before it was ready; it opens as soon as it is.
    private(set) var openMovieWhenReady = false
    private(set) var movieErrorMessage: String?
    /// Set when a movie should open in a player; the view opens it and clears this.
    var finishedMovieURL: URL?

    @ObservationIgnored private var movieTask: Task<Void, Never>?
    @ObservationIgnored private var movieDebounceTask: Task<Void, Never>?
    /// Bumped whenever the movie's inputs change, so results from superseded generations are ignored.
    @ObservationIgnored private var movieGeneration = 0
    /// Movies that have been opened in a player: kept on disk when superseded, since they may still be playing.
    @ObservationIgnored private var pinnedMovieURLs = Set<URL>()

    /// Plays the movie: opens it now if it's ready, otherwise as soon as it is (starting its generation if nothing
    /// is under way, e.g. after an error).
    func playMovie() {
        if let url = movieURL {
            present(url)
            return
        }
        guard previewSource != nil else { return }
        openMovieWhenReady = true
        if !isMakingMovie { startMovieGeneration() }
    }

    private func present(_ url: URL) {
        pinnedMovieURLs.insert(url)
        finishedMovieURL = url
    }

    /// Drops the current movie (cancelling any generation) because its inputs changed or the image was replaced.
    private func invalidateMovie() {
        movieDebounceTask?.cancel()
        movieDebounceTask = nil
        movieTask?.cancel()
        movieTask = nil
        movieGeneration += 1
        if let movieURL, !pinnedMovieURLs.contains(movieURL) {
            try? FileManager.default.removeItem(at: movieURL)
        }
        movieURL = nil
        moviePeak = nil
        isMakingMovie = false
        isMoviePending = false
        movieProgress = 0
        movieErrorMessage = nil
    }

    /// Call when something the movie depends on has changed (or just become available): discards the movie and
    /// regenerates it once `delay` passes without another change.
    private func scheduleMovie(after delay: Duration) {
        guard previewSource != nil else { return }
        invalidateMovie()  // a movie made from the old inputs is out of date either way
        guard autoGeneratesMovie else { return }
        guard delay > .zero else {
            startMovieGeneration()  // nothing to wait for
            return
        }
        isMoviePending = true
        movieDebounceTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            startMovieGeneration()
        }
    }

    private func startMovieGeneration() {
        guard let preview = previewSource else { return }
        movieDebounceTask?.cancel()
        movieDebounceTask = nil
        movieTask?.cancel()
        movieGeneration += 1
        let generation = movieGeneration
        isMoviePending = false
        isMakingMovie = true
        movieProgress = 0
        movieErrorMessage = nil
        // The sweep always starts at 0°, so it doesn't depend on where the dial happens to be.
        var adjustment = adjustment
        adjustment.deltaThetaDegrees = 0
        var settings = movieSettings
        settings.diffGain = Float(diffGain)
        // Utility priority: this is a long background job that shouldn't slow the live preview.
        movieTask = Task(priority: .utility) {
            do {
                // `export` is @concurrent, so the rendering runs off the main actor; awaiting it directly
                // (rather than via a detached task) keeps cancellation connected.
                let result = try await MovieExporter.export(
                    source: preview, adjustment: adjustment, settings: settings
                ) { progress in
                    Task { @MainActor in
                        if self.movieGeneration == generation { self.movieProgress = progress }
                    }
                }
                guard generation == movieGeneration else {
                    try? FileManager.default.removeItem(at: result.url)  // superseded while finishing
                    return
                }
                movieURL = result.url
                moviePeak = result.peak
                isMakingMovie = false
                movieTask = nil
                if openMovieWhenReady {
                    openMovieWhenReady = false
                    present(result.url)
                }
            } catch is CancellationError {
                // Superseded by a newer generation, or the image was replaced; the newer one owns the state.
            } catch {
                guard generation == movieGeneration else { return }
                movieErrorMessage = error.localizedDescription
                isMakingMovie = false
                openMovieWhenReady = false
                movieTask = nil
            }
        }
    }

    /// Call when the diff gain slider moves: redraws the diff pane, and since the movie's diff pane uses the same
    /// gain, schedules a new movie.
    func diffGainEdited() {
        diffGainChanged()
        scheduleMovie(after: .seconds(Self.movieSettleSeconds))
    }

    func load(data: Data) async {
        stopAnimation()
        invalidateMovie()
        invalidateSweep()
        openMovieWhenReady = false
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
        resetPeak()
        adjustmentChanged()
        // Everything both need is now known: find the peak and start generating the movie right away.
        scheduleSweep(after: .zero)
        scheduleMovie(after: .zero)
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
        // The peak describes a sweep of the hue angle at fixed lightness / chroma scales; a new scale starts over.
        if adjustment.lightnessScale != peakLightnessScale || adjustment.chromaScale != peakChromaScale {
            peakLightnessScale = adjustment.lightnessScale
            peakChromaScale = adjustment.chromaScale
            resetPeak()
            // The movie's content, and the hue angle where the difference peaks, depend on these scales too.
            scheduleSweep(after: .seconds(Self.sweepSettleSeconds))
            scheduleMovie(after: .seconds(Self.movieSettleSeconds))
        }
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
            let epoch = peakEpoch
            let (plainRender, preservedRender) = await Task.detached(priority: .userInitiated) {
                (Self.render(plain, of: preview), Self.render(preserved, of: preview))
            }.value
            latestPlain = plainRender.image
            latestPreserved = preservedRender.image
            latestRenderEpoch = epoch
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
            let epoch = latestRenderEpoch
            let map = await Task.detached(priority: .userInitiated) {
                OklabRotor.differenceMap(plain, preserved, gain: gain)
            }.value
            diffImage = map.image.makeCGImage()
            diffMeanError = map.meanError
            // Only a measurement made since the last reset counts toward the peak.
            if epoch == peakEpoch {
                diffPeakMeanError = peakTracker.record(map.meanError)
            }
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
