import AppKit
import SwiftUI

@main
struct SnapshotRenderer {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let size = NSSize(width: 1160, height: 730)
        let view = NSHostingView(rootView: ContentView())
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()

        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fatalError("Could not create a snapshot bitmap")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not encode the snapshot")
        }

        let output = CommandLine.arguments.dropFirst().first ?? "/private/tmp/TilePatternMaker.png"
        do {
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
            print(output)
        } catch {
            fatalError("Could not write the snapshot: \(error)")
        }
    }
}
