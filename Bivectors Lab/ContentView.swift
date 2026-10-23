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

    private var workspace: some View {
        ScrollView {
            VStack(spacing: 24) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) { imagePanes }
                    VStack(spacing: 16) { imagePanes }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 32) { controls }
                    VStack(spacing: 24) { controls }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var imagePanes: some View {
        pane("Original", image: model.originalImage)
        pane("Adjusted", image: model.adjustedImage)
        if let restored = model.restoredImage {
            pane("Restored (inverse)", image: restored)
        }
    }

    private func pane(_ title: String, image: CGImage?) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.headline)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 220, maxWidth: .infinity)
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 8) {
            HueDial(degrees: $model.adjustment.deltaThetaDegrees)
                .frame(width: 220, height: 220)
            Stepper("Fine adjust Δθ", value: $model.adjustment.deltaThetaDegrees, in: 0...360, step: 1)
                .labelsHidden()
        }

        VStack(alignment: .leading, spacing: 16) {
            scaleSlider("Lightness scale", value: $model.adjustment.lightnessScale)
            scaleSlider("Chroma scale", value: $model.adjustment.chromaScale)

            Button("Reset", systemImage: "arrow.counterclockwise") {
                model.adjustment = OklabAdjustment()
            }
            .disabled(model.adjustment.isIdentity)

            Divider()
            metadataReadout

            Button("Restore (apply inverse)", systemImage: "arrow.uturn.backward") {
                model.restore()
            }
            .disabled(model.isRestoring)

            if let stats = model.restoreStats {
                Text("Restore error vs original: max \(stats.maxError, specifier: "%.3f"), mean \(stats.meanError, specifier: "%.4f") (8-bit units, of 255)")
                    .font(.callout.monospacedDigit())
            }
        }
        .frame(minWidth: 260, maxWidth: 360)
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
            Text("Pixels outside sRGB gamut (preserved, preview): \(model.outOfGamut)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
