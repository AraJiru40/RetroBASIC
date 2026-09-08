import Foundation

// MARK: - Standard MIDI File model

struct MIDINote: Equatable {
    let startTick: Int
    let endTick: Int
    let pitch: Int
    let velocity: Int
    let channel: Int
    let track: Int
}

struct MIDITempoEvent: Equatable {
    let tick: Int
    let microsecondsPerQuarter: Int
}

struct MIDIPart: Identifiable, Hashable {
    let id: String
    let track: Int
    let channel: Int
    let trackName: String
    let noteCount: Int
    let lowestPitch: Int
    let highestPitch: Int
    let totalTicks: Int

    var isPercussion: Bool { channel == 9 }

    var displayName: String {
        let channelName = isPercussion ? "Ch 10 Drums" : "Ch \(channel + 1)"
        let range = isPercussion
            ? ""
            : " · \(MIDIFile.noteName(lowestPitch))–\(MIDIFile.noteName(highestPitch))"
        return "\(trackName) · \(channelName) · \(noteCount) notes\(range)"
    }
}

struct MIDIFile {
    let fileName: String
    let format: Int
    let ticksPerQuarter: Int
    let trackCount: Int
    let trackNames: [String]
    let notes: [MIDINote]
    let tempoEvents: [MIDITempoEvent]
    let endTick: Int

    var parts: [MIDIPart] {
        let groups = Dictionary(grouping: notes) { Self.partID(track: $0.track, channel: $0.channel) }
        return groups.compactMap { id, notes -> MIDIPart? in
            guard let first = notes.first else { return nil }
            return MIDIPart(
                id: id,
                track: first.track,
                channel: first.channel,
                trackName: trackNames.indices.contains(first.track)
                    ? trackNames[first.track] : "Track \(first.track + 1)",
                noteCount: notes.count,
                lowestPitch: notes.map(\.pitch).min() ?? 0,
                highestPitch: notes.map(\.pitch).max() ?? 0,
                totalTicks: notes.reduce(0) { $0 + max(0, $1.endTick - $1.startTick) }
            )
        }.sorted {
            if $0.track != $1.track { return $0.track < $1.track }
            return $0.channel < $1.channel
        }
    }

    func notes(forPartID id: String) -> [MIDINote] {
        notes.filter { Self.partID(track: $0.track, channel: $0.channel) == id }
    }

    static func partID(track: Int, channel: Int) -> String {
        "\(track):\(channel)"
    }

    static func noteName(_ pitch: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F",
                     "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[(pitch % 12 + 12) % 12])\(pitch / 12 - 1)"
    }
}

enum MIDIFileError: LocalizedError {
    case truncated
    case invalidHeader
    case unsupportedFormat(Int)
    case unsupportedTimeDivision
    case invalidTrack(Int)
    case invalidRunningStatus
    case malformedVariableLength
    case noNotes

    var errorDescription: String? {
        switch self {
        case .truncated: return "MIDIファイルが途中で切れています。"
        case .invalidHeader: return "Standard MIDI Fileではありません。"
        case .unsupportedFormat(let format): return "MIDI Format \(format)には対応していません。"
        case .unsupportedTimeDivision: return "SMPTE時間形式のMIDIには対応していません。"
        case .invalidTrack(let track): return "MIDIトラック\(track + 1)を解析できません。"
        case .invalidRunningStatus: return "MIDIのランニングステータスが不正です。"
        case .malformedVariableLength: return "MIDIの可変長数値が不正です。"
        case .noNotes: return "変換できるノートイベントがありません。"
        }
    }
}

// MARK: - Standard MIDI File parser

