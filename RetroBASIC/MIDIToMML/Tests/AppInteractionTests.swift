import AppKit
import Foundation

@main
struct AppInteractionTests {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let model = MIDIToMMLModel()
        try model.load(data: MIDIFixture.make(), fileName: "fixture.mid")

        guard model.midiFile?.parts.count == 2,
              model.partIDs.compactMap({ $0 }).count == 2,
              model.output.contains("PLAY A$,B$,C$") else {
            fatalError("loading MIDI did not populate the converter")
        }

        model.setBackgroundPlayback(true)
        guard model.output.contains("A$=\"MB") else {
            fatalError("background option did not regenerate MB MML")
        }

        model.setQuantization(.thirtySecond)
        guard model.output.contains("REM QUANTIZE: 1/32") else {
            fatalError("quantization did not regenerate the program")
        }

        var copied: String?
        model.copyOutput { text in
            copied = text
            return true
        }
        guard copied == model.output, model.copied else {
            fatalError("copy did not export the complete BASIC program")
        }

        print("AppInteractionTests: OK")
    }
}
