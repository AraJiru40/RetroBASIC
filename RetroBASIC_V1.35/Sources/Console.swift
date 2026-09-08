import Foundation

// MARK: - Console protocol
// The interpreter talks to the outside world only through this protocol,
// so the same core runs under the GUI terminal and a stdio CLI.

protocol Console: AnyObject {
    var column: Int { get }          // 0-based cursor column
    var row: Int { get }             // 0-based cursor row
    var width: Int { get }
    var graphicsWidth: Int { get }
    var breakRequested: Bool { get set }
    func write(_ s: String)
    func readLine() throws -> String?    // blocking; nil = EOF
    func readKey() throws -> Character   // blocking single key (INPUT$)
    func inkey() -> String               // non-blocking (INKEY$)
    func cls()
    func locate(_ x: Int, _ y: Int)
    func setWidth(_ columns: Int)
    func setColor(_ fg: Int, background: Int?)
    func readText(_ x: Int, _ y: Int, count: Int) -> String
    func clearGraphics()
    func pset(_ x: Int, _ y: Int, color: Int)
    func plot(_ points: [(Int, Int)], color: Int)
    func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, color: Int)
    func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, color: Int, filled: Bool)
    func circle(_ cx: Int, _ cy: Int, radius: Int, color: Int, aspect: Double,
                start: Double?, end: Double?)
    func paint(_ x: Int, _ y: Int, color: Int, border: Int)
    func point(_ x: Int, _ y: Int) -> Int
}

// MARK: - PC-8801 style graphics plane

/// A 320/640x200, eight-colour graphics plane. The real PC-8801 stored the three
/// RGB bits in separate VRAM planes; keeping one palette index per pixel gives
/// the same visible result while leaving the interpreter UI-independent.
final class GraphicsSurface {
    static let defaultWidth = 640
    static let height = 200

    private(set) var pixelWidth: Int
    private(set) var pixels: [UInt8]
    private(set) var enabled = false

    init(width: Int = defaultWidth) {
        pixelWidth = width
        pixels = [UInt8](repeating: 0, count: width * Self.height)
    }

    func setWidth(_ width: Int) {
        guard width == 320 || width == 640, width != pixelWidth else { return }
        pixelWidth = width
        pixels = [UInt8](repeating: 0, count: width * Self.height)
        enabled = true
    }

    func clear() {
        pixels = [UInt8](repeating: 0, count: pixelWidth * Self.height)
        enabled = true
    }

    func point(_ x: Int, _ y: Int) -> Int {
        guard contains(x, y) else { return -1 }
        return Int(pixels[y * pixelWidth + x])
    }

    func pset(_ x: Int, _ y: Int, color: Int) {
        guard contains(x, y) else { return }
        pixels[y * pixelWidth + x] = UInt8(color & 7)
        enabled = true
    }

    /// Plot one animation-sized batch in a single surface update. The
    /// interpreter uses this to expose partially completed graphics without
    /// taking the console lock once per pixel.
    func plot(_ points: [(Int, Int)], color: Int) {
        guard !points.isEmpty else { return }
        let value = UInt8(color & 7)
        for (x, y) in points where contains(x, y) {
            pixels[y * pixelWidth + x] = value
        }
        enabled = true
    }