enum MIDIFileParser {
    static func parse(_ data: Data, fileName: String) throws -> MIDIFile {
        var reader = MIDIByteReader(data)
        guard try reader.readASCII(4) == "MThd" else { throw MIDIFileError.invalidHeader }
        let headerLength = Int(try reader.readUInt32())
        guard headerLength >= 6 else { throw MIDIFileError.invalidHeader }
        let format = Int(try reader.readUInt16())
        guard format == 0 || format == 1 else { throw MIDIFileError.unsupportedFormat(format) }
        let declaredTrackCount = Int(try reader.readUInt16())
        let division = Int(try reader.readUInt16())
        guard division & 0x8000 == 0, division > 0 else {
            throw MIDIFileError.unsupportedTimeDivision
        }
        if headerLength > 6 { try reader.skip(headerLength - 6) }

        var allNotes: [MIDINote] = []
        var allTempos: [(event: MIDITempoEvent, order: Int)] = []
        var trackNames: [String] = []
        var parsedTracks = 0
        var endTick = 0

        while parsedTracks < declaredTrackCount, !reader.isAtEnd {
            let chunkID = try reader.readASCII(4)
            let chunkLength = Int(try reader.readUInt32())
            let chunk = try reader.readData(chunkLength)
            guard chunkID == "MTrk" else { continue }

            let parsed = try parseTrack(chunk, track: parsedTracks)
            allNotes.append(contentsOf: parsed.notes)
            allTempos.append(contentsOf: parsed.tempos.enumerated().map {
                (event: $0.element, order: parsedTracks * 1_000_000 + $0.offset)
            })
            trackNames.append(parsed.name ?? "Track \(parsedTracks + 1)")
            endTick = max(endTick, parsed.endTick)
            parsedTracks += 1
        }

        guard parsedTracks == declaredTrackCount else { throw MIDIFileError.truncated }
        guard !allNotes.isEmpty else { throw MIDIFileError.noNotes }

        allNotes.sort {
            if $0.startTick != $1.startTick { return $0.startTick < $1.startTick }
            if $0.track != $1.track { return $0.track < $1.track }
            if $0.channel != $1.channel { return $0.channel < $1.channel }
            return $0.pitch < $1.pitch
        }

        let tempos = allTempos.sorted {
            if $0.event.tick != $1.event.tick { return $0.event.tick < $1.event.tick }
            return $0.order < $1.order
        }.map(\.event)

        return MIDIFile(
            fileName: fileName,
            format: format,
            ticksPerQuarter: division,
            trackCount: parsedTracks,
            trackNames: trackNames,
            notes: allNotes,
            tempoEvents: tempos,
            endTick: endTick
        )
    }

    private struct ActiveNote {
        let startTick: Int
        let velocity: Int
    }

    private struct NoteKey: Hashable {
        let channel: Int
        let pitch: Int
    }

    private struct ParsedTrack {
        let name: String?
        let notes: [MIDINote]
        let tempos: [MIDITempoEvent]
        let endTick: Int
    }

    private static func parseTrack(_ data: Data, track: Int) throws -> ParsedTrack {
        var reader = MIDIByteReader(data)
        var tick = 0
        var runningStatus: UInt8?
        var name: String?
        var notes: [MIDINote] = []
        var tempos: [MIDITempoEvent] = []
        var active: [NoteKey: [ActiveNote]] = [:]

        while !reader.isAtEnd {
            tick += try reader.readVariableLength()
            guard !reader.isAtEnd else { throw MIDIFileError.invalidTrack(track) }

            let leading = try reader.peekUInt8()
            let status: UInt8
            if leading & 0x80 != 0 {
                status = try reader.readUInt8()
                if status < 0xF0 { runningStatus = status }
                else { runningStatus = nil }
            } else {
                guard let existing = runningStatus else {
                    throw MIDIFileError.invalidRunningStatus
                }
                status = existing
            }

            if status == 0xFF {
                let type = try reader.readUInt8()
                let length = try reader.readVariableLength()
                let payload = try reader.readData(length)
                switch type {
                case 0x03:
                    if name == nil {
                        name = String(data: payload, encoding: .utf8)
                            ?? String(data: payload, encoding: .macOSRoman)
                    }
                case 0x51 where payload.count == 3:
                    let value = payload.reduce(0) { ($0 << 8) | Int($1) }
                    if value > 0 {
                        tempos.append(MIDITempoEvent(tick: tick,
                                                     microsecondsPerQuarter: value))
                    }
                case 0x2F:
                    reader.moveToEnd()
                default:
                    break
                }
                continue
            }

            if status == 0xF0 || status == 0xF7 {
                try reader.skip(try reader.readVariableLength())
                continue
            }

            guard status < 0xF0 else { throw MIDIFileError.invalidTrack(track) }
            let kind = status & 0xF0
            let channel = Int(status & 0x0F)
            let first = Int(try reader.readUInt8())
            let second: Int?
            switch kind {
            case 0xC0, 0xD0:
                second = nil
            case 0x80, 0x90, 0xA0, 0xB0, 0xE0:
                second = Int(try reader.readUInt8())
            default:
                throw MIDIFileError.invalidTrack(track)
            }

            guard first < 128, second.map({ $0 < 128 }) ?? true else {
                throw MIDIFileError.invalidTrack(track)
            }

            if kind == 0x90, let velocity = second, velocity > 0 {
                let key = NoteKey(channel: channel, pitch: first)
                active[key, default: []].append(ActiveNote(startTick: tick, velocity: velocity))
            } else if kind == 0x80 || (kind == 0x90 && second == 0) {
                let key = NoteKey(channel: channel, pitch: first)
                if var stack = active[key], let started = stack.popLast() {
                    if tick > started.startTick {
                        notes.append(MIDINote(startTick: started.startTick,
                                             endTick: tick,
                                             pitch: first,
                                             velocity: started.velocity,
                                             channel: channel,
                                             track: track))
                    }
                    active[key] = stack.isEmpty ? nil : stack
                }
            }
        }

        for (key, stack) in active {
            for started in stack where tick > started.startTick {
                notes.append(MIDINote(startTick: started.startTick,
                                     endTick: tick,
                                     pitch: key.pitch,
                                     velocity: started.velocity,
                                     channel: key.channel,
                                     track: track))
            }
        }

        return ParsedTrack(name: name, notes: notes, tempos: tempos, endTick: tick)
    }
}

