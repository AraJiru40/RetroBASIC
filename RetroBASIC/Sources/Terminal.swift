import Cocoa

// MARK: - Terminal state (shared between UI thread and interpreter thread)

final class TermCore {
    static let defaultCols = 80
    static let rows = 25

    // Private-use characters used only inside the keyboard queue while the
    // interpreter is waiting for a line.  During program execution the arrow
    // keys still produce the classic CHR$(28)...CHR$(31) values for INKEY$.
    static let editLeft: Character = "\u{E000}"
    static let editRight: Character = "\u{E001}"
    static let editUp: Character = "\u{E002}"
    static let editDown: Character = "\u{E003}"
    static let editDelete: Character = "\u{E004}"

    struct Cell {
        var ch: Character = " "
        var fg: Int = 7
        var wideTail = false
    }

    private let lock = NSLock()
    var grid: [[Cell]]
    private var columnCount = TermCore.defaultCols
    // true when this physical row is a continuation of the preceding row.
    // This lets Enter reconstruct a BASIC line that wrapped at column 80.
    private var wrappedFromPrevious: [Bool]
    var cx = 0
    var cy = 0
    var fg = 7
    var bg = 0
    let graphics = GraphicsSurface()
    var dirty = true
    private var lineInputActive = false
    private var inputOrigin = (x: 0, y: 0)
    private var useInputOrigin = true
    private var insertMode = false

    // keyboard queue
    private let keyCond = NSCondition()
    private var keys: [Character] = []
    // Program-time arrow keys are level-triggered for INKEY$: holding a key
    // returns its direction on every poll, and releasing it stops immediately.
    // Keep their one-shot presses separately so blocking INPUT$ can still
    // consume an arrow as a key event without autorepeat filling the FIFO.
    private var heldProgramKeys: [Character] = []
    private var pendingProgramKeyPresses: [Character] = []
    private var breakFlag = false

    init() {
        grid = Array(repeating: Array(repeating: Cell(), count: Self.defaultCols), count: Self.rows)
        wrappedFromPrevious = Array(repeating: false, count: Self.rows)
    }

    func sync<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var columns: Int { sync { columnCount } }

    /// The column count without taking the lock. Only valid from inside `sync`,
    /// where `columns` would deadlock on the non-recursive lock.
    var columnsWhileLocked: Int { columnCount }

    /// Cursor rendering state without taking the lock. These are only valid
    /// from inside `sync`, alongside the other fields captured by the view.
    var cursorVisibleWhileLocked: Bool { lineInputActive }
    var insertModeWhileLocked: Bool { insertMode }

    func setColumns(_ columns: Int) {
        sync {
            guard columns == 40 || columns == 80, columns != columnCount else { return }
            columnCount = columns
            clearNoLock()
            graphics.setWidth(columns * 8)
            dirty = true
        }
    }

    // MARK: output (called under sync from TerminalConsole)

    func putRaw(_ s: String) {
        sync {
            for ch in RetroCharset.storageString(s) { putChar(ch) }
            dirty = true
        }
    }

    private func putChar(_ ch: Character) {
        switch ch {
        case "\n":
            cx = 0; advanceRow(wrapped: false)
        case "\r":
            cx = 0
        case "\u{07}":
            DispatchQueue.main.async { NSSound.beep() }
        case "\u{0C}":
            clearNoLock()
        case "\t":
            let target = min(((cx / 8) + 1) * 8, columnCount - 1)
            while cx < target { putChar(" ") }
        default:
            guard let u = ch.unicodeScalars.first, u.value >= 32 || u.value > 0x7F else { return }
            let w = TermWidth.of(ch)
            if cx + w > columnCount { cx = 0; advanceRow(wrapped: true) }
            grid[cy][cx] = Cell(ch: ch, fg: fg, wideTail: false)
            if w == 2, cx + 1 < columnCount {
                grid[cy][cx + 1] = Cell(ch: " ", fg: fg, wideTail: true)
            }
            cx += w
            if cx >= columnCount { cx = 0; advanceRow(wrapped: true) }
        }
    }

    private func advanceRow(wrapped: Bool) {
        cy += 1
        if cy >= Self.rows {
            grid.removeFirst()
            grid.append(Array(repeating: Cell(), count: columnCount))
            wrappedFromPrevious.removeFirst()
            wrappedFromPrevious.append(wrapped)
            // The continuation's preceding row has scrolled off screen.
            wrappedFromPrevious[0] = false
            if lineInputActive, inputOrigin.y > 0 { inputOrigin.y -= 1 }
            cy = Self.rows - 1
        } else {
            wrappedFromPrevious[cy] = wrapped
        }
    }

    func backspace(width: Int) {
        sync {
            for _ in 0..<width {
                if cx > 0 { cx -= 1 }
                else if cy > 0 { cy -= 1; cx = columnCount - 1 }
                grid[cy][cx] = Cell(ch: " ", fg: fg, wideTail: false)
            }
            dirty = true
        }
    }

