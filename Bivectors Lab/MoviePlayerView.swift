//
//  MoviePlayerView.swift
//  Bivectors Lab
//

import SwiftUI
import AVKit

/// A movie to show in a full-screen cover / sheet on platforms without separate player windows.
struct MovieItem: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Plays a movie forward, then backward, then forward again, indefinitely ("ping-pong").
///
/// Reaching either end doesn't flip an `AVPlayer` by itself, so a periodic time observer watches the playhead and
/// reverses the rate at each end. The decision is a pure function (`flip`) so it can be tested without playback.
@MainActor
final class PingPongController {
    let player: AVPlayer
    private var timeObserver: Any?
    /// The rate seen on the previous tick. Flipping only happens if we were actually playing toward that end, so a
    /// user who pauses or scrubs to an end isn't fought.
    private var lastRate: Float = 0

    /// How close to an end (in seconds) counts as having reached it: about one frame at 60 Hz.
    nonisolated static let edgeTolerance = 1.0 / 60

    /// What to do at the ends of the movie, given the previous playback rate and the playhead.
    /// Returns nil when nothing should change.
    nonisolated static func flip(
        lastRate: Float, time: Double, duration: Double, canPlayReverse: Bool
    ) -> (rate: Float, restartFromBeginning: Bool)? {
        guard duration > 0 else { return nil }
        if lastRate > 0, time >= duration - edgeTolerance {
            // Reached the end going forward: turn around, or just loop if this item can't play backward.
            return canPlayReverse ? (-1, false) : (1, true)
        }
        if lastRate < 0, time <= edgeTolerance {
            return (1, false)
        }
        return nil
    }

    init(url: URL) {
        player = AVPlayer(url: url)
        // Stay at the end instead of pausing, so we can reverse from there.
        player.actionAtItemEnd = .none
    }

    func start() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 60), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        player.play()
    }

    /// Stops playback and removes the time observer. Call when the player goes away.
    func stop() {
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        lastRate = 0
    }

    private func tick() {
        guard let item = player.currentItem else { return }
        let duration = item.duration.seconds
        if duration.isFinite,
           let change = Self.flip(
               lastRate: lastRate,
               time: player.currentTime().seconds,
               duration: duration,
               canPlayReverse: item.canPlayReverse
           ) {
            if change.restartFromBeginning {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player.rate = change.rate
        }
        lastRate = player.rate
    }
}

/// Plays a movie full screen, looping back and forth, with scrub, play / pause and full-screen controls.
struct MoviePlayerView: View {
    @State private var controller: PingPongController
#if !os(macOS)
    @Environment(\.dismiss) private var dismiss
#endif

    init(url: URL) {
        _controller = State(initialValue: PingPongController(url: url))
    }

    var body: some View {
        playerView
            .onAppear { controller.start() }
            .onDisappear { controller.stop() }
#if os(macOS)
            .frame(minWidth: 480, minHeight: 200)
#else
            .overlay(alignment: .topLeading) {
                Button("Done", systemImage: "xmark.circle.fill") { dismiss() }
                    .labelStyle(.iconOnly)
                    .font(.title)
                    .padding()
            }
#endif
    }

    @ViewBuilder
    private var playerView: some View {
#if os(macOS)
        // AVPlayerView shows the full-screen button only when asked; SwiftUI's VideoPlayer doesn't expose that.
        MacPlayerView(player: controller.player)
#else
        VideoPlayer(player: controller.player)
            .ignoresSafeArea()
#endif
    }
}

#if os(macOS)
/// An `AVPlayerView` whose window enters full screen the first time it appears.
private final class FullScreenPlayerView: AVPlayerView {
    private var hasEnteredFullScreen = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !hasEnteredFullScreen, let window else { return }
        hasEnteredFullScreen = true
        // Let the window finish ordering in before animating into full screen.
        DispatchQueue.main.async {
            if !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        }
    }
}

private struct MacPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = FullScreenPlayerView()
        view.player = player
        view.controlsStyle = .inline  // scrubber, play / pause, time
        view.showsFullScreenToggleButton = true
        view.showsSharingServiceButton = true  // lets you save / share the movie file
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}
#endif
