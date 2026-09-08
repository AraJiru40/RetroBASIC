import Foundation

extension Character {
    var isASCIIDigit: Bool { self >= "0" && self <= "9" }
}

@main
struct MIDIConversionTests {
    static func main() throws {
        let file = try parseFixture()
        try convertLead(file)
        try convertBackground(file)
        try convertDrums(file)
        rejectMalformedFiles()
        print("MIDIConversionTests: OK")
    }

    private static func parseFixture() throws -> MIDIFile {
        let file = try MIDIFileParser.parse(MIDIFixture.make(), fileName: "fixture.mid")
        require(file.format == 1, "wrong MIDI format")
        require(file.ticksPerQuarter == 480, "wrong MIDI division")
        require(file.trackCount == 3, "wrong track count")
        require(file.notes.count == 5, "wrong note count")
        require(file.tempoEvents == [
            MIDITempoEvent(tick: 0, microsecondsPerQuarter: 500_000),
            MIDITempoEvent(tick: 480, microsecondsPerQuarter: 1_000_000),
        ], "tempo map was not parsed")
        require(file.parts.map(\.trackName) == ["Lead", "Drums"], "part names were not parsed")
        require(file.notes.contains(where: {
            $0.pitch == 67 && $0.startTick == 480 && $0.endTick == 720
        }), "running status note was not parsed")
        return file
    }

    private static func convertLead(_ file: MIDIFile) throws {
        let lead = file.parts.first(where: { $0.trackName == "Lead" })!
        let result = try RetroBASICMMLConverter.convert(
            file,
            options: MIDIConversionOptions(
                partIDs: [lead.id, nil, nil],
                quantization: .sixteenth,
                backgroundPlayback: false,
                preserveVelocity: true
            )
        )
        require(result.channelMML[0] == "MF@0Q7T120O4V9E4T60V11G8",
                "unexpected lead MML: \(result.channelMML[0])")
        require(result.channelMML[1].isEmpty && result.channelMML[2].isEmpty,
                "unused PSG channels were not empty")
        require(result.program.contains("PLAY A$,B$,C$"), "missing PLAY statement")
        require(result.program.contains("REM SOURCE: fixture.mid"), "missing source comment")
        require(result.warnings.contains(where: { $0.contains("最高音") }),
                "polyphony warning was not generated")
        let score = try MMLCompiler.compile(channels: result.channelMML)
        require(score.channels[0].count == 2, "RetroBASIC rejected or changed generated notes")
    }

    private static func convertBackground(_ file: MIDIFile) throws {
        let lead = file.parts.first(where: { $0.trackName == "Lead" })!
        let result = try RetroBASICMMLConverter.convert(
            file,
            options: MIDIConversionOptions(
                partIDs: [nil, lead.id, nil],
                quantization: .eighth,
                backgroundPlayback: true,
                preserveVelocity: false
            )
        )
        require(result.channelMML[0] == "MB", "background mode was not put on channel A")
        require(result.channelMML[1].hasPrefix("@0Q7T120"), "lead was not assigned to channel B")
        require(result.channelMML[1].contains("V12"), "fixed volume was not emitted")
        let score = try MMLCompiler.compile(channels: result.channelMML)
        require(score.requestedPlaybackMode == .background,
                "RetroBASIC did not accept generated MB mode")
    }

    private static func convertDrums(_ file: MIDIFile) throws {
        let drums = file.parts.first(where: \.isPercussion)!
        let result = try RetroBASICMMLConverter.convert(
            file,
            options: MIDIConversionOptions(
                partIDs: [drums.id, nil, nil],
                quantization: .sixteenth,
                backgroundPlayback: false,
                preserveVelocity: true
            )
        )
        require(result.channelMML[0].hasPrefix("MF@1Q2"), "drums did not use AY noise")
        require(result.warnings.contains(where: { $0.contains("共有ノイズ") }),
                "drum conversion warning was not generated")
    }

    private static func rejectMalformedFiles() {
        for data in [Data(), Data("not midi".utf8), MIDIFixture.make().prefix(20)] {
            do {
                _ = try MIDIFileParser.parse(Data(data), fileName: "broken.mid")
                fatalError("accepted malformed MIDI")
            } catch {
                // expected
            }
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}
