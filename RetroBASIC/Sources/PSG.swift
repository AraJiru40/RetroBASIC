import AVFoundation
import Foundation

// MARK: - Music Macro Language

enum PSGWaveform: Equatable {
    case tone
    case noise
    case toneAndNoise
}

enum MMLPlaybackMode: Equatable {
    case foreground
    case background
}

struct PSGNoteEvent: Equatable {
    let start: TimeInterval
    let duration: TimeInterval
    var soundingDuration: TimeInterval
    let frequency: Double?
    let volume: Int
    let waveform: PSGWaveform
    var tiedFromPrevious: Bool
    var tiedToNext: Bool
}

struct PSGScore {
    let channels: [[PSGNoteEvent]]
    let duration: TimeInterval
    let requestedPlaybackMode: MMLPlaybackMode?
}

/// MSX1 BIOS BEEP (00C0H): channel A, tone period 0x055, volume 7, 40 ms.
/// Deriving the frequency from the PSG clock keeps it on the same quantized
/// pitch grid as PLAY instead of substituting a generic computer alert sound.
enum MSXBeep {
    static let tonePeriod = 0x055
    static let frequency = 1_789_773.0 / (16.0 * Double(tonePeriod))
    static let duration: TimeInterval = 0.040
    static let volume = 7

    static var score: PSGScore {
        let event = PSGNoteEvent(
            start: 0,
            duration: duration,
            soundingDuration: duration,
            frequency: frequency,
            volume: volume,
            waveform: .tone,
            tiedFromPrevious: false,
            tiedToNext: false
        )
        return PSGScore(channels: [[event]], duration: duration,
                        requestedPlaybackMode: .foreground)
    }
}

struct MMLError: Error {
    let message: String
}

/// Compiles the MSX-style subset of MML used by PLAY into three PSG tracks.
/// Timing is resolved while parsing, so each channel may change its own tempo.
enum MMLCompiler {
    static let maximumChannels = 3
    static let maximumDuration: TimeInterval = 600

    static func compile(channels source: [String]) throws -> PSGScore {
        guard !source.isEmpty, source.count <= maximumChannels else {
            throw MMLError(message: "MML syntax error")
        }
        var tracks: [[PSGNoteEvent]] = []
        var duration: TimeInterval = 0
        var requestedMode: MMLPlaybackMode?
        for text in source {
            let parsed = try MMLChannelParser(text).parse()
            tracks.append(parsed.events)
            duration = max(duration, parsed.events.last.map { $0.start + $0.duration } ?? 0)
            if let mode = parsed.requestedPlaybackMode {
                if let existing = requestedMode, existing != mode {
                    throw MMLError(message: "MML playback mode conflict")
                }
                requestedMode = mode
            }
        }
        guard duration <= maximumDuration else { throw MMLError(message: "MML too long") }
        return PSGScore(channels: tracks, duration: duration,
                        requestedPlaybackMode: requestedMode)
    }
}

private struct ParsedMMLChannel {
    let events: [PSGNoteEvent]
    let requestedPlaybackMode: MMLPlaybackMode?
}

private final class MMLChannelParser {
    private let source: [Character]
    private var position = 0
    private var time: TimeInterval = 0
    private var octave = 4
    private var defaultLength = 4
    private var tempo = 120
    private var volume = 8
    private var quantize = 8
    private var waveform: PSGWaveform = .tone
    private var requestedPlaybackMode: MMLPlaybackMode?
    private var pendingTie = false
    private var events: [PSGNoteEvent] = []

    init(_ text: String) {
        source = Array(text.uppercased())
    }

    func parse() throws -> ParsedMMLChannel {
        while true {
            skipSpaces()
            guard position < source.count else { break }
            let command = source[position]
            position += 1
            switch command {
            case "A"..."G":
                try appendNote(command)
            case "N":
                try appendNumberedNote()
            case "R":
                try appendRest()
            case "T":
                tempo = try requiredNumber(in: 32...255)
            case "O":
                octave = try requiredNumber(in: 1...8)
            case "L":
                defaultLength = try requiredNumber(in: 1...64)
            case "M":
                try readPlaybackMode()
            case "V":
                volume = try requiredNumber(in: 0...15)
            case "Q":
                quantize = try requiredNumber(in: 1...8)
            case ">":
                guard octave < 8 else { throw syntaxError() }
                octave += 1
            case "<":
                guard octave > 1 else { throw syntaxError() }
                octave -= 1
            case "&":
                try beginTie()
            case "@":
                let mode = try requiredNumber(in: 0...2)
                waveform = [.tone, .noise, .toneAndNoise][mode]
            default:
                throw syntaxError()
            }
        }
        if pendingTie { throw syntaxError() }
        return ParsedMMLChannel(events: events,
                                requestedPlaybackMode: requestedPlaybackMode)
    }

