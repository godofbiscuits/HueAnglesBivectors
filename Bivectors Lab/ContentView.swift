//
//  ContentView.swift
//  Bivectors Lab
//

import SwiftUI
import PhotosUI

struct ContentView: View {
    @State private var model = HueLabModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingImporter = false
#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#else
    @State private var presentedMovie: MovieItem?
#endif

    var body: some View {
        NavigationStack {
            Group {
                if model.originalImage == nil {
                    ContentUnavailableView {
                        Label("No Image", systemImage: "photo")
                    } description: {
                        Text(model.errorMessage ?? "Choose or drop an image to rotate its hue in Oklab.")
                    } actions: {
                        openButtons
                    }
                } else {
                    workspace
                }
            }
            .navigationTitle("Bivectors Lab")
            .toolbar {
                ToolbarItemGroup {
                    openButtons
                }
            }
        }
#if os(macOS)
        // Enough room for the images plus the full control row without scrolling.
        .frame(minWidth: 1100, minHeight: 680)
#endif
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                Task { await model.load(url: url) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await model.load(url: url) }
            return true
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await model.load(data: data)
                }
            }
        }
        .onChange(of: model.adjustment) {
            model.adjustmentChanged()
        }
        .onChange(of: model.diffGain) {
            model.diffGainEdited()
        }
        .onChange(of: model.finishedMovieURL) { _, url in
            guard let url else { return }
            model.finishedMovieURL = nil
#if os(macOS)
            openWindow(value: url)
#else
            presentedMovie = MovieItem(url: url)
#endif
        }
#if os(iOS)
        .fullScreenCover(item: $presentedMovie) { movie in
            MoviePlayerView(url: movie.url)
        }
#elseif !os(macOS)
        .sheet(item: $presentedMovie) { movie in
            MoviePlayerView(url: movie.url)
        }
