//
//  MoviePlayerView.swift
//  Bivectors Lab
//

import SwiftUI
import AVKit

/// A movie to show in a sheet on platforms without separate player windows.
struct MovieItem: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Plays a movie with scrub, play / pause and full-screen controls.
struct MoviePlayerView: View {
    @State private var player: AVPlayer

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        playerView
            .onAppear { player.play() }
            .onDisappear { player.pause() }
#if os(macOS)
            .frame(minWidth: 480, minHeight: 200)
#endif
    }

    @ViewBuilder
    private var playerView: some View {
#if os(macOS)
        // AVPlayerView shows the full-screen button only when asked; SwiftUI's VideoPlayer doesn't expose that.
        MacPlayerView(player: player)
#else
        VideoPlayer(player: player)
#endif
    }
}

#if os(macOS)
private struct MacPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
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