    func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, color: Int) {
        var x = x0, y = y0
        let dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1
        let dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1
        var error = dx + dy
        while true {
            pset(x, y, color: color)
            if x == x1 && y == y1 { break }
            let twice = error * 2
            if twice >= dy { error += dy; x += sx }
            if twice <= dx { error += dx; y += sy }
        }
    }

    func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, color: Int, filled: Bool) {
        let left = min(x0, x1), right = max(x0, x1)
        let top = min(y0, y1), bottom = max(y0, y1)
        if filled {
            guard right >= 0, left < pixelWidth, bottom >= 0, top < Self.height else { return }
            for y in max(0, top)...min(Self.height - 1, bottom) {
                for x in max(0, left)...min(pixelWidth - 1, right) { pset(x, y, color: color) }
            }
        } else {
            line(left, top, right, top, color: color)
            line(right, top, right, bottom, color: color)
            line(right, bottom, left, bottom, color: color)
            line(left, bottom, left, top, color: color)
        }
    }

    func circle(_ cx: Int, _ cy: Int, radius: Int, color: Int, aspect: Double,
                start: Double?, end: Double?) {
        guard radius >= 0, aspect > 0 else { return }
        let ry = max(1, Int((Double(radius) * aspect).rounded()))
        // Sampling by angle avoids gaps on the non-square coordinate grid.
        let steps = max(24, Int(2 * Double.pi * Double(max(radius, ry)) * 1.5))
        let from = start ?? 0
        var to = end ?? (2 * Double.pi)
        if to < from { to += 2 * Double.pi }
        for i in 0...steps {
            let t = from + (to - from) * Double(i) / Double(steps)
            let x = cx + Int((cos(t) * Double(radius)).rounded())
            let y = cy - Int((sin(t) * Double(ry)).rounded())
            pset(x, y, color: color)
        }
    }

    func paint(_ x: Int, _ y: Int, color: Int, border: Int) {
        guard contains(x, y) else { return }
        let replacement = point(x, y)
        let fill = color & 7, edge = border & 7
        guard replacement != fill, replacement != edge else { return }
        var stack = [(x, y)]
        while let (sx, sy) = stack.popLast() {
            guard contains(sx, sy), point(sx, sy) == replacement else { continue }
            var left = sx, right = sx
            while left > 0, point(left - 1, sy) == replacement { left -= 1 }
            while right + 1 < pixelWidth, point(right + 1, sy) == replacement { right += 1 }
            for px in left...right {
                pset(px, sy, color: fill)
                if sy > 0, point(px, sy - 1) == replacement { stack.append((px, sy - 1)) }
                if sy + 1 < Self.height, point(px, sy + 1) == replacement { stack.append((px, sy + 1)) }
            }
        }
    }

    private func contains(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && x < pixelWidth && y >= 0 && y < Self.height
    }
}

// MARK: - Stdio console (CLI / tests)

final class StdioConsole: Console {
    private struct TextCell {
        var ch: Character = " "
        var wideTail = false
    }

    private(set) var column = 0
    private(set) var row = 0
    private(set) var width = 80
    var breakRequested = false
    private let interactive = isatty(fileno(stdin)) != 0
    private let graphics = GraphicsSurface()
    private var textGrid = Array(
        repeating: Array(repeating: TextCell(), count: 80),
        count: 25
    )
    var graphicsWidth: Int { graphics.pixelWidth }

    func write(_ s: String) {
        let stored = RetroCharset.storageString(s)
        for ch in stored {
            switch ch {
            case "\n":
                column = 0
                advanceRow()
            case "\r":
                column = 0
            case "\u{0C}":
                clearText()
            case "\t":
                let target = min(((column / 8) + 1) * 8, width - 1)
                while column < target { putTextCharacter(" ") }
            default:
                guard let scalar = ch.unicodeScalars.first,
                      scalar.value >= 32 || scalar.value > 0x7F else { continue }
                putTextCharacter(ch)
            }
        }
        let displayed = RetroCharset.displayString(stored)
        writeToStandardOutput(displayed)
    }

    private func writeToStandardOutput(_ s: String) {
        FileHandle.standardOutput.write(s.data(using: .utf8) ?? Data())
    }

    private func putTextCharacter(_ ch: Character) {
        let characterWidth = TermWidth.of(ch)
        if column + characterWidth > width {
            column = 0
            advanceRow()
        }
        textGrid[row][column] = TextCell(ch: ch, wideTail: false)
        if characterWidth == 2, column + 1 < width {
            textGrid[row][column + 1] = TextCell(ch: " ", wideTail: true)
        }
        column += characterWidth
        if column >= width {
            column = 0
            advanceRow()
        }
    }