    private func clearNoLock() {
        grid = Array(repeating: Array(repeating: Cell(), count: columnCount), count: Self.rows)
        wrappedFromPrevious = Array(repeating: false, count: Self.rows)
        cx = 0; cy = 0
    }

    func clear() {
        sync { clearNoLock(); dirty = true }
    }

    func setCursor(_ x: Int, _ y: Int) {
        sync {
            cx = max(0, min(x, columnCount - 1))
            cy = max(0, min(y, Self.rows - 1))
            updateOriginUseNoLock()
            dirty = true
        }
    }

    // MARK: graphics plane

    func clearGraphics() {
        sync { graphics.clear(); dirty = true }
    }

    func pset(_ x: Int, _ y: Int, color: Int) {
        sync { graphics.pset(x, y, color: color); dirty = true }
    }

    func plot(_ points: [(Int, Int)], color: Int) {
        sync { graphics.plot(points, color: color); dirty = true }
    }

    func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, color: Int) {
        sync { graphics.line(x0, y0, x1, y1, color: color); dirty = true }
    }

    func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, color: Int, filled: Bool) {
        sync { graphics.box(x0, y0, x1, y1, color: color, filled: filled); dirty = true }
    }

    func circle(_ cx: Int, _ cy: Int, radius: Int, color: Int, aspect: Double,
                start: Double?, end: Double?) {
        sync {
            graphics.circle(cx, cy, radius: radius, color: color, aspect: aspect,
                            start: start, end: end)
            dirty = true
        }
    }

    func paint(_ x: Int, _ y: Int, color: Int, border: Int) {
        sync { graphics.paint(x, y, color: color, border: border); dirty = true }
    }

    func point(_ x: Int, _ y: Int) -> Int { sync { graphics.point(x, y) } }

    func readText(_ x: Int, _ y: Int, count: Int) -> String {
        sync {
            let start = y * columnCount + x
            let cellCount = columnCount * Self.rows
            var result = ""
            result.reserveCapacity(count)
            for offset in 0..<count {
                let index = start + offset
                guard index < cellCount else {
                    result.append(" ")
                    continue
                }
                let cell = grid[index / columnCount][index % columnCount]
                result.append(cell.wideTail ? " " : cell.ch)
            }
            return result
        }
    }

    var screenText: String {
        sync {
            RetroCharset.displayString(grid.map { row in
                String(row.filter { !$0.wideTail }.map { $0.ch })
                    .replacingOccurrences(of: " +$", with: "", options: .regularExpression)
            }.joined(separator: "\n"))
        }
    }

    // MARK: screen editor

    var isLineEditing: Bool { sync { lineInputActive } }
    var isInsertMode: Bool { sync { insertMode } }

    @discardableResult
    func toggleInsertMode() -> Bool {
        sync {
            insertMode.toggle()
            dirty = true
            return insertMode
        }
    }

    func beginLineInput() {
        clearProgramKeys()
        sync {
            lineInputActive = true
            inputOrigin = (cx, cy)
            useInputOrigin = true
            dirty = true
        }
    }

    func cancelLineInput() {
        sync {
            lineInputActive = false
            dirty = true
        }
    }

    /// Return the logical line under the cursor. If it is the line on which
    /// readLine started, omit the already printed prompt (e.g. "? ").
    func finishLineInput() -> String {
        sync {
            var first = cy
            while first > 0, wrappedFromPrevious[first] { first -= 1 }
            var last = cy
            while last + 1 < Self.rows, wrappedFromPrevious[last + 1] { last += 1 }

            let containsOrigin = useInputOrigin && inputOrigin.y >= first && inputOrigin.y <= last
            let firstRow = containsOrigin ? inputOrigin.y : first
            var result = ""
            for row in firstRow...last {
                let from = containsOrigin && row == inputOrigin.y ? inputOrigin.x : 0
                if from < columnCount {
                    for col in from..<columnCount where !grid[row][col].wideTail {
                        result.append(grid[row][col].ch)
                    }
                }
            }
            while result.last == " " { result.removeLast() }
            lineInputActive = false
            dirty = true
            return result
        }
    }

    func moveEditCursor(dx: Int, dy: Int) {
        sync {
            if dy != 0 {
                cy = max(0, min(cy + dy, Self.rows - 1))
                if grid[cy][cx].wideTail, cx > 0 { cx -= 1 }
            } else if dx < 0 {
                moveLeftNoLock()
            } else if dx > 0 {
                moveRightNoLock()
            }
            updateOriginUseNoLock()
            dirty = true
        }
    }

    private func updateOriginUseNoLock() {
        guard lineInputActive else { return }
        var first = cy
        while first > 0, wrappedFromPrevious[first] { first -= 1 }
        var last = cy
        while last + 1 < Self.rows, wrappedFromPrevious[last + 1] { last += 1 }
        useInputOrigin = inputOrigin.y >= first && inputOrigin.y <= last
    }

    private func moveLeftNoLock() {
        if cx > 0 { cx -= 1 }
        else if cy > 0 { cy -= 1; cx = columnCount - 1 }
        if grid[cy][cx].wideTail, cx > 0 { cx -= 1 }
    }

    private func moveRightNoLock() {
        let step = (cx + 1 < columnCount && grid[cy][cx + 1].wideTail) ? 2 : 1
        if cx + step < columnCount { cx += step }
        else if cy + 1 < Self.rows { cy += 1; cx = 0 }
    }

    func putEditCharacter(_ ch: Character) {
        sync {
            let width = TermWidth.of(ch)
            if cx + width > columnCount {
                cx = 0
                advanceRow(wrapped: true)
            }
            if insertMode {
                insertCellsNoLock(count: width)
            }
            clearCellNoLock(x: cx, y: cy)
            if width == 2, cx + 1 < columnCount { clearCellNoLock(x: cx + 1, y: cy) }
            grid[cy][cx] = Cell(ch: ch, fg: fg, wideTail: false)
            if width == 2, cx + 1 < columnCount {
                grid[cy][cx + 1] = Cell(ch: " ", fg: fg, wideTail: true)
            }
            cx += width
            if cx >= columnCount {
                cx = 0
                advanceRow(wrapped: true)
            }
            dirty = true
        }
    }

    func backspaceEdit() {
        sync {
            moveLeftNoLock()
            if insertMode { deleteAndShiftNoLock() }
            else { clearCellNoLock(x: cx, y: cy) }
            dirty = true
        }
    }

    func deleteEdit() {
        sync {
            if insertMode { deleteAndShiftNoLock() }
            else { clearCellNoLock(x: cx, y: cy) }
            dirty = true
        }
    }

    private func logicalBoundsNoLock() -> (first: Int, last: Int) {
        var first = cy
        while first > 0, wrappedFromPrevious[first] { first -= 1 }
        var last = cy
        while last + 1 < Self.rows, wrappedFromPrevious[last + 1] { last += 1 }
        return (first, last)
    }

    private func cellNoLock(flat index: Int, firstRow: Int) -> Cell {
        grid[firstRow + index / columnCount][index % columnCount]
    }

    private func setCellNoLock(flat index: Int, firstRow: Int, _ cell: Cell) {
        grid[firstRow + index / columnCount][index % columnCount] = cell
    }

    /// Make one more physical row part of the logical line. Existing contents
    /// on that row are cleared, matching a real screen editor's reflow.
    private func extendLogicalLineNoLock(first: inout Int, last: inout Int)
        -> (capacityGrew: Bool, scrolled: Bool) {
        if last + 1 < Self.rows {
            last += 1
            grid[last] = Array(repeating: Cell(), count: columnCount)
            wrappedFromPrevious[last] = true
            if inputOrigin.y == last, !useInputOrigin { inputOrigin.y = -1 }
            return (true, false)
        }

        // The logical line reaches the bottom: scroll once to create a row.
        let oldRowCount = last - first + 1
        grid.removeFirst()
        grid.append(Array(repeating: Cell(), count: columnCount))
        wrappedFromPrevious.removeFirst()
        wrappedFromPrevious.append(true)
        wrappedFromPrevious[0] = false
        if inputOrigin.y > 0 { inputOrigin.y -= 1 }
        else { inputOrigin.y = -1; useInputOrigin = false }
        cy = max(0, cy - 1)
        first = max(0, first - 1)
        last = Self.rows - 1
        return (last - first + 1 > oldRowCount, true)
    }

    private func insertCellsNoLock(count: Int) {
        if grid[cy][cx].wideTail, cx > 0 { cx -= 1 }
        var bounds = logicalBoundsNoLock()
        var capacity = (bounds.last - bounds.first + 1) * columnCount
        var cursor = (cy - bounds.first) * columnCount + cx
        var used = capacity
        while used > 0 {
            let cell = cellNoLock(flat: used - 1, firstRow: bounds.first)
            if cell.ch == " ", !cell.wideTail { used -= 1 }
            else { break }
        }

        let needed = max(used + count, cursor + count + 1)
        if needed > capacity {
            let oldFirst = bounds.first
            let extended = extendLogicalLineNoLock(first: &bounds.first, last: &bounds.last)
            if extended.scrolled, oldFirst == 0 {
                cursor = max(0, cursor - columnCount)
                used = max(0, used - columnCount)
            }
            if extended.capacityGrew {
                capacity = (bounds.last - bounds.first + 1) * columnCount
            }
        }

        let sourceEnd = min(used, capacity - count)
        if sourceEnd > cursor {
            for source in stride(from: sourceEnd - 1, through: cursor, by: -1) {
                setCellNoLock(flat: source + count, firstRow: bounds.first,
                              cellNoLock(flat: source, firstRow: bounds.first))
            }
        }
        for index in cursor..<min(cursor + count, capacity) {
            setCellNoLock(flat: index, firstRow: bounds.first, Cell(ch: " ", fg: fg, wideTail: false))
        }
    }

    private func deleteAndShiftNoLock() {
        if grid[cy][cx].wideTail, cx > 0 { cx -= 1 }
        let bounds = logicalBoundsNoLock()
        let capacity = (bounds.last - bounds.first + 1) * columnCount
        let cursor = (cy - bounds.first) * columnCount + cx
        let count = (cx + 1 < columnCount && grid[cy][cx + 1].wideTail) ? 2 : 1
        guard cursor < capacity else { return }

        if cursor + count < capacity {
            for destination in cursor..<(capacity - count) {
                setCellNoLock(flat: destination, firstRow: bounds.first,
                              cellNoLock(flat: destination + count, firstRow: bounds.first))
            }
        }
        for index in max(cursor, capacity - count)..<capacity {
            setCellNoLock(flat: index, firstRow: bounds.first, Cell(ch: " ", fg: fg, wideTail: false))
        }
    }

    private func clearCellNoLock(x: Int, y: Int) {
        if grid[y][x].wideTail {
            grid[y][x] = Cell(ch: " ", fg: fg, wideTail: false)
            if x > 0 { grid[y][x - 1] = Cell(ch: " ", fg: fg, wideTail: false) }
            return
        }
        grid[y][x] = Cell(ch: " ", fg: fg, wideTail: false)
        if x + 1 < columnCount, grid[y][x + 1].wideTail {
            grid[y][x + 1] = Cell(ch: " ", fg: fg, wideTail: false)
        }
    }

    // MARK: keyboard

    func pushKey(_ ch: Character) {
        keyCond.lock()
        keys.append(ch)
        keyCond.signal()
        keyCond.unlock()
    }

    func pressProgramKey(_ ch: Character, isRepeat: Bool) {
        keyCond.lock()
        if !heldProgramKeys.contains(ch) { heldProgramKeys.append(ch) }
        if !isRepeat {
            pendingProgramKeyPresses.append(ch)
            keyCond.signal()
        }
        keyCond.unlock()
    }

    func releaseProgramKey(_ ch: Character) {
        keyCond.lock()
        heldProgramKeys.removeAll { $0 == ch }
        keyCond.unlock()
    }

    func clearProgramKeys() {
        keyCond.lock()
        heldProgramKeys.removeAll()
        pendingProgramKeyPresses.removeAll()
        keyCond.unlock()
    }

    func pushBreak() {
        keyCond.lock()
        // The queued character wakes readLine/readKey. Keep only one pending
        // break so key repeat cannot leak another Ctrl-C into the next prompt.
        if !breakFlag { keys.append("\u{03}") }
        breakFlag = true
        keyCond.signal()
        keyCond.unlock()
    }

    var isBreakRequested: Bool {
        keyCond.lock()
        defer { keyCond.unlock() }
        return breakFlag
    }

    /// Acknowledge one break operation and discard its wake-up character.
    /// Other typed keys are preserved for the screen editor.
    func clearBreak() {
        keyCond.lock()
        breakFlag = false
        keys.removeAll { $0 == "\u{03}" }
        keyCond.unlock()
    }

    func popKeyBlocking() -> Character {
        keyCond.lock()
        while keys.isEmpty && pendingProgramKeyPresses.isEmpty { keyCond.wait() }
        let c = keys.isEmpty ? pendingProgramKeyPresses.removeFirst() : keys.removeFirst()
        keyCond.unlock()
        return c
    }

    func popKeyNonBlocking() -> Character? {
        keyCond.lock()
        defer { keyCond.unlock() }
        return keys.isEmpty ? nil : keys.removeFirst()
    }

    func pollProgramKey() -> Character? {
        keyCond.lock()
        defer { keyCond.unlock() }
        // INKEY$ observes the current arrow-key state, not historical presses.
        pendingProgramKeyPresses.removeAll()
        if !keys.isEmpty { return keys.removeFirst() }
        return heldProgramKeys.last
    }
}

