import AppKit
import SwiftUI

@main
struct SnapshotRenderer {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let model = MIDIToMMLModel()
        try model.load(data: MIDIFixture.make(), fileName: "RETRO_DEMO.mid")
        let size = NSSize(width: 1160, height: 760)
        let view = NSHostingView(rootView: MIDIToMMLContentView(model: model))
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()

        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fatalError("Could not create snapshot bitmap")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not encode snapshot")
        }
        let output = CommandLine.arguments.dropFirst().first
            ?? "/private/tmp/MIDIToMML.png"
        try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        print(output)
    }
}
