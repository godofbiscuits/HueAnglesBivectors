//
//  Bivectors_LabApp.swift
//  Bivectors Lab
//
//  Created by Jeffrey Barbose on 10/23/26.
//

import SwiftUI

@main
struct Bivectors_LabApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }

#if os(macOS)
        // Player window for finished hue-rotation movies; opened with openWindow(value: url).
        WindowGroup("Hue Rotation Movie", for: URL.self) { $url in
            if let url {
                MoviePlayerView(url: url)
            } else {
                Text("No movie")
            }
        }
        .defaultSize(width: 1100, height: 420)
#endif
    }
}