// MARK: - Console implementation backed by TermCore

final class TerminalConsole: Console {
    let core: TermCore
    init(core: TermCore) { self.core = core }

    var column: Int { core.sync { core.cx } }
    var row: Int { core.sync { core.cy } }
    var width: Int { core.columns }
    var graphicsWidth: Int { core.sync { core.graphics.pixelWidth } }
    var breakRequested: Bool {
        get { core.isBreakRequested }
        set { newValue ? core.pushBreak() : core.clearBreak() }
    }

    func write(_ s: String) { core.putRaw(s) }

    func readLine() throws -> String? {
        core.beginLineInput()
        defer { core.cancelLineInput() }
        while true {
            let c = core.popKeyBlocking()
            switch c {
            case "\u{03}":
                core.clearBreak()
                throw BreakSignal()
            case "\n", "\r":
                let line = core.finishLineInput()
                core.putRaw("\n")
                return line
            case "\u{7F}", "\u{08}":
                core.backspaceEdit()
            case TermCore.editLeft: core.moveEditCursor(dx: -1, dy: 0)
            case TermCore.editRight: core.moveEditCursor(dx: 1, dy: 0)
            case TermCore.editUp: core.moveEditCursor(dx: 0, dy: -1)
            case TermCore.editDown: core.moveEditCursor(dx: 0, dy: 1)
            case TermCore.editDelete: core.deleteEdit()
            default:
                if let u = c.unicodeScalars.first, u.value >= 32 || u.value > 0x7F {
                    core.putEditCharacter(c)
                }
            }
        }
    }

