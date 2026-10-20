import Foundation

private final class RecordingPlayer: MMLPlaying {
    var channels: [String] = []
    var result: MMLPlaybackResult = .completed
    var beepCount = 0
    var stopCount = 0
    var playingChannels: Set<Int> = []
    func play(channels: [String], shouldStop: () -> Bool) throws -> MMLPlaybackResult {
        self.channels = channels
        return shouldStop() ? .interrupted : result
    }
    func beep(shouldStop: () -> Bool) throws -> MMLPlaybackResult {
        beepCount += 1
        return shouldStop() ? .interrupted : result
    }
    func isPlaying(channel: Int) -> Bool {
        channel == 0 ? !playingChannels.isEmpty : playingChannels.contains(channel)
    }
    func stop() { stopCount += 1 }
}

private final class TestConsole: Console {
    var column = 0
    var row = 0
    var width = 80
    var graphicsWidth = 640
    var breakRequested = false
    var output = ""
    func write(_ s: String) { output += s }
    func readLine() throws -> String? { nil }
    func readKey() throws -> Character { "\0" }
    func inkey() -> String { "" }
    func cls() {}
    func locate(_ x: Int, _ y: Int) {}
    func setWidth(_ columns: Int) { width = columns; graphicsWidth = columns * 8 }
    func setColor(_ fg: Int, background: Int?) {}
    func readText(_ x: Int, _ y: Int, count: Int) -> String {
        String(repeating: " ", count: count)
    }
    func clearGraphics() {}
    func pset(_ x: Int, _ y: Int, color: Int) {}
    func plot(_ points: [(Int, Int)], color: Int) {}
    func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, color: Int) {}
    func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, color: Int, filled: Bool) {}
    func circle(_ cx: Int, _ cy: Int, radius: Int, color: Int, aspect: Double,
                start: Double?, end: Double?) {}
    func paint(_ x: Int, _ y: Int, color: Int, border: Int) {}
    func point(_ x: Int, _ y: Int) -> Int { 0 }
}