    private func readPlaybackMode() throws {
        guard position < source.count else { throw syntaxError() }
        let mode: MMLPlaybackMode
        switch source[position] {
        case "F": mode = .foreground
        case "B": mode = .background
        default: throw syntaxError()
        }
        position += 1
        if let existing = requestedPlaybackMode, existing != mode {
            throw MMLError(message: "MML playback mode conflict")
        }
        requestedPlaybackMode = mode
    }

    private func appendNote(_ name: Character) throws {
        let semitones: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5,
                                           "G": 7, "A": 9, "B": 11]
        var pitch = semitones[name]!
        if position < source.count {
            if source[position] == "+" || source[position] == "#" {
                pitch += 1; position += 1
            } else if source[position] == "-" {
                pitch -= 1; position += 1
            }
        }
        let (duration, _) = try readDuration()
        let midiNote = (octave + 1) * 12 + pitch
        let frequency = Self.ayFrequency(forMIDINote: midiNote)
        let event = PSGNoteEvent(
            start: time,
            duration: duration,
            soundingDuration: duration * Double(quantize) / 8.0,
            frequency: frequency,
            volume: volume,
            waveform: waveform,
            tiedFromPrevious: pendingTie,
            tiedToNext: false
        )
        pendingTie = false
        events.append(event)
        time += duration
    }

    private func appendNumberedNote() throws {
        let number = try requiredNumber(in: 0...96)
        let duration = durationForDefaultLengthWithDots()
        if number == 0 {
            if pendingTie { throw syntaxError() }
            events.append(PSGNoteEvent(
                start: time, duration: duration, soundingDuration: 0, frequency: nil,
                volume: 0, waveform: waveform, tiedFromPrevious: false, tiedToNext: false
            ))
        } else {
            // MSX MML numbers C1 as N1, C2 as N13, ... C8 as N85.
            events.append(PSGNoteEvent(
                start: time,
                duration: duration,
                soundingDuration: duration * Double(quantize) / 8.0,
                frequency: Self.ayFrequency(forMIDINote: number + 23),
                volume: volume,
                waveform: waveform,
                tiedFromPrevious: pendingTie,
                tiedToNext: false
            ))
            pendingTie = false
        }
        time += duration
    }

    private func appendRest() throws {
        if pendingTie { throw syntaxError() }
        let (duration, _) = try readDuration()
        events.append(PSGNoteEvent(
            start: time,
            duration: duration,
            soundingDuration: 0,
            frequency: nil,
            volume: 0,
            waveform: waveform,
            tiedFromPrevious: false,
            tiedToNext: false
        ))
        time += duration
    }

    private func beginTie() throws {
        guard !pendingTie, !events.isEmpty, events[events.count - 1].frequency != nil else {
            throw syntaxError()
        }
        events[events.count - 1].soundingDuration = events[events.count - 1].duration
        events[events.count - 1].tiedToNext = true
        pendingTie = true
    }

    private func readDuration() throws -> (TimeInterval, Int) {
        skipSpaces()
        let length = optionalNumber() ?? defaultLength
        guard (1...64).contains(length) else { throw syntaxError() }
        var multiplier = 1.0
        var addition = 0.5
        while position < source.count, source[position] == "." {
            multiplier += addition
            addition /= 2
            position += 1
        }
        let wholeNote = 240.0 / Double(tempo)
        return (wholeNote / Double(length) * multiplier, length)
    }

    private func durationForDefaultLengthWithDots() -> TimeInterval {
        var multiplier = 1.0
        var addition = 0.5
        while position < source.count, source[position] == "." {
            multiplier += addition
            addition /= 2
            position += 1
        }
        return 240.0 / Double(tempo) / Double(defaultLength) * multiplier
    }

    private static func ayFrequency(forMIDINote note: Int) -> Double {
        let target = 440.0 * pow(2.0, Double(note - 69) / 12.0)
        let period = max(1, min(4095, Int((1_789_773.0 / (16.0 * target)).rounded())))
        return 1_789_773.0 / (16.0 * Double(period))
    }

    private func requiredNumber(in range: ClosedRange<Int>) throws -> Int {
        skipSpaces()
        guard let value = optionalNumber(), range.contains(value) else { throw syntaxError() }
        return value
    }

    private func optionalNumber() -> Int? {
        guard position < source.count, source[position].isASCIIDigit else { return nil }
        var value = 0
        while position < source.count, source[position].isASCIIDigit {
            let digit = Int(String(source[position]))!
            if value <= (256 - digit) / 10 {
                value = value * 10 + digit
            } else {
                // No MML command accepts a value above 255. Saturating keeps
                // malformed input in the normal syntax-error path without
                // risking an Int overflow while consuming the remaining digits.
                value = 256
            }
            position += 1
        }
        return value
    }

    private func skipSpaces() {
        while position < source.count,
              source[position] == " " || source[position] == "\t" { position += 1 }
    }

    private func syntaxError() -> MMLError {
        MMLError(message: "MML syntax error at \(max(1, position))")
    }
}