    func readKey() throws -> Character {
        let c = core.popKeyBlocking()
        if c == "\u{03}" { core.clearBreak(); throw BreakSignal() }
        return c
    }

    func inkey() -> String {
        guard let c = core.pollProgramKey() else { return "" }
        if c == "\u{03}" { return "" }   // break handled via breakFlag
        return String(c)
    }

    func cls() { core.clear() }
    func locate(_ x: Int, _ y: Int) { core.setCursor(x, y) }
    func setWidth(_ columns: Int) { core.setColumns(columns) }
    func setColor(_ fg: Int, background: Int?) {
        core.sync {
            core.fg = fg & 7
            if let background { core.bg = background & 7 }
            core.dirty = true
        }
    }
    func readText(_ x: Int, _ y: Int, count: Int) -> String {
        core.readText(x, y, count: count)
    }
    func clearGraphics() { core.clearGraphics() }
    func pset(_ x: Int, _ y: Int, color: Int) { core.pset(x, y, color: color) }
    func plot(_ points: [(Int, Int)], color: Int) { core.plot(points, color: color) }
    func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, color: Int) {
        core.line(x0, y0, x1, y1, color: color)
    }
    func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, color: Int, filled: Bool) {
        core.box(x0, y0, x1, y1, color: color, filled: filled)
    }
    func circle(_ cx: Int, _ cy: Int, radius: Int, color: Int, aspect: Double,
                start: Double?, end: Double?) {
        core.circle(cx, cy, radius: radius, color: color, aspect: aspect, start: start, end: end)
    }
    func paint(_ x: Int, _ y: Int, color: Int, border: Int) {
        core.paint(x, y, color: color, border: border)
    }
    func point(_ x: Int, _ y: Int) -> Int { core.point(x, y) }
}