@main
struct MMLTests {
    static func main() throws {
        try compileNotesAndControls()
        try compileParallelChannels()
        try compileNoiseAndTie()
        try compilePlaybackModes()
        testMSXBeepScore()
        try renderPCMBuffer()
        try rejectInvalidMML()
        dispatchPlayStatement()
        queryBackgroundPlayback()
        print("MMLTests: OK")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    private static func close(_ a: Double, _ b: Double, epsilon: Double = 0.000_001) -> Bool {
        abs(a - b) < epsilon
    }

    private static func compileNotesAndControls() throws {
        let score = try MMLCompiler.compile(channels: ["T120O4L4V15Q6 C D+8. R8 >C2 N37 N0."])
        let notes = score.channels[0]
        require(notes.count == 6, "wrong event count")
        require(close(notes[0].frequency!, 1_789_773.0 / (16.0 * 428.0)), "wrong middle C")
        require(close(notes[0].duration, 0.5), "wrong quarter-note duration")
        require(close(notes[0].soundingDuration, 0.375), "wrong Q gate duration")
        require(close(notes[1].duration, 0.375), "wrong dotted eighth duration")
        require(notes[2].frequency == nil, "R did not compile as a rest")
        require(close(notes[3].frequency!, 1_789_773.0 / (16.0 * 214.0)), "wrong octave shift")
        require(close(notes[4].frequency!, notes[0].frequency!), "N note numbering is wrong")
        require(notes[5].frequency == nil && close(notes[5].duration, 0.75), "N0 rest is wrong")
    }

    private static func compileParallelChannels() throws {
        let score = try MMLCompiler.compile(channels: ["T120L4C", "T60L1C", ""])
        require(score.channels.count == 3, "PLAY did not retain three channels")
        require(close(score.duration, 4), "score did not use longest channel")
    }

    private static func compileNoiseAndTie() throws {
        let score = try MMLCompiler.compile(channels: ["@2V12L8C&C@1D"])
        let notes = score.channels[0]
        require(notes[0].waveform == .toneAndNoise && notes[2].waveform == .noise,
                "waveform selection failed")
        require(notes[0].tiedToNext && notes[1].tiedFromPrevious,
                "tie flags were not compiled")
        require(close(notes[0].soundingDuration, notes[0].duration), "tie left a gate gap")
    }

    private static func compilePlaybackModes() throws {
        let defaultScore = try MMLCompiler.compile(channels: ["T120C"])
        let background = try MMLCompiler.compile(channels: ["MBT120C", "O3G"])
        let foreground = try MMLCompiler.compile(channels: ["MFT120C"])
        require(defaultScore.requestedPlaybackMode == nil, "default mode should be inherited")
        require(background.requestedPlaybackMode == .background, "MB was not compiled")
        require(foreground.requestedPlaybackMode == .foreground, "MF was not compiled")
        require(background.channels[0].count == 1, "MB leaked into note parsing")

        for channels in [["MBMF"], ["MBC", "MFG"]] {
            do {
                _ = try MMLCompiler.compile(channels: channels)
                fatalError("accepted conflicting playback modes")
            } catch is MMLError {
                // expected
            }
        }
    }

    private static func testMSXBeepScore() {
        let score = MSXBeep.score
        require(score.channels.count == 1 && score.channels[0].count == 1,
                "BEEP must use PSG channel A only")
        let beep = score.channels[0][0]
        require(close(beep.frequency!, 1_789_773.0 / (16.0 * Double(0x55))),
                "BEEP does not use the MSX tone period")
        require(close(beep.duration, 0.040), "BEEP duration is not 40 ms")
        require(beep.volume == 7 && beep.waveform == .tone,
                "BEEP volume or waveform differs from MSX1")
    }

    private static func renderPCMBuffer() throws {
        let score = try MMLCompiler.compile(channels: ["T255L64V15C"])
        let wave = PSGPlayer.renderWave(score)
        require(String(data: wave.prefix(4), encoding: .ascii) == "RIFF", "missing RIFF header")
        require(String(data: wave[8..<12], encoding: .ascii) == "WAVE", "missing WAVE header")
        require(wave.count > 44 && wave.dropFirst(44).contains(where: { $0 != 0 }),
                "renderer produced no PCM signal")
    }

    private static func rejectInvalidMML() throws {
        let invalidSources = ["O9C", "T10C", "L0C", "Q9C", "@3C", "C&", "R&C", "Z",
                              "T" + String(repeating: "9", count: 1_000) + "C"]
        for source in invalidSources {
            do {
                _ = try MMLCompiler.compile(channels: [source])
                fatalError("accepted invalid MML: \(source)")
            } catch is MMLError {
                // expected
            }
        }
    }

    private static func dispatchPlayStatement() {
        let console = TestConsole()
        let player = RecordingPlayer()
        let interpreter = Interpreter(console: console, mmlPlayer: player)
        interpreter.handleImmediate("A$=\"O4CDE\":PLAY A$,\"O3G\",\"R4\":PRINT \"DONE\"")
        require(player.channels == ["O4CDE", "O3G", "R4"], "PLAY arguments were not dispatched")
        require(console.output == "DONE\n", "execution did not continue after PLAY")

        player.result = .startedInBackground
        console.output = ""
        interpreter.handleImmediate("PLAY \"MBC\":PRINT \"RUNNING\"")
        require(console.output == "RUNNING\n", "background PLAY did not continue execution")

        console.output = ""
        interpreter.handleImmediate("BEEP:PRINT \"BEEPED\"")
        require(player.beepCount == 1, "BEEP was not dispatched to the PSG player")
        require(console.output == "BEEPED\n", "execution did not continue after BEEP")
    }

    private static func queryBackgroundPlayback() {
        let console = TestConsole()
        let player = RecordingPlayer()
        let interpreter = Interpreter(console: console, mmlPlayer: player)
        player.playingChannels = [1, 3]

        interpreter.handleImmediate("IF PLAY(0) THEN PRINT \"ALL\"")
        interpreter.handleImmediate("IF PLAY(1) THEN PRINT \"A\"")
        interpreter.handleImmediate("IF PLAY(2) THEN PRINT \"B\"")
        interpreter.handleImmediate("IF PLAY(3) THEN PRINT \"C\"")
        require(console.output == "ALL\nA\nC\n", "PLAY(n) returned the wrong channel status")

        player.playingChannels = []
        console.output = ""
        interpreter.handleImmediate("IF PLAY(0) THEN PRINT \"ACTIVE\" ELSE PRINT \"IDLE\"")
        require(console.output == "IDLE\n", "PLAY(0) did not report idle")

        console.output = ""
        interpreter.handleImmediate("PRINT PLAY(4)")
        require(console.output.contains("Illegal function call"), "PLAY accepted an invalid channel")
    }
}