// MARK: - AY-3-8910-style audio renderer

protocol MMLPlaying: AnyObject {
    func play(channels: [String], shouldStop: () -> Bool) throws -> MMLPlaybackResult
    func beep(shouldStop: () -> Bool) throws -> MMLPlaybackResult
    func isPlaying(channel: Int) -> Bool
    func stop()
}

enum MMLPlaybackResult: Equatable {
    case completed
    case startedInBackground
    case interrupted
}

final class PSGPlayer: NSObject, MMLPlaying, AVAudioPlayerDelegate {
    static let sampleRate = 44_100.0
    private let playbackLock = NSLock()
    private var backgroundPlayer: AVAudioPlayer?
    private var backgroundChannelEndTimes: [TimeInterval] = []
    private var playbackMode: MMLPlaybackMode = .foreground

    func play(channels: [String], shouldStop: () -> Bool) throws -> MMLPlaybackResult {
        let score = try MMLCompiler.compile(channels: channels)
        if let requestedMode = score.requestedPlaybackMode {
            playbackMode = requestedMode
        }
        stop()
        return try play(score: score, mode: playbackMode, shouldStop: shouldStop)
    }

    func beep(shouldStop: () -> Bool) throws -> MMLPlaybackResult {
        // The MSX BIOS initializes the PLAY machinery before producing BEEP,
        // so an active background tune is stopped and channel A is reused.
        stop()
        return try play(score: MSXBeep.score, mode: .foreground, shouldStop: shouldStop)
    }

    private func play(score: PSGScore, mode: MMLPlaybackMode,
                      shouldStop: () -> Bool) throws -> MMLPlaybackResult {
        guard score.duration > 0 else {
            return mode == .background ? .startedInBackground : .completed
        }

        let waveData = Self.renderWave(score)
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: waveData)
        } catch {
            throw MMLError(message: "Audio device unavailable")
        }
        player.volume = 0.8
        player.prepareToPlay()
        if mode == .background {
            player.delegate = self
            playbackLock.lock()
            backgroundPlayer = player
            backgroundChannelEndTimes = score.channels.map {
                $0.last.map { $0.start + $0.duration } ?? 0
            }
            playbackLock.unlock()
            guard player.play() else {
                clearBackgroundPlayer(ifSameAs: player)
                throw MMLError(message: "Audio device unavailable")
            }
            return .startedInBackground
        }

        guard player.play() else { throw MMLError(message: "Audio device unavailable") }
        while player.isPlaying {
            if shouldStop() {
                player.stop()
                return .interrupted
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return .completed
    }

    func stop() {
        playbackLock.lock()
        let player = backgroundPlayer
        backgroundPlayer = nil
        backgroundChannelEndTimes = []
        playbackLock.unlock()
        player?.stop()
    }

    func isPlaying(channel: Int) -> Bool {
        playbackLock.lock()
        defer { playbackLock.unlock() }
        guard let player = backgroundPlayer, player.isPlaying else {
            backgroundPlayer = nil
            backgroundChannelEndTimes = []
            return false
        }
        let time = player.currentTime
        if channel == 0 {
            return backgroundChannelEndTimes.contains { time < $0 }
        }
        let index = channel - 1
        return backgroundChannelEndTimes.indices.contains(index)
            && time < backgroundChannelEndTimes[index]
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        clearBackgroundPlayer(ifSameAs: player)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        clearBackgroundPlayer(ifSameAs: player)
    }

    private func clearBackgroundPlayer(ifSameAs player: AVAudioPlayer) {
        playbackLock.lock()
        if backgroundPlayer === player {
            backgroundPlayer = nil
            backgroundChannelEndTimes = []
        }
        playbackLock.unlock()
    }

    /// AVAudioPlayer is intentionally fed a complete mono WAV. Unlike an audio
    /// unit source node, its initializer fails normally when CoreAudio is not
    /// available instead of raising an Objective-C exception in a headless CLI.
    static func renderWave(_ score: PSGScore) -> Data {
        let frameCount = Int(ceil(score.duration * Self.sampleRate))
        let dataByteCount = frameCount * MemoryLayout<Int16>.size
        var wave = Data(count: 44 + dataByteCount)
        let state = PSGRenderState(score: score, sampleRate: Self.sampleRate)

        wave.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            func put(_ text: String, at offset: Int) {
                for (index, byte) in text.utf8.enumerated() { bytes[offset + index] = byte }
            }
            func put16(_ value: UInt16, at offset: Int) {
                bytes[offset] = UInt8(value & 0xFF)
                bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
            }
            func put32(_ value: UInt32, at offset: Int) {
                bytes[offset] = UInt8(value & 0xFF)
                bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
                bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
                bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
            }

            put("RIFF", at: 0)
            put32(UInt32(36 + dataByteCount), at: 4)
            put("WAVE", at: 8)
            put("fmt ", at: 12)
            put32(16, at: 16)                         // PCM format chunk size
            put16(1, at: 20)                          // linear PCM
            put16(1, at: 22)                          // mono PSG output
            put32(UInt32(Self.sampleRate), at: 24)
            put32(UInt32(Self.sampleRate * 2), at: 28)
            put16(2, at: 32)
            put16(16, at: 34)
            put("data", at: 36)
            put32(UInt32(dataByteCount), at: 40)

            for frame in 0..<frameCount {
                let value = Int16((Double(state.nextSample()) * Double(Int16.max)).rounded())
                put16(UInt16(bitPattern: value), at: 44 + frame * 2)
            }
        }
        return wave
    }
}