// MARK: - Terminal view

final class TerminalView: NSView, NSTextInputClient, NSMenuItemValidation {
    let core: TermCore

    private static let crtEffectDefaultsKey = "CRTDisplayEffectEnabled"
    private let preferences: UserDefaults
    private(set) var isCRTEffectEnabled: Bool

    // Digital-RGB palette (N88 / MSX style ordering)
    static let palette: [NSColor] = [
        NSColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1),  // 0 black
        NSColor(red: 0.20, green: 0.35, blue: 1.00, alpha: 1),  // 1 blue
        NSColor(red: 1.00, green: 0.35, blue: 0.35, alpha: 1),  // 2 red
        NSColor(red: 1.00, green: 0.45, blue: 1.00, alpha: 1),  // 3 magenta
        NSColor(red: 0.35, green: 1.00, blue: 0.45, alpha: 1),  // 4 green
        NSColor(red: 0.40, green: 1.00, blue: 1.00, alpha: 1),  // 5 cyan
        NSColor(red: 1.00, green: 1.00, blue: 0.40, alpha: 1),  // 6 yellow
        NSColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1),  // 7 white
    ]
    static let background = NSColor(red: 0.0, green: 0.05, blue: 0.55, alpha: 1)  // classic blue

    static func backgroundColor(_ index: Int) -> NSColor {
        // Keep the original deep blue as color 1; the other entries use the
        // same digital-RGB palette as foreground colors.
        index & 7 == 1 ? background : palette[index & 7]
    }

    /// One 32-bit RGBA word per colour, ready to drop straight into the frame
    /// buffer.
    private static func packed(_ color: NSColor) -> UInt32 {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        let r = UInt32((c.redComponent * 255).rounded())
        let g = UInt32((c.greenComponent * 255).rounded())
        let b = UInt32((c.blueComponent * 255).rounded())
        return r | (g << 8) | (b << 16) | 0xFF00_0000
    }
    private static let packedInk: [UInt32] = palette.map { TerminalView.packed($0) }
    private static let packedPaper: [UInt32] = (0..<8).map {
        TerminalView.packed(TerminalView.backgroundColor($0))
    }

    // MARK: screen geometry
    //
    // Text and graphics are composed into a single dot buffer and blown up by
    // an integer factor at the very end. A character cell is 8x8 dots, so 80
    // columns span exactly the 640 dots of the graphics plane and 25 rows span
    // its 200 lines: the two planes line up by construction, the way they do
    // on the real hardware.
    private static let dotRows = TermCore.rows * RetroFont.cellHeight            // 200
    private static let dotColumns = TermCore.defaultCols * RetroFont.cellWidth   // 640

    /// A 200-line screen was shown on a 400-line raster, so one dot is twice as
    /// tall as it is wide. `WIDTH 40` doubles dots horizontally rather than
    /// shrinking the window, exactly as the 40-column mode did.
    private(set) var zoom = 1
    private var margin: CGFloat { CGFloat(8 * zoom) }
    private var dotWidth: CGFloat { CGFloat(Self.dotColumns / (core.columns * RetroFont.cellWidth) * zoom) }
    private var dotHeight: CGFloat { CGFloat(2 * zoom) }

    private var blinkOn = true
    private var timer: Timer?
    private var cachedFramebuffer: NSBitmapImageRep?
    private var fallbackCache: [Character: [UInt16]] = [:]

    init(core: TermCore, preferences: UserDefaults = .standard) {
        self.core = core
        self.preferences = preferences
        isCRTEffectEnabled = preferences.bool(forKey: Self.crtEffectDefaultsKey)
        super.init(frame: .zero)
        zoom = Self.fittingZoom()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let phase = Int(Date().timeIntervalSince1970 * 2.5) % 2 == 0
            let dirty = self.core.sync { () -> Bool in
                let d = self.core.dirty
                self.core.dirty = false
                return d
            }
            if dirty || phase != self.blinkOn {
                self.blinkOn = phase
                self.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var desiredSize: NSSize {
        NSSize(width: CGFloat(Self.dotColumns * zoom) + 2 * margin,
               height: CGFloat(Self.dotRows * 2 * zoom) + 2 * margin)
    }

    /// Largest whole-number zoom whose window still sits comfortably on screen.
    private static func fittingZoom() -> Int {
        guard let visible = NSScreen.main?.visibleFrame else { return 2 }
        var best = 1
        for z in 1...4 {
            let size = NSSize(width: CGFloat(dotColumns * z + 16 * z),
                              height: CGFloat(dotRows * 2 * z + 16 * z))
            if size.width <= visible.width * 0.9 && size.height <= visible.height * 0.9 { best = z }
        }
        return best
    }

    func setZoom(_ value: Int) {
        let clamped = max(1, min(value, 4))
        guard clamped != zoom else { return }
        zoom = clamped
        window?.setContentSize(desiredSize)
        needsDisplay = true
    }

    // MARK: glyphs

    /// Eight rows of up to 16 dots, bit 15 leftmost, so that full-width
    /// characters occupying two cells use the same representation.
    private func glyphRows(_ ch: Character) -> [UInt16] {
        if ch.unicodeScalars.count == 1, let scalar = ch.unicodeScalars.first,
           let rows = RetroFont.glyph(for: scalar) {
            return rows.map { UInt16($0) << 8 }
        }
        return fallbackRows(ch)
    }

    /// Characters the character ROM never had (kanji, hiragana, symbols) are
    /// rasterised from the system font into the same dot grid. They come out
    /// coarse -- a 200-line screen simply has no room for them -- but they stay
    /// aligned with everything else.
    private func fallbackRows(_ ch: Character) -> [UInt16] {
        if let cached = fallbackCache[ch] { return cached }
        let width = TermWidth.of(ch) * RetroFont.cellWidth
        let height = RetroFont.cellHeight
        var rows = [UInt16](repeating: 0, count: height)
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false,
                                      isPlanar: false, colorSpaceName: .deviceWhite,
                                      bytesPerRow: width, bitsPerPixel: 8),
           let data = rep.bitmapData, let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.setShouldAntialias(false)
            context.cgContext.setShouldSmoothFonts(false)
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()
            let text = String(ch) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: CGFloat(height)),
                .foregroundColor: NSColor.white,
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (CGFloat(width) - size.width) / 2,
                                  y: (CGFloat(height) - size.height) / 2), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
            for y in 0..<height {
                var bits: UInt16 = 0
                for x in 0..<width where data[y * width + x] > 110 {
                    bits |= UInt16(0x8000) >> UInt16(x)
                }
                rows[y] = bits
            }
        }
        fallbackCache[ch] = rows
        return rows
    }

    private func blit(_ rows: [UInt16], column: Int, row: Int, color: UInt32,
                      into dots: UnsafeMutablePointer<UInt32>, width: Int) {
        let left = column * RetroFont.cellWidth
        let top = row * RetroFont.cellHeight
        for (dy, bits) in rows.enumerated() where bits != 0 {
            let base = (top + dy) * width
            var mask: UInt16 = 0x8000
            for dx in 0..<16 {
                if bits & mask != 0, left + dx < width { dots[base + left + dx] = color }
                mask >>= 1
            }
        }
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        let (grid, cx, cy, bg, columns, cursorVisible, insertMode,
             graphicsOn, graphicsPixels) = core.sync {
            (core.grid, core.cx, core.cy, core.bg, core.columnsWhileLocked,
             core.cursorVisibleWhileLocked, core.insertModeWhileLocked,
             core.graphics.enabled, core.graphics.pixels)
        }
        Self.backgroundColor(bg).setFill()
        bounds.fill()

        let width = columns * RetroFont.cellWidth
        let height = Self.dotRows
        guard let rep = framebuffer(width: width), let raw = rep.bitmapData else { return }
        let dots = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: UInt32.self)

        let paper = Self.packedPaper[bg & 7]
        for i in 0..<(width * height) { dots[i] = paper }

        // The graphics plane sits behind the text, filling the screen once any
        // of it has been drawn on.
        if graphicsOn && graphicsPixels.count == width * height {
            for i in 0..<(width * height) { dots[i] = Self.packedInk[Int(graphicsPixels[i]) & 7] }
        }

        for (r, rowCells) in grid.enumerated() where r < TermCore.rows {
            for (c, cell) in rowCells.enumerated() where c < columns {
                if cell.wideTail || cell.ch == " " { continue }
                blit(glyphRows(cell.ch), column: c, row: r,
                     color: Self.packedInk[cell.fg & 7], into: dots, width: width)
            }
        }

        // The hardware cursor belongs to the screen editor. During program
        // execution (including INKEY$-driven games), LOCATE only changes the
        // output position and must not leave a blinking block on the playfield.
        // A thin caret indicates insert mode; the classic block is overwrite.
        if blinkOn, cursorVisible, cy < grid.count, cx < columns, cx < grid[cy].count {
            let ink = Self.packedInk[7]
            let left = cx * RetroFont.cellWidth
            let top = cy * RetroFont.cellHeight
            if insertMode {
                for dy in 0..<RetroFont.cellHeight { dots[(top + dy) * width + left] = ink }
            } else {
                for dy in 0..<RetroFont.cellHeight {
                    for dx in 0..<RetroFont.cellWidth { dots[(top + dy) * width + left + dx] = ink }
                }
                let under = grid[cy][cx]
                if under.ch != " " {
                    blit(glyphRows(under.ch), column: cx, row: cy,
                         color: paper, into: dots, width: width)
                }
            }
        }

        let screenRect = NSRect(x: margin, y: margin,
                                width: CGFloat(Self.dotColumns * zoom),
                                height: CGFloat(Self.dotRows * 2 * zoom))
        rep.draw(in: screenRect,
                 from: .zero, operation: .copy, fraction: 1,
                 respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
        if isCRTEffectEnabled { drawCRTEffect(framebuffer: rep, in: screenRect) }
    }

    /// Add a restrained CRT character without animating the display: a soft
    /// phosphor halo, scanlines aligned to the 200 source rows, and barely
    /// perceptible edge falloff. The sharp framebuffer remains underneath.
    private func drawCRTEffect(framebuffer: NSBitmapImageRep, in screenRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: screenRect)

        // Several faint, offset screen-blended copies approximate phosphor
        // diffusion while leaving the original pixel grid readable.
        let halo = max(1, CGFloat(zoom) * 0.9)
        let offsets = [
            NSPoint(x: -halo, y: 0), NSPoint(x: halo, y: 0),
            NSPoint(x: 0, y: -halo), NSPoint(x: 0, y: halo),
            NSPoint(x: -halo, y: -halo), NSPoint(x: halo, y: -halo),
            NSPoint(x: -halo, y: halo), NSPoint(x: halo, y: halo),
        ]
        for offset in offsets {
            framebuffer.draw(in: screenRect.offsetBy(dx: offset.x, dy: offset.y),
                             from: .zero, operation: .screen, fraction: 0.035,
                             respectFlipped: true,
                             hints: [.interpolation: NSImageInterpolation.none])
        }

        // Each logical raster row is 2 * zoom points high. Darkening the lower
        // half very slightly creates stable scanlines without adding animation.
        NSColor.black.withAlphaComponent(0.09).setFill()
        let rasterHeight = CGFloat(2 * zoom)
        let scanlineHeight = CGFloat(zoom)
        for row in 0..<Self.dotRows {
            NSRect(x: screenRect.minX,
                   y: screenRect.minY + CGFloat(row) * rasterHeight + rasterHeight - scanlineHeight,
                   width: screenRect.width, height: scanlineHeight).fill()
        }

        context.setBlendMode(.normal)
        drawVignette(in: screenRect, context: context)
        context.restoreGState()
    }

    private func drawVignette(in rect: NSRect, context: CGContext) {
        let horizontalDepth = rect.width * 0.10
        let verticalDepth = rect.height * 0.12
        drawEdgeGradient(from: CGPoint(x: rect.minX, y: rect.midY),
                         to: CGPoint(x: rect.minX + horizontalDepth, y: rect.midY),
                         alpha: 0.025, context: context)
        drawEdgeGradient(from: CGPoint(x: rect.maxX, y: rect.midY),
                         to: CGPoint(x: rect.maxX - horizontalDepth, y: rect.midY),
                         alpha: 0.025, context: context)
        drawEdgeGradient(from: CGPoint(x: rect.midX, y: rect.minY),
                         to: CGPoint(x: rect.midX, y: rect.minY + verticalDepth),
                         alpha: 0.018, context: context)
        drawEdgeGradient(from: CGPoint(x: rect.midX, y: rect.maxY),
                         to: CGPoint(x: rect.midX, y: rect.maxY - verticalDepth),
                         alpha: 0.018, context: context)
    }

    private func drawEdgeGradient(from start: CGPoint, to end: CGPoint,
                                  alpha: CGFloat, context: CGContext) {
        let components: [CGFloat] = [
            0, 0, 0, alpha,
            0, 0, 0, 0,
        ]
        guard let gradient = CGGradient(colorSpace: CGColorSpaceCreateDeviceRGB(),
                                        colorComponents: components,
                                        locations: [0, 1], count: 2) else { return }
        context.drawLinearGradient(gradient, start: start, end: end,
                                   options: [.drawsBeforeStartLocation])
    }

    private func framebuffer(width: Int) -> NSBitmapImageRep? {
        if let existing = cachedFramebuffer, existing.pixelsWide == width { return existing }
        cachedFramebuffer = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
                                            pixelsHigh: Self.dotRows,
                                            bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: width * 4, bitsPerPixel: 32)
        return cachedFramebuffer
    }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control),
           let ch = event.charactersIgnoringModifiers?.lowercased() {
            if ch == "c" {
                core.pushBreak()
                return
            }
            if ch == "i", core.isLineEditing {
                _ = core.toggleInsertMode()
                return
            }
        }
        let editing = core.isLineEditing
        switch event.keyCode {
        case 123:
            editing ? core.pushKey(TermCore.editLeft)
                    : core.pressProgramKey("\u{1D}", isRepeat: event.isARepeat)
        case 124:
            editing ? core.pushKey(TermCore.editRight)
                    : core.pressProgramKey("\u{1C}", isRepeat: event.isARepeat)
        case 125:
            editing ? core.pushKey(TermCore.editDown)
                    : core.pressProgramKey("\u{1F}", isRepeat: event.isARepeat)
        case 126:
            editing ? core.pushKey(TermCore.editUp)
                    : core.pressProgramKey("\u{1E}", isRepeat: event.isARepeat)
        default: interpretKeyEvents([event])
        }
    }

    override func keyUp(with event: NSEvent) {
        switch event.keyCode {
        case 123: core.releaseProgramKey("\u{1D}")
        case 124: core.releaseProgramKey("\u{1C}")
        case 125: core.releaseProgramKey("\u{1F}")
        case 126: core.releaseProgramKey("\u{1E}")
        default: super.keyUp(with: event)
        }
    }

    override func resignFirstResponder() -> Bool {
        core.clearProgramKeys()
        return super.resignFirstResponder()
    }

    @objc func sendBreak(_ sender: Any?) { core.pushBreak() }

    @objc func toggleInsertMode(_ sender: Any?) {
        guard core.isLineEditing else { return }
        let enabled = core.toggleInsertMode()
        (sender as? NSMenuItem)?.state = enabled ? .on : .off
    }

    @objc func toggleCRTEffect(_ sender: Any?) {
        isCRTEffectEnabled.toggle()
        preferences.set(isCRTEffectEnabled, forKey: Self.crtEffectDefaultsKey)
        (sender as? NSMenuItem)?.state = isCRTEffectEnabled ? .on : .off
        needsDisplay = true
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleInsertMode(_:)) {
            menuItem.state = core.isInsertMode ? .on : .off
            return core.isLineEditing
        }
        if menuItem.action == #selector(toggleCRTEffect(_:)) {
            menuItem.state = isCRTEffectEnabled ? .on : .off
        }
        return true
    }

    @objc func paste(_ sender: Any?) {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        let normalized = s.replacingOccurrences(of: "\r\n", with: "\n")
                          .replacingOccurrences(of: "\r", with: "\n")
        for ch in RetroCharset.storageString(normalized) { core.pushKey(ch) }
    }

    @objc func copy(_ sender: Any?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(core.screenText, forType: .string)
    }

    @objc func zoomIn(_ sender: Any?) { setZoom(zoom + 1) }
    @objc func zoomOut(_ sender: Any?) { setZoom(zoom - 1) }

    // MARK: NSTextInputClient (minimal: commit-only IME support)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        for ch in RetroCharset.storageString(s) { core.pushKey(ch) }
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): core.pushKey("\n")
        case #selector(NSResponder.deleteBackward(_:)): core.pushKey("\u{7F}")
        case #selector(NSResponder.deleteForward(_:)): core.pushKey(TermCore.editDelete)
        case #selector(NSResponder.moveLeft(_:)):
            core.pushKey(core.isLineEditing ? TermCore.editLeft : "\u{1D}")
        case #selector(NSResponder.moveRight(_:)):
            core.pushKey(core.isLineEditing ? TermCore.editRight : "\u{1C}")
        case #selector(NSResponder.moveUp(_:)):
            core.pushKey(core.isLineEditing ? TermCore.editUp : "\u{1E}")
        case #selector(NSResponder.moveDown(_:)):
            core.pushKey(core.isLineEditing ? TermCore.editDown : "\u{1F}")
        case #selector(NSResponder.cancelOperation(_:)): core.pushBreak()
        default: break
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { false }
    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let w = window else { return .zero }
        let (cx, cy) = core.sync { (core.cx, core.cy) }
        let cellW = CGFloat(RetroFont.cellWidth) * dotWidth
        let cellH = CGFloat(RetroFont.cellHeight) * dotHeight
        let local = NSRect(x: margin + CGFloat(cx) * cellW,
                           y: margin + CGFloat(cy + 1) * cellH,
                           width: cellW, height: cellH)
        let inWindow = convert(local, to: nil)
        return w.convertToScreen(inWindow)
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
}