private struct MIDIByteReader {
    private let data: Data
    private(set) var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { offset >= data.count }

    mutating func moveToEnd() { offset = data.count }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw MIDIFileError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    func peekUInt8() throws -> UInt8 {
        guard offset < data.count else { throw MIDIFileError.truncated }
        return data[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let a = UInt16(try readUInt8())
        let b = UInt16(try readUInt8())
        return (a << 8) | b
    }

    mutating func readUInt32() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 { value = (value << 8) | UInt32(try readUInt8()) }
        return value
    }

    mutating func readVariableLength() throws -> Int {
        var value = 0
        for _ in 0..<4 {
            let byte = Int(try readUInt8())
            value = (value << 7) | (byte & 0x7F)
            if byte & 0x80 == 0 { return value }
        }
        throw MIDIFileError.malformedVariableLength
    }

    mutating func readASCII(_ count: Int) throws -> String {
        let bytes = try readData(count)
        guard let string = String(data: bytes, encoding: .ascii) else {
            throw MIDIFileError.invalidHeader
        }
        return string
    }

    mutating func readData(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw MIDIFileError.truncated }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, offset + count <= data.count else { throw MIDIFileError.truncated }
        offset += count
    }
}

// MARK: - RetroBASIC MML conversion

enum MMLQuantization: Int, CaseIterable, Identifiable {
    case eighth = 8
    case sixteenth = 16
    case thirtySecond = 32

    var id: Int { rawValue }
    var label: String { "1/\(rawValue)" }
}

struct MIDIConversionOptions {
    var partIDs: [String?]
    var quantization: MMLQuantization
    var backgroundPlayback: Bool
    var preserveVelocity: Bool
}

struct MIDIConversionResult {
    let channelMML: [String]
    let program: String
    let warnings: [String]
    let approximateDuration: TimeInterval
}

enum MIDIConversionError: LocalizedError {
    case noPartSelected
    case songTooLong(TimeInterval)
    case tooManyGridUnits

    var errorDescription: String? {
        switch self {
        case .noPartSelected: return "PSGチャンネルへ割り当てるパートを選択してください。"
        case .songTooLong(let seconds):
            return String(format: "曲の長さが%.1f秒あります。RetroBASICの上限は600秒です。", seconds)
        case .tooManyGridUnits: return "量子化後の曲が長すぎます。粗い量子化を選択してください。"
        }
    }
}

enum RetroBASICMMLConverter {
    private struct GridCell: Equatable {
        let pitch: Int
        let volume: Int
        let noteIdentity: Int
        let velocity: Int
    }

    private struct DurationToken {
        let units: Int
        let text: String
    }

    static func suggestedPartIDs(for file: MIDIFile) -> [String?] {
        let ranked = file.parts.sorted {
            if $0.totalTicks != $1.totalTicks { return $0.totalTicks > $1.totalTicks }
            return $0.noteCount > $1.noteCount
        }
        var result = ranked.prefix(3).map { Optional($0.id) }
        while result.count < 3 { result.append(nil) }
        return result
    }