private final class PSGRenderState {
    private let score: PSGScore
    private let sampleRate: Double
    private var frame: Int64 = 0
    private var eventIndexes = [Int](repeating: 0, count: MMLCompiler.maximumChannels)
    private var previousEventIndexes = [Int](repeating: -1, count: MMLCompiler.maximumChannels)
    private var phases = [Double](repeating: 0, count: MMLCompiler.maximumChannels)
    private var noisePhase = 0.0
    private var noiseRegister: UInt32 = 0x1FFFF
    private var noiseHigh = true

    // Approximate AY-3-8910 logarithmic DAC levels, normalized to level 15.
    private static let levels: [Double] = [
        0.000000, 0.009994, 0.014450, 0.021057,
        0.030701, 0.045548, 0.064499, 0.107362,
        0.126588, 0.204989, 0.292210, 0.372838,
        0.492530, 0.635324, 0.805584, 1.000000
    ]

    init(score: PSGScore, sampleRate: Double) {
        self.score = score
        self.sampleRate = sampleRate
    }

    func nextSample() -> Float {
        let now = Double(frame) / sampleRate
        advanceNoise()
        var mixed = 0.0

        for channel in 0..<score.channels.count {
            let events = score.channels[channel]
            var index = eventIndexes[channel]
            while index < events.count, now >= events[index].start + events[index].duration {
                index += 1
            }
            eventIndexes[channel] = index
            guard index < events.count else { continue }
            let event = events[index]
            guard now >= event.start, let frequency = event.frequency,
                  now < event.start + event.soundingDuration else { continue }

            if previousEventIndexes[channel] != index {
                if !event.tiedFromPrevious { phases[channel] = 0 }
                previousEventIndexes[channel] = index
            }
            phases[channel] += frequency / sampleRate
            phases[channel] -= floor(phases[channel])
            let toneHigh = phases[channel] < 0.5
            let signal: Double
            switch event.waveform {
            case .tone:
                signal = toneHigh ? 1 : -1
            case .noise:
                signal = noiseHigh ? 1 : -1
            case .toneAndNoise:
                // The AY mixer ANDs its unipolar tone and noise outputs.
                signal = toneHigh && noiseHigh ? 1 : -1.0 / 3.0
            }

            let elapsed = now - event.start
            let remaining = event.start + event.soundingDuration - now
            let attack = event.tiedFromPrevious ? 1 : min(1, elapsed / 0.0015)
            let release = event.tiedToNext ? 1 : min(1, remaining / 0.002)
            mixed += signal * Self.levels[event.volume] * max(0, min(attack, release))
        }

        frame += 1
        // The original chip exposes one mono mix of its three channels.
        return Float(max(-1, min(1, mixed * 0.32)))
    }

    private func advanceNoise() {
        // AY noise period 16 at the common 1.789773 MHz clock.
        noisePhase += (1_789_773.0 / (16.0 * 16.0)) / sampleRate
        while noisePhase >= 1 {
            let feedback = (noiseRegister ^ (noiseRegister >> 3)) & 1
            noiseRegister = (noiseRegister >> 1) | (feedback << 16)
            noiseHigh = (noiseRegister & 1) != 0
            noisePhase -= 1
        }
    }
}