    private func advanceRow() {
        row += 1
        if row >= textGrid.count {
            textGrid.removeFirst()
            textGrid.append(Array(repeating: TextCell(), count: width))
            row = textGrid.count - 1
        }
    }

    private func clearText() {
        textGrid = Array(
            repeating: Array(repeating: TextCell(), count: width),
            count: 25
        )
        column = 0
        row = 0
    }

    func readLine() throws -> String? {
        Swift.readLine(strippingNewline: true)
    }

    func readKey() throws -> Character {
        var byte: UInt8 = 0
        let n = read(0, &byte, 1)
        if n <= 0 { throw BErr("Out of input") }
        return Character(UnicodeScalar(byte))
    }

    func inkey() -> String { "" }

    func cls() {
        if interactive { writeToStandardOutput("\u{1B}[2J\u{1B}[H") }
        clearText()
    }

    func locate(_ x: Int, _ y: Int) {
        if interactive { writeToStandardOutput("\u{1B}[\(y + 1);\(x + 1)H") }
        column = x; row = y
    }

    func setWidth(_ columns: Int) {
        width = columns
        graphics.setWidth(columns * 8)
        cls()
    }

    func readText(_ x: Int, _ y: Int, count: Int) -> String {
        let start = y * width + x
        let cellCount = width * textGrid.count
        var result = ""
        result.reserveCapacity(count)
        for offset in 0..<count {
            let index = start + offset
            guard index < cellCount else {
                result.append(" ")
                continue
            }
            let cell = textGrid[index / width][index % width]
            result.append(cell.wideTail ? " " : cell.ch)
        }
        return result
    }

    func setColor(_ fg: Int, background: Int?) {
        guard interactive else { return }
        let foregroundCodes = [30, 34, 31, 35, 32, 36, 33, 37]
        let backgroundCodes = [40, 44, 41, 45, 42, 46, 43, 47]
        var codes = [foregroundCodes[fg & 7]]
        if let background { codes.append(backgroundCodes[background & 7]) }
        let sequence = "\u{1B}[\(codes.map(String.init).joined(separator: ";"))m"
        writeToStandardOutput(sequence)
    }

    func clearGraphics() { graphics.clear() }
    func pset(_ x: Int, _ y: Int, color: Int) { graphics.pset(x, y, color: color) }
    func plot(_ points: [(Int, Int)], color: Int) { graphics.plot(points, color: color) }
    func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, color: Int) {
        graphics.line(x0, y0, x1, y1, color: color)
    }
    func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, color: Int, filled: Bool) {
        graphics.box(x0, y0, x1, y1, color: color, filled: filled)
    }
    func circle(_ cx: Int, _ cy: Int, radius: Int, color: Int, aspect: Double,
                start: Double?, end: Double?) {
        graphics.circle(cx, cy, radius: radius, color: color, aspect: aspect, start: start, end: end)
    }
    func paint(_ x: Int, _ y: Int, color: Int, border: Int) {
        graphics.paint(x, y, color: color, border: border)
    }
    func point(_ x: Int, _ y: Int) -> Int { graphics.point(x, y) }

}

// MARK: - East Asian width helper

enum TermWidth {
    static func of(_ ch: Character) -> Int {
        guard let u = ch.unicodeScalars.first?.value else { return 1 }
        switch u {
        case 0x1100...0x115F,          // Hangul Jamo
             0x2E80...0x303E,          // CJK Radicals, Kangxi, CJK punctuation
             0x3041...0x33FF,          // Hiragana, Katakana, CJK compat
             0x3400...0x4DBF,          // CJK ext A
             0x4E00...0x9FFF,          // CJK unified
             0xA000...0xA4CF,          // Yi
             0xAC00...0xD7A3,          // Hangul syllables
             0xF900...0xFAFF,          // CJK compat ideographs
             0xFE30...0xFE4F,          // CJK compat forms
             0xFF00...0xFF60,          // Fullwidth forms
             0xFFE0...0xFFE6,
             0x20000...0x2FFFD,
             0x30000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}