    static func convert(_ file: MIDIFile,
                        options: MIDIConversionOptions) throws -> MIDIConversionResult {
        var selected = Array(options.partIDs.prefix(3))
        while selected.count < 3 { selected.append(nil) }
        guard selected.contains(where: { $0 != nil }) else {
            throw MIDIConversionError.noPartSelected
        }

        let gridTicks = Double(file.ticksPerQuarter * 4) / Double(options.quantization.rawValue)
        func gridUnit(_ tick: Int) -> Int {
            max(0, Int((Double(tick) / gridTicks).rounded()))
        }

        let selectedNotes = selected.compactMap { $0 }.flatMap { file.notes(forPartID: $0) }
        let maximumUnit = selectedNotes.map { max(gridUnit($0.startTick) + 1, gridUnit($0.endTick)) }.max() ?? 0
        guard maximumUnit <= 200_000 else { throw MIDIConversionError.tooManyGridUnits }

        var tempoAtUnit: [Int: Int] = [0: 120]
        var tempoWasClamped = false
        for event in file.tempoEvents {
            let rawTempo = Int((60_000_000.0 / Double(event.microsecondsPerQuarter)).rounded())
            let tempo = min(255, max(32, rawTempo))
            if tempo != rawTempo { tempoWasClamped = true }
            tempoAtUnit[gridUnit(event.tick)] = tempo
        }

        var duration = 0.0
        var currentTempo = tempoAtUnit[0] ?? 120
        if maximumUnit > 0 {
            for unit in 0..<maximumUnit {
                if let tempo = tempoAtUnit[unit] { currentTempo = tempo }
                duration += 240.0 / Double(currentTempo) / Double(options.quantization.rawValue)
            }
        }
        guard duration <= 600 else { throw MIDIConversionError.songTooLong(duration) }

        var warnings: [String] = []
        if tempoWasClamped {
            warnings.append("RetroBASICの範囲に合わせ、テンポをT32〜T255へ丸めました。")
        }
        if selectedNotes.contains(where: { $0.pitch < 24 || $0.pitch > 119 }) {
            warnings.append("O1〜O8を超える音は、最も近い対応オクターブへ収めました。")
        }

        var channelMML: [String] = []
        var foundPolyphony = false
        for channelIndex in 0..<3 {
            let modePrefix = channelIndex == 0
                ? (options.backgroundPlayback ? "MB" : "MF")
                : ""
            guard let partID = selected[channelIndex],
                  let part = file.parts.first(where: { $0.id == partID }) else {
                channelMML.append(modePrefix)
                continue
            }
            let notes = file.notes(forPartID: partID)
            let built = makeChannelMML(
                notes: notes,
                part: part,
                modePrefix: modePrefix,
                maximumUnit: maximumUnit,
                gridUnit: gridUnit,
                tempoAtUnit: tempoAtUnit,
                quantization: options.quantization,
                preserveVelocity: options.preserveVelocity
            )
            channelMML.append(built.mml)
            foundPolyphony = foundPolyphony || built.hadPolyphony
        }

        if foundPolyphony {
            warnings.append("同時発音は各パートの最高音を優先し、PSG用の単音へ整理しました。")
        }
        let hasPercussion = selected.compactMap { id in
            id.flatMap { selectedID in file.parts.first(where: { $0.id == selectedID }) }
        }.contains(where: \.isPercussion)
        if hasPercussion {
            warnings.append("MIDIチャンネル10のドラムはAY共有ノイズ（@1）へ変換しました。")
        }

        return MIDIConversionResult(
            channelMML: channelMML,
            program: makeProgram(fileName: file.fileName,
                                 quantization: options.quantization,
                                 channelMML: channelMML),
            warnings: warnings,
            approximateDuration: duration
        )
    }