#endif
    }

    // MARK: - Pieces

    @ViewBuilder
    private var openButtons: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            Label("Photos", systemImage: "photo.on.rectangle")
        }
        Button("Open…", systemImage: "folder") {
            showingImporter = true
        }
    }

    /// Wide windows show everything at once: images take the remaining space above a fixed-height control row.
    /// Narrow windows (e.g. iPhone) fall back to a scrolling single column.
    private var workspace: some View {
        ViewThatFits(in: .horizontal) {
            VStack(spacing: 16) {
                HStack(spacing: 12) { imagePanes }
                    .frame(maxHeight: .infinity)
                Divider()
                HStack(alignment: .center, spacing: 28) {
                    dialControl
                    sliderColumn
                    infoColumn
                }
            }
            .padding()
            .frame(minWidth: 1000)

            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 16) { imagePanes }
                    dialControl
                    sliderColumn
                    infoColumn
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private var imagePanes: some View {
        pane("Original", image: model.originalImage)
        pane("Hue-altered, luminance preserved", image: model.preservedImage)
        pane(
            "Luminance diff ×\(Int(model.diffGain)): hue-altered vs preserved",
            image: model.diffImage,
            caption: DifferenceMap.caption(mean: model.diffMeanError, peak: model.diffPeakMeanError)
        )
        if let restored = model.restoredImage {
            pane("Restored: hue-altered", image: restored)
        }
        if let restored = model.restoredPreservedImage {
            pane("Restored: luminance preserved", image: restored)
        }
    }

    /// One image pane. `caption`, if given, is written on the image itself (bottom-left), like the movie does.
    private func pane(_ title: String, image: CGImage?, caption: String? = nil) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .overlay(alignment: .bottomLeading) {
                        if let caption {
                            Text(caption)
                                .font(.system(.callout, design: .monospaced).bold())
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                                .padding(6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 160, maxWidth: .infinity)
    }

    private var dialControl: some View {
        VStack(spacing: 6) {
            HueDial(degrees: $model.adjustment.deltaThetaDegrees, onDrag: model.stopAnimation)
                .frame(width: 190, height: 190)
            HStack {
                Stepper("Fine adjust Δθ", value: $model.adjustment.deltaThetaDegrees, in: 0...360, step: 1)
                    .labelsHidden()
                Button(model.isAnimating ? "Stop" : "Animate",
                       systemImage: model.isAnimating ? "stop.fill" : "play.fill") {
                    model.toggleAnimation()
                }
                .help("Rotate the hue angle through a full 360° in \(Int(HueLabModel.animationSeconds)) seconds")
                Button("Movie", systemImage: movieButtonIcon) {
                    model.playMovie()
                }
                .disabled(model.openMovieWhenReady)
                .help(model.movieURL != nil
                      ? "Play the 60 fps movie that steps the hue angle 0.5° per frame"
                      : "The movie is made automatically; click to play it as soon as it's ready")
            }
            movieStatus
            if let message = model.movieErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(width: 190)
            }
        }
    }

    private var movieButtonIcon: String {
        if model.movieURL != nil { return "play.rectangle.fill" }
        if model.isMakingMovie || model.isMoviePending || model.openMovieWhenReady { return "hourglass" }
        return "film"
    }

    /// What the automatically generated movie is doing, under the dial.
    @ViewBuilder
    private var movieStatus: some View {
        if model.isMakingMovie {
            VStack(spacing: 2) {
                ProgressView(value: model.movieProgress)
                Text("Rendering movie… \(Int(model.movieProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 190)
        } else if model.isMoviePending {
            Text("Movie out of date; it will re-render when you stop adjusting")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 190)
        } else if model.movieURL != nil {
            Text("Movie ready")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if model.openMovieWhenReady {
            Text("Will play when ready")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sliderColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            scaleSlider("Lightness scale", value: $model.adjustment.lightnessScale)
            scaleSlider("Chroma scale", value: $model.adjustment.chromaScale)
            VStack(alignment: .leading) {
                HStack {
                    Text("Diff gain")
                    Spacer()
                    Text("×\(Int(model.diffGain))")
                        .monospacedDigit()
                }
                Slider(value: $model.diffGain, in: 1...64)
            }
        }
        .frame(minWidth: 220, maxWidth: 320)
    }

    /// Right of the sliders: reset, stored metadata, restore.
    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Reset", systemImage: "arrow.counterclockwise") {
                model.stopAnimation()
                model.adjustment.resetValues()
                model.resetPeak()
            }
            .disabled(model.adjustment.isIdentity)

            metadataReadout

            Button("Restore (apply inverse)", systemImage: "arrow.uturn.backward") {
                model.restore()
            }
            .disabled(model.isRestoring)

            if let stats = model.restoreStats, let preservedStats = model.restorePreservedStats {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restore error vs original (8-bit units, of 255)")
                        .font(.callout)
                    Text("Hue-altered: max \(stats.maxError, specifier: "%.3f"), mean \(stats.meanError, specifier: "%.4f")")
                    Text("Luminance preserved: max \(preservedStats.maxError, specifier: "%.3f"), mean \(preservedStats.meanError, specifier: "%.4f")")
                }
                .font(.callout.monospacedDigit())
            }
        }
        .frame(minWidth: 280, maxWidth: 400, alignment: .leading)
    }

    private func scaleSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text("×\(value.wrappedValue, specifier: "%.2f")")
                    .monospacedDigit()
            }
            Slider(value: value, in: OklabAdjustment.scaleRange)
        }
    }

    private var metadataReadout: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stored metadata")
                .font(.headline)
            Text("Δθ = \(model.adjustment.deltaThetaDegrees, specifier: "%.2f")°   L × \(model.adjustment.lightnessScale, specifier: "%.2f")   C × \(model.adjustment.chromaScale, specifier: "%.2f")")
                .font(.callout.monospacedDigit())
            Text("Mean luminance Y: original \(model.originalMeanLuminance, specifier: "%.4f")")
                .font(.callout.monospacedDigit())
            Text("  hue-altered \(model.adjustedMeanLuminance, specifier: "%.4f"), luminance preserved \(model.preservedMeanLuminance, specifier: "%.4f")")
                .font(.callout.monospacedDigit())
            Text("Luminance diff, hue-altered vs preserved: mean \(model.diffMeanError, specifier: "%.3f"), peak \(model.diffPeakMeanError, specifier: "%.3f") (8-bit units)")
                .font(.callout.monospacedDigit())
            // Where the luminance difference peaks over the whole rotation. A quick sweep finds it within about a
            // second; once the movie's frames have all been generated, its own measurement replaces that.
            if let peak = model.moviePeak ?? model.predictedPeak {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(model.moviePeak != nil ? "Movie peak" : "Peak (quick sweep)"): ΔY \(peak.meanError, specifier: "%.2f") at hue \(peak.angleDegrees, specifier: "%.1f")°")
                    Text("  frame \(peak.frame + 1) of \(peak.frameCount) (\(peak.timeSeconds, specifier: "%.2f") s)")
                }
                .font(.callout.monospacedDigit().bold())
            } else if model.isFindingPeak {
                Text("Finding the peak…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Outside sRGB gamut (kept): \(model.outOfGamut) hue-altered, \(model.preservedOutOfGamut) preserved")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