    private static func makeChannelMML(
        notes: [MIDINote],
        part: MIDIPart,
        modePrefix: String,
        maximumUnit: Int,
        gridUnit: (Int) -> Int,
        tempoAtUnit: [Int: Int],
        quantization: MMLQuantization,
        preserveVelocity: Bool
    ) -> (mml: String, hadPolyphony: Bool) {
        let voiceEnd = notes.map { max(gridUnit($0.startTick) + 1, gridUnit($0.endTick)) }.max() ?? 0
        let length = min(maximumUnit, voiceEnd)
        var cells = [GridCell?](repeating: nil, count: length)
        var hadPolyphony = false

        for (identity, note) in notes.enumerated() {
            let start = min(length, gridUnit(note.startTick))
            let end = min(length, max(start + 1, gridUnit(note.endTick)))
            guard start < end else { continue }
            let candidate = GridCell(
                pitch: part.isPercussion ? 60 : note.pitch,
                volume: max(1, min(15, Int((Double(note.velocity) / 127.0 * 15.0).rounded()))),
                noteIdentity: identity,
                velocity: note.velocity
            )
            for unit in start..<end {
                if let existing = cells[unit] {
                    hadPolyphony = true
                    let candidateWins = part.isPercussion
                        ? candidate.velocity > existing.velocity
                        : (candidate.pitch > existing.pitch
                           || (candidate.pitch == existing.pitch
                               && candidate.velocity > existing.velocity))
                    if candidateWins { cells[unit] = candidate }
                } else {
                    cells[unit] = candidate
                }
            }
        }

        var mml = modePrefix
        mml += part.isPercussion ? "@1Q2" : "@0Q7"
        var currentTempo: Int?
        var currentOctave: Int?
        var currentVolume: Int?
        let tokens = durationTokens(for: quantization)
        var unit = 0

        while unit < cells.count {
            if let tempo = tempoAtUnit[unit], tempo != currentTempo {
                mml += "T\(tempo)"
                currentTempo = tempo
            }
            let cell = cells[unit]
            var end = unit + 1
            while end < cells.count, cells[end] == cell, tempoAtUnit[end] == nil {
                end += 1
            }

            let durations = splitDuration(end - unit, using: tokens)
            if let cell {
                let octave = cell.pitch / 12 - 1
                if octave != currentOctave {
                    mml += "O\(min(8, max(1, octave)))"
                    currentOctave = octave
                }
                if preserveVelocity, cell.volume != currentVolume {
                    mml += "V\(cell.volume)"
                    currentVolume = cell.volume
                } else if !preserveVelocity, currentVolume == nil {
                    mml += "V12"
                    currentVolume = 12
                }
                let note = part.isPercussion ? "C" : noteToken(cell.pitch)
                for (index, duration) in durations.enumerated() {
                    mml += note + duration
                    if index + 1 < durations.count { mml += "&" }
                }
            } else {
                for duration in durations { mml += "R" + duration }
            }
            unit = end
        }
        return (mml, hadPolyphony)
    }

    private static func durationTokens(for quantization: MMLQuantization) -> [DurationToken] {
        var byUnits: [Int: String] = [:]
        for length in [1, 2, 4, 8, 16, 32, 64] {
            for dots in 0...2 {
                let multiplier = dots == 0 ? 1.0 : (dots == 1 ? 1.5 : 1.75)
                let value = Double(quantization.rawValue) / Double(length) * multiplier
                let rounded = Int(value.rounded())
                guard rounded > 0, abs(value - Double(rounded)) < 0.000_001 else { continue }
                let text = "\(length)" + String(repeating: ".", count: dots)
                if byUnits[rounded] == nil || text.count < byUnits[rounded]!.count {
                    byUnits[rounded] = text
                }
            }
        }
        return byUnits.map { DurationToken(units: $0.key, text: $0.value) }
            .sorted { $0.units > $1.units }
    }

    private static func splitDuration(_ units: Int,
                                      using tokens: [DurationToken]) -> [String] {
        var remaining = units
        var result: [String] = []
        while remaining > 0 {
            guard let token = tokens.first(where: { $0.units <= remaining }) else {
                break
            }
            result.append(token.text)
            remaining -= token.units
        }
        return result
    }

    private static func noteToken(_ pitch: Int) -> String {
        ["C", "C+", "D", "D+", "E", "F",
         "F+", "G", "G+", "A", "A+", "B"][(pitch % 12 + 12) % 12]
    }

    private static func makeProgram(fileName: String,
                                    quantization: MMLQuantization,
                                    channelMML: [String]) -> String {
        var lines: [String] = []
        var lineNumber = 10
        func append(_ statement: String) {
            lines.append("\(lineNumber) \(statement)")
            lineNumber += 10
        }

        let safeName = fileName.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        append("REM GENERATED BY MIDI TO RETROBASIC MML")
        append("REM SOURCE: \(safeName)")
        append("REM QUANTIZE: \(quantization.label)")

        let variables = ["A$", "B$", "C$"]
        for index in 0..<3 {
            let mml = channelMML.indices.contains(index) ? channelMML[index] : ""
            let chunks = mml.isEmpty ? [""] : mml.chunks(maxLength: 52)
            for (chunkIndex, chunk) in chunks.enumerated() {
                let operation = chunkIndex == 0 ? "=" : "=" + variables[index] + "+"
                append("\(variables[index])\(operation)\"\(chunk)\"")
            }
        }
        append("PLAY A$,B$,C$")
        append("END")
        return lines.joined(separator: "\n") + "\n"
    }
}

private extension String {
    func chunks(maxLength: Int) -> [String] {
        guard !isEmpty else { return [""] }
        var result: [String] = []
        var start = startIndex
        while start < endIndex {
            let end = index(start, offsetBy: maxLength, limitedBy: endIndex) ?? endIndex
            result.append(String(self[start..<end]))
            start = end
        }
        return result
    }
}
